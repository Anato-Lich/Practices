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
public struct ProjectManifest: Codable, Hashable, Sendable {
    public var sources: [SourceRef]
    /// Project variable → registry key; set in addition to the registry's own names.
    public var env: [String: String]

    public init(sources: [SourceRef], env: [String: String] = [:]) { self.sources = sources; self.env = env }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sources = try c.decodeIfPresent([SourceRef].self, forKey: .sources) ?? []
        env = try c.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
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
