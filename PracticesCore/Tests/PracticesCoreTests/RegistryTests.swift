import Testing
import Foundation
import Yams
@testable import PracticesCore

/// A throwaway home per test: spaces and secrets never touch ~/.practices.
struct TempHome {
    let url: URL
    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("practices-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    var registry: Registry { Registry(home: url) }
    var store: SecretStore { SecretStore(url: url.appendingPathComponent("secrets.json")) }
    func write(_ text: String, _ relative: String) throws {
        let file = url.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }
    /// A service card put in place without git, with the space and project around it.
    func place(_ service: Service, space: String = "sp", project: String = "pr") throws {
        try write("name: \(space)\n", "spaces/\(space)/space.yaml")
        try write("name: \(project)\n", "spaces/\(space)/projects/\(project)/project.yaml")
        try write(Registry.yaml(service), "spaces/\(space)/projects/\(project)/services/\(service.id)/service.yaml")
    }
}

@Suite struct TemplateTests {
    @Test func renderAndMissing() throws {
        #expect(Template.keys(in: "${A}:${B}") == ["A", "B"])
        #expect(try Template.render("${A}:${B}", values: ["A": "h", "B": "1"]) == "h:1")
        #expect(throws: Template.Missing.self) { try Template.render("${A}:${B}", values: ["A": "h", "B": ""]) }
    }

    @Test func dotenv() {
        let pairs = EnvFiles.parseDotenv("""
            # comment
            export A=1
            B="two words"
            C='x#y'
            D=plain # trailing
            bad-key=1
            """)
        #expect(pairs.map(\.key) == ["A", "B", "C", "D"])
        #expect(pairs.map(\.value) == ["1", "two words", "x#y", "plain"])
    }

    @Test func refs() {
        #expect(ServiceRef(parsing: "kafka@dev") == ServiceRef(service: "kafka", env: "dev"))
        #expect(ServiceRef(parsing: "kafka").env == nil)
    }
}

@Suite struct RepoIDTests {
    @Test func everyFormOfTheAddressIsOneRepository() {
        let id = "gitlab.rnd.x-keeper.net/x-keeper-rnd/x-vision/x-vision-cloud"
        for remote in ["git@gitlab.rnd.x-keeper.net:x-keeper-rnd/x-vision/x-vision-cloud.git",
                       "https://gitlab.rnd.x-keeper.net/X-Keeper-RND/x-vision/x-vision-cloud",
                       "https://gitlab.rnd.x-keeper.net/x-keeper-rnd/x-vision/x-vision-cloud.git/",
                       "https://user:token@gitlab.rnd.x-keeper.net/x-keeper-rnd/x-vision/x-vision-cloud.git",
                       "ssh://git@gitlab.rnd.x-keeper.net:2222/x-keeper-rnd/x-vision/x-vision-cloud.git",
                       "  " + id + "\n"] {
            #expect(RepoID(remote)?.description == id, "\(remote)")
        }
        #expect(RepoID("git@github.com:X-Keeper/device_analysis.git")?.description == "github.com/x-keeper/device_analysis")
        #expect(RepoID(id)?.sshURL == "git@gitlab.rnd.x-keeper.net:x-keeper-rnd/x-vision/x-vision-cloud.git")
    }

    @Test func whatIsNotAnAddressIsRefused() {
        for junk in ["", "name", "/Users/me/repo.git", "file:///srv/repo.git", "github.com/", "two words/x"] {
            #expect(RepoID(junk) == nil, "\(junk)")
        }
    }
}

/// The formats of PLAN.md, as written there.
@Suite struct YAMLFormatTests {
    func roundTrip<T: Codable & Equatable>(_ value: T) throws -> Bool {
        try YAMLDecoder().decode(T.self, from: Registry.yaml(value)) == value
    }

    @Test func service() throws {
        let service = try YAMLDecoder().decode(Service.self, from: """
            id: xkeeper-pg
            name: X-Keeper Postgres
            kind: postgres
            description: Базы X-Keeper, одна учётная запись на чтение. Никогда не писать.
            tags: [read-only, prod-data]
            repo: git@github.com:X-Keeper/pg-infra.git
            aliases: [pg.x-keeper.net]
            envs: [prod]
            keys: [XK_PG_HOST, XK_PG_USER, XK_PG_PASSWORD, XK_PG_PORT_DEVICES]
            endpoints:
              - id: devices
                address: ${XK_PG_HOST}:${XK_PG_PORT_DEVICES}
                requires: [corp-network]
            requires: []
            guards:
              - 'Каждое соединение: default_transaction_read_only = on'
            """)
        #expect(service.repo?.description == "github.com/x-keeper/pg-infra")
        #expect(service.aliases == ["pg.x-keeper.net"])
        #expect(service.endpoints[0].requires == ["corp-network"] && service.requires.isEmpty)
        #expect(service.conditionIDs == ["corp-network"])
        #expect(service.keys[2].secret && !service.keys[0].secret)
        let text = try Registry.yaml(service)
        #expect(text.contains("- XK_PG_HOST") && text.contains("Базы X-Keeper"))
        #expect(!text.contains("space:") && !text.contains("project:"))
        #expect(!text.contains("role:"))                       // written only when set
        #expect(try roundTrip(service))
        var placed = service
        placed.role = "infra"
        #expect(try Registry.yaml(placed).contains("kind: postgres\nrole: infra\n"))
        #expect(try roundTrip(placed))
    }

    @Test func minimalServiceDecodes() throws {
        let s = try YAMLDecoder().decode(Service.self, from: "id: x\nkeys: [A_TOKEN]\n")
        #expect(s.name == "x" && s.envs == ["prod"] && s.keys[0].secret && s.repo == nil && s.endpoints.isEmpty)
    }

