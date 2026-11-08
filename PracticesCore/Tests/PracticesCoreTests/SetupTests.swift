import Testing
import Foundation
@testable import PracticesCore

@Suite struct RootsTests {
    @Test func addRemoveAndRefusals() throws {
        let home = TempHome()
        let projects = home.url.appendingPathComponent("code")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try home.registry.addRoot(projects.path + "/")
        #expect(home.registry.local.roots.map { LocalConfig.expand($0) } == [projects.standardizedFileURL.path])
        #expect(throws: Registry.Failure.self) { try home.registry.addRoot(projects.path) }                        // listed
        #expect(throws: Registry.Failure.self) { try home.registry.addRoot(home.url.appendingPathComponent("nope").path) }
        #expect(throws: Registry.Failure.self) { try home.registry.addRoot("/") }
        #expect(throws: Registry.Failure.self) { try home.registry.addRoot("~") }
        try home.registry.removeRoot(projects.path)
        #expect(home.registry.local.roots.isEmpty)
        #expect(throws: Registry.Failure.self) { try home.registry.removeRoot(projects.path) }
    }
}

@Suite struct AgentSetupTests {
    @Test func blockCreateReplaceOutdated() throws {
        let file = TempHome().url.appendingPathComponent("a/CLAUDE.md")
        #expect(AgentInstructions.state(of: file) == "absent")
        try AgentInstructions.write(to: file)
        #expect(AgentInstructions.state(of: file) == "current")
        #expect(try String(contentsOf: file, encoding: .utf8).contains("Проекты ваших пространств описаны"))
        #expect(try String(contentsOf: file, encoding: .utf8).contains("`get_conventions`"))
        let v8 = AgentInstructions.block(spaces: [])
        #expect(v8.hasPrefix("<!-- practices:begin v8 -->\n"))
        #expect(v8.contains("`get_service` показывает роль сервиса (`role`)"))
        #expect(v8.contains("только после\n  подтверждения пользователя."))
        #expect(v8.split(separator: "\n").allSatisfy { $0.count <= 100 })

        try "# Mine\nkeep me\n\n<!-- practices:begin v0 -->\nold\n<!-- practices:end -->\nafter\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(AgentInstructions.state(of: file) == "outdated(v0)")
        try AgentInstructions.write(to: file)
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(AgentInstructions.state(of: file) == "current")
        #expect(text.hasPrefix("# Mine\nkeep me\n\n<!-- practices:begin v\(AgentInstructions.version) -->"))
        #expect(text.hasSuffix("<!-- practices:end -->\nafter\n"))
        #expect(!text.contains("old"))
        #expect(text.components(separatedBy: "practices:begin").count == 2)

        try "no newline".write(to: file, atomically: true, encoding: .utf8)
        try AgentInstructions.write(to: file)
        #expect(try String(contentsOf: file, encoding: .utf8).hasPrefix("no newline\n\n<!-- practices:begin"))
    }

    @Test func spacesAreNamedInTheBlock() throws {
        #expect(AgentInstructions.block(spaces: ["X-Keeper", "SphereTele"]).contains("Проекты пространств X-Keeper и SphereTele описаны"))
        #expect(AgentInstructions.block(spaces: ["A", "B", "C"]).contains("пространств A, B и C описаны"))
        #expect(AgentInstructions.block(spaces: ["demo"]).contains("Проекты пространства demo описаны"))
        #expect(AgentInstructions.block(spaces: []).contains("Проекты ваших пространств описаны"))
        #expect(!AgentInstructions.block(spaces: []).contains("{{"))
        let file = TempHome().url.appendingPathComponent("CLAUDE.md")
        try "<!-- practices:begin v4 -->\nold\n<!-- practices:end -->\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(AgentInstructions.state(of: file) == "outdated(v4)")
    }

