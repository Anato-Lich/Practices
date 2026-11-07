import SwiftUI
import AppKit
import PracticesCore

/// Where the map is: the level and what it shows. Kept by `MapView` while the screen is open.
@MainActor @Observable
final class MapState {
    enum Level: Hashable { case space, project, service }
    var level = Level.space
    var space = ""
    var project: String?
    var service: String?
    /// The «Общие» pill clicked: its callers lit, its lines drawn.
    var hub: String?
    var catalogue = Catalogue(projects: [], services: [], links: [])

    func lookup(_ id: String) -> Service? { catalogue.services.first { $0.id == id } }

    func open(project id: String) {
        project = id
        space = catalogue.projects.first { $0.id == id }?.space ?? space
        hub = nil
        level = .project
    }

    func focus(_ id: String) {
        service = id
        if let s = lookup(id) { project = s.project; space = s.space }
        level = .service
    }

    /// Caller → hub: the link behind a `→ hub` chip, for its colour.
    func link(from: String, to: String) -> PracticesCore.Link? { catalogue.links.first { $0.from == from && $0.link.to == to }?.link }
}

/// The map (DECISIONS 33–35): space → project → service, read-only.
struct MapView: View {
    @Environment(RegistryModel.self) private var registry
    @State private var state = MapState()

