import Testing
import Foundation
@testable import PracticesCore

@Suite struct PracticeTests {
    @Test func usesAreFound() {
        let code = """
            from practices import use
            meta = use("xkeeper-pg/device-meta")
            tele = use( 'xkdb/get-chunk-multi' )
            # use("not/a-call") in a comment still counts, which only over-provisions values
            """
        #expect(PracticeStore.uses(in: code) == ["xkeeper-pg/device-meta", "xkdb/get-chunk-multi", "not/a-call"])
    }

    @Test func practiceRefs() {
        #expect(Practice(ref: "xkdb/get-chunk-multi").source == "xkdb")
        #expect(Practice(ref: "chains/device-telemetry").source == nil)
        #expect(Practice(ref: "chains/device-telemetry").isChain)
    }

    @Test func scrubMasksOnlyLongValues() {
        let runner = PracticeRunner()
        let out = runner.scrub("password=hunter2hunter2 port=5432", values: ["P": "hunter2hunter2", "PORT": "5432"])
        #expect(out == "password=*** port=5432")
    }

    @Test func bigIntegersStayExact() throws {
        let value = try JSONDecoder().decode([JSONValue].self, from: Data("[-4896437846419584425, 1.5, 3]".utf8))
        #expect(value[0].cellText == "-4896437846419584425")
        #expect(value[1].cellText == "1.5")
        #expect(value[2].cellText == "3")
    }

    @Test func fieldsAreLearnedPerStepSource() async throws {
        let home = TempHome()
        try await home.registry.ensureRepository()
        try home.registry.save(Source(id: "xkdb", name: "x", kind: "socket"))
        try home.registry.saveFields([FieldDoc(path: "extra.acc_motion", type: "int", meaning: "kept")], of: "xkdb")
        let json = """
            {"ok": true, "ms": 1, "steps": [{"ref": "xkdb/get", "ok": true, "ms": 1,
              "schema": [{"path": "extra.acc_motion", "type": "int", "present": 1, "seen": 1},
                         {"path": "extra.te", "type": "float", "present": 1, "seen": 1}]}]}
            """
        let result = try JSONDecoder().decode(PracticeResult.self, from: Data(json.utf8))
        let gained = await FieldsLearner.learn(from: result, practice: Practice(ref: "chains/c"), registry: home.registry)
        #expect(gained == ["xkdb": 1])
        let fields = home.registry.fields(of: "xkdb")
        #expect(fields.map(\.path) == ["extra.acc_motion", "extra.te"])
        #expect(fields[0].meaning == "kept")
    }
}
