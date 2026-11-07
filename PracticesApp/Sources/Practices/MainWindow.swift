import SwiftUI
import AppKit
import PracticesCore

/// The main window: the catalogue on the left — spaces, their projects (nested), services and
/// practices — and a card on the right. The app lives in the menu bar; while this window is
/// open it also shows in the Dock and ⌘Tab.
struct MainWindow: View {
    static let id = "main"

    @Environment(RegistryModel.self) private var registry
    @Environment(MonitorModel.self) private var monitor
    enum SidebarItem: Hashable {
        case space(String)
        case project(String)
        case service(String)
        case practice(String)
        case pending
        case unassigned
        case conflicts
        case doctor
    }

    var body: some View {
        @Bindable var registry = registry
        NavigationSplitView {
            List(selection: $registry.selection) {
                // Above the tree: with a few dozen projects the end of the list is off screen,
                // and what waits for the user must not be.
                Section {
                    counted("Pending", "tray.and.arrow.down", registry.pending.count).tag(SidebarItem.pending)
                    counted("Unassigned", "questionmark.folder", registry.unassigned?.filter { !$0.ignored }.count ?? 0).tag(SidebarItem.unassigned)
                }
                ForEach(registry.spaces) { space in
                    Section {
                        Label("Overview", systemImage: "square.grid.2x2").tag(SidebarItem.space(space.id))
                        ForEach(registry.topProjects.filter { $0.space == space.id }) { ProjectRows(project: $0) }
                    } header: {
                        Text(verbatim: space.name)
                    }
                }
                Section {
                    counted("Port conflicts", "point.3.filled.connected.trianglepath.dotted", monitor.conflicts.count).tag(SidebarItem.conflicts)
                    counted("Doctor", "stethoscope", registry.findings?.count ?? 0).tag(SidebarItem.doctor)
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
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
                case .conflicts:
                    ConflictsView()
                case .doctor:
                    DoctorView()
                case nil:
                    placeholder
                }
            }
        }
        .searchable(text: $registry.searchText, placement: .sidebar, prompt: Text("Fields, practices, docs"))
        .toolbar {
            ToolbarItem {
                Button { Task { await registry.checkAll() } } label: {
                    Label("Check all", systemImage: "checkmark.circle")
                }
                .help("Check conditions and endpoints of every service — nothing is checked without asking")
            }
        }
        .alert(Text(verbatim: "Practices"), isPresented: Binding(get: { registry.error != nil }, set: { if !$0 { registry.error = nil } })) {
        } message: {
            Text(verbatim: registry.error ?? "")
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

    private func counted(_ title: LocalizedStringKey, _ icon: String, _ count: Int) -> some View {
        Label {
            HStack {
                Text(title)
                Spacer()
                if count > 0 { Text(verbatim: String(count)).foregroundStyle(.orange).font(.caption) }
            }
        } icon: {
            Image(systemName: icon)
        }
    }

    private var placeholder: some View {
        ContentUnavailableView {
            Label("No services yet", systemImage: "tray")
        } description: {
            Text("Add one with `practicesctl service add <id> --project <project>`.")
        }
    }
}

/// A project in the sidebar: the projects inside it, its services — each opening to its
/// practices — and its chains.
struct ProjectRows: View {
    @Environment(RegistryModel.self) private var registry
    let project: Project

    var body: some View {
        let children = registry.childProjects[project.id] ?? []
        let services = registry.services(of: project)
        let chains = registry.chains[project.id] ?? []
        if children.isEmpty && services.isEmpty && chains.isEmpty {
            label
        } else {
            DisclosureGroup(isExpanded: expanded(.project(project.id))) {
                ForEach(children) { ProjectRows(project: $0) }
                ForEach(services) { service in
                    let practices = registry.practices[service.id] ?? []
                    if practices.isEmpty {
                        serviceRow(service)
                    } else {
                        DisclosureGroup(isExpanded: expanded(.service(service.id))) {
                            ForEach(practices) { practiceRow($0, "chevron.left.forwardslash.chevron.right") }
                        } label: {
                            serviceRow(service)
                        }
                    }
                }
                ForEach(chains) { practiceRow($0, "point.3.connected.trianglepath.dotted") }
            } label: {
                label
            }
        }
    }

    private func expanded(_ item: MainWindow.SidebarItem) -> Binding<Bool> {
        Binding(get: { registry.expanded.contains(item) },
                set: { if $0 { registry.expanded.insert(item) } else { registry.expanded.remove(item) } })
    }

    private var label: some View {
        Label { Text(verbatim: project.name).lineLimit(1) } icon: { Image(systemName: "folder") }
            .tag(MainWindow.SidebarItem.project(project.id))
    }

    private func practiceRow(_ practice: Practice, _ icon: String) -> some View {
        Label { Text(verbatim: practice.name).lineLimit(1) } icon: { Image(systemName: icon).foregroundStyle(.secondary) }
            .tag(MainWindow.SidebarItem.practice(practice.ref))
    }

    private func serviceRow(_ service: Service) -> some View {
        HStack(spacing: 8) {
            HealthDot(health: registry.health(of: service.id))
                .help(registry.lastCheck[service.id].map { String(localized: "Last check \($0.formatted(date: .abbreviated, time: .shortened))") }
                      ?? String(localized: "Not checked yet"))
            Text(verbatim: service.name).lineLimit(1)
            Spacer()
            if registry.checking.contains(service.id) { ProgressView().controlSize(.mini) }
        }
        .tag(MainWindow.SidebarItem.service(service.id))
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