    var body: some View {
        Group {
            switch state.level {
            case .space: SpaceMapView(state: state)
            case .project: ProjectMapView(state: state)
            case .service: ServiceMapView(state: state)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .toolbarLeading { MapTitle(state: state) }
        .toolbarTrailing { ToolbarButton("Открыть карточку") { openCard() } }
        .onAppear { load(); start() }
        .onChange(of: registry.services) { load() }
    }

    private func load() {
        do { state.catalogue = try registry.registry.catalogue() } catch { registry.error = String(describing: error) }
    }

    /// The sidebar shows `.map` once the map is open, so the last card opened says where to start.
    private func start() {
        guard state.space.isEmpty else { return }
        switch registry.selection == .map ? registry.recent.first : registry.selection {
        case .service(let id)? where state.lookup(id) != nil: state.focus(id)
        case .project(let id)? where registry.project(id) != nil: state.open(project: id)
        case .space(let id)?: state.space = id
        default: state.space = registry.spaces.first?.id ?? ""
        }
    }

    private func openCard() {
        switch state.level {
        case .space: registry.selection = .space(state.space)
        case .project: if let id = state.project { registry.selection = .project(id) }
        case .service: if let id = state.service { registry.selection = .service(id) }
        }
    }
}

// MARK: - Toolbar

/// `space / project / ` **id**, the counts, the level control.
private struct MapTitle: View {
    @Environment(RegistryModel.self) private var registry
    let state: MapState

    var body: some View {
        HStack(spacing: 10) {
            Breadcrumb(crumbs: crumbs, title: title)
            Text(verbatim: subtitle).font(Theme.ui(13)).foregroundStyle(Theme.Color.textSecondary).lineLimit(1)
                .layoutPriority(-1)
            levels.fixedSize()
        }
    }

    private var title: String {
        switch state.level {
        case .space: state.space
        case .project: state.project ?? ""
        case .service: state.service ?? ""
        }
    }

    /// The space, then the projects above the shown one (all of them for a service); each opens its level.
    private var crumbs: [Crumb] {
        guard state.level != .space else { return [] }
        var path = registry.path(of: state.project ?? "")
        if state.level == .project { path = Array(path.dropLast()) }
        return [Crumb(label: state.space) { state.level = .space }]
            + path.map { p in Crumb(label: p.id, color: registry.zoneColor(of: p.id)) { state.open(project: p.id) } }
    }

    private var subtitle: String {
        let c = state.catalogue
        switch state.level {
        case .space:
            let map = ServiceMap.space(state.space, in: c)
            return [ru(map.projects.count, "проект", "проекта", "проектов"),
                    ru(map.pairs.reduce(0) { $0 + $1.count }, "связь", "связи", "связей"),
                    ru(map.pairs.count, "связанная пара", "связанные пары", "связанных пар")].joined(separator: " · ")
        case .project:
            guard let id = state.project else { return "" }
            let map = ServiceMap.project(id, in: c)
            return [ru(map.own.values.reduce(0) { $0 + $1.count }, "сервис", "сервиса", "сервисов"),
                    ru(map.edges.count, "связь", "связи", "связей") + " линиями",
                    ru(map.hubs.count, "общий", "общих", "общих"),
                    ru(map.externals.reduce(0) { $0 + $1.services.count }, "внешний", "внешних", "внешних")].joined(separator: " · ")
        case .service:
            guard let id = state.service else { return "" }
            let f = ServiceMap.service(id, in: c)
            let links = (f.callers + f.callees).reduce(0) { $0 + $1.links.count }
            return ru(f.callers.count, "вызывающий", "вызывающих", "вызывающих")
                + " из " + ru(Set(f.callers.map(\.service.project)).count, "проекта", "проектов", "проектов")
                + " · " + ru(links, "связь", "связи", "связей") + " · " + ru(f.callees.count, "зависимость", "зависимости", "зависимостей")
        }
    }

    /// Segment control: padding 2, radius 7; segments padding 3 14, radius 5, accent when on.
    private var levels: some View {
        HStack(spacing: 0) {
            segment("Пространство", .space, enabled: true)
            segment("Проект", .project, enabled: state.project != nil)
            segment("Сервис", .service, enabled: state.service != nil)
        }
        .padding(2)
        .background(Theme.Color.buttonBg, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.Color.border))
    }

    private func segment(_ label: String, _ level: MapState.Level, enabled: Bool) -> some View {
        let on = state.level == level
        return Button { state.level = level } label: {
            Text(verbatim: label).font(Theme.ui(13))
                .foregroundStyle(on ? .white : enabled ? Theme.Color.text : Theme.Color.textDisabled)
                .padding(.horizontal, 14).padding(.vertical, 3)
                .background(on ? Theme.Color.accent : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

// MARK: - Level 1: space

private struct SpaceMapView: View {
    @Environment(RegistryModel.self) private var registry
    let state: MapState
    static let threshold = 3
    /// The card under the pointer: its pairs accent, the rest dimmed.
    @State private var hover: String?

    var body: some View {
        let map = ServiceMap.space(state.space, in: state.catalogue)
        let services = state.catalogue.services.filter { $0.space == state.space }
        GeometryReader { geo in
            let layout = SpaceLayout(map, services: services, width: geo.size.width - 40)
            let rect = Dictionary(layout.cards.map { ($0.project.id, $0.rect) }, uniquingKeysWith: { a, _ in a })
            let strong = map.pairs.filter { $0.count >= Self.threshold && rect[$0.a] != nil && rect[$0.b] != nil }
            let routes = MapGeometry.routes(strong.map { p in
                let (a, b) = (rect[p.a]!, rect[p.b]!)
                return a.minX <= b.minX ? (from: a, to: b) : (from: b, to: a)
            }, obstacles: layout.obstacles, bounds: CGRect(origin: .zero, size: layout.size))
            let order = strong.indices.sorted { lit(strong[$0]) == lit(strong[$1]) ? $0 < $1 : !lit(strong[$0]) }
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 12) {
                    ZStack(alignment: .topLeading) {
                        MapLines(lines: order.map { i -> MapLine in
                            let on = lit(strong[i])
                            return MapLine(path: MapGeometry.rounded(routes[i]), color: on ? Theme.Color.accent : Color(hex: 0x9A9AA3),
                                           width: 1 + log2(CGFloat(strong[i].count)), opacity: on ? 0.95 : hover == nil ? 0.55 : 0.2)
                        })
                        ForEach(strong.indices, id: \.self) { i in
                            Text(verbatim: "\(strong[i].count)").font(Theme.mono(10.5)).foregroundStyle(Theme.Color.text)
                                .padding(.horizontal, 3).background(Theme.Color.windowBg, in: RoundedRectangle(cornerRadius: 3))
                                .position(label(routes[i]))
                        }
                        ForEach(layout.frames.indices, id: \.self) { i in zoneFrame(layout.frames[i]) }
                        ForEach(layout.cards.indices, id: \.self) { i in
                            let id = layout.cards[i].project.id
                            card(layout.cards[i].project, services: services, weak: map.pairs).placed(layout.cards[i].rect)
                                .onHover { hover = $0 ? id : nil }
                        }
                    }
                    .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
                    legend(cross: map.crossSpace)
                }
                .padding(20)
            }
        }
    }

    private func lit(_ p: (a: String, b: String, count: Int)) -> Bool { hover == p.a || hover == p.b }

    /// A pair's count sits in the middle of its route's longest segment.
    private func label(_ route: [CGPoint]) -> CGPoint {
        let (a, b) = zip(route, route.dropFirst()).max { hypot($0.1.x - $0.0.x, $0.1.y - $0.0.y) < hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }!
        return CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }

    /// Dashed frame of a parent (radius 12, 1.5 dashed at 0.6, fill 0.05); its label opens it.
    private func zoneFrame(_ f: (project: Project, rect: CGRect, services: Int)) -> some View {
        let zone = registry.zoneColor(of: f.project.id)
        return RoundedRectangle(cornerRadius: 12).fill(zone.opacity(0.05))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(zone.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])))
            .overlay(alignment: .topLeading) {
                Button { state.open(project: f.project.id) } label: {
                    Text(verbatim: "\(f.project.id) · \(f.services)").font(Theme.mono(12, .semibold)).foregroundStyle(zone)
                }
                .buttonStyle(.plain).padding(.leading, 12).padding(.top, 8)
            }
            .placed(f.rect)
    }

