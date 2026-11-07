import SwiftUI
import PracticesCore

/// A service card (`design/Service.dc.html`): header with badges and the last check, a kv-block,
/// then endpoints, practices and links on the left; keys, guards, copies, docs and notes on the right.
struct ServiceView: View {
    @Environment(RegistryModel.self) private var registry
    let service: Service
    @State private var editing: KeyEdit?
    @State private var connecting = false
    @State private var env: String?

    struct KeyEdit: Identifiable {
        let key: String
        let env: String
        var id: String { "\(key)@\(env)" }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                if let description = service.description {
                    Text(verbatim: description).font(Theme.ui(13)).foregroundStyle(Theme.Color.textSecondary)
                        .textSelection(.enabled).padding(.top, -4)
                }
                kvBlock
                FractionColumns(left: 1.2, right: 1, spacing: 12) {
                    VStack(spacing: 12) {
                        endpoints
                        practices
                        incoming
                        outgoing
                    }
                    VStack(spacing: 12) {
                        keys
                        if !service.guards.isEmpty { guards }
                        copies
                        docs
                        notes
                    }
                }
                fields
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(service.name)
        .toolbarTrailing {
            ToolbarButton("Проверить", systemImage: "arrow.clockwise", prominent: true) { Task { await registry.check(service.id) } }
                .disabled(registry.checking.contains(service.id))
            Button { connecting = true } label: { Text(verbatim: "Подключить к проекту…") }
                .help("Write this service's values into a project's env file")
            Button { registry.selection = .map } label: { Text(verbatim: "Карта") }
            Button { registry.revealService(service.id) } label: { Text(verbatim: "Finder") }
        }
        .sheet(isPresented: $connecting) { ConnectSheet(service: service) }
        .sheet(item: $editing) { edit in
            SecretSheet(service: service, key: edit.key, env: edit.env)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text(verbatim: service.name).font(Theme.ui(17, .semibold)).foregroundStyle(Theme.Color.text)
            let kind = ServiceClass(for: service)
            Badge(service.kind, color: kind.color, background: kind.rgbBadgeBackground)
            ForEach(service.tags, id: \.self) { tag in
                switch tag {
                case "read-only": Badge(tag, color: Theme.Color.warn, background: Theme.Color.warn.opacity(0.16))
                case "prod-data": Badge(tag, color: ServiceClass.ext.color, background: ServiceClass.ext.rgbBadgeBackground)
                case "shared":
                    Badge("shared · " + ru(registry.callers(of: service.id), "вызывающего", "вызывающих", "вызывающих"),
                          color: Theme.Color.textChip, background: ServiceClass.other.rgbBadgeBackground)
                default: Badge(tag, color: Theme.Color.textChip, background: ServiceClass.other.rgbBadgeBackground)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Circle().fill(healthColor).frame(width: 8, height: 8)
                Text(verbatim: checkSummary)
            }
            .font(Theme.ui(11)).foregroundStyle(Theme.Color.textSecondary)
        }
    }

    private var healthColor: Color {
        switch registry.health(of: service.id) {
        case .unknown: Theme.Color.textMuted
        case .up: Theme.Color.ok
        case .partial: Theme.Color.warn
        case .down: Theme.Color.error
        }
    }

    /// «4 из 4 точек отвечают · проверено 14:02», or «не проверялось».
    private var checkSummary: String {
        if registry.checking.contains(service.id) { return "проверяется…" }
        guard let date = registry.lastCheck[service.id] else { return "не проверялось" }
        let answering = service.endpoints.filter { result(of: $0)?.ok == true }.count
        let when = Calendar.current.isDateInToday(date) ? date.formatted(.dateTime.hour().minute())
            : date.formatted(.dateTime.day().month().hour().minute())
        return "\(answering) из \(service.endpoints.count) точек отвечают · проверено \(when)"
    }

    private func result(of endpoint: Service.Endpoint) -> CheckResult? {
        registry.checks[service.id]?.first { $0.endpoint == endpoint.id }
    }

    // MARK: kv-block

