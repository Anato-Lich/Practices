import Foundation

/// A host port a compose service would publish on `docker compose up`.
public struct PortClaim: Hashable, Sendable, Codable {
    public let project: String
    public let service: String
    public let hostPort: Int
    public let containerPort: Int
    public let hostIP: String?
    /// The files the claim was resolved from: one file, or a base file plus an overlay.
    public let files: [String]

    /// Where the service answers under OrbStack without publishing anything.
    public var orbURL: String { "http://\(service).\(project).orb.local:\(containerPort)" }
}

public struct ComposeScan: Sendable, Codable {
    public let date: Date
    public let claims: [PortClaim]
    /// Files that could not be resolved, with compose's own message.
    public let unresolved: [String: String]
}

/// Finds compose files under the projects root and resolves the ports they publish through
/// `docker compose config`, which applies `.env`, interpolation, `extends` and `!override`
/// exactly as `up` would (DECISIONS 13).
public enum ComposeScanner {

    static let skippedDirectories: Set<String> = ["node_modules", ".venv", "venv", "build", "dist", "target"]

    /// Files for servers, not for this machine.
    static func isServerFile(_ name: String) -> Bool {
        let lower = name.lowercased()
        return ["prod", "stage", "staging"].contains { lower.contains(".\($0).") || lower.contains("-\($0).") }
    }

    /// Local overlays that only make sense on top of a base file (`docker-compose.ports.yml`).
    static func isOverlay(_ name: String) -> Bool {
        let lower = name.lowercased()
        return ["ports", "override", "local"].contains { lower.contains(".\($0).") }
    }

    static func isComposeFile(_ name: String) -> Bool {
        let lower = name.lowercased()
        guard lower.hasSuffix(".yml") || lower.hasSuffix(".yaml") else { return false }
        return lower.hasPrefix("docker-compose") || lower.hasPrefix("compose")
    }

    public static func findFiles(root: String = Monitor.projectsRoot(), maxDepth: Int = 6) -> [String] {
        let fm = FileManager.default
        var result: [String] = []
        func walk(_ dir: String, depth: Int) {
            guard depth <= maxDepth, let names = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for name in names.sorted() {
                let path = dir + "/" + name
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: path, isDirectory: &isDir) else { continue }
                if isDir.boolValue {
                    // Dot folders hold agent worktrees and copies (.claude/worktrees), not projects.
                    if name.hasPrefix(".") || skippedDirectories.contains(name) { continue }
                    walk(path, depth: depth + 1)
                } else if isComposeFile(name) && !isServerFile(name) {
                    result.append(path)
                }
            }
        }
        walk(root, depth: 0)
        return result
    }

    /// Files an overlay may extend, most likely first: the dev file of the same folder, then
    /// the plain one, then any other non-overlay sibling.
    static func bases(for overlay: String, among files: [String]) -> [String] {
        let dir = (overlay as NSString).deletingLastPathComponent
        let siblings = files.filter {
            ($0 as NSString).deletingLastPathComponent == dir && $0 != overlay
                && !isOverlay(($0 as NSString).lastPathComponent)
        }
        let preferred = ["docker-compose.dev.yml", "docker-compose.dev.yaml", "compose.dev.yml", "compose.dev.yaml",
                         "docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml"]
        func rank(_ path: String) -> Int {
            preferred.firstIndex(of: (path as NSString).lastPathComponent) ?? preferred.count
        }
        return siblings.sorted { (rank($0), $0) < (rank($1), $1) }
    }

    /// A file that is only a fragment: compose rejects it alone because a service has no image.
    static func isFragmentError(_ error: Error) -> Bool {
        (error as? Shell.Failure)?.stderr.contains("neither an image nor a build context") ?? false
    }

    /// Resolves a file alone, or on top of the first sibling it extends cleanly.
    static func resolve(file: String, among files: [String]) async -> Result<[PortClaim], Error> {
        let alone = await resolve([file])
        guard case .failure(let error) = alone, isFragmentError(error) else { return alone }
        for base in bases(for: file, among: files) where base != file {
            let layered = await resolve([base, file])
            if case .success = layered { return layered }
        }
        if case .failure(let error) = alone, let failure = error as? Shell.Failure {
            // Every base was tried and none defines the overlay's services: a stale overlay.
            return .failure(Shell.Failure(tool: failure.tool, status: failure.status,
                                          stderr: "fits no base file in its folder — " + describe(failure)))
        }
        return alone
    }

    public static func scan(root: String = Monitor.projectsRoot()) async -> ComposeScan {
        let files = findFiles(root: root)
        var claims: [PortClaim] = []
        var unresolved: [String: String] = [:]
        await withTaskGroup(of: (String, Result<[PortClaim], Error>).self) { group in
            var pending = files[...]
            // Four at a time: each is a short docker CLI process.
            for _ in 0..<4 {
                guard let file = pending.popFirst() else { break }
                group.addTask { (file, await resolve(file: file, among: files)) }
            }
            for await (file, result) in group {
                switch result {
                case .success(let found): claims.append(contentsOf: found)
                case .failure(let error): unresolved[file] = describe(error)
                }
                if let next = pending.popFirst() {
                    group.addTask { (next, await resolve(file: next, among: files)) }
                }
            }
        }
        var seen = Set<String>()
        claims = claims
            .sorted { ($0.hostPort, $0.project, $0.service, $0.files.count) < ($1.hostPort, $1.project, $1.service, $1.files.count) }
            .filter { seen.insert("\($0.project)|\($0.service)|\($0.hostPort)").inserted }
        return ComposeScan(date: Date(), claims: claims, unresolved: unresolved)
    }

    static func describe(_ error: Error) -> String {
        guard let failure = error as? Shell.Failure else { return String(describing: error) }
        // Compose prints warnings first; the reason is the last line.
        return failure.stderr.split(separator: "\n").last.map(String.init) ?? failure.description
    }

    static func resolve(_ files: [String]) async -> Result<[PortClaim], Error> {
        let dir = (files[0] as NSString).deletingLastPathComponent
        var args = ["compose", "--project-directory", dir]
        for file in files { args += ["-f", file] }
        args += ["config", "--format", "json"]
        do {
            let output = try await Shell.run("docker", args)
            return .success(try parse(configJSON: Data(output.utf8), files: files))
        } catch {
            return .failure(error)
        }
    }

    private struct Config: Decodable {
        struct Service: Decodable {
            struct Port: Decodable {
                let target: Int
                let published: String?
                let host_ip: String?
                let `protocol`: String?
            }
            let ports: [Port]?
        }
        let name: String
        let services: [String: Service]
    }

    static func parse(configJSON data: Data, files: [String]) throws -> [PortClaim] {
        let config = try JSONDecoder().decode(Config.self, from: data)
        var claims: [PortClaim] = []
        for (serviceName, service) in config.services {
            for port in service.ports ?? [] where (port.protocol ?? "tcp") == "tcp" {
                guard let published = port.published, !published.isEmpty else { continue }
                let bounds = published.split(separator: "-").compactMap { Int($0) }
                guard let first = bounds.first else { continue }
                let last = bounds.count > 1 ? bounds[1] : first
                for (offset, hostPort) in (first...max(first, last)).enumerated() {
                    claims.append(PortClaim(
                        project: config.name, service: serviceName, hostPort: hostPort,
                        containerPort: port.target + offset, hostIP: port.host_ip, files: files))
                }
            }
        }
        return claims
    }
}
