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
