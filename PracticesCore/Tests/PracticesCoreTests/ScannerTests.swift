import Testing
import Foundation
import Yams
@testable import PracticesCore

@Suite struct ScannerTests {
    /// A home whose search root is `code/`, with project `pr` of space `sp` holding the given
    /// repositories, each cloned under its last name.
    func catalogue(_ repos: [String]) throws -> TempHome {
        let home = TempHome()
        try home.write("roots: [\(home.url.path)/code]\n", "local.yaml")
        try home.write("name: sp\n", "spaces/sp/space.yaml")
        try home.write(Registry.yaml(Project(id: "pr", space: "sp", name: "pr", repos: repos.map { .init(repo: RepoID($0)!) })),
                       "spaces/sp/projects/pr/project.yaml")
        for repo in repos {
            try home.write("[remote \"origin\"]\n\turl = https://\(repo).git\n", "code/\((repo as NSString).lastPathComponent)/.git/config")
        }
        return home
    }

    func card(_ home: TempHome, _ service: Service) throws {
        try home.write(Registry.yaml(service), "spaces/sp/projects/pr/services/\(service.id)/service.yaml")
    }

    func json(_ result: ScanResult) throws -> String { String(decoding: try JSONEncoder().encode(result), as: UTF8.self) }

    @Test func valuesAndFileNames() {
        #expect(Scanner.literal("${A:-http://x:1}/v${B-2}") == "http://x:1/v2")
        #expect(Scanner.literal("http://${HOST}:8000") == nil)
        #expect(Scanner.literal("$HOME/x") == nil)
        #expect(Scanner.addresses("postgresql+asyncpg://u:p@ss@Db.Example:5432/app?sslmode=require")
                == [.init(scheme: "postgresql+asyncpg", host: "db.example", port: 5432, path: "/app")])
        #expect(Scanner.addresses("jdbc:clickhouse://ch:8123").map(\.host) == ["ch"])
        #expect(Scanner.addresses("PLAINTEXT://a:9092, b:9093").map(\.port) == [9092, 9093])
        #expect(Scanner.addresses("https://api.example/").first?.path == nil)
        for notAnAddress in ["12:30", "0.0.0.0:8000", "http://0.0.0.0:8000", "frames.norm", "redis:7-alpine", "true"] {
            #expect(Scanner.addresses(notAnAddress).isEmpty, "\(notAnAddress)")
        }
        for name in [".default.env", "kafka.default.env", ".env.example", "env.example", "prod.env.example", ".env.sample"] {
            #expect(Scanner.isExampleEnv(name), "\(name)")
        }
        for name in [".env", ".env.local", ".env.production", ".deploy.env", "kafka.env", "example.txt"] {
            #expect(!Scanner.isExampleEnv(name), "\(name)")
        }
        #expect(Scanner.realCounterpart("a/.default.env") == "a/.env")
        #expect(Scanner.realCounterpart("a/kafka.default.env") == "a/kafka.env")
        #expect(Scanner.realCounterpart(".env.example") == ".env")
        #expect(Scanner.realCounterpart("a/env.example") == "a/.env")
        #expect(["postgres:16-alpine", "clickhouse/clickhouse-server", "confluentinc/cp-kafka:7", "minio/minio", "provectuslabs/kafka-ui", nil]
            .map(Scanner.kind(ofImage:)) == ["postgres", "clickhouse", "kafka", "s3", "http", "http"])
        #expect(Scanner.hostKey(.init(id: "e", address: "${H}:${P}")) == "H")
        #expect(Scanner.hostKey(.init(id: "e", url: "https://${U}:${PW}@${HOST}/api")) == "HOST")
        #expect(Scanner.hostKey(.init(id: "e", url: "${URL}/v1")) == "URL")
        #expect(Scanner.hostKey(.init(id: "e", url: "https://${SUB}.example.com")) == nil)
    }

    @Test func composeServicesAreMatchedOrBecomeCandidates() throws {
        let shopRepo = RepoID("github.com/acme/shop")!
        let home = try catalogue(["github.com/acme/shop", "github.com/acme/infra"])
        try card(home, Service(id: "kafka", name: "Kafka", kind: "kafka", aliases: ["hyper-kafka"]))
        try card(home, Service(id: "shop-backend", name: "API", kind: "http", repo: shopRepo, aliases: ["api"]))
        try card(home, Service(id: "billing", name: "Billing", kind: "http", repo: shopRepo))
        try home.write("""
            services:
              api: {build: .}
              billing: {build: ./billing}
              hyper-kafka: {image: "apache/kafka:4.1.1"}
              postgres: {image: "postgres:16-alpine"}
              mailer: {build: ./mailer}
              frontend: {build: ./web}
              shop-frontend: {build: ./web2}
            networks:
              sphere-net: {external: true}
              default: {}
            """, "code/shop/docker-compose.yml")
        try home.write("""
            services:
              mailer: {image: "registry.example/mailer:1"}
              minio: {image: minio/minio}
            networks:
              shared: {name: sphere-net, external: true}
            """, "code/shop/deploy/compose.prod.yaml")
        try home.write("services:\n  mailer: {image: x/mailer}\n  kafka-ui: {image: provectuslabs/kafka-ui}\n", "code/infra/docker-compose.yml")
        try home.write("services:\n  too-deep: {image: redis}\n", "code/shop/a/b/c/d/docker-compose.yml")
        try home.write("services:\n  vendored: {image: redis}\n", "code/shop/node_modules/x/docker-compose.yml")
        try home.write("services: [not, a, map\n", "code/shop/compose.broken.yml")

        let result = try Scanner.scan(registry: home.registry, store: home.store)
        #expect(result.repos.map(\.repo.description) == ["github.com/acme/infra", "github.com/acme/shop"])
        let infra = result.repos[0], shop = result.repos[1]
        // `api` and `billing` are the repository's own cards, `hyper-kafka` is the shared Kafka.
        #expect(infra.services.map(\.id) == ["kafka-ui", "mailer"])
        #expect(infra.services.map(\.kind) == ["http", "http"])
        // `mailer` is taken by the other candidate, the rest are generic names; `shop-frontend`
        // keeps its own name, so the generic `frontend` has none left.
        #expect(shop.services.map(\.id) == ["shop-frontend", "shop-mailer", "shop-minio", "shop-postgres"])
        #expect(shop.services.map(\.kind) == ["http", "http", "s3", "postgres"])
        #expect(shop.services.map(\.aliases) == [[], ["mailer"], ["minio"], ["postgres"]])
        #expect(shop.services.allSatisfy { $0.repo == shopRepo })
        #expect(shop.problems == ["compose.broken.yml: not read as YAML",
                                  "frontend: its id shop-frontend is taken — if it is that service, add frontend to its aliases"])
        #expect(result.networks == ["sphere-net": ["github.com/acme/shop"]])
        // One repository, by address or by its project; an unknown name is an error.
        #expect(try Scanner.scan(["git@github.com:acme/shop.git"], registry: home.registry, store: home.store).repos.map(\.repo) == [shopRepo])
        #expect(try Scanner.scan(["pr"], registry: home.registry, store: home.store).repos.count == 2)
        #expect(throws: Registry.Failure.self) { _ = try Scanner.scan(["nothing"], registry: home.registry, store: home.store) }
    }

    @Test func aBuildWithAWebFrameworkIsAFrontend() throws {
        let home = try catalogue(["github.com/acme/shop"])
        try home.write("services:\n  web: {build: ./web}\n  api: {build: .}\n", "code/shop/docker-compose.yml")
        try home.write("{\"devDependencies\": {\"vite\": \"^5\"}}\n", "code/shop/web/package.json")
        let services = try Scanner.scan(registry: home.registry, store: home.store).repos[0].services
        #expect(services.map { "\($0.id) \($0.kind)" } == ["shop-api http", "shop-web frontend"])
    }

    @Test func variablesBecomeLinksAndEnvIsNeverRead() throws {
        let home = try catalogue(["github.com/acme/shop", "github.com/acme/lone", "github.com/acme/tiles"])
        try card(home, Service(id: "kafka", name: "Kafka", kind: "kafka", aliases: ["hyper-kafka"],
                               endpoints: [.init(id: "bootstrap", address: "${KAFKA_BOOTSTRAP}")]))
        try card(home, Service(id: "locator", name: "Locator", kind: "http", aliases: ["wifi-locator-api"],
                               endpoints: [.init(id: "api", url: "${LOC_URL}")]))
        try card(home, Service(id: "pg", name: "PG", kind: "postgres", keys: [.init(name: "PG_HOST"), .init(name: "PG_PASSWORD")],
                               endpoints: [.init(id: "main", address: "${PG_HOST}:${PG_PORT}"), .init(id: "other", address: "${PG_HOST}:${PG_PORT2}")]))
        try card(home, Service(id: "ch", name: "CH", kind: "clickhouse", envs: ["dev"], endpoints: [.init(id: "http", url: "http://${CH_HOST}:8123")]))
        try home.store.setAll(["PG_HOST": "db.corp.example", "PG_PORT": "5432", "PG_PORT2": "5433", "PG_PASSWORD": "stored-secret-pw"], service: "pg", env: "prod")
        try home.store.setAll(["CH_HOST": "localhost"], service: "ch", env: "dev")
        try home.write("""
            services:
              api:
                build: .
                env_file:
                  - {path: .default.env, required: true}
                  - {path: .env, required: false}
                environment:
                  DB_DSN: postgresql://app:hunter2pw@postgres:5432/app
                  LOCATOR_URL: http://wifi-locator-api:8000/mac?x=1
                  CH_URL: http://host.docker.internal:8123
                  FROM_SHELL: ${LOCATOR_URL}
                  WITH_DEFAULT: ${ELSEWHERE:-http://nowhere.example:9000}
                  SELF_URL: http://api:8080
              worker:
                build: .
                env_file: .env
              postgres:
                image: postgres:16
            """, "code/shop/docker-compose.yml")
        try home.write("""
            SRC_PG=db.corp.example:5432
            KAFKA_BOOTSTRAP_SERVERS=hyper-kafka:19092
            KAFKA_TOPIC_INPUT=frames
            KAFKA_TOPIC_NORM_OUT=frames.norm
            KAFKA_TOPIC_WARNINGS=warnings
            KAFKA_AUTO_CREATE_TOPICS_ENABLE=true
            EMPTY_URL=
            """, "code/shop/.default.env")
        try home.write("REPORTS_TOPIC=reports\nMETRICS=metrics.example:9100\n", "code/shop/jobs/.env.example")
        for secret in [".env", ".env.local", ".deploy.env", "jobs/secrets.env"] {
            try home.write("POISON_URL=http://poison.example:6666\nKAFKA_TOPIC_POISON=poison-topic\n", "code/shop/\(secret)")
        }
        try home.write("""
            services:
              svc:
                build: ../tiles
                environment: [EVENTS_TOPIC=events]
              svc2:
                build: {context: ../shop/sub}
            """, "code/lone/compose.yaml")
        try home.write("services:\n  tileserver: {build: .}\n", "code/tiles/docker-compose.yml")

        let result = try Scanner.scan(registry: home.registry, store: home.store)
        let lone = result.repos[0], shop = result.repos[1]
        #expect(shop.services.map(\.id) == ["shop-api", "shop-postgres", "shop-worker"])
        func links(_ from: String, _ repo: ScanResult.Repo) -> [Link] { repo.new.filter { $0.from == from }.map(\.link) }

        let compose = "derived:docker-compose.yml", env = "derived:.default.env"
        #expect(links("shop-api", shop) == [
            // `environment:` of the service: the DSN to the repository's own compose service,
            Link(to: "ch", endpoint: "http", env: "dev", via: "db", names: ["CH_URL": "CH_HOST"], origin: compose),
            Link(to: "shop-postgres", via: "db", origin: compose),
            // another name of a catalogued service,
            Link(to: "locator", via: "http", what: "/mac", names: ["LOCATOR_URL": "LOC_URL"], origin: compose),
            // then the env file it names: an endpoint as the stored values render it, and topics.
            Link(to: "pg", endpoint: "main", env: "prod", via: "db", names: ["SRC_PG": "PG_HOST"], file: ".default.env", origin: env),
            Link(to: "kafka", via: "network", names: ["KAFKA_BOOTSTRAP_SERVERS": "KAFKA_BOOTSTRAP"], file: ".default.env", origin: env),
            Link(to: "kafka", via: "topic", what: "frames", access: "read", origin: env),
            Link(to: "kafka", via: "topic", what: "frames.norm", access: "write", origin: env),
            Link(to: "kafka", via: "topic", what: "warnings", origin: env),
            Link(to: "kafka", via: "topic", what: "reports", origin: "derived:jobs/.env.example"),
        ])
        // `worker` names `.env`, which `.default.env` stands for; nobody names `jobs/.env.example`,
        // so it is of the services that are built.
        #expect(links("shop-worker", shop).map(\.what) == [nil, nil, "frames", "frames.norm", "warnings", "reports"])
        #expect(links("shop-postgres", shop).isEmpty)
        #expect(shop.unknown == [
            .init(callers: ["shop-api"], file: "docker-compose.yml", variable: "WITH_DEFAULT", host: "nowhere.example", port: 9000),
            .init(callers: ["shop-api", "shop-worker"], file: "jobs/.env.example", variable: "METRICS", host: "metrics.example", port: 9100),
        ])

        // A build context in another repository: its one service, or a question.
        #expect(lone.new == [.init(from: "svc", link: Link(to: "tileserver", via: "build", origin: "derived:compose.yaml"))])
        #expect(lone.unknown == [
            .init(callers: ["svc"], file: "compose.yaml", variable: "EVENTS_TOPIC", topic: "events"),
            .init(callers: ["svc2"], file: "compose.yaml", build: "github.com/acme/shop"),
        ])

        // Nothing of the secret files, of credentials in a DSN or of stored values gets out.
        let text = try json(result)
        for secret in ["poison", "hunter2pw", "stored-secret-pw", "db.corp.example"] { #expect(!text.contains(secret), "\(secret)") }
    }

    @Test func hostAndPortInTwoVariablesAreOneAddress() throws {
        #expect(Scanner.splitHost("DB_HOST", "Db.Example") { $0 == "DB_PORT" ? "5432" : nil } == .init(host: "db.example", port: 5432))
        #expect(Scanner.splitHost("DB_HOST", "db.example") { _ in nil } == .init(host: "db.example"))
        for (name, value) in [("DB_HOSTNAME", "db"), ("HOST", "db"), ("BIND_HOST", "0.0.0.0"), ("DB_HOST", "localhost"), ("DB_HOST", "db:5432"), ("N_HOST", "42")] {
            #expect(Scanner.splitHost(name, value) { _ in nil } == nil, "\(name)=\(value)")
        }

        let home = try catalogue(["github.com/acme/shop"])
        try card(home, Service(id: "pg", name: "PG", kind: "postgres",
                               endpoints: [.init(id: "main", address: "${PG_HOST}:${PG_PORT}"), .init(id: "other", address: "${PG_HOST}:${PG_PORT2}")]))
        try card(home, Service(id: "cache", name: "Cache", kind: "redis", aliases: ["shared-redis"]))
        try home.store.setAll(["PG_HOST": "db.corp.example", "PG_PORT": "5432", "PG_PORT2": "5433"], service: "pg", env: "prod")
        try home.write("""
            services:
              api:
                build: .
                env_file: .env
                environment: {SRC_PORT: "5432"}
            """, "code/shop/docker-compose.yml")
        // The port is the sibling of the same file, not `SRC_PORT` of the compose file.
        try home.write("SRC_HOST=db.corp.example\nSRC_PORT=5433\nANY_HOST=db.corp.example\nREDIS_HOST=shared-redis\nNEW_HOST=new.example\nNEW_PORT=1\n",
                       "code/shop/.env.example")
        let shop = try Scanner.scan(registry: home.registry, store: home.store).repos[0]
        let env = "derived:.env.example"
        #expect(shop.new.map(\.link) == [
            // `ANY_HOST` is pg again by `via: db`, whichever endpoint: one link.
            Link(to: "pg", endpoint: "other", env: "prod", via: "db", names: ["SRC_HOST": "PG_HOST"], file: ".env.example", origin: env),
            // A host alone is a service known by that name.
            Link(to: "cache", via: "db", origin: env),
        ])
        #expect(shop.present.isEmpty)
        #expect(shop.unknown == [.init(callers: ["shop-api"], file: ".env.example", variable: "NEW_HOST", host: "new.example", port: 1)])
    }

    @Test func genericNames() {
        for name in ["db", "Postgres", "kafka", "broker", "localhost", "127.0.0.1", "::1", "::1:80", "localhost:8000", "db:5432", "host.docker.internal:80"] {
            #expect(Scanner.generic(name), "\(name)")
        }
        for name in ["ble-anchors-pg", "wifi-locator", "locator.imux.ru", "db.corp.example:5432", "10.0.0.5", "dbx"] {
            #expect(!Scanner.generic(name), "\(name)")
        }
    }

    @Test func shortNamesDoNotCrossProjects() throws {
        let home = try catalogue(["github.com/acme/scada"])
        // Same project, no repository: found by its generic alias.
        try card(home, Service(id: "pr-api", name: "API", kind: "http", aliases: ["api"]))
        // Another project of the space: by a name of its own, never by `localhost:8000`.
        try home.place(Service(id: "wifi-db", name: "Wifi", kind: "http", aliases: ["wifi-locator", "localhost:8000"],
                               endpoints: [.init(id: "api", url: "${WIFI_URL}")]), project: "other")
        try home.store.setAll(["WIFI_URL": "http://localhost:8000"], service: "wifi-db", env: "prod")
        // Another space: only by a dotted name.
        try home.place(Service(id: "far-pg", name: "PG", kind: "postgres", aliases: ["db"]), space: "far", project: "fp")
        try home.place(Service(id: "far-redis", name: "Redis", kind: "redis", aliases: ["cache"]), space: "far", project: "fp")
        try home.place(Service(id: "locator", name: "Locator", kind: "http", aliases: ["locator.imux.ru"]), space: "far", project: "fp")
        try home.write("""
            services:
              app:
                build: .
                environment:
                  API_URL: http://api:8080
                  BFF_URL: http://localhost:8000/v1
                  DB_DSN: postgresql://u@db:5432/x
                  LOC_URL: https://locator.imux.ru/mac
                  REDIS_URL: redis://cache:6379
                  WIFI: http://wifi-locator:8000
              cache: {image: "redis:7"}
            """, "code/scada/docker-compose.yml")

        let first = try Scanner.scan(registry: home.registry, store: home.store)
        let scada = first.repos[0]
        // `cache` is far-redis's alias in another space: a candidate of its own.
        #expect(scada.services.map(\.id) == ["scada-app", "scada-cache"])
        let compose = "derived:docker-compose.yml"
        #expect(scada.new.map(\.link) == [
            Link(to: "pr-api", via: "http", origin: compose),
            Link(to: "locator", via: "http", what: "/mac", origin: compose),
            Link(to: "scada-cache", via: "db", origin: compose),
            Link(to: "wifi-db", via: "http", names: ["WIFI": "WIFI_URL"], origin: compose),
        ])
        #expect(scada.unknown == [
            .init(callers: ["scada-app"], file: "docker-compose.yml", variable: "BFF_URL", host: "localhost", port: 8000),
            .init(callers: ["scada-app"], file: "docker-compose.yml", variable: "DB_DSN", host: "db", port: 5432),
        ])

        try Scanner.write(first, registry: home.registry)
        let second = try Scanner.scan(registry: home.registry, store: home.store).repos[0]
        #expect(second.services.isEmpty && second.new.isEmpty && second.gone.isEmpty)
        #expect(second.present.map(\.link) == scada.new.map(\.link))
    }

    @Test func curatedLinksAreFoundAgainByCallerTargetAndVia() async throws {
        let home = TempHome()
        let repo = RepoID("github.com/acme/shop")!
        try home.write("roots: [\(home.url.path)/code]\n", "local.yaml")
        let registry = home.registry
        try home.write("[remote \"origin\"]\n\turl = git@github.com:acme/shop.git\n", "code/shop/.git/config")
        try await registry.add(Space(id: "sp", name: "sp"))
        try await registry.add(Project(id: "pr", space: "sp", name: "pr"))
        try await registry.assign(repo, to: "pr")
        try await registry.add(Service(id: "kafka", name: "Kafka", kind: "kafka", aliases: ["hyper-kafka"]), to: "pr")
        try await registry.add(Service(id: "wifi-db", name: "Wifi", kind: "http", aliases: ["wifi-locator"],
                                         endpoints: [.init(id: "cluster", url: "${WIFI_URL}")]), to: "pr")
        try await registry.add(Service(id: "shop-api", name: "API", kind: "http", repo: repo, aliases: ["api"]), to: "pr")
        let curated = Link(to: "wifi-db", endpoint: "cluster", via: "http", what: "GET /mac/{mac}", why: "where a MAC is",
                           origin: "derived:.default.env")
        let derived = "derived:.default.env"
        for link in [curated, Link(to: "kafka", via: "network", origin: derived),
                     Link(to: "kafka", via: "topic", what: "a", origin: derived), Link(to: "kafka", via: "topic", what: "b", origin: derived),
                     Link(to: "kafka", via: "topic", what: "old", origin: derived), Link(to: "kafka", via: "topic", what: "by-hand")] {
            try registry.addLink(link, from: "shop-api")
        }
        try home.write("services:\n  api: {build: ., env_file: .env}\n", "code/shop/docker-compose.yml")
        try home.write("BFF_WIFI_LOCATOR_URL=http://wifi-locator:8000/mac\nKAFKA=hyper-kafka:9092\nA_TOPIC=a\nB_TOPIC=b\nC_TOPIC=c\n",
                       "code/shop/.default.env")

        let shop = try Scanner.scan(registry: registry, store: home.store).repos[0]
        #expect(shop.present.map(\.link.to) == ["wifi-db", "kafka", "kafka", "kafka"])
        #expect(shop.present.compactMap(\.link.what) == ["/mac", "a", "b"])
        // Topics are one link each; a manual link is never gone.
        #expect(shop.new.map(\.link) == [Link(to: "kafka", via: "topic", what: "c", origin: derived)])
        #expect(shop.gone.map(\.link.what) == ["old"])
    }

    @Test func writeLeavesEverythingPendingAndTheNextScanSeesIt() async throws {
        let home = TempHome()
        let repo = RepoID("github.com/acme/shop")!
        try home.write("roots: [\(home.url.path)/code]\n", "local.yaml")
        let registry = home.registry                                    // reads local.yaml when made
        try home.write("[remote \"origin\"]\n\turl = git@github.com:acme/shop.git\n", "code/shop/.git/config")
        try await registry.add(Space(id: "sp", name: "sp"))
        try await registry.add(Project(id: "pr", space: "sp", name: "pr"))
        try await registry.assign(repo, to: "pr")
        try await registry.add(Service(id: "kafka", name: "Kafka", kind: "kafka", aliases: ["hyper-kafka"]), to: "pr")
        let compose = "services:\n  api:\n    build: .\n    environment:\n      KAFKA: hyper-kafka:9092\n"
        try home.write(compose + "      EVENTS_TOPIC_OUT: events\n", "code/shop/docker-compose.yml")

        let first = try Scanner.scan(registry: registry, store: home.store)
        #expect(first.repos[0].new.count == 2)
        #expect(await registry.pending().isEmpty)                       // a scan alone writes nothing

        try Scanner.write(first, registry: registry)
        let pending = await registry.pending()
        #expect(Set(pending.map(\.path)) == ["projects/pr/services/shop-api/service.yaml", "projects/pr/services/shop-api/links.yaml"])
        #expect(pending.allSatisfy { $0.state == "new" })
        #expect(registry.links(of: "shop-api").map(\.origin) == ["derived:docker-compose.yml", "derived:docker-compose.yml"])

        let second = try Scanner.scan(registry: registry, store: home.store).repos[0]
        #expect(second.services.isEmpty && second.new.isEmpty && second.gone.isEmpty)
        #expect(second.present == first.repos[0].new)

        // The variable is gone from the file: the link is reported and left alone.
        try home.write(compose, "code/shop/docker-compose.yml")
        let third = try Scanner.scan(registry: registry, store: home.store).repos[0]
        #expect(third.gone == [.init(from: "shop-api", link: Link(to: "kafka", via: "topic", what: "events", access: "write", origin: "derived:docker-compose.yml"))])
        #expect(third.present.count == 1 && third.new.isEmpty)
        try Scanner.write(Scanner.scan(registry: registry, store: home.store), registry: registry)
        #expect(registry.links(of: "shop-api").count == 2)
    }

    @Test func aRejectedLinkLeavesTheCatalogueAndIsNotOfferedAgain() throws {
        let home = try catalogue(["github.com/acme/shop"])
        let registry = home.registry
        try card(home, Service(id: "kafka", name: "Kafka", kind: "kafka", aliases: ["hyper-kafka"]))
        try home.write("services:\n  api:\n    build: .\n    environment:\n      KAFKA: hyper-kafka:9092\n      A_TOPIC_OUT: a\n      B_TOPIC_OUT: b\n",
                       "code/shop/docker-compose.yml")
        try Scanner.write(Scanner.scan(registry: registry, store: home.store), registry: registry)
        #expect(registry.links(of: "shop-api").map(\.via) == ["network", "topic", "topic"])

        // A topic is told apart by `what`: rejecting `a` keeps `b`.
        let files = try registry.reject(Link(to: "kafka", via: "topic", what: "a"), from: "shop-api", why: "only b is produced", origin: "code:x.py")
        #expect(files.map(\.lastPathComponent) == ["links.yaml", "rejected.yaml"])
        #expect(registry.links(of: "shop-api").compactMap(\.what) == ["b"])
        #expect(registry.rejected(of: "shop-api") == [RejectedLink(to: "kafka", via: "topic", what: "a", why: "only b is produced", origin: "code:x.py")])
        let second = try Scanner.scan(registry: registry, store: home.store).repos[0]
        #expect(second.new.isEmpty && second.present.count == 2)
        #expect(second.rejected.map(\.link.what) == ["a"])

        // Without `via` every way to the service is refused, and a topic needs a broker link.
        _ = try registry.reject(Link(to: "kafka"), from: "shop-api", why: "no Kafka client", origin: "manual")
        #expect(registry.links(of: "shop-api").isEmpty)
        let third = try Scanner.scan(registry: registry, store: home.store).repos[0]
        #expect(third.new.isEmpty && third.present.isEmpty && third.rejected.map(\.link.via) == ["network", "topic"])
        #expect(third.unknown.map(\.topic) == ["b"])
        try Scanner.write(Scanner.scan(registry: registry, store: home.store), registry: registry)
        #expect(registry.links(of: "shop-api").isEmpty)

        #expect(try registry.unreject(Link(to: "kafka", via: "http"), from: "shop-api") == nil)
        _ = try registry.unreject(Link(to: "kafka"), from: "shop-api")
        _ = try registry.unreject(Link(to: "kafka", via: "topic", what: "a"), from: "shop-api")
        #expect(registry.rejected(of: "shop-api").isEmpty)
        #expect(try Scanner.scan(registry: registry, store: home.store).repos[0].new.count == 3)
    }

    @Test func namesKeepTheirOrderThroughYAML() throws {
        let link = Link(to: "ch", names: ["Z_URL": "CH_URL", "A_USER": "CH_USER", "M_DB": "CH_DATABASE"])
        let text = try Registry.yaml([link])
        #expect(text.range(of: "Z_URL")!.lowerBound < text.range(of: "A_USER")!.lowerBound)
        #expect(try YAMLDecoder().decode([Link].self, from: text) == [link])
    }

    /// The CLI an agent runs: `link add --origin code:… --no-commit` leaves the file for the user.
    @Test func linkAddForAgentsStaysUncommitted() async throws {
        let home = TempHome()
        let registry = home.registry
        try await registry.add(Space(id: "sp", name: "sp"))
        try await registry.add(Project(id: "pr", space: "sp", name: "pr"))
        try await registry.add(Service(id: "a", name: "a", kind: "http"), to: "pr")
        try await registry.add(Service(id: "b", name: "b", kind: "http"), to: "pr")
        let binary = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/debug/practicesctl")
        let process = Process()
        process.executableURL = binary
        process.arguments = ["link", "add", "a", "b", "--via", "http", "--origin", "code:src/client.py", "--no-commit"]
        process.environment = ProcessInfo.processInfo.environment.merging(["PRACTICES_HOME": home.url.path]) { $1 }
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(registry.links(of: "a").map(\.origin) == ["code:src/client.py"])
        #expect(await registry.pending().map(\.path) == ["projects/pr/services/a/links.yaml"])
    }

    @Test func doctorAndCodeSearchWalkEverySearchRoot() async throws {
        let home = TempHome()
        try home.write("roots: [\(home.url.path)/one, \(home.url.path)/two]\n", "local.yaml")
        try home.place(Service(id: "pg", name: "pg", kind: "postgres", keys: [.init(name: "PG_PASSWORD")]))
        try home.store.set("hunter2hunter2", key: "PG_PASSWORD", service: "pg", env: "prod")
        try home.write("PG_PASSWORD=old-password-1\n", "one/a/.env")
        try home.write("see hunter2hunter2 here", "two/b/NOTES.md")
        try home.write("x = 'needle-word'\n", "one/a/a.py")
        try home.write("y = 'needle-word'\n", "two/b/b.py")
        #expect(try await Doctor.run(registry: home.registry, store: home.store).map(\.kind) == [.leak, .drift])
        #expect(await ProjectCode.search("needle-word", registry: home.registry).hits.count == 2)
    }
}
