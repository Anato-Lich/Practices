import SwiftUI
import AppKit
import PracticesCore

/// The map (`work/2026-11-08-map`): space (frames or flow) → project (even grid) → service
/// (its thread); zoom and pan on every level, a click pins a service and opens the side panel.
struct MapView: View {
    @Environment(RegistryModel.self) private var registry
    private var state: MapState { registry.map }

    var body: some View {
        HStack(spacing: 0) {
            Group {
                switch state.level {
                case .space: SpaceMapView(state: state)
                case .project: ProjectMapView(state: state)
                case .service: ServiceMapView(state: state)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if let id = state.pinned, let s = state.lookup(id) {
                MapSidePanel(state: state, service: s)
                    .frame(width: 320)
                    .overlay(alignment: .leading) { Theme.Color.border.frame(width: 1) }
            }
        }
        .background(Theme.Color.windowBg)
        .toolbarLeading { MapTitle(state: state) }
        .toolbarTrailing { MapControls(state: state) { openCard() } }
        .onAppear { start() }
    }

    /// The first visit opens the first space; later ones return to where the map was. A card's
    /// «Карта» button sets the level itself before coming here.
    private func start() {
        if state.space.isEmpty || !registry.spaces.contains(where: { $0.id == state.space }) {
            state.space = registry.spaces.first?.id ?? ""
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
            if state.level == .space, registry.spaces.count > 1 {
                Menu {
                    ForEach(registry.spaces, id: \.id) { s in
                        Button { state.show(space: s.id) } label: { Text(verbatim: "\(s.id) — \(s.name)") }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(verbatim: state.space).font(Theme.mono(15, .semibold)).foregroundStyle(Theme.Color.text)
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.Color.textMuted)
                    }
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            } else {
                Breadcrumb(crumbs: crumbs, title: title)
            }
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

    private var crumbs: [Crumb] {
        guard state.level != .space else { return [] }
        var path = registry.path(of: state.project ?? "")
        if state.level == .project { path = Array(path.dropLast()) }
        return [Crumb(label: state.space) { state.show(space: state.space) }]
            + path.map { p in Crumb(label: p.id, color: registry.zoneColor(of: p.id)) { state.open(project: p.id) } }
    }

    private var subtitle: String {
        let c = state.catalogue
        switch state.level {
        case .space:
            let map = ServiceMap.space(state.space, in: c)
            return [ru(map.projects.count, "проект", "проекта", "проектов"),
                    ru(map.pairs.reduce(0) { $0 + $1.count }, "связь", "связи", "связей") + " между проектами"].joined(separator: " · ")
        case .project:
            guard let id = state.project else { return "" }
            let map = ServiceMap.project(id, in: c)
            return [ru(map.own.count, "сервис", "сервиса", "сервисов"),
                    ru(map.pairs.reduce(0) { $0 + $1.links.count }, "связь", "связи", "связей"),
                    ru(map.callers.count + map.callees.count, "сосед", "соседа", "соседей")].joined(separator: " · ")
        case .service:
            guard let id = state.service else { return "" }
            let t = ServiceMap.thread(id, in: c, hops: state.hops)
            return ru(t.up.reduce(0) { $0 + $1.count }, "выше", "выше", "выше") + " · "
                + ru(t.down.reduce(0) { $0 + $1.count }, "ниже", "ниже", "ниже") + " · до " + ru(state.hops, "шага", "шагов", "шагов")
        }
    }

    private var levels: some View {
        HStack(spacing: 0) {
            segment("Пространство", enabled: true, on: state.level == .space) { state.show(space: state.space) }
            segment("Проект", enabled: state.project != nil, on: state.level == .project) { state.open(project: state.project!) }
            segment("Сервис", enabled: state.service != nil, on: state.level == .service) { state.focus(state.service!) }
        }
        .padding(2)
        .background(Theme.Color.buttonBg, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.Color.border))
    }
}

/// Segment of a control: padding 3 14, radius 5, accent when on.
private func segment(_ label: String, enabled: Bool = true, on: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Text(verbatim: label).font(Theme.ui(13))
            .foregroundStyle(on ? .white : enabled ? Theme.Color.text : Theme.Color.textDisabled)
            .padding(.horizontal, 14).padding(.vertical, 3)
            .background(on ? Theme.Color.accent : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(!enabled)
}

/// Right of the toolbar: «Рамки / Поток» or the thread's depth, the zoom, «1:1», the card.
private struct MapControls: View {
    @Bindable var state: MapState
    let openCard: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if state.level == .space {
                HStack(spacing: 0) {
                    segment("Рамки", on: state.spaceMode == .frames) { state.spaceMode = .frames }
                    segment("Поток", on: state.spaceMode == .flow) { state.spaceMode = .flow }
                }
                .padding(2)
                .background(Theme.Color.buttonBg, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.Color.border))
                .fixedSize()
            }
            if state.level == .service {
                Stepper(value: $state.hops, in: 1...5) {
                    Text(verbatim: "шагов: \(state.hops)").font(Theme.ui(12)).foregroundStyle(Theme.Color.textSecondary)
                }
                .fixedSize()
            }
            Text(verbatim: "\(Int((state.scale * 100).rounded())) %").font(Theme.mono(11)).foregroundStyle(Theme.Color.textMuted)
                .monospacedDigit().frame(width: 44, alignment: .trailing)
            ToolbarButton("1:1") { state.zoom(to: 1, around: CGPoint(x: state.viewSize.width / 2, y: state.viewSize.height / 2)) }
                .help("Масштаб 1:1; двойной клик по карте — вписать")
            ToolbarButton("Открыть карточку", action: openCard)
        }
    }
}

// MARK: - Shared pieces

/// Focus: the focused service, its neighbours over `pairs`; nil — nothing focused.
@MainActor private func litSet(_ state: MapState, _ pairs: [ServiceMap.Pair]) -> Set<String>? {
    guard let f = state.focused else { return nil }
    var lit: Set<String> = [f]
    for p in pairs where p.from == f || p.to == f { lit.insert(p.from); lit.insert(p.to) }
    return lit
}

/// A pair's colour: by its via, a write to a database warn.
private func color(_ p: ServiceMap.Pair) -> Color {
    p.links.contains { $0.via == "db" && $0.access == "write" } ? Theme.viaColor("db", access: "write") : Theme.viaColor(p.via)
}

/// Lines lit by the focus go on top, the rest dimmed.
private func ordered(_ lines: [(line: MapLine, ends: [String])], focus: String?) -> [MapLine] {
    guard let f = focus else { return lines.map(\.line) }
    let on = lines.filter { $0.ends.contains(f) }.map(\.line)
    let off = lines.filter { !$0.ends.contains(f) }.map { l -> MapLine in var x = l.line; x.opacity *= 0.18; return x }
    return off + on
}

private func tooltip(_ s: Service) -> String { [s.name, s.description].compactMap { $0 }.joined(separator: "\n") }

/// A one-line card: the kind dot (or bar), the id, ⚑ when it has conditions. Lit when focused
/// (white border) or a neighbour of the focused one (accent glow); dimmed otherwise.
private struct MapChip: View {
    let state: MapState
    let service: Service
    var size: CGSize
    var lit: Set<String>?
    var stub = false
    var bar = false
    var projectDot = false
    var radius: CGFloat = 6

