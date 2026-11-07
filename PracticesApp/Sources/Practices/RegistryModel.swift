import Foundation
import AppKit
import Observation
import PracticesCore

/// The catalogue as the window sees it: spaces, the tree of projects, services, which keys have
/// values, the latest checks, what waits to be accepted and Doctor's report. Values themselves never reach this model — only `set` passes one
/// through, straight to the store.
@MainActor @Observable
final class RegistryModel {

    private(set) var spaces: [Space] = []
    /// Projects of every space in tree order, with their depth (`Registry.tree`).
    private(set) var tree: [(project: Project, depth: Int)] = []
    /// project id → the projects right under it; the top ones of all spaces apart.
    private(set) var childProjects: [String: [Project]] = [:]
    private(set) var topProjects: [Project] = []
    /// space id → its conditions.
    private(set) var conditions: [String: [Condition]] = [:]
    private(set) var services: [Service] = []
    /// project id → `space / parent / project`, for display.
    private(set) var projectPaths: [String: String] = [:]
    /// service id → its practices; project id → its chains.
    private(set) var practices: [String: [Practice]] = [:]
    private(set) var chains: [String: [Practice]] = [:]
    /// Repository → its clone on this machine, and the clone's state once a project view asked.
    private(set) var clones: [RepoID: String] = [:]
    private(set) var gitStates: [RepoID: GitState] = [:]
    /// Uncommitted changes in the spaces: what agents wrote and the user has not accepted (DECISIONS 19).
    private(set) var pending: [Pending] = []
    /// «Не распределено»: nil until asked for — it calls `gh` and `glab` (DECISIONS 15, 16).
    private(set) var unassigned: [RepoInfo]?
    private(set) var unassignedProblems: [String] = []
    private(set) var loadingUnassigned = false
    /// What the window shows; views set it to open a project, a service or a practice.
    var selection: MainWindow.SidebarItem? { didSet { if selection != nil { welcomeShown = false }; reveal(); remember() } }
    /// The last three cards opened (sidebar «Недавние»); kept between launches.
    private(set) var recent: [MainWindow.SidebarItem] =
        (UserDefaults.standard.data(forKey: "recent")).flatMap { try? JSONDecoder().decode([MainWindow.SidebarItem].self, from: $0) } ?? []
    /// Where the map is; kept across visits, so «Карта» returns to the last level shown.
    let map = MapState()
    /// space id → `git status` of the space's own repository (status bar).
    private(set) var spaceGit: [String: GitState] = [:]
    /// Projects and services whose rows are open in the sidebar.
    var expanded: Set<MainWindow.SidebarItem> = []
    var searchText = ""
    /// The ⌘K palette over the window.
    var paletteShown = false
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
    /// The last operation that failed: «Не удалось <what>», the error text, when (`design/States.dc.html`).
    var failed: (what: String, text: String, at: Date)?
    /// Views that only have the text; the bar then names no operation.
    var error: String? {
        get { failed?.text }
        set { failed = newValue.map { ("выполнить операцию", $0, Date()) } }
    }
    func fail(_ what: String, _ error: any Error) { failed = (what, String(describing: error), Date()) }
    /// A project waiting for the user to confirm its removal.
    var removalCandidate: String?

    /// Opened again on every reload: «Настройка» changes `local.yaml` (roots) under it.
    private(set) var registry = Registry()
    let store = SecretStore()
    @ObservationIgnored private(set) lazy var setup: SetupModel = {
        let model = SetupModel()
        model.app = self
        return model
    }()
    /// «Начало» in the content: from a launch without spaces until «Открыть каталог», «Настроить
    /// позже» or a pick in the sidebar — not until the first space, which comes at step 2 of 3.
    var welcomeShown = false

    func reload() {
        registry = Registry()
        // Ids are unique by rule, not by construction: a card written by hand may repeat one,
        // and the window must still open to show it.
        func first<T>(_ a: T, _: T) -> T { a }
        do {
            spaces = try registry.spaces()
            tree = Registry.tree(try registry.projects())
            // The tree is a preorder: the last project of a smaller depth is the parent.
            var above: [Project] = []
            topProjects = []
            childProjects = [:]
            for (project, depth) in tree {
                above.removeLast(above.count - depth)
                if let parent = above.last { childProjects[parent.id, default: []].append(project) } else { topProjects.append(project) }
                above.append(project)
            }
            conditions = Dictionary(spaces.map { ($0.id, registry.conditions(space: $0.id)) }, uniquingKeysWith: first)
            services = try registry.services()
            projectPaths = Dictionary(projects.map { ($0.id, ([$0.space] + path(of: $0.id).map(\.id)).joined(separator: " / ")) }, uniquingKeysWith: first)
            keyStatus = Dictionary(services.map { ($0.id, (try? store.status(service: $0)) ?? [:]) }, uniquingKeysWith: first)
            let practiceStore = PracticeStore(registry: registry)
            practices = Dictionary(services.map { ($0.id, practiceStore.list(service: $0.id)) }, uniquingKeysWith: first)
            loadChecks()
            chains = Dictionary(projects.map { ($0.id, practiceStore.chains(project: $0.id)) }, uniquingKeysWith: first)
            map.catalogue = try registry.catalogue()
            // A removed project or service stays remembered otherwise; its row would lead nowhere.
            recent.removeAll { item in
                switch item {
                case .project(let id): project(id) == nil
                case .service(let id): service(id) == nil
                default: false
                }
            }
        } catch {
            fail("прочитать каталог", error)
        }
    }