    /// 170×64: id, composition bar, «N серв · M репо»; pairs under the threshold as «+N».
    private func card(_ p: Project, services: [Service], weak pairs: [(a: String, b: String, count: Int)]) -> some View {
        let own = services.filter { $0.project == p.id }
        let weak = pairs.filter { $0.count < Self.threshold && ($0.a == p.id || $0.b == p.id) }.reduce(0) { $0 + $1.count }
        let parts = ServiceClass.allCases.map { c in (c, own.filter { ServiceClass(for: $0) == c }.count) }
        return VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: p.id).font(Theme.mono(12, .semibold)).lineLimit(1).truncationMode(.tail)
            CompositionBar(parts).padding(.top, 4).padding(.bottom, 3)
            Text(verbatim: "\(own.count) серв · \(p.repos.count) репо" + (weak > 0 ? " · +\(weak)" : ""))
                .font(Theme.mono(10.5)).foregroundStyle(Theme.Color.textMuted).lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(width: 170, height: 64, alignment: .leading)
        .background(Theme.Color.cardBg, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.Color.borderCard))
        .help(weak > 0 ? "\(p.name) · +" + ru(weak, "слабая связь", "слабых связи", "слабых связей") : p.name)
        .contentShape(Rectangle())
        .onTapGesture { state.open(project: p.id) }
    }

    private func legend(cross: Int) -> some View {
        HStack(spacing: 14) {
            Text(verbatim: "линии — пары с ≥ \(Self.threshold) связями, толщина ∝ log₂")
            if cross > 0 { Text(verbatim: ru(cross, "связь", "связи", "связей") + " с другими пространствами не показаны") }
            ForEach([ServiceClass.front, .api, .data, .bus, .ext], id: \.self) { c in
                HStack(spacing: 4) { RoundedRectangle(cornerRadius: 2).fill(c.color).frame(width: 8, height: 8); Text(verbatim: c.rawValue) }
            }
        }
        .font(Theme.mono(10.5)).foregroundStyle(Theme.Color.textMuted).fixedSize()
    }
}

// MARK: - Level 2: project

private struct ProjectMapView: View {
    @Environment(RegistryModel.self) private var registry
    let state: MapState
    @State private var hover: String?
    /// The card or external row under the pointer: its lines accent, the rest dimmed.
    @State private var hoverCard: String?

    var body: some View {
        if let id = state.project {
            let map = ServiceMap.project(id, in: state.catalogue)
            let layout = ProjectLayout(map)
            let hub = hover ?? state.hub
            let lit: Set<String>? = hub.map { h in Set(map.chips.filter { $0.value.contains(h) }.keys) }
            VStack(spacing: 0) {
                ScrollView([.vertical, .horizontal]) {
                    ZStack(alignment: .topLeading) {
                        boxes(layout)
                        MapLines(lines: lines(map, layout, hub: hub, dim: lit != nil))
                        MapLegend(items: viaLegend, note: "⚑ условие · чип «→ имя» — связь с общим сервисом")
                        titles(layout, map)
                        ForEach(layout.columns.indices, id: \.self) { c in
                            ForEach(layout.columns[c].services, id: \.id) { s in
                                card(s, chips: map.chips[s.id] ?? []).opacity(lit.map { $0.contains(s.id) ? 1 : 0.35 } ?? 1)
                                    .onHover { hoverCard = $0 ? s.id : nil }
                                    .placed(layout.rects[s.id]!)
                            }
                        }
                        ForEach(layout.externals.indices, id: \.self) { i in external(layout.externals[i], lit: lit).placed(layout.externals[i].rect) }
                    }
                    .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
                    .padding(20)
                }
                if !map.hubs.isEmpty { strip(map.hubs) }
            }
        }
    }

