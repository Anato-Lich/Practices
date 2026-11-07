import Foundation

/// A space as `spaces` shows it: its local git repository (history, accepted edits). The
/// catalogue is personal — spaces have no remote (DECISIONS 36).
public struct SpaceState: Codable, Sendable {
    public let id: String
    public let name: String
    public let path: String
    /// nil — detached HEAD, or not a git repository.
    public let branch: String?
    /// nil — not a git repository.
    public let uncommitted: Int?
}

/// Decision 36: roots stay in `local.yaml` on this machine.
extension Registry {

    /// The `~/.practices` this registry was opened at.
    public var home: URL { root.deletingLastPathComponent() }

    // MARK: Roots

    private static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: LocalConfig.expand(path)).standardizedFileURL.path
    }

    /// Adds a folder where clones are looked for; returns it as written (`~/…`).
    @discardableResult
    public func addRoot(_ path: String) throws -> String {
        let full = Self.normalized(path)
        guard full != "/", full != Self.normalized(NSHomeDirectory()) else {
            throw Failure("укажите папки с проектами, не весь диск")
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue else {
            throw Failure("not a directory: \(full)")
        }
        guard !local.roots.map(Self.normalized).contains(full) else { throw Failure("already a root: \(full)") }
        var config = local
        let stored = (full as NSString).abbreviatingWithTildeInPath
        config.roots.append(stored)
        try config.save(home.appendingPathComponent("local.yaml"))
        return stored
    }

    public func removeRoot(_ path: String) throws {
        let full = Self.normalized(path)
        var config = local
        guard config.roots.contains(where: { Self.normalized($0) == full }) else { throw Failure("not a root: \(full)") }
        config.roots.removeAll { Self.normalized($0) == full }
        try config.save(home.appendingPathComponent("local.yaml"))
    }

    // MARK: Spaces

    /// Every space with the state of its repository.
    public func spaceStates() async throws -> [SpaceState] {
        var out: [SpaceState] = []
        for space in try spaces() {
            let dir = dir(ofSpace: space.id)
            // A space without `.git` must not answer with the state of a repository above it.
            let git = FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) ? await Repos.gitState(ofClone: dir.path) : nil
            out.append(SpaceState(id: space.id, name: space.name, path: dir.path, branch: git?.branch, uncommitted: git?.uncommitted))
        }
        return out
    }
}
