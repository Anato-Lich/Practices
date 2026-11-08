import Foundation
import CryptoKit

/// The agent tools Practices registers itself in.
public enum AgentTool: String, CaseIterable, Codable, Sendable {
    case claude, codex, cursor
}

/// Where each agent tool keeps its files. `base` is the user's home, or `PRACTICES_AGENT_HOME`
/// when set: renders and dry runs read and write there, not in `~/.claude*`; tests pass a temp dir.
public struct AgentHome: Sendable {
    public let base: URL
    /// The `~/.practices` whose `bin/practicesctl` the agents are told to run.
    public let practices: URL

    public static func defaultBase(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        environment["PRACTICES_AGENT_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSHomeDirectory())
    }

    public init(base: URL = AgentHome.defaultBase(), practices: URL = PracticesHome.url) {
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

/// What to do with a hand-written section of the block's heading outside the markers: leave it and
/// write nothing (`skip`), put the block in its place (`replace`), or keep it and add the block at the end (`append`).
public enum OwnSection: String, CaseIterable, Codable, Sendable {
    case skip, replace, append
}

/// A block written into agents' CLAUDE.md / AGENTS.md between `<!-- <marker>:begin vN -->` and
/// `<!-- <marker>:end -->`: the Practices block, and the optional «Как работаем с кодом».
public struct AgentInstructions: Sendable {
    public let marker: String
    /// Bump when the text of the resource changes: older blocks show as outdated.
    public let version: Int
    let resource: String
    /// A hand-written section with this heading outside the markers is not duplicated (`state` is `own section`).
    let heading: String?
    /// Prefix of `SetupWrite.state`: the two blocks of one file read apart.
    let label: String

    public static let practices = AgentInstructions(marker: "practices", version: 8, resource: "AgentInstructions", heading: nil, label: "")
    public static let rules = AgentInstructions(marker: "practices-rules", version: 1, resource: "CodingRules",
                                                heading: "# Как работаем с кодом", label: "rules ")
    public static let projectFiles = ["CLAUDE.md", "AGENTS.md"]

    public var text: String {
        Bundle.module.url(forResource: resource, withExtension: "md")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }

    /// `{{spaces}}` names the spaces at the time of writing: «пространства demo», «пространств X-Keeper и SphereTele».
    public func block(spaces: [String]) -> String {
        let names = spaces.isEmpty ? "ваших пространств" : spaces.count == 1 ? "пространства " + spaces[0]
            : "пространств " + spaces.dropLast().joined(separator: ", ") + " и " + spaces.last!
        return "<!-- \(marker):begin v\(version) -->\n" + text.trimmingCharacters(in: .newlines).replacingOccurrences(of: "{{spaces}}", with: names)
            + "\n<!-- \(marker):end -->\n"
    }

    var pattern: NSRegularExpression {
        try! NSRegularExpression(pattern: "<!-- \(NSRegularExpression.escapedPattern(for: marker)):begin v(\\d+) -->[\\s\\S]*?<!-- \(NSRegularExpression.escapedPattern(for: marker)):end -->\n?")
    }

    func match(in text: String) -> NSTextCheckingResult? { pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) }

    /// The hand-written section: from `heading` outside our block to the next `# ` heading or block marker.
    func ownSection(in text: String) -> Range<String.Index>? {
        guard let heading else { return nil }
        let ours = match(in: text).flatMap { Range($0.range, in: text) }
        var from = text.startIndex
        while let start = text.range(of: "(?m)^" + NSRegularExpression.escapedPattern(for: heading) + "[ \\t]*$", options: .regularExpression, range: from..<text.endIndex) {
            from = start.upperBound
            if let ours, ours.contains(start.lowerBound) { continue }
            let next = text.range(of: "(?m)^(# |<!-- practices)", options: .regularExpression, range: start.upperBound..<text.endIndex)
            return start.lowerBound..<(next?.lowerBound ?? text.endIndex)
        }
        return nil
    }

    /// `absent`, `current`, `outdated(vM)`, or `own section` (a hand-written one and no block).
    public func state(of file: URL) -> String {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return "absent" }
        guard let match = match(in: text), let range = Range(match.range(at: 1), in: text), let found = Int(text[range])
        else { return ownSection(in: text) == nil ? "absent" : "own section" }
        return found == version ? "current" : "outdated(v\(found))"
    }

    /// Replaces the block of any version, or appends it after a blank line; creates the file if needed.
    /// A hand-written section of the same heading: see `OwnSection`; states `own section` (nothing
    /// written), `replaced`, `appended`. Else `written` or `updated` — a block once there is updated in place.
    @discardableResult
    public func write(to file: URL, spaces: [String] = [], own: OwnSection = .skip) throws -> String {
        let ours = block(spaces: spaces)
        var text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let state: String
        if own == .replace, ownSection(in: text) != nil {
            if let match = match(in: text), let range = Range(match.range, in: text) { text.removeSubrange(range) }
            let own = ownSection(in: text)!
            text.replaceSubrange(own, with: ours + (own.upperBound == text.endIndex ? "" : "\n"))
            state = "replaced"
        } else if let match = match(in: text), let range = Range(match.range, in: text) {
            text.replaceSubrange(range, with: ours)
            state = "updated"
        } else {
            let found = ownSection(in: text) != nil
            if found && own == .skip { return "own section" }
            if !text.isEmpty { text += text.hasSuffix("\n") ? "\n" : "\n\n" }
            text += ours
            state = found ? "appended" : "written"
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
        return state
    }

    /// Takes the block out; a file left with nothing else is deleted. False when there was no block.
    public func remove(from file: URL) throws -> Bool {
        guard var text = try? String(contentsOf: file, encoding: .utf8),
              let match = match(in: text), let range = Range(match.range, in: text) else { return false }
        text.removeSubrange(range)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try FileManager.default.removeItem(at: file)
        } else {
            try (text.hasSuffix("\n\n") ? String(text.dropLast()) : text).write(to: file, atomically: true, encoding: .utf8)
        }
        return true
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
/// `both` is only ever found (`setup status`), never written: writing one scope clears the other.
public enum InstructionScope: String, CaseIterable, Codable, Sendable {
    case global, projects, both

    public static let allCases: [InstructionScope] = [.global, .projects]
}

/// A thing `setup agents` did: `target` is a tool or a project id; `state` is `registered` (MCP),
/// `written` (the file had no block), `updated` (a block was replaced), `removed` (the other scope's
/// block was taken out) or `not found` (tool skipped). The rules block's states start with `rules `:
/// `rules replaced` / `rules appended` (beside a hand-written section), `rules own section` (not written, `note` says why).
public struct SetupWrite: Codable, Sendable {
    public let target: String
    public let file: String
    public let state: String
    public var note: String? = nil
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
        /// The «Как работаем с кодом» block: absent / current / outdated(vN) / own section.
        public let rules: String?
    }
    public struct ProjectBlock: Codable, Sendable {
        public let project: String
        public let clone: String
        public let file: String
        public let state: String
        public let rules: String
    }
    /// Roots from `local.yaml`.
    public let roots: [Root]
    public let spaces: [SpaceState]
    public let command: String
    public let commandInstalled: Bool
    /// The installed copy against the app's `Contents/Helpers/practicesctl`.
    public let commandState: CommandState
    public let tools: [Tool]
    public let projectBlocks: [ProjectBlock]
    /// Inferred from the blocks there are: global ones → `global`, project ones → `projects`, both → `both`, none → nil.
    public let scope: InstructionScope?
}

/// The installed `practicesctl` against the app's copy: an app update brings a new one.
public enum CommandState: String, Codable, Sendable {
    case missing, current, outdated
}

public enum Setup {

    /// The one hint wherever the installed command is missing (CLI, MCP).
    public static let installHint = "не установлен: `practicesctl setup install`, или кнопка «Установить practicesctl» в приложении («Начало» / «Настройка»)"

    /// The CLI the app carries: this app's own when running in one, else the installed app's.
    public static var appHelper: URL {
        let main = Bundle.main.bundleURL
        return main.pathExtension == "app" ? main.appendingPathComponent("Contents/Helpers/practicesctl")
            : URL(fileURLWithPath: "/Applications/Practices.app/Contents/Helpers/practicesctl")
    }

    /// SHA-256 of `practicesctl` and of `uv` beside it, installed against the helper's (about 12 ms
    /// a pair of 2–5 MB files; uv is bigger). Without a helper to compare with (CLI from source, no
    /// app), an installed copy counts as current; a helper without uv compares the CLI only.
    public static func commandState(helper: URL = appHelper, home: URL = PracticesHome.url) -> CommandState {
        let installed = home.appendingPathComponent("bin/practicesctl")
        guard FileManager.default.isExecutableFile(atPath: installed.path) else { return .missing }
        func hash(_ url: URL) -> SHA256.Digest? { (try? Data(contentsOf: url, options: .mappedIfSafe)).map { SHA256.hash(data: $0) } }
        guard let new = hash(helper) else { return .current }
        guard hash(installed) == new else { return .outdated }
        let uv = helper.deletingLastPathComponent().appendingPathComponent("uv")
        guard let newUV = hash(uv) else { return .current }
        return hash(installed.deletingLastPathComponent().appendingPathComponent("uv")) == newUV ? .current : .outdated
    }

    public static func status(registry: Registry = Registry(), home: AgentHome = AgentHome()) async throws -> SetupStatus {
        let fm = FileManager.default
        let roots = registry.searchRoots.map { path in
            SetupStatus.Root(path: path, exists: fm.fileExists(atPath: path), clones: Repos.clones(roots: [path]).count)
        }
        let tools = AgentTool.allCases.map { tool in
            SetupStatus.Tool(tool: tool, found: home.found(tool), mcp: MCPRegistration.isRegistered(tool, home: home),
                             instructions: home.instructions(tool).map(AgentInstructions.practices.state),
                             rules: home.instructions(tool).map(AgentInstructions.rules.state))
        }
        var blocks: [SetupStatus.ProjectBlock] = []
        for (project, clone) in try projectClones(registry: registry) {
            for name in AgentInstructions.projectFiles {
                let file = URL(fileURLWithPath: clone).appendingPathComponent(name)
                let state = AgentInstructions.practices.state(of: file), rules = AgentInstructions.rules.state(of: file)
                if state != "absent" || rules != "absent" { blocks.append(.init(project: project, clone: clone, file: name, state: state, rules: rules)) }
            }
        }
        return SetupStatus(roots: roots, spaces: try await registry.spaceStates(),
                           command: home.command, commandInstalled: fm.isExecutableFile(atPath: home.command),
                           commandState: commandState(home: home.practices),
                           tools: tools, projectBlocks: blocks,
                           scope: scope(global: tools.contains { ($0.instructions ?? "absent") != "absent" }, projects: !blocks.isEmpty))
    }

    static func scope(global: Bool, projects: Bool) -> InstructionScope? {
        global && projects ? .both : global ? .global : projects ? .projects : nil
    }

    /// Registers the MCP server for each found tool (all of them unless `tools` names some) and
    /// writes the instruction block: into the tools' global files, or with `.projects` into every
    /// clone of every project (whatever `tools` says — the files are CLAUDE.md and AGENTS.md).
    /// The block of the other scope is removed: global files of every tool, or every project clone.
    /// `rules` adds the «Как работаем с кодом» block next to it (and moves it with the scope the same
    /// way); `ownRules` says what to do where a hand-written section of that heading is found.
    public static func agents(home: AgentHome = AgentHome(), registry: Registry = Registry(), tools: [AgentTool]? = nil,
                              mcp: Bool = true, instructions: Bool = true, rules: Bool = false, ownRules: OwnSection = .skip,
                              scope: InstructionScope = .global) throws -> [SetupWrite] {
        guard scope != .both else { throw Registry.Failure("scope is global or projects") }
        let all = instructions ? try projectClones(registry: registry) : []
        let clones = scope == .projects ? all : []
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
                done += try write(file, target: tool.rawValue, spaces: spaces, rules: rules, ownRules: ownRules)
            }
        }
        done += try write(clones, spaces: spaces, rules: rules, ownRules: ownRules)
        guard instructions else { return done }
        let other: [(target: String, file: URL)] = scope == .global
            ? all.flatMap { p in AgentInstructions.projectFiles.map { (p.project, URL(fileURLWithPath: p.clone).appendingPathComponent($0)) } }
            : AgentTool.allCases.compactMap { tool in home.instructions(tool).map { (tool.rawValue, $0) } }
        for block in rules ? [AgentInstructions.practices, .rules] : [.practices] {
            for (target, file) in other where try block.remove(from: file) {
                done.append(.init(target: target, file: file.path, state: block.label + "removed"))
            }
        }
        return done
    }