    private var viaLegend: [(String, Color)] { ["http", "topic", "db", "network", "build"].map { ($0, Theme.viaColor($0)) } }

    /// Column backgrounds: the class colour at 0.05, border 0.25; externals pink, dashed.
    @ViewBuilder private func boxes(_ layout: ProjectLayout) -> some View {
        ForEach(layout.columns.indices, id: \.self) { i in
            let c = ServiceClass(rawValue: layout.columns[i].column.rawValue) ?? .other
            RoundedRectangle(cornerRadius: 10).fill(Color(hex: c.hex, alpha: 0.05))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(hex: c.hex, alpha: 0.25)))
                .placed(CGRect(x: layout.columns[i].x, y: 44, width: 220, height: layout.boxHeight))
        }
        if !layout.externals.isEmpty {
            RoundedRectangle(cornerRadius: 10).fill(Color(hex: 0xFF7AA2, alpha: 0.04))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(hex: 0xFF7AA2, alpha: 0.3), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                .placed(CGRect(x: layout.externalX, y: 44, width: 188, height: layout.boxHeight))
        }
    }

    @ViewBuilder private func titles(_ layout: ProjectLayout, _ map: ServiceMap.ProjectMap) -> some View {
        let names: [ServiceMap.Column: String] = [.front: "Фронты", .api: "API и воркеры", .data: "Данные"]
        ForEach(layout.columns.indices, id: \.self) { i in
            let col = layout.columns[i]
            SectionTitle("\(names[col.column] ?? "") · \(col.services.count)", color: (ServiceClass(rawValue: col.column.rawValue) ?? .other).color)
                .placed(col.x + 10, 52)
        }
        if !layout.externals.isEmpty {
            SectionTitle("Внешние · \(map.externals.reduce(0) { $0 + $1.services.count })", color: ZonePalette.external).placed(layout.externalX + 10, 52)
        }
    }

    /// Plain links routed orthogonally, a hovered card's on top in accent; with a hub shown, its
    /// callers' links to the strip below.
    private func lines(_ map: ServiceMap.ProjectMap, _ layout: ProjectLayout, hub: String?, dim: Bool) -> [MapLine] {
        let grouped = Dictionary(grouping: map.edges) { [$0.from, $0.link.to] }
        // Sorted, so a link keeps its lane from one render to the next.
        let keys = grouped.keys.filter { layout.rects[$0[0]] != nil && layout.rects[$0[1]] != nil }.sorted { $0.joined(separator: " ") < $1.joined(separator: " ") }
        let ends = keys.map { (from: layout.rects[$0[0]]!, to: layout.rects[$0[1]]!) }
        let routes = MapGeometry.routes(ends, obstacles: layout.obstacles, bounds: CGRect(origin: .zero, size: layout.size))
        var lines = keys.indices.map { i -> MapLine in
            var line = MapGeometry.line(ends[i].from, ends[i].to, links: grouped[keys[i]]!.map(\.link), route: routes[i])
            if let card = hoverCard {
                if keys[i].contains(card) { line.color = Theme.Color.accent; line.opacity = 0.95 } else { line.opacity *= 0.35 }
            } else if dim { line.opacity *= 0.35 }
            return line
        }
        if let card = hoverCard { lines = keys.indices.filter { !keys[$0].contains(card) }.map { lines[$0] } + keys.indices.filter { keys[$0].contains(card) }.map { lines[$0] } }
        guard let hub else { return lines }
        let target = CGPoint(x: layout.size.width / 2, y: layout.size.height)
        for (caller, hubs) in map.chips where hubs.contains(hub) {
            guard let a = layout.rects[caller] else { continue }
            let link = state.link(from: caller, to: hub)
            var path = Path()
            let start = CGPoint(x: a.midX, y: a.maxY), back = CGPoint(x: target.x, y: target.y - 60)
            path.move(to: start)
            path.addCurve(to: target, control1: CGPoint(x: start.x, y: start.y + 60), control2: back)
            lines.append(MapLine(path: path, tip: target, back: back, color: Theme.viaColor(link?.via, access: link?.access), width: 1.6, opacity: 0.75))
        }
        return lines
    }

    /// 200×92: dot, id, ⚑; name; kind badge and `→ hub` chips in the link's colour.
    private func card(_ s: Service, chips: [String]) -> some View {
        let cls = ServiceClass(for: s)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle().fill(cls.color).frame(width: 7, height: 7)
                Text(verbatim: s.id).font(Theme.mono(12, .semibold)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                if !s.conditionIDs.isEmpty {
                    Text(verbatim: "⚑").font(Theme.ui(11)).foregroundStyle(Theme.Color.warn).help(s.conditionIDs.joined(separator: ", "))
                }
            }
            Text(verbatim: s.name).font(Theme.ui(11)).foregroundStyle(Theme.Color.textSecondary).lineLimit(1)
            Spacer(minLength: 0)
            MapFlow(spacing: 3) {
                KindBadge(cls)
                ForEach(chips, id: \.self) { hub in
                    let link = state.link(from: s.id, to: hub)
                    Chip("→ \(hub)", color: Theme.viaColor(link?.via, access: link?.access))
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(width: 200, height: 92, alignment: .topLeading)
        .background(Theme.Color.cardBg, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.Color.borderCard))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .help(s.description ?? s.name)
        .contentShape(Rectangle())
        .onTapGesture { state.focus(s.id) }
    }

    /// One card per outside project: «project · N» in its zone colour, rows of 22.
    private func external(_ e: (project: Project, services: [Service], rect: CGRect), lit: Set<String>?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Button { state.open(project: e.project.id) } label: {
                Text(verbatim: "\(e.project.id) · \(e.services.count)").font(Theme.mono(11.5, .semibold))
                    .foregroundStyle(registry.zoneColor(of: e.project.id)).lineLimit(1).frame(height: 16)
            }
            .buttonStyle(.plain).padding(.bottom, 2)
            ForEach(e.services, id: \.id) { s in
                HStack(spacing: 6) {
                    Text(verbatim: s.id).font(Theme.mono(11)).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                    KindBadge(ServiceClass(for: s))
                }
                .padding(.horizontal, 4).frame(height: 22)
                .contentShape(Rectangle())
                .onTapGesture { state.focus(s.id) }
                .onHover { hoverCard = $0 ? s.id : nil }
                .opacity(lit.map { $0.contains(s.id) ? 1 : 0.35 } ?? 1)
            }
        }
        .padding(8)
        .frame(width: 170, alignment: .topLeading)
        .background(Theme.Color.cardBg, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.Color.borderCard))
    }

    /// «Общие», pinned under the scrolled map: hover or click lights the callers; «›» or ⌥-click opens the hub.
    private func strip(_ hubs: [(service: Service, callers: Int)]) -> some View {
        MapFlow(spacing: 8) {
            SectionTitle("Общие · линии скрыты").padding(.trailing, 8).frame(height: 26)
            ForEach(hubs, id: \.service.id) { h in
                let id = h.service.id
                HStack(spacing: 6) {
                    Text(verbatim: id).font(Theme.mono(12))
                    Text(verbatim: "\(h.callers)").font(Theme.mono(11)).foregroundStyle(Theme.Color.textSecondary)
                    KindBadge(ServiceClass(for: h.service))
                    Button { state.focus(id) } label: {
                        Text(verbatim: "›").font(Theme.mono(12)).foregroundStyle(Theme.Color.textMuted).frame(width: 20, height: 20).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.leading, 10).padding(.trailing, 4).padding(.vertical, 2)
                .background(Theme.Color.cardBg, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(state.hub == id ? Theme.Color.accent : Theme.Color.borderCard))
                .help("\(h.service.name) · " + ru(h.callers, "вызывающий", "вызывающих", "вызывающих"))
                .onHover { hover = $0 ? id : nil }
                .onTapGesture {
                    if NSEvent.modifierFlags.contains(.option) { state.focus(id) } else { state.hub = state.hub == id ? nil : id }
                }
            }
            Text(verbatim: "наведение на плашку подсвечивает вызывающих; ⌥-клик открывает карту сервиса")
                .font(Theme.ui(11)).foregroundStyle(Theme.Color.textMuted).padding(.leading, 8).frame(height: 26)
        }
        .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Color.windowBg)
        .overlay(alignment: .top) { Theme.Color.border.frame(height: 1) }
    }
}

