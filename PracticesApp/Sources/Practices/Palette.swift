import SwiftUI
import AppKit
import PracticesCore

/// The ⌘K palette (`design/Palette.dc.html`) over the whole window. Always in the window, so ⌘K
/// works with the sidebar hidden; the dialog only while `registry.paletteShown`.
struct Palette: View {
    @Environment(RegistryModel.self) private var registry

    var body: some View {
        ZStack(alignment: .top) {
            Button("") { registry.paletteShown.toggle() }.keyboardShortcut("k")
                .opacity(0).allowsHitTesting(false)
            if registry.paletteShown {
                Theme.Color.overlay.onTapGesture { registry.paletteShown = false }
                PaletteDialog().padding(.top, 96)
            }
        }
        .ignoresSafeArea()
    }
}

private struct PaletteDialog: View {
    @Environment(RegistryModel.self) private var registry
    @State private var query = ""
    @State private var index = 0
    @State private var fields: [SearchResults.FieldHit] = []
    /// service id → links into it; read once per opening, not per keystroke.
    @State private var callers: [String: Int] = [:]
    @FocusState private var focused: Bool

    struct Row {
        var header = false
        var badge = ""
        var color = Theme.Color.textMuted
        var id = ""
        var path = ""
        var name = ""
        /// The hint the row always shows (actions); the selected one shows «↩» otherwise.
        var hint = ""
        var copy = ""
        var open: () -> Void = {}
        var map: (() -> Void)?
    }

