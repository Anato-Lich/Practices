import Foundation
import AppKit
import Observation
import PracticesCore

/// The registry as the window sees it: sources, which keys have values, the latest checks
/// and Doctor's report. Values themselves never reach this model — only `set` passes one
/// through, straight to the store.
@MainActor @Observable
final class RegistryModel {

    private(set) var sources: [Source] = []
    /// source id → its practices; chains apart.
    private(set) var practices: [String: [Practice]] = [:]
    private(set) var chains: [Practice] = []
    /// What the window shows; views set it to open a source or a practice.
    var selection: MainWindow.SidebarItem?
    var searchText = ""
    /// Projects with a practices.yaml; the chosen one decides environments of runs.
    private(set) var projects: [(dir: URL, manifest: ProjectManifest)] = []
    var projectPath: String? = UserDefaults.standard.string(forKey: "projectContext") {
        didSet { UserDefaults.standard.set(projectPath, forKey: "projectContext") }
    }
    /// Environment per source for runs started from the window.
    var contextEnvs: [String: String] {
        projects.first { $0.dir.path == projectPath }?.manifest.envs ?? [:]
    }
    /// Open practices keep their state (code being edited, last result) while switching.
    private var practiceModels: [String: PracticeModel] = [:]
    /// source id → env → keys that have a value.
    private(set) var keyStatus: [String: [String: Set<String>]] = [:]
    /// source id → results of the last check, preconditions first.
    private(set) var checks: [String: [CheckResult]] = [:]
    private(set) var checking: Set<String> = []
    private(set) var lastCheck: [String: Date] = [:]
    private(set) var findings: [DoctorFinding]?
    private(set) var proposals: [Proposal] = []
    /// Marked copies of practices in ~/Projects; nil until the first scan.
    private(set) var copies: [PracticeCopy]?
    private(set) var doctorRunning = false
    var error: String?

    let registry = Registry()
    let store = SecretStore()

    func reload() {
        do {
            sources = try registry.sources()
            keyStatus = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, (try? store.status(source: $0)) ?? [:]) })
            let practiceStore = PracticeStore(registry: registry)
            practices = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, practiceStore.list(source: $0.id)) })
            chains = practiceStore.chains()
            projects = ProjectManifest.all()
            if let path = projectPath, !projects.contains(where: { $0.dir.path == path }) { projectPath = nil }
        } catch {
            self.error = String(describing: error)
        }
    }

    func source(_ id: String) -> Source? { sources.first { $0.id == id } }

    func reloadProposals() { proposals = ProposalStore().all() }

    var pendingProposals: Int { proposals.filter { $0.status == .pending }.count }

    func decide(_ proposal: Proposal, accept: Bool) async {
        do {
            if accept { _ = try await ProposalReviewer().accept(proposal, by: "user") }
            else { _ = try ProposalReviewer().reject(proposal) }
        } catch {
            self.error = String(describing: error)
        }
        reloadProposals()
        reload()
    }

    func scanCopies() async {
        copies = await Copies.scan()
    }

    func model(for ref: String) -> PracticeModel {
        if let model = practiceModels[ref] { return model }
        let model = PracticeModel(practice: Practice(ref: ref), registry: self)
        practiceModels[ref] = model
        return model
    }

    func lastRun(of ref: String) -> RunRecord? {
        (try? RunsStore())?.runs(of: ref, limit: 1).first
    }

    /// Green when every target answers, orange when some do, red when a precondition fails or
    /// nothing answers, grey before the first check.
    func health(of id: String) -> Health {
        guard let results = checks[id], !results.isEmpty else { return .unknown }
        if results.contains(where: { $0.target == "requires" && !$0.ok }) { return .down }
        let ok = results.filter(\.ok).count
        return ok == results.count ? .up : ok == 0 ? .down : .partial
    }

    enum Health { case unknown, up, partial, down }

    func check(_ id: String) async {
        guard let source = source(id) else { return }
        checking.insert(id)
        var results: [CheckResult] = []
        for env in source.envs {
            let values = (try? store.values(source: id, env: env)) ?? [:]
            for failure in await Checks.unmet(source, env: env, values: values) {
                results.append(CheckResult(source: id, env: env, target: "requires", ok: false, millis: nil, message: failure))
            }
            results += await Checks.check(source, env: env, values: values)
        }
        checks[id] = results
        lastCheck[id] = Date()
        checking.remove(id)
    }

    func checkAll() async {
        await withTaskGroup(of: Void.self) { group in
            for source in sources { group.addTask { await self.check(source.id) } }
        }
    }

    func set(_ value: String, key: String, source id: String, env: String) {
        do {
            try store.set(value, key: key, source: id, env: env)
            reload()
        } catch {
            self.error = String(describing: error)
        }
    }

    func unset(key: String, source id: String, env: String) {
        do {
            try store.remove(key: key, source: id, env: env)
            reload()
        } catch {
            self.error = String(describing: error)
        }
    }

    func runDoctor() async {
        doctorRunning = true
        do { findings = try await Doctor.run() } catch { self.error = String(describing: error) }
        doctorRunning = false
    }

    func notes(of id: String) -> String? { registry.notes(of: id) }
    func docs(of id: String) -> [SourceDoc] { registry.docs(of: id) }
    func fields(of id: String) -> [FieldDoc] { registry.fields(of: id) }

    func open(_ doc: SourceDoc, of id: String) {
        if let url = doc.url.flatMap(URL.init(string:)) { NSWorkspace.shared.open(url); return }
        guard let path = doc.path else { return }
        let file = path.hasPrefix("/") ? URL(fileURLWithPath: path)
            : registry.dir(of: id).appendingPathComponent("docs").appendingPathComponent(path)
        NSWorkspace.shared.open(file)
    }

    func revealSource(_ id: String) {
        NSWorkspace.shared.activateFileViewerSelecting([registry.dir(of: id).appendingPathComponent("source.yaml")])
    }
}
