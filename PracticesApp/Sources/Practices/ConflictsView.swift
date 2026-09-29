import SwiftUI
import PracticesCore

/// Ports compose files want that something else already holds — in the window only; the
/// menu-bar popover stays about what is running now.
struct ConflictsView: View {
    @Environment(MonitorModel.self) private var monitor
    @State private var scanning = false

    var body: some View {
        let conflicts = monitor.conflicts
        Group {
            if monitor.composeScan == nil {
                ProgressView("Reading compose files in ~/Projects…")
            } else if conflicts.isEmpty {
                ContentUnavailableView("No port conflicts", systemImage: "checkmark.circle",
                                       description: Text("Every port the compose files in ~/Projects publish is free or held by its own service."))
            } else {
                List {
                    Section {
                        ForEach(conflicts) { ConflictRow(conflict: $0) }
                    } footer: {
                        Text("A service that wants a taken port fails on `docker compose up`. Under OrbStack it answers at service.project.orb.local without publishing the port.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Port conflicts")
        .toolbar {
            ToolbarItem {
                Button {
                    scanning = true
                    Task { await monitor.refresh(); await monitor.rescanCompose(); scanning = false }
                } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                    .disabled(scanning)
            }
        }
        .task {
            await monitor.refresh()
            if (monitor.composeScan?.date.timeIntervalSinceNow ?? -.infinity) < -60 { await monitor.rescanCompose() }
        }
    }
}
