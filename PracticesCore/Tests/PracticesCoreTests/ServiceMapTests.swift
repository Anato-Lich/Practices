import Testing
@testable import PracticesCore

@Suite struct ServiceMapTests {
    static func svc(_ id: String, _ kind: String, _ project: String, space: String = "sp", tags: [String] = []) -> Service {
        var s = Service(id: id, name: id, kind: kind, tags: tags)
        s.project = project; s.space = space
        return s
    }

    /// app ⊃ app-sub is the view; sso has 5 callers in it, sysapi 4, wifi is tagged shared.
    static let catalogue: Catalogue = {
        let projects = [Project(id: "app", space: "sp", name: "App"), Project(id: "app-sub", space: "sp", name: "Sub", parent: "app"),
                        Project(id: "plat", space: "sp", name: "Plat"), Project(id: "plat2", space: "sp", name: "Plat2"),
                        Project(id: "far", space: "sp2", name: "Far")]
        let services = [svc("web", "http", "app"), svc("api", "http", "app"), svc("db", "postgres", "app"),
                        svc("worker", "worker", "app-sub"), svc("job", "script", "app-sub"),
                        svc("sso", "http", "plat"), svc("sysapi", "http", "plat"), svc("wifi", "http", "plat", tags: ["shared"]),
                        svc("kafka", "kafka", "plat2"), svc("ext1", "http", "far", space: "sp2")]
        var links: [(from: String, link: Link)] = []
        for from in ["web", "api", "db", "worker", "job"] { links.append((from, Link(to: "sso", via: "http"))) }
        for from in ["web", "api", "worker", "job"] { links.append((from, Link(to: "sysapi", via: "http"))) }
        links += [("api", Link(to: "sysapi", via: "db")), ("api", Link(to: "wifi", via: "http")),
                  ("api", Link(to: "db", via: "db", access: "write")), ("worker", Link(to: "api", via: "http")),
                  ("api", Link(to: "kafka", via: "topic", what: "t1", access: "write")),
                  ("worker", Link(to: "kafka", via: "topic", what: "t1", access: "read")),
                  ("job", Link(to: "kafka", via: "topic", what: "t1")),
                  ("web", Link(to: "kafka", via: "topic", access: "read")),
                  ("api", Link(to: "ext1", via: "http")), ("api", Link(to: "ghost", via: "http"))]
        return Catalogue(projects: projects, services: services, links: links)
    }()

    @Test func classifiers() {
        #expect(ServiceMap.column(of: Self.svc("device-web", "http", "p")) == .front)
        #expect(ServiceMap.column(of: Self.svc("webhook", "http", "p")) == .api)
        #expect(ServiceMap.column(of: Self.svc("job", "script", "p")) == .api)
        #expect(ServiceMap.column(of: Self.svc("kafka", "kafka", "p")) == .data)
    }

    @Test func projectView() {
        let m = ServiceMap.project("app", in: Self.catalogue)
        #expect(m.own.map(\.id) == ["api", "db", "job", "web", "worker"])
        #expect(m.callers.isEmpty)
        #expect(m.callees.map(\.id) == ["ext1", "sso", "sysapi", "wifi", "kafka"])   // by project (far, plat, plat2), then id
        #expect(m.pairs.count == 17)                                                   // api→sysapi http+db is one pair
        #expect(m.pairs.first { $0.from == "api" && $0.to == "sysapi" }?.links.count == 2)
        #expect(!m.pairs.contains { $0.to == "ghost" })
        let plat = ServiceMap.project("plat", in: Self.catalogue)
        #expect(plat.callers.map(\.id) == ["api", "db", "web", "job", "worker"])      // they only call in
    }

    @Test func roles() {
        let r = ServiceMap.roles(in: Self.catalogue)
        #expect(r["web"] == .front && r["db"] == .infra && r["kafka"] == .infra && r["job"] == .ops)
        #expect(r["api"] == .backend)            // called by a worker, not only by fronts
        #expect(r["worker"] == .processing)      // reads a topic
        var c = Self.catalogue
        c.links.removeAll { $0.from == "worker" && $0.link.to == "api" }
        c.links.append(("web", Link(to: "api", via: "http")))
        #expect(ServiceMap.roles(in: c)["api"] == .bff)   // now called only by web
        c.services[1].role = "worker"                       // `role:` wins over the inference
        #expect(ServiceMap.roles(in: c)["api"] == .worker)
        c.services[1].role = "nonsense"
        #expect(ServiceMap.roles(in: c)["api"] == .bff)
        let relay = Self.svc("x-relay", "worker", "p"), target = Self.svc("t", "http", "q", tags: ["external"])
        #expect(ServiceMap.inferredRole(relay, callers: [], calls: [(target, Link(to: "t", access: "write"))]) == .relay)
        #expect(ServiceMap.inferredRole(Self.svc("rx", "socket", "p"), callers: [], calls: []) == .ingest)
        #expect(ServiceMap.inferredRole(Self.svc("fw", "firmware", "p"), callers: [], calls: []) == .device)
        #expect(ServiceMap.inferredRole(target, callers: [], calls: []) == .external)
    }

