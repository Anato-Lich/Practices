import Foundation

/// What the map needs from the registry, loaded once: `Registry.catalogue()`.
public struct Catalogue: Sendable {
    public var projects: [Project]
    public var services: [Service]
    public var links: [(from: String, link: Link)]

    public init(projects: [Project], services: [Service], links: [(from: String, link: Link)]) {
        self.projects = projects; self.services = services; self.links = links
    }
}

extension Registry {
    public func catalogue() throws -> Catalogue {
        let registry = indexed()
        return Catalogue(projects: try registry.projects(), services: try registry.services(),
                         links: registry.serviceIDs().flatMap { from in registry.links(of: from).map { (from, $0) } })
    }
}

/// The three levels of the map (DECISIONS 35) as data, so views only draw: a space's projects
/// and their pairs, a project's columns, externals and shared hubs, a service's two sides.
/// Ported from `tools/map/levels.html`.
public enum ServiceMap {
    public enum Column: String, CaseIterable, Sendable { case front, api, data }
    public enum KindClass: String, CaseIterable, Sendable { case front, api, data, bus, hw, ext, worker, other }

    /// A drawn link of a project view.
    public struct Edge: Hashable, Sendable {
        public var from: String
        public var link: Link
    }

    public struct ProjectMap: Sendable {
        public var own: [Column: [Service]]
        public var externals: [(project: Project, services: [Service])]
        public var hubs: [(service: Service, callers: Int)]
        public var edges: [Edge]
        /// Caller id → the hubs it calls, in link order: the `→ имя` chips on its card.
        public var chips: [String: [String]]
    }

    public struct SpaceMap: Sendable {
        public var projects: [(project: Project, depth: Int)]
        /// Links between two different projects of the space, `a < b`; the app picks the threshold.
        public var pairs: [(a: String, b: String, count: Int)]
        /// Links from or to another space, not drawn.
        public var crossSpace: Int
    }

    public struct Topic: Sendable {
        public var what: String?
        public var writers: [Service], readers: [Service], users: [Service]
    }

    public struct ServiceFocus: Sendable {
        public var callers: [(service: Service, links: [Link])]
        public var callees: [(service: Service, links: [Link])]
        /// Only for a broker (kafka, rabbitmq): the topic table instead of the caller fan.
        public var topics: [Topic]?
    }

    public static let hubCallers = 5

