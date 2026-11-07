import SwiftUI
import PracticesCore

/// The design's tokens (`design/tokens.md`): one theme, dark. Views use these, not system colours.
enum Theme {
    enum Color {
        // Surfaces
        static let windowBg = SwiftUI.Color(hex: 0x1C1C1E)
        static let sidebarBg = SwiftUI.Color(hex: 0x262629)
        static let toolbarBg = SwiftUI.Color(hex: 0x222225)
        static let cardBg = SwiftUI.Color(hex: 0x26262A)
        static let codeBg = SwiftUI.Color(hex: 0x161618)
        static let gutterBg = SwiftUI.Color(hex: 0x19191B)
        static let buttonBg = SwiftUI.Color(hex: 0x2C2C30)
        static let border = SwiftUI.Color(hex: 0x3A3A3F)
        static let borderCard = SwiftUI.Color(hex: 0x38383D)
        static let borderButton = SwiftUI.Color(hex: 0x45454B)
        static let borderSoft = SwiftUI.Color(hex: 0x2A2A2E)
        static let overlay = SwiftUI.Color.black.opacity(0.55)
        // Text
        static let text = SwiftUI.Color(hex: 0xF2F2F4)
        static let textCode = SwiftUI.Color(hex: 0xE6E6EA)
        static let textSecondary = SwiftUI.Color(hex: 0xA6A6AE)
        static let textMuted = SwiftUI.Color(hex: 0x8A8A92)
        static let textDisabled = SwiftUI.Color(hex: 0x6E6E76)
        static let textGutter = SwiftUI.Color(hex: 0x5C5C64)
        static let textChip = SwiftUI.Color(hex: 0xC9C9D0)
        static let link = SwiftUI.Color(hex: 0x6CB2FF)
        static let linkHover = SwiftUI.Color(hex: 0x9CCBFF)
        // Accent and states
        static let accent = SwiftUI.Color(hex: 0x0A84FF)
        static let accentSelection = SwiftUI.Color(hex: 0x0A84FF, alpha: 0.22)
        static let ok = SwiftUI.Color(hex: 0x4ED27A)
        static let warn = SwiftUI.Color(hex: 0xFFB04A)
        static let error = SwiftUI.Color(hex: 0xFF6B6B)
    }

    /// `font.ui`: SF Pro at the design's pixel size.
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }
    /// `font.mono`: SF Mono — ids, paths, code, kv-blocks.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .monospaced) }

    /// Link colour on the map by `via`; a write to a database is warn.
    static func viaColor(_ via: String?, access: String? = nil) -> SwiftUI.Color {
        switch via {
        case "http": SwiftUI.Color(hex: 0x5AA9FF)
        case "topic": SwiftUI.Color(hex: 0xFFB04A)
        case "db": access == "write" ? Color.warn : SwiftUI.Color(hex: 0x4ED27A)
        case "build": SwiftUI.Color(hex: 0xB48CFF)
        default: SwiftUI.Color(hex: 0x9A9AA3)
        }
    }
}

extension SwiftUI.Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }
}

/// The colour code of a service, the same everywhere: dots, badges, composition bars, the map.
enum ServiceClass: String, CaseIterable, Sendable {
    case front, api, data, bus, hw, ext, worker, other

    var hex: UInt32 {
        switch self {
        case .front: 0x4FD1D9
        case .api: 0x5AA9FF
        case .data: 0x4ED27A
        case .bus: 0xFFB04A
        case .hw: 0xE8C547
        case .ext: 0xFF7AA2
        case .worker: 0xB48CFF
        case .other: 0x9A9AA3
        }
    }
    var color: Color { Color(hex: hex) }
    /// Badge background: the colour at 0.16.
    var rgbBadgeBackground: Color { Color(hex: hex, alpha: 0.16) }

