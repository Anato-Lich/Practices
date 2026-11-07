import SwiftUI
import PracticesCore

/// What agents wrote into the spaces and the user has not accepted: files by space, the diff
/// of the chosen one, and the commit that accepts it (DECISIONS 19).
struct PendingView: View {
    @Environment(RegistryModel.self) private var registry
    @State private var selected: Pending?
    @State private var diff = ""

    var body: some View {
        Group {
            if registry.pending.isEmpty {
                ContentUnavailableView("Nothing pending", systemImage: "checkmark.seal",
                                       description: Text("What agents write into the spaces waits here until you accept it."))
            } else {
                HStack(spacing: 0) {
                    List {
                        ForEach(registry.spaces.filter { space in registry.pending.contains { $0.space == space.id } }) { space in
                            Section {
                                ForEach(registry.pending.filter { $0.space == space.id }, id: \.self) { row($0) }
                            } header: {
                                Text(verbatim: space.name)
                            }
                        }
                    }
                    .frame(width: 340)
                    Divider()
                    VStack(spacing: 0) {
                        if let selected {
                            HStack(spacing: 10) {
                                Text(verbatim: selected.path).font(.callout.monospaced()).lineLimit(1).truncationMode(.head)
                                    .textSelection(.enabled)
                                Spacer()
                                Button("Accept") { Task { await registry.accept(selected) } }
                            }
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            Divider()
                        }
                        MonoText(text: diff)
                    }
                }
            }
        }
        .navigationTitle("Pending")
        .toolbar {
            ToolbarItem {
                Button { Task { await registry.refreshPending() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            }
            ToolbarItem {
                Button("Accept all") { Task { await registry.accept() } }.disabled(registry.pending.isEmpty)
            }
        }
        .task(id: registry.pending) {
            if let selected, registry.pending.contains(selected) { return }
            selected = registry.pending.first
        }
        .task(id: selected) {
            if let selected { diff = await registry.diff(of: selected) } else { diff = "" }
        }
    }

    // A button, not a list selection: the file stays chosen while the window is not key.
    private func row(_ change: Pending) -> some View {
        Button { selected = change } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: (change.path as NSString).lastPathComponent).font(.callout.monospaced()).lineLimit(1)
                    Text(verbatim: (change.path as NSString).deletingLastPathComponent)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
                Spacer()
                Text(LocalizedStringKey(change.state)).font(.caption)
                    .foregroundStyle(change.state == "new" ? Color.green : change.state == "deleted" ? .red : .orange)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(selected == change ? RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.18)).padding(.horizontal, 6) : nil)
    }
}
