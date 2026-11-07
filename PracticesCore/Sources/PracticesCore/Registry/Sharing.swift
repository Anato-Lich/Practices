import Foundation

/// A space as `spaces` shows it: where its repository is shared and how far this copy is from it.
public struct SpaceState: Codable, Sendable {
    public let id: String
    public let name: String
    /// `origin`; nil — the space is on this machine only.
    public let remote: String?
    public let git: GitState?
}

/// Decision 36: spaces are shared through git, roots stay in `local.yaml` on this machine.
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

    // MARK: Remotes

    // A space without `.git` must not answer with the state of a repository above it.
    private func isRepository(_ dir: URL) -> Bool { FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) }

    public func remote(ofSpace id: String) async -> String? {
        guard isRepository(dir(ofSpace: id)) else { return nil }
        return (try? await git(dir(ofSpace: id), ["remote", "get-url", "origin"]))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Every space with its remote and git state; `fetch` asks the remotes first (network).
    public func spaceStates(fetch: Bool = false) async throws -> [SpaceState] {
        var out: [SpaceState] = []
        for space in try spaces() {
            let dir = dir(ofSpace: space.id)
            let remote = await remote(ofSpace: space.id)
            if fetch, remote != nil { _ = try await git(dir, ["fetch", "-q", "origin"]) }
            out.append(SpaceState(id: space.id, name: space.name, remote: remote, git: isRepository(dir) ? await Repos.gitState(ofClone: dir.path) : nil))
        }
        return out
    }

    private func existingSpace(_ id: String) throws -> URL {
        guard spaceIDs().contains(id) else { throw Failure("no space \(id)") }
        return dir(ofSpace: id)
    }

    public func setRemote(ofSpace id: String, to url: String) async throws {
        let dir = try existingSpace(id)
        try await ensureRepository(dir)
        let verb = await remote(ofSpace: id) == nil ? "add" : "set-url"
        _ = try await git(dir, ["remote", verb, "origin", url])
    }

    private func requireRemote(_ id: String) async throws {
        guard await remote(ofSpace: id) != nil else { throw Failure("space \(id) has no remote — `practicesctl space remote \(id) <url>`") }
    }

    public func push(space id: String) async throws {
        let dir = try existingSpace(id)
        try await requireRemote(id)
        _ = try await git(dir, ["push", "-q", "-u", "origin", "HEAD"])
    }

    /// Fast-forward only, and never over uncommitted files: those are an agent's edits waiting
    /// for the user (DECISIONS 19).
    public func pull(space id: String) async throws {
        let dir = try existingSpace(id)
        try await requireRemote(id)
        let waiting = await pending().filter { $0.space == id }
        guard waiting.isEmpty else {
            throw Failure("space \(id) has \(waiting.count) uncommitted files (pending edits) — accept or discard them first (`practicesctl pending`)")
        }
        _ = try await git(dir, ["pull", "-q", "--ff-only"])
    }

    /// Clones a shared space into `spaces/<id>`; returns the id.
    @discardableResult
    public func clone(space url: String, as given: String? = nil) async throws -> String {
        var name = url.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        name = String(name.split(whereSeparator: { $0 == "/" || $0 == ":" }).last ?? "")
        if name.hasSuffix(".git") { name = String(name.dropLast(4)) }
        let id = given ?? name
        guard Self.isValidID(id) else { throw Failure("not an id: \(id) — give one: space clone <url> <id>") }
        let dest = root.appendingPathComponent(id)
        guard !FileManager.default.fileExists(atPath: dest.path), !spaceIDs().contains(id) else { throw Failure("space \(id) exists: \(dest.path)") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try await Shell.run("git", ["clone", "-q", url, dest.path])
        guard FileManager.default.fileExists(atPath: dest.appendingPathComponent("space.yaml").path) else {
            try? FileManager.default.removeItem(at: dest)
            throw Failure("\(url) has no space.yaml — not a Practices space; the clone is removed")
        }
        // Same local author as a space made here, so `accept` works without a global identity.
        _ = try await git(dest, ["config", "user.name", "Practices"])
        _ = try await git(dest, ["config", "user.email", "practices@localhost"])
        return id
    }
}
