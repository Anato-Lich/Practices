import SwiftUI
import AppKit
import PracticesCore

/// The main window (`design/Main.dc.html`): the sidebar, then a 52-high toolbar with the
/// breadcrumb and the screen's buttons, the card, a 24-high status bar. The app lives in the
/// menu bar; while this window is open it also shows in the Dock and ⌘Tab.
struct MainWindow: View {
    static let id = "main"

    @Environment(RegistryModel.self) private var registry
    @State private var sidebarShown = true

    enum SidebarItem: Hashable, Codable {
        case space(String)
        case project(String)
        case service(String)
        case practice(String)
        case pending
        case unassigned
        case map
        case doctor
    }

    var body: some View {
        HStack(spacing: 0) {
            if sidebarShown {
                Sidebar(shown: $sidebarShown)
                Theme.Color.border.frame(width: 1)
            }
            VStack(spacing: 0) {
                Color.clear.frame(height: 52)
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.Color.windowBg)
                StatusBar(items: statusItems)
            }
            .overlayPreferenceValue(ShellToolbarKey.self, alignment: .top) { toolbar($0) }
        }
        .background(Theme.Color.windowBg)
        .foregroundStyle(Theme.Color.text)
        .ignoresSafeArea(.container, edges: .top)
        .overlay { Palette() }
        .preferredColorScheme(.dark)
        .alert(Text(verbatim: "Practices"), isPresented: Binding(get: { registry.error != nil }, set: { if !$0 { registry.error = nil } })) {
        } message: {
            Text(verbatim: registry.error ?? "")
        }
        .confirmationDialog(Text(verbatim: "Удалить проект \(registry.removalCandidate ?? "")?"),
                            isPresented: Binding(get: { registry.removalCandidate != nil }, set: { if !$0 { registry.removalCandidate = nil } })) {
            Button(role: .destructive) {
                if let id = registry.removalCandidate { Task { await registry.remove(project: id) } }
            } label: { Text(verbatim: "Удалить") }
            Button(role: .cancel) {} label: { Text(verbatim: "Отмена") }
        } message: {
            let id = registry.removalCandidate ?? ""
            let ids = registry.services.filter { $0.project == id }.map(\.id)
            let dangling = ids.flatMap { registry.registry.links(to: $0).filter { !ids.contains($0.from) } }.count
            Text(verbatim: "Сервисы проекта (\(ids.count)) будут удалены, его репозитории попадут в ignore пространства. Связи из других сервисов на них останутся висеть: \(dangling).")
        }
        .frame(minWidth: 900, minHeight: 600)
        .onAppear {
            registry.reload()
            if registry.selection == nil, let first = registry.spaces.first { registry.selection = .space(first.id) }
            guard !CommandLine.arguments.contains("--render-window") else { return }
            NSApp.setActivationPolicy(.regular)
            Task { await registry.scanCopies() }
        }
        // Agents write to the spaces while the window is in the background: coming back to it
        // shows what they left. Local files and `git status` only.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            registry.reload()
            Task { await registry.refreshPending() }
        }
        .task { await registry.refreshPending() }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
    }

    @ViewBuilder private var detail: some View {
        if registry.searchText.trimmingCharacters(in: .whitespaces).count >= 2 {
            SearchView(query: registry.searchText) { item in
                registry.searchText = ""
                registry.selection = item
            }
        } else {
            switch registry.selection {
            case .space(let id):
                if let space = registry.spaces.first(where: { $0.id == id }) { SpaceView(space: space) } else { placeholder }
            case .project(let id):
                if let project = registry.project(id) { ProjectView(project: project) } else { placeholder }
            case .service(let id):
                if let service = registry.service(id) { ServiceView(service: service) } else { placeholder }
            case .practice(let ref):
                PracticeView(model: registry.model(for: ref)).id(ref)
            case .pending:
                PendingView()
            case .unassigned:
                UnassignedView()
            case .map:
                MapView()
            case .doctor:
                DoctorView()
            case nil:
                placeholder
            }
        }
    }

    // MARK: Toolbar

    private func toolbar(_ slots: ShellToolbar) -> some View {
        HStack(spacing: 10) {
            if !sidebarShown { SidebarToggle(shown: $sidebarShown) }
            if let leading = slots.leading { leading } else { breadcrumb }
            Spacer(minLength: 10)
            HStack(spacing: 6) {
                if let trailing = slots.trailing { trailing } else { defaultTrailing }
            }
            .buttonStyle(ToolbarButtonStyle())
            .labelStyle(GapLabelStyle())
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
        .background(Theme.Color.toolbarBg.gesture(WindowDragGesture()))
        .overlay(alignment: .bottom) { Theme.Color.border.frame(height: 1) }
    }

    /// `~/.practices/spaces/` **x-keeper**; `space / project / ` **id** — each part a link, projects in their zone colour.
    @ViewBuilder private var breadcrumb: some View {
        if registry.searchText.trimmingCharacters(in: .whitespaces).count >= 2 {
            Breadcrumb(title: "Поиск", monoTitle: false)
        } else {
            switch registry.selection {
            case .space(let id):
                Breadcrumb(prefix: abbreviated(registry.registry.dir(ofSpace: id).deletingLastPathComponent()) + "/", title: id)
            case .project(let id):
                Breadcrumb(crumbs: crumbs(space: registry.project(id)?.space, project: registry.project(id)?.parent), title: id)
            case .service(let id):
                Breadcrumb(crumbs: crumbs(space: registry.service(id)?.space, project: registry.service(id)?.project), title: id)
            case .practice(let ref):
                let practice = Practice(ref: ref)
                if let service = practice.service.flatMap(registry.service) {
                    Breadcrumb(crumbs: crumbs(space: service.space, project: service.project)
                               + [Crumb(label: service.id, color: ServiceClass(for: service).color) { registry.selection = .service(service.id) }],
                               title: practice.name)
                } else {
                    let project = registry.chains.first { $0.value.contains(practice) }?.key
                    Breadcrumb(crumbs: crumbs(space: project.flatMap(registry.project)?.space, project: project), title: practice.name)
                }
            case .pending: Breadcrumb(title: "Ждут приёмки", monoTitle: false)
            case .unassigned: Breadcrumb(title: "Не распределено", monoTitle: false)
            case .map: Breadcrumb(title: "Карта", monoTitle: false)
            case .doctor: Breadcrumb(title: "Doctor", monoTitle: false)
            case nil: EmptyView()
            }
        }
    }

    /// The space, then the project and its ancestors, outermost first.
    private func crumbs(space: String?, project: String?) -> [Crumb] {
        let spaceCrumb = space.map { id in Crumb(label: id) { registry.selection = .space(id) } }
        let projects = project.map(registry.path(of:)) ?? []
        return [spaceCrumb].compactMap { $0 }
            + projects.map { p in Crumb(label: p.id, color: registry.zoneColor(of: p.id)) { registry.selection = .project(p.id) } }
    }

    @ViewBuilder private var defaultTrailing: some View {
        if case .space = registry.selection {
            Button { registry.selection = .map } label: { Label { Text(verbatim: "Карта") } icon: { Image(systemName: "point.3.connected.trianglepath.dotted") } }
            Button { Task { await registry.checkAll() } } label: { Label { Text(verbatim: "Проверить всё") } icon: { Image(systemName: "checkmark.circle") } }
                .help("Check conditions and endpoints of every service — nothing is checked without asking")
        }
    }

    // MARK: Status bar

    /// The selected card's file and its space's git state; elsewhere the git state of every space.
    private var statusItems: [String] {
        let r = registry.registry
        func underSpace(_ url: URL?, _ space: String) -> String? {
            guard let url else { return nil }
            let root = r.dir(ofSpace: space).path
            return url.path.hasPrefix(root) ? "…" + url.path.dropFirst(root.count) : abbreviated(url)
        }
        let (path, space): (String?, String?) = switch registry.selection {
        case .space(let id): (abbreviated(r.dir(ofSpace: id)), id)
        case .project(let id): (r.dir(ofProject: id).map(abbreviated), registry.project(id)?.space)
        case .service(let id):
            (registry.service(id).flatMap { underSpace(r.dir(of: $0.id)?.appendingPathComponent("service.yaml"), $0.space) }, registry.service(id)?.space)
        case .practice(let ref):
            Practice(ref: ref).service.flatMap(registry.service).map { service in
                (underSpace(r.dir(of: service.id)?.appendingPathComponent("practices/\(Practice(ref: ref).name).py"), service.space), service.space)
            } ?? (nil, nil)
        default: (nil, nil)
        }
        if let space { return [path, registry.spaceGit[space].map(gitLabel)].compactMap { $0 } }
        return registry.spaces.compactMap { s in registry.spaceGit[s.id].map { "\(s.id): " + gitLabel($0) } }
    }

    private func gitLabel(_ git: GitState) -> String {
        (git.branch ?? "HEAD") + " · " + (git.uncommitted == 0 ? "чисто" : ru(git.uncommitted, "незакоммиченный", "незакоммиченных", "незакоммиченных"))
    }

    private func abbreviated(_ url: URL) -> String { (url.path as NSString).abbreviatingWithTildeInPath }

    private var placeholder: some View {
        ContentUnavailableView {
            Label("No services yet", systemImage: "tray")
        } description: {
            Text("Add one with `practicesctl service add <id> --project <project>`.")
        }
    }
}

struct HealthDot: View {
    let health: RegistryModel.Health
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .help(help)
    }
    private var color: Color {
        switch health {
        case .unknown: .secondary.opacity(0.5)
        case .up: .green
        case .partial: .orange
        case .down: .red
        }
    }
    private var help: LocalizedStringKey {
        switch health {
        case .unknown: "Not checked yet"
        case .up: "All endpoints answer"
        case .partial: "Some endpoints do not answer"
        case .down: "Not reachable"
        }
    }
}
