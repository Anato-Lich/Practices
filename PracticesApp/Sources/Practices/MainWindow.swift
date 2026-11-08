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
        case settings
    }

    var body: some View {
        HStack(spacing: 0) {
            if sidebarShown {
                Sidebar(shown: $sidebarShown)
                Theme.Color.border.frame(width: 1)
            }
            VStack(spacing: 0) {
                Color.clear.frame(height: 52)
                if let failed = registry.failed { ErrorBar(what: failed.what, text: failed.text) }
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.Color.windowBg)
                StatusBar(items: statusItems,
                          alert: registry.failed.map { "последняя операция с ошибкой · " + $0.at.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)) })
            }
            .overlayPreferenceValue(ShellToolbarKey.self, alignment: .top) { toolbar($0) }
        }
        .background(Theme.Color.windowBg)
        .foregroundStyle(Theme.Color.text)
        .ignoresSafeArea(.container, edges: .top)
        .overlay { SwipeArrow() }
        .overlay { Palette() }
        .preferredColorScheme(.dark)
        .overlay(alignment: .top) {
            if let id = registry.removalCandidate, let project = registry.project(id) {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.45).onTapGesture { registry.removalCandidate = nil }
                    HStack(spacing: 0) {
                        if sidebarShown { Color.clear.frame(width: 261, height: 0) }
                        RemoveProjectSheet(project: project).frame(maxWidth: .infinity)
                    }
                    .padding(.top, 52)
                }
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .onAppear {
            pickFirstScreen()
            guard !CommandLine.arguments.contains("--render-window") else { return }
            // The window is up with the catalogue last read; a newer one replaces it when ready.
            Task {
                await registry.reload(ifChanged: true)
                pickFirstScreen()
            }
            NSApp.setActivationPolicy(.regular)
            Task { await registry.scanCopies() }
        }
        // Agents write to the spaces while the window is in the background: coming back to it
        // shows what they left. Local files and `git status` only, off the main thread; «Настройка»
        // and «Начало» check the setup themselves.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            registry.forgetClones()
            Task {
                await registry.reload(ifChanged: true)
                await registry.refreshPending()
            }
        }
        .task { await registry.refreshPending() }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
    }

    /// A first launch opens on the first space, or on «Начало» when there is none.
    private func pickFirstScreen() {
        guard registry.loaded else { return }
        if registry.selection == nil, let first = registry.spaces.first { registry.selection = .space(first.id) }
        if registry.spaces.isEmpty, registry.selection == nil { registry.welcomeShown = true }
    }

    @ViewBuilder private var detail: some View {
        if registry.welcomeShown {
            WelcomeView()
        } else if registry.spaces.isEmpty && registry.selection != .settings {
            EmptyState(glyph: "∅", tint: Theme.Color.link, title: "Пока нет пространств",
                       text: "Склонируйте пространство или создайте новое — на экране «Начало» или в «Настройке».") {
                StateButton("Начало", prominent: true) { registry.welcomeShown = true }
                StateButton("Настройка") { registry.selection = .settings }
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
        } else if registry.searchText.trimmingCharacters(in: .whitespaces).count >= 2 {
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
            case .settings:
                SettingsView()
            case nil:
                placeholder
            }
        }
    }

    // MARK: Toolbar

    private func toolbar(_ slots: ShellToolbar) -> some View {
        HStack(spacing: 10) {
            if !sidebarShown { SidebarToggle(shown: $sidebarShown) }
            NavigationButtons()
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
                HStack(spacing: 12) {
                    Text(verbatim: registry.spaces.first { $0.id == id }?.name ?? id).font(Theme.ui(15, .semibold)).foregroundStyle(Theme.Color.text)
                    Text(verbatim: abbreviated(registry.registry.dir(ofSpace: id))).font(Theme.mono(12)).foregroundStyle(Theme.Color.textMuted)
                }
                .lineLimit(1)
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
            case .settings: Breadcrumb(prefix: tilde(PracticesHome.url.path) + "/", title: "Настройка", monoTitle: false)
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

/// «Не удалось <что>» under the toolbar (`design/States.dc.html`). No «Повторить»: the model keeps no retry.
private struct ErrorBar: View {
    @Environment(RegistryModel.self) private var registry
    let what: String
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Text(verbatim: "✕").font(Theme.mono(12, .semibold)).foregroundStyle(Theme.Color.error)
            Text(verbatim: "Не удалось " + what).font(Theme.ui(12)).lineLimit(1).fixedSize()
            Text(verbatim: text.replacingOccurrences(of: "\n", with: " ")).font(Theme.mono(11.5)).foregroundStyle(Theme.Color.textSecondary)
                .lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
                .help(text)
            Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) } label: {
                Text(verbatim: "Скопировать текст")
            }
            .buttonStyle(CompactButtonStyle(height: 22, fontSize: 11.5))
            Button { registry.failed = nil } label: {
                Text(verbatim: "×").font(Theme.ui(13)).foregroundStyle(Theme.Color.textMuted).frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help(Text(verbatim: "Закрыть"))
        }
        .padding(.horizontal, 20)
        .frame(height: 32)
        .background(Theme.Color.error.opacity(0.12))
        .overlay(alignment: .bottom) { Theme.Color.error.opacity(0.45).frame(height: 1) }
    }
}

/// The removal of a project, confirmed with the registry's numbers (`design/ProjectDelete.dc.html`):
/// a 480 px sheet under the toolbar. Only the catalogue's record goes; folders on disk stay.
private struct RemoveProjectSheet: View {
    @Environment(RegistryModel.self) private var registry
    let project: Project
    @State private var keepRepos = false
    @State private var trashClones = false

