import Foundation

/// The agent tools Practices registers itself in.
public enum AgentTool: String, CaseIterable, Codable, Sendable {
    case claude, codex, cursor
}

/// Where each agent tool keeps its files. `base` is the user's home; tests point it at a temp dir.
public struct AgentHome: Sendable {
    public let base: URL
    /// The `~/.practices` whose `bin/practicesctl` the agents are told to run.
    public let practices: URL

    public init(base: URL = URL(fileURLWithPath: NSHomeDirectory()), practices: URL = PracticesHome.url) {
        self.base = base
        self.practices = practices
    }

    public var command: String { practices.appendingPathComponent("bin/practicesctl").path }

    public func dir(_ tool: AgentTool) -> URL { base.appendingPathComponent("." + tool.rawValue) }

    public func found(_ tool: AgentTool) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: dir(tool).path, isDirectory: &isDir) && isDir.boolValue
    }

    /// The global instructions file; Cursor keeps its rules in its own settings, not in a file here.
    public func instructions(_ tool: AgentTool) -> URL? {
        switch tool {
        case .claude: dir(.claude).appendingPathComponent("CLAUDE.md")
        case .codex: dir(.codex).appendingPathComponent("AGENTS.md")
        case .cursor: nil
        }
    }

    public func mcpConfig(_ tool: AgentTool) -> URL {
        switch tool {
        case .claude: base.appendingPathComponent(".claude.json")
        case .codex: dir(.codex).appendingPathComponent("config.toml")
        case .cursor: dir(.cursor).appendingPathComponent("mcp.json")
        }
    }
}

/// The instruction block written into agents' CLAUDE.md / AGENTS.md between markers.
public enum AgentInstructions {
    /// Bump when the text of `Resources/AgentInstructions.md` changes: older blocks show as outdated.
    public static let version = 5
    public static let projectFiles = ["CLAUDE.md", "AGENTS.md"]

    public static var text: String {
        Bundle.module.url(forResource: "AgentInstructions", withExtension: "md")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }

    /// `{{spaces}}` names the spaces at the time of writing: «пространств X-Keeper и SphereTele».
    public static func block(spaces: [String]) -> String {
        let names = spaces.isEmpty ? "ваших пространств"
            : "пространств " + (spaces.count == 1 ? spaces[0] : spaces.dropLast().joined(separator: ", ") + " и " + spaces.last!)
        return "<!-- practices:begin v\(version) -->\n" + text.trimmingCharacters(in: .newlines).replacingOccurrences(of: "{{spaces}}", with: names)
            + "\n<!-- practices:end -->\n"
    }

    static let pattern = try! NSRegularExpression(pattern: #"<!-- practices:begin v(\d+) -->[\s\S]*?<!-- practices:end -->\n?"#)

    /// `absent`, `current` or `outdated(vM)`.
    public static func state(of file: URL) -> String {
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              let match = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text), let found = Int(text[range])
        else { return "absent" }
        return found == version ? "current" : "outdated(v\(found))"
    }

    /// Replaces the block of any version, or appends it after a blank line; creates the file if needed.
    public static func write(to file: URL, spaces: [String] = []) throws {
        let ours = block(spaces: spaces)
        var text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        if let match = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let range = Range(match.range, in: text) {
            text.replaceSubrange(range, with: ours)
        } else {
            if !text.isEmpty { text += text.hasSuffix("\n") ? "\n" : "\n\n" }
            text += ours
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }
}

/// Registration of `practicesctl mcp` in the agents' MCP configuration.
public enum MCPRegistration {

    public static func isRegistered(_ tool: AgentTool, home: AgentHome) -> Bool {
        let file = home.mcpConfig(tool)
        guard let data = try? Data(contentsOf: file) else { return false }
        if tool == .codex {
            return table(in: String(decoding: data, as: UTF8.self)).map { $0.contains("command = \(quoted(home.command))") } ?? false
        }
        let entry = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["mcpServers"] as? [String: Any]
        return (entry?["practices"] as? [String: Any])?["command"] as? String == home.command
    }