    private var kvBlock: some View {
        KVBlock {
            if !service.aliases.isEmpty { KVRow("aliases", service.aliases.joined(separator: " · ")) }
            if let repo = service.repo { KVRow("repo", repo.description) }
            KVRow("envs", service.envs.joined(separator: " · "))
            if !service.conditionIDs.isEmpty {
                KVRow("requires") {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(service.conditionIDs, id: \.self) { requirement($0) }
                    }
                }
            }
            KVRow("mcp") {
                Text(verbatim: ["get_service", "list_practices", "env_names"].map { "\($0) \(service.id)" }.joined(separator: " · "))
                    .foregroundStyle(Theme.Color.textSecondary)
            }
        }
        .textSelection(.enabled)
    }

    /// `⚑ corp-network — hint`; a failed check shows its message in error colour. A condition of
    /// some endpoints only names them.
    private func requirement(_ id: String) -> Text {
        let condition = registry.condition(id)
        let failed = registry.checks[service.id]?.first { $0.endpoint == "requires:\(id)" && !$0.ok }
        let scope = service.requires.contains(id) ? [] : service.endpoints.filter { $0.requires.contains(id) }.map(\.id)
        let hint = failed?.message ?? condition?.hint ?? condition?.name
        return Text(verbatim: "⚑ \(id)").foregroundStyle(failed == nil ? Theme.Color.warn : Theme.Color.error)
            + Text(verbatim: scope.isEmpty ? "" : " (\(scope.joined(separator: ", ")))").foregroundStyle(Theme.Color.textMuted)
            + Text(verbatim: hint.map { " — \($0)" } ?? "").foregroundStyle(Theme.Color.textSecondary)
    }

    // MARK: Left column

    private var endpoints: some View {
        SectionCard("Точки входа · \(service.endpoints.count)", spacing: 6) {
            ForEach(service.endpoints, id: \.id) { endpoint in
                let result = result(of: endpoint)
                HStack(spacing: 8) {
                    Circle().fill(result.map { $0.ok ? Theme.Color.ok : Theme.Color.error } ?? Theme.Color.textMuted)
                        .frame(width: 7, height: 7)
                    Text(verbatim: endpoint.id).frame(minWidth: 70, alignment: .leading)
                    if let label = endpoint.label { Text(verbatim: label).foregroundStyle(Theme.Color.textSecondary) }
                    // The template names keys, never their values.
                    Text(verbatim: endpoint.address ?? endpoint.url ?? "").foregroundStyle(Theme.Color.textMuted)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    if let result {
                        Text(verbatim: result.ok ? (result.millis.map { "\($0) ms" } ?? "") : (result.message ?? ""))
                            .monospacedDigit().lineLimit(1)
                            .foregroundStyle(result.ok ? Theme.Color.textSecondary : Theme.Color.error)
                            .help(result.message ?? "")
                    }
                }
                .font(Theme.mono(12)).lineLimit(1)
            }
            if service.endpoints.isEmpty { empty("Точек входа нет") }
        }
    }

