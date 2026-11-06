import SwiftUI
import AppKit
import PracticesCore

/// The main window: services on the left, a service card or Doctor on the right. The app lives
/// in the menu bar; while this window is open it also shows in the Dock and ⌘Tab.
struct MainWindow: View {
    static let id = "main"

    @Environment(RegistryModel.self) private var registry
    @Environment(MonitorModel.self) private var monitor
    enum SidebarItem: Hashable {
        case service(String)
        case practice(String)
        case conflicts
        case doctor
    }

    var body: some View {
        @Bindable var registry = registry
        NavigationSplitView {
            List(selection: $registry.selection) {
                Section("Services") {
                    ForEach(registry.services) { service in
                        let practices = registry.practices[service.id] ?? []
                        if practices.isEmpty {
                            serviceRow(service)
                        } else {
                            DisclosureGroup {
                                ForEach(practices) { p in
                                    Label { Text(verbatim: p.name).lineLimit(1) } icon: {
                                        Image(systemName: "chevron.left.forwardslash.chevron.right").foregroundStyle(.secondary)
                                    }
                                    .tag(SidebarItem.practice(p.ref))
                                }
                            } label: {
                                serviceRow(service)
                            }
                        }
                    }
                }
                if !registry.chains.isEmpty {
                    Section("Chains") {
                        ForEach(registry.chains) { chain in
                            Label { Text(verbatim: chain.name).lineLimit(1) } icon: {
                                Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(.secondary)
                            }
                            .tag(SidebarItem.practice(chain.ref))
                        }
                    }
                }
                Section {
                    Label {
                        HStack {
                            Text("Port conflicts")
                            Spacer()
                            if !monitor.conflicts.isEmpty {
                                Text(verbatim: String(monitor.conflicts.count)).foregroundStyle(.orange).font(.caption)
                            }
                        }
                    } icon: {
                        Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                    }
                    .tag(SidebarItem.conflicts)
                    Label {
                        HStack {
                            Text("Doctor")
                            Spacer()
                            if let count = registry.findings?.count, count > 0 {
                                Text(verbatim: String(count)).foregroundStyle(.orange).font(.caption)
                            }
                        }
                    } icon: {
                        Image(systemName: "stethoscope")
                    }
                    .tag(SidebarItem.doctor)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            if registry.searchText.trimmingCharacters(in: .whitespaces).count >= 2 {
                SearchView(query: registry.searchText) { item in
                    registry.searchText = ""
                    registry.selection = item
                }
            } else {
                switch registry.selection {
                case .service(let id):
                    if let service = registry.service(id) { ServiceView(service: service) } else { placeholder }
                case .practice(let ref):
                    PracticeView(model: registry.model(for: ref)).id(ref)
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
        .frame(minWidth: 900, minHeight: 600)
        .onAppear {
            registry.reload()
            if registry.selection == nil, let first = registry.services.first { registry.selection = .service(first.id) }
            guard !CommandLine.arguments.contains("--render-window") else { return }
            NSApp.setActivationPolicy(.regular)
            Task { await registry.scanCopies() }
        }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
    }

    private func serviceRow(_ service: Service) -> some View {
        HStack(spacing: 8) {
            HealthDot(health: registry.health(of: service.id))
                .help(registry.lastCheck[service.id].map { String(localized: "Last check \($0.formatted(date: .abbreviated, time: .shortened))") }
                      ?? String(localized: "Not checked yet"))
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: service.name).lineLimit(1)
                Text(verbatim: registry.projectPaths[service.project] ?? service.project)
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            Spacer()
            if registry.checking.contains(service.id) { ProgressView().controlSize(.mini) }
        }
        .tag(SidebarItem.service(service.id))
    }

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