    var body: some View {
        let id = service.id, cls = ServiceClass(for: service)
        let isSelf = state.focused == id, glow = !isSelf && (lit?.contains(id) ?? false)
        HStack(spacing: 7) {
            if bar { RoundedRectangle(cornerRadius: 2).fill(cls.color).frame(width: 4).padding(.vertical, 0) }
            else { Circle().fill(cls.color).frame(width: 8, height: 8) }
            if projectDot { Circle().fill(state.color(ofProject: service.project)).frame(width: 7, height: 7) }
            Text(verbatim: id).font(Theme.mono(12, stub ? .regular : .semibold))
                .foregroundStyle(stub ? Theme.Color.textSecondary : Theme.Color.text).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            if !service.conditionIDs.isEmpty { Text(verbatim: "⚑").font(Theme.ui(11)).foregroundStyle(Theme.Color.warn) }
        }
        .padding(.leading, bar ? 0 : 10).padding(.trailing, 8)
        .frame(width: size.width, height: min(size.height, bar ? size.height : 32), alignment: .leading)
        .frame(width: size.width, height: size.height, alignment: .top)
        .background(stub ? Color(hex: 0x212124) : Theme.Color.cardBg, in: RoundedRectangle(cornerRadius: radius))
        .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(
            isSelf ? .white : glow ? Theme.Color.accent : Theme.Color.borderCard,
            style: StrokeStyle(lineWidth: isSelf || glow ? 2 : 1, dash: stub && !glow && !isSelf ? [3, 3] : [])))
        .clipShape(RoundedRectangle(cornerRadius: radius))
        .shadow(color: glow ? Theme.Color.accent.opacity(0.8) : .clear, radius: 5)
        .opacity(lit.map { $0.contains(id) ? 1 : 0.3 } ?? 1)
        .help(tooltip(service))
        .contentShape(Rectangle())
        .onHover { state.hover = $0 ? id : (state.hover == id ? nil : state.hover) }
        .onTapGesture { state.pin(id) }
    }
}

