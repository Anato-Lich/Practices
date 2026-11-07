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

    /// A link's line: by `via`, a write to a database warn and thicker.
    static func line(_ a: CGRect, _ b: CGRect, links: [PracticesCore.Link], width: CGFloat = 1.4) -> MapLine {
        let (path, tip, back) = curve(a, b)
        if let w = links.first(where: { $0.via == "db" && $0.access == "write" }) {
            return MapLine(path: path, tip: tip, back: back, color: Theme.viaColor(w.via, access: w.access), width: 1.8, opacity: 0.9)
        }
        return MapLine(path: path, tip: tip, back: back, color: Theme.viaColor(links.first?.via), width: width, opacity: 0.75)
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
