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
        #expect(try String(contentsOf: file, encoding: .utf8).contains("practicesctl setup status"))

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

    @Test func toolNotFoundIsSkipped() throws {
        let base = TempHome().url
        let done = try Setup.agents(home: AgentHome(base: base, practices: base))
        #expect(done.allSatisfy { $0.contains("not found") })
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
        #expect(Set(json.keys) == ["roots", "defaultRoots", "spaces", "command", "commandInstalled", "tools", "projectBlocks"])
        #expect(json["defaultRoots"] as? Bool == false)
        let root = (json["roots"] as! [[String: Any]])[0]
        #expect(root["clones"] as? Int == 0 && root["exists"] as? Bool == true)
        let space = (json["spaces"] as! [[String: Any]])[0]
        #expect(space["id"] as? String == "sp" && space["remote"] == nil)
        #expect((space["git"] as? [String: Any])?["uncommitted"] as? Int == 0)
        let tools = json["tools"] as! [[String: Any]]
        #expect(tools.map { $0["tool"] as? String } == ["claude", "codex", "cursor"])
        #expect(tools[0]["found"] as? Bool == true && tools[0]["mcp"] as? Bool == false && tools[0]["instructions"] as? String == "absent")
        #expect(tools[1]["found"] as? Bool == false)
    }
}

@Suite struct SpaceSharingTests {
    func git(_ dir: URL, _ args: String...) async throws -> String { try await Shell.run("git", ["-C", dir.path] + args) }

    @Test func remotePushCloneAndPull() async throws {
        let mine = TempHome(), theirs = TempHome()
        let bare = mine.url.appendingPathComponent("shared/sp.git")
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        _ = try await git(bare, "init", "-q", "--bare")

        try await mine.registry.add(Space(id: "sp", name: "Space"))
        try await mine.registry.setRemote(ofSpace: "sp", to: bare.path)
        try await mine.registry.setRemote(ofSpace: "sp", to: bare.path)          // set-url the second time
        try await mine.registry.push(space: "sp")
        let branch = try #require(try await mine.registry.spaceStates().first?.git?.branch)
        _ = try await git(bare, "symbolic-ref", "HEAD", "refs/heads/\(branch)")
        let state = try await mine.registry.spaceStates()[0]
        #expect(state.remote == bare.path && state.git?.ahead == 0 && state.git?.behind == 0)

        #expect(try await theirs.registry.clone(space: bare.path) == "sp")
        #expect(try theirs.registry.space("sp").name == "Space")
        await #expect(throws: Registry.Failure.self) { try await theirs.registry.clone(space: bare.path) }   // exists

        try await mine.registry.add(Project(id: "pr", space: "sp", name: "Project"))
        try await mine.registry.push(space: "sp")
        try await theirs.registry.pull(space: "sp")
        #expect(try theirs.registry.project("pr").name == "Project")

        try "draft".write(to: theirs.registry.dir(ofSpace: "sp").appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        await #expect(throws: Registry.Failure.self) { try await theirs.registry.pull(space: "sp") }
    }

    @Test func cloneWithoutSpaceYamlIsRemoved() async throws {
        let home = TempHome()
        let repo = home.url.appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        _ = try await git(repo, "init", "-q")
        try "x".write(to: repo.appendingPathComponent("README"), atomically: true, encoding: .utf8)
        _ = try await git(repo, "add", "README")
        _ = try await git(repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "x")
        await #expect(throws: Registry.Failure.self) { try await home.registry.clone(space: repo.path + "/.git", as: "other") }
        #expect(!FileManager.default.fileExists(atPath: home.registry.root.appendingPathComponent("other").path))
        await #expect(throws: Registry.Failure.self) { try await home.registry.push(space: "missing") }
    }
}
