import SwiftUI
import AppKit
import PracticesCore

/// The main window: sources on the left, a source card or Doctor on the right. The app lives
/// in the menu bar; while this window is open it also shows in the Dock and ⌘Tab.
struct MainWindow: View {
    static let id = "main"

    @Environment(RegistryModel.self) private var registry
    @Environment(MonitorModel.self) private var monitor
    enum SidebarItem: Hashable {
        case source(String)
        case practice(String)
        case proposals
        case doctor
    }

    var body: some View {
        @Bindable var registry = registry
        NavigationSplitView {
            List(selection: $registry.selection) {
                Section("Sources") {
                    ForEach(registry.sources) { source in
                        let practices = registry.practices[source.id] ?? []
                        if practices.isEmpty {
                            sourceRow(source)
                        } else {
                            DisclosureGroup {
                                ForEach(practices) { p in
                                    Label { Text(verbatim: p.name).lineLimit(1) } icon: {
                                        Image(systemName: "chevron.left.forwardslash.chevron.right").foregroundStyle(.secondary)
                                    }
                                    .tag(SidebarItem.practice(p.ref))
                                }
                            } label: {
                                sourceRow(source)
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
                            Text("Proposals")
                            Spacer()
                            if registry.pendingProposals > 0 {
                                Text(verbatim: String(registry.pendingProposals)).foregroundStyle(.orange).font(.caption)
                            }
                        }
                    } icon: {
                        Image(systemName: "arrow.triangle.pull")
                    }
                    .tag(SidebarItem.proposals)
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
                case .source(let id):
                    if let source = registry.source(id) { SourceView(source: source) } else { placeholder }
                case .practice(let ref):
                    PracticeView(model: registry.model(for: ref)).id(ref)
                case .proposals:
                    ProposalsView()
                case .doctor:
                    DoctorView()
                case nil:
                    placeholder
                }
            }
        }
        .searchable(text: $registry.searchText, placement: .sidebar, prompt: Text("Fields, practices, docs"))
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Picker(selection: $registry.projectPath) {
                    Text("No project · first environments").tag(String?.none)
                    ForEach(registry.projects, id: \.dir.path) { project in
                        Text(verbatim: project.dir.path.replacingOccurrences(of: NSHomeDirectory() + "/Projects/", with: "")
                             + " · " + project.manifest.sources.map(\.description).joined(separator: ", "))
                            .tag(String?.some(project.dir.path))
                    }
                } label: {
                    Label("Project", systemImage: "folder.badge.gearshape")
                }
                .help(registry.projects.isEmpty
                      ? "Projects appear here once they have a practices.yaml (`practicesctl init --write` in the project)."
                      : "Practices run with the environments this project chose")
            }
            ToolbarItem {
                Button { Task { await registry.checkAll() } } label: {
                    Label("Check all", systemImage: "checkmark.circle")
                }
                .help("Check preconditions and targets of every source")
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .onAppear {
            registry.reload()
            registry.reloadProposals()
            if registry.selection == nil, let first = registry.sources.first { registry.selection = .source(first.id) }
            guard !CommandLine.arguments.contains("--render-window") else { return }
            NSApp.setActivationPolicy(.regular)
            Task { await registry.checkAll() }
            Task { await registry.scanCopies() }
        }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
    }

    private func sourceRow(_ source: Source) -> some View {
        HStack(spacing: 8) {
            HealthDot(health: registry.health(of: source.id))
            Text(verbatim: source.name).lineLimit(1)
            Spacer()
            if registry.checking.contains(source.id) { ProgressView().controlSize(.mini) }
        }
        .tag(SidebarItem.source(source.id))
    }

    private var placeholder: some View {
        ContentUnavailableView {
            Label("No sources yet", systemImage: "tray")
        } description: {
            Text("Import the Connectors sources with `practicesctl import connectors`.")
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
        case .up: "All targets answer"
        case .partial: "Some targets do not answer"
        case .down: "Not reachable"
        }
    }
}
