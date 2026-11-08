import SwiftUI
import AppKit

/// Back and forward at the toolbar's leading edge, as in Safari and Finder.
struct NavigationButtons: View {
    @Environment(RegistryModel.self) private var registry

    var body: some View {
        HStack(spacing: 2) {
            button("chevron.left", "Назад", enabled: registry.history.canGoBack) { registry.goBack() }
            button("chevron.right", "Вперёд", enabled: registry.history.canGoForward) { registry.goForward() }
        }
        .background(NavigationEvents(registry: registry))
    }

    private func button(_ symbol: String, _ help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14, weight: .medium))
                .foregroundStyle(enabled ? Theme.Color.textSecondary : Theme.Color.textMuted.opacity(0.5))
                .frame(width: 26, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(Text(verbatim: help))
    }
}

/// The arrow at the window's edge while a two-finger swipe goes back or forward.
struct SwipeArrow: View {
    @Environment(RegistryModel.self) private var registry

    var body: some View {
        let amount = registry.swipe
        if amount != 0 {
            Image(systemName: amount > 0 ? "chevron.left" : "chevron.right")
                .font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.Color.text)
                .frame(width: 40, height: 40)
                .background(Theme.Color.buttonBg.opacity(0.9), in: Circle())
                .overlay(Circle().strokeBorder(Theme.Color.border))
                .opacity(min(1, abs(amount) * 1.5))
                .offset(x: (abs(amount) - 1) * 40 * (amount > 0 ? 1 : -1))
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: amount > 0 ? .leading : .trailing)
                .allowsHitTesting(false)
        }
    }
}

/// ⌘[ ⌘], ⌘← ⌘→ outside text, the mouse's back and forward buttons, and a horizontal swipe — two fingers
/// (scroll events, «Swipe between pages») or three (swipe events) — through a local monitor.
private struct NavigationEvents: NSViewRepresentable {
    let registry: RegistryModel

    func makeNSView(context: Context) -> MonitorView { MonitorView() }
    func updateNSView(_ view: MonitorView, context: Context) { view.registry = registry }

    final class MonitorView: NSView {
        var registry: RegistryModel?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .otherMouseDown, .swipe, .scrollWheel]) { [weak self] event in
                // Local monitors run on the main thread; NSEvent is not Sendable, so it crosses unchecked.
                nonisolated(unsafe) let e = event
                let used = MainActor.assumeIsolated { self?.handle(e) ?? false }
                return used ? nil : event
            }
        }

        private func handle(_ e: NSEvent) -> Bool {
            guard let registry, let window, e.window === window else { return false }
            switch e.type {
            case .keyDown:
                // Key codes, not characters: ⌘[ ⌘] are the same keys on a Russian layout (х ъ).
                guard e.modifierFlags.intersection([.command, .shift, .option, .control]) == .command else { return false }
                let inText = window.firstResponder is NSText
                if e.keyCode == 33 || (e.keyCode == 123 && !inText) { registry.goBack(); return true }
                if e.keyCode == 30 || (e.keyCode == 124 && !inText) { registry.goForward(); return true }
                return false
            case .otherMouseDown:
                if e.buttonNumber == 3 { registry.goBack(); return true }
                if e.buttonNumber == 4 { registry.goForward(); return true }
                return false
            case .swipe:
                if e.deltaX > 0 { registry.goBack(); return true }
                if e.deltaX < 0 { registry.goForward(); return true }
                return false
            case .scrollWheel:
                return trackSwipe(e, registry: registry)
            default:
                return false
            }
        }

        /// A horizontal two-finger scroll that starts over a view not scrolling sideways itself.
        private func trackSwipe(_ e: NSEvent, registry: RegistryModel) -> Bool {
            guard e.phase == .began, NSEvent.isSwipeTrackingFromScrollEventsEnabled,
                  abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY),
                  registry.history.canGoBack || registry.history.canGoForward,
                  !pansSideways(at: e.locationInWindow) else { return false }
            let (back, forward) = (registry.history.canGoBack, registry.history.canGoForward)
            e.trackSwipeEvent(options: [.lockDirection, .clampGestureAmount],
                              dampenAmountThresholdMin: forward ? -1 : 0, max: back ? 1 : 0) { amount, phase, complete, _ in
                MainActor.assumeIsolated {
                    registry.swipe = complete ? 0 : amount
                    // Positive: the fingers moved right, the page behind comes in from the left.
                    if phase == .ended, amount != 0 { amount > 0 ? registry.goBack() : registry.goForward() }
                }
            }
            return true
        }

        /// The map's canvas (it pans on a scroll) or a scroll view wider than its window, under the point.
        private func pansSideways(at point: NSPoint) -> Bool {
            guard let root = window?.contentView else { return false }
            func search(_ view: NSView) -> Bool {
                guard !view.isHidden, view.bounds.contains(view.convert(point, from: nil)) else { return false }
                if view is PansSideways { return true }
                if let scroll = view as? NSScrollView, let doc = scroll.documentView,
                   doc.frame.width > scroll.contentView.bounds.width + 1 { return true }
                return view.subviews.contains(where: search)
            }
            return search(root)
        }
    }
}

/// A view that takes horizontal scrolls itself (the map's canvas): no swipe starts over it.
protocol PansSideways: NSView {}
