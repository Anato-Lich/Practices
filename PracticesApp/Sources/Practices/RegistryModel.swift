import Foundation
import AppKit
import Observation
import PracticesCore

/// The registry as the window sees it: services, which keys have values, the latest checks
/// and Doctor's report. Values themselves never reach this model — only `set` passes one
/// through, straight to the store.
@MainActor @Observable
final class RegistryModel {

    private(set) var services: [Service] = []
    /// project id → `space / parent / project`, for display.
    private(set) var projectPaths: [String: String] = [:]
    /// service id → its practices; chains apart.
    private(set) var practices: [String: [Practice]] = [:]
    private(set) var chains: [Practice] = []
    /// What the window shows; views set it to open a service or a practice.
    var selection: MainWindow.SidebarItem?
    var searchText = ""
    /// Open practices keep their state (code being edited, last result) while switching.
    private var practiceModels: [String: PracticeModel] = [:]
    /// service id → env → keys that have a value.
    private(set) var keyStatus: [String: [String: Set<String>]] = [:]
    /// service id → results of the last check, conditions first.
    private(set) var checks: [String: [CheckResult]] = [:]
    private(set) var checking: Set<String> = []
    private(set) var lastCheck: [String: Date] = [:]
    private(set) var findings: [DoctorFinding]?
    /// Marked copies of practices in ~/Projects; nil until the first scan.
    private(set) var copies: [PracticeCopy]?
    private(set) var doctorRunning = false
    var error: String?

    let registry = Registry()
    let store = SecretStore()

    func reload() {
        do {
            services = try registry.services()
            projectPaths = Dictionary(uniqueKeysWithValues: try registry.projects().map {
                ($0.id, ([$0.space] + registry.path(ofProject: $0.id)).joined(separator: " / "))
            })
            keyStatus = Dictionary(uniqueKeysWithValues: services.map { ($0.id, (try? store.status(service: $0)) ?? [:]) })
            let practiceStore = PracticeStore(registry: registry)
            practices = Dictionary(uniqueKeysWithValues: services.map { ($0.id, practiceStore.list(service: $0.id)) })
            loadChecks()
            chains = practiceStore.chains()
        } catch {
            self.error = String(describing: error)
        }
    }

    func service(_ id: String) -> Service? { services.first { $0.id == id } }

    func scanCopies() async {
        copies = await Copies.scan()
    }

    func model(for ref: String) -> PracticeModel {
        if let model = practiceModels[ref] { return model }
        let model = PracticeModel(practice: Practice(ref: ref))
        practiceModels[ref] = model
        return model
    }

    func lastRun(of ref: String) -> RunRecord? {
        (try? RunsStore())?.runs(of: ref, limit: 1).first
    }

    /// Green when every endpoint answers, orange when some do, red when a condition fails or
    /// nothing answers, grey before the first check.
    func health(of id: String) -> Health {
        guard let results = checks[id], !results.isEmpty else { return .unknown }
        if results.contains(where: { $0.endpoint.hasPrefix("requires:") && !$0.ok }) { return .down }
        let ok = results.filter(\.ok).count
        return ok == results.count ? .up : ok == 0 ? .down : .partial
    }

    enum Health { case unknown, up, partial, down }

    /// Last results survive restarts: services are checked only when asked, and the window
    /// shows what the last attempt found and when (DECISIONS 56).
    private struct SavedCheck: Codable { let date: Date; let results: [CheckResult] }
    private static var checksURL: URL { PracticesHome.url.appendingPathComponent("checks.json") }

    private func loadChecks() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: Self.checksURL),
              let saved = try? decoder.decode([String: SavedCheck].self, from: data) else { return }
        for (id, check) in saved where checks[id] == nil {
            checks[id] = check.results
            lastCheck[id] = check.date
        }
    }

    private func saveChecks() {
        var saved: [String: SavedCheck] = [:]
        for (id, results) in checks { if let date = lastCheck[id] { saved[id] = SavedCheck(date: date, results: results) } }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(saved).write(to: Self.checksURL, options: .atomic)
    }

    func check(_ id: String) async {
        guard let service = service(id) else { return }
        checking.insert(id)
        var results: [CheckResult] = []
        for env in service.envs {
            let values = (try? store.values(service: id, env: env)) ?? [:]
            results += await Checks.conditions(service, env: env, values: values, registry: registry)
            results += await Checks.check(service, env: env, values: values)
        }
        checks[id] = results
        lastCheck[id] = Date()
        checking.remove(id)
        saveChecks()
    }

    func checkAll() async {
        await withTaskGroup(of: Void.self) { group in
            for service in services { group.addTask { await self.check(service.id) } }
        }
    }

    func set(_ value: String, key: String, service id: String, env: String) {
        do {
            try store.set(value, key: key, service: id, env: env)
            reload()
        } catch {
            self.error = String(describing: error)
        }
    }

    func unset(key: String, service id: String, env: String) {
        do {
            try store.remove(key: key, service: id, env: env)
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
    func docs(of id: String) -> [ServiceDoc] { registry.docs(of: id) }
    func fields(of id: String) -> [FieldDoc] { registry.fields(of: id) }
    func condition(_ id: String) -> Condition? { registry.condition(id) }
    func links(of id: String) -> [Link] { registry.links(of: id) }
    func links(to id: String) -> [(from: String, link: Link)] { registry.links(to: id) }

    /// A document is a link, a file in a repository's clone, or a file under the card's `docs/`.
    func open(_ doc: ServiceDoc, of id: String) {
        if let url = doc.url.flatMap(URL.init(string:)) { NSWorkspace.shared.open(url); return }
        guard let path = doc.path else { return }
        let base = doc.repo.map { Repos.clones(roots: registry.searchRoots)[$0].map(URL.init(fileURLWithPath:)) }
            ?? registry.dir(of: id)?.appendingPathComponent("docs")
        guard let file = path.hasPrefix("/") ? URL(fileURLWithPath: path) : base?.appendingPathComponent(path) else { return }
        NSWorkspace.shared.open(file)
    }

    func revealService(_ id: String) {
        guard let dir = registry.dir(of: id) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([dir.appendingPathComponent("service.yaml")])
    }
}
