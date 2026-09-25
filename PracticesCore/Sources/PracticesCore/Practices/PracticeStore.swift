import Foundation
import Yams

/// A practice: `registry/sources/<source>/practices/<name>.py`, or a chain:
/// `registry/chains/<name>.py`. Its reference is `source/name` or `chains/name`.
public struct Practice: Identifiable, Hashable, Sendable, Codable {
    public let ref: String
    public var id: String { ref }
    public var isChain: Bool { ref.hasPrefix("chains/") }
    public var source: String? { isChain ? nil : String(ref.split(separator: "/")[0]) }
    public var name: String { String(ref.split(separator: "/", maxSplits: 1).last ?? "") }

    public init(ref: String) { self.ref = ref }
}

/// Parameters a practice is checked on: its own examples, or the ones an agent sent.
public struct ParamSet: Codable, Hashable, Sendable {
    public var name: String
    public var params: [String: String]
    public init(name: String, params: [String: String]) { self.name = name; self.params = params }
}

public struct PracticeVersion: Hashable, Sendable, Codable {
    public let number: Int          // 1 = first commit of the file
    public let commit: String
    public let date: Date
    public let message: String
}

/// Practices in the registry. Every save is a commit; version N is the file's Nth commit
/// (DECISIONS 31), so the version history is `git log` and nothing else.
public struct PracticeStore: Sendable {
    public let registry: Registry

    public init(registry: Registry = Registry()) { self.registry = registry }

    public func url(of practice: Practice) -> URL {
        let parts = practice.ref.split(separator: "/", maxSplits: 1).map(String.init)
        if practice.isChain { return registry.root.appendingPathComponent("chains/\(parts[1]).py") }
        return registry.dir(of: parts[0]).appendingPathComponent("practices/\(parts[1]).py")
    }

    public func all() -> [Practice] {
        var result: [Practice] = []
        for id in registry.sourceIDs() { result += list(source: id) }
        result += chains()
        return result
    }

    public func list(source id: String) -> [Practice] {
        names(in: registry.dir(of: id).appendingPathComponent("practices")).map { Practice(ref: "\(id)/\($0)") }
    }

    public func chains() -> [Practice] {
        names(in: registry.root.appendingPathComponent("chains")).map { Practice(ref: "chains/\($0)") }
    }

    private func names(in dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".py") && !$0.hasPrefix("_") }
            .map { String($0.dropLast(3)) }
            .sorted()
    }

    public func code(of practice: Practice) throws -> String {
        try String(contentsOf: url(of: practice), encoding: .utf8)
    }

    /// Writes the code and commits it; returns the new version number (nil when unchanged).
    @discardableResult
    public func save(_ code: String, for practice: Practice, message: String? = nil) async throws -> Int? {
        let file = url(of: practice)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try code.write(to: file, atomically: true, encoding: .utf8)
        let next = (try await versions(of: practice).count) + 1
        let committed = try await registry.commit(message.map { "\(practice.ref) v\(next): \($0)" } ?? "\(practice.ref) v\(next)")
        return committed ? next : nil
    }

    public func versions(of practice: Practice) async throws -> [PracticeVersion] {
        let path = url(of: practice).path.replacingOccurrences(of: registry.root.path + "/", with: "")
        guard FileManager.default.fileExists(atPath: registry.root.appendingPathComponent(".git").path) else { return [] }
        // A registry without commits yet has no history, not an error.
        guard let log = try? await registry.git(["log", "--follow", "--format=%H%x09%ct%x09%s", "--", path]) else { return [] }
        let lines = log.split(separator: "\n").reversed()
        return lines.enumerated().compactMap { i, line in
            let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard parts.count == 3, let ts = TimeInterval(parts[1]) else { return nil }
            return PracticeVersion(number: i + 1, commit: parts[0], date: Date(timeIntervalSince1970: ts), message: parts[2])
        }
    }

    // MARK: Saved parameter sets

    /// `<name>.sets.yaml` beside the practice: named parameter sets new versions are checked on.
    func setsURL(of practice: Practice) -> URL {
        url(of: practice).deletingPathExtension().appendingPathExtension("sets.yaml")
    }

    public func sets(of practice: Practice) -> [ParamSet] {
        guard let text = try? String(contentsOf: setsURL(of: practice), encoding: .utf8) else { return [] }
        return (try? YAMLDecoder().decode([ParamSet].self, from: text)) ?? []
    }

    public func saveSet(_ set: ParamSet, for practice: Practice) async throws {
        var all = sets(of: practice).filter { $0.name != set.name }
        all.append(set)
        try Registry.yaml(all).write(to: setsURL(of: practice), atomically: true, encoding: .utf8)
        try await registry.commit("\(practice.ref): parameter set \(set.name)")
    }

    /// Writes the code without committing: a draft that runs can use before it is saved as a
    /// version.
    public func writeDraft(_ code: String, for practice: Practice) throws {
        let file = url(of: practice)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try code.write(to: file, atomically: true, encoding: .utf8)
    }

    /// True when the file differs from its last version (or has none yet).
    public func isDraft(_ practice: Practice) async -> Bool {
        let path = url(of: practice).path.replacingOccurrences(of: registry.root.path + "/", with: "")
        guard let status = try? await registry.git(["status", "--porcelain", "--", path]) else { return true }
        return !status.isEmpty
    }

    /// The code of one version.
    public func code(of practice: Practice, at version: PracticeVersion) async throws -> String {
        let path = url(of: practice).path.replacingOccurrences(of: registry.root.path + "/", with: "")
        return try await registry.git(["show", "\(version.commit):\(path)"])
    }

    /// Practices a practice calls through `use("…")`, transitively.
    public func dependencies(of practice: Practice) -> [Practice] {
        var seen: [Practice] = []
        func visit(_ p: Practice) {
            guard let code = try? code(of: p) else { return }
            for ref in Self.uses(in: code) where !seen.contains(Practice(ref: ref)) && ref != practice.ref {
                seen.append(Practice(ref: ref))
                visit(Practice(ref: ref))
            }
        }
        visit(practice)
        return seen
    }

    static func uses(in code: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: #"use\(\s*["']([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)["']\s*\)"#)
        let range = NSRange(code.startIndex..., in: code)
        return pattern.matches(in: code, range: range).compactMap {
            Range($0.range(at: 1), in: code).map { String(code[$0]) }
        }
    }

    /// Sources whose values a run of this practice needs: its own and its dependencies'.
    public func sources(for practice: Practice) -> [String] {
        var ids: [String] = []
        for p in [practice] + dependencies(of: practice) {
            if let s = p.source, !ids.contains(s) { ids.append(s) }
        }
        return ids
    }

    public static func template(for practice: Practice, source: Source?) -> String {
        let keys = (source?.keys ?? []).map(\.name).prefix(4).map { "#   \($0)" }.joined(separator: "\n")
        return """
            # practices: \(practice.ref)
            import os


            def run(limit: int = 10):
                \"\"\"What this practice returns, in one sentence.\"\"\"
                env = os.environ
                # Values of the source's keys are in the environment, e.g.:
            \(keys)
                return [{"n": i} for i in range(limit)]

            """
    }
}
