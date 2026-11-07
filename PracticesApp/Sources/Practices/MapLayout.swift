import SwiftUI
import PracticesCore

/// Geometry of the three map levels (`design/Map*.dc.html`): explicit rectangles, so the views
/// only place cards and draw lines between them. Coordinates are inside the content, without
/// its 20pt padding.

/// A line on the map; `tip` gets a 7×7 arrow pointing away from `back`.
struct MapLine {
    var path: Path
    var tip: CGPoint?
    var back: CGPoint = .zero
    var color: Color
    var width: CGFloat
    var opacity: Double
}

enum MapGeometry {
    /// A cubic curve from a card's right middle to the target's left middle (left to right when
    /// the target lies to the left); two cards of one column are joined by a loop on the right.
    static func curve(_ a: CGRect, _ b: CGRect) -> (path: Path, tip: CGPoint, back: CGPoint) {
        let start: CGPoint, tip: CGPoint, c1: CGPoint, c2: CGPoint
        if abs(a.minX - b.minX) < 1 {
            start = CGPoint(x: a.maxX, y: a.midY); tip = CGPoint(x: b.maxX, y: b.midY)
            c1 = CGPoint(x: a.maxX + 40, y: a.midY); c2 = CGPoint(x: b.maxX + 40, y: b.midY)
        } else {
            let forward = a.midX < b.midX
            start = CGPoint(x: forward ? a.maxX : a.minX, y: a.midY); tip = CGPoint(x: forward ? b.minX : b.maxX, y: b.midY)
            let mx = (start.x + tip.x) / 2
            c1 = CGPoint(x: mx, y: start.y); c2 = CGPoint(x: mx, y: tip.y)
        }
        var path = Path()
        path.move(to: start)
        path.addCurve(to: tip, control1: c1, control2: c2)
        return (path, tip, c2)
    }

    /// A link's line: by `via`, a write to a database warn and thicker; along `route` when given.
    static func line(_ a: CGRect, _ b: CGRect, links: [PracticesCore.Link], width: CGFloat = 1.4, route: [CGPoint]? = nil) -> MapLine {
        var (path, tip, back) = curve(a, b)
        if let route, route.count > 1 { path = rounded(route); tip = route[route.count - 1]; back = route[route.count - 2] }
        if let w = links.first(where: { $0.via == "db" && $0.access == "write" }) {
            return MapLine(path: path, tip: tip, back: back, color: Theme.viaColor(w.via, access: w.access), width: 1.8, opacity: 0.9)
        }
        return MapLine(path: path, tip: tip, back: back, color: Theme.viaColor(links.first?.via), width: width, opacity: 0.75)
    }

