import Foundation

/// Values of keys: `secrets.json`, `{service: {env: {KEY: value}}}`, mode 0600, excluded from
/// Time Machine, never in git (DECISIONS 3). Stored unencrypted by the user's choice; this type
/// is the one place that reads or writes values, so encryption can be added here alone.
public struct SecretStore: Sendable {
    public let url: URL

    public init(url: URL = PracticesHome.secrets) { self.url = url }

    typealias Table = [String: [String: [String: String]]]

    func load() throws -> Table {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        return try JSONDecoder().decode(Table.self, from: Data(contentsOf: url))
    }

    func save(_ table: Table) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(table)
        // Create with 0600 before any byte is written, then replace the content.
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var target = url
        try? target.setResourceValues(excluded)
    }

    /// Values of one service in one environment.
    public func values(service: String, env: String) throws -> [String: String] {
        try load()[service]?[env] ?? [:]
    }

    /// Which of the given keys have a non-empty value, per environment. Never the values.
    public func status(service: Service) throws -> [String: Set<String>] {
        try status(of: [service])[service.id] ?? [:]
    }

    /// `status(service:)` of each, the file read once: service id → env → keys with a value.
    public func status(of services: [Service]) throws -> [String: [String: Set<String>]] {
        let all = try load()
        return Dictionary(services.map { ($0.id, Self.status(of: $0, in: all[$0.id] ?? [:])) }, uniquingKeysWith: { first, _ in first })
    }

    private static func status(of service: Service, in table: [String: [String: String]]) -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for env in service.envs {
            let values = table[env] ?? [:]
            result[env] = Set(service.keys.map(\.name).filter { !(values[$0] ?? "").isEmpty })
        }
        return result
    }

    public func set(_ value: String, key: String, service: String, env: String) throws {
        var table = try load()
        table[service, default: [:]][env, default: [:]][key] = value
        try save(table)
    }

    public func setAll(_ values: [String: String], service: String, env: String) throws {
        var table = try load()
        table[service, default: [:]][env, default: [:]].merge(values) { _, new in new }
        try save(table)
    }

    public func remove(key: String, service: String, env: String) throws {
        var table = try load()
        table[service]?[env]?[key] = nil
        try save(table)
    }

    /// Every secret value with where it belongs, for Doctor's search of plain files. Stays in
    /// this process; callers report names and paths only.
    func secretValues(services: [Service]) throws -> [(value: String, service: String, env: String, key: String)] {
        let table = try load()
        var out: [(String, String, String, String)] = []
        for service in services {
            for key in service.keys where key.secret {
                for (env, values) in table[service.id] ?? [:] {
                    if let value = values[key.name], value.count >= 8 { out.append((value, service.id, env, key.name)) }
                }
            }
        }
        return out
    }
}