    public static func register(_ tool: AgentTool, home: AgentHome) throws {
        let file = home.mcpConfig(tool)
        let existing = try? Data(contentsOf: file)
        let out: Data
        if tool == .codex {
            var text = existing.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let ours = "[mcp_servers.practices]\ncommand = \(quoted(home.command))\nargs = [\"mcp\"]\n"
            if let range = tableRange(in: text) {
                text.replaceSubrange(range, with: ours)
            } else {
                if !text.isEmpty { text += text.hasSuffix("\n") ? "\n" : "\n\n" }
                text += ours
            }
            out = Data(text.utf8)
        } else {
            var root: [String: Any] = [:]
            if let existing, !existing.isEmpty {
                // A file we cannot read is left alone rather than replaced by ours.
                guard let parsed = (try? JSONSerialization.jsonObject(with: existing)) as? [String: Any] else {
                    throw Registry.Failure("\(file.path) is not a JSON object; not changed")
                }
                root = parsed
            }
            var servers = root["mcpServers"] as? [String: Any] ?? [:]
            servers["practices"] = ["command": home.command, "args": ["mcp"]]
            root["mcpServers"] = servers
            out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try out.write(to: file, options: .atomic)
    }

    static func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// `[mcp_servers.practices]` up to the next table header.
    static func tableRange(in text: String) -> Range<String.Index>? {
        guard let start = text.range(of: "(?m)^\\[mcp_servers\\.practices\\][^\\n]*\\n?", options: .regularExpression) else { return nil }
        let next = text.range(of: "(?m)^\\[", options: .regularExpression, range: start.upperBound..<text.endIndex)
        return start.lowerBound..<(next?.lowerBound ?? text.endIndex)
    }

    static func table(in text: String) -> Substring? { tableRange(in: text).map { text[$0] } }
}

/// Where `setup agents` writes the instruction block: the tools' global files, or CLAUDE.md and
/// AGENTS.md of every clone of the catalogue's projects. The MCP server is registered globally either way.
public enum InstructionScope: String, CaseIterable, Codable, Sendable {
    case global, projects
}

/// A thing `setup agents` did: `target` is a tool or a project id; `state` is `registered` (MCP),
/// `written` (the file had no block), `updated` (a block was replaced) or `not found` (tool skipped).
public struct SetupWrite: Codable, Sendable {
    public let target: String
    public let file: String
    public let state: String
}

/// What `setup status` shows: is this machine set up (DECISIONS 36).
public struct SetupStatus: Codable, Sendable {
    public struct Root: Codable, Sendable {
        public let path: String
        public let exists: Bool
        public let clones: Int
    }
    public struct Tool: Codable, Sendable {
        public let tool: AgentTool
        public let found: Bool
        public let mcp: Bool
        /// nil — the tool has no instructions file of ours.
        public let instructions: String?
    }
    public struct ProjectBlock: Codable, Sendable {
        public let project: String
        public let clone: String
        public let file: String
        public let state: String
    }
    /// Roots from `local.yaml`; when it lists none, the default one, with `defaultRoots`.
    public let roots: [Root]
    public let defaultRoots: Bool
    public let spaces: [SpaceState]
    public let command: String
    public let commandInstalled: Bool
    public let tools: [Tool]
    public let projectBlocks: [ProjectBlock]
    /// Inferred from the blocks there are: global ones → `global`, only project ones → `projects`, none → nil.
    public let scope: InstructionScope?
}

public enum Setup {