    @Test func link() throws {
        let links = try YAMLDecoder().decode([Link].self, from: """
            - to: xkeeper-pg
              endpoint: devices
              env: prod
              via: db
              what: x-keeper_devices.devices
              access: read
              why: Модель и дата создания устройства для расчёта
              practice: xkeeper-pg/device-info
              names: {SRC_DEVICES_HOST: XK_PG_HOST}
              file: ops/.env
              origin: manual
            - to: kafka
            """)
        #expect(links[0].names == ["SRC_DEVICES_HOST": "XK_PG_HOST"] && links[0].via == "db" && links[0].file == "ops/.env")
        #expect(links[1] == Link(to: "kafka", origin: nil))
        #expect(try roundTrip(links))
    }

    @Test func conditionProjectSpace() throws {
        let conditions = try YAMLDecoder().decode([Condition].self, from: """
            - id: corp-network
              name: Корпоративная сеть X-Keeper
              hint: Включите WireGuard-туннель
              reachable: ${XK_PG_HOST}:${XK_PG_PORT_DEVICES}
            - id: office
              name: Только из офиса
            """)
        #expect(conditions[0].reachable == "${XK_PG_HOST}:${XK_PG_PORT_DEVICES}" && conditions[1].reachable == nil)
        #expect(try roundTrip(conditions))

        let project = try YAMLDecoder().decode(Project.self, from: """
            name: Device analysis
            parent: x-factory
            description: Анализ траекторий устройств
            repos:
              - {repo: github.com/x-keeper/device_analysis, role: frontend}
              - {repo: "https://github.com/X-Keeper/device_analysis-api.git", role: backend}
            folders:
              - {name: export_engine}
            """)
        #expect(project.repos.map(\.repo.description) == ["github.com/x-keeper/device_analysis", "github.com/x-keeper/device_analysis-api"])
        #expect(project.repos[1].role == "backend" && project.folders == [.init(name: "export_engine")] && project.parent == "x-factory")
        #expect(try roundTrip(project))
        #expect(try project.hosts.isEmpty && !Registry.yaml(project).contains("hosts"))
        var hosted = project
        hosted.hosts = ["prod-vm", "stage-vm"]
        #expect(try Registry.yaml(hosted).contains("hosts:\n- prod-vm\n- stage-vm\n"))
        #expect(try roundTrip(hosted))

        let space = try YAMLDecoder().decode(Space.self, from: """
            name: X-Keeper
            hosting:
              - {host: github.com, owner: X-Keeper}
              - {host: gitlab.rnd.x-keeper.net, owner: x-keeper-rnd}
            ignore:
              - gitlab.rnd.x-keeper.net/x-keeper-rnd/kanban
            """)
        #expect(space.hosting[1] == .init(host: "gitlab.rnd.x-keeper.net", owner: "x-keeper-rnd"))
        #expect(space.ignore == [RepoID("gitlab.rnd.x-keeper.net/x-keeper-rnd/kanban")!])
        #expect(try roundTrip(space))
    }
}

@Suite struct RegistryTests {
    @Test func servicesAreFoundAcrossSpacesAndIdsAreNotRepeated() async throws {
        let home = TempHome()
        let registry = home.registry
        try await registry.add(Space(id: "x-keeper", name: "X-Keeper"))
        try await registry.add(Space(id: "spheretele", name: "SphereTele"))
        try await registry.add(Project(id: "device-analysis", space: "x-keeper", name: "Device analysis"))
        try await registry.add(Project(id: "hyper-imu", space: "spheretele", name: "Hyper IMU"))
        try await registry.add(Service(id: "xkeeper-pg", name: "PG", kind: "postgres"), to: "device-analysis")
        try await registry.add(Service(id: "kafka", name: "Kafka", kind: "kafka"), to: "hyper-imu")
        try await registry.add(Condition(id: "corp-network", name: "Сеть"), to: "x-keeper")

        #expect(registry.spaceIDs() == ["spheretele", "x-keeper"])
        let kafka = try registry.service("kafka")
        #expect(kafka.space == "spheretele" && kafka.project == "hyper-imu")
        #expect(try registry.service("xkeeper-pg").space == "x-keeper")
        #expect(try registry.services().map(\.id) == ["kafka", "xkeeper-pg"])
        #expect(try registry.services(project: "hyper-imu").map(\.id) == ["kafka"])
        #expect(try registry.project("hyper-imu").space == "spheretele")
        #expect(registry.condition("corp-network")?.name == "Сеть")
        #expect(registry.dir(of: "kafka")?.path.hasSuffix("spaces/spheretele/projects/hyper-imu/services/kafka") == true)
        #expect(throws: Registry.Failure.self) { try registry.service("nope") }

        // One id, one record — in whatever space the second one is tried.
        await #expect(throws: Registry.Failure.self) { try await registry.add(Service(id: "kafka", name: "again", kind: "kafka"), to: "device-analysis") }
        await #expect(throws: Registry.Failure.self) { try await registry.add(Project(id: "hyper-imu", space: "x-keeper", name: "again")) }
        await #expect(throws: Registry.Failure.self) { try await registry.add(Condition(id: "corp-network", name: "again"), to: "spheretele") }
        await #expect(throws: Registry.Failure.self) { try await registry.add(Space(id: "x-keeper", name: "again")) }
        await #expect(throws: Registry.Failure.self) { try await registry.add(Service(id: "../x", name: "x", kind: "x"), to: "hyper-imu") }
        // Everything created was committed, each file by its own commit.
        #expect(await registry.pending().isEmpty)
        try home.write("", "spaces/x-keeper/projects/.DS_Store")
        #expect(await registry.pending().isEmpty)
    }

    @Test func localYamlMovesASpaceAndTheSearchRoots() throws {
        let home = TempHome()
        let elsewhere = home.url.appendingPathComponent("elsewhere/xk").path
        try home.write("spaces: {xk: \(elsewhere)}\nroots: [\(home.url.path)/code]\nfolders: {export_engine: /tmp/ee}\n", "local.yaml")
        try home.write("name: X\n", "elsewhere/xk/space.yaml")
        try home.write("name: Y\n", "spaces/other/space.yaml")
        let registry = home.registry
        #expect(registry.spaceIDs() == ["other", "xk"])
        #expect(try registry.space("xk").name == "X")
        #expect(registry.searchRoots == [home.url.path + "/code"])
        #expect(registry.local.folders == ["export_engine": "/tmp/ee"])
        #expect(Registry(home: TempHome().url).searchRoots.isEmpty)
    }