    @Test func mcpRegistrationKeepsOtherServers() throws {
        let base = TempHome().url
        let home = AgentHome(base: base, practices: base.appendingPathComponent(".practices"))
        for tool in AgentTool.allCases { try FileManager.default.createDirectory(at: home.dir(tool), withIntermediateDirectories: true) }
        try #"{"numStartups": 3, "mcpServers": {"other": {"command": "x", "args": ["y"]}}}"#
            .write(to: home.mcpConfig(.claude), atomically: true, encoding: .utf8)
        try "model = \"o3\"\n\n[mcp_servers.practices]\ncommand = \"/old\"\nargs = [\"mcp\"]\n\n[mcp_servers.other]\ncommand = \"x\"\n"
            .write(to: home.mcpConfig(.codex), atomically: true, encoding: .utf8)
        #expect(!MCPRegistration.isRegistered(.claude, home: home))

        let done = try Setup.agents(home: home)
        #expect(done.count == 5)       // three registrations, two instruction files (Cursor has none)
        for tool in AgentTool.allCases { #expect(MCPRegistration.isRegistered(tool, home: home)) }

        let claude = try JSONSerialization.jsonObject(with: Data(contentsOf: home.mcpConfig(.claude))) as! [String: Any]
        #expect(claude["numStartups"] as? Int == 3)
        let servers = claude["mcpServers"] as! [String: Any]
        #expect((servers["other"] as? [String: Any])?["command"] as? String == "x")
        #expect((servers["practices"] as? [String: Any])?["args"] as? [String] == ["mcp"])

        let codex = try String(contentsOf: home.mcpConfig(.codex), encoding: .utf8)
        #expect(codex.hasPrefix("model = \"o3\"\n"))
        #expect(!codex.contains("/old"))
        #expect(codex.contains("[mcp_servers.other]\ncommand = \"x\""))
        #expect(codex.components(separatedBy: "[mcp_servers.practices]").count == 2)
        #expect(AgentInstructions.state(of: home.instructions(.codex)!) == "current")
    }

    @Test func agentHomeFollowsEnvironment() {
        let base = TempHome().url
        setenv("PRACTICES_AGENT_HOME", base.path, 1)
        defer { unsetenv("PRACTICES_AGENT_HOME") }
        #expect(AgentHome().base.path == base.path)
        #expect(AgentHome().mcpConfig(.claude).path == base.appendingPathComponent(".claude.json").path)
    }

    @Test func toolNotFoundIsSkipped() throws {
        let base = TempHome().url
        let done = try Setup.agents(home: AgentHome(base: base, practices: base))
        #expect(done.allSatisfy { $0.state == "not found" })
        #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent(".claude.json").path))
    }

    @Test func statusJSONShape() async throws {
        let home = TempHome()
        try await home.registry.add(Space(id: "sp", name: "Space"))
        let agents = AgentHome(base: home.url, practices: home.url)
        try FileManager.default.createDirectory(at: agents.dir(.claude), withIntermediateDirectories: true)
        let code = home.url.appendingPathComponent("code")
        try FileManager.default.createDirectory(at: code, withIntermediateDirectories: true)
        try home.registry.addRoot(code.path)

        let status = try await Setup.status(registry: home.registry, home: agents)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(status)) as! [String: Any]
        #expect(Set(json.keys) == ["roots", "spaces", "command", "commandInstalled", "commandState", "tools", "projectBlocks"])     // scope nil: no block anywhere
        let root = (json["roots"] as! [[String: Any]])[0]
        #expect(root["clones"] as? Int == 0 && root["exists"] as? Bool == true)
        let space = (json["spaces"] as! [[String: Any]])[0]
        #expect(space["id"] as? String == "sp" && space["remote"] == nil && space["uncommitted"] as? Int == 0)
        let tools = json["tools"] as! [[String: Any]]
        #expect(tools.map { $0["tool"] as? String } == ["claude", "codex", "cursor"])
        #expect(tools[0]["found"] as? Bool == true && tools[0]["mcp"] as? Bool == false && tools[0]["instructions"] as? String == "absent")
        #expect(tools[1]["found"] as? Bool == false)
    }

    /// Project `pr` with two repositories, each cloned under `code/`; Claude Code found.
    func catalogue() throws -> (TempHome, AgentHome, [URL]) {
        let home = TempHome()
        let repos = ["github.com/o/one", "github.com/o/two"]
        try home.write("roots: [\(home.url.path)/code]\n", "local.yaml")
        try home.write("name: sp\n", "spaces/sp/space.yaml")
        try home.write(Registry.yaml(Project(id: "pr", space: "sp", name: "pr", repos: repos.map { .init(repo: RepoID($0)!) })),
                       "spaces/sp/projects/pr/project.yaml")
        for repo in repos {
            try home.write("[remote \"origin\"]\n\turl = https://\(repo).git\n", "code/\((repo as NSString).lastPathComponent)/.git/config")
        }
        let agents = AgentHome(base: home.url.appendingPathComponent("user"), practices: home.url)
        try FileManager.default.createDirectory(at: agents.dir(.claude), withIntermediateDirectories: true)
        return (home, agents, ["one", "two"].map { home.url.appendingPathComponent("code/" + $0) })
    }

