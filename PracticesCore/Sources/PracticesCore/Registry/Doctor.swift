import Foundation
import CryptoKit

/// A report instead of discipline. Reads `.env` files and plain text under the projects root
/// and compares them with the registry. Findings carry key names and paths —
/// values are compared inside this process and never leave it.
public struct DoctorFinding: Hashable, Sendable, Codable {
    public enum Kind: String, Sendable, Codable {
        case leak           // a registry secret written in a plain file
        case drift          // an .env key the registry knows, with a different value
        case duplicate      // an .env file whose registry keys all match: replaceable by `run`
        case shared         // one secret value in several .env files, unknown to the registry
    }
    public let kind: Kind
    public let path: String
    public let keys: [String]
    /// For drift and duplicate: the service the keys belong to; for shared: the other files.
    public let related: [String]
}

public enum Doctor {

    static let skippedDirs: Set<String> = ["node_modules", ".venv", "venv", ".git", "build", "dist", "target",
                                           "DerivedData", ".build", "__pycache__", ".claude", ".ua", ".mypy_cache"]
    static let textExtensions: Set<String> = ["md", "txt", "py", "ts", "tsx", "js", "json", "yml", "yaml",
                                              "toml", "sh", "ini", "cfg", "conf", "sql", "swift", "ipynb", "html"]

    static func isEnvFile(_ name: String) -> Bool {
        let lower = name.lowercased()
        guard lower.hasPrefix(".env") || lower.hasSuffix(".env") else { return false }
        return !["example", "sample", "template", "dist"].contains { lower.contains($0) }
    }

    /// Secrets live in config and notes, not in data dumps: bigger files are skipped.
    static let maxTextSize = 1024 * 1024

    /// One walk: `.env` files, and text files small enough to hold a pasted secret.
    public static func collect(root: String) -> (env: [String], text: [String]) {
        var env: [String] = [], text: [String] = []
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: URL(fileURLWithPath: root),
                                         includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey],
                                         options: []) else { return ([], []) }
        for case let url as URL in walker {
            let name = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true { continue }
            if values?.isDirectory == true {
                if skippedDirs.contains(name) { walker.skipDescendants() }
                continue
            }
            if isEnvFile(name) { env.append(url.path); continue }
            if textExtensions.contains(url.pathExtension.lowercased()), (values?.fileSize ?? .max) <= maxTextSize {
                text.append(url.path)
            }
        }
        return (env.sorted(), text)
    }

    public static func run(root: String = Monitor.projectsRoot(), registry: Registry = Registry(),
                           store: SecretStore = SecretStore(), scanText: Bool = true) async throws -> [DoctorFinding] {
        let services = try registry.services()
        var keyOwner: [String: [Service]] = [:]
        for service in services { for key in service.keys { keyOwner[key.name, default: []].append(service) } }

        let (envFiles, textFiles) = collect(root: root)
        var findings: [DoctorFinding] = []
        var unknownSecrets: [String: [(path: String, key: String)]] = [:]   // digest → places

        for path in envFiles {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            let pairs = EnvFiles.parseDotenv(text)
            var byService: [String: (same: [String], differ: [String])] = [:]
            var unknownCount = 0
            for (key, value) in pairs where !value.isEmpty {
                guard let owners = keyOwner[key] else {
                    unknownCount += 1
                    if Service.Key.looksSecret(key), value.count >= 8 {
                        unknownSecrets[digest(value), default: []].append((path, key))
                    }
                    continue
                }
                // A key two services declare is matched against any of their environments.
                var matched: String?
                var anyValue = false
                for service in owners {
                    for env in service.envs {
                        guard let stored = try store.values(service: service.id, env: env)[key] else { continue }
                        anyValue = true
                        if stored == value { matched = service.id }
                    }
                }
                let owner = matched ?? owners[0].id
                if matched != nil { byService[owner, default: ([], [])].same.append(key) }
                else if anyValue { byService[owner, default: ([], [])].differ.append(key) }
            }
            for (service, keys) in byService.sorted(by: { $0.key < $1.key }) {
                if !keys.differ.isEmpty {
                    findings.append(.init(kind: .drift, path: path, keys: keys.differ.sorted(), related: [service]))
                } else if unknownCount == 0 && byService.count == 1 {
                    findings.append(.init(kind: .duplicate, path: path, keys: keys.same.sorted(), related: [service]))
                }
            }
        }

        for (_, places) in unknownSecrets {
            let files = Set(places.map(\.path))
            guard files.count > 1 else { continue }
            let keys = Array(Set(places.map(\.key))).sorted()
            let sorted = files.sorted()
            findings.append(.init(kind: .shared, path: sorted[0], keys: keys, related: Array(sorted.dropFirst())))
        }

        if scanText {
            // Values of four bytes or more only, as MultiSearch keeps them (secretValues already
            // drops anything under eight).
            let secrets = try store.secretValues(services: services).filter { $0.value.utf8.count >= 4 }
            let search = MultiSearch(secrets.map(\.value))
            for (path, indices) in await search.scan(textFiles).sorted(by: { $0.key < $1.key }) {
                let hits = indices.map { secrets[$0] }
                findings.append(.init(kind: .leak, path: path,
                                      keys: Array(Set(hits.map(\.key))).sorted(),
                                      related: Array(Set(hits.map(\.service))).sorted()))
            }
        }

        let order: [DoctorFinding.Kind] = [.leak, .drift, .shared, .duplicate]
        return findings.sorted { (order.firstIndex(of: $0.kind)!, $0.path) < (order.firstIndex(of: $1.kind)!, $1.path) }
    }

    /// Unknown secrets are grouped by a digest so equal values meet without being kept.
    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
