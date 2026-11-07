import SwiftUI

/// The design's one template for empty screens and failures (`design/States.dc.html`): a 36×36
/// glyph on a tint of its colour, a title, one line of what to do, an optional mono line, buttons.
/// `alert` paints the title, the mono line and the frame in the error colour.
struct EmptyState<Actions: View>: View {
    let glyph: String
    let tint: Color
    let title: String
    let text: String
    var code: String? = nil
    var alert = false
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 6) {
            Text(verbatim: glyph).font(Theme.mono(18, .semibold)).foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(tint.opacity(0x1F / 255), in: RoundedRectangle(cornerRadius: 10))
            Text(verbatim: title).font(Theme.ui(13, .semibold)).foregroundStyle(alert ? Theme.Color.error : Theme.Color.text)
            Text(verbatim: text).font(Theme.ui(12)).foregroundStyle(Theme.Color.textSecondary)
                .multilineTextAlignment(.center).lineSpacing(3).frame(maxWidth: 320)
            if let code {
                Text(verbatim: code).font(Theme.mono(11)).foregroundStyle(alert ? Theme.Color.error : Theme.Color.textMuted)
                    .multilineTextAlignment(.center).frame(maxWidth: 340).padding(.top, 4).textSelection(.enabled)
            }
            HStack(spacing: 6) { actions() }.padding(.top, 6)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Color.cardBg, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(alert ? Theme.Color.error.opacity(0.45) : Theme.Color.borderCard))
    }
}

extension EmptyState where Actions == EmptyView {
    init(glyph: String, tint: Color, title: String, text: String, code: String? = nil, alert: Bool = false) {
        self.init(glyph: glyph, tint: tint, title: title, text: text, code: code, alert: alert) { EmptyView() }
    }
}

/// A 26 px button of an empty state: accent for the main action, plain otherwise.
struct StateButton: View {
    let title: String
    var prominent = false
    let action: () -> Void
    init(_ title: String, prominent: Bool = false, action: @escaping () -> Void) {
        self.title = title; self.prominent = prominent; self.action = action
    }
    var body: some View {
        Button(action: action) { Text(verbatim: title) }.buttonStyle(CompactButtonStyle(prominent: prominent, fontSize: 12))
    }
}
