import SwiftUI
import PracticesCore

/// A practice or a chain (mock-up boards 2 and 4): code, parameters from `run()`'s
/// signature, the run's result or a chain's steps, versions with their timings.
struct PracticeView: View {
    @State var model: PracticeModel
    @State private var naming = false
    @State private var setName = ""

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                Divider()
                VSplitView {
                    CodeEditor(text: $model.code)
                        .frame(minHeight: 140, idealHeight: 300)
                    VStack(spacing: 0) {
                        params
                        Divider()
                        output
                    }
                    .frame(minHeight: 200)
                }
            }
            .frame(minWidth: 560)
            Divider()
            inspector
                .frame(width: 270)
        }
        .navigationTitle(model.practice.ref)
        .toolbar {
            ToolbarItemGroup {
                Button { Task { await model.save() } } label: { Label("Save version", systemImage: "square.and.arrow.down") }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!model.dirty)
                    .help("Save as a new version (⌘S)")
                if model.running {
                    Button { model.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                        .keyboardShortcut(".", modifiers: .command)
                } else {
                    Button { model.run() } label: { Label("Run", systemImage: "play.fill") }
                        .keyboardShortcut(.return, modifiers: .command)
                        .help("Run (⌘↩)")
                }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: model.practice.isChain ? "point.3.connected.trianglepath.dotted" : "chevron.left.forwardslash.chevron.right")
                .foregroundStyle(.secondary)
            Text(verbatim: model.practice.ref).font(.callout.monospaced())
            if let doc = model.signature?.doc, !doc.isEmpty {
                Text(verbatim: doc.components(separatedBy: "\n").first ?? "").font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(verbatim: model.dirty ? String(localized: "draft") : model.versions.last.map { "v\($0.number)" } ?? "")
                .font(.caption.monospaced())
                .foregroundStyle(model.dirty ? .orange : .secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    // MARK: Parameters

    @ViewBuilder
    private var params: some View {
        if let signature = model.signature, !signature.ok {
            Label { Text(verbatim: signature.error ?? "") } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                .font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(8)
        } else if let list = model.signature?.params, !list.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(list, id: \.name) { param in
                        HStack(spacing: 6) {
                            Text(verbatim: param.name).font(.caption.monospaced()).foregroundStyle(.secondary)
                            TextField(param.default ?? (param.annotation ?? ""), text: Binding(
                                get: { model.params[param.name] ?? "" },
                                set: { model.params[param.name] = $0 }))
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                                .frame(minWidth: 120, idealWidth: 220)
                                .help(param.annotation ?? "")
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
            .overlay(alignment: .trailing) {
                Button { naming = true } label: { Image(systemName: "bookmark") }
                    .buttonStyle(.borderless)
                    .padding(.trailing, 10)
                    .help("Save these parameters as a set: new versions are checked on it")
            }
            .alert("Save parameter set", isPresented: $naming) {
                TextField("Name", text: $setName)
                Button("Save") {
                    let name = setName, params = model.params, practice = model.practice
                    Task { try? await PracticeStore().saveSet(ParamSet(name: name, params: params), for: practice); await model.reloadSets() }
                    setName = ""
                }
                Button("Cancel", role: .cancel) { setName = "" }
            } message: {
                Text("Proposed changes are accepted by themselves only when they return the same rows on every saved set.")
            }
        }
    }

    // MARK: Output

    @ViewBuilder
    private var output: some View {
        VStack(spacing: 0) {
            statusBar
            if let result = model.result {
                if !result.steps.isEmpty { steps(result) }
                if let i = model.selectedStep, i < result.steps.count {
                    stepOutput(result.steps[i])
                } else if result.ok {
                    ResultView(shape: result.shape, columns: result.columns ?? [], rows: result.rows ?? [],
                               tree: result.tree, text: result.text, stdout: result.stdout)
                } else {
                    failure(result)
                }
            } else if let failure = model.failure {
                MonoText(text: failure).foregroundStyle(.red)
            } else if model.running {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label("Not run yet", systemImage: "play.circle")
                } description: {
                    Text("⌘↩ runs it with the values of its sources.")
                }
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            if model.running {
                ProgressView().controlSize(.small)
                Text("Running…").foregroundStyle(.secondary)
            } else if let r = model.result {
                Text(r.ok ? "done" : "failed").foregroundStyle(r.ok ? .green : .red)
                Text(verbatim: metrics(ms: r.ms, rows: r.total, bytes: r.bytes)).font(.caption.monospaced()).foregroundStyle(.secondary)
                if !r.secretsUpdated.isEmpty {
                    Text("stored rotated \(r.secretsUpdated.joined(separator: ", "))").font(.caption).foregroundStyle(.blue)
                }
                Spacer()
                Text(verbatim: r.envs.sorted { $0.key < $1.key }.map { "\($0.key)@\($0.value)" }.joined(separator: "  "))
                    .font(.caption.monospaced()).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private func steps(_ result: PracticeResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(result.steps.enumerated()), id: \.offset) { i, step in
                Button { model.selectedStep = model.selectedStep == i ? nil : i } label: {
                    HStack(spacing: 10) {
                        Text(verbatim: "\(i + 1)").font(.caption.monospacedDigit())
                            .frame(width: 18, height: 18)
                            .background((step.ok ? Color.green : .red).opacity(0.2), in: Circle())
                        Text(verbatim: step.ref).font(.callout.monospaced())
                        Spacer()
                        Text(verbatim: step.ok ? metrics(ms: step.ms, rows: step.total, bytes: nil) : (step.error ?? ""))
                            .font(.caption.monospaced()).foregroundStyle(step.ok ? Color.secondary : Color.red).lineLimit(1)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(model.selectedStep == i ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.07),
                                in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Text(model.selectedStep == nil ? "Click a step to see its output." : "Showing a step's output. Click it again for the final result.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12).padding(.bottom, 6)
    }

    private func stepOutput(_ step: PracticeResult.Step) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let input = step.input {
                Text("input: \(input)").font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                    .padding(.horizontal, 12).padding(.bottom, 4)
            }
            if step.ok {
                ResultView(shape: step.shape, columns: step.columns ?? [], rows: step.rows ?? [],
                           tree: step.tree, text: step.text, stdout: "")
            } else {
                MonoText(text: step.error ?? "").foregroundStyle(.red)
            }
        }
    }

    private func failure(_ result: PracticeResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: result.error ?? "").font(.callout.monospaced()).foregroundStyle(.red)
                .textSelection(.enabled).padding(.horizontal, 12).padding(.top, 8)
            MonoText(text: [result.traceback ?? "", result.stderr, result.stdout].filter { !$0.isEmpty }.joined(separator: "\n\n"))
        }
    }

    private func metrics(ms: Int, rows: Int?, bytes: Int?) -> String {
        var parts = [ms >= 1000 ? String(format: "%.1f s", Double(ms) / 1000) : "\(ms) ms"]
        if let rows { parts.append("\(rows) rows") }
        if let bytes { parts.append(bytes >= 1024 ? "\(bytes / 1024) KB" : "\(bytes) B") }
        return parts.joined(separator: " · ")
    }

    // MARK: Inspector

    private var inspector: some View {
        List {
            Section("Versions") {
                let timings = model.timings
                let slowest = max(1, timings.map(\.median).max() ?? 1)
                ForEach(timings, id: \.version) { t in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(verbatim: t.version.map { "v\($0)" } ?? String(localized: "draft")).font(.callout.monospaced())
                            Spacer()
                            Text(verbatim: t.median >= 1000 ? String(format: "%.1f s", Double(t.median) / 1000) : "\(t.median) ms")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(t.median == timings.map(\.median).filter { $0 > 0 }.min() ? .green : .secondary)
                        }
                        GeometryReader { geo in
                            Capsule().fill(Color.secondary.opacity(0.35))
                                .frame(width: max(4, geo.size.width * CGFloat(t.median) / CGFloat(slowest)), height: 4)
                        }
                        .frame(height: 4)
                        Text("\(t.count) runs" + (t.failed > 0 ? ", \(t.failed) failed" : "")).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                if timings.isEmpty { Text("No runs yet").foregroundStyle(.secondary) }
                if let first = model.versions.first {
                    Text("v1 saved \(first.date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            if !model.sets.isEmpty {
                Section("Parameter sets") {
                    ForEach(model.sets, id: \.name) { set in
                        Button { model.params = set.params } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(verbatim: set.name).font(.callout)
                                Text(verbatim: set.params.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
                                    .font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                        .help("Fill the parameters from this set")
                    }
                }
            }
            if let schema = model.result?.schema, !schema.isEmpty {
                Section("Fields in the result") {
                    ForEach(schema, id: \.path) { f in
                        HStack {
                            Text(verbatim: f.path).font(.caption.monospaced()).lineLimit(1)
                            Spacer()
                            Text(verbatim: f.type).font(.caption2.monospaced()).foregroundStyle(.secondary)
                            if f.present < f.seen {
                                Text(verbatim: "\(f.present)/\(f.seen)").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}
