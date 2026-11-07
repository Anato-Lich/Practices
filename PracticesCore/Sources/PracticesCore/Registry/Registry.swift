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
    public static var secrets: URL { url.appendingPathComponent("secrets.json") }
}

/// `local.yaml`, optional: what is true on this machine only and so is not in any space.
///
///     spaces: {x-keeper: ~/Projects/x-keeper-space}    # a space's repository kept elsewhere
///     roots: [~/Projects, ~/Work]                       # where clones are looked for
///     folders: {export_engine: ~/Projects/export_engine}   # code without git, by folder name
public struct LocalConfig: Codable, Sendable {
    public var spaces: [String: String] = [:]
    public var roots: [String] = []
    public var folders: [String: String] = [:]

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        spaces = try c.decodeIfPresent([String: String].self, forKey: .spaces) ?? [:]
        roots = try c.decodeIfPresent([String].self, forKey: .roots) ?? []
        folders = try c.decodeIfPresent([String: String].self, forKey: .folders) ?? [:]
    }

    static func load(_ url: URL) -> LocalConfig {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return LocalConfig() }
        return (try? YAMLDecoder().decode(LocalConfig.self, from: text)) ?? LocalConfig()
    }

    static func expand(_ path: String) -> String { (path as NSString).expandingTildeInPath }
}

/// An uncommitted change in a space: what an agent wrote and the user has not accepted yet
/// (DECISIONS 19).
public struct Pending: Codable, Hashable, Sendable {
    public let space: String
    /// Relative to the space's root.
    public let path: String
    public let state: String                // new | modified | deleted
}

/// The registry: every space under `~/.practices/spaces/` (or where `local.yaml` says), each a
/// git repository of its own:
///
///     <space>/space.yaml, conditions.yaml
///     <space>/projects/<project>/project.yaml, chains/<name>.py
///     <space>/projects/<project>/services/<service>/{service.yaml, links.yaml, notes.md,
///                                                    fields.yaml, docs.yaml, practices/<name>.py}
///
/// Ids of services, projects and conditions are unique across spaces (DECISIONS 7): the path
/// is for display. No values ever land here.
public struct Registry: Sendable {
    public let root: URL
    public let local: LocalConfig

    public init(home: URL = PracticesHome.url) {
        root = home.appendingPathComponent("spaces")
        local = LocalConfig.load(home.appendingPathComponent("local.yaml"))
    }

    public struct Failure: Error, CustomStringConvertible, Sendable {
        public let description: String
        public init(_ description: String) { self.description = description }
    }

    /// Ids become directory names and parts of practice references.
    public static func isValidID(_ id: String) -> Bool {
        id.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil
    }

    public static var projectsRoot: String { NSHomeDirectory() + "/Projects" }

    /// Where clones of repositories are looked for.
    public var searchRoots: [String] {
        local.roots.isEmpty ? [Registry.projectsRoot] : local.roots.map(LocalConfig.expand)
    }

    // MARK: Spaces

    public func dir(ofSpace id: String) -> URL {
        local.spaces[id].map { URL(fileURLWithPath: LocalConfig.expand($0)).standardizedFileURL } ?? root.appendingPathComponent(id)
    }

