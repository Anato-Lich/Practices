import SwiftUI
import AppKit
import PracticesCore

@main
struct PracticesApp: App {

    @State private var model = MonitorModel()
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
            MonitorPopover()
                .environment(model)
        } label: {
            // The label always exists (it is the menu-bar item), unlike the lazy popover,
            // so monitoring starts here.
            MenuBarLabel()
                .environment(model)
                .task { model.start() }
                .modifier(OpensMainWindow())
        }
        .menuBarExtraStyle(.window)

        Window("Practices", id: MainWindow.id) {
            MainWindow()
                .environment(registry)
                .environment(model)
        }
        .defaultSize(width: 1200, height: 780)

        WindowGroup("Logs", id: LogsView.windowID, for: String.self) { $containerID in
            if let containerID {
                LogsView(containerID: containerID)
                    .environment(model)
            }
        }
        .defaultSize(width: 820, height: 520)
    }
}

struct MenuBarLabel: View {
    @Environment(MonitorModel.self) private var model

    var body: some View {
        let count = model.alertCount
        if count > 0 {
            // Monochrome like every other item; the number is what draws the eye.
            Label("\(count)", systemImage: "shippingbox.and.arrow.backward.fill")
                .labelStyle(.titleAndIcon)
        } else if model.snapshot?.containers == nil && model.snapshot != nil {
            Image(systemName: "shippingbox")
                .symbolRenderingMode(.hierarchical)
                .opacity(0.5)
        } else {
            Image(systemName: "shippingbox")
        }
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
