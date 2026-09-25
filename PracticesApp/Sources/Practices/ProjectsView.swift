import SwiftUI
import AppKit
import PracticesCore

/// Env files Practices keeps in projects: which are current, which a sync would change.
struct ProjectsView: View {
    @Environment(RegistryModel.self) private var registry
    @State private var syncing = false

    var body: some View {
        Group {
            if let statuses = registry.fileStatuses {
                if statuses.isEmpty {
                    ContentUnavailableView {
                        Label("No connected files yet", systemImage: "doc.badge.gearshape")
                    } description: {
                        Text("Connect a source to a project from its card (“Connect to project…”), or adopt an existing project with `practicesctl init --write`.")
                    }
                } else {
                    List {
                        ForEach(groups(statuses), id: \.0) { project, files in
                            Section(project) {
                                ForEach(files, id: \.file.path) { s in
                                    HStack(alignment: .firstTextBaseline) {
                                        Image(systemName: s.stale ? "arrow.triangle.2.circlepath" : "checkmark.circle")
                                            .foregroundStyle(s.stale ? .orange : .green)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(verbatim: s.file.path).font(.callout.monospaced())
                                            Text(verbatim: s.file.sources.map(\.description).joined(separator: ", "))
                                                .font(.caption).foregroundStyle(.secondary)
                                            let changes = s.lines.filter { $0.state == .changed || $0.state == .new }
                                            if !changes.isEmpty {
                                                Text(verbatim: changes.map { "\($0.variable) (\($0.state == .new ? "new" : "changed"))" }.joined(separator: ", "))
                                                    .font(.caption.monospaced()).foregroundStyle(.orange)
                                            }
                                            let missing = s.lines.filter { $0.state == .missingValue }
                                            if !missing.isEmpty {
                                                Text("No value in the registry: \(missing.map(\.key).joined(separator: ", "))")
                                                    .font(.caption).foregroundStyle(.secondary)
                                            }
                                        }
                                        Spacer()
                                        Button { NSWorkspace.shared.activateFileViewerSelecting([s.project.appendingPathComponent(s.file.path)]) } label: {
                                            Image(systemName: "folder")
                                        }
                                        .buttonStyle(.borderless).help("Show in Finder")
                                    }
                                }
                            }
                        }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Projects")
        .toolbar {
            ToolbarItem {
                Button {
                    syncing = true
                    Task { await registry.syncFiles(); syncing = false }
                } label: { Label("Sync all", systemImage: "arrow.triangle.2.circlepath") }
                    .disabled(syncing || (registry.fileStatuses ?? []).allSatisfy { !$0.stale })
                    .help("Rewrite the files that differ from the registry")
            }
        }
        .task { await registry.refreshFiles() }
    }

    private func groups(_ statuses: [ProjectFiles.FileStatus]) -> [(String, [ProjectFiles.FileStatus])] {
        let root = NSHomeDirectory() + "/Projects/"
        let byProject = Dictionary(grouping: statuses) { s in
            s.project.path.hasPrefix(root) ? String(s.project.path.dropFirst(root.count)) : s.project.path
        }
        return byProject.keys.sorted().map { ($0, byProject[$0]!) }
    }
}

/// Writes a source's values into a project's env file (the way a new source reaches a project):
/// which file, which environment, which keys under which names — with the names the values
/// already have elsewhere offered first.
struct ConnectSheet: View {
    @Environment(RegistryModel.self) private var registry
    @Environment(\.dismiss) private var dismiss
    let source: Source

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
        let known: [KnownName]
        var id: String { key }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect \(source.name) to a project").font(.headline)
            HStack {
                Text(verbatim: project.map { short($0.path) } ?? String(localized: "No folder chosen"))
                    .font(.callout.monospaced()).lineLimit(1).truncationMode(.head)
                Spacer()
                Menu("Project") {
                    ForEach(registry.projects, id: \.dir.path) { p in
                        Button(short(p.dir.path)) { choose(p.dir) }
                    }
                    Divider()
                    Button("Choose a folder…") { pickFolder() }
                }
                .fixedSize()
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
                Picker("", selection: $env) { ForEach(source.envs, id: \.self) { Text(verbatim: $0).tag($0) } }
                    .labelsHidden().fixedSize()
            }
            Divider()
            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                    ForEach($rows) { $row in
                        GridRow {
                            Toggle("", isOn: $row.include).labelsHidden()
                            Text(verbatim: row.key).font(.caption.monospaced()).foregroundStyle(.secondary)
                            HStack(spacing: 4) {
                                TextField(row.key, text: $row.variable).textFieldStyle(.roundedBorder).font(.callout.monospaced())
                                    .frame(minWidth: 220)
                                if !row.known.isEmpty {
                                    Menu {
                                        ForEach(row.known, id: \.name) { k in
                                            Button("\(k.name) — \(k.files.count) file(s)") { row.variable = k.name }
                                        }
                                    } label: { Image(systemName: "list.bullet") }
                                        .menuIndicator(.hidden).fixedSize().help("Names this value already has in projects")
                                }
                            }
                            stateText(for: row)
                        }
                        if row.include, !row.known.isEmpty, !row.known.contains(where: { $0.name == row.variable }) {
                            GridRow {
                                Color.clear.frame(width: 1, height: 1)
                                Color.clear.frame(width: 1, height: 1)
                                Text("A new name for a value already known as \(row.known.prefix(3).map(\.name).joined(separator: ", ")).")
                                    .font(.caption).foregroundStyle(.orange)
                                    .gridCellColumns(2)
                            }
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
            env = source.defaultEnv
            let names = Names.load(source.id)
            rows = source.keys.map { Row(key: $0.name, include: true, variable: names[$0.name]?.first?.name ?? $0.name, known: names[$0.name] ?? []) }
        }
        .onChange(of: env) { refreshPlan() }
        .onChange(of: file) { refreshPlan() }
        .onChange(of: rows.map { "\($0.include)\($0.variable)" }) { refreshPlan() }
    }

    private var managed: ManagedFile {
        let included = rows.filter(\.include)
        let aliases = Dictionary(included.filter { $0.variable != $0.key && !$0.variable.isEmpty }.map { ($0.variable, $0.key) },
                                 uniquingKeysWith: { a, _ in a })
        return ManagedFile(path: file, sources: [SourceRef(source: source.id, env: env)], env: aliases,
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
                try await ProjectFiles.connect(file, project: project)
                registry.reload()
                await registry.refreshFiles()
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
