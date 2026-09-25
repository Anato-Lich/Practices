#if DEBUG
import SwiftUI
import AppKit

/// `Practices --render-popover out.png`: takes one real snapshot, renders the popover
/// offscreen and exits. Lets the layout be checked without clicking the menu-bar item.
@MainActor
enum DevRender {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--render-popover"), i + 1 < args.count else { return }
        let path = args[i + 1]
        Task { @MainActor in
            let model = MonitorModel()
            await model.refresh()
            await model.rescanCompose()
            let view = MonitorPopover()
                .environment(model)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, args.contains("--light") ? .light : .dark)
            // ImageRenderer leaves ScrollView and AppKit-backed controls blank, so the view
            // is hosted in a window that is never ordered on screen and cached from there.
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: args.contains("--light") ? .aqua : .darkAqua)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(300))
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            exit(0)
        }
    }
}
#endif