    /// Straight segments through `points` with corners rounded to `radius`.
    static func rounded(_ points: [CGPoint], radius: CGFloat = 4) -> Path {
        var path = Path()
        path.move(to: points[0])
        for i in points.indices.dropFirst().dropLast() {
            let (p, c, n) = (points[i - 1], points[i], points[i + 1])
            let r = min(radius, hypot(c.x - p.x, c.y - p.y) / 2, hypot(n.x - c.x, n.y - c.y) / 2)
            path.addArc(tangent1End: c, tangent2End: n, radius: r)
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    /// Orthogonal routes (design «Линии на карте»): out of the source's right side (left when the
    /// target lies wholly to its left), into the target's side facing the line; segments only on
    /// lines through the middle of the gaps between `obstacles`, so no line crosses a card. Ends
    /// sharing a card side are spread 7 apart; each route gets a lane a few points off the middle.
    static func routes(_ ends: [(from: CGRect, to: CGRect)], obstacles: [CGRect], bounds: CGRect) -> [[CGPoint]] {
        // Stubs 2i and 2i+1: the start and the end of route i; side +1 is the right edge, -1 the left.
        var stubs: [(rect: CGRect, side: CGFloat, other: CGFloat)] = []
        for (a, b) in ends {
            let out: CGFloat = b.maxX < a.minX ? -1 : 1
            stubs.append((a, out, b.midY))
            stubs.append((b, out > 0 && b.minX > a.maxX ? -1 : 1, a.midY))
        }
        let ys = stubs.indices.map { i -> CGFloat in
            let s = stubs[i]
            let group = stubs.indices.filter { stubs[$0].rect == s.rect && stubs[$0].side == s.side }
            let k = group.filter { (stubs[$0].other, $0) < (s.other, i) }.count
            let step = min(7, max(s.rect.height - 16, 0) / CGFloat(max(group.count - 1, 1)))
            return s.rect.midY + (CGFloat(k) - CGFloat(group.count - 1) / 2) * step
        }
        let inflated = obstacles.map { $0.insetBy(dx: -3, dy: -3) }
        return ends.indices.map { i in
            let (s, e) = (stubs[2 * i], stubs[2 * i + 1])
            return route(CGPoint(x: s.side > 0 ? s.rect.maxX : s.rect.minX, y: ys[2 * i]), out: s.side > 0 ? 0 : 1,
                         CGPoint(x: e.side > 0 ? e.rect.maxX : e.rect.minX, y: ys[2 * i + 1]), into: e.side > 0 ? 1 : 0,
                         obstacles: inflated, bounds: bounds, lane: i)
        }
    }

    /// Dijkstra on the sparse grid of gap lines, a bend costing 24pt; `out`/`into` are the first and
    /// the last move (0 = +x, 1 = −x).
    private static func route(_ s: CGPoint, out: Int, _ t: CGPoint, into: Int, obstacles: [CGRect], bounds: CGRect, lane: Int) -> [CGPoint] {
        let shift = CGFloat(lane % 7 - 3) * 3
        func lines(_ edges: [CGFloat], _ ends: [CGFloat]) -> [CGFloat] {
            let e = Set(edges).sorted()
            var lines = Set(ends)
            for (lo, hi) in zip(e, e.dropFirst()) where hi - lo >= 4 {
                let half = (hi - lo) / 2 - 1.5
                lines.insert((lo + hi) / 2 + max(-half, min(half, shift)))
            }
            return lines.sorted()
        }
        let xs = lines(obstacles.flatMap { [$0.minX, $0.maxX] } + [bounds.minX, bounds.maxX], [s.x, t.x])
        let ys = lines(obstacles.flatMap { [$0.minY, $0.maxY] } + [bounds.minY, bounds.maxY], [s.y, t.y])
        let (nx, ny) = (xs.count, ys.count)
        // The cards an end sits in do not block the segment leaving or entering it.
        let atS = obstacles.filter { $0.contains(s) }, atT = obstacles.filter { $0.contains(t) }
        func free(_ p: CGPoint, _ q: CGPoint) -> Bool {
            obstacles.allSatisfy { r in
                if (p == s || q == s) && atS.contains(r) || (p == t || q == t) && atT.contains(r) { return true }
                return !(max(p.x, q.x) > r.minX && min(p.x, q.x) < r.maxX && max(p.y, q.y) > r.minY && min(p.y, q.y) < r.maxY)
            }
        }
        func point(_ n: Int) -> CGPoint { CGPoint(x: xs[n / ny], y: ys[n % ny]) }
        // freeX[n]: node n to its +x neighbour; freeY[n]: to its +y neighbour.
        let freeX = (0..<nx * ny).map { $0 / ny + 1 < nx && free(point($0), point($0 + ny)) }
        let freeY = (0..<nx * ny).map { $0 % ny + 1 < ny && free(point($0), point($0 + 1)) }
        let start = (xs.firstIndex(of: s.x)! * ny + ys.firstIndex(of: s.y)!) * 4 + out
        let goal = (xs.firstIndex(of: t.x)! * ny + ys.firstIndex(of: t.y)!) * 4 + into
        var dist = [CGFloat](repeating: .infinity, count: nx * ny * 4), prev = [Int](repeating: -1, count: nx * ny * 4)
        var heap: [(CGFloat, Int)] = [(0, start)]
        dist[start] = 0
        while !heap.isEmpty {
            let (d, state) = heap[0]
            let last = heap.removeLast()
            if !heap.isEmpty {
                heap[0] = last
                var i = 0
                while true {
                    var m = i
                    for c in [2 * i + 1, 2 * i + 2] where c < heap.count && heap[c].0 < heap[m].0 { m = c }
                    if m == i { break }
                    heap.swapAt(i, m); i = m
                }
            }
            if state == goal { break }
            guard d <= dist[state] else { continue }
            let (node, dir) = (state / 4, state % 4)
            for nd in 0..<4 where nd != dir ^ 1 && (state != start || nd == out) {
                let next: Int
                switch nd {
                case 0: guard freeX[node] else { continue }; next = node + ny
                case 1: guard node >= ny, freeX[node - ny] else { continue }; next = node - ny
                case 2: guard freeY[node] else { continue }; next = node + 1
                default: guard node % ny > 0, freeY[node - 1] else { continue }; next = node - 1
                }
                let (p, q) = (point(node), point(next))
                let cost = d + abs(q.x - p.x) + abs(q.y - p.y) + (nd == dir ? 0 : 24)
                let ns = next * 4 + nd
                guard cost < dist[ns] else { continue }
                dist[ns] = cost; prev[ns] = state
                heap.append((cost, ns))
                var i = heap.count - 1
                while i > 0, heap[(i - 1) / 2].0 > heap[i].0 { heap.swapAt(i, (i - 1) / 2); i = (i - 1) / 2 }
            }
        }
        guard dist[goal] < .infinity else { return [s, CGPoint(x: (s.x + t.x) / 2, y: s.y), CGPoint(x: (s.x + t.x) / 2, y: t.y), t] }
        var states = [goal]
        while let p = states.last.map({ prev[$0] }), p >= 0 { states.append(p) }
        // Keep the corners only: a state whose direction differs from the next one's.
        let path = states.reversed().map { $0 }
        var points = [s]
        for (a, b) in zip(path, path.dropFirst()) where a % 4 != b % 4 && a != start { points.append(point(a / 4)) }
        points.append(t)
        return points
    }
}

/// Level 1: top-level projects with children as dashed frames (their cards inside, three to a
/// row), standalone projects as cards; frames and cards wrap in rows 20 apart.
struct SpaceLayout {
    static let card = CGSize(width: 170, height: 64)
    var cards: [(project: Project, rect: CGRect)] = []
    var frames: [(project: Project, rect: CGRect, services: Int)] = []
    var size = CGSize.zero

    init(_ map: ServiceMap.SpaceMap, services: [Service], width: CGFloat) {
        // The tree is a preorder: a top-level project, then everything under it.
        var groups: [[Project]] = []
        for (p, depth) in map.projects {
            if depth == 0 || groups.isEmpty { groups.append([p]) } else { groups[groups.count - 1].append(p) }
        }
        let withServices = Set(services.map(\.project))
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for group in groups {
            let framed = group.count > 1
            // shortcut: projects nested deeper than one level are cards of the top frame, not frames in frames.
            let inner = framed && !withServices.contains(group[0].id) ? Array(group.dropFirst()) : group
            let cols = CGFloat(min(inner.count, 3)), rows = CGFloat((inner.count + 2) / 3)
            let w = framed ? 24 + cols * 170 + (cols - 1) * 10 : 170
            let h = framed ? 32 + rows * 64 + (rows - 1) * 10 + 12 : 64
            if x > 0 && x + w > width { x = 0; y += rowHeight + 20; rowHeight = 0 }
            if framed {
                let ids = Set(group.map(\.id))
                frames.append((group[0], CGRect(x: x, y: y, width: w, height: h), services.filter { ids.contains($0.project) }.count))
            }
            for (i, p) in inner.enumerated() {
                let origin = framed ? CGPoint(x: x + 12 + CGFloat(i % 3) * 180, y: y + 32 + CGFloat(i / 3) * 74) : CGPoint(x: x, y: y)
                cards.append((p, CGRect(origin: origin, size: Self.card)))
            }
            x += w + 20
            rowHeight = max(rowHeight, h)
            size.width = max(size.width, x - 20)
        }
        size.height = y + rowHeight
    }

    /// What lines go around: the cards and the frame labels (mono 12, about 7.3 a character).
    var obstacles: [CGRect] {
        cards.map(\.rect) + frames.map { f in
            CGRect(x: f.rect.minX + 10, y: f.rect.minY + 6, width: CGFloat("\(f.project.id) · \(f.services)".count) * 7.3 + 4, height: 18)
        }
    }
}

/// Level 2: columns 220 wide at x = 10 / 280 / 550 (empty ones dropped, the rest move left),
/// the externals column 188 wide 22 after the last; cards from y 76, 108 apart (design).
struct ProjectLayout {
    var columns: [(column: ServiceMap.Column, x: CGFloat, services: [Service])] = []
    /// Own service cards and external rows, by service id: the ends of the lines.
    var rects: [String: CGRect] = [:]
    var externals: [(project: Project, services: [Service], rect: CGRect)] = []
    var externalX: CGFloat = 10
    var boxHeight: CGFloat = 500
    var size = CGSize.zero

    init(_ map: ServiceMap.ProjectMap) {
        var x: CGFloat = 10, bottom: CGFloat = 76
        for column in ServiceMap.Column.allCases {
            guard let services = map.own[column], !services.isEmpty else { continue }
            columns.append((column, x, services))
            for (i, s) in services.enumerated() { rects[s.id] = CGRect(x: x + 10, y: 76 + CGFloat(i) * 108, width: 200, height: 92) }
            bottom = max(bottom, 76 + CGFloat(services.count) * 108 - 16)
            x += 270
        }
        externalX = columns.isEmpty ? 10 : x - 270 + 242
        var y: CGFloat = 76
        for e in map.externals {
            // padding 8, header 16 + 2, rows 22 with gap 2, padding 8
            let h = 8 + 18 + CGFloat(e.services.count) * 24 + 8
            externals.append((e.project, e.services, CGRect(x: externalX + 10, y: y, width: 170, height: h)))
            for (i, s) in e.services.enumerated() { rects[s.id] = CGRect(x: externalX + 10, y: y + 28 + CGFloat(i) * 24, width: 170, height: 22) }
            y += h + 8
        }
        boxHeight = max(500, max(bottom, y - 8) + 16 - 44)
        let width = map.externals.isEmpty ? externalX - 22 : externalX + 188
        size = CGSize(width: max(width, 560), height: 44 + boxHeight)
    }

    /// What lines go around: each column's header and cards as one block (no line across a column
    /// between its cards), external cards and the legend; free stay the corridor above the headers
    /// (y 19–41), the gaps between columns and the space below a column's last card.
    var obstacles: [CGRect] {
        columns.map { c in c.services.compactMap { rects[$0.id] }.reduce(CGRect(x: c.x, y: 44, width: 220, height: 26)) { $0.union($1) } }
            + externals.map(\.rect) + (externals.isEmpty ? [] : [CGRect(x: externalX, y: 44, width: 188, height: 26)])
            + [CGRect(x: 0, y: 0, width: size.width, height: 16)]
    }
}

/// Level 3: callers 210×64 at x 20 from y 76, 72 apart; the centre 260×120 at x 440, level with
/// the middle of the taller column; callees at x 790.
struct ServiceLayout {
    var callers: [CGRect] = []
    var callees: [CGRect] = []
    var centre = CGRect.zero
    var size = CGSize.zero

    init(callers: Int, callees: Int) {
        let column = CGFloat(max(callers, callees, 1)) * 72 - 8
        centre = CGRect(x: 440, y: 76 + max(0, (column - 120) / 2), width: 260, height: 120)
        self.callers = (0..<callers).map { CGRect(x: 20, y: 76 + CGFloat($0) * 72, width: 210, height: 64) }
        self.callees = (0..<callees).map { CGRect(x: 790, y: 76 + CGFloat($0) * 72, width: 210, height: 64) }
        size = CGSize(width: 1000, height: max(76 + column, centre.maxY) + 20)
    }
}
