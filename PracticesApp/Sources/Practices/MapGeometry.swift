import SwiftUI
import AppKit

/// A line on the map; `tip` gets a 6 pt arrow pointing away from `back`.
struct MapLine {
    var path: Path
    var tip: CGPoint?
    var back: CGPoint = .zero
    var color: Color
    var width: CGFloat
    var opacity: Double = 0.85
    var dashed = false
}

enum MapGeometry {
    /// Straight segments through `points` with corners rounded to `radius`.
    static func rounded(_ points: [CGPoint], radius: CGFloat = 6) -> Path {
        var path = Path()
        path.move(to: points[0])
        for i in points.indices.dropFirst().dropLast() {
            let (p, c, n) = (points[i - 1], points[i], points[i + 1])
            let r = min(radius, hypot(c.x - p.x, c.y - p.y) / 2, hypot(n.x - c.x, n.y - c.y) / 2)
            if r < 0.01 { path.addLine(to: c); continue }
            path.addArc(tangent1End: c, tangent2End: n, radius: r)
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    /// A left-to-right thread between two chips: a cubic curve from the right side of `a` to the
    /// left side of `b` (reversed when `b` lies to the left); a loop on the right within a column.
    static func thread(_ a: CGRect, _ b: CGRect) -> (path: Path, tip: CGPoint, back: CGPoint) {
        var path = Path()
        if abs(a.minX - b.minX) < 1 {
            let (s, t) = (CGPoint(x: a.maxX, y: a.midY), CGPoint(x: b.maxX + 1, y: b.midY))
            let dx = 30 + abs(t.y - s.y) * 0.25
            let c2 = CGPoint(x: t.x + dx, y: t.y)
            path.move(to: s); path.addCurve(to: t, control1: CGPoint(x: s.x + dx, y: s.y), control2: c2)
            return (path, t, c2)
        }
        let forward = a.midX < b.midX
        let s = CGPoint(x: forward ? a.maxX : a.minX, y: a.midY), t = CGPoint(x: forward ? b.minX : b.maxX, y: b.midY)
        let c2 = CGPoint(x: (s.x + t.x) / 2, y: t.y)
        path.move(to: s); path.addCurve(to: t, control1: CGPoint(x: (s.x + t.x) / 2, y: s.y), control2: c2)
        return (path, t, c2)
    }

    /// Width by the number of links a line stands for.
    static func width(_ count: Int) -> CGFloat { min(1.2 + log2(CGFloat(max(count, 1))) * 1.3, 4) }
}

/// The map's lines in one canvas; arrows 6 pt.
struct MapLines: View {
    let lines: [MapLine]
    var body: some View {
        Canvas { ctx, _ in
            for l in lines {
                let color = l.color.opacity(l.opacity)
                ctx.stroke(l.path, with: .color(color), style: StrokeStyle(lineWidth: l.width, lineCap: .round, lineJoin: .round, dash: l.dashed ? [4, 3] : []))
                guard let tip = l.tip else { continue }
                let (dx, dy) = (tip.x - l.back.x, tip.y - l.back.y), len = max(hypot(dx, dy), 0.001)
                let (ux, uy) = (dx / len, dy / len)
                var arrow = Path()
                arrow.move(to: tip)
                arrow.addLine(to: CGPoint(x: tip.x - ux * 6 - uy * 3, y: tip.y - uy * 6 + ux * 3))
                arrow.addLine(to: CGPoint(x: tip.x - ux * 6 + uy * 3, y: tip.y - uy * 6 - ux * 3))
                arrow.closeSubpath()
                ctx.fill(arrow, with: .color(color))
            }
        }
        .allowsHitTesting(false)
    }
}

/// Zoom and pan for every level (DECISIONS 2): pinch, a mouse wheel or ⌘-scroll zoom around the
/// pointer (0.4×–4×), a trackpad scroll or a drag pans, a double click fits, a click on the
/// empty map unpins. `key` names what is shown: a new one fits the content again.
struct ZoomPan<Content: View, Overlay: View>: View {
    let state: MapState
    let key: String
    let size: CGSize
    var minimum: CGFloat = 0.4
    /// A content point kept in the middle when the content does not fit.
    var anchor: CGPoint? = nil
    @ViewBuilder var content: Content
    /// Drawn over the map in view coordinates (edge markers, the legend).
    @ViewBuilder var overlay: Overlay
    @State private var dragFrom: CGSize?

    var body: some View {
        GeometryReader { geo in
            content
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .scaleEffect(state.scale, anchor: .topLeading)
                .offset(state.pan)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .background(Theme.Color.windowBg.onTapGesture {
                    if (NSApp.currentEvent?.clickCount ?? 1) >= 2 { state.fit(minimum: minimum, anchor: anchor) } else { state.pinned = nil }
                })
                .overlay { overlay.allowsHitTesting(false) }
                .clipped()
                .contentShape(Rectangle())
                .background(EventCatcher { event, p in handle(event, at: p) })
                .simultaneousGesture(DragGesture(minimumDistance: 4)
                    .onChanged { v in
                        let from = dragFrom ?? state.pan
                        dragFrom = from
                        state.pan = CGSize(width: from.width + v.translation.width, height: from.height + v.translation.height)
                    }
                    .onEnded { _ in dragFrom = nil })
                .onAppear { place(geo.size, force: state.fitted != key) }
                .onChange(of: geo.size) { _, s in state.viewSize = s }
                .onChange(of: key) { place(geo.size, force: true) }
                .onChange(of: size) { place(geo.size, force: true) }
        }
    }

    private func place(_ view: CGSize, force: Bool) {
        state.viewSize = view
        state.contentSize = size
        guard force else { return }
        state.fitted = key
        state.fit(minimum: minimum, anchor: anchor)
    }

    private func handle(_ e: NSEvent, at p: CGPoint) {
        if e.type == .magnify { state.zoom(to: state.scale * (1 + e.magnification), around: p); return }
        if e.hasPreciseScrollingDeltas && !e.modifierFlags.contains(.command) {
            state.pan = CGSize(width: state.pan.width + e.scrollingDeltaX, height: state.pan.height + e.scrollingDeltaY)
        } else {
            let delta = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY * 0.01 : e.scrollingDeltaY * 0.1
            state.zoom(to: state.scale * exp(delta), around: p)
        }
    }
}

extension ZoomPan where Overlay == EmptyView {
    init(state: MapState, key: String, size: CGSize, minimum: CGFloat = 0.4, @ViewBuilder content: () -> Content) {
        self.init(state: state, key: key, size: size, minimum: minimum, content: content, overlay: { EmptyView() })
    }
}

/// Scroll and pinch events over the view it backs, through a local monitor: SwiftUI on macOS
/// has no scroll-wheel or zoom-around-a-point gesture, and a view on top would take the clicks.
private struct EventCatcher: NSViewRepresentable {
    let handler: (NSEvent, CGPoint) -> Void

    func makeNSView(context: Context) -> CatcherView { CatcherView() }
    func updateNSView(_ view: CatcherView, context: Context) { view.handler = handler }

    final class CatcherView: NSView {
        var handler: ((NSEvent, CGPoint) -> Void)?
        private var monitor: Any?
        override var isFlipped: Bool { true }

        override func viewDidMoveToWindow() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
                // Local monitors run on the main thread; NSEvent is not Sendable, so it crosses unchecked.
                nonisolated(unsafe) let e = event
                let used = MainActor.assumeIsolated { () -> Bool in
                    guard let self, e.window === self.window else { return false }
                    let p = self.convert(e.locationInWindow, from: nil)
                    guard self.bounds.contains(p), let handler = self.handler else { return false }
                    handler(e, p)
                    return true
                }
                return used ? nil : event
            }
        }
    }
}