    @Test func aRepositoryIsInOneProject() async throws {
        let home = TempHome()
        let registry = home.registry
        try await registry.add(Space(id: "sp", name: "sp"))
        try await registry.add(Project(id: "a", space: "sp", name: "a"))
        try await registry.add(Project(id: "b", space: "sp", name: "b"))
        let repo = RepoID("git@github.com:X-Keeper/device_analysis.git")!
        try await registry.assign(repo, to: "a", role: "frontend")
        #expect(try registry.assigned() == [repo: "a"])
        #expect(try registry.project("a").repos == [.init(repo: repo, role: "frontend")])
        await #expect(throws: Registry.Failure.self) { try await registry.assign(repo, to: "b") }
        #expect(try await registry.unassign(repo) == "a")
        #expect(try await registry.unassign(repo) == nil)
        try await registry.assign(repo, to: "b")
        #expect(try registry.assigned() == [repo: "b"])
        try await registry.ignore(repo, in: "sp")
        #expect(try registry.space("sp").ignore == [repo])
        try await registry.ignore(repo, in: "sp", false)
        #expect(try registry.space("sp").ignore.isEmpty)
        #expect(await registry.pending().isEmpty)
    }

    @Test func projectsNestAndCyclesAreRefused() async throws {
        let home = TempHome()
        let registry = home.registry
        try await registry.add(Space(id: "sp", name: "sp"))
        try await registry.add(Space(id: "other", name: "other"))
        try await registry.add(Project(id: "x-factory", space: "sp", name: "X-Factory"))
        try await registry.add(Project(id: "scada", space: "sp", name: "SCADA", parent: "x-factory"))
        try await registry.add(Project(id: "erp", space: "sp", name: "ERP", parent: "x-factory"))
        try await registry.add(Project(id: "hmi", space: "sp", name: "HMI", parent: "scada"))
        try await registry.add(Project(id: "alone", space: "sp", name: "Alone"))
        let tree = Registry.tree(try registry.projects(space: "sp")).map { "\($0.depth) \($0.project.id)" }
        #expect(tree == ["0 alone", "0 x-factory", "1 erp", "1 scada", "2 hmi"])
        #expect(registry.path(ofProject: "hmi") == ["x-factory", "scada", "hmi"])

        var top = try registry.project("x-factory")
        top.parent = "hmi"
        #expect(throws: Registry.Failure.self) { try registry.save(top) }                // its own descendant
        top.parent = "x-factory"
        #expect(throws: Registry.Failure.self) { try registry.save(top) }                // itself
        await #expect(throws: Registry.Failure.self) { try await registry.add(Project(id: "p1", space: "sp", name: "p", parent: "nope")) }
        await #expect(throws: Registry.Failure.self) { try await registry.add(Project(id: "p2", space: "other", name: "p", parent: "scada")) }
        var erp = try registry.project("erp")
        erp.parent = "scada"
        try registry.save(erp)
        #expect(registry.path(ofProject: "erp") == ["x-factory", "scada", "erp"])
    }

    @Test func removingAProjectIgnoresItsReposAndReportsDanglingLinks() async throws {
        let home = TempHome()
        let registry = home.registry
        try await registry.add(Space(id: "sp", name: "sp"))
        try await registry.add(Project(id: "a", space: "sp", name: "a"))
        try await registry.add(Project(id: "b", space: "sp", name: "b"))
        try await registry.add(Project(id: "c", space: "sp", name: "c", parent: "a"))
        let repo = RepoID("github.com/o/a")!
        try await registry.assign(repo, to: "a")
        try await registry.add(Service(id: "a-svc", name: "a", kind: "http"), to: "a")
        try await registry.add(Service(id: "b-svc", name: "b", kind: "http"), to: "b")
        try await registry.commit("link", [try registry.addLink(Link(to: "a-svc"), from: "b-svc")])

        await #expect(throws: Registry.Failure.self) { try await registry.remove(project: "a") }
        #expect(try await registry.remove(project: "c").isEmpty)
        let dangling = try await registry.remove(project: "a")
        #expect(dangling.map { "\($0.from) \($0.to)" } == ["b-svc a-svc"])
        #expect(throws: Registry.Failure.self) { try registry.project("a") }
        #expect(try registry.space("sp").ignore == [repo])
        let log = try await registry.git(registry.dir(ofSpace: "sp"), ["log", "--format=%s"])
        #expect(log.contains("Remove project a"))
        #expect(await registry.pending().filter { $0.path.hasPrefix("projects/a/") }.isEmpty)

        // Kept repositories stay off the ignore list, back in «Не распределено».
        let kept = RepoID("github.com/o/b")!
        try await registry.assign(kept, to: "b")
        _ = try await registry.remove(project: "b", ignoreRepos: false)
        #expect(throws: Registry.Failure.self) { try registry.project("b") }
        #expect(try registry.space("sp").ignore == [repo])
        #expect(await registry.pending().isEmpty)
    }

    @Test func linksAreKeptAtTheCallerAndReadFromBothSides() throws {
        let home = TempHome()
        try home.place(Service(id: "api", name: "api", kind: "http"))
        try home.place(Service(id: "pg", name: "pg", kind: "postgres", endpoints: [.init(id: "devices", address: "${H}:1")]), project: "infra")
        let registry = home.registry
        let link = Link(to: "pg", endpoint: "devices", via: "db", what: "devices", access: "read", why: "модель устройства")
        _ = try registry.addLink(link, from: "api")
        _ = try registry.addLink(link, from: "api")                                          // the same link twice is one link
        #expect(registry.links(of: "api") == [link])
        #expect(registry.links(to: "pg").map(\.from) == ["api"])
        #expect(registry.links(to: "api").isEmpty)
        #expect(throws: Registry.Failure.self) { try registry.addLink(Link(to: "pg", endpoint: "nope"), from: "api") }
        #expect(throws: Registry.Failure.self) { try registry.addLink(Link(to: "pg", via: "pigeon"), from: "api") }
        #expect(throws: Registry.Failure.self) { try registry.addLink(Link(to: "missing"), from: "api") }
        #expect(throws: Registry.Failure.self) { try registry.addLink(Link(to: "pg"), from: "missing") }
    }

