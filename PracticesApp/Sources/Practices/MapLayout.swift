import SwiftUI
import PracticesCore

/// Geometry of the map's pictures (`work/2026-11-08-map`, ported from the approved prototype):
/// rectangles and line points in content coordinates; the views only place and draw.

private func up8(_ v: CGFloat) -> CGFloat { (v / 8).rounded(.up) * 8 }

/// Order of chips by kind inside a column or a frame (front, api, bus, data, hw, other, ext).
private func kindOrder(_ s: Service) -> Int {
    [ServiceClass.front, .api, .bus, .data, .hw, .worker, .other, .ext].firstIndex(of: ServiceClass(for: s)) ?? 9
}

/// Neighbours over the pairs, both directions.
private func adjacency(_ pairs: [ServiceMap.Pair]) -> [String: Set<String>] {
    var adj: [String: Set<String>] = [:]
    for p in pairs { adj[p.from, default: []].insert(p.to); adj[p.to, default: []].insert(p.from) }
    return adj
}

/// Barycentre sweeps: each column reordered by the mean position of its neighbours in other
/// columns, so threads run as straight as they can.
private func barycentre(_ columns: inout [[Service]], adj: [String: Set<String>], sweeps: Int, centred: Bool, fixed: Set<Int> = []) {
    var pos: [String: Double] = [:], col: [String: Int] = [:]
    func place() {
        for (c, list) in columns.enumerated() {
            for (i, s) in list.enumerated() { pos[s.id] = Double(i) - (centred ? Double(list.count - 1) / 2 : 0); col[s.id] = c }
        }
    }
    place()
    for _ in 0..<sweeps {
        for c in columns.indices where !fixed.contains(c) {
            let bc = Dictionary(columns[c].map { s -> (String, Double) in
                let ns = (adj[s.id] ?? []).filter { col[$0] != nil && col[$0] != c }
                return (s.id, ns.isEmpty ? pos[s.id]! : ns.reduce(0) { $0 + pos[$1]! } / Double(ns.count))
            }, uniquingKeysWith: { a, _ in a })
            columns[c].sort { (bc[$0.id]!, pos[$0.id]!) < (bc[$1.id]!, pos[$1.id]!) }
            place()
        }
    }
}

// MARK: - Project: variant E

/// One project on an even grid: one-line cards 180×32 in columns «Вызывают из других проектов →
/// Фронты → API → Воркеры → Данные и шина → Внешние и другие проекты» (API and workers one column
/// up to 5 cards), a column wrapping into sub-columns at 14 rows (neighbour columns at 24). Each link has its own ports on
/// the cards' sides and its own lane in the corridor between columns; a link skipping columns
/// crosses them in a row gap, and the gaps grow with the links they carry.
struct ProjectGrid {
    static let cardW: CGFloat = 180, cardH: CGFloat = 32, budget = 14, stubBudget = 24, lane: CGFloat = 6, titleH: CGFloat = 40

    enum Group: Hashable { case callers, front, api, work, mid, data, ext }
    struct Card { var service: Service; var rect: CGRect; var stub: Bool }
    struct Head { var project: String; var count: Int; var rect: CGRect }
    struct Title { var text: String; var count: Int; var x0: CGFloat; var x1: CGFloat }
    struct Edge { var pair: ServiceMap.Pair; var points: [CGPoint] }

    var cards: [String: Card] = [:]
    var heads: [Head] = []
    var titles: [Title] = []
    var edges: [Edge] = []
    var size = CGSize.zero