// MARK: - Level 3: service

private struct ServiceMapView: View {
    @Environment(RegistryModel.self) private var registry
    let state: MapState

    var body: some View {
        if let id = state.service, let s = state.lookup(id) {
            let focus = ServiceMap.service(id, in: state.catalogue)
            ScrollView([.vertical, .horizontal]) {
                Group {
                    if let topics = focus.topics { topicTable(s, topics) } else { fan(s, focus) }
                }
                .padding(20)
            }
        }
    }

    private func fan(_ s: Service, _ focus: ServiceMap.ServiceFocus) -> some View {
        let layout = ServiceLayout(callers: focus.callers.count, callees: focus.callees.count)
        let lines = focus.callers.indices.map { MapGeometry.line(layout.callers[$0], layout.centre, links: focus.callers[$0].links, width: 1.6) }
            + focus.callees.indices.map { MapGeometry.line(layout.centre, layout.callees[$0], links: focus.callees[$0].links, width: 1.6) }
        return ZStack(alignment: .topLeading) {
            MapLines(lines: lines)
            ForEach(focus.callers.indices, id: \.self) { i in
                label(focus.callers[i].links, width: 190).position(x: 335, y: (layout.callers[i].midY + layout.centre.midY) / 2)
            }
            ForEach(focus.callees.indices, id: \.self) { i in
                label(focus.callees[i].links, width: 84).position(x: 745, y: (layout.callees[i].midY + layout.centre.midY) / 2)
            }
            MapLegend(items: [("http", Theme.viaColor("http")), ("topic", Theme.viaColor("topic")), ("db read", Theme.viaColor("db")),
                              ("db write", Theme.viaColor("db", access: "write")), ("network", Theme.viaColor("network")), ("build", Theme.viaColor("build"))],
                      note: nil)
            SectionTitle("Вызывают · \(focus.callers.count)").placed(20, 52)
            SectionTitle("Вызывает · \(focus.callees.count)").placed(790, 52)
            if focus.callers.isEmpty { hint("никто не вызывает").placed(20, 80) }
            if focus.callees.isEmpty { hint("никуда не ходит").placed(790, 80) }
            ForEach(focus.callers.indices, id: \.self) { i in side(focus.callers[i]).placed(layout.callers[i]) }
            ForEach(focus.callees.indices, id: \.self) { i in side(focus.callees[i]).placed(layout.callees[i]) }
            centre(s).placed(layout.centre)
        }
        .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
    }

