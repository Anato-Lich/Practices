import Foundation

/// A service: a compose service of a repository or an external system without one (Kafka,
/// X-Keeper Postgres, MoySklad) — what used to be a "source" (DECISIONS 5). Stored as
/// `projects/<project>/services/<id>/service.yaml` in its space; holds names of keys, never
/// their values. The id is unique across all spaces (DECISIONS 7).
public struct Service: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    /// Where the card lives — for display only; filled by the registry, not written to yaml.
    public var space = ""
    public var project = ""
    public var name: String
    public var kind: String                 // postgres, clickhouse, kafka, http, socket…
    public var description: String?
    public var tags: [String]
    /// The repository the service is built from; nil for an external service.
    public var repo: RepoID?
    /// Other names projects know it by: a compose service, a host (DECISIONS 8).
    public var aliases: [String]
    /// Environments this service exists in; each has its own set of values.
    public var envs: [String]
    public var keys: [Key]
    /// Addresses the service is reached at, as templates over the keys: `${XK_PG_HOST}`.
    public var endpoints: [Endpoint]
    /// Ids of conditions that hold for the whole service ("corp-network").
    public var requires: [String]
    /// Rules the practices of this service keep, in words (read-only, shared consumer groups).
    public var guards: [String]

    public struct Key: Codable, Hashable, Sendable {
        public var name: String
        /// Secrets are never printed and are what Doctor looks for in plain files.
        public var secret: Bool
        public var description: String?

        public init(name: String, secret: Bool? = nil, description: String? = nil) {
            self.name = name
            self.secret = secret ?? Key.looksSecret(name)
            self.description = description
        }

        public static func looksSecret(_ name: String) -> Bool {
            let upper = name.uppercased()
            return ["PASS", "TOKEN", "SECRET", "API_KEY", "CONSUMER_KEY"].contains { upper.contains($0) }
        }

        // A key is written as a bare name or as a map with details.
        public init(from decoder: Decoder) throws {
            if let name = try? decoder.singleValueContainer().decode(String.self) {
                self.init(name: name)
                return
            }
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(name: try c.decode(String.self, forKey: .name),
                      secret: try c.decodeIfPresent(Bool.self, forKey: .secret),
                      description: try c.decodeIfPresent(String.self, forKey: .description))
        }

        public func encode(to encoder: Encoder) throws {
            if description == nil && secret == Key.looksSecret(name) {
                var c = encoder.singleValueContainer()
                try c.encode(name)
                return
            }
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(name, forKey: .name)
            try c.encode(secret, forKey: .secret)
            try c.encodeIfPresent(description, forKey: .description)
        }

        enum CodingKeys: String, CodingKey { case name, secret, description }
    }

    /// Either `address` (`host:port`, checked with a TCP connect) or `url` (an HTTP request).
    public struct Endpoint: Codable, Hashable, Sendable {
        public var id: String
        public var label: String?
        public var address: String?
        public var url: String?
        /// Ids of conditions of this endpoint alone (DECISIONS 10).
        public var requires: [String]

        public init(id: String, label: String? = nil, address: String? = nil, url: String? = nil, requires: [String] = []) {
            self.id = id; self.label = label; self.address = address; self.url = url; self.requires = requires
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(id: try c.decode(String.self, forKey: .id),
                      label: try c.decodeIfPresent(String.self, forKey: .label),
                      address: try c.decodeIfPresent(String.self, forKey: .address),
                      url: try c.decodeIfPresent(String.self, forKey: .url),
                      requires: try c.decodeIfPresent([String].self, forKey: .requires) ?? [])
        }
    }

    public init(id: String, name: String, kind: String, description: String? = nil, tags: [String] = [],
                repo: RepoID? = nil, aliases: [String] = [], envs: [String] = ["prod"], keys: [Key] = [],
                endpoints: [Endpoint] = [], requires: [String] = [], guards: [String] = []) {
        self.id = id; self.name = name; self.kind = kind; self.description = description
        self.tags = tags; self.repo = repo; self.aliases = aliases; self.envs = envs; self.keys = keys
        self.endpoints = endpoints; self.requires = requires; self.guards = guards
    }

    enum CodingKeys: String, CodingKey {
        case id, name, kind, description, tags, repo, aliases, envs, keys, endpoints, requires, guards
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "other"
        description = try c.decodeIfPresent(String.self, forKey: .description)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        repo = try c.decodeIfPresent(RepoID.self, forKey: .repo)
        aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
        envs = try c.decodeIfPresent([String].self, forKey: .envs) ?? ["prod"]
        keys = try c.decodeIfPresent([Key].self, forKey: .keys) ?? []
        endpoints = try c.decodeIfPresent([Endpoint].self, forKey: .endpoints) ?? []
        requires = try c.decodeIfPresent([String].self, forKey: .requires) ?? []
        guards = try c.decodeIfPresent([String].self, forKey: .guards) ?? []
    }

    public var defaultEnv: String { envs.first ?? "prod" }

    /// Conditions of the service and of its endpoints, each once.
    public var conditionIDs: [String] {
        var seen = Set<String>()
        return (requires + endpoints.flatMap(\.requires)).filter { seen.insert($0).inserted }
    }
}