    func service(_ id: String) -> Service? { services.first { $0.id == id } }
    func services(of project: Project) -> [Service] { services.filter { $0.project == project.id && $0.space == project.space } }

    var projects: [Project] { tree.map(\.project) }
    func project(_ id: String) -> Project? { projects.first { $0.id == id } }

    /// A project with its ancestors, outermost first. Bounded by the number of projects: a
    /// cycle written by hand must not spin.
    func path(of id: String) -> [Project] {
        var path: [Project] = [], next: String? = id
        for _ in tree {
            guard let found = next.flatMap(project) else { break }
            path.insert(found, at: 0)
            next = found.parent
        }
        return path
    }

    /// Opens the tree down to the selected row, so a jump from a card is seen in the sidebar.
    private func reveal() {
        let project: String?
        switch selection {
        case .practice(let ref):
            let practice = Practice(ref: ref)
            if let id = practice.service { expanded.insert(.service(id)) }
            project = practice.service.flatMap(service)?.project ?? chains.first { $0.value.contains(practice) }?.key
        case .service(let id): project = service(id)?.project
        case .project(let id): project = self.project(id)?.parent
        default: return
        }
        for ancestor in project.map(path(of:)) ?? [] { expanded.insert(.project(ancestor.id)) }
    }

    private func remember() {
        guard let item = selection else { return }
        switch item {
        case .project, .service, .practice: break
        default: return
        }
        recent = Array(([item] + recent.filter { $0 != item }).prefix(3))
        // A render must not change what the user's sidebar shows.
        guard !CommandLine.arguments.contains("--render-window") else { return }
        UserDefaults.standard.set(try? JSONEncoder().encode(recent), forKey: "recent")
    }

    // MARK: Repositories

    /// Where the project's repositories are cloned (a walk of the search roots, off the main
    /// thread) and how the clones stand: local `git status` and `git log`, no fetch.
    func loadGitStates(of project: Project) async {
        let roots = registry.searchRoots
        clones = await Task.detached { Repos.clones(roots: roots) }.value
        for repo in project.repos.map(\.repo) {
            if let path = clones[repo] { gitStates[repo] = await Repos.gitState(ofClone: path) }
        }
    }

    func loadUnassigned() async {
        loadingUnassigned = true
        do {
            let (repos, problems) = try await Repos.unassigned(registry: registry)
            unassigned = repos
            unassignedProblems = problems
        } catch { fail("получить список репозиториев", error) }
        loadingUnassigned = false
    }

    func assign(_ repo: RepoID, to project: String) async {
        do {
            try await registry.assign(repo, to: project)
            unassigned?.removeAll { $0.repo == repo }
            reload()
        } catch { fail("назначить репозиторий", error) }
    }

    func ignore(_ repo: RepoID, in space: String, _ ignored: Bool = true) async {
        do {
            try await registry.ignore(repo, in: space, ignored)
            if let i = unassigned?.firstIndex(where: { $0.repo == repo }) { unassigned?[i].ignored = ignored }
            reload()
        } catch { fail(ignored ? "скрыть репозиторий" : "вернуть репозиторий", error) }
    }

    /// `trash`: clone folders to move to the Trash once the card is gone (the user's choice in the sheet).
    func remove(project id: String, ignoreRepos: Bool = true, trash: [String] = []) async {
        let space = project(id)?.space
        do {
            _ = try await registry.remove(project: id, ignoreRepos: ignoreRepos)
            for path in trash { try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil) }
        } catch { fail("удалить проект \(id)", error) }
        if let space { selection = .space(space) }
        reload()
        await refreshPending()
    }

    /// Services and links the project's clones give (`practicesctl scan <id> --write`), left for acceptance.
    func scanLinks(of id: String) async {
        let (registry, store) = (registry, store)
        // The scan walks the clones: off the main thread.
        do { _ = try await Task.detached { try Scanner.write(try Scanner.scan([id], registry: registry, store: store), registry: registry) }.value }
        catch { fail("найти связи в коде \(id)", error) }
        reload()
        await refreshPending()
        selection = .pending
    }

    // MARK: Pending

    func refreshPending() async {
        pending = await registry.pending()
        for space in spaces { spaceGit[space.id] = await Repos.gitState(ofClone: registry.dir(ofSpace: space.id).path) }
    }

    func diff(of change: Pending) async -> String { await registry.diff(of: change) }

    /// Commits one pending change, or all of them.
    func accept(_ change: Pending? = nil) async {
        do { try await registry.accept(space: change?.space, paths: change.map { [$0.path] } ?? []) } catch { fail("принять " + (change?.path ?? "изменения"), error) }
        reload()
        await refreshPending()
    }

    /// Drops one pending change: the file goes back to what the catalogue holds.
    func discard(_ change: Pending) async {
        do { try await registry.discard(change) } catch { fail("отклонить " + change.path, error) }
        reload()
        await refreshPending()
    }

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
            fail("сохранить \(key)", error)
        }
    }

    func unset(key: String, service id: String, env: String) {
        do {
            try store.remove(key: key, service: id, env: env)
            reload()
        } catch {
            fail("удалить \(key)", error)
        }
    }

    func runDoctor() async {
        doctorRunning = true
        do { findings = try await Doctor.run() } catch { fail("запустить Doctor", error) }
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