    /// tokens.md «Что попадает». Front by name is checked before `http`: frontends are `kind: http`
    /// in the cards, and the design shows them as front.
    init(for service: Service) {
        let kind = service.kind.lowercased()
        let words = Set((service.id + "-" + service.name).lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        func any(_ names: [String]) -> Bool { names.contains { kind.contains($0) } }
        if service.tags.contains("external") { self = .ext }
        else if words.contains(where: { $0.hasPrefix("front") }) || words.contains("web") || words.contains("ui") { self = .front }
        else if kind == "http" { self = .api }
        else if any(["postgres", "clickhouse", "redis", "mysql", "sqlite", "s3", "influx"]) { self = .data }
        else if any(["kafka", "rabbit", "mq", "nats"]) { self = .bus }
        else if any(["firmware", "socket"]) { self = .hw }
        else if any(["worker", "tool", "script", "monitor"]) { self = .worker }
        else { self = .other }
    }
}

/// Zones: top-level projects that hold other projects, coloured in tree order; `external` pink,
/// a standalone project grey.
enum ZonePalette {
    static let colors = [Color(hex: 0xB48CFF), Color(hex: 0x5AA9FF), Color(hex: 0xFFB04A)]
    static let external = Color(hex: 0xFF7AA2)
    static let standalone = Color(hex: 0x9A9AA3)
}

extension RegistryModel {
    /// The zone colour of a project: that of its top-level ancestor.
    func zoneColor(of projectID: String) -> Color {
        guard let top = path(of: projectID).first else { return ZonePalette.standalone }
        let services = services.filter { $0.project == top.id }
        if top.id.contains("external") || (!services.isEmpty && services.allSatisfy { ServiceClass(for: $0) == .ext }) {
            return ZonePalette.external
        }
        let groups = topProjects.filter { $0.space == top.space && childProjects[$0.id] != nil }
        guard let i = groups.firstIndex(of: top) else { return ZonePalette.standalone }
        return ZonePalette.colors[i % ZonePalette.colors.count]
    }
}

/// Russian plural: 1 проект, 2 проекта, 5 проектов.
func ru(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
    let (d10, d100) = (n % 10, n % 100)
    let word = d10 == 1 && d100 != 11 ? one : (2...4).contains(d10) && !(12...14).contains(d100) ? few : many
    return "\(n) \(word)"
}

// MARK: - Small views

/// Section title: 11/600, uppercase, letter-spacing 0.04em, muted (or a zone colour).
struct SectionTitle: View {
    let text: String
    var color = Theme.Color.textMuted
    init(_ text: String, color: Color = Theme.Color.textMuted) { self.text = text; self.color = color }
    var body: some View {
        Text(verbatim: text).textCase(.uppercase).font(Theme.ui(11, .semibold)).tracking(0.44).foregroundStyle(color)
    }
}

/// Kind badge: mono 10.5, padding 1 6, radius 4, the class colour on its 0.16 background.
struct KindBadge: View {
    let kind: ServiceClass
    init(_ kind: ServiceClass) { self.kind = kind }
    var body: some View {
        Text(verbatim: kind.rawValue).font(Theme.mono(10.5)).foregroundStyle(kind.color)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(kind.rgbBadgeBackground, in: RoundedRectangle(cornerRadius: 4))
            .fixedSize()
    }
}

/// Chip («→ name», project): mono 10, padding 0 6, radius 3, 1px border in its colour.
struct Chip: View {
    let text: String
    var color = Theme.Color.textChip
    var mono = true
    init(_ text: String, color: Color = Theme.Color.textChip) { self.text = text; self.color = color }
    /// The old call sites (ServiceView, SpaceView).
    init(text: String, mono: Bool = false, tint: Color? = nil) { self.text = text; self.mono = mono; self.color = tint ?? Theme.Color.textChip }
    var body: some View {
        Text(verbatim: text).font(mono ? Theme.mono(10) : Theme.ui(10)).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(color, lineWidth: 1))
            .fixedSize()
    }
}

/// Card section: padding 12 14, radius 10, card background and border, uppercase header.
struct SectionCard<Content: View>: View {
    let title: String
    var spacing: CGFloat = 8
    @ViewBuilder let content: () -> Content
    init(_ title: String, spacing: CGFloat = 8, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.spacing = spacing; self.content = content
    }
    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            SectionTitle(title)
            content()
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Color.cardBg, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.Color.borderCard))
    }
}

/// kv-block: code background, radius 8, columns 90 / rest, mono 12, line-height 1.5.
/// `KVBlock { KVRow("id", "x-keeper"); KVRow("parent") { Text(…) } }`
struct KVBlock<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 5) { content() }
            .font(Theme.mono(12)).foregroundStyle(Theme.Color.text)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Color.codeBg, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.Color.borderCard))
    }
}

struct KVRow<Value: View>: View {
    let key: String
    @ViewBuilder let value: () -> Value
    init(_ key: String, @ViewBuilder value: @escaping () -> Value) { self.key = key; self.value = value }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(verbatim: key).foregroundStyle(Theme.Color.textMuted).frame(width: 90, alignment: .leading)
            value().frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 18)
    }
}

extension KVRow where Value == Text {
    init(_ key: String, _ value: String) { self.init(key) { Text(verbatim: value) } }
}

/// Composition bar: height 4, segments flex by count, gap 2, radius 2; grey when empty.
struct CompositionBar: View {
    let parts: [(ServiceClass, Int)]
    init(_ parts: [(ServiceClass, Int)]) { self.parts = parts.filter { $0.1 > 0 } }
    var body: some View {
        GeometryReader { geo in
            let total = parts.reduce(0) { $0 + $1.1 }
            let room = geo.size.width - CGFloat(max(parts.count - 1, 0)) * 2
            HStack(spacing: 2) {
                if total == 0 { RoundedRectangle(cornerRadius: 2).fill(Theme.Color.borderCard) }
                ForEach(parts.indices, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2).fill(parts[i].0.color)
                        .frame(width: room * CGFloat(parts[i].1) / CGFloat(total))
                }
            }
        }
        .frame(height: 4)
    }
}