    private var practices: some View {
        let list = registry.practices[service.id] ?? []
        return SectionCard("Практики · \(list.count)", spacing: 8) {
            // Three columns in the design at 1280; narrower windows get fewer so names stay whole.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 10)], alignment: .leading, spacing: 4) {
                ForEach(list) { practice in
                    let run = runLabel(registry.lastRun(of: practice.ref))
                    Button { registry.selection = .practice(practice.ref) } label: {
                        HStack(spacing: 6) {
                            Text(verbatim: "‹›").font(Theme.mono(10)).foregroundStyle(Theme.Color.textMuted)
                            Text(verbatim: practice.name).lineLimit(1).truncationMode(.tail)
                            Spacer(minLength: 4)
                            Text(verbatim: run.0).font(Theme.mono(10.5)).foregroundStyle(run.1).lineLimit(1)
                        }
                        .font(Theme.mono(12)).foregroundStyle(Theme.Color.text)
                        .padding(.horizontal, 6).padding(.vertical, 4)
                        .background(Theme.Color.windowBg, in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            if list.isEmpty { empty("Практик пока нет") }
        }
    }

    /// «v3 · 212 ms»: ok under 500 ms, warn from 1 s, error for a failed run, muted with no run.
    private func runLabel(_ run: RunRecord?) -> (String, Color) {
        // shortcut: without a run the version is unknown (it is `git log`), so only a dash.
        guard let run else { return ("—", Theme.Color.textMuted) }
        let time = run.millis < 1000 ? "\(run.millis) ms" : String(format: "%.1f s", Double(run.millis) / 1000)
        let text = (run.version.map { "v\($0) · " } ?? "") + time
        let color = !run.ok ? Theme.Color.error : run.millis < 500 ? Theme.Color.ok
            : run.millis >= 1000 ? Theme.Color.warn : Theme.Color.textSecondary
        return (text, color)
    }

    private var incoming: some View {
        let links = registry.links(to: service.id)
        let callers = Set(links.map(\.from)).count
        return SectionCard("Кто ходит сюда · " + ru(links.count, "связь", "связи", "связей") + " из "
                           + ru(callers, "сервиса", "сервисов", "сервисов"), spacing: 4) {
            ForEach(links.indices, id: \.self) { i in linkRow(other: links[i].from, links[i].link) }
            if links.isEmpty { empty("Никто не ходит") }
        }
    }

    @ViewBuilder private var outgoing: some View {
        let links = registry.links(of: service.id)
        if !links.isEmpty {
            SectionCard("Куда ходит · " + ru(links.count, "связь", "связи", "связей"), spacing: 4) {
                ForEach(links.indices, id: \.self) { i in linkRow(other: links[i].to, links[i]) }
            }
        }
    }

    /// `[project] caller → endpoint  what  access`; the other side opens on click.
    /// A target removed from the catalogue (its project deleted) stays here marked «цели нет».
    private func linkRow(other: String, _ link: PracticesCore.Link) -> some View {
        let gone = registry.service(other) == nil
        let project = registry.service(other)?.project ?? ""
        let zone = registry.zoneColor(of: project)
        return Button { registry.selection = .service(other) } label: {
            HStack(spacing: 8) {
                if gone {
                    Text(verbatim: "цели нет").font(Theme.mono(10)).foregroundStyle(Theme.Color.warn).lineLimit(1)
                        .padding(.horizontal, 6).frame(minWidth: 96, alignment: .leading)
                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.Color.warn, lineWidth: 1))
                } else {
                    Text(verbatim: project).font(Theme.mono(10)).foregroundStyle(zone).lineLimit(1)
                        .padding(.horizontal, 6).frame(minWidth: 96, alignment: .leading)
                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(zone, lineWidth: 1))
                }
                Text(verbatim: other).foregroundStyle(gone ? Theme.Color.textMuted : Theme.Color.text).frame(minWidth: 150, alignment: .leading)
                Text(verbatim: "→ " + (link.endpoint ?? "") + (link.env.map { "@\($0)" } ?? "")).foregroundStyle(Theme.Color.textMuted)
                Text(verbatim: link.what ?? link.via ?? "").foregroundStyle(Theme.Color.textSecondary)
                    .truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: link.access ?? "")
                    .foregroundStyle(link.access == "write" ? Theme.Color.warn : Theme.Color.textMuted)
            }
            .font(Theme.mono(11.5)).foregroundStyle(Theme.Color.text).lineLimit(1)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(!gone)
        .help([link.via, link.why].compactMap { $0 }.joined(separator: " — "))
    }

    // MARK: Right column