    init(_ map: ServiceMap.ProjectMap, roles: [String: Service.Role]) {
        let ownIDs = Set(map.own.map(\.id)), callerIDs = Set(map.callers.map(\.id))
        func group(_ s: Service) -> Group {
            if !ownIDs.contains(s.id) { return callerIDs.contains(s.id) ? .callers : .ext }
            switch roles[s.id] ?? .worker {
            case .external: return .ext
            case .front: return .front
            case .infra: return .data
            case .bff, .backend: return .api
            default: return .work
            }
        }
        let split = map.own.filter { [.api, .work].contains(group($0)) }.count > 5
        let logical: [(Group, String)] = [(.callers, "Вызывают из других проектов"), (.front, "Фронты")]
            + (split ? [(.api, "API"), (.work, "Воркеры")] : [(.mid, "API и воркеры")])
            + [(.data, "Данные и шина"), (.ext, "Внешние и другие проекты")]
        func g2(_ s: Service) -> Group { let g = group(s); return !split && (g == .api || g == .work) ? .mid : g }

        // Own cards by column, ordered by kind, then by their neighbours.
        let extMine = map.own.filter { g2($0) == .ext }
        var columns = logical.map { g, _ in g == .callers ? map.callers : g == .ext ? extMine + map.callees
            : map.own.filter { g2($0) == g }.sorted { (kindOrder($0), $0.id) < (kindOrder($1), $1.id) } }
        // Stubs keep their project groups; own columns follow them.
        barycentre(&columns, adj: adjacency(map.pairs), sweeps: 4, centred: false, fixed: [0, columns.count - 1])

        // Busy cards span more rows, so their ports stay 6 apart.
        var outs: [String: Int] = [:], ins: [String: Int] = [:]
        for p in map.pairs { outs[p.from, default: 0] += 1; ins[p.to, default: 0] += 1 }
        func span(_ id: String) -> Int {
            let ports = CGFloat(max(outs[id] ?? 0, ins[id] ?? 0) + 1) * Self.lane
            return 1 + max(0, Int(((ports - Self.cardH) / (Self.cardH + 16)).rounded(.up)))
        }
        enum Item { case card(Service, span: Int, stub: Bool), head(String, Int) }
        let items: [[Item]] = columns.enumerated().map { li, list in
            let stubs = logical[li].0 == .callers || logical[li].0 == .ext
            var out: [Item] = [], last: String?
            for s in list {
                let stub = stubs && !ownIDs.contains(s.id)
                if stub && s.project != last { out.append(.head(s.project, list.filter { $0.project == s.project && !ownIDs.contains($0.id) }.count)) }
                if stub { last = s.project }
                out.append(.card(s, span: span(s.id), stub: stub))
            }
            return out
        }

        // Wrap each column into sub-columns of at most `budget` rows (a head stays with its first card).
        var place: [String: (col: Int, row: Int, span: Int, stub: Bool, service: Service)] = [:]
        var headPlaces: [(project: String, count: Int, col: Int, row: Int)] = []
        var physOf: [[Int]] = [], nc = 0, rows = 0
        for (li, list) in items.enumerated() {
            guard !list.isEmpty else { physOf.append([]); continue }
            // Neighbour columns are one-line stubs under project heads: taller before they wrap.
            let budget = [.callers, .ext].contains(logical[li].0) ? Self.stubBudget : Self.budget
            var row = 0, cols = [nc]
            nc += 1
            for (k, item) in list.enumerated() {
                let need: Int
                switch item {
                case .head: if case .card(_, let s, _)? = list.dropFirst(k + 1).first { need = 1 + s } else { need = 1 }
                case .card(_, let s, _): need = s
                }
                if row + need > budget && row > 0 { row = 0; cols.append(nc); nc += 1 }
                switch item {
                case .head(let p, let n): headPlaces.append((p, n, nc - 1, row)); row += 1
                case .card(let s, let sp, let stub): place[s.id] = (nc - 1, row, sp, stub, s); row += sp
                }
                rows = max(rows, row)
            }
            physOf.append(cols)
        }

        // Which gap (above row g) a link skipping columns crosses: the nearest to its target that no
        // spanning card of the columns in between covers.
        let pairs = map.pairs.filter { place[$0.from] != nil && place[$0.to] != nil }
        var gapOf: [Int: Int] = [:], tracks = [Int](repeating: 0, count: rows + 1)
        for (i, p) in pairs.enumerated() {
            let (a, b) = (place[p.from]!, place[p.to]!)
            guard b.col > a.col + 1 else { continue }
            let between = place.values.filter { $0.col > a.col && $0.col < b.col }
            let mid = Double(b.row) + Double(b.span) / 2
            let g = (0...rows).sorted { (abs(Double($0) - mid), $0) < (abs(Double($1) - mid), $1) }
                .first { g in !between.contains { $0.row < g && g < $0.row + $0.span } } ?? b.row
            gapOf[i] = g; tracks[g] += 1
        }
        let gapH = tracks.map { max(16, up8(CGFloat($0) * Self.lane + 10)) }
        var rowTop = [CGFloat](repeating: 0, count: rows + 1)
        rowTop[0] = Self.titleH + gapH[0]
        for r in stride(from: 1, through: rows, by: 1) { rowTop[r] = rowTop[r - 1] + Self.cardH + gapH[r] }
        func top(_ row: Int) -> CGFloat { rowTop[row] }
        func height(_ row: Int, _ span: Int) -> CGFloat { rowTop[row + span - 1] + Self.cardH - rowTop[row] }

        // Ports: outgoing on the right side, incoming on the left (a link within a column on the
        // right at both ends), spread evenly, ordered by the other end's height.
        let mid = { (id: String) in top(place[id]!.row) + height(place[id]!.row, place[id]!.span) / 2 }
        var portLists: [String: [(Int, Bool, String)]] = [:]   // "o"/"i" + id → (pair, outgoing, other)
        for (i, p) in pairs.enumerated() {
            let same = place[p.from]!.col == place[p.to]!.col
            portLists["o" + p.from, default: []].append((i, true, p.to))
            portLists[(same ? "o" : "i") + p.to, default: []].append((i, false, p.from))
        }
        var sy = [CGFloat](repeating: 0, count: pairs.count), ty = sy
        for (key, list) in portLists {
            let id = String(key.dropFirst()), y0 = top(place[id]!.row), h = height(place[id]!.row, place[id]!.span)
            for (k, port) in list.sorted(by: { (mid($0.2), $0.0) < (mid($1.2), $1.0) }).enumerated() {
                let y = y0 + (h * CGFloat(k + 1) / CGFloat(list.count + 1)).rounded()
                if port.1 { sy[port.0] = y } else { ty[port.0] = y }
            }
        }

        // Lanes: corridor k lies left of physical column k; a link takes one right of its source
        // and, unless that is the same corridor, one left of its target.
        var lanes = [[Int]](repeating: [], count: nc + 1)
        for (i, p) in pairs.enumerated() {
            let (a, b) = (place[p.from]!.col, place[p.to]!.col)
            lanes[a + 1].append(i)
            if b != a && b != a + 1 { lanes[b].append(i) }
        }
        for k in lanes.indices { lanes[k].sort { (sy[$0], ty[$0], $0) < (sy[$1], ty[$1], $1) } }
        let cw = lanes.map { max(40, up8(CGFloat($0.count) * Self.lane + 24)) }
        var colX: [CGFloat] = [], x = cw[0]
        for c in 0..<nc { colX.append(x); x += Self.cardW + cw[c + 1] }
        func laneX(_ k: Int, _ i: Int) -> CGFloat {
            let n = lanes[k].count, j = lanes[k].firstIndex(of: i)!
            return (k == 0 ? 0 : colX[k - 1] + Self.cardW) + cw[k] / 2 + (CGFloat(j) - CGFloat(n - 1) / 2) * Self.lane
        }
        let gridBottom = (rows > 0 ? rowTop[rows - 1] + Self.cardH : Self.titleH) + 16
        var back = 0
        let gapTracks = Dictionary(grouping: gapOf.keys.sorted { (sy[$0], $0) < (sy[$1], $1) }, by: { gapOf[$0]! })
        for (i, p) in pairs.enumerated() {
            let (a, b) = (place[p.from]!.col, place[p.to]!.col)
            let sx = colX[a] + Self.cardW, tx = colX[b], x1 = laneX(a + 1, i)
            let pts: [CGPoint]
            if b == a {
                pts = [CGPoint(x: sx, y: sy[i]), CGPoint(x: x1, y: sy[i]), CGPoint(x: x1, y: ty[i]), CGPoint(x: sx, y: ty[i])]
            } else if b == a + 1 {
                pts = [CGPoint(x: sx, y: sy[i]), CGPoint(x: x1, y: sy[i]), CGPoint(x: x1, y: ty[i]), CGPoint(x: tx, y: ty[i])]
            } else {
                let y: CGFloat
                if b < a {
                    y = gridBottom + CGFloat(back) * Self.lane; back += 1
                } else {
                    let g = gapOf[i]!, list = gapTracks[g]!, k = list.firstIndex(of: i)!
                    y = top(g) - gapH[g] / 2 + (CGFloat(k) - CGFloat(list.count - 1) / 2) * Self.lane
                }
                let x2 = laneX(b, i)
                pts = [CGPoint(x: sx, y: sy[i]), CGPoint(x: x1, y: sy[i]), CGPoint(x: x1, y: y), CGPoint(x: x2, y: y), CGPoint(x: x2, y: ty[i]), CGPoint(x: tx, y: ty[i])]
            }
            edges.append(Edge(pair: p, points: pts))
        }

        for (id, pl) in place {
            cards[id] = Card(service: pl.service, rect: CGRect(x: colX[pl.col], y: top(pl.row), width: Self.cardW, height: height(pl.row, pl.span)), stub: pl.stub)
        }
        heads = headPlaces.map { Head(project: $0.project, count: $0.count, rect: CGRect(x: colX[$0.col], y: top($0.row), width: Self.cardW, height: Self.cardH)) }
        for (li, (_, title)) in logical.enumerated() where !physOf[li].isEmpty {
            let n = items[li].filter { if case .card = $0 { true } else { false } }.count
            titles.append(Title(text: title, count: n, x0: colX[physOf[li].first!], x1: colX[physOf[li].last!] + Self.cardW))
        }
        size = CGSize(width: x, height: gridBottom + CGFloat(back) * Self.lane + 8)
    }
}

