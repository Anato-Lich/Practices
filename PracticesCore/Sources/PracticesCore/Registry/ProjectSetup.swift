import Foundation

/// What a project's `.env` files say about the registry: which services and environments
/// their values belong to, and which of its variable names differ from the registry's (the
/// second way a found reference is matched to a service, DECISIONS 8). Values are compared
/// inside this process only.
public struct ProjectSetup: Sendable {
    public struct Match: Hashable, Sendable {
        public let variable: String       // name in the project's .env
        public let key: String            // registry key with the same value
        public let service: String
        public let env: String
        public let file: String
    }

    public var matches: [Match] = []
    /// Variables in the .env files that match nothing in the registry.
    public var unmatched: [String] = []
    public var envFiles: [String] = []

    public static func analyze(_ dir: URL, registry: Registry = Registry(), store: SecretStore = SecretStore()) throws -> ProjectSetup {
        var setup = ProjectSetup()
        let services = try registry.services()
        // value → places in the registry, for values long enough to identify something.
        var byValue: [String: [(key: String, service: String, env: String)]] = [:]
        for service in services {
            for env in service.envs {
                for (key, value) in try store.values(service: service.id, env: env) where value.count >= 6 {
                    byValue[value, default: []].append((key, service.id, env))
                }
            }
        }
        let files = Doctor.collect(root: dir.path).env.filter { !$0.contains("/.claude/") }
        setup.envFiles = files
        for file in files {
            guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
            // Repeats are dropped per file: over a whole tree one name lives in many files.
            var seen = Set<String>()
            for (variable, value) in EnvFiles.parseDotenv(text) where !value.isEmpty && seen.insert(variable).inserted {
                let places = byValue[value] ?? []
                // Same name first; otherwise the value's owner, when there is exactly one.
                if let same = places.first(where: { $0.key == variable }) ?? (places.count == 1 ? places.first : nil) {
                    setup.matches.append(.init(variable: variable, key: same.key, service: same.service, env: same.env, file: file))
                } else {
                    if !setup.unmatched.contains(variable) { setup.unmatched.append(variable) }
                }
            }
        }
        return setup
    }
}