    /// The block into CLAUDE.md and AGENTS.md of every local clone of the project's repositories.
    public static func project(_ id: String, registry: Registry = Registry(), rules: Bool = false, ownRules: OwnSection = .skip) throws -> [SetupWrite] {
        let clones = try projectClones(registry: registry).filter { $0.project == id }
        guard try registry.project(id).repos.count > 0 else { throw Registry.Failure("project \(id) has no repositories") }
        guard !clones.isEmpty else { throw Registry.Failure("no local clone of \(id)'s repositories under the roots") }
        return try write(clones, spaces: try registry.spaces().map(\.name), rules: rules, ownRules: ownRules)
    }

    static func write(_ clones: [(project: String, clone: String)], spaces: [String], rules: Bool, ownRules: OwnSection) throws -> [SetupWrite] {
        try clones.flatMap { project, clone in
            try AgentInstructions.projectFiles.flatMap { name in
                try write(URL(fileURLWithPath: clone).appendingPathComponent(name), target: project, spaces: spaces, rules: rules, ownRules: ownRules)
            }
        }
    }

    static let ownRulesNote = "найден свой раздел «Как работаем с кодом» вне маркеров — блок не записан, замените раздел блоком: `setup agents --with-rules --replace-rules`, или добавьте блок рядом: `--append-rules`"

