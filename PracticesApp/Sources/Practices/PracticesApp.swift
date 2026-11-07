import SwiftUI
import AppKit
import PracticesCore

@main
struct PracticesApp: App {

    @State private var registry = RegistryModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    /// A copy started to render screens or run checks (`--render-*`, `--check-to`) stays out of
    /// the menu bar: it would sit next to the real one for as long as it lives.
    @State private var inMenuBar = !CommandLine.arguments.contains { $0.hasPrefix("--render-") || $0 == "--check-to" }

    init() {
        #if DEBUG
        DevRender.runIfRequested()
        #endif
    }

    var body: some Scene {
        MenuBarExtra(isInserted: $inMenuBar) {
            MenuBarMenu().environment(registry)
        } label: {
            // The label always exists (it is the menu-bar item), unlike the menu.
            Image(systemName: "books.vertical")
                .modifier(OpensMainWindow())
                // A menu-bar agent has no window at launch: the menu's counts load here.
                .task { registry.reload(); await registry.refreshPending() }
        }

        Window("Practices", id: MainWindow.id) {
            MainWindow()
                .environment(registry)
        }
        // The design draws its own toolbar (MainWindow): no title bar, the traffic lights over the sidebar.
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 860)
    }
}

extension Notification.Name {
    static let openMainWindow = Notification.Name("dev.practices.openMainWindow")
}

/// Opening the app again (Finder, Spotlight, Launchpad) while it sits in the menu bar shows
/// the main window, as any app would.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        NotificationCenter.default.post(name: .openMainWindow, object: nil)
        return false
    }
}

/// `openWindow` needs a view inside a scene; the menu-bar label is the one that always exists.
struct OpensMainWindow: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: .openMainWindow)) { _ in
            NSApp.activate()
            openWindow(id: MainWindow.id)
        }
    }
}