/// Bottom-left legend: kind dots, via lines and a note.
private struct MapLegend: View {
    var projects: [(String, Color)] = []
    var note: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                Text(verbatim: "вид")
                ForEach([ServiceClass.front, .api, .data, .bus, .hw, .worker, .ext], id: \.self) { c in
                    HStack(spacing: 4) { Circle().fill(c.color).frame(width: 8, height: 8); Text(verbatim: c.rawValue) }
                }
            }
            HStack(spacing: 10) {
                Text(verbatim: "связь")
                ForEach(["http", "topic", "db", "network", "build"], id: \.self) { v in
                    HStack(spacing: 4) { RoundedRectangle(cornerRadius: 2).fill(Theme.viaColor(v)).frame(width: 14, height: 3); Text(verbatim: v) }
                }
                HStack(spacing: 4) { RoundedRectangle(cornerRadius: 2).fill(Theme.viaColor("db", access: "write")).frame(width: 14, height: 3); Text(verbatim: "db write") }
            }
            // Projects in rows of 6, so a big space (x-keeper: 17) does not run past the window.
            ForEach(Array(stride(from: 0, to: projects.count, by: 6)), id: \.self) { start in
                HStack(spacing: 10) {
                    Text(verbatim: "проект").opacity(start == 0 ? 1 : 0)
                    ForEach(start..<min(start + 6, projects.count), id: \.self) { i in
                        HStack(spacing: 4) { Circle().fill(projects[i].1).frame(width: 8, height: 8); Text(verbatim: projects[i].0) }
                    }
                }
            }
            if let note { Text(verbatim: note) }
        }
        .font(Theme.ui(11)).foregroundStyle(Theme.Color.textMuted)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Theme.Color.cardBg.opacity(0.92), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.Color.border))
        .fixedSize()
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }
}

/// Pills at the view's edge for the focused card's neighbours that are out of view.
private struct EdgeMarks: View {
    let state: MapState
    let rects: [String: CGRect]
    let pairs: [ServiceMap.Pair]