    private var keys: some View {
        let env = self.env.flatMap { service.envs.contains($0) ? $0 : nil } ?? service.defaultEnv
        let set = registry.keyStatus[service.id]?[env] ?? []
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionTitle("Ключи · \(env)")
                Spacer()
                if service.envs.count > 1 {
                    Picker(selection: Binding(get: { env }, set: { self.env = $0 })) {
                        ForEach(service.envs, id: \.self) { Text(verbatim: $0).tag($0) }
                    } label: { EmptyView() }
                    .pickerStyle(.segmented).controlSize(.small).fixedSize()
                }
            }
            .padding(.bottom, 2)
            ForEach(service.keys, id: \.name) { key in
                let isSet = set.contains(key.name)
                HStack(spacing: 8) {
                    Text(verbatim: key.name).font(Theme.mono(12)).lineLimit(1)
                    if key.secret { Text(verbatim: "🔒").font(Theme.mono(10)).foregroundStyle(Theme.Color.textMuted) }
                    Spacer(minLength: 8)
                    Button { editing = KeyEdit(key: key.name, env: env) } label: {
                        Text(verbatim: isSet ? "задан" : "не задан").font(Theme.mono(11))
                            .foregroundStyle(isSet ? Theme.Color.ok : Theme.Color.warn)
                    }
                    .buttonStyle(.plain)
                    .help("Change value")
                }
                .help(key.description ?? "")
            }
            Text(verbatim: "Значения не показываются нигде: ни здесь, ни агенту. Проект получает их через practicesctl run \(service.id) -- …")
                .font(Theme.ui(11)).foregroundStyle(Theme.Color.textMuted).fixedSize(horizontal: false, vertical: true)
        }
        .modifier(CardChrome())
    }

    private var guards: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle("Защита · " + ru(service.guards.count, "правило", "правила", "правил"), color: Theme.Color.warn)
                .padding(.bottom, 2)
            ForEach(service.guards, id: \.self) { rule in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: "▸").foregroundStyle(Theme.Color.warn)
                    Text(verbatim: rule).fixedSize(horizontal: false, vertical: true)
                }
                .font(Theme.ui(12))
            }
        }
        .modifier(CardChrome(background: Theme.Color.warn.opacity(0.05), border: Theme.Color.warn.opacity(0.35)))
    }

    private var copies: some View {
        let mine = registry.copies?.filter { $0.ref.hasPrefix(service.id + "/") }
        return SectionCard("Копии в проектах" + (mine.map { " · \($0.count)" } ?? ""), spacing: 6) {
            if let mine {
                ForEach(mine, id: \.self) { copy in
                    let state = copyState(copy)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: shortPath(copy.path)).font(Theme.mono(12)).lineLimit(1).truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .help(copy.path)
                        Text(verbatim: Practice(ref: copy.ref).name).font(Theme.ui(11)).foregroundStyle(Theme.Color.textMuted)
                        Text(verbatim: state.0).font(Theme.mono(11)).foregroundStyle(state.1)
                    }
                }
                if mine.isEmpty {
                    empty("Отмеченных копий в ~/Projects нет. get_practice отдаёт код со строкой-меткой.")
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

    private func copyState(_ copy: PracticeCopy) -> (String, Color) {
        switch copy.state {
        case .current: ("v\(copy.version ?? 0)", Theme.Color.ok)
        case .outdated: ("v\(copy.version ?? 0) → v\(copy.latest)", Theme.Color.warn)
        case .modified: ("изменена", Theme.Color.link)
        case .unknown: ("версия неизвестна", Theme.Color.textMuted)
        }
    }

    private var docs: some View {
        let docs = registry.docs(of: service.id)
        return SectionCard("Документация", spacing: 6) {
            ForEach(docs, id: \.self) { doc in
                Button { registry.open(doc, of: service.id) } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: doc.title).font(Theme.ui(12)).foregroundStyle(Theme.Color.link)
                        Text(verbatim: [doc.kind.rawValue, doc.section].compactMap { $0 }.joined(separator: " · "))
                            .font(Theme.ui(11)).foregroundStyle(Theme.Color.textMuted)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if docs.isEmpty { empty("Документов нет") }
        }
    }

    private var notes: some View {
        SectionCard("Заметки", spacing: 6) {
            if let text = registry.notes(of: service.id), !text.isEmpty,
               let attributed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                Text(attributed).font(Theme.ui(12)).foregroundStyle(Theme.Color.text).textSelection(.enabled)
            } else {
                empty("Заметок нет")
            }
        }
    }

    @ViewBuilder
    private var fields: some View {
        let fields = registry.fields(of: service.id)
        if !fields.isEmpty {
            SectionCard("Поля · \(fields.filter { $0.meaning != nil }.count)/\(fields.count)", spacing: 8) {
                Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 7) {
                    ForEach(fields, id: \.path) { field in
                        GridRow {
                            Text(verbatim: field.path).font(Theme.mono(12))
                            Text(verbatim: field.type ?? "").font(Theme.mono(12)).foregroundStyle(Theme.Color.textSecondary)
                            VStack(alignment: .leading, spacing: 2) {
                                if let meaning = field.meaning {
                                    Text(verbatim: meaning).font(Theme.ui(12))
                                } else {
                                    Text(verbatim: "Нет описания").font(Theme.ui(12)).foregroundStyle(Theme.Color.warn)
                                }
                                if let values = field.values {
                                    Text(verbatim: values.sorted { $0.key < $1.key }.map { "\($0.key) — \($0.value)" }.joined(separator: " · "))
                                        .font(Theme.ui(11)).foregroundStyle(Theme.Color.textSecondary)
                                }
                            }
                            Text(verbatim: (field.from ?? []).map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))
                                .font(Theme.ui(11)).foregroundStyle(Theme.Color.textMuted).lineLimit(2)
                        }
                    }
                }
            }
        }
    }

    private func empty(_ text: String) -> some View {
        Text(verbatim: text).font(Theme.ui(12)).foregroundStyle(Theme.Color.textMuted)
    }
}

