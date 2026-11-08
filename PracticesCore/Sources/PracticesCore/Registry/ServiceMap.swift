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

/// The three levels of the map (`work/2026-11-08-map`) as data, so views only lay out and draw:
/// a project's services with the neighbours its links reach, a space's service pairs, a
/// service's thread; and the role of every service (STRUCTURE.md §2).
public enum ServiceMap {
    public enum Column: String, CaseIterable, Sendable { case front, api, data }
    public typealias Role = Service.Role

    /// All links from one service to another, both known: one line on the map.
    public struct Pair: Hashable, Sendable {
        public var from: String
        public var to: String
        public var links: [Link]
        /// The via most of the links take: the line's colour.
        public var via: String? {
            Dictionary(grouping: links.compactMap(\.via), by: { $0 }).max { ($0.value.count, $1.key) < ($1.value.count, $0.key) }?.key
        }
    }

    public struct ProjectMap: Sendable {
        /// The project's services and those of its sub-projects, by id.
        public var own: [Service]
        /// Services of other projects that only call into this one.
        public var callers: [Service]
        /// Services of other projects this one calls (or that are called and call back).
        public var callees: [Service]
        public var pairs: [Pair]
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

    /// A service's thread: who calls it, who calls those, … (`up[0]` — the direct callers) and
    /// whom it calls, transitively (`down`), up to `hops` steps; a service is placed once, on the
    /// side and at the distance where it is met first. `pairs` run left to right only.
    public struct Thread: Sendable {
        public var up: [[Service]]
        public var down: [[Service]]
        public var pairs: [Pair]
    }

    public static let hubCallers = 5

