import SwiftUI
import PracticesCore

/// Where the map is: the level, what it shows, the camera and the pinned service. Kept by the
/// registry, so «Карта» returns to the last place.
@MainActor @Observable
final class MapState {
    enum Level: Hashable { case space, project, service }
    /// The space level's two pictures (DECISIONS 4): project frames, or columns by role.
    enum SpaceMode: Hashable { case frames, flow }

    var level = Level.space
    var space = ""
    var project: String?
    var service: String?
    var spaceMode = SpaceMode.frames
    /// How far the service level follows the thread up and down.
    var hops = 1
    var catalogue = Catalogue(projects: [], services: [], links: []) {
        didSet {
            roles = ServiceMap.roles(in: catalogue)
            pairs = ServiceMap.pairs(in: catalogue)
            memo = [:]
            // Each space's projects, biggest first, take the palette in turn.
            var colors: [String: Color] = [:]
            for (_, ps) in Dictionary(grouping: catalogue.projects, by: \.space) {
                let count = { (p: Project) in self.catalogue.services.filter { $0.project == p.id }.count }
                for (i, p) in ps.sorted(by: { (count($1), $0.id) < (count($0), $1.id) }).enumerated() { colors[p.id] = Self.palette[i % Self.palette.count] }
            }
            projectColors = colors
        }
    }
    private(set) var roles: [String: Service.Role] = [:]
    private(set) var pairs: [ServiceMap.Pair] = []
    private(set) var projectColors: [String: Color] = [:]
    static let palette: [Color] = [0xA78BFA, 0xFB923C, 0x22D3EE, 0xA3E635, 0xF472B6, 0xFACC15, 0x60A5FA, 0x34D399].map { Color(hex: $0) }
    func color(ofProject id: String) -> Color { projectColors[id] ?? ZonePalette.standalone }

    /// Layouts by what they show, so a zoom or a hover does not lay the map out again.
    @ObservationIgnored private var memo: [String: Any] = [:]
    func cached<T>(_ key: String, _ make: () -> T) -> T {
        if let v = memo[key] as? T { return v }
        let v = make()
        memo[key] = v
        return v
    }

    /// The card under the pointer and the one clicked: its links on top, the rest dimmed; the
    /// pinned one also opens the side panel.
    var hover: String?
    var pinned: String?
    var focused: String? { pinned ?? hover }

    // MARK: Camera

    /// Content point p is drawn at `p * scale + pan` in the map's view.
    var scale: CGFloat = 1
    var pan = CGSize.zero
    var viewSize = CGSize.zero
    /// What the camera was fitted for, and the content's size then; a new key fits again.
    var fitted: String?
    var contentSize = CGSize.zero
    /// `--zoom k` of a Debug render: applied after the fit, around the centre.
    var renderZoom: CGFloat?
    static let zoomRange: ClosedRange<CGFloat> = 0.4...4

    /// The whole content in view, centred, between `minimum` and 1×; past the minimum it is
    /// aligned to the top left, where the first columns are, or centred on `anchor` (the thread's service).
    func fit(minimum: CGFloat = 0.4, anchor: CGPoint? = nil) {
        guard contentSize.width > 0, viewSize.width > 0 else { return }
        let pad: CGFloat = 32
        let k = min(1, max(minimum, min((viewSize.width - 2 * pad) / contentSize.width, (viewSize.height - 2 * pad) / contentSize.height)))
        scale = k
        pan = CGSize(width: max(pad, (viewSize.width - contentSize.width * k) / 2), height: max(pad, (viewSize.height - contentSize.height * k) / 2))
        if let a = anchor, contentSize.width * k > viewSize.width - 2 * pad { pan.width = viewSize.width / 2 - a.x * k }
        if let a = anchor, contentSize.height * k > viewSize.height - 2 * pad { pan.height = viewSize.height / 2 - a.y * k }
        if let z = renderZoom { zoom(to: k * z, around: CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)) }
    }

    /// Scale to `k` keeping the content point under `p` (a point of the view) where it is.
    func zoom(to k: CGFloat, around p: CGPoint) {
        let k = min(Self.zoomRange.upperBound, max(Self.zoomRange.lowerBound, k))
        pan = CGSize(width: p.x - (p.x - pan.width) * k / scale, height: p.y - (p.y - pan.height) * k / scale)
        scale = k
    }

    /// Where a content point is in the view.
    func onScreen(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * scale + pan.width, y: p.y * scale + pan.height) }

    // MARK: Navigation

    func lookup(_ id: String) -> Service? { catalogue.services.first { $0.id == id } }
    func role(of id: String) -> Service.Role? { roles[id] }

    func show(space id: String) {
        space = id; level = .space; pinned = nil; hover = nil
    }

    func open(project id: String) {
        project = id
        space = catalogue.projects.first { $0.id == id }?.space ?? space
        level = .project; pinned = nil; hover = nil
    }

    func focus(_ id: String) {
        service = id
        if let s = lookup(id) { project = s.project; space = s.space }
        level = .service; pinned = nil; hover = nil
    }

    /// Click on a card: pin it (the side panel), or unpin it.
    func pin(_ id: String?) { pinned = pinned == id ? nil : id }
}