// MARK: - Space: variant B, frames

/// Projects as frames with their services as rows (1 column, 2 above 7), sub-projects as frames
/// inside their parent's; frames on a grid placed so heavy pairs sit close; lines run in 120-pt
/// corridors between frames: zoomed out one bundle per pair of top projects with its count,
/// zoomed in every service → service link.
struct SpaceFrames {
    static let chipW: CGFloat = 228, chipH: CGFloat = 22, rowGap: CGFloat = 6, colGap: CGFloat = 14, pad: CGFloat = 14, head: CGFloat = 46, gap: CGFloat = 120
    static let subHead: CGFloat = 30

    /// A sub-project's frame inside a top frame.
    struct Sub { var project: String; var rect: CGRect }
    struct Frame { var project: String; var title: String; var rect: CGRect; var services: [Service]; var inner: Int; var subs: [Sub] = []; var c = 0; var r = 0; var cols = 1 }
    struct Line { var pair: ServiceMap.Pair; var points: [CGPoint] }
    struct Bundle { var a: String; var b: String; var count: Int; var ends: Set<String>; var points: [CGPoint]; var badge: CGPoint }

    var frames: [Frame] = []
    var chips: [String: CGRect] = [:]
    var lines: [Line] = []
    var bundles: [Bundle] = []
    var size = CGSize.zero