    var body: some View {
        let size = state.viewSize
        ZStack(alignment: .topLeading) {
            if let f = state.focused, rects[f] != nil {
                let others = Set(pairs.filter { $0.from == f || $0.to == f }.map { $0.from == f ? $0.to : $0.from })
                ForEach(others.sorted(), id: \.self) { id in
                    if let r = rects[id] {
                        let p = state.onScreen(CGPoint(x: r.midX, y: r.midY))
                        if p.x < 0 || p.x > size.width || p.y < 0 || p.y > size.height {
                            let text = (p.x < 0 ? "← " : p.x > size.width ? "" : p.y < 0 ? "↑ " : "↓ ") + id + (p.x > size.width ? " →" : "")
                            Text(verbatim: text).font(Theme.mono(11)).foregroundStyle(.white)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Theme.Color.accent, in: Capsule())
                                .fixedSize()
                                .position(x: min(max(p.x, 70), size.width - 70), y: min(max(p.y, 14), size.height - 14))
                        }
                    }
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}

private extension View {
    /// At a rectangle of the map's content (inside a top-leading `ZStack`).
    func placed(_ r: CGRect) -> some View { frame(width: r.width, height: r.height, alignment: .topLeading).offset(x: r.minX, y: r.minY) }
    func placed(_ x: CGFloat, _ y: CGFloat) -> some View { fixedSize().offset(x: x, y: y) }
}

// MARK: - Level 1: space

private struct SpaceMapView: View {
    let state: MapState

    var body: some View {
        switch state.spaceMode {
        case .frames: SpaceFramesView(state: state)
        case .flow: SpaceFlowView(state: state)
        }
    }
}

/// Variant B: project frames; under 0.8× bundles with counts, from 0.8× every link.
private struct SpaceFramesView: View {
    let state: MapState

    var body: some View {
        let space = state.space
        let layout = state.cached("frames:\(space)") { SpaceFrames(space: space, catalogue: state.catalogue, pairs: state.pairs) }
        let pairs = layout.lines.map(\.pair)
        ZoomPan(state: state, key: "frames:\(space)", size: layout.size) {
            ZStack(alignment: .topLeading) {
                ForEach(layout.frames.indices, id: \.self) { i in frame(layout.frames[i]) }
                ForEach(layout.frames.flatMap(\.subs), id: \.project) { sub($0) }
                FramesLines(state: state, layout: layout)
                ForEach(layout.frames.indices, id: \.self) { i in
                    ForEach(layout.frames[i].services, id: \.id) { s in
                        MapChip(state: state, service: s, size: layout.chips[s.id]!.size,
                                lit: litSet(state, pairs), bar: true, radius: 5)
                            .placed(layout.chips[s.id]!)
                    }
                }
            }
        } overlay: {
            MapLegend(note: "< 80 % — пучки между проектами с числом связей, ≥ 80 % — каждая связь сервис → сервис; клик — закрепить")
        }
    }

    /// A sub-project inside its parent's frame: radius 9, a lighter fill, the title in its colour.
    private func sub(_ f: SpaceFrames.Sub) -> some View {
        RoundedRectangle(cornerRadius: 9).fill(Color(hex: 0x28282C))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color(hex: 0x3A3A3E)))
            .overlay(alignment: .topLeading) {
                Button { state.open(project: f.project) } label: {
                    Text(verbatim: f.project).font(Theme.ui(13, .semibold)).foregroundStyle(state.color(ofProject: f.project)).lineLimit(1)
                }
                .buttonStyle(.plain)
                .padding(.leading, SpaceFrames.pad).padding(.top, 7)
            }
            .placed(f.rect)
    }

    /// Frame: radius 12, a colour bar under the title (it opens the project), counts on the right.
    private func frame(_ f: SpaceFrames.Frame) -> some View {
        RoundedRectangle(cornerRadius: 12).fill(Color(hex: 0x222225))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(hex: 0x3A3A3E)))
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 4) {
                    Button { state.open(project: f.project) } label: {
                        Text(verbatim: f.title).font(Theme.ui(17, .semibold)).foregroundStyle(Theme.Color.text).lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    RoundedRectangle(cornerRadius: 1.5).fill(state.color(ofProject: f.project)).frame(width: 30, height: 3)
                }
                .padding(.leading, SpaceFrames.pad).padding(.top, 10)
            }
            .overlay(alignment: .topTrailing) {
                Text(verbatim: f.rect.width > 300 || f.title.count < 12 ? "\(f.services.count) серв · \(f.inner) внутр." : "\(f.services.count)").font(Theme.ui(11)).foregroundStyle(Theme.Color.textMuted)
                    .monospacedDigit().padding(.trailing, SpaceFrames.pad).padding(.top, 15)
            }
            .placed(f.rect)
    }
}

/// The frames' lines: they depend on the zoom, so only they are redrawn while it changes.
private struct FramesLines: View {
    let state: MapState
    let layout: SpaceFrames

    var body: some View {
        let far = state.scale < 0.8, focus = state.focused
        ZStack(alignment: .topLeading) {
            if far {
                MapLines(lines: ordered(layout.bundles.map { b in
                    (MapLine(path: MapGeometry.rounded(b.points), color: Color(hex: 0x8A8A90), width: MapGeometry.width(b.count) + 1, opacity: 0.8),
                     focus.map { b.ends.contains($0) } == true ? [focus!] : [])
                }, focus: focus))
                ForEach(layout.bundles.indices, id: \.self) { i in
                    let b = layout.bundles[i], dim = focus != nil && !b.ends.contains(focus!)
                    Text(verbatim: "\(b.count)").font(Theme.ui(13, .semibold)).monospacedDigit().foregroundStyle(Theme.Color.text)
                        .frame(width: 26, height: 26)
                        .background(Color(hex: 0x2C2C2F), in: Circle())
                        .overlay(Circle().strokeBorder(Color(hex: 0x666666)))
                        .help("\(b.a) ↔ \(b.b): " + ru(b.count, "связь", "связи", "связей") + "\nприблизьте (≥ 80 %), чтобы увидеть каждую")
                        .opacity(dim ? 0.25 : 1)
                        .position(b.badge)
                }
            } else {
                MapLines(lines: ordered(layout.lines.map { l in
                    let pts = l.points, n = pts.count
                    return (MapLine(path: MapGeometry.rounded(pts, radius: 4), tip: pts[n - 1], back: pts[n - 2], color: color(l.pair),
                                    width: MapGeometry.width(l.pair.links.count), opacity: 0.8, dashed: l.pair.via == "build"), [l.pair.from, l.pair.to])
                }, focus: focus))
            }
        }
        .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
        .allowsHitTesting(far)
    }
}

