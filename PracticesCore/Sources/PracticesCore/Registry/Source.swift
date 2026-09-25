import Foundation

/// A data source: the first-class object everything else refers to (PLAN, "Центральная
/// сущность — источник"). Stored as `registry/sources/<id>/source.yaml`; holds names of keys,
/// never their values.
public struct Source: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var kind: String                 // postgres, clickhouse, kafka, http, socket…
    public var description: String?
    public var tags: [String]
    /// Environments this source exists in; each has its own set of values.
    public var envs: [String]
    public var keys: [Key]
    /// Endpoints worth checking, as templates over the keys: `${XK_PG_HOST}`.
    public var targets: [Target]
    /// Checked before `run`, so a missing tunnel fails with a sentence instead of a timeout.
    public var requires: [Requirement]
    /// Rules the practices of this source keep, in words (read-only, shared consumer groups).
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
    public struct Target: Codable, Hashable, Sendable {
        public var id: String
        public var label: String?
        public var address: String?
        public var url: String?

        public init(id: String, label: String? = nil, address: String? = nil, url: String? = nil) {
            self.id = id; self.label = label; self.address = address; self.url = url
        }
    }

    public struct Requirement: Codable, Hashable, Sendable {
        /// `host:port` template that must accept a TCP connection.
        public var reachable: String
        /// What to tell the user when it does not: "нужен WireGuard-туннель".
        public var hint: String?

        public init(reachable: String, hint: String? = nil) {
            self.reachable = reachable; self.hint = hint
        }
    }

    public init(id: String, name: String, kind: String, description: String? = nil, tags: [String] = [],
                envs: [String] = ["prod"], keys: [Key] = [], targets: [Target] = [],
                requires: [Requirement] = [], guards: [String] = []) {
        self.id = id; self.name = name; self.kind = kind; self.description = description
        self.tags = tags; self.envs = envs; self.keys = keys; self.targets = targets
        self.requires = requires; self.guards = guards
    }

    enum CodingKeys: String, CodingKey { case id, name, kind, description, tags, envs, keys, targets, requires, guards }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "other"
        description = try c.decodeIfPresent(String.self, forKey: .description)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        envs = try c.decodeIfPresent([String].self, forKey: .envs) ?? ["prod"]
        keys = try c.decodeIfPresent([Key].self, forKey: .keys) ?? []
        targets = try c.decodeIfPresent([Target].self, forKey: .targets) ?? []
        requires = try c.decodeIfPresent([Requirement].self, forKey: .requires) ?? []
        guards = try c.decodeIfPresent([String].self, forKey: .guards) ?? []
    }

    public var defaultEnv: String { envs.first ?? "prod" }
}

/// A document attached to a source: a file under `docs/` or a link.
public struct SourceDoc: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case official, collected, generated }
    public var title: String
    public var kind: Kind
    /// Relative to the source's `docs/` folder, or absolute (a file in a project).
    public var path: String?
    public var url: String?
    /// Heading inside the file this doc is about, when it is one section of a bigger file.
    public var section: String?

    public init(title: String, kind: Kind, path: String? = nil, url: String? = nil, section: String? = nil) {
        self.title = title; self.kind = kind; self.path = path; self.url = url; self.section = section
    }
}

/// One entry of `fields.yaml`: what a field of the source's results means.
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
