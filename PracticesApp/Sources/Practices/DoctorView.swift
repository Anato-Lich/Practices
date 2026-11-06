import SwiftUI
import AppKit
import PracticesCore

/// Doctor's report (mock-up board 3). Only reports: nothing in the projects is changed.
struct DoctorView: View {
    @Environment(RegistryModel.self) private var registry

    var body: some View {
        Group {
            if let findings = registry.findings {
                if findings.isEmpty {
                    ContentUnavailableView("Nothing to report", systemImage: "checkmark.seal")
                } else {
                    List {
                        ForEach(kinds, id: \.self) { kind in
                            let items = findings.filter { $0.kind == kind }
                            if !items.isEmpty {
                                Section {
                                    ForEach(items, id: \.self) { FindingRow(finding: $0) }
                                } header: {
                                    Text(title(kind))
                                } footer: {
                                    Text(footer(kind)).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            } else if registry.doctorRunning {
                ProgressView("Reading ~/Projects…")
            } else {
                ContentUnavailableView {
                    Label("Doctor", systemImage: "stethoscope")
                } description: {
                    Text("Compares .env files and plain text in ~/Projects with the registry. Reports names and paths, never values.")
                } actions: {
                    Button("Run") { Task { await registry.runDoctor() } }
                }
            }
        }
        .navigationTitle("Doctor")
        .toolbar {
            ToolbarItem {
                Button { Task { await registry.runDoctor() } } label: { Label("Run again", systemImage: "arrow.clockwise") }
                    .disabled(registry.doctorRunning)
            }
        }
    }

    private let kinds: [DoctorFinding.Kind] = [.leak, .drift, .shared, .duplicate]

    private func title(_ kind: DoctorFinding.Kind) -> LocalizedStringKey {
        switch kind {
        case .leak: "Secrets in plain text"
        case .drift: "Differs from the registry"
        case .shared: "One secret in several projects"
        case .duplicate: "Copies of the registry"
        }
    }

    private func footer(_ kind: DoctorFinding.Kind) -> LocalizedStringKey {
        switch kind {
        case .leak: "A registry secret is written in a file. Move it out and delete the copy."
        case .drift: "The key exists in the registry with another value. One of them is stale."
        case .shared: "The same value under different names — a service the registry does not have yet."
        case .duplicate: "Every key matches the registry: `practicesctl run` can replace this file."
        }
    }
}

struct FindingRow: View {
    let finding: DoctorFinding

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: short(finding.path)).font(.callout.monospaced())
                Text(verbatim: finding.keys.joined(separator: ", ")).font(.caption.monospaced()).foregroundStyle(.secondary)
                if finding.kind == .shared {
                    ForEach(finding.related, id: \.self) { Text(verbatim: short($0)).font(.caption.monospaced()).foregroundStyle(.secondary) }
                } else if !finding.related.isEmpty {
                    Text(verbatim: finding.related.joined(separator: ", ")).font(.caption).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: finding.path)]) } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("Show in Finder")
        }
        .padding(.vertical, 2)
    }

    private var icon: String {
        switch finding.kind {
        case .leak: "exclamationmark.octagon.fill"
        case .drift: "arrow.triangle.branch"
        case .shared: "square.on.square"
        case .duplicate: "doc.on.doc"
        }
    }

    private var color: Color {
        switch finding.kind {
        case .leak: .red
        case .drift: .orange
        case .shared: .blue
        case .duplicate: .secondary
        }
    }

    private func short(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
