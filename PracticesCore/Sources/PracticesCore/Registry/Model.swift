import Foundation

/// A repository, known by its remote address and not by a folder (DECISIONS 4): `host/path` in
/// lower case, without protocol, user, port or `.git`. `git@host:a/b.git`, `https://host/a/b`
/// and `ssh://git@host/a/b.git` are one repository.
public struct RepoID: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    public let description: String

    public init?(_ remote: String) {
        var text = remote.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let scheme = text.range(of: "://")
        if let scheme { text = String(text[scheme.upperBound...]) }
        // Without a scheme, `host:path` is the scp form and the colon ends the host.
        guard let cut = text.firstIndex(where: { $0 == "/" || (scheme == nil && $0 == ":") }) else { return nil }
        var host = text[..<cut]
        if let at = host.lastIndex(of: "@") { host = host[host.index(after: at)...] }
        if let port = host.firstIndex(of: ":") { host = host[..<port] }
        var path = text[text.index(after: cut)...].trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.hasSuffix(".git") { path.removeLast(4) }
        guard !host.isEmpty, !path.isEmpty, !(host + path).contains(where: \.isWhitespace) else { return nil }
        description = "\(host)/\(path)"
    }

    /// The address to clone from.
    public var sshURL: String {
        let slash = description.firstIndex(of: "/")!
        return "git@\(description[..<slash]):\(description[description.index(after: slash)...]).git"
    }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let id = RepoID(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a repository address: \(text)"))
        }
        self = id
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }

    public static func < (a: RepoID, b: RepoID) -> Bool { a.description < b.description }
}

/// A space: the boundary of an organisation and of access (X-Keeper, SphereTele). One git
/// repository, `space.yaml` at its root (DECISIONS 6).
public struct Space: Codable, Identifiable, Hashable, Sendable {
    /// The name of the space's directory; not written to yaml.
    public var id = ""
    public var name: String
    /// Where its repositories are looked for: GitHub organisations, GitLab groups.
    public var hosting: [Hosting]
    /// Repositories not to offer in «Не распределено» (archived, empty, not ours).
    public var ignore: [RepoID]

    public struct Hosting: Codable, Hashable, Sendable {
        public var host: String
        public var owner: String
        public init(host: String, owner: String) { self.host = host; self.owner = owner }
    }

    public init(id: String, name: String, hosting: [Hosting] = [], ignore: [RepoID] = []) {
        self.id = id; self.name = name; self.hosting = hosting; self.ignore = ignore
    }

    enum CodingKeys: String, CodingKey { case name, hosting, ignore }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        hosting = try c.decodeIfPresent([Hosting].self, forKey: .hosting) ?? []
        ignore = try c.decodeIfPresent([RepoID].self, forKey: .ignore) ?? []
    }
}

/// A project: repositories with a common goal, `projects/<id>/project.yaml`. A repository is
/// in one project, a project in one space (DECISIONS 2); the id is unique across spaces.
/// Projects nest through `parent` while their folders stay flat (DECISIONS 23): moving a
/// project under another parent changes no path.
public struct Project: Codable, Identifiable, Hashable, Sendable {
    /// The name of the project's directory and the space it is in; not written to yaml.
    public var id = ""
    public var space = ""
    public var name: String
    /// The project this one is inside (`x-factory` for `scada`); same space.
    public var parent: String?
    public var description: String?
    public var repos: [Repo]
    /// Code without git, by folder name; where the folder is on this machine — `local.yaml`.
    public var folders: [Folder]

    public struct Repo: Codable, Hashable, Sendable {
        public var repo: RepoID
        public var role: String?            // frontend, backend, infra, docs…
        public init(repo: RepoID, role: String? = nil) { self.repo = repo; self.role = role }
    }

    public struct Folder: Codable, Hashable, Sendable {
        public var name: String
        public init(name: String) { self.name = name }
    }

    public init(id: String, space: String, name: String, parent: String? = nil, description: String? = nil,
                repos: [Repo] = [], folders: [Folder] = []) {
        self.id = id; self.space = space; self.name = name; self.parent = parent; self.description = description
        self.repos = repos; self.folders = folders
    }

    enum CodingKeys: String, CodingKey { case name, parent, description, repos, folders }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        parent = try c.decodeIfPresent(String.self, forKey: .parent)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        repos = try c.decodeIfPresent([Repo].self, forKey: .repos) ?? []
        folders = try c.decodeIfPresent([Folder].self, forKey: .folders) ?? []
    }
}

/// A named condition ("needs the corporate network"), one entry of a space's `conditions.yaml`.
/// Declared once, services and endpoints refer to it by id (DECISIONS 11).
public struct Condition: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    /// What to tell the user or the agent: "Включите WireGuard-туннель".
    public var hint: String?
    /// `host:port` template over the keys of the service that refers to the condition. Without
    /// it the condition is declared knowledge and is not checked.
    public var reachable: String?

    public init(id: String, name: String, hint: String? = nil, reachable: String? = nil) {
        self.id = id; self.name = name; self.hint = hint; self.reachable = reachable
    }
}

/// "I call that service, this way and for this reason": one entry of the caller's `links.yaml`
/// (DECISIONS 9, 12). The reverse side is computed.
public struct Link: Codable, Hashable, Sendable {
    public static let vias = ["http", "topic", "db", "network", "build"]
    public static let accesses = ["read", "write"]

    public var to: String
    public var endpoint: String?
    public var env: String?
    public var via: String?
    public var what: String?                // a topic, a table, a path
    public var access: String?
    public var why: String?
    public var practice: String?
    /// The caller's variable → the service's key.
    public var names: [String: String]?
    /// The env file in the caller's repository that holds them.
    public var file: String?
    /// `manual`, or `derived:<the file it was derived from>`.
    public var origin: String?

    public init(to: String, endpoint: String? = nil, env: String? = nil, via: String? = nil, what: String? = nil,
                access: String? = nil, why: String? = nil, practice: String? = nil, names: [String: String]? = nil,
                file: String? = nil, origin: String? = "manual") {
        self.to = to; self.endpoint = endpoint; self.env = env; self.via = via; self.what = what
        self.access = access; self.why = why; self.practice = practice; self.names = names
        self.file = file; self.origin = origin
    }
}