    @Test func thread() {
        let t = ServiceMap.thread("api", in: Self.catalogue)
        #expect(t.up.map { $0.map(\.id) } == [["worker"], ["job"]])        // job writes t1, which worker reads
        #expect(t.down.map { $0.map(\.id) } == [["db", "ext1", "sso", "sysapi", "wifi"]])
        #expect(t.columns.map(\.step) == [-4, -3, -2, 1, 2])                // kafka between steps, twice
        #expect(!t.pairs.contains { $0.from == "db" })                      // db→sso runs within one column
        #expect(t.pairs.contains { $0.from == "api" && $0.to == "kafka@1" })
        let one = ServiceMap.thread("sso", in: Self.catalogue, hops: 1)
        #expect(one.up.count == 1 && one.up[0].count == 5 && one.down.isEmpty)
        let two = ServiceMap.thread("sso", in: Self.catalogue, hops: 2)
        #expect(two.up.count == 1)                 // every caller of sso is already in the first column
    }

    /// writer → t → bus → reader, through the broker per topic; db by access.
    @Test func threadFollowsData() {
        let services = ["writer", "reader", "other", "clean", "api", "store", "report"].map { Self.svc($0, "worker", "p") }
            + [Self.svc("bus", "kafka", "p")]
        let links: [(from: String, link: Link)] = [
            ("writer", Link(to: "bus", via: "topic", what: "t", access: "write")),
            ("clean", Link(to: "bus", via: "topic", what: "t", access: "read")),
            ("clean", Link(to: "bus", via: "topic", what: "t.clean", access: "write")),
            ("clean", Link(to: "api", via: "http", access: "read")),
            ("other", Link(to: "bus", via: "topic", what: "u", access: "read")),     // another topic: not on the thread
            ("reader", Link(to: "bus", via: "topic", what: "t.clean", access: "read")),
            ("reader", Link(to: "store", via: "db", access: "write")),
            ("report", Link(to: "store", via: "db", access: "read"))]
        let c = Catalogue(projects: [Project(id: "p", space: "sp", name: "P")], services: services, links: links)
        let t = ServiceMap.thread("clean", in: c)
        #expect(t.up.map { $0.map(\.id) } == [["writer"]])
        #expect(t.down.map { $0.map(\.id) } == [["api", "reader"], ["store"], ["report"]])
        #expect(t.columns.map(\.step) == [-2, -1, 1, 2, 4, 6])               // the broker once on each side, no step of its own
        #expect(t.columns.first { $0.step == 1 }?.nodes.map(\.key) == ["bus@1"])
        let ends = Set(t.pairs.map { "\($0.from)>\($0.to)" })
        #expect(ends == ["writer>bus@-1", "bus@-1>clean", "clean>bus@1", "bus@1>reader", "clean>api", "reader>store", "store>report"])
        #expect(t.pairs.first { $0.to == "bus@1" }?.links.map(\.what) == ["t.clean"])
        #expect(!t.pairs.contains { $0.from.contains("other") || $0.to.contains("other") })
        let bus = ServiceMap.thread("bus", in: c, hops: 1)                    // the broker itself: all writers left, readers right
        #expect(bus.up.map { $0.map(\.id) } == [["clean", "writer"]])
        #expect(bus.down.map { $0.map(\.id) } == [["other", "reader"]])        // clean is placed already, up
    }

    @Test func spaceView() {
        let m = ServiceMap.space("sp", in: Self.catalogue)
        #expect(m.projects.map(\.project.id) == ["app", "app-sub", "plat", "plat2"])
        #expect(m.projects.map(\.depth) == [0, 1, 0, 0])
        let pairs = Dictionary(uniqueKeysWithValues: m.pairs.map { ("\($0.a)|\($0.b)", $0.count) })
        #expect(pairs == ["app|plat": 7, "app-sub|plat": 4, "app|plat2": 2, "app-sub|plat2": 2, "app|app-sub": 1])
        #expect(m.pairs.first?.count == 7)
        #expect(m.crossSpace == 1)
    }

    @Test func focusAndTopics() {
        let api = ServiceMap.service("api", in: Self.catalogue)
        #expect(api.callers.map(\.service.id) == ["worker"])
        #expect(api.callees.map(\.service.id) == ["db", "ext1", "kafka", "sso", "sysapi", "wifi"])
        #expect(api.callees.first { $0.service.id == "sysapi" }?.links.count == 2)
        #expect(api.topics == nil)

        let topics = ServiceMap.service("kafka", in: Self.catalogue).topics ?? []
        #expect(topics.map(\.what) == ["t1", nil])
        #expect(topics[0].writers.map(\.id) == ["api"])
        #expect(topics[0].readers.map(\.id) == ["worker"])
        #expect(topics[0].users.map(\.id) == ["job"])
        #expect(topics[1].readers.map(\.id) == ["web"])
    }
}
