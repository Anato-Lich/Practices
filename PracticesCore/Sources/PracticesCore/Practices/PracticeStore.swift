import Foundation

/// A practice: `projects/<project>/services/<service>/practices/<name>.py` in the service's
/// space — it belongs to the service it calls (DECISIONS 9) — or a chain:
/// `projects/<project>/chains/<name>.py`. Its reference is `service/name` or `chains/name`.
public struct Practice: Identifiable, Hashable, Sendable, Codable {
    public let ref: String
    public var id: String { ref }
    public var isChain: Bool { ref.hasPrefix("chains/") }
    public var service: String? { isChain ? nil : String(ref.split(separator: "/")[0]) }
    public var name: String { String(ref.split(separator: "/", maxSplits: 1).last ?? "") }

    public init(ref: String) { self.ref = ref }
}

public struct PracticeVersion: Hashable, Sendable, Codable {
    public let number: Int          // 1 = first commit of the file
    public let commit: String
    public let date: Date
    public let message: String
}

/// Practices in the registry. Version N is the file's Nth commit (DECISIONS 31), so the
/// version history is `git log` and nothing else; a file that differs from its last commit is
/// a draft — the user's own, or an agent's edit waiting to be accepted (DECISIONS 19).
public struct PracticeStore: Sendable {
    public let registry: Registry

    public init(registry: Registry = Registry()) { self.registry = registry }

    /// The practice's file. A chain that does not exist yet needs the project it will live in;
    /// nil when the service (or that project) is unknown or the name is not a file name.
    public func url(of practice: Practice, project: String? = nil) -> URL? {
        guard Registry.isValidID(practice.name) else { return nil }
        guard practice.isChain else {
            return registry.dir(of: practice.service ?? "")?.appendingPathComponent("practices/\(practice.name).py")
        }
        let file = "chains/\(practice.name).py"
        let projects = registry.projectDirs()
        if let existing = projects.map({ $0.url.appendingPathComponent(file) }).first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            return existing
        }
        return projects.first { $0.id == project }?.url.appendingPathComponent(file)
    }

    private func file(of practice: Practice, project: String? = nil) throws -> URL {
        guard let url = url(of: practice, project: project) else {
            throw Registry.Failure(practice.isChain ? "no chain \(practice.name): a new one needs its project"
                                                    : "no service for \(practice.ref)")
        }
        // `chains/<name>` is one name for all projects: a second chain would be unreachable.
        let owner = url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
        if practice.isChain, let project, project != owner {
            throw Registry.Failure("chain \(practice.name) exists in project \(owner) — a chain's name is global, pick another")
        }
        return url
    }

    public func all() -> [Practice] {
        registry.serviceIDs().flatMap { list(service: $0) } + chains()
    }

    public func list(service id: String) -> [Practice] {
        guard let dir = registry.dir(of: id) else { return [] }
        return names(in: dir.appendingPathComponent("practices")).map { Practice(ref: "\(id)/\($0)") }
    }

    public func chains(project: String? = nil) -> [Practice] {
        registry.projectDirs().filter { project == nil || $0.id == project }
            .flatMap { names(in: $0.url.appendingPathComponent("chains")) }.map { Practice(ref: "chains/\($0)") }
    }

    private func names(in dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".py") && !$0.hasPrefix("_") }
            .map { String($0.dropLast(3)) }
            .sorted()
    }

    public func code(of practice: Practice) throws -> String {
        try String(contentsOf: file(of: practice), encoding: .utf8)
    }

    /// Writes the code and commits that file alone; returns the new version number (nil when
    /// unchanged).
    @discardableResult
    public func save(_ code: String, for practice: Practice, message: String? = nil, project: String? = nil) async throws -> Int? {
        let file = try writeDraft(code, for: practice, project: project)
        let next = (try await versions(of: practice).count) + 1
        let committed = try await registry.commit(message.map { "\(practice.ref) v\(next): \($0)" } ?? "\(practice.ref) v\(next)", [file])
        return committed ? next : nil
    }

    public func versions(of practice: Practice) async throws -> [PracticeVersion] {
        guard let place = url(of: practice).flatMap(registry.place(of:)) else { return [] }
        // A space without commits yet has no history, not an error.
        // No --follow: it takes a new practice for a copy of an older, similar one (practices repeat
        // their connection code) and counts that one's commits too.
        guard let log = try? await registry.git(place.root, ["log", "--format=%H%x09%ct%x09%s", "--", place.path]) else { return [] }
        let lines = log.split(separator: "\n").reversed()
        return lines.enumerated().compactMap { i, line in
            let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard parts.count == 3, let ts = TimeInterval(parts[1]) else { return nil }
            return PracticeVersion(number: i + 1, commit: parts[0], date: Date(timeIntervalSince1970: ts), message: parts[2])
        }
    }

    /// Writes the code without committing: a draft that runs can use before it becomes a
    /// version. Returns the file.
    @discardableResult
    public func writeDraft(_ code: String, for practice: Practice, project: String? = nil) throws -> URL {
        let file = try file(of: practice, project: project)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try code.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    /// True when the file differs from its last version (or has none yet).
    public func isDraft(_ practice: Practice) async -> Bool {
        guard let place = url(of: practice).flatMap(registry.place(of:)),
              let status = try? await registry.git(place.root, ["status", "--porcelain", "--", place.path]) else { return true }
        return !status.isEmpty
    }

    /// The code of one version.
    public func code(of practice: Practice, at version: PracticeVersion) async throws -> String {
        guard let place = registry.place(of: try file(of: practice)) else { throw Registry.Failure("\(practice.ref) is not in a space") }
        return try await registry.git(place.root, ["show", "\(version.commit):\(place.path)"])
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

    /// Services whose values a run of this practice needs: its own and its dependencies'.
    public func services(for practice: Practice) -> [String] {
        var ids: [String] = []
        for p in [practice] + dependencies(of: practice) {
            if let s = p.service, !ids.contains(s) { ids.append(s) }
        }
        return ids
    }

    public static func template(for practice: Practice, service: Service?) -> String {
        let keys = (service?.keys ?? []).map(\.name).prefix(4).map { "#   \($0)" }.joined(separator: "\n")
        return """
            # practices: \(practice.ref)
            import os


            def run(limit: int = 10):
                \"\"\"What this practice returns, in one sentence.\"\"\"
                env = os.environ
                # Values of the service's keys are in the environment, e.g.:
            \(keys)
                return [{"n": i} for i in range(limit)]

            """
    }
}
