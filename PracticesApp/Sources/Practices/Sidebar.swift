import SwiftUI
import PracticesCore

/// The catalogue (`design/Sidebar.dc.html`): the field, recent cards, what waits for the user,
/// each space's tree of projects → services → practices, Doctor; counts in the footer.
struct Sidebar: View {
    @Environment(RegistryModel.self) private var registry
    @Binding var shown: Bool
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool
    @AppStorage("recentCollapsed") private var recentCollapsed = false
    /// Ids of the spaces whose sections are folded, space-separated.
    @AppStorage("collapsedSpaces") private var collapsedSpaces = ""

    typealias Item = MainWindow.SidebarItem

    var body: some View {
        let rows = rows()
        VStack(spacing: 0) {
            header
            search
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) {
                            RowView(row: $0, selected: $0.item != nil && $0.item == registry.selection, select: select, toggle: toggle, collapse: collapse)
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .scrollIndicators(.never)
                .focusable()
                .focusEffectDisabled()
                .focused($listFocused)
                .onKeyPress(.upArrow) { move(rows, -1) }
                .onKeyPress(.downArrow) { move(rows, 1) }
                .onKeyPress(.rightArrow) { open(true) }
                .onKeyPress(.leftArrow) { open(false) }
                .onChange(of: registry.selection) { _, item in
                    if let item { withAnimation(nil) { proxy.scrollTo(item.rowID) } }
                }
            }
            footer
        }
        .frame(width: 260)
        .background(Theme.Color.sidebarBg)
        .background {
            // ⌘1–3: shortcuts need a button in the window. ⌘K opens the palette (Palette.swift).
            Group {
                Button("") { select(.pending) }.keyboardShortcut("1")
                Button("") { select(.unassigned) }.keyboardShortcut("2")
                Button("") { select(.map) }.keyboardShortcut("3")
            }
            .opacity(0).allowsHitTesting(false)
        }
    }

    // MARK: Parts

    /// 52 high, like the toolbar; the traffic lights sit on the left.
    private var header: some View {
        HStack(spacing: 0) {
            Spacer()
            Button {
                if NSEvent.modifierFlags.contains(.option) {
                    collapsedSpaces = ""
                    registry.expanded.formUnion(registry.projects.map { .project($0.id) })
                } else {
                    registry.expanded.removeAll()
                }
            } label: {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.Color.textMuted)
                    .frame(width: 28, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Text(verbatim: "Свернуть всё · ⌥ развернуть всё"))
            SidebarToggle(shown: $shown)
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .background(Color.clear.contentShape(Rectangle()).gesture(WindowDragGesture()))
    }

    private var search: some View {
        @Bindable var registry = registry
        return HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.Color.textMuted)
            TextField(text: $registry.searchText, prompt: Text(verbatim: "Перейти…").foregroundStyle(Theme.Color.textMuted)) {
                Text(verbatim: "Поиск и переход")
            }
            .textFieldStyle(.plain)
            .font(Theme.ui(13)).foregroundStyle(Theme.Color.text)
            .focused($searchFocused)
            .onExitCommand { registry.searchText = ""; searchFocused = false }
            Text(verbatim: "⌘K").font(Theme.mono(10.5)).foregroundStyle(Theme.Color.textMuted)
                .padding(.horizontal, 5)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.Color.border))
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(Theme.Color.windowBg, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.Color.border))
        .padding(.horizontal, 10).padding(.bottom, 6)
    }

    private var footer: some View {
        let on = registry.selection == .settings
        return HStack(spacing: 8) {
            Text(verbatim: registry.spaces.isEmpty ? "нет пространств" : [ru(registry.spaces.count, "пространство", "пространства", "пространств"),
                            ru(registry.projects.count, "проект", "проекта", "проектов"),
                            ru(registry.services.count, "сервис", "сервиса", "сервисов")].joined(separator: " · "))
                .font(Theme.mono(10.5)).foregroundStyle(Theme.Color.textMuted).lineLimit(1)
                .allowsTightening(true).minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { select(.settings) } label: {
                Image(systemName: "gearshape").font(.system(size: 12))
                    .foregroundStyle(on ? .white : Theme.Color.textMuted)
                    .frame(width: 22, height: 20)
                    .background(on ? Theme.Color.accent : .clear, in: RoundedRectangle(cornerRadius: 4))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).help(Text(verbatim: "Настройка"))
        }
        .padding(.leading, 12).padding(.trailing, 6)
        .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24)
        .overlay(alignment: .top) { Theme.Color.border.frame(height: 1) }
    }

    // MARK: Rows

    struct Row: Identifiable {
        var id: String
        var item: Item?
        var label = ""
        var depth = 0
        var disc = ""
        /// What the disclosure glyph opens and closes.
        var toggle: Item?
        var mono = false
        var kind: ServiceClass?
        var count = ""
        var countColor = Theme.Color.textMuted
        var header = false
        /// A header that folds the rows under it; `open` is its state.
        var collapsible = false
        var open = true
        var disabled = false
        var hint = false
    }

    /// The sidebar as a flat list, the way the design draws it.
    private func rows() -> [Row] {
        var rows: [Row] = []
        let byProject = Dictionary(grouping: registry.services, by: \.project)
        func header(_ label: String) { rows.append(Row(id: "header:\(rows.count)", label: label, header: true)) }
        func total(_ p: Project) -> Int {
            (byProject[p.id]?.count ?? 0) + (registry.childProjects[p.id] ?? []).reduce(0) { $0 + total($1) }
        }
        func project(_ p: Project, _ depth: Int) {
            let children = registry.childProjects[p.id] ?? []
            let services = byProject[p.id] ?? []
            let chains = registry.chains[p.id] ?? []
            let item = Item.project(p.id)
            let leaf = children.isEmpty && services.isEmpty && chains.isEmpty
            let open = registry.expanded.contains(item)
            let n = total(p)
            rows.append(Row(id: item.rowID, item: item, label: p.id, depth: depth, disc: leaf ? "" : open ? "▾" : "▸",
                            toggle: leaf ? nil : item, mono: true, count: n > 0 ? String(n) : ""))
            guard open else { return }
            for child in children { project(child, depth + 1) }
            for service in services {
                let item = Item.service(service.id)
                let practices = registry.practices[service.id] ?? []
                let open = registry.expanded.contains(item)
                rows.append(Row(id: item.rowID, item: item, label: service.id, depth: depth + 1,
                                disc: practices.isEmpty ? "" : open ? "▾" : "▸", toggle: practices.isEmpty ? nil : item,
                                mono: true, kind: ServiceClass(for: service), count: open && !practices.isEmpty ? String(practices.count) : ""))
                if open { for practice in practices { rows.append(practiceRow(practice, depth + 2, label: practice.name)) } }
            }
            for chain in chains { rows.append(practiceRow(chain, depth + 1, label: chain.name)) }
        }

        if registry.spaces.isEmpty {
            // First run (`Sidebar.dc.html`, mode empty): the queues greyed, a hint instead of the tree.
            header("")
            for (item, label, count) in [(Item.pending, "Ждут приёмки", "0"), (.unassigned, "Не распределено", ""), (.map, "Карта", "")] {
                rows.append(Row(id: item.rowID, label: label, count: count, disabled: true))
            }
            rows.append(Row(id: "header:spaces", label: "Пространства", header: true))
            rows.append(Row(id: "hint", label: "Пока нет — добавьте на экране «Начало»", hint: true))
            return rows
        }
        if !registry.recent.isEmpty {
            rows.append(Row(id: "header:recent", label: "Недавние", header: true, collapsible: true, open: !recentCollapsed))
            for item in registry.recent where !recentCollapsed {
                var row: Row
                switch item {
                // A removed project or service may still be remembered; its row would lead nowhere.
                case .service(let id):
                    guard let service = registry.service(id) else { continue }
                    row = Row(id: "", item: item, label: id, mono: true, kind: ServiceClass(for: service))
                case .practice(let ref): row = Row(id: "", item: item, label: ref, disc: "‹›", mono: true)
                case .project(let id):
                    guard registry.project(id) != nil else { continue }
                    row = Row(id: "", item: item, label: id, disc: "▸", mono: true)
                default: continue
                }
                row.id = "recent:" + item.rowID
                rows.append(row)
            }
        }
        header("")
        let pending = registry.pending.count
        rows.append(Row(id: Item.pending.rowID, item: .pending, label: "Ждут приёмки", count: pending > 0 ? "\(pending)  ⌘1" : "⌘1",
                        countColor: pending > 0 ? Theme.Color.warn : Theme.Color.textMuted))
        let unassigned = registry.unassigned?.filter { !$0.ignored }.count ?? 0
        rows.append(Row(id: Item.unassigned.rowID, item: .unassigned, label: "Не распределено", count: unassigned > 0 ? "\(unassigned)  ⌘2" : "⌘2"))
        rows.append(Row(id: Item.map.rowID, item: .map, label: "Карта", count: "⌘3"))
        let folded = Set(collapsedSpaces.split(separator: " ").map(String.init))
        for space in registry.spaces {
            let open = !folded.contains(space.id)
            rows.append(Row(id: "header:space:" + space.id, label: space.name, header: true, collapsible: true, open: open))
            guard open else { continue }
            let projects = registry.projects.filter { $0.space == space.id }.count
            let services = registry.services.filter { $0.space == space.id }.count
            rows.append(Row(id: Item.space(space.id).rowID, item: .space(space.id), label: "Обзор", count: "\(projects) · \(services)"))
            for top in registry.topProjects where top.space == space.id { project(top, 0) }
        }
        header("")
        let findings = registry.findings?.count ?? 0
        rows.append(Row(id: Item.doctor.rowID, item: .doctor, label: "Doctor", count: findings > 0 ? String(findings) : "", countColor: Theme.Color.warn))
        return rows
    }

    private func practiceRow(_ practice: Practice, _ depth: Int, label: String) -> Row {
        let item = Item.practice(practice.ref)
        return Row(id: item.rowID, item: item, label: label, depth: depth, disc: "‹›", mono: true)
    }

    // MARK: Actions

    private func select(_ item: Item) {
        registry.searchText = ""
        registry.selection = item
        listFocused = true
    }

    /// Folds a section: «Недавние» or a space.
    private func collapse(_ headerID: String) {
        guard headerID.hasPrefix("header:space:") else { recentCollapsed.toggle(); return }
        let id = String(headerID.dropFirst("header:space:".count))
        var folded = collapsedSpaces.split(separator: " ").map(String.init)
        if folded.contains(id) { folded.removeAll { $0 == id } } else { folded.append(id) }
        collapsedSpaces = folded.joined(separator: " ")
    }

    private func toggle(_ item: Item) {
        if registry.expanded.contains(item) { registry.expanded.remove(item) } else { registry.expanded.insert(item) }
    }

    /// Up and down walk the tree rows (not the recent ones, which repeat them).
    private func move(_ rows: [Row], _ step: Int) -> KeyPress.Result {
        let items = rows.filter { !$0.id.hasPrefix("recent:") }.compactMap(\.item)
        guard !items.isEmpty else { return .ignored }
        let i = registry.selection.flatMap(items.firstIndex(of:)) ?? (step > 0 ? -1 : items.count)
        registry.selection = items[min(max(i + step, 0), items.count - 1)]
        return .handled
    }

    private func open(_ open: Bool) -> KeyPress.Result {
        guard let item = registry.selection else { return .ignored }
        switch item {
        case .project, .service: break
        default: return .ignored
        }
        if open { registry.expanded.insert(item) } else { registry.expanded.remove(item) }
        return .handled
    }

    // MARK: Row view

    /// A row: 24 high, radius 5, padding 0 8 (+16 a level); glyph 12, kind dot 7, label, count.
    /// Selected — accent background, white text and dot.
    private struct RowView: View {
        let row: Row
        let selected: Bool
        let select: (Item) -> Void
        let toggle: (Item) -> Void
        let collapse: (String) -> Void

        var body: some View {
            if row.header && row.collapsible {
                HStack {
                    SectionTitle(row.label)
                    Spacer()
                    Text(verbatim: row.open ? "▾" : "▸").font(.system(size: 10)).foregroundStyle(Theme.Color.textDisabled).frame(width: 12)
                }
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: 26, maxHeight: 26, alignment: .bottomLeading)
                .contentShape(Rectangle())
                .onTapGesture { collapse(row.id) }
            } else if row.hint {
                Text(verbatim: row.label).font(Theme.ui(12)).foregroundStyle(Theme.Color.textDisabled)
                    .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if row.header {
                SectionTitle(row.label)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, minHeight: 26, maxHeight: 26, alignment: .bottomLeading)
            } else {
                HStack(spacing: 6) {
                    Text(verbatim: row.disc).font(.system(size: 10)).opacity(0.7).frame(width: 12)
                        .contentShape(Rectangle())
                        .onTapGesture { if let t = row.toggle { toggle(t) } else if let item = row.item { select(item) } }
                    if let kind = row.kind {
                        Circle().fill(selected ? .white : kind.color).frame(width: 7, height: 7)
                    }
                    Text(verbatim: row.label)
                        .font(row.mono ? Theme.mono(12) : Theme.ui(13))
                        .lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !row.count.isEmpty {
                        Text(verbatim: row.count).font(Theme.mono(10.5)).monospacedDigit()
                            .foregroundStyle(selected ? Color.white.opacity(0.85) : row.countColor)
                            .help(Text(verbatim: { if case .space? = row.item { "проектов · сервисов" } else { "" } }()))
                    }
                }
                .foregroundStyle(selected ? .white : row.disabled ? Theme.Color.textDisabled : Theme.Color.text)
                .padding(.leading, 8 + CGFloat(row.depth) * 16).padding(.trailing, 8)
                .frame(height: 24)
                .background(selected ? Theme.Color.accent : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
                .onTapGesture { if let item = row.item { select(item) } }
                .contextMenu {
                    if case .project(let id) = row.item {
                        Button { select(.project(id)) } label: { Text(verbatim: "Открыть") }
                        Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(id, forType: .string) } label: {
                            Text(verbatim: "Скопировать id")
                        }
                        ProjectMenuItems(id: id)
                    }
                }
            }
        }
    }
}

/// The «hide the sidebar» button: in the sidebar's header, or at the start of the toolbar when it is hidden.
struct SidebarToggle: View {
    @Binding var shown: Bool
    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "sidebar.left").font(.system(size: 14)).foregroundStyle(Theme.Color.textMuted)
                .frame(width: 28, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(verbatim: shown ? "Скрыть боковую панель" : "Показать боковую панель"))
    }
}

extension MainWindow.SidebarItem {
    /// The row's id in the sidebar, for scrolling to it.
    var rowID: String {
        switch self {
        case .space(let id): "space:" + id
        case .project(let id): "project:" + id
        case .service(let id): "service:" + id
        case .practice(let ref): "practice:" + ref
        case .pending: "pending"
        case .unassigned: "unassigned"
        case .map: "map"
        case .doctor: "doctor"
        case .settings: "settings"
        }
    }
}
