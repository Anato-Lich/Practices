import SwiftUI
import AppKit
import PracticesCore

/// Search by meaning (mock-up board 6): the field, practices whose result has it, documents,
/// code of practices.
extension CodeHit: @retroactive Identifiable {
    public var id: String { "\(path):\(line)" }
}

private func short(_ path: String) -> String {
    let root = NSHomeDirectory() + "/Projects/"
    return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
}

/// Which source the new practice belongs to and its name; the draft opens in the editor.
struct DraftSheet: View {
    @Environment(RegistryModel.self) private var registry
    @Environment(\.dismiss) private var dismiss
    let hit: CodeHit
    var created: (String) -> Void
    @State private var source = ""
    @State private var name = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New practice from \(hit.function ?? "")()").font(.headline)
            Text(verbatim: short(hit.path) + ":\(hit.line)").font(.caption).foregroundStyle(.secondary)
            Picker("Source", selection: $source) {
                ForEach(registry.sources) { Text(verbatim: $0.name).tag($0.id) }
            }
            TextField("Name", text: $name).textFieldStyle(.roundedBorder)
            Text("The draft gets the file's imports, the constants it uses and `run = \(hit.function ?? "")`. Inline what it needs from its project, then save a version with ⌘S.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(verbatim: error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create draft") { create() }.keyboardShortcut(.defaultAction).disabled(source.isEmpty || name.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            source = registry.sources.first?.id ?? ""
            name = (hit.function ?? "practice").trimmingCharacters(in: CharacterSet(charactersIn: "_")).replacingOccurrences(of: "_", with: "-")
        }
    }

    private func create() {
        let ref = "\(source)/\(name)"
        let practice = Practice(ref: ref)
        let store = PracticeStore()
        guard !FileManager.default.fileExists(atPath: store.url(of: practice).path) else { error = String(localized: "\(ref) already exists"); return }
        guard let function = hit.function, let code = ProjectCode.draft(from: hit.path, function: function, ref: ref) else {
            error = String(localized: "Could not read the function"); return
        }
        do {
            try store.writeDraft(code, for: practice)
            dismiss()
            created(ref)
        } catch {
            self.error = String(describing: error)
        }
    }
}

struct SearchView: View {
    let query: String
    var open: (MainWindow.SidebarItem) -> Void
    @Environment(RegistryModel.self) private var registry
    @State private var results = SearchResults()
    @State private var projectHits: [CodeHit]?
    @State private var projectFiles = 0
    @State private var drafting: CodeHit?

    var body: some View {
        List {
            if !results.fields.isEmpty {
                Section("Field") {
                    ForEach(results.fields, id: \.self) { hit in
                        Button { open(.source(hit.source)) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 8) {
                                    Text(verbatim: hit.field.path).font(.callout.monospaced())
                                    Text(verbatim: hit.field.type ?? "").font(.caption.monospaced()).foregroundStyle(.secondary)
                                    Text(verbatim: "· \(hit.source)").font(.caption).foregroundStyle(.secondary)
                                }
                                if let meaning = hit.field.meaning {
                                    Text(verbatim: meaning).font(.callout)
                                } else {
                                    Text("No description").font(.callout).foregroundStyle(.orange)
                                }
                                if let values = hit.field.values {
                                    Text(verbatim: values.sorted { $0.key < $1.key }.map { "\($0.key) — \($0.value)" }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                if let from = hit.field.from, !from.isEmpty {
                                    Text("Described from: \(from.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))")
                                        .font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if !results.results.isEmpty {
                Section("In the result of") {
                    ForEach(results.results, id: \.self) { hit in
                        Button { open(.practice(hit.practice)) } label: {
                            HStack {
                                Image(systemName: Practice(ref: hit.practice).isChain ? "point.3.connected.trianglepath.dotted" : "chevron.left.forwardslash.chevron.right")
                                    .foregroundStyle(.secondary)
                                Text(verbatim: hit.practice).font(.callout.monospaced())
                                Text(verbatim: hit.path).font(.caption.monospaced()).foregroundStyle(.secondary)
                                Spacer()
                                if let step = hit.viaStep { Text("via \(step)").font(.caption).foregroundStyle(.tertiary) }
                                Text(verbatim: "\(hit.present)/\(hit.seen)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    .help("Rows with the field / rows looked at, in the latest run")
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if !results.docs.isEmpty {
                Section("Documentation") {
                    ForEach(results.docs, id: \.self) { hit in
                        Button { NSWorkspace.shared.open(URL(fileURLWithPath: hit.path)) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: hit.title + (hit.source.map { " · \($0)" } ?? "")).font(.callout)
                                Text(verbatim: hit.excerpt).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if !results.code.isEmpty {
                Section("Code of practices") {
                    ForEach(results.code, id: \.self) { hit in
                        Button { open(.practice(hit.title)) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: hit.title).font(.callout.monospaced())
                                Text(verbatim: hit.excerpt).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Section {
                if let hits = projectHits {
                    ForEach(hits, id: \.self) { hit in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: hit.function.map { "\($0)()" } ?? (hit.path as NSString).lastPathComponent)
                                    .font(.callout.monospaced())
                                Text(verbatim: short(hit.path) + ":\(hit.line)").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                            }
                            Spacer()
                            if hit.function != nil && hit.path.hasSuffix(".py") {
                                Button("Make a practice") { drafting = hit }.controlSize(.small)
                            }
                            Button { NSWorkspace.shared.open(URL(fileURLWithPath: hit.path)) } label: { Image(systemName: "arrow.up.forward.square") }
                                .buttonStyle(.borderless).help("Open the file")
                        }
                    }
                    if hits.isEmpty { Text("No project code mentions it").foregroundStyle(.secondary) }
                } else {
                    HStack { ProgressView().controlSize(.small); Text("Reading ~/Projects…").foregroundStyle(.secondary) }
                }
            } header: {
                Text(projectHits == nil ? "In project code" : "In project code · \(projectFiles) files · not practices yet")
            }
        }
        .navigationTitle("Search")
        .task(id: query) {
            let q = query
            projectHits = nil
            results = await Task.detached { Search.run(q) }.value
            let (hits, files) = await ProjectCode.search(q, limit: 60)
            projectHits = hits
            projectFiles = files
        }
        .sheet(item: $drafting) { hit in
            DraftSheet(hit: hit) { ref in
                registry.reload()
                open(.practice(ref))
            }
        }
    }
}