    init(space: String, catalogue c: Catalogue, pairs all: [ServiceMap.Pair]) {
        let byID = Dictionary(c.services.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let mine = Set(c.services.filter { $0.space == space }.map(\.id))
        let pairs = all.filter { mine.contains($0.from) || mine.contains($0.to) }
        // Services of other spaces this one links with join as frames of their own projects.
        let shown = mine.union(pairs.flatMap { [$0.from, $0.to] })
        let byProject = Dictionary(grouping: shown.compactMap { byID[$0] }, by: \.project)
        let parentOf = Dictionary(c.projects.map { ($0.id, $0.parent) }, uniquingKeysWith: { a, _ in a })
        let children = Dictionary(grouping: c.projects.filter { $0.parent != nil }, by: { $0.parent! }).mapValues { $0.map(\.id).sorted() }
        func root(_ p: String) -> String { var p = p, seen: Set<String> = [p]; while let q = parentOf[p] ?? nil, seen.insert(q).inserted { p = q }; return p }
        func hasShown(_ p: String) -> Bool { byProject[p] != nil || (children[p] ?? []).contains(where: hasShown) }
        // Frames are the top projects; a link inside one (parent ↔ child) is inner.
        let projectOf = { (id: String) in root(byID[id]!.project) }
        let services = { (p: String) in (byProject[p] ?? []).sorted { (kindOrder($0), $0.id) < (kindOrder($1), $1.id) } }
        var weight: [String: [String: Int]] = [:]
        for p in pairs where projectOf(p.from) != projectOf(p.to) {
            weight[projectOf(p.from), default: [:]][projectOf(p.to), default: 0] += p.links.count
            weight[projectOf(p.to), default: [:]][projectOf(p.from), default: 0] += p.links.count
        }
        let pw = { (a: String, b: String) in weight[a]?[b] ?? 0 }
        let total = { (a: String) in weight[a]?.values.reduce(0, +) ?? 0 }
        let roots = Set(byProject.keys.map(root))
        func count(_ p: String) -> Int { (byProject[p]?.count ?? 0) + (children[p] ?? []).reduce(0) { $0 + count($1) } }
        func spaceOf(_ p: String) -> String? { byProject[p]?.first?.space ?? (children[p] ?? []).lazy.compactMap(spaceOf).first }
        let foreign = { (p: String) in spaceOf(p).map { $0 != space } ?? false }
        let ids = roots.sorted { (foreign($0) ? 1 : 0, -count($0), $0) < (foreign($1) ? 1 : 0, -count($1), $1) }

        // Width a project needs at a nesting depth: its rows or its widest sub-project, plus padding.
        func need(_ p: String, _ d: Int) -> CGFloat {
            let cols: CGFloat = (byProject[p]?.count ?? 0) > 7 ? 2 : 1
            return (children[p] ?? []).filter(hasShown).reduce(Self.pad * 2 * CGFloat(d + 1) + cols * Self.chipW + (cols - 1) * Self.colGap) { max($0, need($1, d + 1)) }
        }
        var rel: [String: CGRect] = [:], chipCol: [String: Int] = [:], subs: [Sub] = []
        // Rows of `p` from `y` at `x`, then its sub-projects framed below; returns the bottom.
        func lay(_ p: String, x: CGFloat, y: CGFloat, w: CGFloat) -> CGFloat {
            let ss = services(p), cols = ss.count > 7 ? 2 : 1, rows = (ss.count + cols - 1) / cols
            // One column of rows spans the frame, so a line meets the row at the frame's padding.
            let cw = cols == 1 ? w - Self.pad * 2 : Self.chipW
            for (k, s) in ss.enumerated() {
                let (ic, ir) = (k / rows, k % rows)
                rel[s.id] = CGRect(x: x + Self.pad + CGFloat(ic) * (Self.chipW + Self.colGap), y: y + CGFloat(ir) * (Self.chipH + Self.rowGap), width: cw, height: Self.chipH)
                chipCol[s.id] = cols == 2 ? ic : -1
            }
            var bottom = rows > 0 ? y + CGFloat(rows) * (Self.chipH + Self.rowGap) - Self.rowGap : y - Self.rowGap * 2
            for ch in (children[p] ?? []) where hasShown(ch) {
                let top = bottom + Self.rowGap * 2, x0 = x + Self.pad
                let end = lay(ch, x: x0, y: top + Self.subHead, w: w - Self.pad * 2)
                subs.append(Sub(project: ch, rect: CGRect(x: x0, y: top, width: w - Self.pad * 2, height: end + Self.pad * 0.75 - top)))
                bottom = end + Self.pad * 0.75
            }
            return bottom
        }
        var relOf: [Int: ([String: CGRect], [Sub])] = [:]
        frames = ids.enumerated().map { i, p in
            rel = [:]; subs = []
            let w = need(p, 0), h = lay(p, x: 0, y: Self.head, w: w) + Self.pad
            relOf[i] = (rel, subs)
            let ss = rel.keys.compactMap { byID[$0] }.sorted { ($0.project, kindOrder($0), $0.id) < ($1.project, kindOrder($1), $1.id) }
            let inner = pairs.filter { projectOf($0.from) == p && projectOf($0.to) == p }.reduce(0) { $0 + $1.links.count }
            let title = foreign(p) ? "\(spaceOf(p) ?? "") / \(p)" : p
            return Frame(project: p, title: title, rect: CGRect(x: 0, y: 0, width: w, height: h), services: ss, inner: inner,
                         cols: (byProject[p]?.count ?? 0) > 7 ? 2 : 1)
        }

        // Heaviest first; each next into the free slot nearest, by weight, to those placed.
        let gridCols = max(1, Int(Double(frames.count * 2).squareRoot().rounded(.up))), gridRows = (frames.count + gridCols - 1) / gridCols
        let slots = (0..<gridRows).flatMap { r in (0..<gridCols).map { (c: $0, r: r) } }
        var used = Set<Int>()
        let order = frames.indices.sorted { (-total(frames[$0].project), $0) < (-total(frames[$1].project), $1) }
        for (k, f) in order.enumerated() {
            let placed = order.prefix(k)
            let best = slots.indices.filter { !used.contains($0) }.min { a, b in
                func cost(_ s: Int) -> Double {
                    if k == 0 { return abs(Double(slots[s].c) - Double(gridCols - 1) / 2) + Double(slots[s].r) }
                    return placed.reduce(0.0) { t, o in t + Double(pw(frames[f].project, frames[o].project)) * Double(abs(slots[s].c - frames[o].c) + abs(slots[s].r - frames[o].r)) }
                }
                return (cost(a), a) < (cost(b), b)
            }!
            used.insert(best); frames[f].c = slots[best].c; frames[f].r = slots[best].r
        }
        let colW = (0..<gridCols).map { c in frames.filter { $0.c == c }.map(\.rect.width).max() ?? 0 }
        let rowH = (0..<gridRows).map { r in frames.filter { $0.r == r }.map(\.rect.height).max() ?? 0 }
        var colX = [Self.gap], rowY = [Self.gap]
        for w in colW { colX.append(colX.last! + w + Self.gap) }
        for h in rowH { rowY.append(rowY.last! + h + Self.gap) }
        let vx = { (v: Int) in colX[v] - Self.gap / 2 }, hy = { (h: Int) in rowY[h] - Self.gap / 2 }
        var frameOf: [String: Int] = [:]
        for i in frames.indices {
            let o = CGPoint(x: colX[frames[i].c], y: rowY[frames[i].r])
            frames[i].rect.origin = o
            let (r, ss) = relOf[i]!
            for (id, rect) in r { chips[id] = rect.offsetBy(dx: o.x, dy: o.y); frameOf[id] = i }
            frames[i].subs = ss.map { Sub(project: $0.project, rect: $0.rect.offsetBy(dx: o.x, dy: o.y)) }
        }

        // An end: its x and y, the vertical corridor it enters (v) and its row of frames.
        struct End { var x: CGFloat; var y: CGFloat; var v: Int; var r: Int }
        func end(_ id: String, toward other: String) -> End {
            let f = frames[frameOf[id]!], chip = chips[id]!
            let right = chipCol[id]! >= 0 ? chipCol[id] == 1 : frames[frameOf[other]!].c >= f.c
            return End(x: right ? chip.maxX : chip.minX, y: chip.midY, v: f.c + (right ? 1 : 0), r: f.r)
        }
        var sideCount: [String: Int] = [:]
        func frameEnd(_ i: Int, toward o: Int) -> End {
            let f = frames[i], right = frames[o].c >= f.c, key = "\(i)\(right)"
            let k = sideCount[key, default: 0]; sideCount[key] = k + 1
            return End(x: right ? f.rect.maxX : f.rect.minX, y: f.rect.minY + 60 + CGFloat(k) * 18, v: f.c + (right ? 1 : 0), r: f.r)
        }
        // Two passes: count the lanes of each corridor, then spread them across it.
        func route(_ ends: [(s: End, t: End)], step: CGFloat) -> [[CGPoint]] {
            func keys(_ s: End, _ t: End) -> [String] {
                if s.v == t.v { return ["v\(s.v)"] }
                let h = s.r == t.r ? (s.r == 0 ? 0 : s.r + 1) : max(s.r, t.r)
                return ["v\(s.v)", "h\(h)", "v\(t.v)"]
            }
            var counts: [String: Int] = [:], index: [String: Int] = [:]
            for e in ends { for k in keys(e.s, e.t) { counts[k, default: 0] += 1 } }
            func offset(_ k: String) -> CGFloat {
                let i = index[k, default: -1] + 1, n = counts[k]!
                index[k] = i
                return (CGFloat(i) - CGFloat(n - 1) / 2) * min(step, (Self.gap - 24) / CGFloat(n))
            }
            return ends.map { s, t in
                let ks = keys(s, t), o = ks.map(offset)
                if ks.count == 1 {
                    let x = vx(s.v) + o[0]
                    return [CGPoint(x: s.x, y: s.y), CGPoint(x: x, y: s.y), CGPoint(x: x, y: t.y), CGPoint(x: t.x, y: t.y)]
                }
                let xs = vx(s.v) + o[0], y = hy(Int(ks[1].dropFirst())!) + o[1], xt = vx(t.v) + o[2]
                return [CGPoint(x: s.x, y: s.y), CGPoint(x: xs, y: s.y), CGPoint(x: xs, y: y), CGPoint(x: xt, y: y), CGPoint(x: xt, y: t.y), CGPoint(x: t.x, y: t.y)]
            }
        }
        let near = pairs.map { (pair: $0, s: end($0.from, toward: $0.to), t: end($0.to, toward: $0.from)) }
            .sorted { ($0.s.y, $0.t.y, $0.pair.from, $0.pair.to) < ($1.s.y, $1.t.y, $1.pair.from, $1.pair.to) }
        lines = zip(near, route(near.map { ($0.s, $0.t) }, step: 4)).map { Line(pair: $0.pair, points: $1) }

        var groups: [[Int]: (count: Int, ends: Set<String>)] = [:]
        for p in pairs {
            let (a, b) = (frameOf[p.from]!, frameOf[p.to]!)
            guard a != b else { continue }
            let key = [min(a, b), max(a, b)]
            groups[key, default: (0, [])].count += p.links.count
            groups[key]!.ends.formUnion([p.from, p.to])
        }
        let keys = groups.keys.sorted { $0.lexicographicallyPrecedes($1) }
        let ends = keys.map { (s: frameEnd($0[0], toward: $0[1]), t: frameEnd($0[1], toward: $0[0])) }
        let routes = route(ends, step: 14)
        // Badges on the middle segment, moved along it until none touches another.
        var badges: [CGPoint] = []
        for (k, key) in keys.enumerated() {
            let pts = routes[k], m = (pts.count - 1) / 2, (p1, p2) = (pts[m], pts[m + 1])
            let candidates = [0.5, 0.3, 0.7, 0.2, 0.8, 0.4, 0.6, 0.1, 0.9].map { CGPoint(x: p1.x + (p2.x - p1.x) * $0, y: p1.y + (p2.y - p1.y) * $0) }
            let badge = candidates.first { c in badges.allSatisfy { hypot($0.x - c.x, $0.y - c.y) >= 30 } } ?? candidates[0]
            badges.append(badge)
            bundles.append(Bundle(a: frames[key[0]].project, b: frames[key[1]].project, count: groups[key]!.count, ends: groups[key]!.ends, points: pts, badge: badge))
        }
        size = CGSize(width: colX.last!, height: rowY.last!)   // corridors outside the frames stay inside the canvas
    }
}

// MARK: - Space: variant A, flow

/// Columns by role, left to right along the data: devices, ingest, bus, processing, storage,
/// API, fronts, external; «Обработка» split into sub-columns of at most 14 rows, whole projects
/// packed into them under a project label, so it does not become a poster. Ops services are left
/// out. Threads are curves left to right.
struct SpaceFlow {
    static let chipW: CGFloat = 228, chipH: CGFloat = 22, row: CGFloat = 30, gap: CGFloat = 110, budget = 14