    public static func column(of s: Service) -> Column {
        let words = (s.id + " " + s.name).lowercased()
        if s.kind == "frontend" || s.tags.contains("frontend") || words.contains("front")
            || words.range(of: #"(^|[-_ ])(ui|web)([-_ ]|$)"#, options: .regularExpression) != nil { return .front }
        return ["http", "worker", "tool", "script", "monitor"].contains { s.kind.contains($0) } ? .api : .data
    }

    public static func kindClass(of s: Service) -> KindClass {
        let has = { (words: [String]) in words.contains { s.kind.contains($0) } }
        if s.tags.contains("external") { return .ext }
        if has(["kafka", "rabbit", "mq", "nats"]) { return .bus }
        if has(["postgres", "clickhouse", "redis", "mysql", "sqlite", "s3", "influx"]) { return .data }
        if has(["firmware", "socket"]) { return .hw }
        if column(of: s) == .front { return .front }
        if has(["http"]) { return .api }
        if has(["worker", "tool", "script", "monitor"]) { return .worker }
        return .other
    }

    /// A project and all projects under it.
    static func subtree(_ id: String, _ projects: [Project]) -> Set<String> {
        var ids: Set<String> = [id], queue = [id]
        while let next = queue.popLast() {
            for p in projects where p.parent == next && ids.insert(p.id).inserted { queue.append(p.id) }
        }
        return ids
    }

    /// Links whose both ends are known services.
    static func resolved(_ c: Catalogue) -> (byID: [String: Service], links: [(from: Service, to: Service, link: Link)]) {
        let byID = Dictionary(c.services.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return (byID, c.links.compactMap { l in byID[l.from].flatMap { a in byID[l.link.to].map { (a, $0, l.link) } } })
    }

    public static func project(_ id: String, in c: Catalogue) -> ProjectMap {
        let ids = subtree(id, c.projects), (_, all) = resolved(c)
        let ls = all.filter { ids.contains($0.from.project) || ids.contains($0.to.project) }
        var callers: [String: Set<String>] = [:]
        for l in ls { callers[l.to.id, default: []].insert(l.from.id) }
        var seen = Set<String>(), touched: [Service] = []
        for l in ls { for s in [l.from, l.to] where seen.insert(s.id).inserted { touched.append(s) } }
        let hubs = touched.filter { callers[$0.id, default: []].count >= hubCallers || $0.tags.contains("shared") }
            .map { (service: $0, callers: callers[$0.id, default: []].count) }
            .sorted { ($1.callers, $0.service.id) < ($0.callers, $1.service.id) }
        let hubIDs = Set(hubs.map(\.service.id))

        let own = c.services.filter { ids.contains($0.project) && !hubIDs.contains($0.id) }.sorted { $0.id < $1.id }
        let plain = ls.filter { !hubIDs.contains($0.from.id) && !hubIDs.contains($0.to.id) }
        let ext = touched.filter { !ids.contains($0.project) && !hubIDs.contains($0.id) }
        let weight = { (pid: String) in plain.filter { $0.from.project == pid || $0.to.project == pid }.count }
        let externals = Dictionary(grouping: ext, by: \.project).compactMap { pid, xs in
            c.projects.first { $0.id == pid }.map { (project: $0, services: xs.sorted { $0.id < $1.id }) }
        }.sorted { (weight($1.project.id), $0.project.id) < (weight($0.project.id), $1.project.id) }

        var chips: [String: [String]] = [:]
        for l in ls where hubIDs.contains(l.to.id) && !hubIDs.contains(l.from.id) && !(chips[l.from.id]?.contains(l.to.id) ?? false) {
            chips[l.from.id, default: []].append(l.to.id)
        }
        return ProjectMap(own: Dictionary(grouping: own, by: column(of:)), externals: externals, hubs: hubs,
                          edges: plain.map { Edge(from: $0.from.id, link: $0.link) }, chips: chips)
    }

    public static func space(_ id: String, in c: Catalogue) -> SpaceMap {
        var counts: [[String]: Int] = [:], cross = 0
        for l in resolved(c).links where l.from.project != l.to.project {
            let (a, b) = (l.from, l.to)
            if a.space != b.space { if a.space == id || b.space == id { cross += 1 }; continue }
            if a.space == id { counts[[a.project, b.project].sorted(), default: 0] += 1 }
        }
        return SpaceMap(projects: Registry.tree(c.projects.filter { $0.space == id }),
                        pairs: counts.map { (a: $0.key[0], b: $0.key[1], count: $0.value) }
                            .sorted { ($1.count, $0.a, $0.b) < ($0.count, $1.a, $1.b) },
                        crossSpace: cross)
    }

    public static func service(_ id: String, in c: Catalogue) -> ServiceFocus {
        let (byID, ls) = resolved(c)
        func group(_ pairs: [(Service, Link)]) -> [(service: Service, links: [Link])] {
            Dictionary(grouping: pairs, by: \.0.id).map { (service: $0.value[0].0, links: $0.value.map(\.1)) }
                .sorted { $0.service.id < $1.service.id }
        }
        let incoming = ls.filter { $0.to.id == id }.map { ($0.from, $0.link) }
        var topics: [Topic]?
        if let s = byID[id], ["kafka", "rabbitmq"].contains(where: s.kind.contains) {
            topics = Dictionary(grouping: incoming, by: \.1.what).map { what, xs in
                let who = { (access: String?) in
                    group(xs.filter { access == nil ? !["read", "write"].contains($0.1.access ?? "") : $0.1.access == access }).map(\.service)
                }
                return Topic(what: what, writers: who("write"), readers: who("read"), users: who(nil))
            }.sorted { ($0.what ?? "\u{10FFFF}") < ($1.what ?? "\u{10FFFF}") }   // no topic last
        }
        return ServiceFocus(callers: group(incoming), callees: group(ls.filter { $0.from.id == id }.map { ($0.to, $0.link) }),
                            topics: topics)
    }
}