    public static func status(registry: Registry = Registry(), home: AgentHome = AgentHome()) async throws -> SetupStatus {
        let fm = FileManager.default
        let roots = registry.searchRoots.map { path in
            SetupStatus.Root(path: path, exists: fm.fileExists(atPath: path), clones: Repos.clones(roots: [path]).count)
        }
        let tools = AgentTool.allCases.map { tool in
            SetupStatus.Tool(tool: tool, found: home.found(tool), mcp: MCPRegistration.isRegistered(tool, home: home),
                             instructions: home.instructions(tool).map(AgentInstructions.state))
        }
        var blocks: [SetupStatus.ProjectBlock] = []
        for (project, clone) in try projectClones(registry: registry) {
            for name in AgentInstructions.projectFiles {
                let state = AgentInstructions.state(of: URL(fileURLWithPath: clone).appendingPathComponent(name))
                if state != "absent" { blocks.append(.init(project: project, clone: clone, file: name, state: state)) }
            }
        }
        return SetupStatus(roots: roots, defaultRoots: registry.local.roots.isEmpty, spaces: try await registry.spaceStates(),
                           command: home.command, commandInstalled: fm.isExecutableFile(atPath: home.command),
                           tools: tools, projectBlocks: blocks,
                           scope: tools.contains { ($0.instructions ?? "absent") != "absent" } ? .global : blocks.isEmpty ? nil : .projects)
    }

    /// Registers the MCP server for each found tool (all of them unless `tools` names some) and
    /// writes the instruction block: into the tools' global files, or with `.projects` into every
    /// clone of every project (whatever `tools` says — the files are CLAUDE.md and AGENTS.md).
    public static func agents(home: AgentHome = AgentHome(), registry: Registry = Registry(), tools: [AgentTool]? = nil,
                              mcp: Bool = true, instructions: Bool = true, scope: InstructionScope = .global) throws -> [SetupWrite] {
        let clones = instructions && scope == .projects ? try projectClones(registry: registry) : []
        if instructions && scope == .projects && clones.isEmpty {
            throw Registry.Failure("no local clone of any project's repositories under the roots")
        }
        let spaces = try registry.spaces().map(\.name)
        var done: [SetupWrite] = []
        for tool in tools ?? AgentTool.allCases {
            guard home.found(tool) else { done.append(.init(target: tool.rawValue, file: home.dir(tool).path, state: "not found")); continue }
            if mcp {
                try MCPRegistration.register(tool, home: home)
                done.append(.init(target: tool.rawValue, file: home.mcpConfig(tool).path, state: "registered"))
            }
            if instructions, scope == .global, let file = home.instructions(tool) {
                done.append(try write(file, target: tool.rawValue, spaces: spaces))
            }
        }
        return done + (try write(clones, spaces: spaces))
    }

    /// The block into CLAUDE.md and AGENTS.md of every local clone of the project's repositories.
    public static func project(_ id: String, registry: Registry = Registry()) throws -> [SetupWrite] {
        let clones = try projectClones(registry: registry).filter { $0.project == id }
        guard try registry.project(id).repos.count > 0 else { throw Registry.Failure("project \(id) has no repositories") }
        guard !clones.isEmpty else { throw Registry.Failure("no local clone of \(id)'s repositories under the roots") }
        return try write(clones, spaces: try registry.spaces().map(\.name))
    }

    static func write(_ clones: [(project: String, clone: String)], spaces: [String]) throws -> [SetupWrite] {
        var done: [SetupWrite] = []
        for (project, clone) in clones {
            for name in AgentInstructions.projectFiles {
                done.append(try write(URL(fileURLWithPath: clone).appendingPathComponent(name), target: project, spaces: spaces))
            }
        }
        return done
    }

    static func write(_ file: URL, target: String, spaces: [String]) throws -> SetupWrite {
        let before = AgentInstructions.state(of: file)
        try AgentInstructions.write(to: file, spaces: spaces)
        return SetupWrite(target: target, file: file.path, state: before == "absent" ? "written" : "updated")
    }

    public static func projectClones(registry: Registry) throws -> [(project: String, clone: String)] {
        let clones = Repos.clones(roots: registry.searchRoots)
        return try registry.projects().flatMap { p in p.repos.compactMap { r in clones[r.repo].map { (p.id, $0) } } }
    }
}
