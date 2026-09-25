import Foundation
import Yams

/// Names a registry key goes by in projects (DECISIONS 49): the same X-Keeper password is
/// `XK_PG_PASSWORD` here, `DB_PASSWORD` there. Kept per source in `names.yaml` of the registry,
/// found by matching values in the projects' env files and by the aliases of their manifests.
public struct KnownName: Codable, Hashable, Sendable {
    public var name: String
    /// Env files (under the projects root) that hold the key under this name.
    public var files: [String]
}

public enum Names {

    /// source id → key → names, from ~/Projects. Values are compared in-process only.
    public static func scan(root: String = Monitor.projectsRoot(), registry: Registry = Registry(),
                            store: SecretStore = SecretStore()) throws -> [String: [String: [KnownName]]] {
        let setup = try ProjectSetup.analyze(URL(fileURLWithPath: root), registry: registry, store: store)
        var table: [String: [String: [String: Set<String>]]] = [:]
        // Both spellings of the root: the given one and the real one (/var → /private/var).
        // (realpath, not resolvingSymlinksInPath: the latter strips /private instead of adding it.)
        var real = root
        if let resolved = realpath(root, nil) {
            real = String(cString: resolved)
            free(resolved)
        }
        let prefixes = [root, real].map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        func rel(_ p: String) -> String {
            for prefix in prefixes where p.hasPrefix(prefix) { return String(p.dropFirst(prefix.count)) }
            return p
        }
        for m in setup.matches {
            table[m.source, default: [:]][m.key, default: [:]][m.variable, default: []].insert(rel(m.file))
        }
        for project in ProjectManifest.all(root: root) {
            for file in project.manifest.files {
                for (variable, key) in file.env {
                    guard let source = file.sources.first(where: { ref in
                        ((try? registry.source(ref.source))?.keys ?? []).contains { $0.name == key } })?.source else { continue }
                    table[source, default: [:]][key, default: [:]][variable, default: []]
                        .insert(rel(project.dir.appendingPathComponent(file.path).path))
                }
            }
        }
        return table.mapValues { keys in
            keys.mapValues { names in
                names.map { KnownName(name: $0.key, files: $0.value.sorted()) }.sorted { ($0.files.count, $1.name) > ($1.files.count, $0.name) }
            }
        }
    }

    public static func load(_ source: String, registry: Registry = Registry()) -> [String: [KnownName]] {
        guard let text = try? String(contentsOf: registry.dir(of: source).appendingPathComponent("names.yaml"), encoding: .utf8) else { return [:] }
        return (try? YAMLDecoder().decode([String: [KnownName]].self, from: text)) ?? [:]
    }

    /// Rescans and writes `names.yaml` for every source; commits when something changed.
    @discardableResult
    public static func refresh(registry: Registry = Registry(), store: SecretStore = SecretStore()) async throws -> [String: [String: [KnownName]]] {
        let table = try scan(registry: registry, store: store)
        for id in registry.sourceIDs() {
            let names = table[id] ?? [:]
            let url = registry.dir(of: id).appendingPathComponent("names.yaml")
            if names.isEmpty { try? FileManager.default.removeItem(at: url); continue }
            let header = "# Names of this source's keys in project env files (practicesctl names). Values never.\n"
            try (header + Registry.yaml(names)).write(to: url, atomically: true, encoding: .utf8)
        }
        try await registry.commit("Names of keys in projects")
        return table
    }

    /// Other names a key already has, when `variable` is a new one for it: the warning `connect`
    /// prints before a project gets yet another name for the same value.
    public static func others(for key: String, source: String, variable: String, registry: Registry = Registry()) -> [KnownName] {
        let known = load(source, registry: registry)[key] ?? []
        guard !known.contains(where: { $0.name == variable }) else { return [] }
        return known
    }
}