    var body: some View {
        let services = registry.services(of: project)
        let ids = Set(services.map(\.id))
        let practices = services.reduce(0) { $0 + (registry.practices[$1.id]?.count ?? 0) } + (registry.chains[project.id]?.count ?? 0)
        let own = services.reduce(0) { $0 + registry.links(of: $1.id).count }
        let dangling = services.flatMap { s in registry.links(to: s.id).filter { !ids.contains($0.from) }.map { "\($0.from) → \(s.id)" } }
        let clones = project.repos.compactMap { registry.clones[$0.repo] }
        let clone = clones.first.map { ($0 as NSString).abbreviatingWithTildeInPath }

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Text(verbatim: "!").font(Theme.mono(16, .semibold)).foregroundStyle(Theme.Color.error)
                    .frame(width: 32, height: 32).background(Theme.Color.error.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 4) {
                    (Text(verbatim: "Удалить проект ") + Text(verbatim: project.id).font(Theme.mono(15, .semibold)) + Text(verbatim: " из каталога?"))
                        .font(Theme.ui(15, .semibold))
                    Group {
                        if let clone, !trashClones {
                            Text(verbatim: "Папка ") + Text(verbatim: clone).font(Theme.mono(12)) + Text(verbatim: " и репозитории на хостинге не трогаются.")
                        } else {
                            Text(verbatim: "Репозитории на хостинге и их история не трогаются.")
                        }
                    }
                    .font(Theme.ui(12)).foregroundStyle(Theme.Color.textSecondary)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                bullet(bold(ru(services.count, "сервис", "сервиса", "сервисов")) + Text(verbatim: " и ")
                       + bold(ru(practices, "практика", "практики", "практик")) + Text(verbatim: " уйдут из каталога вместе с заметками и полями"))
                if !project.repos.isEmpty {
                    let repos = bold(ru(project.repos.count, "репозиторий", "репозитория", "репозиториев"))
                    bullet(repos + Text(verbatim: keepRepos ? " останутся в «Не распределено»" : " попадут в ignore — «Не распределено» их больше не предложит"))
                }
                bullet(bold(ru(own, "связь", "связи", "связей")) + Text(verbatim: " из \(project.id) удалятся")
                       + (dangling.isEmpty ? Text(verbatim: "")
                          : Text(verbatim: "; ") + bold(ru(dangling.count, "связь повиснет", "связи повиснут", "связей повиснут"), Theme.Color.warn)
                            + Text(verbatim: ": \(dangling[0])" + (dangling.count > 1 ? " и другие останутся у вызывающих" : " останется у вызывающего") + " с пометкой «цели нет»")))
                if practices > 0 {
                    bullet(Text(verbatim: "Запуски практик и копии ") + Text(verbatim: "practices:").font(Theme.mono(12))
                           + Text(verbatim: " в чужом коде останутся, но перестанут сверяться с версией"))
                }
            }
            if !project.repos.isEmpty {
                Toggle(isOn: $keepRepos) { Text(verbatim: "Не помечать репозитории ignore — оставить в «Не распределено»") }
                    .toggleStyle(.checkbox).font(Theme.ui(12)).foregroundStyle(Theme.Color.textSecondary)
            }
            if !clones.isEmpty {
                Toggle(isOn: $trashClones) {
                    Text(verbatim: clones.count == 1 ? "Удалить клон с диска (в Корзину): " : "Удалить клоны с диска (в Корзину): ")
                        + Text(verbatim: clones.map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: ", ")).font(Theme.mono(11))
                }
                .toggleStyle(.checkbox).font(Theme.ui(12)).foregroundStyle(Theme.Color.textSecondary)
            }
            HStack(spacing: 8) {
                Text(verbatim: "Запись в личной истории каталога (\(tilde(PracticesHome.url.path))): откатить можно через неё.")
                    .font(Theme.ui(11)).foregroundStyle(Theme.Color.textMuted).frame(maxWidth: .infinity, alignment: .leading)
                Button { registry.removalCandidate = nil } label: { Text(verbatim: "Отмена") }
                    .buttonStyle(CompactButtonStyle(height: 28)).keyboardShortcut(.cancelAction)
                Button {
                    registry.removalCandidate = nil
                    Task { await registry.remove(project: project.id, ignoreRepos: !keepRepos, trash: trashClones ? clones : []) }
                } label: { Text(verbatim: "Удалить").font(Theme.ui(13, .semibold)).foregroundStyle(Theme.Color.error) }
                    .buttonStyle(DestructiveButtonStyle())
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 480, alignment: .leading)
        .background(Theme.Color.cardBg)
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12))
        .overlay(UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12).strokeBorder(Theme.Color.borderButton))
        .shadow(color: .black.opacity(0.6), radius: 30, y: 24)
        .task(id: project.id) { await registry.loadGitStates(of: project) }
    }

    private func bold(_ s: String, _ color: Color = Theme.Color.text) -> Text { Text(verbatim: s).bold().foregroundColor(color) }

    private func bullet(_ text: Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: "•")
            text.fixedSize(horizontal: false, vertical: true)
        }
        .font(Theme.ui(12.5)).foregroundStyle(Theme.Color.textCode)
    }
}

/// 28 high, error outline on no fill: the sheet's «Удалить».
private struct DestructiveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 14).frame(height: 28)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.Color.error))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Rectangle())
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
