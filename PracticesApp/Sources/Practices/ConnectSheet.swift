import SwiftUI
import AppKit
import PracticesCore

/// Writes a service's values into a project's env file, once: which file, which environment,
/// which keys under which names. Nothing remembers the file afterwards (DECISIONS 18).
struct ConnectSheet: View {
    @Environment(\.dismiss) private var dismiss
    let service: Service

    @State private var project: URL?
    @State private var file = ".env"
    @State private var existingFiles: [String] = []
    @State private var env = ""
    @State private var rows: [Row] = []
    @State private var plan: [EnvFiles.Line] = []
    @State private var error: String?
    @State private var writing = false

    struct Row: Identifiable {
        let key: String
        var include: Bool
        var variable: String
        var id: String { key }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect \(service.name) to a project").font(.headline)
            HStack {
                Text(verbatim: project.map { short($0.path) } ?? String(localized: "No folder chosen"))
                    .font(.callout.monospaced()).lineLimit(1).truncationMode(.head)
                Spacer()
                Button("Choose a folder…") { pickFolder() }
            }
            HStack {
                Text("File").frame(width: 80, alignment: .leading)
                TextField(".env", text: $file).textFieldStyle(.roundedBorder).font(.callout.monospaced())
                if !existingFiles.isEmpty {
                    Menu("Existing") { ForEach(existingFiles, id: \.self) { f in Button(f) { file = f } } }.fixedSize()
                }
            }
            HStack {
                Text("Environment").frame(width: 80, alignment: .leading)
                Picker("", selection: $env) { ForEach(service.envs, id: \.self) { Text(verbatim: $0).tag($0) } }
                    .labelsHidden().fixedSize()
            }
            Divider()
            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                    ForEach($rows) { $row in
                        GridRow {
                            Toggle("", isOn: $row.include).labelsHidden()
                            Text(verbatim: row.key).font(.caption.monospaced()).foregroundStyle(.secondary)
                            TextField(row.key, text: $row.variable).textFieldStyle(.roundedBorder).font(.callout.monospaced())
                                .frame(minWidth: 220)
                            stateText(for: row)
                        }
                    }
                }
            }
            .frame(minHeight: 180, maxHeight: 340)
            if let error { Text(verbatim: error).font(.caption).foregroundStyle(.red) }
            HStack {
                Text("Values go into the file; its other lines stay as they are. Git-tracked files do not get secrets.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Write") { write() }.keyboardShortcut(.defaultAction)
                    .disabled(project == nil || file.isEmpty || !rows.contains(where: \.include) || writing)
            }
        }
        .padding(20)
        .frame(width: 640)
        .onAppear {
            env = service.defaultEnv
            rows = service.keys.map { Row(key: $0.name, include: true, variable: $0.name) }
        }
        .onChange(of: env) { refreshPlan() }
        .onChange(of: file) { refreshPlan() }
        .onChange(of: rows.map { "\($0.include)\($0.variable)" }) { refreshPlan() }
    }

    private var managed: ManagedFile {
        let included = rows.filter(\.include)
        let aliases = Dictionary(included.filter { $0.variable != $0.key && !$0.variable.isEmpty }.map { ($0.variable, $0.key) },
                                 uniquingKeysWith: { a, _ in a })
        return ManagedFile(path: file, services: [ServiceRef(service: service.id, env: env)], env: aliases,
                           only: included.count == rows.count ? nil : included.map(\.key))
    }

    private func refreshPlan() {
        guard let project else { plan = []; return }
        plan = (try? EnvFiles.plan(managed, project: project)) ?? []
    }

    @ViewBuilder
    private func stateText(for row: Row) -> some View {
        if row.include, let line = plan.first(where: { $0.key == row.key }) {
            switch line.state {
            case .same: Text("same").font(.caption).foregroundStyle(.secondary)
            case .changed: Text("changes").font(.caption).foregroundStyle(.orange)
            case .new: Text("added").font(.caption).foregroundStyle(.green)
            case .missingValue: Text("no value").font(.caption).foregroundStyle(.red)
            }
        } else {
            Text(verbatim: "")
        }
    }

    private func choose(_ dir: URL) {
        project = dir
        existingFiles = Doctor.collect(root: dir.path).env.filter { !$0.contains("/.claude/") }
            .map { $0.hasPrefix(dir.path + "/") ? String($0.dropFirst(dir.path.count + 1)) : $0 }
        refreshPlan()
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/Projects")
        if panel.runModal() == .OK, let url = panel.url { choose(url) }
    }

    private func write() {
        guard let project else { return }
        writing = true
        error = nil
        let file = managed
        Task {
            do {
                try await EnvFiles.write(file, project: project)
                dismiss()
            } catch {
                self.error = String(describing: error)
            }
            writing = false
        }
    }

    private func short(_ path: String) -> String {
        let root = NSHomeDirectory() + "/Projects/"
        return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
    }
}