/// `service@env`; without `@env` the service's first environment.
public struct ServiceRef: Hashable, Sendable, CustomStringConvertible {
    public var service: String
    public var env: String?

    public init(service: String, env: String? = nil) { self.service = service; self.env = env }

    public init(parsing text: String) {
        let parts = text.split(separator: "@", maxSplits: 1).map(String.init)
        self.init(service: parts[0], env: parts.count > 1 ? parts[1] : nil)
    }

    public var description: String { env.map { "\(service)@\($0)" } ?? service }
}

/// A document about a service: a file in a repository (`repo` + `path`), a file beside the card
/// under `docs/`, or a link. Documentation that already lives in code repositories is referred
/// to, not copied.
public struct ServiceDoc: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case official, collected, generated }
    public var title: String
    public var kind: Kind
    /// The repository `path` is in; nil — relative to the service's `docs/` folder, or absolute.
    public var repo: RepoID?
    public var path: String?
    public var url: String?
    /// Heading inside the file this doc is about, when it is one section of a bigger file.
    public var section: String?

    public init(title: String, kind: Kind, repo: RepoID? = nil, path: String? = nil, url: String? = nil, section: String? = nil) {
        self.title = title; self.kind = kind; self.repo = repo; self.path = path; self.url = url; self.section = section
    }
}

/// One entry of `fields.yaml`: what a field of the service's results means.
public struct FieldDoc: Codable, Hashable, Sendable {
    public var path: String                 // extra.acc_motion
    public var type: String?
    public var meaning: String?
    public var values: [String: String]?    // "2|3": "начало движения"
    /// Where the meaning comes from: a doc title, a project file, "manual".
    public var from: [String]?

    public init(path: String, type: String? = nil, meaning: String? = nil,
                values: [String: String]? = nil, from: [String]? = nil) {
        self.path = path; self.type = type; self.meaning = meaning; self.values = values; self.from = from
    }
}

/// `${KEY}` templates over a set of values.
public enum Template {
    public struct Missing: Error, CustomStringConvertible, Sendable {
        public let keys: [String]
        public var description: String { "not set: " + keys.joined(separator: ", ") }
    }

    public static func keys(in template: String) -> [String] {
        var result: [String] = []
        var rest = template[...]
        while let open = rest.range(of: "${"), let close = rest[open.upperBound...].firstIndex(of: "}") {
            result.append(String(rest[open.upperBound..<close]))
            rest = rest[rest.index(after: close)...]
        }
        return result
    }

    public static func render(_ template: String, values: [String: String]) throws -> String {
        let needed = keys(in: template)
        let missing = needed.filter { (values[$0] ?? "").isEmpty }
        if !missing.isEmpty { throw Missing(keys: missing) }
        var out = template
        for key in needed { out = out.replacingOccurrences(of: "${\(key)}", with: values[key]!) }
        return out
    }
}