    @Test func scopeProjectsWritesEveryClone() async throws {
        let (home, agents, clones) = try catalogue()
        #expect(try await Setup.status(registry: home.registry, home: agents).scope == nil)

        let done = try Setup.agents(home: agents, registry: home.registry, scope: .projects)
        #expect(done.filter { $0.state == "written" }.count == 4 && done.filter { $0.state == "written" }.allSatisfy { $0.target == "pr" })
        for clone in clones {
            for name in AgentInstructions.projectFiles { #expect(AgentInstructions.state(of: clone.appendingPathComponent(name)) == "current") }
        }
        #expect(AgentInstructions.state(of: agents.instructions(.claude)!) == "absent")
        #expect(MCPRegistration.isRegistered(.claude, home: agents))
        let status = try await Setup.status(registry: home.registry, home: agents)
        #expect(status.scope == .projects && status.projectBlocks.count == 4)

        #expect(try Setup.agents(home: agents, registry: home.registry, scope: .projects).filter { $0.target == "pr" }.allSatisfy { $0.state == "updated" })
    }

    @Test func scopeGlobalLeavesClones() async throws {
        let (home, agents, clones) = try catalogue()
        _ = try Setup.agents(home: agents, registry: home.registry, scope: .global)
        for clone in clones {
            for name in AgentInstructions.projectFiles { #expect(!FileManager.default.fileExists(atPath: clone.appendingPathComponent(name).path)) }
        }
        #expect(AgentInstructions.state(of: agents.instructions(.claude)!) == "current")
        #expect(try await Setup.status(registry: home.registry, home: agents).scope == .global)
    }

    @Test func writingOneScopeClearsTheOther() async throws {
        let (home, agents, clones) = try catalogue()
        let mine = clones[0].appendingPathComponent("CLAUDE.md")
        _ = try Setup.agents(home: agents, registry: home.registry, scope: .projects)
        try ("# Mine\n\n" + String(contentsOf: mine, encoding: .utf8)).write(to: mine, atomically: true, encoding: .utf8)
        try AgentInstructions.write(to: agents.instructions(.claude)!)
        #expect(try await Setup.status(registry: home.registry, home: agents).scope == .both)

        let global = try Setup.agents(home: agents, registry: home.registry, scope: .global)
        #expect(global.filter { $0.state == "removed" }.count == 4)
        #expect(try String(contentsOf: mine, encoding: .utf8) == "# Mine\n")
        #expect(!FileManager.default.fileExists(atPath: clones[1].appendingPathComponent("AGENTS.md").path))
        #expect(try await Setup.status(registry: home.registry, home: agents).scope == .global)

        let projects = try Setup.agents(home: agents, registry: home.registry, scope: .projects)
        #expect(projects.filter { $0.state == "removed" }.map(\.target) == ["claude"])
        #expect(AgentInstructions.state(of: agents.instructions(.claude)!) == "absent")
        #expect(try await Setup.status(registry: home.registry, home: agents).scope == .projects)
    }

    @Test func scopeProjectsWithoutClonesFails() throws {
        let home = TempHome()
        let agents = AgentHome(base: home.url, practices: home.url)
        try FileManager.default.createDirectory(at: agents.dir(.claude), withIntermediateDirectories: true)
        try home.write("roots: [\(home.url.path)/code]\n", "local.yaml")
        #expect(throws: Registry.Failure.self) { try Setup.agents(home: agents, registry: home.registry, scope: .projects) }
        #expect(!MCPRegistration.isRegistered(.claude, home: agents))      // nothing done before the refusal
    }
}

@Suite struct InstallCommandTests {
    @Test func copiesHelperAndBundleAndLinks() async throws {
        let temp = TempHome().url, fm = FileManager.default
        let helpers = temp.appendingPathComponent("Practices.app/Contents/Helpers")
        let bundle = helpers.appendingPathComponent("PracticesCore_PracticesCore.bundle")
        try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
        try "v1".write(to: bundle.appendingPathComponent("AgentInstructions.md"), atomically: true, encoding: .utf8)
        let helper = helpers.appendingPathComponent("practicesctl")
        try "#!/bin/sh\necho new\n".write(to: helper, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let home = temp.appendingPathComponent(".practices"), links = temp.appendingPathComponent("local-bin")

        try await Setup.installCommand(from: helper, home: home, links: links, fallbackUV: nil)
        try "#!/bin/sh\necho newer\n".write(to: helper, atomically: true, encoding: .utf8)
        let written = try await Setup.installCommand(from: helper, home: home, links: links, fallbackUV: nil)       // over an installed copy

        let command = home.appendingPathComponent("bin/practicesctl")
        #expect(written.map(\.lastPathComponent) == ["practicesctl", "PracticesCore_PracticesCore.bundle", "practicesctl"])
        #expect(try String(contentsOf: command, encoding: .utf8).contains("newer"))
        #expect(fm.isExecutableFile(atPath: command.path))
        #expect(fm.fileExists(atPath: home.appendingPathComponent("bin/PracticesCore_PracticesCore.bundle/AgentInstructions.md").path))
        #expect(try fm.destinationOfSymbolicLink(atPath: links.appendingPathComponent("practicesctl").path) == command.path)

        // uv beside the helper goes too; the installed copy installing itself keeps its files.
        let uv = helpers.appendingPathComponent("uv")
        try "#!/bin/sh\necho uv\n".write(to: uv, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: uv.path)
        let withUV = try await Setup.installCommand(from: helper, home: home, links: links, fallbackUV: nil)
        #expect(withUV.map(\.lastPathComponent) == ["practicesctl", "PracticesCore_PracticesCore.bundle", "uv", "practicesctl"])
        try await Setup.installCommand(from: command, home: home, links: links, fallbackUV: nil)
        #expect(try String(contentsOf: command, encoding: .utf8).contains("newer"))
        #expect(fm.isExecutableFile(atPath: home.appendingPathComponent("bin/uv").path))

        try fm.removeItem(at: bundle)
        await #expect(throws: Registry.Failure.self) { try await Setup.installCommand(from: helper, home: home, links: links) }
    }
}

@Suite struct CommandStateTests {
    @Test func comparesInstalledCopyWithHelper() throws {
        let home = TempHome(), fm = FileManager.default
        let helper = home.url.appendingPathComponent("Helpers/practicesctl")
        try home.write("#!/bin/sh\necho v2\n", "Helpers/practicesctl")
        #expect(Setup.commandState(helper: helper, home: home.url) == .missing)
        try home.write("#!/bin/sh\necho v1\n", "bin/practicesctl")
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.url.appendingPathComponent("bin/practicesctl").path)
        #expect(Setup.commandState(helper: helper, home: home.url) == .outdated)
        try home.write("#!/bin/sh\necho v2\n", "bin/practicesctl")
        #expect(Setup.commandState(helper: helper, home: home.url) == .current)
        // The app's uv counts too: missing or different beside the installed CLI is outdated.
        try home.write("uv 2", "Helpers/uv")
        #expect(Setup.commandState(helper: helper, home: home.url) == .outdated)
        try home.write("uv 2", "bin/uv")
        #expect(Setup.commandState(helper: helper, home: home.url) == .current)
    }

    @Test func uvIsTheInstalledOneFirst() throws {
        let home = TempHome(), fm = FileManager.default
        let app = home.url.appendingPathComponent("Practices.app")
        try home.write("#!/bin/sh\n", "Practices.app/Contents/Helpers/uv")
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: app.appendingPathComponent("Contents/Helpers/uv").path)
        #expect(PythonRuntime.uv(home: home.url, app: app) == app.appendingPathComponent("Contents/Helpers/uv").path)
        try home.write("#!/bin/sh\n", "bin/uv")
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.url.appendingPathComponent("bin/uv").path)
        #expect(PythonRuntime.uv(home: home.url, app: app) == home.url.appendingPathComponent("bin/uv").path)
    }
}
