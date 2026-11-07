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
        #expect(ServiceMap.kindClass(of: Self.svc("kafka", "kafka", "p")) == .bus)
        #expect(ServiceMap.kindClass(of: Self.svc("xkdb", "socket", "p")) == .hw)
        #expect(ServiceMap.kindClass(of: Self.svc("job", "script", "p")) == .worker)
        #expect(ServiceMap.kindClass(of: Self.svc("gh", "http", "p", tags: ["external"])) == .ext)
    }

    @Test func projectView() {
        let m = ServiceMap.project("app", in: Self.catalogue)
        #expect(m.hubs.map(\.service.id) == ["sso", "wifi"])          // 5 callers, shared tag; sysapi's 4 is not enough
        #expect(m.hubs.map(\.callers) == [5, 1])
        #expect(m.own[.front]?.map(\.id) == ["web"])
        #expect(m.own[.api]?.map(\.id) == ["api", "job", "worker"])
        #expect(m.own[.data]?.map(\.id) == ["db"])
        #expect(m.chips["api"] == ["sso", "wifi"])
        #expect(m.chips["db"] == ["sso"] && m.chips["job"] == ["sso"] && m.chips.count == 5)
        #expect(m.externals.map(\.project.id) == ["plat", "plat2", "far"])   // 5, 4, 1 links
        #expect(m.externals[0].services.map(\.id) == ["sysapi"])
        #expect(m.edges.count == 12)                                   // no edge to a hub or to an unknown service
        #expect(!m.edges.contains { ["sso", "wifi"].contains($0.link.to) })
        #expect(m.edges.contains { $0.from == "api" && $0.link.to == "db" && $0.link.access == "write" })
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