    struct Column { var title: String; var count: Int; var x: CGFloat; var top: CGFloat; var heads: [(project: String, y: CGFloat)] }
    var columns: [Column] = []
    var chips: [String: CGRect] = [:]
    var lines: [(pair: ServiceMap.Pair, from: CGRect, to: CGRect)] = []
    var hidden = 0
    var size = CGSize.zero

    static let titles = ["Устройства", "Приём", "Шина", "Обработка", "Хранение", "API / BFF", "Фронты", "Внешнее"]

    static func column(_ s: Service, _ role: Service.Role) -> Int? {
        switch role {
        case .device: 0
        case .ingest: 1
        case .infra: ServiceMap.isBus(s) ? 2 : 4
        case .processing, .worker, .relay: 3
        case .bff, .backend: 5
        case .front: 6
        case .external: 7
        case .ops: nil
        }
    }

    init(space: String, catalogue c: Catalogue, pairs all: [ServiceMap.Pair], roles: [String: Service.Role]) {
        let byID = Dictionary(c.services.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let mine = Set(c.services.filter { $0.space == space }.map(\.id))
        let pairs = all.filter { mine.contains($0.from) || mine.contains($0.to) }
        let shown = mine.union(pairs.flatMap { [$0.from, $0.to] }).compactMap { byID[$0] }
        // Another space's service is external here, whatever it is at home.
        let col = { (s: Service) -> Int? in s.space != space ? 7 : Self.column(s, roles[s.id] ?? .worker) }
        hidden = shown.filter { col($0) == nil }.count
        // Physical columns: one per role column; «Обработка» packs project groups (a label row each).
        var phys: [(logical: Int, services: [Service], heads: [(String, Int)])] = []
        var processing = Set<Int>()
        for l in Self.titles.indices {
            let ss = shown.filter { col($0) == l }.sorted { ($0.project, $0.id) < ($1.project, $1.id) }
            guard !ss.isEmpty else { continue }
            guard l == 3 else { phys.append((l, ss, [])); continue }
            var current: (services: [Service], heads: [(String, Int)]) = ([], [])
            for (project, list) in Dictionary(grouping: ss, by: \.project).sorted(by: { ($0.value.count, $1.key) > ($1.value.count, $0.key) }) {
                for chunk in stride(from: 0, to: list.count, by: Self.budget - 1) {
                    let part = Array(list[chunk..<min(chunk + Self.budget - 1, list.count)])
                    if !current.services.isEmpty && current.services.count + current.heads.count + part.count + 1 > Self.budget {
                        processing.insert(phys.count); phys.append((l, current.services, current.heads)); current = ([], [])
                    }
                    current.heads.append((project, current.services.count + current.heads.count))
                    current.services += part
                }
            }
            processing.insert(phys.count); phys.append((l, current.services, current.heads))
        }
        var cols = phys.map(\.services)
        // Processing sub-columns keep their project groups; the rest follow the threads.
        barycentre(&cols, adj: adjacency(pairs), sweeps: 12, centred: true, fixed: processing)
        let rows = phys.map { $0.services.count + $0.heads.count }
        let tallest = CGFloat(rows.max() ?? 0)
        var x: CGFloat = 0
        for (k, list) in cols.enumerated() {
            let top = (tallest - CGFloat(rows[k])) / 2 * Self.row + 44
            var row = 0, heads: [(project: String, y: CGFloat)] = []
            for s in list {
                if let h = phys[k].heads.first(where: { $0.1 == row }) { heads.append((h.0, top + CGFloat(row) * Self.row)); row += 1 }
                chips[s.id] = CGRect(x: x, y: top + CGFloat(row) * Self.row, width: Self.chipW, height: Self.chipH)
                row += 1
            }
            let l = phys[k].logical, first = k == 0 || phys[k - 1].logical != l
            columns.append(Column(title: first ? Self.titles[l] : "", count: first ? phys.filter { $0.logical == l }.reduce(0) { $0 + $1.services.count } : 0,
                                  x: x, top: top, heads: heads))
            x += Self.chipW + (k + 1 < phys.count && phys[k + 1].logical == l ? Self.gap / 2 : Self.gap)
        }
        lines = pairs.compactMap { p in chips[p.from].flatMap { a in chips[p.to].map { (p, a, $0) } } }
        size = CGSize(width: max(0, x - Self.gap + 40), height: tallest * Self.row + 60)
    }
}

// MARK: - Service: the thread

/// The service in the middle, where its data comes from to the left (nearest first) and where it
/// goes to the right, a column per step; a broker crossed gets a narrow column of its own between
/// two steps. Compact: fixed gaps, not the window's width. Each column is split into «данные»
/// (reached through a topic or a db, and brokers) on top and «вызовы» (other links) below, the
/// split shared across columns. Cards are keyed by `ServiceMap.Thread.Node.key`.
struct ThreadLayout {
    static let chipW: CGFloat = 196, chipH: CGFloat = 24, row: CGFloat = 40, gap: CGFloat = 110, brokerGap: CGFloat = 130, brokerW: CGFloat = 92
    static let centre = CGSize(width: 236, height: 48)
    /// Column titles at the top, the bands below them; a band's label sits over its first card.
    static let titleY: CGFloat = 8, bandTop: CGFloat = 56, bandGap: CGFloat = 32

