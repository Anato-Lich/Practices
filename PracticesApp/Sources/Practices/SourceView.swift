import SwiftUI
import PracticesCore

/// A source card (mock-up board 1): targets, keys, guards, notes, documents and fields.
struct SourceView: View {
    @Environment(RegistryModel.self) private var registry
    let source: Source
    @State private var editing: KeyEdit?
    @State private var connecting = false

    struct KeyEdit: Identifiable {
        let key: String
        let env: String
        var id: String { "\(key)@\(env)" }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 16) {
                    GridRow {
                        VStack(spacing: 16) {
                            targets
                            practices
                            if !source.guards.isEmpty { guards }
                            notes
                        }
                        VStack(spacing: 16) {
                            keys
                            copies
                            docs
                        }
                    }
                }
                fields
            }
            .padding(20)
            .frame(maxWidth: 1100, alignment: .leading)
        }
        .navigationTitle(source.name)
        .toolbar {
            ToolbarItem {
                Button { Task { await registry.check(source.id) } } label: {
                    Label("Check", systemImage: "arrow.clockwise")
                }
                .disabled(registry.checking.contains(source.id))
            }
            ToolbarItem {
                Button { connecting = true } label: { Label("Connect to project…", systemImage: "arrow.right.doc.on.clipboard") }
                    .help("Write this source's values into a project's env file")
            }
            ToolbarItem {
                Button { registry.revealSource(source.id) } label: { Label("Show in Finder", systemImage: "folder") }
            }
        }
        .sheet(isPresented: $connecting) { ConnectSheet(source: source) }
        .sheet(item: $editing) { edit in
            SecretSheet(source: source, key: edit.key, env: edit.env)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(verbatim: source.name).font(.title2.weight(.semibold))
                Chip(text: source.kind, mono: true)
                ForEach(source.tags, id: \.self) { tag in
                    Chip(text: tag, tint: tag == "read-only" ? .orange : nil)
                }
            }
            if let description = source.description {
                Text(verbatim: description).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Cards

    private var targets: some View {
        Card(title: "Targets", trailing: lastCheckText) {
            let results = registry.checks[source.id] ?? []
            VStack(alignment: .leading, spacing: 6) {
                ForEach(results.filter { $0.target == "requires" }, id: \.self) { r in
                    Label { Text(verbatim: r.message ?? "") } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                        .font(.callout)
                }
                ForEach(source.targets, id: \.id) { target in
                    let result = results.first { $0.target == target.id }
                    HStack(spacing: 8) {
                        HealthDot(health: result.map { $0.ok ? .up : .down } ?? .unknown)
                        Text(verbatim: target.id).font(.callout.monospaced())
                        Text(verbatim: target.label ?? "").font(.callout).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        if let result {
                            Text(verbatim: result.ok ? (result.millis.map { "\($0) ms" } ?? "") : (result.message ?? ""))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(result.ok ? Color.secondary : Color.red)
                        }
                    }
                }
                if source.targets.isEmpty { Text("No targets").foregroundStyle(.secondary).font(.callout) }
            }
        }
    }

    private var practices: some View {
        Card(title: "Practices", trailing: nil) {
            let list = registry.practices[source.id] ?? []
            VStack(alignment: .leading, spacing: 2) {
                ForEach(list) { practice in
                    let last = registry.lastRun(of: practice.ref)
                    Button { registry.selection = .practice(practice.ref) } label: {
                        HStack {
                            Text(verbatim: practice.name).font(.callout)
                            Spacer()
                            if let last {
                                Text(verbatim: (last.version.map { "v\($0) · " } ?? "") + "\(last.millis) ms")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(last.ok ? Color.secondary : Color.red)
                            }
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if list.isEmpty { Text("No practices yet").foregroundStyle(.secondary).font(.callout) }
            }
        }
    }

    private var lastCheckText: String? {
        guard let date = registry.lastCheck[source.id] else { return nil }
        return date.formatted(date: .omitted, time: .shortened)
    }

    private var keys: some View {
        Card(title: "Keys", trailing: nil) {
            let status = registry.keyStatus[source.id] ?? [:]
            let names = Names.load(source.id)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("Key").foregroundStyle(.secondary)
                    ForEach(source.envs, id: \.self) { Text(verbatim: $0).foregroundStyle(.secondary) }
                }
                .font(.caption)
                ForEach(source.keys, id: \.name) { key in
                    GridRow {
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 4) {
                                Text(verbatim: key.name).font(.callout.monospaced()).lineLimit(1)
                                if key.secret { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.tertiary) }
                            }
                            let others = (names[key.name] ?? []).map(\.name).filter { $0 != key.name }
                            if !others.isEmpty {
                                Text("in projects also: \(others.joined(separator: ", "))")
                                    .font(.caption2.monospaced()).foregroundStyle(others.count > 1 ? .orange : .secondary)
                                    .lineLimit(2)
                            }
                        }
                        ForEach(source.envs, id: \.self) { env in
                            let set = status[env]?.contains(key.name) == true
                            Button { editing = KeyEdit(key: key.name, env: env) } label: {
                                Text(set ? "set" : "not set")
                                    .font(.caption)
                                    .foregroundStyle(set ? .green : .orange)
                            }
                            .buttonStyle(.borderless)
                            .help("Change value")
                        }
                    }
                }
            }
            Text("Values are never shown — not here, not to the agent.")
                .font(.caption).foregroundStyle(.tertiary).padding(.top, 6)
        }
    }

    private var copies: some View {
        Card(title: "Copies in projects", trailing: nil) {
            if let all = registry.copies {
                let mine = all.filter { $0.ref.hasPrefix(source.id + "/") }
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(mine, id: \.self) { copy in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(verbatim: shortPath(copy.path)).font(.callout).lineLimit(1).truncationMode(.head)
                                Text(verbatim: copy.ref.split(separator: "/").last.map(String.init) ?? "").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(copyState(copy)).font(.caption).foregroundStyle(copyColor(copy))
                        }
                    }
                    if mine.isEmpty {
                        Text("No marked copies in ~/Projects yet. `get_practice` hands code out with the marker line.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func shortPath(_ path: String) -> String {
        let root = NSHomeDirectory() + "/Projects/"
        return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
    }

    private func copyState(_ copy: PracticeCopy) -> String {
        switch copy.state {
        case .current: "v\(copy.version ?? 0)"
        case .outdated: String(localized: "v\(copy.version ?? 0) → v\(copy.latest) available")
        case .modified: String(localized: "changed, not sent")
        case .unknown: String(localized: "unknown version")
        }
    }

    private func copyColor(_ copy: PracticeCopy) -> Color {
        switch copy.state {
        case .current: .green
        case .outdated: .orange
        case .modified: .blue
        case .unknown: .secondary
        }
    }

    private var guards: some View {
        Card(title: "Guards", trailing: nil) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(source.guards, id: \.self) { rule in
                    Label { Text(verbatim: rule).font(.callout) } icon: {
                        Image(systemName: "lock.shield").foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    private var notes: some View {
        Card(title: "Notes", trailing: nil) {
            if let text = registry.notes(of: source.id), !text.isEmpty,
               let attributed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                Text(attributed).font(.callout).textSelection(.enabled)
            } else {
                Text("No notes").foregroundStyle(.secondary).font(.callout)
            }
        }
    }

    private var docs: some View {
        Card(title: "Documentation", trailing: nil) {
            let docs = registry.docs(of: source.id)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(docs, id: \.self) { doc in
                    Button { registry.open(doc, of: source.id) } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: doc.title).font(.callout)
                            Text(verbatim: [doc.kind.rawValue, doc.section].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                if docs.isEmpty { Text("No documents").foregroundStyle(.secondary).font(.callout) }
            }
        }
    }

    @ViewBuilder
    private var fields: some View {
        let fields = registry.fields(of: source.id)
        if !fields.isEmpty {
            Card(title: "Fields", trailing: "\(fields.filter { $0.meaning != nil }.count)/\(fields.count)") {
                Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 7) {
                    ForEach(fields, id: \.path) { field in
                        GridRow {
                            Text(verbatim: field.path).font(.callout.monospaced())
                            Text(verbatim: field.type ?? "").font(.callout.monospaced()).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                if let meaning = field.meaning {
                                    Text(verbatim: meaning).font(.callout)
                                } else {
                                    Text("No description").font(.callout).foregroundStyle(.orange)
                                }
                                if let values = field.values {
                                    Text(verbatim: values.sorted { $0.key < $1.key }.map { "\($0.key) — \($0.value)" }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Text(verbatim: (field.from ?? []).map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))
                                .font(.caption).foregroundStyle(.tertiary).lineLimit(2)
                        }
                    }
                }
            }
        }
    }
}

/// Sets a value without ever showing the current one.
struct SecretSheet: View {
    @Environment(RegistryModel.self) private var registry
    @Environment(\.dismiss) private var dismiss
    let source: Source
    let key: String
    let env: String
    @State private var value = ""

    var body: some View {
        let isSet = registry.keyStatus[source.id]?[env]?.contains(key) == true
        VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: "\(key)").font(.headline.monospaced())
            Text(verbatim: "\(source.name) · \(env)").foregroundStyle(.secondary)
            SecureField(isSet ? "New value (the current one stays hidden)" : "Value", text: $value)
                .textFieldStyle(.roundedBorder)
                .frame(width: 380)
            HStack {
                if isSet {
                    Button("Remove value", role: .destructive) {
                        registry.unset(key: key, source: source.id, env: env)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    registry.set(value, key: key, source: source.id, env: env)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(value.isEmpty)
            }
        }
        .padding(20)
    }
}

struct Card<Content: View>: View {
    let title: LocalizedStringKey
    let trailing: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                if let trailing { Text(verbatim: trailing).font(.caption).foregroundStyle(.secondary) }
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.6)))
    }
}

struct Chip: View {
    let text: String
    var mono = false
    var tint: Color? = nil
    var body: some View {
        Text(verbatim: text)
            .font(mono ? .caption.monospaced() : .caption)
            .foregroundStyle(tint ?? .secondary)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder((tint ?? .secondary).opacity(0.5)))
    }
}
