import Foundation
import Observation
import PracticesCore

/// «Начало» and «Настройка» (DECISIONS 36): `Setup.status` and the operations that change it.
/// Every call runs off the main thread on a fresh `Registry()` — `local.yaml` changes under it.
@MainActor @Observable
final class SetupModel {

    private(set) var status: SetupStatus?
    private(set) var checkedAt: Date?
    /// Operations in flight: "status", "roots", "create", "agents", …
    private(set) var busy: Set<String> = []
    /// What the last «Настроить агентов» did, an entry per file.
    private(set) var agentWrites: [SetupWrite]?
    /// Clones of the catalogue's projects: what «В проектах» writes into.
    private(set) var projectClones = 0
    private(set) var runtimeBusy = false

    @ObservationIgnored weak var app: RegistryModel?

    /// `PRACTICES_AGENT_HOME` replaces the user's home for the agents' files: renders and dry runs
    /// read and write there, not in `~/.claude*`.
    nonisolated static var agentHome: AgentHome {
        let base = ProcessInfo.processInfo.environment["PRACTICES_AGENT_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        return AgentHome(base: base ?? URL(fileURLWithPath: NSHomeDirectory()))
    }

    func refresh() async {
        let home = Self.agentHome
        if let (s, n) = await run("проверить настройку", "status", { (try await Setup.status(registry: Registry(), home: home), try Setup.projectClones(registry: Registry()).count) }) {
            status = s
            projectClones = n
            checkedAt = Date()
        }
    }

    /// Runs `body` off the main thread; a failure goes to the window's error bar.
    @discardableResult
    private func run<T: Sendable>(_ what: String, _ key: String, _ body: @escaping @Sendable () async throws -> T) async -> T? {
        busy.insert(key)
        defer { busy.remove(key) }
        do { return try await Task.detached(operation: body).value } catch { app?.fail(what, error); return nil }
    }

    /// After a change: the setup screen and the catalogue both read again.
    private func changed() async {
        app?.reload()
        await refresh()
    }

    // MARK: Roots

    func addRoots(_ urls: [URL]) async {
        for url in urls {
            let path = url.path
            await run("добавить папку " + (path as NSString).abbreviatingWithTildeInPath, "roots") { try Registry().addRoot(path) }
        }
        await changed()
    }

    func removeRoot(_ path: String) async {
        await run("убрать папку", "roots") { try Registry().removeRoot(path) }
        await changed()
    }

    // MARK: Spaces

    /// True when the space was made.
    func create(id: String, name: String) async -> Bool {
        let space = Space(id: id.trimmingCharacters(in: .whitespaces), name: name.trimmingCharacters(in: .whitespaces))
        let made = await run("создать пространство \(space.id)", "create") { try await Registry().add(space); return true } ?? false
        await changed()
        return made
    }

    // MARK: Agents

    func setupAgents(_ tools: [AgentTool], scope: InstructionScope = .global, mcp: Bool = true, instructions: Bool = true) async {
        let home = Self.agentHome
        agentWrites = await run("настроить агентов", "agents") {
            try Setup.agents(home: home, registry: Registry(), tools: tools, mcp: mcp, instructions: instructions, scope: scope)
        }
        await refresh()
    }

    func writeProject(_ id: String) async {
        await run("записать блок в \(id)", "project") { try Setup.project(id, registry: Registry()) }
        await refresh()
    }

    // MARK: Runtime

    func ensureRuntime() async {
        runtimeBusy = true
        await run("обновить окружение Python", "runtime") { try await PythonRuntime.ensure() }
        runtimeBusy = false
    }

    /// `3.12.6` from the venv's `pyvenv.cfg`, and when the venv was made.
    nonisolated static var runtime: (version: String?, date: Date?) {
        let venv = PythonRuntime.directory.appendingPathComponent(".venv")
        let cfg = (try? String(contentsOf: venv.appendingPathComponent("pyvenv.cfg"), encoding: .utf8)) ?? ""
        let version = cfg.split(separator: "\n").first { $0.hasPrefix("version") }?
            .split(separator: "=").last.map { $0.trimmingCharacters(in: .whitespaces) }
        let date = (try? FileManager.default.attributesOfItem(atPath: venv.path))?[.modificationDate] as? Date
        return (version, date)
    }
}

extension AgentTool {
    var title: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .cursor: "Cursor"
        }
    }
}

/// «7 ноя»: when an instruction block was written, from the file's date.
func shortDate(_ date: Date?) -> String {
    guard let date else { return "" }
    let f = DateFormatter()
    f.locale = Locale(identifier: "ru_RU")
    f.dateFormat = "LLL"
    return "\(Calendar.current.component(.day, from: date)) " + f.string(from: date).prefix(3)
}

func modified(_ path: String) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
}

func tilde(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }
