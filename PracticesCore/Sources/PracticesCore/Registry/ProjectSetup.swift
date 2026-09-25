import Foundation

/// What a project's `.env` files say about the registry: which sources and environments their
/// values belong to, and which of its variable names differ from the registry's. The base of
/// `practicesctl init`. Values are compared inside this process only.
public struct ProjectSetup: Sendable {
    public struct Match: Hashable, Sendable {
        public let variable: String       // name in the project's .env
        public let key: String            // registry key with the same value
        public let source: String
        public let env: String
        public let file: String
    }

    public var matches: [Match] = []
    /// Variables in the .env files that match nothing in the registry.
    public var unmatched: [String] = []
    public var envFiles: [String] = []

    /// The manifest this suggests: one environment per source (the one most variables point
    /// to), aliases where the project's name differs.
    public var manifest: ProjectManifest {
        var bySource: [String: [String: Int]] = [:]
        for m in matches { bySource[m.source, default: [:]][m.env, default: 0] += 1 }
        let chosen = bySource.mapValues { $0.max { $0.value < $1.value }!.key }
        var aliases: [String: String] = [:]
        for m in matches where chosen[m.source] == m.env && m.variable != m.key { aliases[m.variable] = m.key }
        return ProjectManifest(sources: chosen.keys.sorted().map { SourceRef(source: $0, env: chosen[$0]) }, env: aliases)
    }

    public static func analyze(_ dir: URL, registry: Registry = Registry(), store: SecretStore = SecretStore()) throws -> ProjectSetup {
        var setup = ProjectSetup()
        let sources = try registry.sources()
        // value → places in the registry, for values long enough to identify something.
        var byValue: [String: [(key: String, source: String, env: String)]] = [:]
        var names = Set<String>()
        for source in sources {
            for env in source.envs {
                for (key, value) in try store.values(source: source.id, env: env) where value.count >= 6 {
                    byValue[value, default: []].append((key, source.id, env))
                }
            }
            source.keys.forEach { names.insert($0.name) }
        }
        let files = Doctor.collect(root: dir.path).env.filter { !$0.contains("/.claude/") }
        setup.envFiles = files
        var seen = Set<String>()
        for file in files {
            guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
            for (variable, value) in ConnectorsImport.parseDotenv(text) where !value.isEmpty && seen.insert(variable).inserted {
                let places = byValue[value] ?? []
                // Same name first; otherwise the value's owner, when there is exactly one.
                if let same = places.first(where: { $0.key == variable }) ?? (places.count == 1 ? places.first : nil) {
                    setup.matches.append(.init(variable: variable, key: same.key, source: same.source, env: same.env, file: file))
                } else {
                    setup.unmatched.append(variable)
                }
            }
        }
        return setup
    }
}