    public static func column(of s: Service) -> Column {
        let words = (s.id + " " + s.name).lowercased()
        if s.kind == "frontend" || s.tags.contains("frontend") || words.contains("front")
            || words.range(of: #"(^|[-_ ])(ui|web)([-_ ]|$)"#, options: .regularExpression) != nil { return .front }
        return ["http", "worker", "tool", "script", "monitor"].contains { s.kind.contains($0) } ? .api : .data
    }

    // MARK: Roles

    static let infraKinds = ["postgres", "clickhouse", "redis", "kafka", "rabbit", "mq", "nats", "mysql", "sqlite", "s3", "minio", "influx"]
    static let busKinds = ["kafka", "rabbit", "mq", "nats"]

    /// A broker or a stream store: the `Шина` column of «Поток».
    public static func isBus(_ s: Service) -> Bool { busKinds.contains { s.kind.contains($0) } }

    /// `role:` of the card when it names a role, else the inferred one.
    public static func role(of s: Service, in c: Catalogue) -> Role { roles(in: c)[s.id] ?? inferredRole(s, callers: [], calls: []) }

    /// Every service's role at once: the map asks for all of them.
    public static func roles(in c: Catalogue) -> [String: Role] {
        let (_, ls) = resolved(c)
        // Reading another project's env file at build time is not a call.
        let callers = Dictionary(grouping: ls.filter { $0.link.via != "build" }, by: \.to.id), calls = Dictionary(grouping: ls, by: \.from.id)
        return Dictionary(c.services.map { s in
            (s.id, s.role.flatMap(Role.init(rawValue:))
                ?? inferredRole(s, callers: (callers[s.id] ?? []).map(\.from), calls: (calls[s.id] ?? []).map { ($0.to, $0.link) }))
        }, uniquingKeysWith: { a, _ in a })
    }

    /// STRUCTURE.md §2 by kind, name and links: external, device, infra, ops by kind; front by
    /// kind or a name word (front, web, ui, gateway, nginx); ingest — a socket or a receiver;
    /// relay — a worker writing to an external service; HTTP called only by fronts — bff, else
    /// backend; a worker with topic links or reading a broker — processing, else worker.
    public static func inferredRole(_ s: Service, callers: [Service], calls: [(to: Service, link: Link)]) -> Role {
        let kind = s.kind.lowercased()
        let words = Set((s.id + "-" + s.name).lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        let external = { (x: Service) in x.tags.contains("external") || ["external", "smtp"].contains(x.kind) }
        if external(s) { return .external }
        if kind.contains("firmware") { return .device }
        if infraKinds.contains(where: kind.contains) { return .infra }
        if ["script", "tool", "monitor"].contains(where: kind.contains) { return .ops }
        if kind == "frontend" || words.contains(where: { $0.hasPrefix("front") }) || !words.isDisjoint(with: ["web", "ui", "gateway", "nginx"]) { return .front }
        if kind == "socket" || words.contains(where: { $0.hasPrefix("receiver") }) { return .ingest }
        if kind == "http" {
            let fronts = callers.filter { ($0.role.flatMap(Role.init(rawValue:)) ?? inferredRole($0, callers: [], calls: [])) == .front }
            return !callers.isEmpty && fronts.count == callers.count ? .bff : .backend
        }
        if calls.contains(where: { external($0.to) && $0.link.access == "write" }) || words.contains("relay") { return .relay }
        if calls.contains(where: { $0.link.via == "topic" || isBus($0.to) }) { return .processing }
        if kind == "other" && calls.isEmpty && callers.isEmpty { return .ops }
        return .worker
    }

    // MARK: Levels

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

    /// Links grouped by caller and callee, in a stable order.
    public static func pairs(in c: Catalogue) -> [Pair] {
        var order: [[String]] = [], links: [[String]: [Link]] = [:]
        for l in resolved(c).links where l.from.id != l.to.id {
            let key = [l.from.id, l.to.id]
            if links[key] == nil { order.append(key) }
            links[key, default: []].append(l.link)
        }
        return order.map { Pair(from: $0[0], to: $0[1], links: links[$0]!) }
    }

    public static func project(_ id: String, in c: Catalogue) -> ProjectMap {
        let ids = subtree(id, c.projects)
        let byID = Dictionary(c.services.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let ps = pairs(in: c).filter { ids.contains(byID[$0.from]!.project) || ids.contains(byID[$0.to]!.project) }
        let own = c.services.filter { ids.contains($0.project) }.sorted { $0.id < $1.id }
        let others = Set(ps.flatMap { [$0.from, $0.to] }).filter { !ids.contains(byID[$0]!.project) }
        let called = Set(ps.map(\.to))
        let sorted = { (xs: [String]) in xs.compactMap { byID[$0] }.sorted { ($0.project, $0.id) < ($1.project, $1.id) } }
        return ProjectMap(own: own, callers: sorted(others.filter { !called.contains($0) }), callees: sorted(others.filter(called.contains)), pairs: ps)
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

    public static func thread(_ id: String, in c: Catalogue, hops: Int = 3) -> Thread {
        let all = pairs(in: c)
        let byID = Dictionary(c.services.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // Column: 0 the service, -d a caller d steps up, +d a callee d steps down.
        var column: [String: Int] = [id: 0]
        for (sign, next) in [(-1, { (p: Pair) in (p.to, p.from) }), (1, { (p: Pair) in (p.from, p.to) })] {
            var frontier = [id]
            for d in 1...max(hops, 1) {
                var found: [String] = []
                for p in all {
                    let (at, other) = next(p)
                    if frontier.contains(at) && column[other] == nil { column[other] = sign * d; found.append(other) }
                }
                frontier = found
            }
        }
        let side = { (sign: Int) in (1...max(hops, 1)).map { d in
            column.filter { $0.value == sign * d }.keys.compactMap { byID[$0] }.sorted { ($0.project, $0.id) < ($1.project, $1.id) } }
            .filter { !$0.isEmpty } }
        return Thread(up: side(-1), down: side(1),
                      pairs: all.filter { p in column[p.from].flatMap { a in column[p.to].map { a < $0 } } ?? false })
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