/// Variant A: columns by role, threads left to right, the project as a colour dot.
private struct SpaceFlowView: View {
    let state: MapState

    var body: some View {
        let space = state.space
        let layout = state.cached("flow:\(space)") { SpaceFlow(space: space, catalogue: state.catalogue, pairs: state.pairs, roles: state.roles) }
        let pairs = layout.lines.map(\.pair), lit = litSet(state, pairs)
        let byID = Dictionary(state.catalogue.services.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let projects = Set(layout.chips.keys.compactMap { byID[$0]?.project }).sorted()
        ZoomPan(state: state, key: "flow:\(space)", size: layout.size) {
            ZStack(alignment: .topLeading) {
                ForEach(layout.columns.indices, id: \.self) { i in header(layout.columns[i]) }
                MapLines(lines: ordered(layout.lines.map { l in
                    let t = MapGeometry.thread(l.from, l.to)
                    return (MapLine(path: t.path, tip: t.tip, back: t.back, color: color(l.pair), width: MapGeometry.width(l.pair.links.count),
                                    opacity: 0.7, dashed: l.pair.via == "build"), [l.pair.from, l.pair.to])
                }, focus: state.focused))
                ForEach(layout.chips.keys.sorted(), id: \.self) { id in
                    if let s = byID[id] {
                        MapChip(state: state, service: s, size: CGSize(width: SpaceFlow.chipW, height: SpaceFlow.chipH), lit: lit, bar: true, projectDot: true, radius: 5)
                            .placed(layout.chips[id]!)
                    }
                }
            }
        } overlay: {
            MapLegend(projects: projects.map { ($0, state.color(ofProject: $0)) },
                      note: layout.hidden > 0 ? "служебные (ops) скрыты: \(layout.hidden)" : nil)
        }
    }

    @ViewBuilder private func header(_ c: SpaceFlow.Column) -> some View {
        if !c.title.isEmpty { SectionTitle("\(c.title) · \(c.count)").monospacedDigit().placed(c.x, c.top - 26) }
        ForEach(c.heads.indices, id: \.self) { i in
            let h = c.heads[i]
            Text(verbatim: h.project).font(Theme.ui(11, .semibold)).foregroundStyle(state.color(ofProject: h.project)).placed(c.x + 2, h.y + 6)
        }
    }
}

// MARK: - Level 2: project

/// Variant E: the even grid; the whole project fits when opened (not under 0.5×).
private struct ProjectMapView: View {
    @Environment(RegistryModel.self) private var registry
    let state: MapState

    var body: some View {
        if let id = state.project {
            let grid = state.cached("project:\(id)") { ProjectGrid(ServiceMap.project(id, in: state.catalogue), roles: state.roles) }
            let pairs = grid.edges.map(\.pair), lit = litSet(state, pairs)
            ZoomPan(state: state, key: "project:\(id)", size: grid.size, minimum: 0.5) {
                ZStack(alignment: .topLeading) {
                    ForEach(grid.titles.indices, id: \.self) { i in title(grid.titles[i]) }
                    MapLines(lines: ordered(grid.edges.flatMap { e -> [(line: MapLine, ends: [String])] in
                        let pts = e.points, n = pts.count, ends = [e.pair.from, e.pair.to]
                        let topics = brokerTopics(e.pair, grid)
                        // Links to a broker: one thin line, a line per topic for the focused card.
                        guard topics.count > 1 else {
                            return [(MapLine(path: MapGeometry.rounded(pts), tip: pts[n - 1], back: pts[n - 2], color: color(e.pair),
                                             width: topics.isEmpty ? MapGeometry.width(e.pair.links.count) : 1.4, opacity: 0.9, dashed: e.pair.via == "build"), ends)]
                        }
                        let fan = ends.contains(state.focused ?? "") ? min(topics.count, 8) : 1
                        return (0..<fan).map { i in
                            let d = 3 * (CGFloat(i) - CGFloat(fan - 1) / 2), q = pts.map { CGPoint(x: $0.x, y: $0.y + d) }
                            return (MapLine(path: MapGeometry.rounded(q), tip: q[n - 1], back: q[n - 2], color: color(e.pair), width: 1.4, opacity: 0.9), ends)
                        }
                    }, focus: state.focused))
                    ForEach(grid.edges.indices, id: \.self) { i in badge(grid.edges[i], grid) }
                    ForEach(grid.heads.indices, id: \.self) { i in head(grid.heads[i]) }
                    ForEach(grid.cards.keys.sorted(), id: \.self) { sid in
                        let c = grid.cards[sid]!
                        MapChip(state: state, service: c.service, size: c.rect.size, lit: lit, stub: c.stub, radius: c.stub ? 7 : 8)
                            .placed(c.rect)
                    }
                }
            } overlay: {
                ZStack {
                    EdgeMarks(state: state, rects: grid.cards.mapValues(\.rect), pairs: pairs)
                    MapLegend(note: "пунктир — сервисы других проектов; клик — закрепить, двойной клик по полю — вписать")
                }
            }
        }
    }

