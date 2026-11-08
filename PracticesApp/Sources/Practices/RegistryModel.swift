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
    @ObservationIgnored private var serviceByID: [String: Service] = [:]
    @ObservationIgnored private var projectByID: [String: Project] = [:]
    /// service id → whom it calls / who calls it, from `map.catalogue`.
    @ObservationIgnored private var linksOut: [String: [Link]] = [:]
    @ObservationIgnored private var linksIn: [String: [(from: String, link: Link)]] = [:]
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
    var selection: MainWindow.SidebarItem? { didSet { if selection != nil { welcomeShown = false }; reveal(); remember(); visit() } }
    /// Back and forward (toolbar chevrons, ⌘[ ⌘], a swipe): the selection, and on the map its level.
    private(set) var history = NavigationHistory<Place>()
    /// How far a two-finger swipe has gone, −1…1 (positive: back), for the edge arrow.
    var swipe: CGFloat = 0
    @ObservationIgnored private var restoring = false
    /// The last three cards opened (sidebar «Недавние»); kept between launches.
    private(set) var recent: [MainWindow.SidebarItem] =
        (UserDefaults.standard.data(forKey: "recent")).flatMap { try? JSONDecoder().decode([MainWindow.SidebarItem].self, from: $0) } ?? []
    /// Where the map is; kept across visits, so «Карта» returns to the last level shown.
    let map = MapState()

    init() { map.onMove = { [weak self] in self?.visit() } }
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

    /// Opened again on every reload: «Настройка» changes `local.yaml` (roots) under it. Its folder
    /// listing is that of the last reload (`Registry.indexed`): writes go through a fresh `Registry()`.
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

    /// Reads the catalogue again, off the main thread, and puts it in place in one go: until then
    /// the window shows the previous one. `ifChanged`: only when a file under the spaces, `local.yaml`
    /// or the secrets changed since the last read (coming back to the window), and not a second time
    /// while one is running.
    func reload(ifChanged: Bool = false) async {
        if ifChanged, let loading { await loading.value; return }
        let previous = ifChanged ? stamp : nil
        let store = store
        generation += 1
        let mine = generation
        let task = Task.detached { () -> Result<CatalogueSnapshot, any Error>? in
            let stamp = CatalogueSnapshot.stamp(of: Registry(), store: store)
            if stamp == previous { return nil }
            return Result { try CatalogueSnapshot(stamp: stamp, store: store) }
        }
        let waiting = Task { _ = await task.value }
        loading = waiting
        let result = await task.value
        if loading == waiting { loading = nil }
        // A later reload started meanwhile: its result is the one to show.
        guard mine == generation, let result else { return }
        switch result {
        case .success(let snapshot): apply(snapshot)
        case .failure(let error): fail("прочитать каталог", error)
        }
    }

    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var stamp: Int?
    /// A first reload has finished: an empty `spaces` means none, not «not read yet».
    var loaded: Bool { stamp != nil }

    private func apply(_ s: CatalogueSnapshot) {
        stamp = s.stamp
        registry = s.registry
        spaces = s.spaces
        tree = s.tree
        childProjects = s.childProjects
        topProjects = s.topProjects
        projectByID = s.projectByID
        conditions = s.conditions
        services = s.services
        serviceByID = s.serviceByID
        projectPaths = s.projectPaths
        keyStatus = s.keyStatus
        practices = s.practices
        chains = s.chains
        linksOut = s.linksOut
        linksIn = s.linksIn
        for (id, check) in s.savedChecks where checks[id] == nil {
            checks[id] = check.results
            lastCheck[id] = check.date
        }
        map.catalogue = s.catalogue
        // A removed project or service stays remembered otherwise; its row would lead nowhere.
        recent.removeAll { item in
            switch item {
            case .project(let id): project(id) == nil
            case .service(let id): service(id) == nil
            default: false
            }
        }
    }

    func service(_ id: String) -> Service? { serviceByID[id] }
    func services(of project: Project) -> [Service] { services.filter { $0.project == project.id && $0.space == project.space } }

    var projects: [Project] { tree.map(\.project) }
    func project(_ id: String) -> Project? { projectByID[id] }

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

    struct Place: Hashable {
        let selection: MainWindow.SidebarItem
        /// Only for `.map`: where the map was.
        var level: MapState.Level?
        var space, project, service: String?
    }

    private func visit() {
        guard !restoring, let selection else { return }
        if selection == .map, map.space.isEmpty || !spaces.contains(where: { $0.id == map.space }) { map.space = spaces.first?.id ?? "" }
        history.visit(selection == .map ? Place(selection: .map, level: map.level, space: map.space, project: map.project, service: map.service)
                                        : Place(selection: selection))
    }

    func goBack() { history.back().map(go) }
    func goForward() { history.forward().map(go) }

    private func go(to place: Place) {
        restoring = true
        defer { restoring = false }
        if let level = place.level {
            map.level = level; map.space = place.space ?? map.space; map.project = place.project; map.service = place.service
            map.pinned = nil; map.hover = nil
        }
        selection = place.selection
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
        await loadClones()
        for repo in project.repos.map(\.repo) {
            if let path = clones[repo] { gitStates[repo] = await Repos.gitState(ofClone: path) }
        }
    }

    /// The walk is done once per set of roots and again after the window comes back
    /// (`forgetClones`): a clone made meanwhile shows up then.
    func loadClones() async {
        let roots = registry.searchRoots
        guard clonesRoots != roots else { return }
        clonesRoots = roots
        clones = await Task.detached { Repos.clones(roots: roots) }.value
    }

    func forgetClones() { clonesRoots = nil }
    @ObservationIgnored private var clonesRoots: [String]?

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
            try await Registry().assign(repo, to: project)
            unassigned?.removeAll { $0.repo == repo }
            await reload()
        } catch { fail("назначить репозиторий", error) }
    }

    func ignore(_ repo: RepoID, in space: String, _ ignored: Bool = true) async {
        do {
            try await Registry().ignore(repo, in: space, ignored)
            if let i = unassigned?.firstIndex(where: { $0.repo == repo }) { unassigned?[i].ignored = ignored }
            await reload()
        } catch { fail(ignored ? "скрыть репозиторий" : "вернуть репозиторий", error) }
    }

    /// `trash`: clone folders to move to the Trash once the card is gone (the user's choice in the sheet).
    func remove(project id: String, ignoreRepos: Bool = true, trash: [String] = []) async {
        let space = project(id)?.space
        do {
            _ = try await Registry().remove(project: id, ignoreRepos: ignoreRepos)
            for path in trash { try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil) }
        } catch { fail("удалить проект \(id)", error) }
        if let space { selection = .space(space) }
        await reload()
        await refreshPending()
    }

    /// Services and links the project's clones give (`practicesctl scan <id> --write`), left for acceptance.
    func scanLinks(of id: String) async {
        let (registry, store) = (Registry(), store)
        // The scan walks the clones: off the main thread.
        do { _ = try await Task.detached { try Scanner.write(try Scanner.scan([id], registry: registry, store: store), registry: registry) }.value }
        catch { fail("найти связи в коде \(id)", error) }
        await reload()
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
        do { try await Registry().accept(space: change?.space, paths: change.map { [$0.path] } ?? []) } catch { fail("принять " + (change?.path ?? "изменения"), error) }
        await reload()
        await refreshPending()
    }

    /// Drops one pending change: the file goes back to what the catalogue holds.
    func discard(_ change: Pending) async {
        do { try await Registry().discard(change) } catch { fail("отклонить " + change.path, error) }
        await reload()
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
    nonisolated static var checksURL: URL { PracticesHome.url.appendingPathComponent("checks.json") }

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
            Task { await reload() }
        } catch {
            fail("сохранить \(key)", error)
        }
    }

    func unset(key: String, service id: String, env: String) {
        do {
            try store.remove(key: key, service: id, env: env)
            Task { await reload() }
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
    func condition(_ id: String) -> Condition? { conditions.values.lazy.flatMap { $0 }.first { $0.id == id } }
    func links(of id: String) -> [Link] { linksOut[id] ?? [] }
    func links(to id: String) -> [(from: String, link: Link)] { linksIn[id] ?? [] }

    /// A document is a link, a file in a repository's clone, or a file under the card's `docs/`.
    func open(_ doc: ServiceDoc, of id: String) async {
        if let url = doc.url.flatMap(URL.init(string:)) { NSWorkspace.shared.open(url); return }
        guard let path = doc.path else { return }
        if doc.repo != nil { await loadClones() }
        let base = doc.repo.map { clones[$0].map(URL.init(fileURLWithPath:)) }
            ?? registry.dir(of: id)?.appendingPathComponent("docs")
        guard let file = path.hasPrefix("/") ? URL(fileURLWithPath: path) : base?.appendingPathComponent(path) else { return }
        NSWorkspace.shared.open(file)
    }

    func revealService(_ id: String) {
        guard let dir = registry.dir(of: id) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([dir.appendingPathComponent("service.yaml")])
    }
}

/// The last results of checks as `checks.json` keeps them.
struct SavedCheck: Codable { let date: Date; let results: [CheckResult] }

/// What `RegistryModel.reload` reads from disk, built off the main thread. Derived lists the
/// views ask for on every render (by id, links of a service) are made here once.
struct CatalogueSnapshot: Sendable {
    let stamp: Int
    let registry: Registry
    var spaces: [Space] = []
    var tree: [(project: Project, depth: Int)] = []
    var childProjects: [String: [Project]] = [:]
    var topProjects: [Project] = []
    var projectByID: [String: Project] = [:]
    var conditions: [String: [Condition]] = [:]
    var services: [Service] = []
    var serviceByID: [String: Service] = [:]
    var projectPaths: [String: String] = [:]
    var keyStatus: [String: [String: Set<String>]] = [:]
    var practices: [String: [Practice]] = [:]
    var chains: [String: [Practice]] = [:]
    var catalogue: Catalogue
    var linksOut: [String: [Link]] = [:]
    var linksIn: [String: [(from: String, link: Link)]] = [:]
    var savedChecks: [String: SavedCheck] = [:]

    init(stamp: Int, store: SecretStore) throws {
        self.stamp = stamp
        let registry = Registry().indexed()
        self.registry = registry
        // Ids are unique by rule, not by construction: a card written by hand may repeat one,
        // and the window must still open to show it.
        func first<T>(_ a: T, _: T) -> T { a }
        spaces = try registry.spaces()
        catalogue = try registry.catalogue()
        tree = Registry.tree(catalogue.projects)
        projectByID = Dictionary(catalogue.projects.map { ($0.id, $0) }, uniquingKeysWith: first)
        // The tree is a preorder: the last project of a smaller depth is the parent.
        var above: [Project] = []
        for (project, depth) in tree {
            above.removeLast(above.count - depth)
            if let parent = above.last { childProjects[parent.id, default: []].append(project) } else { topProjects.append(project) }
            above.append(project)
            projectPaths[project.id] = projectPaths[project.id] ?? ([project.space] + above.map(\.id)).joined(separator: " / ")
        }
        conditions = Dictionary(spaces.map { ($0.id, registry.conditions(space: $0.id)) }, uniquingKeysWith: first)
        services = catalogue.services
        serviceByID = Dictionary(services.map { ($0.id, $0) }, uniquingKeysWith: first)
        keyStatus = (try? store.status(of: services)) ?? [:]
        let practiceStore = PracticeStore(registry: registry)
        practices = Dictionary(services.map { ($0.id, practiceStore.list(service: $0.id)) }, uniquingKeysWith: first)
        chains = Dictionary(catalogue.projects.map { ($0.id, practiceStore.chains(project: $0.id)) }, uniquingKeysWith: first)
        for (from, link) in catalogue.links {
            linksOut[from, default: []].append(link)
            linksIn[link.to, default: []].append((from, link))
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: RegistryModel.checksURL),
           let saved = try? decoder.decode([String: SavedCheck].self, from: data) { savedChecks = saved }
    }

    /// Every file and folder under the spaces (their `.git` aside), `local.yaml` and the secrets, by
    /// path, modification time and size: what an agent's edit, a new card or a removed one changes.
    /// About 600 entries: a few milliseconds, against a full read.
    static func stamp(of registry: Registry, store: SecretStore) -> Int {
        var hasher = Hasher()
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        func add(_ url: URL) {
            let values = try? url.resourceValues(forKeys: Set(keys))
            hasher.combine(url.path)
            hasher.combine(values?.contentModificationDate)
            hasher.combine(values?.fileSize)
        }
        for url in [registry.home.appendingPathComponent("local.yaml"), store.url, registry.root] { add(url) }
        for id in registry.spaceIDs() {
            let dir = registry.dir(ofSpace: id)
            add(dir)
            guard let walk = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys) else { continue }
            for case let url as URL in walk {
                if url.lastPathComponent == ".git" { walk.skipDescendants(); continue }
                add(url)
            }
        }
        return hasher.finalize()
    }
}