    @Test func anIndexedRegistryReadsTheSameAndKeepsItsListing() throws {
        let home = TempHome()
        try home.place(Service(id: "api", name: "api", kind: "http"))
        try home.place(Service(id: "pg", name: "pg", kind: "postgres"), project: "infra")
        _ = try home.registry.addLink(Link(to: "pg", via: "db"), from: "api")
        let indexed = home.registry.indexed()
        #expect(indexed.serviceIDs() == home.registry.serviceIDs())
        #expect(indexed.dir(of: "pg") == home.registry.dir(of: "pg"))
        #expect(indexed.links(to: "pg").map(\.from) == ["api"])
        try home.place(Service(id: "redis", name: "redis", kind: "redis"), project: "infra")
        #expect(indexed.dir(of: "redis") == nil)                                       // listed before the card was written
        #expect(home.registry.dir(of: "redis") != nil)
    }
}

@Suite struct HostsAndConventionsTests {
    @Test func hostsAreConditionsOfTheProjectsSpace() async throws {
        let home = TempHome()
        let registry = home.registry
        try await registry.add(Space(id: "sp", name: "Space"))
        try await registry.add(Space(id: "other", name: "Other"))
        try await registry.add(Project(id: "pr", space: "sp", name: "pr"))
        try await registry.add(Condition(id: "prod-vm", name: "Прод-сервер", hint: "ssh prod", reachable: "${HOST}:22"), to: "sp")
        try await registry.add(Condition(id: "elsewhere", name: "Чужой"), to: "other")

        try await registry.setHosts(["prod-vm"], of: "pr")
        #expect(try registry.project("pr").hosts == ["prod-vm"])
        await #expect(throws: Registry.Failure.self) { try await registry.setHosts(["elsewhere"], of: "pr") }
        await #expect(throws: Registry.Failure.self) { try await registry.setHosts(["nope"], of: "pr") }
        #expect(await registry.pending().isEmpty)

        let hosts = (try MCPServer(registry: registry).getProject("pr") as! [String: Any])["hosts"] as! [[String: Any]]
        #expect(hosts.count == 1 && hosts[0]["name"] as? String == "Прод-сервер" && hosts[0]["hint"] as? String == "ssh prod")
        #expect(hosts[0]["reachable"] == nil)

        try await registry.setHosts([], of: "pr")
        #expect(try registry.project("pr").hosts.isEmpty)
    }

    @Test func aNewSpaceGetsTheDefaultConventionsAndAnExistingOneKeepsItsOwn() async throws {
        let home = TempHome()
        let registry = home.registry
        try await registry.add(Space(id: "sp", name: "Space"))
        #expect(registry.conventions(of: "sp")?.contains("docker-compose.dev.yml") == true)
        #expect(registry.templates(of: "sp").map(\.path) == ["vscode/tasks.json"])
        #expect(registry.templates(of: "sp")[0].text.contains("docker compose -f docker-compose.dev.yml"))
        #expect(await registry.pending().isEmpty)

        // A space made by hand: what it has is read as is; big and binary files are left out.
        try home.write("name: own\n", "spaces/own/space.yaml")
        #expect(registry.conventions(of: "own") == nil && registry.templates(of: "own").isEmpty)
        try home.write("# Мои правила\n", "spaces/own/conventions.md")
        try home.write("services: {}\n", "spaces/own/templates/compose/docker-compose.yml")
        try home.write("A=1\n", "spaces/own/templates/.default.env")
        try home.write(String(repeating: "x", count: 65 * 1024), "spaces/own/templates/big.txt")
        try Data([0xff, 0xfe, 0x00, 0xd8]).write(to: home.url.appendingPathComponent("spaces/own/templates/logo.bin"))
        #expect(registry.conventions(of: "own") == "# Мои правила\n")
        #expect(registry.templates(of: "own").map(\.path) == [".default.env", "compose/docker-compose.yml"])

        let out = try await MCPServer(registry: registry).call("get_conventions", ["space": "own"]) as! [String: Any]
        #expect(out["space"] as? String == "own" && out["conventions"] as? String == "# Мои правила\n")
        #expect((out["templates"] as! [[String: Any]]).map { $0["path"] as! String } == [".default.env", "compose/docker-compose.yml"])
        await #expect(throws: (any Error).self) { _ = try await MCPServer(registry: registry).call("get_conventions", ["space": "nope"]) }
    }
}

@Suite struct SpaceGitTests {
    /// DECISIONS 19: an agent's practice edit waits for the user; a note saved meanwhile must
    /// not commit it.
    @Test func aNoteCommitLeavesAnUncommittedPracticeEditAlone() async throws {
        let home = TempHome()
        let registry = home.registry
        let store = PracticeStore(registry: registry)
        try await registry.add(Space(id: "sp", name: "sp"))
        try await registry.add(Project(id: "pr", space: "sp", name: "pr"))
        try await registry.add(Service(id: "s", name: "s", kind: "x"), to: "pr")
        let practice = Practice(ref: "s/p")
        try await store.save("def run():\n    return 1\n", for: practice)

        try store.writeDraft("def run():\n    return 2\n", for: practice)                      // the agent's edit
        try store.writeDraft("def run():\n    return 0\n", for: Practice(ref: "s/new"))        // and a new practice
        _ = try registry.addLink(Link(to: "s"), from: "s")                                     // and a link
        #expect(try await registry.commit("s: note", [try registry.saveNotes("- осторожно\n", of: "s")]))

        let services = "projects/pr/services/s"
        let pending = await registry.pending()
        #expect(Set(pending.map { "\($0.state) \($0.path)" })
                == ["modified \(services)/practices/p.py", "new \(services)/practices/new.py", "new \(services)/links.yaml"])
        #expect(pending.allSatisfy { $0.space == "sp" })
        #expect(try await store.versions(of: practice).count == 1)
        #expect(await store.isDraft(practice))
        let root = registry.dir(ofSpace: "sp")
        let lastCommit = try await registry.git(root, ["show", "--name-only", "--format=", "HEAD"])
        #expect(lastCommit.trimmingCharacters(in: .whitespacesAndNewlines) == "\(services)/notes.md")
        // Nothing to commit a second time.
        #expect(try await registry.commit("s: note", [root.appendingPathComponent("\(services)/notes.md")]) == false)

