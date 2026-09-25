import Foundation
import Yams

/// Where Practices keeps the user's data (DECISIONS 11). `PRACTICES_HOME` overrides it, which
/// is how tests and dry runs stay away from the real one.
public enum PracticesHome {
    public static var url: URL {
        if let override = ProcessInfo.processInfo.environment["PRACTICES_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".practices")
    }
    public static var registry: URL { url.appendingPathComponent("registry") }
    public static var secrets: URL { url.appendingPathComponent("secrets.json") }
}

/// The registry: `registry/sources/<id>/{source.yaml, notes.md, docs.yaml, docs/, fields.yaml}`
/// in a local git repository without a remote (PLAN, «Git — только для реестра»). No values
/// ever land here.
public struct Registry: Sendable {
    public let root: URL

    public init(root: URL = PracticesHome.registry) { self.root = root }

    var sourcesDir: URL { root.appendingPathComponent("sources") }
    public func dir(of id: String) -> URL { sourcesDir.appendingPathComponent(id) }

    public func sourceIDs() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: sourcesDir.path)) ?? []
        return names.filter {
            FileManager.default.fileExists(atPath: dir(of: $0).appendingPathComponent("source.yaml").path)
        }.sorted()
    }

    public func sources() throws -> [Source] {
        try sourceIDs().map { try source($0) }
    }

    public func source(_ id: String) throws -> Source {
        let text = try String(contentsOf: dir(of: id).appendingPathComponent("source.yaml"), encoding: .utf8)
        return try YAMLDecoder().decode(Source.self, from: text)
    }

    public func notes(of id: String) -> String? {
        try? String(contentsOf: dir(of: id).appendingPathComponent("notes.md"), encoding: .utf8)
    }

    public func docs(of id: String) -> [SourceDoc] {
        guard let text = try? String(contentsOf: dir(of: id).appendingPathComponent("docs.yaml"), encoding: .utf8)
        else { return [] }
        return (try? YAMLDecoder().decode([SourceDoc].self, from: text)) ?? []
    }

    public func fields(of id: String) -> [FieldDoc] {
        guard let text = try? String(contentsOf: dir(of: id).appendingPathComponent("fields.yaml"), encoding: .utf8)
        else { return [] }
        return (try? YAMLDecoder().decode([FieldDoc].self, from: text)) ?? []
    }

    // MARK: Writing

    public func save(_ source: Source) throws {
        try write(Self.yaml(source), to: dir(of: source.id).appendingPathComponent("source.yaml"))
    }

    public func saveNotes(_ text: String, of id: String) throws {
        try write(text, to: dir(of: id).appendingPathComponent("notes.md"))
    }

    public func saveDocs(_ docs: [SourceDoc], of id: String) throws {
        try write(Self.yaml(docs), to: dir(of: id).appendingPathComponent("docs.yaml"))
    }

    public func saveFields(_ fields: [FieldDoc], of id: String) throws {
        try write(Self.yaml(fields), to: dir(of: id).appendingPathComponent("fields.yaml"))
    }

    /// YAML a person reads: Cyrillic as is, not `\u041F…` escapes.
    public static func yaml<T: Encodable>(_ value: T) throws -> String {
        let encoder = YAMLEncoder()
        encoder.options.allowUnicode = true
        encoder.options.width = -1
        return try encoder.encode(value)
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: Git

    /// Creates the repository on first use. The author is local to it so the user's global
    /// identity is not needed and not touched.
    public func ensureRepository() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard !FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path) else { return }
        _ = try await git(["init", "-q"])
        _ = try await git(["config", "user.name", "Practices"])
        _ = try await git(["config", "user.email", "practices@localhost"])
    }

    /// Commits everything that changed; returns false when there was nothing to commit.
    @discardableResult
    public func commit(_ message: String) async throws -> Bool {
        try await ensureRepository()
        _ = try await git(["add", "-A"])
        let status = try await git(["status", "--porcelain"])
        guard !status.isEmpty else { return false }
        _ = try await git(["commit", "-q", "-m", message])
        return true
    }

    func git(_ args: [String]) async throws -> String {
        try await Shell.run("git", ["-C", root.path] + args)
    }
}