extension RegistryModel {
    /// Distinct services that link to this one («shared · N вызывающих»).
    func callers(of id: String) -> Int { Set(links(to: id).map(\.from)).count }
}

/// Badge: mono 10.5, padding 1 6, radius 4, a colour on its 0.16 background.
private struct Badge: View {
    let text: String
    let color: Color
    let background: Color
    init(_ text: String, color: Color, background: Color) { self.text = text; self.color = color; self.background = background }
    var body: some View {
        Text(verbatim: text).font(Theme.mono(10.5)).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(background, in: RoundedRectangle(cornerRadius: 4))
            .fixedSize()
    }
}

/// SectionCard's chrome for cards with their own header (keys with an env picker, guards tinted warn).
private struct CardChrome: ViewModifier {
    var background = Theme.Color.cardBg
    var border = Theme.Color.borderCard
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(border))
    }
}

/// Two columns sharing the width as `left fr / right fr` (the design's `1.2fr 1fr`), tops aligned.
private struct FractionColumns: Layout {
    let left: CGFloat
    let right: CGFloat
    let spacing: CGFloat

    private func widths(_ total: CGFloat) -> [CGFloat] {
        let room = max(total - spacing, 0)
        return [room * left / (left + right), room * right / (left + right)]
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 900
        let w = widths(width)
        let height = zip(subviews, w).map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let w = widths(bounds.width)
        var x = bounds.minX
        for (view, width) in zip(subviews, w) {
            view.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading, proposal: ProposedViewSize(width: width, height: nil))
            x += width + spacing
        }
    }
}

/// Sets a value without ever showing the current one.
struct SecretSheet: View {
    @Environment(RegistryModel.self) private var registry
    @Environment(\.dismiss) private var dismiss
    let service: Service
    let key: String
    let env: String
    @State private var value = ""

    var body: some View {
        let isSet = registry.keyStatus[service.id]?[env]?.contains(key) == true
        VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: "\(key)").font(.headline.monospaced())
            Text(verbatim: "\(service.name) · \(env)").foregroundStyle(.secondary)
            SecureField(isSet ? "New value (the current one stays hidden)" : "Value", text: $value)
                .textFieldStyle(.roundedBorder)
                .frame(width: 380)
            HStack {
                if isSet {
                    Button("Remove value", role: .destructive) {
                        registry.unset(key: key, service: service.id, env: env)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    registry.set(value, key: key, service: service.id, env: env)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(value.isEmpty)
            }
        }
        .padding(20)
    }
}

/// The old card, still used by ProjectView and SpaceView until they move to `SectionCard`.
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