        // What the user reads before accepting: a diff, or the whole file when it is new.
        let diff = await registry.diff(of: pending.first { $0.state == "modified" }!)
        #expect(diff.contains("-    return 1") && diff.contains("+    return 2"))
        #expect(await registry.diff(of: pending.first { $0.path.hasSuffix("new.py") }!) == "def run():\n    return 0\n")

        // Accepting one file, then the rest.
        let one = try await registry.accept(space: "sp", paths: ["\(services)/practices/p.py"])
        #expect(one.map(\.path) == ["\(services)/practices/p.py"])
        #expect(try await store.versions(of: practice).count == 2)
        #expect(await registry.pending().count == 2)
        try await registry.accept()
        #expect(await registry.pending().isEmpty)
        #expect(try await store.versions(of: Practice(ref: "s/new")).count == 1)
    }

    @Test func discardDropsANewFileAndRestoresAnEditedOne() async throws {
        let home = TempHome()
        let registry = home.registry
        let store = PracticeStore(registry: registry)
        try await registry.add(Space(id: "sp", name: "sp"))
        try await registry.add(Project(id: "pr", space: "sp", name: "pr"))
        try await registry.add(Service(id: "s", name: "s", kind: "x"), to: "pr")
        let practice = Practice(ref: "s/p")
        try await store.save("def run():\n    return 1\n", for: practice)
        try store.writeDraft("def run():\n    return 2\n", for: practice)
        try home.write("id: t\nname: t\nkind: x\n", "spaces/sp/projects/pr/services/t/service.yaml")    // a candidate's card
        #expect(await registry.pending().count == 2)

        for change in await registry.pending() { try await registry.discard(change) }
        #expect(await registry.pending().isEmpty)
        let root = registry.dir(ofSpace: "sp")
        #expect(try String(contentsOf: root.appendingPathComponent("projects/pr/services/s/practices/p.py"), encoding: .utf8) == "def run():\n    return 1\n")
        // The card's folder, which it alone filled, is gone with it.
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("projects/pr/services/t").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("projects/pr/services/s").path))
    }
}

