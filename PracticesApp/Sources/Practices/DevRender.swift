#if DEBUG
import SwiftUI
import AppKit

/// `Practices --render-popover out.png`: takes one real snapshot, renders the popover
/// offscreen and exits. Lets the layout be checked without clicking the menu-bar item.
@MainActor
enum DevRender {
    static func runIfRequested() {
        let args = CommandLine.arguments
        // `--check-to <file>`: run every source check and write the results as JSON, then exit.
        // Launched with `open`, the app is its own responsible process — the way to see what a
        // check does outside the terminal's network context.
        if let i = args.firstIndex(of: "--check-to"), i + 1 < args.count {
            let path = args[i + 1]
            Task { @MainActor in
                let registry = RegistryModel()
                registry.reload()
                await registry.checkAll()
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let all = registry.checks.values.flatMap { $0 }
                try? encoder.encode(all).write(to: URL(fileURLWithPath: path))
                exit(0)
            }
            return
        }
        let window = args.firstIndex(of: "--render-window")
        guard let i = args.firstIndex(of: "--render-popover") ?? window, i + 1 < args.count else { return }
        let path = args[i + 1]
        Task { @MainActor in
            let model = MonitorModel()
            let registry = RegistryModel()
            let content: AnyView
            if window != nil {
                registry.reload()
                await registry.checkAll()
                if args.contains("--doctor") { await registry.runDoctor() }
                if let j = args.firstIndex(of: "--practice"), j + 1 < args.count {
                    let ref = args[j + 1]
                    registry.selection = .practice(ref)
                    let practice = registry.model(for: ref)
                    try? await Task.sleep(for: .seconds(1))
                    practice.run()
                    while practice.running { try? await Task.sleep(for: .milliseconds(200)) }
                    if let k = args.firstIndex(of: "--step"), k + 1 < args.count { practice.selectedStep = Int(args[k + 1]) }
                }
                if args.contains("--proposals") { registry.reloadProposals(); registry.selection = .proposals }
                if let j = args.firstIndex(of: "--search"), j + 1 < args.count {
                    registry.searchText = args[j + 1]
                    if let w = args.firstIndex(of: "--wait"), w + 1 < args.count { try? await Task.sleep(for: .seconds(Double(args[w + 1]) ?? 0)) }
                }
                content = AnyView(MainWindow().environment(registry).environment(model)
                    .frame(width: 1200, height: 780))
            } else {
                await model.refresh()
                await model.rescanCompose()
                content = AnyView(MonitorPopover().environment(model))
            }
            let view = content
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
