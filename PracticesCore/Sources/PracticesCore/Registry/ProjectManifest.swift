import Foundation
import Yams

/// `practices.yaml` at a project's root, committed with the project: which sources it uses and
/// in which environment (DECISIONS 19). References only, no values.
///
///     sources:
///       - xkeeper-pg@prod
///       - kafka@dev
///
/// A project that names a variable its own way keeps its name through an alias:
///
///     env:
///       BFF_CLICKHOUSE_PASSWORD: CH_PASSWORD_READONLY   # project name: registry key
///
/// Env files Practices writes into the project (DECISIONS 48) — each with its own sources and
/// environments, so `.env` can be dev while `.deploy.env` is prod:
///
///     files:
///       - path: .env
///         sources: [clickhouse@dev, kafka@prod]
///         env: {BFF_CLICKHOUSE_PASSWORD: CH_PASSWORD_READONLY}
public struct ProjectManifest: Codable, Hashable, Sendable {
    public var sources: [SourceRef]
    /// Project variable → registry key; set in addition to the registry's own names.
    public var env: [String: String]
    public var files: [ManagedFile]

    public init(sources: [SourceRef], env: [String: String] = [:], files: [ManagedFile] = []) {
        self.sources = sources; self.env = env; self.files = files
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sources = try c.decodeIfPresent([SourceRef].self, forKey: .sources) ?? []
        env = try c.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        files = try c.decodeIfPresent([ManagedFile].self, forKey: .files) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sources, forKey: .sources)
        if !env.isEmpty { try c.encode(env, forKey: .env) }
        if !files.isEmpty { try c.encode(files, forKey: .files) }
    }

    enum CodingKeys: String, CodingKey { case sources, env, files }

    public static func load(_ dir: URL) -> ProjectManifest? {
        guard let text = try? String(contentsOf: dir.appendingPathComponent(fileName), encoding: .utf8) else { return nil }
        return try? YAMLDecoder().decode(ProjectManifest.self, from: text)
    }

    public func save(to dir: URL) throws {
        let header = "# Sources this project uses (Practices). Names and environments only, no values.\n"
        try (header + Registry.yaml(self)).write(to: dir.appendingPathComponent(Self.fileName), atomically: true, encoding: .utf8)
    }

    /// Projects under the root that have a manifest.
    public static func all(root: String = Monitor.projectsRoot()) -> [(dir: URL, manifest: ProjectManifest)] {
        var out: [(URL, ProjectManifest)] = []
        let fm = FileManager.default
        func walk(_ dir: URL, depth: Int) {
            guard depth <= 4, let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
            if names.contains(fileName),
               let text = try? String(contentsOf: dir.appendingPathComponent(fileName), encoding: .utf8),
               let manifest = try? YAMLDecoder().decode(ProjectManifest.self, from: text) {
                out.append((dir, manifest))
            }
            for name in names where !name.hasPrefix(".") && !Doctor.skippedDirs.contains(name) {
                var isDir: ObjCBool = false
                let url = dir.appendingPathComponent(name)
                if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { walk(url, depth: depth + 1) }
            }
        }
        walk(URL(fileURLWithPath: root), depth: 0)
        return out.sorted { $0.0.path < $1.0.path }
    }

    /// Environment per source, for running practices in this project's context.
    public var envs: [String: String] {
        Dictionary(sources.compactMap { ref in ref.env.map { (ref.source, $0) } }, uniquingKeysWith: { a, _ in a })
    }

    public static let fileName = "practices.yaml"

    /// The manifest of the project `directory` is in: the nearest `practices.yaml` upwards.
    public static func find(from directory: URL) -> (url: URL, manifest: ProjectManifest)? {
        var dir = directory.standardizedFileURL
        while dir.path != "/" {
            let candidate = dir.appendingPathComponent(fileName)
            if let text = try? String(contentsOf: candidate, encoding: .utf8),
               let manifest = try? YAMLDecoder().decode(ProjectManifest.self, from: text) {
                return (candidate, manifest)
            }
            dir.deleteLastPathComponent()
        }
        return nil
    }
}

/// `source@env`; without `@env` the source's first environment.
public struct SourceRef: Codable, Hashable, Sendable, CustomStringConvertible {
    public var source: String
    public var env: String?

    public init(source: String, env: String? = nil) { self.source = source; self.env = env }

    public init(parsing text: String) {
        let parts = text.split(separator: "@", maxSplits: 1).map(String.init)
        self.init(source: parts[0], env: parts.count > 1 ? parts[1] : nil)
    }

    public init(from decoder: Decoder) throws {
        self.init(parsing: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }

    public var description: String { env.map { "\(source)@\($0)" } ?? source }
}
