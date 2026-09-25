import Testing
import Foundation
import Yams
@testable import PracticesCore

/// A throwaway home per test: registry and secrets never touch ~/.practices.
struct TempHome {
    let url: URL
    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("practices-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    var registry: Registry { Registry(root: url.appendingPathComponent("registry")) }
    var store: SecretStore { SecretStore(url: url.appendingPathComponent("secrets.json")) }
    func write(_ text: String, _ relative: String) throws {
        let file = url.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }
}

@Suite struct TemplateTests {
    @Test func renderAndMissing() throws {
        #expect(Template.keys(in: "${A}:${B}") == ["A", "B"])
        #expect(try Template.render("${A}:${B}", values: ["A": "h", "B": "1"]) == "h:1")
        #expect(throws: Template.Missing.self) { try Template.render("${A}:${B}", values: ["A": "h", "B": ""]) }
    }

    @Test func dotenv() {
        let pairs = ConnectorsImport.parseDotenv("""
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
        #expect(SourceRef(parsing: "kafka@dev") == SourceRef(source: "kafka", env: "dev"))
        #expect(SourceRef(parsing: "kafka").env == nil)
    }
}

@Suite struct SourceYAMLTests {
    @Test func roundTripKeepsBareKeys() throws {
        let source = Source(id: "s", name: "Имя", kind: "postgres", keys: [.init(name: "HOST"), .init(name: "PASSWORD"),
                            .init(name: "PORT", description: "порт")], targets: [.init(id: "t", address: "${HOST}:${PORT}")])
        let text = try Registry.yaml(source)
        #expect(text.contains("- HOST"))
        #expect(text.contains("Имя"))
        let back = try YAMLDecoder().decode(Source.self, from: text)
        #expect(back == source)
        #expect(back.keys[1].secret)
        #expect(!back.keys[0].secret)
    }

    @Test func minimalSourceDecodes() throws {
        let s = try YAMLDecoder().decode(Source.self, from: "id: x\nkeys: [A_TOKEN]\n")
        #expect(s.name == "x" && s.envs == ["prod"] && s.keys[0].secret)
    }
}

@Suite struct StoreAndRunTests {
    @Test func secretsFileIsPrivate() throws {
        let home = TempHome()
        try home.store.set("v", key: "K", source: "s", env: "prod")
        let attrs = try FileManager.default.attributesOfItem(atPath: home.store.url.path)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)
        #expect(try home.store.values(source: "s", env: "prod") == ["K": "v"])
    }

    @Test func conflictingKeysAreRefused() throws {
        let home = TempHome()
        try home.registry.save(Source(id: "a", name: "a", kind: "x", keys: [.init(name: "SHARED")]))
        try home.registry.save(Source(id: "b", name: "b", kind: "x", envs: ["prod", "dev"], keys: [.init(name: "SHARED"), .init(name: "ONLY_B")]))
        try home.store.set("1", key: "SHARED", source: "a", env: "prod")
        try home.store.set("2", key: "SHARED", source: "b", env: "prod")
        try home.store.set("1", key: "SHARED", source: "b", env: "dev")
        #expect(throws: RunEnvironment.Conflict.self) {
            try RunEnvironment.resolve([.init(source: "a"), .init(source: "b")], registry: home.registry, store: home.store)
        }
        let ok = try RunEnvironment.resolve([.init(source: "a"), .init(source: "b", env: "dev")], registry: home.registry, store: home.store)
        #expect(ok.values == ["SHARED": "1"])
        #expect(ok.missing["b@dev"] == ["ONLY_B"])
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
        try home.registry.save(Source(id: "pg", name: "pg", kind: "postgres", keys: [.init(name: "PG_HOST"), .init(name: "PG_PASSWORD")]))
        try home.store.setAll(["PG_HOST": "db.local", "PG_PASSWORD": "hunter2hunter2"], source: "pg", env: "prod")
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
    }

    @Test func planAndWriteWithAliases() async throws {
        let home = TempHome()
        try home.registry.save(Source(id: "ch", name: "ch", kind: "clickhouse", envs: ["prod", "dev"],
                                      keys: [.init(name: "CH_URL"), .init(name: "CH_PASSWORD")]))
        try home.store.setAll(["CH_URL": "http://dev", "CH_PASSWORD": "secret-dev"], source: "ch", env: "dev")
        let project = home.url.appendingPathComponent("proj")
        try home.write("BFF_CH_PASSWORD=old\nOTHER=keep\n", "proj/.env")
        let file = ManagedFile(path: ".env", sources: [SourceRef(source: "ch", env: "dev")], env: ["BFF_CH_PASSWORD": "CH_PASSWORD"])
        let plan = try EnvFiles.plan(file, project: project, registry: home.registry, store: home.store)
        #expect(Set(plan.map { "\($0.variable):\($0.state.rawValue)" }) == ["CH_URL:new", "BFF_CH_PASSWORD:changed"])
        try await EnvFiles.write(file, project: project, registry: home.registry, store: home.store)
        let written = try String(contentsOf: project.appendingPathComponent(".env"), encoding: .utf8)
        #expect(written.hasPrefix("BFF_CH_PASSWORD=secret-dev\nOTHER=keep\n"))
        #expect(written.contains("CH_URL=http://dev"))
        #expect(!written.contains("CH_PASSWORD=secret-dev\n\(EnvFiles.blockEnd)"))   // alias replaces the registry name
        let after = try EnvFiles.plan(file, project: project, registry: home.registry, store: home.store)
        #expect(after.allSatisfy { $0.state == .same })
    }

    @Test func refusesAFileGitWouldCommit() async throws {
        let home = TempHome()
        try home.registry.save(Source(id: "s", name: "s", kind: "x", keys: [.init(name: "API_TOKEN")]))
        try home.store.set("value1", key: "API_TOKEN", source: "s", env: "prod")
        let project = home.url.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        _ = try await Shell.run("git", ["-C", project.path, "init", "-q"])
        // Not `.env`: a global gitignore (this machine has one) may already ignore that.
        let file = ManagedFile(path: "app.secrets", sources: [SourceRef(source: "s")])
        await #expect(throws: EnvFiles.Refused.self) {
            try await EnvFiles.write(file, project: project, registry: home.registry, store: home.store)
        }
        try "app.secrets\n".write(to: project.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try await EnvFiles.write(file, project: project, registry: home.registry, store: home.store)
        let attrs = try FileManager.default.attributesOfItem(atPath: project.appendingPathComponent("app.secrets").path)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)
    }
}

@Suite struct NamesTests {
    @Test func namesAreFoundByValueAcrossProjects() throws {
        let home = TempHome()
        try home.registry.save(Source(id: "pg", name: "pg", kind: "postgres", keys: [.init(name: "XK_PG_PASSWORD")]))
        try home.store.set("very-secret-pw", key: "XK_PG_PASSWORD", source: "pg", env: "prod")
        try home.write("SRC_PG_PASSWORD=very-secret-pw\n", "projects/a/.env")
        try home.write("DB_PASS=very-secret-pw\nOTHER=x\n", "projects/b/.env.local")
        try home.write("SRC_PG_PASSWORD=very-secret-pw\n", "projects/c/.env")
        let table = try Names.scan(root: home.url.appendingPathComponent("projects").path, registry: home.registry, store: home.store)
        let names = table["pg"]?["XK_PG_PASSWORD"] ?? []
        #expect(names.map(\.name) == ["SRC_PG_PASSWORD", "DB_PASS"])
        #expect(names[0].files == ["a/.env", "c/.env"])
    }
}