    /// The topics of a pair whose far end is a broker (kafka, rabbitmq), empty for other pairs.
    private func brokerTopics(_ p: ServiceMap.Pair, _ grid: ProjectGrid) -> [String] {
        guard [p.from, p.to].contains(where: { grid.cards[$0].map { ServiceMap.isBus($0.service) } ?? false }) else { return [] }
        return Array(Set(p.links.map { $0.what ?? "—" })).sorted()
    }

    /// The count of topics at the client's end of a collapsed line (the broker's ports sit too close
    /// for a badge each); the focused card lists them.
    @ViewBuilder private func badge(_ e: ProjectGrid.Edge, _ grid: ProjectGrid) -> some View {
        let topics = brokerTopics(e.pair, grid)
        if topics.count > 1 {
            let atEnd = grid.cards[e.pair.to].map { ServiceMap.isBus($0.service) } ?? false
            let p = atEnd ? e.points[0] : e.points[e.points.count - 1]
            let open = [e.pair.from, e.pair.to].contains(state.focused ?? "")
            let shown = topics.prefix(8).joined(separator: "\n") + (topics.count > 8 ? "\n+\(topics.count - 8)" : "")
            Text(verbatim: open ? shown : "\(topics.count)")
                .font(Theme.mono(open ? 10 : 9.5, .semibold)).foregroundStyle(open ? Theme.Color.text : .black)
                .multilineTextAlignment(.trailing)
                .padding(.horizontal, 4).padding(.vertical, open ? 3 : 0)
                .background(open ? Theme.Color.cardBg.opacity(0.95) : Theme.viaColor("topic"), in: RoundedRectangle(cornerRadius: open ? 4 : 6))
                .fixedSize()
                .help(topics.joined(separator: "\n"))
                .position(x: p.x + (atEnd ? 14 : -14) * (open ? 3 : 1), y: p.y)
                .opacity(state.focused == nil || open ? 1 : 0.25)
        }
    }

    /// Column header and a 1 px hairline across its sub-columns; no frame.
    private func title(_ t: ProjectGrid.Title) -> some View {
        // Wraps to two lines over a narrow column, bottom-aligned to the hairline.
        VStack(alignment: .leading, spacing: 4) {
            SectionTitle("\(t.text) · \(t.count)").monospacedDigit()
                .frame(width: t.x1 - t.x0, height: 28, alignment: .bottomLeading)
            Color(hex: 0x3A3A3E).frame(width: t.x1 - t.x0, height: 1)
        }
        .placed(t.x0, 2)
    }

    /// A neighbour project's group: «project · N» in its colour; opens it.
    private func head(_ h: ProjectGrid.Head) -> some View {
        Button { state.open(project: h.project) } label: {
            Text(verbatim: "\(h.project) · \(h.count)").font(Theme.ui(12, .semibold)).foregroundStyle(state.color(ofProject: h.project))
        }
        .buttonStyle(.plain)
        .frame(width: h.rect.width, height: h.rect.height, alignment: .bottomLeading)
        .padding(.leading, 2)
        .offset(x: h.rect.minX, y: h.rect.minY)
    }
}

// MARK: - Level 3: service

/// Variant A filtered to the thread: where the data comes from on the left, where it goes on the
/// right, up to `hops`; a broker between two steps, the topics on its lines.
private struct ServiceMapView: View {
    let state: MapState

