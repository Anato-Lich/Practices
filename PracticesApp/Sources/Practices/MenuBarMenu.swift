import SwiftUI
import AppKit
import ServiceManagement

/// The menu-bar item's menu: the way back to the window, login item, quit.
struct MenuBarMenu: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Practices") {
            NSApp.activate()
            openWindow(id: MainWindow.id)
        }
        LaunchAtLoginToggle()
        Divider()
        Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

/// Registers the app as a login item through SMAppService (like Tandem).
struct LaunchAtLoginToggle: View {
    @State private var enabled = SMAppService.mainApp.status == .enabled

    var body: some View {
        Toggle("Launch at login", isOn: $enabled)
            .onChange(of: enabled) { _, on in
                do {
                    if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                } catch {
                    enabled = SMAppService.mainApp.status == .enabled
                }
            }
    }
}