    private func hint(_ text: String) -> some View { Text(verbatim: text).font(Theme.ui(12)).foregroundStyle(Theme.Color.textMuted) }

    /// `what (access)` of each link, joined; long ones truncated, whole in the tooltip.
    private func label(_ links: [PracticesCore.Link], width: CGFloat) -> some View {
        var seen = Set<String>()
        let text = links.map { ($0.what ?? $0.via ?? "—") + ($0.access.map { " (\($0))" } ?? "") }.filter { seen.insert($0).inserted }.joined(separator: " · ")
        let write = links.contains { $0.via == "db" && $0.access == "write" }
        return Text(verbatim: text).font(Theme.mono(10.5)).foregroundStyle(write ? Theme.Color.warn : Theme.Color.text)
            .lineLimit(1).truncationMode(.tail)
            .padding(.horizontal, 3).background(Theme.Color.windowBg, in: RoundedRectangle(cornerRadius: 3))
            .frame(maxWidth: width)
            .help(text)
    }

    /// 210×64: id and kind; the project as a chip in its zone colour, the count of links.
    private func side(_ entry: (service: Service, links: [PracticesCore.Link])) -> some View {
        let s = entry.service
        let writes = entry.links.filter { $0.access == "write" }.count
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(verbatim: s.id).font(Theme.mono(12, .semibold)).lineLimit(1).truncationMode(.tail)
                KindBadge(ServiceClass(for: s))
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Chip(s.project, color: registry.zoneColor(of: s.project))
                Text(verbatim: ru(entry.links.count, "связь", "связи", "связей") + (writes > 0 ? " · \(writes) write" : ""))
                    .font(Theme.ui(10.5)).foregroundStyle(Theme.Color.textMuted)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(width: 210, height: 64, alignment: .topLeading)
        .background(Theme.Color.cardBg, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.Color.borderCard))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { state.focus(s.id) }
    }

    /// 260×120, 2pt border in the class colour: id 15/600, name · project, kind and conditions.
    private func centre(_ s: Service) -> some View {
        let cls = ServiceClass(for: s)
        return VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: s.id).font(Theme.mono(15, .semibold)).lineLimit(1)
            Text(verbatim: "\(s.name) · \(s.project)").font(Theme.ui(11.5)).foregroundStyle(Theme.Color.textSecondary).lineLimit(1)
            MapFlow(spacing: 3) {
                KindBadge(cls)
                ForEach(s.conditionIDs, id: \.self) { c in
                    Text(verbatim: "⚑ \(c)").font(Theme.mono(10.5)).foregroundStyle(Theme.Color.warn)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.Color.warn))
                }
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(width: 260, height: 120, alignment: .topLeading)
        .background(Theme.Color.cardBg, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(cls.color, lineWidth: 2))
    }

    /// A broker: the node, then Топик / Пишут / Читают / Используют instead of the fan.
    private func topicTable(_ s: Service, _ topics: [ServiceMap.Topic]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            centre(s)
            SectionTitle("Топики · \(topics.count)")
            Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 5) {
                GridRow {
                    ForEach(["Топик", "Пишут", "Читают", "Используют"], id: \.self) { SectionTitle($0) }
                }
                Theme.Color.borderSoft.frame(height: 1)
                ForEach(topics.indices, id: \.self) { i in
                    GridRow {
                        Text(verbatim: topics[i].what ?? "—").font(Theme.mono(12)).foregroundStyle(Theme.Color.text)
                        chips(topics[i].writers)
                        chips(topics[i].readers)
                        chips(topics[i].users)
                    }
                    Theme.Color.borderSoft.frame(height: 1)
                }
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: 980, alignment: .leading)
        }
    }

    private func chips(_ services: [Service]) -> some View {
        MapFlow(spacing: 3) {
            ForEach(services, id: \.id) { s in
                Chip(s.id, color: ServiceClass(for: s).color).onTapGesture { state.focus(s.id) }
            }
        }
        .frame(minWidth: 160, alignment: .leading)
    }
}