@Suite struct ReposTests {
    @Test func clonesAreFoundByTheirOrigin() throws {
        let home = TempHome()
        func clone(_ dir: String, _ url: String) throws {
            try home.write("[core]\n\tbare = false\n[remote \"upstream\"]\n\turl = git@github.com:other/fork.git\n[remote \"origin\"]\n\turl = \(url)\n\tfetch = +refs/heads/*:refs/remotes/origin/*\n[branch \"main\"]\n\tremote = origin\n", "code/\(dir)/.git/config")
        }
        try clone("X-Keeper/device-analysis/api", "git@github.com:X-Keeper/device_analysis-api.git")
        try clone("vision", "https://gitlab.rnd.x-keeper.net/x-keeper-rnd/x-vision/x-vision-cloud.git")
        try clone("vision/node_modules/dep", "git@github.com:some/dep.git")
        try clone("vision/.worktrees/feature", "git@github.com:some/worktree.git")
        try clone("a/b/c/d/e", "git@github.com:too/deep.git")
        try clone("a/b/c/d", "git@github.com:deep/enough.git")
        try home.write("gitdir: /elsewhere/.git/worktrees/w\n", "code/worktree/.git")          // a file: skipped
        try home.write("[core]\n\tbare = false\n", "code/local-only/.git/config")               // no remote
        try clone("vision/vendor/inner", "git@github.com:inside/a-clone.git")                    // a clone is not walked into
        try clone("py/lib/site-packages/pkg", "git@github.com:some/pkg.git")
        try clone("elsewhere/linked", "git@github.com:via/link.git")
        try FileManager.default.createSymbolicLink(atPath: home.url.appendingPathComponent("code/link").path,
                                                   withDestinationPath: home.url.appendingPathComponent("code/elsewhere").path)
        let clones = Repos.clones(roots: [home.url.appendingPathComponent("code").path])
        #expect(Set(clones.keys.map(\.description)) == ["github.com/x-keeper/device_analysis-api",
                                                         "gitlab.rnd.x-keeper.net/x-keeper-rnd/x-vision/x-vision-cloud",
                                                         "github.com/deep/enough", "github.com/via/link"])
        #expect(clones[RepoID("github.com/x-keeper/device_analysis-api")!]?.hasSuffix("code/X-Keeper/device-analysis/api") == true)
    }

    @Test func gitStateOfAClone() async throws {
        let home = TempHome()
        let origin = home.url.appendingPathComponent("origin").path, clone = home.url.appendingPathComponent("clone").path
        func git(_ dir: String, _ args: String...) async throws {
            _ = try await Shell.run("git", ["-C", dir, "-c", "user.name=t", "-c", "user.email=t@localhost", "-c", "commit.gpgsign=false"] + args)
        }
        try home.write("one\n", "origin/a.txt")
        try await git(origin, "init", "-q", "-b", "main")
        #expect(await Repos.gitState(ofClone: origin) == GitState(branch: "main", uncommitted: 1))     // no commit, no upstream
        try await git(origin, "add", "a.txt")
        try await git(origin, "commit", "-q", "-m", "first")
        try await git(home.url.path, "clone", "-q", origin, clone)
        try home.write("two\n", "origin/a.txt")
        try await git(origin, "commit", "-q", "-am", "theirs")

        try home.write("mine\n", "clone/b.txt")
        try await git(clone, "add", "b.txt")
        try await git(clone, "commit", "-q", "-m", "Мой коммит\tс табом")
        try home.write("changed\n", "clone/a.txt")
        try home.write("new\n", "clone/c.txt")
        // Before a fetch the clone does not know of `theirs`; nothing here fetches.
        var state = try #require(await Repos.gitState(ofClone: clone))
        #expect(state.branch == "main" && state.uncommitted == 2 && state.ahead == 1 && state.behind == 0)
        #expect(state.subject == "Мой коммит\tс табом" && abs(state.lastCommit!.timeIntervalSinceNow) < 60)
        try await git(clone, "fetch", "-q")
        state = try #require(await Repos.gitState(ofClone: clone))
        #expect(state.ahead == 1 && state.behind == 1)
        try await git(clone, "checkout", "-q", "--detach")
        #expect(await Repos.gitState(ofClone: clone)?.branch == nil)
        #expect(await Repos.gitState(ofClone: home.url.appendingPathComponent("nowhere").path) == nil)
    }

    static let github = """
        [{"description":"Анализ траекторий","isArchived":false,"nameWithOwner":"X-Keeper/device_analysis","pushedAt":"2026-10-30T09:15:00Z"},
         {"description":"","isArchived":true,"nameWithOwner":"X-Keeper/old-thing","pushedAt":"2023-01-02T00:00:00Z"}]
        """
    static let gitlab = """
        [{"id":1,"description":null,"path_with_namespace":"x-keeper-rnd/x-vision/x-vision-cloud","archived":false,"last_activity_at":"2026-11-01T10:00:00.123Z","namespace":{"full_path":"x-keeper-rnd/x-vision"}},
         {"id":2,"description":"Доска","path_with_namespace":"x-keeper-rnd/kanban","archived":false,"last_activity_at":"2026-05-01T10:00:00.000Z"},
         {"id":3,"description":"","path_with_namespace":"X-Keeper-RND/xsm/tools/xsm-external","archived":true,"last_activity_at":"2022-05-01T10:00:00.000Z"}]
        """

    @Test func hostingListingsAreParsed() throws {
        let gh = try Repos.parseGitHub(Self.github)
        #expect(gh.map(\.repo.description) == ["github.com/x-keeper/device_analysis", "github.com/x-keeper/old-thing"])
        #expect(gh.map(\.archived) == [false, true])
        #expect(gh[0].description == "Анализ траекторий" && gh[1].description == nil && gh[0].suggestedProject == nil)
        #expect(gh[0].lastActivity == ISO8601DateFormatter().date(from: "2026-10-30T09:15:00Z"))

        let gl = try Repos.parseGitLab(Self.gitlab, hosting: .init(host: "gitlab.rnd.x-keeper.net", owner: "x-keeper-rnd"))
        #expect(gl.map(\.repo.description) == ["gitlab.rnd.x-keeper.net/x-keeper-rnd/x-vision/x-vision-cloud",
                                                "gitlab.rnd.x-keeper.net/x-keeper-rnd/kanban",
                                                "gitlab.rnd.x-keeper.net/x-keeper-rnd/xsm/tools/xsm-external"])
        // The subgroup is the suggested project; a repository right in the group suggests none.
        #expect(gl.map(\.suggestedProject) == ["x-vision", nil, "xsm"])
        #expect(gl.map(\.archived) == [false, false, true])
        #expect(gl[0].lastActivity != nil)
        #expect(throws: (any Error).self) { try Repos.parseGitLab("{\"message\":\"401 Unauthorized\"}", hosting: .init(host: "h", owner: "o")) }
    }

    @Test func unassignedIsHostedPlusClonesMinusAssigned() throws {
        let hosted = try Repos.parseGitHub(Self.github)
            + Repos.parseGitLab(Self.gitlab, hosting: .init(host: "gitlab.rnd.x-keeper.net", owner: "x-keeper-rnd"))
        func id(_ text: String) -> RepoID { RepoID(text)! }
        let clones = [id("github.com/x-keeper/device_analysis"): "/code/da",                   // hosted, assigned
                      id("gitlab.rnd.x-keeper.net/x-keeper-rnd/kanban"): "/code/kanban",        // hosted, not assigned
                      id("github.com/me/scratch"): "/code/scratch",                             // only local
                      id("github.com/me/assigned-local"): "/code/al"]                           // only local, assigned
        let list = Repos.unassigned(hosted: hosted, clones: clones,
                                    assigned: [id("git@github.com:X-Keeper/device_analysis.git"), id("github.com/me/assigned-local")],
                                    ignored: [id("gitlab.rnd.x-keeper.net/x-keeper-rnd/kanban"), id("github.com/x-keeper/old-thing")])
        #expect(list.map(\.repo.description) == ["github.com/me/scratch", "github.com/x-keeper/old-thing",
                                                  "gitlab.rnd.x-keeper.net/x-keeper-rnd/kanban",
                                                  "gitlab.rnd.x-keeper.net/x-keeper-rnd/x-vision/x-vision-cloud",
                                                  "gitlab.rnd.x-keeper.net/x-keeper-rnd/xsm/tools/xsm-external"])
        #expect(list.map(\.clone) == ["/code/scratch", nil, "/code/kanban", nil, nil])
        // Ignored ones are marked, so the list leaves them out unless all are asked for.
        #expect(list.filter { !$0.ignored }.map(\.repo.description) == ["github.com/me/scratch",
                                                                         "gitlab.rnd.x-keeper.net/x-keeper-rnd/x-vision/x-vision-cloud",
                                                                         "gitlab.rnd.x-keeper.net/x-keeper-rnd/xsm/tools/xsm-external"])
        #expect(list.first { $0.repo == id("github.com/x-keeper/old-thing") }?.archived == true)
    }
}