    public func spaceIDs() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return Set(names + local.spaces.keys).filter { exists(dir(ofSpace: $0).appendingPathComponent("space.yaml")) }.sorted()
    }

    public func spaces() throws -> [Space] { try spaceIDs().map(space) }

    public func space(_ id: String) throws -> Space {
        guard spaceIDs().contains(id) else { throw Failure("no space \(id)") }
        var space = try read(Space.self, dir(ofSpace: id).appendingPathComponent("space.yaml"))
        space.id = id
        return space
    }

    // MARK: Projects

    func projectDirs() -> [(space: String, id: String, url: URL)] {
        spaceIDs().flatMap { space in
            let projects = dir(ofSpace: space).appendingPathComponent("projects")
            return subdirectories(of: projects, holding: "project.yaml").map { (space, $0, projects.appendingPathComponent($0)) }
        }
    }

    public func dir(ofProject id: String) -> URL? { projectDirs().first { $0.id == id }?.url }

    public func projects(space: String? = nil) throws -> [Project] {
        try projectDirs().filter { space == nil || $0.space == space }.map(load)
    }

    public func project(_ id: String) throws -> Project {
        guard let place = projectDirs().first(where: { $0.id == id }) else { throw Failure("no project \(id)") }
        return try load(place)
    }

    private func load(_ place: (space: String, id: String, url: URL)) throws -> Project {
        var project = try read(Project.self, place.url.appendingPathComponent("project.yaml"))
        project.id = place.id
        project.space = place.space
        return project
    }

    /// Projects in tree order — a parent, then its children, each level by id — with their
    /// depth. A project whose parent is missing (or is in a cycle written by hand) is shown at
    /// the top rather than lost.
    public static func tree(_ projects: [Project]) -> [(project: Project, depth: Int)] {
        let sorted = projects.sorted { ($0.space, $0.id) < ($1.space, $1.id) }   // a space's projects together
        let ids = Set(projects.map(\.id))
        var out: [(project: Project, depth: Int)] = []
        func add(under parent: String?, depth: Int) {
            for project in sorted where parent == nil ? !ids.contains(project.parent ?? "") : project.parent == parent {
                out.append((project, depth))
                add(under: project.id, depth: depth + 1)
            }
        }
        add(under: nil, depth: 0)
        return out + sorted.filter { p in !out.contains { $0.project.id == p.id } }.map { ($0, 0) }
    }

    /// A project with its ancestors, outermost first: the display path (DECISIONS 23).
    public func path(ofProject id: String) -> [String] {
        var path = [id]
        while let parent = (try? project(path[0]))?.parent, !path.contains(parent) { path.insert(parent, at: 0) }
        return path
    }

    /// A parent is a project of the same space and never the project's own descendant.
    private func checkParent(of project: Project) throws {
        var seen = [project.id]
        var next = project.parent
        while let id = next {
            guard !seen.contains(id) else { throw Failure("\(project.id) under \(project.parent!) would be a cycle: " + (seen + [id]).joined(separator: " → ")) }
            guard let parent = try? self.project(id) else { throw Failure("no project \(id) to be the parent of \(project.id)") }
            guard parent.space == project.space else { throw Failure("parent \(id) is in space \(parent.space), \(project.id) in \(project.space)") }
            seen.append(id)
            next = parent.parent
        }
    }

    // MARK: Services

    func serviceDirs() -> [(space: String, project: String, id: String, url: URL)] {
        projectDirs().flatMap { project in
            let services = project.url.appendingPathComponent("services")
            return subdirectories(of: services, holding: "service.yaml").map { (project.space, project.id, $0, services.appendingPathComponent($0)) }
        }
    }

    /// The folder of a service's card, wherever it is; nil when no space has the service.
    public func dir(of id: String) -> URL? { serviceDirs().first { $0.id == id }?.url }

    public func serviceIDs() -> [String] { serviceDirs().map(\.id).sorted() }

    public func services(project: String? = nil) throws -> [Service] {
        try serviceDirs().filter { project == nil || $0.project == project }.map(load).sorted { $0.id < $1.id }
    }

    public func service(_ id: String) throws -> Service {
        guard let place = serviceDirs().first(where: { $0.id == id }) else { throw Failure("no service \(id)") }
        return try load(place)
    }

    private func load(_ place: (space: String, project: String, id: String, url: URL)) throws -> Service {
        var service = try read(Service.self, place.url.appendingPathComponent("service.yaml"))
        // The directory is what references resolve by, so it is the id.
        service.id = place.id
        service.space = place.space
        service.project = place.project
        return service
    }

    public func notes(of id: String) -> String? {
        dir(of: id).flatMap { try? String(contentsOf: $0.appendingPathComponent("notes.md"), encoding: .utf8) }
    }

    public func docs(of id: String) -> [ServiceDoc] { list(ServiceDoc.self, "docs.yaml", of: id) }

    public func fields(of id: String) -> [FieldDoc] { list(FieldDoc.self, "fields.yaml", of: id) }

    /// Outgoing links: whom this service calls.
    public func links(of id: String) -> [Link] { list(Link.self, "links.yaml", of: id) }

    /// Incoming links, computed from the callers' files.
    public func links(to id: String) -> [(from: String, link: Link)] {
        serviceIDs().flatMap { from in links(of: from).filter { $0.to == id }.map { (from, $0) } }
    }

    // MARK: Conditions

    public func conditions(space: String) -> [Condition] {
        guard let text = try? String(contentsOf: dir(ofSpace: space).appendingPathComponent("conditions.yaml"), encoding: .utf8) else { return [] }
        return (try? YAMLDecoder().decode([Condition].self, from: text)) ?? []
    }

    public func condition(_ id: String) -> Condition? {
        spaceIDs().lazy.flatMap { conditions(space: $0) }.first { $0.id == id }
    }

    // MARK: Repositories

    /// Every repository that is in a project, with the project.
    public func assigned() throws -> [RepoID: String] {
        var out: [RepoID: String] = [:]
        for project in try projects() { for repo in project.repos { out[repo.repo] = project.id } }
        return out
    }

    /// Puts a repository into a project. A repository is in one project (DECISIONS 2), so one
    /// that is already somewhere else is refused rather than moved.
    public func assign(_ repo: RepoID, to id: String, role: String? = nil) async throws {
        var project = try project(id)
        if let other = try assigned()[repo], other != id {
            throw Failure("\(repo) is in project \(other) — `unassign` it there first")
        }
        project.repos.removeAll { $0.repo == repo }
        project.repos.append(.init(repo: repo, role: role))
        try await commit("\(id): \(repo)" + (role.map { " as \($0)" } ?? ""), [try save(project)])
    }

    /// Takes a repository out of its project; returns the project it was in.
    @discardableResult
    public func unassign(_ repo: RepoID) async throws -> String? {
        guard let id = try assigned()[repo] else { return nil }
        var project = try project(id)
        project.repos.removeAll { $0.repo == repo }
        try await commit("\(id): without \(repo)", [try save(project)])
        return id
    }

    /// Adds a repository to a space's `ignore` list, or takes it off.
    public func ignore(_ repo: RepoID, in id: String, _ ignored: Bool = true) async throws {
        var space = try space(id)
        space.ignore.removeAll { $0 == repo }
        if ignored { space.ignore.append(repo) }
        let file = dir(ofSpace: id).appendingPathComponent("space.yaml")
        try write(Self.yaml(space), to: file)
        try await commit("\(ignored ? "Ignore" : "Stop ignoring") \(repo)", [file])
    }

    // MARK: Creating

    /// A new space: its directory, its git repository and `space.yaml`.
    public func add(_ space: Space) async throws {
        guard Self.isValidID(space.id) else { throw Failure("not an id: \(space.id)") }
        guard !spaceIDs().contains(space.id) else { throw Failure("space \(space.id) exists") }
        let file = dir(ofSpace: space.id).appendingPathComponent("space.yaml")
        try write(Self.yaml(space), to: file)
        // Finder leaves `.DS_Store` in every folder it shows; it is nobody's pending change.
        let ignore = try write(".DS_Store\n", to: dir(ofSpace: space.id).appendingPathComponent(".gitignore"))
        try await commit("Space \(space.name)", [file, ignore])
    }

    public func add(_ project: Project) async throws {
        guard Self.isValidID(project.id) else { throw Failure("not an id: \(project.id)") }
        guard spaceIDs().contains(project.space) else { throw Failure("no space \(project.space)") }
        if let existing = projectDirs().first(where: { $0.id == project.id }) {
            throw Failure("project \(project.id) exists in space \(existing.space)")
        }
        try checkParent(of: project)
        let file = dir(ofSpace: project.space).appendingPathComponent("projects/\(project.id)/project.yaml")
        try write(Self.yaml(project), to: file)
        try await commit("Project \(project.id)", [file])
    }

    public func add(_ service: Service, to project: String) async throws {
        try await commit("Service \(service.id)", [try draft(service, in: project)])
    }

    /// A new service's card, written and returned uncommitted: the scanner's candidate waits
    /// for the user (DECISIONS 19).
    public func draft(_ service: Service, in project: String) throws -> URL {
        guard Self.isValidID(service.id) else { throw Failure("not an id: \(service.id)") }
        guard let dir = dir(ofProject: project) else { throw Failure("no project \(project)") }
        if let existing = serviceDirs().first(where: { $0.id == service.id }) {
            throw Failure("service \(service.id) exists in \(existing.space)/\(existing.project) — one service, one card")
        }
        return try write(Self.yaml(service), to: dir.appendingPathComponent("services/\(service.id)/service.yaml"))
    }

    public func add(_ condition: Condition, to space: String) async throws {
        guard Self.isValidID(condition.id) else { throw Failure("not an id: \(condition.id)") }
        guard spaceIDs().contains(space) else { throw Failure("no space \(space)") }
        guard self.condition(condition.id) == nil else { throw Failure("condition \(condition.id) exists") }
        let file = dir(ofSpace: space).appendingPathComponent("conditions.yaml")
        try write(Self.yaml(conditions(space: space) + [condition]), to: file)
        try await commit("Condition \(condition.id)", [file])
    }

    /// Adds a link to the caller's `links.yaml` and returns the file, uncommitted: an agent's
    /// link waits for the user (DECISIONS 19), the CLI commits it itself.
    public func addLink(_ link: Link, from: String) throws -> URL {
        let target = try service(link.to)
        if let endpoint = link.endpoint, !target.endpoints.contains(where: { $0.id == endpoint }) {
            throw Failure("\(link.to) has no endpoint \(endpoint); it has " + target.endpoints.map(\.id).joined(separator: ", "))
        }
        if let via = link.via, !Link.vias.contains(via) { throw Failure("via is one of " + Link.vias.joined(separator: ", ")) }
        if let access = link.access, !Link.accesses.contains(access) { throw Failure("access is one of " + Link.accesses.joined(separator: ", ")) }
        let existing = links(of: from)
        return try saveLinks(existing.contains(link) ? existing : existing + [link], of: from)
    }

    // MARK: Writing

    // Each returns the file it wrote, for `commit`.

    @discardableResult
    public func save(_ project: Project) throws -> URL {
        guard let dir = dir(ofProject: project.id) else { throw Failure("no project \(project.id)") }
        try checkParent(of: project)
        return try write(Self.yaml(project), to: dir.appendingPathComponent("project.yaml"))
    }

    @discardableResult
    public func save(_ service: Service) throws -> URL {
        try write(Self.yaml(service), to: file("service.yaml", of: service.id))
    }

    @discardableResult
    public func saveNotes(_ text: String, of id: String) throws -> URL {
        try write(text, to: file("notes.md", of: id))
    }

    @discardableResult
    public func saveDocs(_ docs: [ServiceDoc], of id: String) throws -> URL {
        try write(Self.yaml(docs), to: file("docs.yaml", of: id))
    }

    @discardableResult
    public func saveFields(_ fields: [FieldDoc], of id: String) throws -> URL {
        try write(Self.yaml(fields), to: file("fields.yaml", of: id))
    }

    @discardableResult
    public func saveLinks(_ links: [Link], of id: String) throws -> URL {
        try write(Self.yaml(links), to: file("links.yaml", of: id))
    }

    /// YAML a person reads: Cyrillic as is, not `П…` escapes.
    public static func yaml<T: Encodable>(_ value: T) throws -> String {
        let encoder = YAMLEncoder()
        encoder.options.allowUnicode = true
        encoder.options.width = -1
        return try encoder.encode(value)
    }

    private func file(_ name: String, of id: String) throws -> URL {
        guard let dir = dir(of: id) else { throw Failure("no service \(id)") }
        return dir.appendingPathComponent(name)
    }

    private func read<T: Decodable>(_ type: T.Type, _ url: URL) throws -> T {
        try YAMLDecoder().decode(type, from: String(contentsOf: url, encoding: .utf8))
    }

    private func list<T: Decodable>(_ type: T.Type, _ name: String, of id: String) -> [T] {
        guard let url = dir(of: id)?.appendingPathComponent(name) else { return [] }
        return (try? read([T].self, url)) ?? []
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private func subdirectories(of dir: URL, holding file: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { exists(dir.appendingPathComponent($0).appendingPathComponent(file)) }.sorted()
    }

    @discardableResult
    private func write(_ text: String, to url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: Git

    /// The space a file is in and the file's path inside it.
    func place(of file: URL) -> (root: URL, path: String)? {
        let path = file.standardizedFileURL.path
        for id in spaceIDs() {
            let root = dir(ofSpace: id).standardizedFileURL
            if path.hasPrefix(root.path + "/") { return (root, String(path.dropFirst(root.path.count + 1))) }
        }
        return nil
    }

    /// Creates the repository on first use. The author is local to it so the user's global
    /// identity is not needed and not touched.
    func ensureRepository(_ root: URL) async throws {
        guard !exists(root.appendingPathComponent(".git")) else { return }
        _ = try await git(root, ["init", "-q"])
        _ = try await git(root, ["config", "user.name", "Practices"])
        _ = try await git(root, ["config", "user.email", "practices@localhost"])
    }

    /// Commits these files and nothing else; returns false when none of them changed. Never
    /// `git add -A`: an agent's edits to practices and links lie in the same repository
    /// uncommitted, waiting for the user, and must not ride along (DECISIONS 19).
    @discardableResult
    public func commit(_ message: String, _ files: [URL]) async throws -> Bool {
        var byRoot: [URL: [String]] = [:]
        for file in files {
            guard let place = place(of: file) else { throw Failure("\(file.path) is not in a space") }
            byRoot[place.root, default: []].append(place.path)
        }
        var committed = false
        for (root, paths) in byRoot {
            try await ensureRepository(root)
            _ = try await git(root, ["add", "--"] + paths)
            guard !(try await git(root, ["status", "--porcelain", "--"] + paths)).isEmpty else { continue }
            _ = try await git(root, ["commit", "-q", "-m", message, "--"] + paths)
            committed = true
        }
        return committed
    }

    func git(_ root: URL, _ args: [String]) async throws -> String {
        try await Shell.run("git", ["-C", root.path] + args)
    }

    /// Uncommitted changes of every space, file by file.
    public func pending() async -> [Pending] {
        var out: [Pending] = []
        for id in spaceIDs() {
            let root = dir(ofSpace: id)
            guard exists(root.appendingPathComponent(".git")),
                  let status = try? await git(root, ["-c", "core.quotePath=false", "status", "--porcelain", "-uall", "--no-renames"])
            else { continue }
            for line in status.split(separator: "\n") where line.count > 3 {
                let code = line.prefix(2)
                let path = line.dropFirst(3).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                out.append(Pending(space: id, path: path, state: code == "??" ? "new" : code.contains("D") ? "deleted" : "modified"))
            }
        }
        return out
    }

    /// What accepting a pending change would commit: the file itself when it is new, its diff
    /// otherwise.
    public func diff(of change: Pending) async -> String {
        let root = dir(ofSpace: change.space)
        if change.state == "new" { return (try? String(contentsOf: root.appendingPathComponent(change.path), encoding: .utf8)) ?? "" }
        return (try? await git(root, ["diff", "HEAD", "--", change.path])) ?? ""
    }

    /// Commits pending changes — all of them, or those of one space, or the given paths of it.
    /// Returns what was accepted.
    @discardableResult
    public func accept(space: String? = nil, paths: [String] = [], message: String? = nil) async throws -> [Pending] {
        let chosen = await pending().filter { (space == nil || $0.space == space) && (paths.isEmpty || paths.contains($0.path)) }
        for (id, changes) in Dictionary(grouping: chosen, by: \.space) {
            let files = changes.map { dir(ofSpace: id).appendingPathComponent($0.path) }
            try await commit(message ?? "Accepted: " + changes.map(\.path).joined(separator: ", "), files)
        }
        return chosen
    }
}
