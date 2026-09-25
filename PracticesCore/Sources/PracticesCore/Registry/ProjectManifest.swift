import Foundation
import Yams

/// `practices.yaml` at a project's root, committed with the project: which sources it uses and
/// in which environment (DECISIONS 19). References only, no values.
///
///     sources:
///       - xkeeper-pg@prod
///       - kafka@dev
public struct ProjectManifest: Codable, Hashable, Sendable {
    public var sources: [SourceRef]

    public init(sources: [SourceRef]) { self.sources = sources }

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