@Suite struct StoreAndRunTests {
    @Test func secretsFileIsPrivate() throws {
        let home = TempHome()
        try home.store.set("v", key: "K", service: "s", env: "prod")
        let attrs = try FileManager.default.attributesOfItem(atPath: home.store.url.path)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)
        #expect(try home.store.values(service: "s", env: "prod") == ["K": "v"])
    }

    @Test func conflictingKeysAreRefused() throws {
        let home = TempHome()
        try home.place(Service(id: "a", name: "a", kind: "x", keys: [.init(name: "SHARED")]))
        try home.place(Service(id: "b", name: "b", kind: "x", envs: ["prod", "dev"], keys: [.init(name: "SHARED"), .init(name: "ONLY_B")]),
                       space: "other", project: "elsewhere")
        try home.store.set("1", key: "SHARED", service: "a", env: "prod")
        try home.store.set("2", key: "SHARED", service: "b", env: "prod")
        try home.store.set("1", key: "SHARED", service: "b", env: "dev")
        #expect(throws: RunEnvironment.Conflict.self) {
            try RunEnvironment.resolve([.init(service: "a"), .init(service: "b")], registry: home.registry, store: home.store)
        }
        let ok = try RunEnvironment.resolve([.init(service: "a"), .init(service: "b", env: "dev")], registry: home.registry, store: home.store)
        #expect(ok.values == ["SHARED": "1"])
        #expect(ok.missing["b@dev"] == ["ONLY_B"])
        #expect(throws: RunEnvironment.Unknown.self) { try RunEnvironment.resolve([.init(service: "nope")], registry: home.registry, store: home.store) }
    }

    @Test func conditionsOfTheServiceAndItsEndpointsAreChecked() async throws {
        let home = TempHome()
        try home.write("""
            - id: tunnel
              name: Туннель
              hint: Включите WireGuard-туннель
              reachable: ${HOST}:${PORT}
            - id: office
              name: Только из офиса
              hint: Работает из офисной сети
            - id: foreign
              name: Чужая сеть
              reachable: ${SOMEONE_ELSES_HOST}:1
            """, "spaces/sp/conditions.yaml")
        let service = Service(id: "pg", name: "pg", kind: "postgres", keys: [.init(name: "HOST"), .init(name: "PORT")],
                              endpoints: [.init(id: "devices", address: "${HOST}:${PORT}", requires: ["tunnel", "foreign"])],
                              requires: ["office", "undeclared"])
        try home.place(service)
        // Port 1 on localhost refuses at once.
        let results = await Checks.conditions(service, env: "prod", values: ["HOST": "127.0.0.1", "PORT": "1"], registry: home.registry)
        #expect(results.map(\.endpoint) == ["requires:office", "requires:undeclared", "requires:tunnel", "requires:foreign"])
        #expect(results.map(\.ok) == [true, false, false, true])
        let unmet = await Checks.unmet(service, env: "prod", values: ["HOST": "127.0.0.1", "PORT": "1"], registry: home.registry)
        #expect(unmet.count == 2 && unmet.contains("Включите WireGuard-туннель"))
        // Declared and never probed: what goes with a failed run. The probed and the undeclared do not.
        #expect(Checks.declared([service, service], registry: home.registry).map(\.hint) == ["Работает из офисной сети"])
    }
}

@Suite struct DoctorTests {
    @Test func multiSearch() {
        let search = MultiSearch(["secret-one", "другой-секрет", "abc"])
        let hits = search.matches(in: Data("xx другой-секрет yy secret-onX secret-one".utf8))
        #expect(hits == [0, 1])
    }

    @Test func findsLeakDriftDuplicateShared() async throws {
        let home = TempHome()
        try home.place(Service(id: "pg", name: "pg", kind: "postgres", keys: [.init(name: "PG_HOST"), .init(name: "PG_PASSWORD")]))
        try home.store.setAll(["PG_HOST": "db.local", "PG_PASSWORD": "hunter2hunter2"], service: "pg", env: "prod")
        try home.write("PG_HOST=db.local\nPG_PASSWORD=hunter2hunter2\n", "projects/a/.env")
        try home.write("PG_PASSWORD=old-password-1\n", "projects/b/.env")
        try home.write("see hunter2hunter2 here", "projects/c/NOTES.md")
        try home.write("OTHER_TOKEN=same-unknown-token\n", "projects/d/.env")
        try home.write("THIRD_TOKEN=same-unknown-token\n", "projects/e/.env.local")
        try home.write("PG_PASSWORD=hunter2hunter2\n", "projects/f/.env.example")
        let root = home.url.appendingPathComponent("projects").path
        let findings = try await Doctor.run(root: root, registry: home.registry, store: home.store)
        let byKind = Dictionary(grouping: findings, by: \.kind)
        #expect(byKind[.duplicate]?.map { ($0.path as NSString).lastPathComponent } == [".env"])
        #expect(byKind[.drift]?.first?.keys == ["PG_PASSWORD"])
        #expect(byKind[.leak]?.first?.path.hasSuffix("NOTES.md") == true)
        #expect(byKind[.shared]?.first?.keys == ["OTHER_TOKEN", "THIRD_TOKEN"])
        #expect(!findings.contains { $0.path.hasSuffix(".env.example") })
    }

    @Test func linkToAMissingServiceIsFlagged() async throws {
        let home = TempHome()
        try home.place(Service(id: "api", name: "api", kind: "http"))
        try home.place(Service(id: "pg", name: "pg", kind: "postgres"))
        _ = try home.registry.saveLinks([Link(to: "pg"), Link(to: "gone", via: "db"), Link(to: "gone", via: "http")], of: "api")
        let root = home.url.appendingPathComponent("projects")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let findings = try await Doctor.run(root: root.path, registry: home.registry, store: home.store, scanText: false)
        #expect(findings.map(\.kind) == [.dangling])
        #expect(findings.first?.related == ["api"] && findings.first?.keys == ["gone"])
        #expect(findings.first?.path.hasSuffix("services/api/links.yaml") == true)
    }

