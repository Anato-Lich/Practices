#if DEBUG
import SwiftUI
import AppKit

/// `Practices --render-window out.png [--space id | --project id | --service id | --practice ref |
/// --pending | --unassigned | --map | --search text | --palette text | --doctor | --welcome | --settings] [--expand project,…] [--wait seconds]`:
/// renders the main window offscreen and exits. Lets the layout be checked without clicking.
@MainActor
enum DevRender {
    static func runIfRequested() {
        let args = CommandLine.arguments
        // `--check-to <file>`: run every service check and write the results as JSON, then exit.
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
        guard let i = args.firstIndex(of: "--render-window"), i + 1 < args.count else { return }
        let path = args[i + 1]
        Task { @MainActor in
            let registry = RegistryModel()
            registry.reload()
            if args.contains("--doctor") {
                registry.selection = .doctor
                await registry.runDoctor()
            }
            if let j = args.firstIndex(of: "--practice"), j + 1 < args.count {
                let ref = args[j + 1]
                registry.selection = .practice(ref)
                let practice = registry.model(for: ref)
                try? await Task.sleep(for: .seconds(1))
                practice.run()
                while practice.running { try? await Task.sleep(for: .milliseconds(200)) }
                if let k = args.firstIndex(of: "--step"), k + 1 < args.count { practice.selectedStep = Int(args[k + 1]) }
            }
            if let j = args.firstIndex(of: "--service"), j + 1 < args.count { registry.selection = .service(args[j + 1]) }
            if let j = args.firstIndex(of: "--space"), j + 1 < args.count { registry.selection = .space(args[j + 1]) }
            if let j = args.firstIndex(of: "--project"), j + 1 < args.count, let project = registry.project(args[j + 1]) {
                registry.selection = .project(project.id)
                await registry.loadGitStates(of: project)
            }
            if args.contains("--pending") {
                await registry.refreshPending()
                registry.selection = .pending
            }
            // `--expand a,b`: these projects open in the sidebar, with their services.
            if let j = args.firstIndex(of: "--expand"), j + 1 < args.count {
                for id in args[j + 1].split(separator: ",").map(String.init) {
                    registry.expanded.insert(.project(id))
                    for service in registry.services where service.project == id { registry.expanded.insert(.service(service.id)) }
                }
            }
            if args.contains("--unassigned") {
                registry.selection = .unassigned
                if args.contains("--load") { await registry.loadUnassigned() }
            }
            if args.contains("--map") { registry.selection = .map }
            // `--welcome`: «Начало» (with an empty `PRACTICES_HOME` it shows anyway); `--settings`: «Настройка».
            if args.contains("--welcome") { registry.welcomeShown = true; await registry.setup.refresh() }
            if args.contains("--settings") { registry.selection = .settings; await registry.setup.refresh() }
            if let j = args.firstIndex(of: "--search"), j + 1 < args.count { registry.searchText = args[j + 1] }
            if args.contains("--palette") { registry.paletteShown = true }
            // `--remove`: the removal sheet of the `--project`; `--failed <what>`: the error bar.
            if args.contains("--remove"), case .project(let id)? = registry.selection { registry.removalCandidate = id }
            if let j = args.firstIndex(of: "--failed"), j + 1 < args.count { registry.failed = (args[j + 1], "git commit: exit 128 · .git/index.lock exists", Date()) }
            // The design's size; the traffic lights a real window draws, so the PNG compares with it.
            let view = MainWindow().environment(registry).frame(width: 1280, height: 860)
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 8) {
                        ForEach([0xFF5F57, 0xFEBC2E, 0x28C840] as [UInt32], id: \.self) { Circle().fill(Color(hex: $0)).frame(width: 12, height: 12) }
                    }
                    .padding(.leading, 14).frame(height: 52)
                }
                .environment(\.colorScheme, .dark)
            // ImageRenderer leaves ScrollView and AppKit-backed controls blank, so the view
            // is hosted in a window that is never ordered on screen and cached from there.
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(300))
            // `--wait <seconds>`: for what the views load themselves once they are on screen.
            if let w = args.firstIndex(of: "--wait"), w + 1 < args.count { try? await Task.sleep(for: .seconds(Double(args[w + 1]) ?? 0)) }
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            exit(0)
        }
    }
}
#endif