    static func write(_ file: URL, target: String, spaces: [String], rules: Bool, ownRules: OwnSection) throws -> [SetupWrite] {
        try (rules ? [AgentInstructions.practices, .rules] : [.practices]).map { block in
            let state = try block.write(to: file, spaces: spaces, own: ownRules)
            return SetupWrite(target: target, file: file.path, state: block.label + state, note: state == "own section" ? ownRulesNote : nil)
        }
    }

    /// Copies the CLI the app carries (`Contents/Helpers/practicesctl`, the resource bundle and `uv`
    /// next to it) into `<home>/bin` and links it from `links/practicesctl`; returns the paths written.
    /// `uv` is taken from next to the helper, else from `fallbackUV` (the app's), else skipped;
    /// `links` is `~/.local/bin` unless a test passes a temp dir. A file already in place (the
    /// installed CLI running `setup install`) is left as it is.
    @discardableResult
    public static func installCommand(from helper: URL, home: URL = PracticesHome.url,
                                      links: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/bin"),
                                      fallbackUV: URL? = appHelper.deletingLastPathComponent().appendingPathComponent("uv")) async throws -> [URL] {
        let fm = FileManager.default
        let bundle = helper.deletingLastPathComponent().appendingPathComponent("PracticesCore_PracticesCore.bundle")
        guard fm.isExecutableFile(atPath: helper.path) else { throw Registry.Failure("\(helper.path) is not an executable") }
        guard fm.fileExists(atPath: bundle.path) else { throw Registry.Failure("\(bundle.path) is missing") }
        let uv = [helper.deletingLastPathComponent().appendingPathComponent("uv"), fallbackUV].compactMap { $0 }
            .first { fm.isExecutableFile(atPath: $0.path) }
        let bin = home.appendingPathComponent("bin")
        let command = bin.appendingPathComponent("practicesctl"), resources = bin.appendingPathComponent(bundle.lastPathComponent)
        let link = links.appendingPathComponent("practicesctl")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try fm.createDirectory(at: links, withIntermediateDirectories: true)
        var pairs = [(helper, command), (bundle, resources)]
        if let uv { pairs.append((uv, bin.appendingPathComponent("uv"))) }
        // Remove, then copy: overwriting a signed binary in place keeps the kernel's cached signature
        // of the old file, and macOS kills the new one at launch (exit 137).
        for (source, target) in pairs where source.resolvingSymlinksInPath().path != target.resolvingSymlinksInPath().path {
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.copyItem(at: source, to: target)
        }
        if (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil || fm.fileExists(atPath: link.path) { try fm.removeItem(at: link) }
        try fm.createSymbolicLink(at: link, withDestinationURL: command)
        // A downloaded app's files carry the quarantine flag, which copies keep; exit 1 is «no such xattr».
        _ = try await Shell.run("xattr", ["-dr", "com.apple.quarantine"] + pairs.map(\.1.path), allowedStatuses: [0, 1])
        return pairs.map(\.1) + [link]
    }

    public static func projectClones(registry: Registry) throws -> [(project: String, clone: String)] {
        let clones = Repos.clones(roots: registry.searchRoots)
        return try registry.projects().flatMap { p in p.repos.compactMap { r in clones[r.repo].map { (p.id, $0) } } }
    }
}
