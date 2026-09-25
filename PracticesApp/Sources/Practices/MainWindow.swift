import SwiftUI
import AppKit
import PracticesCore

/// The main window: sources on the left, a source card or Doctor on the right. The app lives
/// in the menu bar; while this window is open it also shows in the Dock and ⌘Tab.
struct MainWindow: View {
    static let id = "main"

    @Environment(RegistryModel.self) private var registry
    @Environment(MonitorModel.self) private var monitor
    @State private var selection: SidebarItem? = nil

    enum SidebarItem: Hashable {
        case source(String)
        case doctor
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Sources") {
                    ForEach(registry.sources) { source in
                        HStack(spacing: 8) {
                            HealthDot(health: registry.health(of: source.id))
                            Text(verbatim: source.name).lineLimit(1)
                            Spacer()
                            if registry.checking.contains(source.id) { ProgressView().controlSize(.mini) }
                        }
                        .tag(SidebarItem.source(source.id))
                    }
                }
                Section {
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
            switch selection {
            case .source(let id):
                if let source = registry.source(id) { SourceView(source: source) } else { placeholder }
            case .doctor:
                DoctorView()
            case nil:
                placeholder
            }
        }
        .toolbar {
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
            if selection == nil, let first = registry.sources.first { selection = .source(first.id) }
            guard !CommandLine.arguments.contains("--render-window") else { return }
            NSApp.setActivationPolicy(.regular)
            Task { await registry.checkAll() }
        }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
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