    var chips: [String: CGRect] = [:]
    var brokers: Set<String> = []
    /// Each card's column, left to right.
    var column: [String: Int] = [:]
    var columns: [(title: String, x: CGFloat)] = []
    var groups: [(title: String, x: CGFloat, y: CGFloat)] = []
    /// The gap right of each column's x, for the topic labels on its lines.
    var gapAfter: [CGFloat: CGFloat] = [:]
    var size = CGSize.zero

    init(_ thread: ServiceMap.Thread, centre: Service) {
        let centreNode = ServiceMap.Thread.Node(key: centre.id, service: centre, broker: false)
        let steps = thread.columns.map(\.step).filter { $0 < 0 } + [0] + thread.columns.map(\.step).filter { $0 > 0 }
        var cols = thread.columns.filter { $0.step < 0 }.map(\.nodes) + [[centreNode]] + thread.columns.filter { $0.step > 0 }.map(\.nodes)
        // barycentre works on services; a broker's key stands in for its id.
        var keyed = cols.map { $0.map { n -> Service in var s = n.service; s.id = n.key; return s } }
        barycentre(&keyed, adj: adjacency(thread.pairs), sweeps: 8, centred: true)
        let byKey = Dictionary(cols.flatMap { $0 }.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        cols = keyed.map { $0.map { byKey[$0.id]! } }
        brokers = Set(byKey.values.filter(\.broker).map(\.key))
        var stepOf: [String: Int] = [:]
        for (k, list) in cols.enumerated() { for n in list { stepOf[n.key] = steps[k]; column[n.key] = k } }

        // Data or call: by the links toward the centre (a node with none counts as data).
        func isData(_ n: ServiceMap.Thread.Node, _ d: Int) -> Bool {
            if n.broker { return true }
            let inner = thread.pairs.filter { d < 0 ? $0.from == n.key && stepOf[$0.to]! > d : $0.to == n.key && stepOf[$0.from]! < d }
            return inner.isEmpty || inner.contains { p in
                brokers.contains(d < 0 ? p.to : p.from) || p.links.contains { ["topic", "db"].contains($0.via ?? "") }
            }
        }
        let split = cols.enumerated().map { k, list in
            steps[k] == 0 ? (data: list, calls: []) : (data: list.filter { isData($0, steps[k]) }, calls: list.filter { !isData($0, steps[k]) })
        }
        let labelled = split.contains { !$0.calls.isEmpty }
        let hd = CGFloat(split.map(\.data.count).max() ?? 0), hc = CGFloat(split.map(\.calls.count).max() ?? 0)
        let callsTop = Self.bandTop + hd * Self.row + (hd > 0 && hc > 0 ? Self.bandGap : 0)
        let bottom = callsTop + hc * Self.row
        var x: CGFloat = 0
        for (k, list) in split.enumerated() {
            let d = steps[k], broker = d % 2 != 0
            let gap = k + 1 < steps.count && (broker || steps[k + 1] % 2 != 0) ? Self.brokerGap : Self.gap
            if d == 0 {
                chips[centre.id] = CGRect(x: x, y: ((Self.bandTop + bottom - Self.row + Self.chipH) / 2 - Self.centre.height / 2).rounded(),
                                          width: Self.centre.width, height: Self.centre.height)
                columns.append(("", x)); gapAfter[x] = gap
                x += Self.centre.width + gap
                continue
            }
            let w = broker ? Self.brokerW : Self.chipW
            for (band, nodes, h, top) in [("данные", list.data, hd, Self.bandTop), ("вызовы", list.calls, hc, callsTop)] where !nodes.isEmpty {
                let y0 = top + ((h - CGFloat(nodes.count)) / 2).rounded(.down) * Self.row
                for (i, n) in nodes.enumerated() { chips[n.key] = CGRect(x: x, y: y0 + CGFloat(i) * Self.row, width: w, height: Self.chipH) }
                if labelled && !broker { groups.append((band, x, y0 - 18)) }
            }
            let title = broker ? "" : d == -2 ? "Откуда приходит" : d == 2 ? "Куда уходит" : ru(abs(d) / 2, "шаг", "шага", "шагов") + (d < 0 ? " вверх" : " вниз")
            columns.append((title, x)); gapAfter[x] = gap
            x += w + gap
        }
        size = CGSize(width: max(x - Self.gap, 1), height: max(bottom, chips[centre.id]!.maxY) + 24)
    }
}