    var body: some View {
        if let id = state.service, let s = state.lookup(id) {
            let key = "thread:\(id):\(state.hops)"
            let thread = state.cached(key) { ServiceMap.thread(id, in: state.catalogue, hops: state.hops) }
            let layout = state.cached(key + ":layout") { ThreadLayout(thread, centre: s) }
            let nodes = Dictionary(thread.columns.flatMap(\.nodes).map { ($0.key, $0.service) }, uniquingKeysWith: { a, _ in a })
            let sid = { (k: String) in nodes[k]?.id ?? k }
            // Hover and pin go by service id: a broker crossed twice lights up on both sides.
            let lit = litSet(state, thread.pairs.map { var p = $0; p.from = sid(p.from); p.to = sid(p.to); return p })
            let mid = layout.chips[id].map { CGPoint(x: $0.midX, y: $0.midY) }
            ZoomPan(state: state, key: key, size: layout.size, minimum: 0.75, anchor: mid) {
                ZStack(alignment: .topLeading) {
                    ForEach(layout.columns.indices, id: \.self) { i in
                        if !layout.columns[i].title.isEmpty { SectionTitle(layout.columns[i].title).placed(layout.columns[i].x, ThreadLayout.titleY) }
                    }
                    ForEach(layout.groups.indices, id: \.self) { i in
                        let g = layout.groups[i]
                        Text(verbatim: g.title).font(Theme.ui(11)).foregroundStyle(Theme.Color.textMuted).placed(g.x + 2, g.y)
                    }
                    MapLines(lines: ordered(thread.pairs.compactMap { p in
                        guard let a = layout.chips[p.from], let b = layout.chips[p.to] else { return nil }
                        let t = MapGeometry.thread(a, b), ends = [sid(p.from), sid(p.to)]
                        // A call between two cards columns apart crosses the thread: faint unless focused.
                        let far = !ends.contains(id) && abs(layout.column[p.from, default: 0] - layout.column[p.to, default: 0]) > 1
                            && !ends.contains(state.focused ?? "")
                        return (MapLine(path: t.path, tip: t.tip, back: t.back, color: color(p), width: MapGeometry.width(p.links.count),
                                        opacity: far ? 0.3 : 0.8, dashed: p.via == "build"), ends)
                    }, focus: state.focused))
                    ForEach(thread.pairs.indices, id: \.self) { i in topics(thread.pairs[i], layout, centre: id) }
                    ForEach(nodes.keys.sorted(), id: \.self) { k in
                        let broker = layout.brokers.contains(k)
                        MapChip(state: state, service: nodes[k]!, size: layout.chips[k]!.size,
                                lit: lit, bar: !broker, projectDot: !broker, radius: broker ? ThreadLayout.chipH / 2 : 5)
                            .placed(layout.chips[k]!)
                    }
                    centre(s).placed(layout.chips[id]!)
                }
            } overlay: {
                MapLegend(note: thread.columns.isEmpty ? "данные не приходят и не уходят" : "слева — откуда приходят данные, справа — куда уходят; клик — закрепить")
            }
        }
    }

    /// The topics of a line to or from a broker, just above the line at its card's end (the
    /// broker's end when the card is the centre): cards stand a row apart, so labels never meet.
    @ViewBuilder private func topics(_ p: ServiceMap.Pair, _ layout: ThreadLayout, centre: String) -> some View {
        let names = Array(Set(p.links.filter { $0.via == "topic" }.compactMap(\.what))).sorted()
        if !names.isEmpty, let a = layout.chips[p.from], let b = layout.chips[p.to] {
            let text = names.count > 1 ? "\(names[0]) +\(names.count - 1)" : names[0]
            // A broker in the middle is the centre itself.
            let broker = layout.brokers.contains(p.from) ? p.from : layout.brokers.contains(p.to) ? p.to : centre
            let other = broker == p.from ? p.to : p.from
            let atFrom = (other == centre ? broker : other) == p.from
            let gap = (layout.gapAfter[a.minX] ?? ThreadLayout.gap) - 10, end = atFrom ? a : b
            Text(verbatim: text).font(Theme.mono(9.5)).foregroundStyle(Theme.Color.textSecondary)
                .lineLimit(1).truncationMode(.head)
                .padding(.horizontal, 2).background(Theme.Color.windowBg.opacity(0.85), in: RoundedRectangle(cornerRadius: 3))
                .frame(maxWidth: gap, alignment: atFrom ? .leading : .trailing)
                .frame(width: gap, alignment: atFrom ? .leading : .trailing)
                .help(names.joined(separator: "\n"))
                .position(x: atFrom ? end.maxX + 4 + gap / 2 : end.minX - 4 - gap / 2, y: end.midY - 9)
        }
    }