    var body: some View {
        let (rows, counts) = results()
        let selectable = rows.indices.filter { !rows[$0].header }
        let current = selectable.isEmpty ? nil : selectable[min(index, selectable.count - 1)]
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(verbatim: "›").foregroundStyle(Theme.Color.textMuted)
                TextField(text: $query, prompt: Text(verbatim: "")) { Text(verbatim: "Поиск по каталогу") }
                    .textFieldStyle(.plain).foregroundStyle(Theme.Color.text)
                    .focused($focused)
                    .onKeyPress(keys: [.upArrow, .downArrow, .return]) { press in
                        switch press.key {
                        case .upArrow: index = max(min(index, selectable.count - 1) - 1, 0)
                        case .downArrow: index = min(index + 1, max(selectable.count - 1, 0))
                        default:
                            guard let current else { return .handled }
                            let row = rows[current]
                            if press.modifiers.contains(.option) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(row.copy, forType: .string)
                            } else if press.modifiers.contains(.command) {
                                (row.map ?? row.open)()
                            } else {
                                row.open()
                            }
                            registry.paletteShown = false
                        }
                        return .handled
                    }
                    .onKeyPress(.escape) { registry.paletteShown = false; return .handled }
                    .onExitCommand { registry.paletteShown = false }
                Text(verbatim: counts).font(Theme.mono(11)).foregroundStyle(Theme.Color.textMuted).lineLimit(1).fixedSize()
            }
            .font(Theme.mono(15))
            .padding(.horizontal, 16).frame(height: 48)
            .overlay(alignment: .bottom) { Theme.Color.border.frame(height: 1) }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(rows.indices, id: \.self) { i in
                            if rows[i].header { header(rows[i].id) } else { row(rows[i], selected: i == current).id(i) }
                        }
                    }
                    .padding(6)
                }
                .scrollIndicators(.never)
                .frame(height: min(height(rows), 480))
                .onChange(of: current) { _, i in if let i { proxy.scrollTo(i) } }
            }

            HStack(spacing: 14) {
                Text(verbatim: "↑↓ выбрать")
                Text(verbatim: "↩ открыть")
                Text(verbatim: "⌘↩ карта")
                Text(verbatim: "⌥↩ копировать id")
                Spacer(minLength: 0)
                Text(verbatim: "префиксы: ") + Text(verbatim: "s: p: pr: f:").foregroundStyle(Theme.Color.textSecondary)
                    + Text(verbatim: " — сервис, проект, практика, поле")
            }
            .font(Theme.mono(10.5)).foregroundStyle(Theme.Color.textMuted).lineLimit(1)
            .padding(.horizontal, 16).frame(height: 32)
            .overlay(alignment: .top) { Theme.Color.border.frame(height: 1) }
        }
        .frame(width: 640)
        .background(Theme.Color.cardBg, in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.Color.borderButton))
        .shadow(color: .black.opacity(0.6), radius: 30, y: 24)
        .onAppear {
            focused = true
            for s in registry.services { for link in registry.links(of: s.id) { callers[link.to, default: 0] += 1 } }
        }
        .onChange(of: query) { index = 0 }
        .task(id: query) {
            let (scope, term) = Self.parse(query)
            guard scope == nil || scope == "f", term.count >= 2 else { fields = []; return }
            fields = await Task.detached { Search.run(term).fields }.value
        }
    }

    private func height(_ rows: [Row]) -> CGFloat {
        rows.reduce(12) { $0 + ($1.header ? 24 : 30) + 1 }
    }

    private func header(_ label: String) -> some View {
        Text(verbatim: label).textCase(.uppercase).font(Theme.ui(10.5, .semibold)).tracking(0.42)
            .foregroundStyle(Theme.Color.textMuted)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24, alignment: .bottomLeading)
    }

    private func row(_ row: Row, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Text(verbatim: row.badge).font(Theme.mono(10)).foregroundStyle(selected ? .white : row.color)
                .frame(width: 46).padding(.vertical, 1)
                .background(row.color.opacity(selected ? 0.3 : 0.16), in: RoundedRectangle(cornerRadius: 4))
            Text(verbatim: row.id).font(Theme.mono(12.5)).foregroundStyle(Theme.Color.text)
                .lineLimit(1).frame(minWidth: 190, alignment: .leading)
            Text(verbatim: row.path).font(Theme.mono(11)).foregroundStyle(selected ? .white.opacity(0.8) : Theme.Color.textMuted).lineLimit(1)
            Text(verbatim: row.name).font(Theme.ui(12)).foregroundStyle(selected ? .white.opacity(0.9) : Theme.Color.textSecondary)
                .lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .trailing)
            Text(verbatim: row.hint.isEmpty && selected ? "↩" : row.hint).font(Theme.mono(10.5))
                .foregroundStyle(selected ? .white.opacity(0.8) : Theme.Color.textGutter)
                .frame(minWidth: 28, alignment: .trailing)
        }
        .padding(.horizontal, 10).frame(height: 30)
        .background(selected ? Theme.Color.accent : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { row.open(); registry.paletteShown = false }
    }

    // MARK: Results

    /// `s:` `p:` `pr:` `f:` restrict the groups; `pr:` is checked before `p:`.
    static func parse(_ query: String) -> (scope: String?, term: String) {
        let q = query.trimmingCharacters(in: .whitespaces)
        for prefix in ["pr", "s", "p", "f"] where q.lowercased().hasPrefix(prefix + ":") {
            return (prefix, q.dropFirst(prefix.count + 1).trimmingCharacters(in: .whitespaces).lowercased())
        }
        return (nil, q.lowercased())
    }

    private func results() -> ([Row], String) {
        let (scope, term) = Self.parse(query)
        func has(_ s: String) -> Bool { term.isEmpty || s.lowercased().contains(term) }
        func rank(_ id: String) -> (Int, String) { (id.lowercased().hasPrefix(term) ? 0 : 1, id) }
        func wanted(_ s: String) -> Bool { scope == nil || scope == s }
        let go: (MainWindow.SidebarItem) -> () -> Void = { item in { registry.searchText = ""; registry.selection = item } }
        let toMap: () -> Void = { registry.searchText = ""; registry.selection = .map }

        let services = !wanted("s") ? [] : registry.services
            .filter { has($0.id) || has($0.name) || $0.aliases.contains(where: has) }
            .sorted { rank($0.id) < rank($1.id) }
        let projects = !wanted("p") ? [] : registry.projects
            .filter { has($0.id) || has($0.name) }.sorted { rank($0.id) < rank($1.id) }
        let practices = !wanted("pr") ? [] : (registry.practices.values.flatMap { $0 } + registry.chains.values.flatMap { $0 })
            .filter { has($0.ref) }.sorted { rank($0.ref) < rank($1.ref) }
        let fieldHits = wanted("f") ? fields : []

        var rows: [Row] = []
        if !services.isEmpty {
            rows.append(Row(header: true, id: "Сервисы"))
            for s in services.prefix(7) {
                let kind = ServiceClass(for: s)
                let practices = registry.practices[s.id]?.count ?? 0
                let calls = callers[s.id] ?? 0
                let name = [s.name, practices > 0 ? ru(practices, "практика", "практики", "практик") : nil,
                            calls > 0 ? ru(calls, "вызывающий", "вызывающих", "вызывающих") : nil].compactMap { $0 }.joined(separator: " · ")
                rows.append(Row(badge: kind.rawValue, color: kind.color, id: s.id, path: "\(s.space)/\(s.project)", name: name,
                                copy: s.id, open: go(.service(s.id)), map: toMap))
            }
        }
        if !projects.isEmpty {
            rows.append(Row(header: true, id: "Проекты"))
            for p in projects.prefix(4) {
                rows.append(Row(badge: "proj", color: registry.zoneColor(of: p.id), id: p.id, path: p.space, name: p.name,
                                copy: p.id, open: go(.project(p.id)), map: toMap))
            }
        }
        if !practices.isEmpty {
            rows.append(Row(header: true, id: "Практики"))
            for p in practices.prefix(4) {
                let run = registry.lastRun(of: p.ref)
                let path = run.map { r in (r.version.map { "v\($0) · " } ?? "") + "\(r.millis) ms" } ?? "draft"
                let waits = registry.pending.contains { $0.practice == p }
                let name = [waits ? "Ждёт приёмки" : nil, run == nil ? "не запускалась" : nil].compactMap { $0 }.joined(separator: " · ")
                rows.append(Row(badge: "pr", color: ServiceClass.worker.color, id: p.ref, path: path, name: name,
                                copy: p.ref, open: go(.practice(p.ref)), map: toMap))
            }
        }
        if !fieldHits.isEmpty {
            rows.append(Row(header: true, id: "Поля"))
            for f in fieldHits.prefix(4) {
                rows.append(Row(badge: "f", color: ServiceClass.other.color, id: f.field.path, path: f.service, name: f.field.meaning ?? "",
                                copy: f.field.path, open: go(.service(f.service)), map: toMap))
            }
        }
        // Actions on the best service match, only for a plain query.
        var actions = 0
        if scope == nil, !term.isEmpty, let s = services.first {
            let command = "practicesctl service \(s.id)"
            let copy: (String) -> () -> Void = { text in { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) } }
            let act = Theme.Color.warn
            rows.append(Row(header: true, id: "Действия"))
            rows.append(Row(badge: "act", color: act, id: "Карта → \(s.project)", name: "уровень проекта, подсветить \(s.id)",
                            hint: "⌘↩", copy: s.id, open: toMap, map: toMap))
            rows.append(Row(badge: "act", color: act, id: command, name: "скопировать команду",
                            hint: "⌥↩", copy: command, open: copy(command)))
            rows.append(Row(badge: "act", color: act, id: "Finder → …/services/\(s.id)", name: "открыть папку карточки",
                            copy: s.id, open: { registry.revealService(s.id) }))
            actions = 3
        }
        var counts = [ru(services.count, "сервис", "сервиса", "сервисов")]
        if !projects.isEmpty { counts.append(ru(projects.count, "проект", "проекта", "проектов")) }
        counts.append(ru(practices.count, "практика", "практики", "практик"))
        if !fieldHits.isEmpty { counts.append(ru(fieldHits.count, "поле", "поля", "полей")) }
        if actions > 0 { counts.append(ru(actions, "действие", "действия", "действий")) }
        return (rows, counts.joined(separator: " · "))
    }
}