/// Stat tile: number mono 22/600, label 11 secondary; padding 10 14, radius 8.
struct StatTile: View {
    let n: String
    let label: String
    var color = Theme.Color.text
    init(_ n: String, _ label: String, color: Color = Theme.Color.text) { self.n = n; self.label = label; self.color = color }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: n).font(Theme.mono(22, .semibold)).foregroundStyle(color)
            Text(verbatim: label).font(Theme.ui(11)).foregroundStyle(Theme.Color.textSecondary).lineLimit(1)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Color.cardBg, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.Color.borderCard))
    }
}

/// Button: height 28, padding 0 12, radius 6; plain or accent. The shell applies it to every
/// button in the toolbar's trailing slot.
struct ToolbarButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(GapLabelStyle())
            .font(Theme.ui(13))
            .foregroundStyle(!enabled ? Theme.Color.textDisabled : prominent ? .white : Theme.Color.text)
            .padding(.horizontal, 12).frame(height: 28)
            .background(!enabled ? Theme.Color.cardBg : prominent ? Theme.Color.accent : Theme.Color.buttonBg,
                        in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(!enabled ? Theme.Color.borderCard : prominent ? Theme.Color.accent : Theme.Color.borderButton))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Rectangle())
    }
}

/// Icon and title with the design's 6pt gap, icon 14pt.
struct GapLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) { configuration.icon.font(.system(size: 12, weight: .medium)); configuration.title }
    }
}

struct ToolbarButton: View {
    let title: String
    var systemImage: String?
    var prominent = false
    let action: () -> Void
    init(_ title: String, systemImage: String? = nil, prominent: Bool = false, action: @escaping () -> Void) {
        self.title = title; self.systemImage = systemImage; self.prominent = prominent; self.action = action
    }
    var body: some View {
        Button(action: action) {
            if let systemImage { Label { Text(verbatim: title) } icon: { Image(systemName: systemImage) } } else { Text(verbatim: title) }
        }
        .buttonStyle(ToolbarButtonStyle(prominent: prominent))
    }
}

/// One part of the breadcrumb: a link (`link` colour unless a zone or kind colour is given).
struct Crumb {
    var label: String
    var color: Color? = nil
    var action: (() -> Void)? = nil
}

/// Toolbar title: `~/.practices/spaces/` + **x-keeper**, or `space / project / ` + **id**.
struct Breadcrumb: View {
    var prefix: String? = nil
    var crumbs: [Crumb] = []
    let title: String
    var monoTitle = true

    var body: some View {
        HStack(spacing: 6) {
            if let prefix {
                Text(verbatim: prefix).font(Theme.mono(12)).foregroundStyle(Theme.Color.textMuted).padding(.trailing, 4)
            }
            ForEach(crumbs.indices, id: \.self) { i in
                Button { crumbs[i].action?() } label: {
                    Text(verbatim: crumbs[i].label).font(Theme.mono(12)).foregroundStyle(crumbs[i].color ?? Theme.Color.link)
                }
                .buttonStyle(.plain)
                Text(verbatim: "/").font(Theme.mono(12)).foregroundStyle(Theme.Color.textMuted)
            }
            Text(verbatim: title).font(monoTitle ? Theme.mono(15, .semibold) : Theme.ui(15, .semibold))
                .foregroundStyle(Theme.Color.text)
        }
        .lineLimit(1)
    }
}

/// Status bar: 24 high, mono 11 muted, items 14 apart, the hint on the right.
struct StatusBar: View {
    let items: [String]
    var trailing = "⌘K — перейти"
    var body: some View {
        HStack(spacing: 14) {
            ForEach(items.indices, id: \.self) { Text(verbatim: items[$0]).lineLimit(1).truncationMode(.head) }
            Spacer(minLength: 0)
            Text(verbatim: trailing)
        }
        .font(Theme.mono(11)).foregroundStyle(Theme.Color.textMuted)
        .padding(.horizontal, 12).frame(height: 24)
        .background(Theme.Color.toolbarBg)
        .overlay(alignment: .top) { Theme.Color.border.frame(height: 1) }
    }
}

// MARK: - Toolbar slots

/// What a screen puts in the shell's toolbar: its own title instead of the breadcrumb, and its buttons.
struct ShellToolbar {
    var leading: AnyView?
    var trailing: AnyView?
}

struct ShellToolbarKey: PreferenceKey {
    static var defaultValue: ShellToolbar { ShellToolbar() }
    static func reduce(value: inout ShellToolbar, nextValue: () -> ShellToolbar) {
        let next = nextValue()
        value.leading = next.leading ?? value.leading
        value.trailing = next.trailing ?? value.trailing
    }
}

extension View {
    /// Buttons on the right of the toolbar; styled as `ToolbarButtonStyle` by the shell.
    func toolbarTrailing<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        let view = AnyView(content())
        return transformPreference(ShellToolbarKey.self) { $0.trailing = view }
    }
    /// Replaces the shell's breadcrumb (a title with a subtitle or a badge after it).
    func toolbarLeading<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        let view = AnyView(content())
        return transformPreference(ShellToolbarKey.self) { $0.leading = view }
    }
}
