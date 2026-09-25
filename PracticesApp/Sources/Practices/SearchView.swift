import SwiftUI
import AppKit
import PracticesCore

/// Search by meaning (mock-up board 6): the field, practices whose result has it, documents,
/// code of practices.
struct SearchView: View {
    let query: String
    var open: (MainWindow.SidebarItem) -> Void
    @State private var results = SearchResults()

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
            if results.isEmpty {
                Text("Nothing found for “\(query)”").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Search")
        .task(id: query) {
            let q = query
            results = await Task.detached { Search.run(q) }.value
        }
    }
}