// MARK: - Shared pieces

/// The map's lines in one canvas, under the cards; arrows 7×7.
private struct MapLines: View {
    let lines: [MapLine]
    var body: some View {
        Canvas { ctx, _ in
            for l in lines {
                let color = l.color.opacity(l.opacity)
                ctx.stroke(l.path, with: .color(color), style: StrokeStyle(lineWidth: l.width, lineCap: .round))
                guard let tip = l.tip else { continue }
                let (dx, dy) = (tip.x - l.back.x, tip.y - l.back.y), len = max(hypot(dx, dy), 0.001)
                let (ux, uy) = (dx / len, dy / len)
                var arrow = Path()
                arrow.move(to: tip)
                arrow.addLine(to: CGPoint(x: tip.x - ux * 7 - uy * 3.5, y: tip.y - uy * 7 + ux * 3.5))
                arrow.addLine(to: CGPoint(x: tip.x - ux * 7 + uy * 3.5, y: tip.y - uy * 7 - ux * 3.5))
                arrow.closeSubpath()
                ctx.fill(arrow, with: .color(color))
            }
        }
        .allowsHitTesting(false)
    }
}

/// Legend: markers 16×3 radius 2, gap 14, mono 10.5 muted.
private struct MapLegend: View {
    let items: [(String, Color)]
    let note: String?
    var body: some View {
        HStack(spacing: 14) {
            ForEach(items.indices, id: \.self) { i in
                HStack(spacing: 5) { RoundedRectangle(cornerRadius: 2).fill(items[i].1).frame(width: 16, height: 3); Text(verbatim: items[i].0) }
            }
            if let note { Text(verbatim: note).padding(.leading, 10) }
        }
        .font(Theme.mono(10.5)).foregroundStyle(Theme.Color.textMuted).fixedSize()
    }
}

/// Views in a row that wraps (chips, the «Общие» pills).
private struct MapFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (i, point) in arrange(bounds.width, subviews).points.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> (points: [CGPoint], size: CGSize) {
        var points: [CGPoint] = [], x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (points, CGSize(width: maxX, height: y + rowHeight))
    }
}

private extension View {
    /// At a rectangle of the map's content (inside a top-leading `ZStack`).
    func placed(_ r: CGRect) -> some View { frame(width: r.width, height: r.height, alignment: .topLeading).offset(x: r.minX, y: r.minY) }
    func placed(_ x: CGFloat, _ y: CGFloat) -> some View { fixedSize().offset(x: x, y: y) }
}
