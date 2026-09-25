import SwiftUI
import PracticesCore

/// Changes sent back from projects (mock-up board 5): pending first, then the decided ones.
struct ProposalsView: View {
    @Environment(RegistryModel.self) private var registry
    @State private var selected: String?

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $selected) {
                let pending = registry.proposals.filter { $0.status == .pending }
                let decided = registry.proposals.filter { $0.status != .pending }
                if !pending.isEmpty {
                    Section("Waiting for you") { ForEach(pending) { row($0) } }
                }
                if !decided.isEmpty {
                    Section("Decided") { ForEach(decided) { row($0) } }
                }
            }
            .frame(width: 300)
            Divider()
            if let id = selected, let proposal = registry.proposals.first(where: { $0.id == id }) {
                ReviewView(proposal: proposal).id(proposal.id)
            } else {
                ContentUnavailableView {
                    Label("Proposals", systemImage: "arrow.triangle.pull")
                } description: {
                    Text("Agents send changed practices here with `propose_update`. Those that pass every rule are accepted by themselves.")
                }
            }
        }
        .navigationTitle("Proposals")
        .onAppear {
            registry.reloadProposals()
            if selected == nil { selected = registry.proposals.first?.id }
        }
    }

    private func row(_ p: Proposal) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(verbatim: p.ref).font(.callout.monospaced()).lineLimit(1)
                Spacer()
                StatusChip(proposal: p)
            }
            Text(verbatim: p.why.split(separator: "\n").first.map(String.init) ?? "").font(.caption).lineLimit(2)
            Text(verbatim: (p.origin as NSString).lastPathComponent + " · " + p.created.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .tag(p.id)
    }
}

struct StatusChip: View {
    let proposal: Proposal
    var body: some View {
        let (text, color): (LocalizedStringKey, Color) = switch proposal.status {
        case .pending: ("waiting", .orange)
        case .accepted: (proposal.decidedBy == "auto" ? "auto-accepted" : "accepted", .green)
        case .rejected: ("rejected", .secondary)
        }
        Text(text).font(.caption2).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .overlay(Capsule().strokeBorder(color.opacity(0.5)))
    }
}

struct ReviewView: View {
    @Environment(RegistryModel.self) private var registry
    let proposal: Proposal
    @State private var base = ""
    @State private var working = false

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 10) {
                            Text(verbatim: proposal.why.split(separator: "\n").first.map(String.init) ?? proposal.ref)
                                .font(.title3.weight(.semibold))
                            StatusChip(proposal: proposal)
                        }
                        Text(verbatim: "\(proposal.ref) · v\(proposal.baseVersion) → " + (proposal.acceptedVersion.map { "v\($0)" } ?? "?")
                             + " · " + proposal.origin + " · " + proposal.created.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Card(title: "What and why", trailing: nil) {
                        Text(verbatim: proposal.why).font(.callout).textSelection(.enabled)
                    }
                    Card(title: "Change", trailing: "v\(proposal.baseVersion)") {
                        DiffView(old: base, new: proposal.code)
                    }
                    if let params = proposal.params, !params.isEmpty {
                        Card(title: "Parameters the agent tried", trailing: nil) {
                            Text(verbatim: params.sorted { $0.key < $1.key }.map { "\($0.key) = \($0.value)" }.joined(separator: "\n"))
                                .font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                }
                .padding(18)
            }
            Divider()
            List {
                Section("Checks") {
                    ForEach(proposal.checks, id: \.self) { check in
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(verbatim: check.name).font(.callout)
                                Text(verbatim: check.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: check.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(check.ok ? .green : .orange)
                        }
                    }
                }
                Section(proposal.status == .pending ? "Why it waits for you" : "Verdict") {
                    Text(verbatim: proposal.verdict).font(.callout)
                }
                Section("Rules for accepting by itself") {
                    Text("Same fields and the same rows on every saved parameter set, not slower by more than 5% (or 50 ms), the source not marked write-allowed. Accepted changes are versions: any can be restored.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if proposal.status == .pending {
                    Section {
                        HStack {
                            Button("Reject", role: .destructive) { decide(accept: false) }
                            Spacer()
                            Button("Accept as new version") { decide(accept: true) }
                                .buttonStyle(.borderedProminent)
                        }
                        .disabled(working)
                    }
                }
            }
            .frame(width: 320)
        }
        .task {
            let practice = Practice(ref: proposal.ref)
            let store = PracticeStore()
            if let versions = try? await store.versions(of: practice), proposal.baseVersion >= 1, proposal.baseVersion <= versions.count {
                base = (try? await store.code(of: practice, at: versions[proposal.baseVersion - 1])) ?? ""
            }
        }
    }

    private func decide(accept: Bool) {
        working = true
        Task {
            await registry.decide(proposal, accept: accept)
            working = false
        }
    }
}

/// Line diff, unified: removed lines red, added green, a few lines of context around changes.
struct DiffView: View {
    let old: String
    let new: String

    struct Line: Identifiable {
        let id: Int
        let kind: Character   // " ", "-", "+", "…"
        let text: String
    }

    var body: some View {
        ScrollView(.horizontal) {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(lines) { line in
                Text(verbatim: "\(line.kind) \(line.text)")
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(line.kind == "-" ? Color.red : line.kind == "+" ? Color.green : line.kind == "…" ? Color.secondary.opacity(0.6) : Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
                    .background(line.kind == "-" ? Color.red.opacity(0.1) : line.kind == "+" ? Color.green.opacity(0.1) : .clear)
            }
        }
        .textSelection(.enabled)
    }

    var lines: [Line] {
        let a = old.components(separatedBy: "\n"), b = new.components(separatedBy: "\n")
        let diff = b.difference(from: a)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var all: [(Character, String)] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, removed.contains(i) { all.append(("-", a[i])); i += 1 }
            else if j < b.count, inserted.contains(j) { all.append(("+", b[j])); j += 1 }
            else { if j < b.count { all.append((" ", b[j])) }; i += 1; j += 1 }
        }
        // Keep three lines of context around changes.
        let changed = all.indices.filter { all[$0].0 != " " }
        var keep = Set<Int>()
        for c in changed { for k in max(0, c - 3)...min(all.count - 1, c + 3) { keep.insert(k) } }
        var out: [Line] = []
        var skipped = false
        for (n, entry) in all.enumerated() {
            if keep.contains(n) || changed.isEmpty {
                out.append(Line(id: n, kind: entry.0, text: entry.1)); skipped = false
            } else if !skipped {
                out.append(Line(id: n, kind: "…", text: "")); skipped = true
            }
        }
        return out
    }
}