    /// The service: 236×48, 2 pt border in its kind colour, id and `name · project`.
    private func centre(_ s: Service) -> some View {
        let cls = ServiceClass(for: s)
        return VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: s.id).font(Theme.mono(14, .semibold)).lineLimit(1)
            Text(verbatim: "\(s.name) · \(s.project)").font(Theme.ui(11)).foregroundStyle(Theme.Color.textSecondary).lineLimit(1)
        }
        .padding(.horizontal, 12)
        .frame(width: ThreadLayout.centre.width, height: ThreadLayout.centre.height, alignment: .leading)
        .background(Theme.Color.cardBg, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(cls.color, lineWidth: 2))
        .help(tooltip(s))
        .contentShape(Rectangle())
        .onTapGesture { state.pin(s.id) }
    }
}

// MARK: - Side panel

/// The pinned service: what it is, its role, its links both ways (each opens its end).
private struct MapSidePanel: View {
    @Environment(RegistryModel.self) private var registry
    let state: MapState
    let service: Service

    var body: some View {
        let s = service
        let out = state.catalogue.links.filter { $0.from == s.id }.map(\.link)
        let incoming = state.catalogue.links.filter { $0.link.to == s.id }
        let role = state.role(of: s.id)
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    Text(verbatim: s.id).font(Theme.mono(14, .semibold)).textSelection(.enabled)
                    Spacer()
                    Button { state.pinned = nil } label: { Image(systemName: "xmark").foregroundStyle(Theme.Color.textMuted) }.buttonStyle(.plain)
                }
                Text(verbatim: s.name).font(Theme.ui(13)).foregroundStyle(Theme.Color.text)
                HStack(spacing: 6) {
                    KindBadge(ServiceClass(for: s))
                    if let role { Chip(role.rawValue + (s.role == role.rawValue ? "" : " ?"), color: Theme.Color.textChip).help(s.role == role.rawValue ? "роль задана" : "роль выведена по виду и связям") }
                    Chip(s.project, color: state.color(ofProject: s.project))
                }
                if !s.conditionIDs.isEmpty {
                    Text(verbatim: "⚑ " + s.conditionIDs.joined(separator: ", ")).font(Theme.mono(11)).foregroundStyle(Theme.Color.warn)
                }
                if let d = s.description { Text(verbatim: d).font(Theme.ui(12)).foregroundStyle(Theme.Color.textSecondary).textSelection(.enabled) }
                HStack(spacing: 8) {
                    ToolbarButton("Карточка") { registry.selection = .service(s.id) }
                    ToolbarButton("Нить") { state.focus(s.id) }
                    ToolbarButton("Проект") { state.open(project: s.project) }
                }
                .padding(.vertical, 4)
                SectionTitle("Исходящие · \(out.count)").padding(.top, 6)
                ForEach(out.indices, id: \.self) { i in row(out[i], other: out[i].to) }
                if out.isEmpty { none }
                SectionTitle("Входящие · \(incoming.count)").padding(.top, 6)
                ForEach(incoming.indices, id: \.self) { i in row(incoming[i].link, other: incoming[i].from) }
                if incoming.isEmpty { none }
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.Color.cardBg)
    }

    private var none: some View { Text(verbatim: "нет").font(Theme.ui(12)).foregroundStyle(Theme.Color.textMuted) }

    private func row(_ l: PracticesCore.Link, other: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(verbatim: l.via ?? "—").font(Theme.mono(10.5)).foregroundStyle(.black)
                    .padding(.horizontal, 5).background(Theme.viaColor(l.via, access: l.access), in: RoundedRectangle(cornerRadius: 4))
                Button { state.pinned = other } label: {
                    Text(verbatim: other).font(Theme.mono(12)).foregroundStyle(Theme.Color.link)
                }
                .buttonStyle(.plain)
                if let a = l.access { Text(verbatim: a).font(Theme.ui(11)).foregroundStyle(Theme.Color.textMuted) }
            }
            if let w = l.what { Text(verbatim: w).font(Theme.ui(11)).foregroundStyle(Theme.Color.textSecondary).lineLimit(3) }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Theme.Color.borderSoft.frame(height: 1) }
    }
}