    @Test func valuesAreMatchedToServicesAcrossEnvFiles() throws {
        let home = TempHome()
        try home.place(Service(id: "pg", name: "pg", kind: "postgres", keys: [.init(name: "XK_PG_PASSWORD")]))
        try home.store.set("very-secret-pw", key: "XK_PG_PASSWORD", service: "pg", env: "prod")
        try home.write("SRC_PG_PASSWORD=very-secret-pw\n", "projects/a/.env")
        try home.write("DB_PASS=very-secret-pw\nOTHER=x\n", "projects/b/.env.local")
        let setup = try ProjectSetup.analyze(home.url.appendingPathComponent("projects"), registry: home.registry, store: home.store)
        #expect(setup.matches.map(\.variable) == ["SRC_PG_PASSWORD", "DB_PASS"])
        #expect(setup.matches.allSatisfy { $0.service == "pg" && $0.key == "XK_PG_PASSWORD" && $0.env == "prod" })
        #expect(setup.unmatched == ["OTHER"])
    }
}

@Suite struct EnvFilesTests {
    @Test func renderKeepsTheRestAndReplacesInPlace() {
        let text = "# app\nDEBUG=1\nexport CH_URL=http://old\nCH_URL=dup\n"
        let out = EnvFiles.render(text, values: ["CH_URL": "http://new", "CH_PASSWORD": "p w#1"], order: ["CH_URL", "CH_PASSWORD"])
        #expect(out == """
            # app
            DEBUG=1
            export CH_URL=http://new
            CH_URL=http://new

            \(EnvFiles.blockStart)
            CH_PASSWORD="p w#1"
            \(EnvFiles.blockEnd)

            """)
        // A second write rebuilds the block instead of stacking another one.
        let again = EnvFiles.render(out, values: ["CH_URL": "http://new", "CH_PASSWORD": "x"], order: ["CH_URL", "CH_PASSWORD"])
        #expect(again.components(separatedBy: EnvFiles.blockStart).count == 2)
        #expect(again.contains("CH_PASSWORD=x"))
        // A block written under the earlier heading is rebuilt too.
        let old = "A=1\n\n# >>> practices — values from ~/.practices; change them in Practices, then sync\nCH_PASSWORD=old\n\(EnvFiles.blockEnd)\n"
        let renewed = EnvFiles.render(old, values: ["CH_PASSWORD": "x"], order: ["CH_PASSWORD"])
        #expect(renewed == "A=1\n\n\(EnvFiles.blockStart)\nCH_PASSWORD=x\n\(EnvFiles.blockEnd)\n")
    }

    @Test func planAndWriteWithAliases() async throws {
        let home = TempHome()
        try home.place(Service(id: "ch", name: "ch", kind: "clickhouse", envs: ["prod", "dev"],
                               keys: [.init(name: "CH_URL"), .init(name: "CH_PASSWORD")]))
        try home.store.setAll(["CH_URL": "http://dev", "CH_PASSWORD": "secret-dev"], service: "ch", env: "dev")
        let project = home.url.appendingPathComponent("proj")
        try home.write("BFF_CH_PASSWORD=old\nOTHER=keep\n", "proj/.env")
        let file = ManagedFile(path: ".env", services: [ServiceRef(service: "ch", env: "dev")], env: ["BFF_CH_PASSWORD": "CH_PASSWORD"])
        let plan = try EnvFiles.plan(file, project: project, registry: home.registry, store: home.store)
        #expect(Set(plan.map { "\($0.variable):\($0.state.rawValue)" }) == ["CH_URL:new", "BFF_CH_PASSWORD:changed"])
        try await EnvFiles.write(file, project: project, registry: home.registry, store: home.store)
        let written = try String(contentsOf: project.appendingPathComponent(".env"), encoding: .utf8)
        #expect(written.hasPrefix("BFF_CH_PASSWORD=secret-dev\nOTHER=keep\n"))
        #expect(written.contains("CH_URL=http://dev"))
        #expect(!written.contains("CH_PASSWORD=secret-dev\n\(EnvFiles.blockEnd)"))   // alias replaces the registry name
        let after = try EnvFiles.plan(file, project: project, registry: home.registry, store: home.store)
        #expect(after.allSatisfy { $0.state == .same })
        // Nothing but the env file was written into the project.
        #expect(try FileManager.default.contentsOfDirectory(atPath: project.path) == [".env"])
    }

    @Test func refusesAFileGitWouldCommit() async throws {
        let home = TempHome()
        try home.place(Service(id: "s", name: "s", kind: "x", keys: [.init(name: "API_TOKEN")]))
        try home.store.set("value1", key: "API_TOKEN", service: "s", env: "prod")
        let project = home.url.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        _ = try await Shell.run("git", ["-C", project.path, "init", "-q"])
        // Not `.env`: a global gitignore (this machine has one) may already ignore that.
        let file = ManagedFile(path: "app.secrets", services: [ServiceRef(service: "s")])
        await #expect(throws: EnvFiles.Refused.self) {
            try await EnvFiles.write(file, project: project, registry: home.registry, store: home.store)
        }
        try "app.secrets\n".write(to: project.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try await EnvFiles.write(file, project: project, registry: home.registry, store: home.store)
        let attrs = try FileManager.default.attributesOfItem(atPath: project.appendingPathComponent("app.secrets").path)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)
    }
}

@Suite struct ServiceSearchTests {
    @Test func servicesMatchByIdNameKindAliasDescription() throws {
        let home = TempHome()
        try home.place(Service(id: "xkdb", name: "Main DB", kind: "postgres"))
        try home.place(Service(id: "api", name: "API", kind: "http", description: "talks to Postgres", aliases: ["gateway"]))
        try home.place(Service(id: "cache", name: "Redis", kind: "redis"))
        let pg = Search.run("postgres", registry: home.registry, runs: nil)
        #expect(pg.services.map(\.id) == ["api", "xkdb"] && pg.services.map(\.match) == ["description", "kind"])
        #expect(Search.run("gateway", registry: home.registry, runs: nil).services.map(\.match) == ["alias"])
        #expect(Search.run("main", registry: home.registry, runs: nil).services.first?.project == "pr")
        #expect(!pg.isEmpty && Search.run("nothing", registry: home.registry, runs: nil).isEmpty)
    }
}
