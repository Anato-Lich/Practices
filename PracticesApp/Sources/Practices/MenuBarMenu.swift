import SwiftUI
import AppKit
import ServiceManagement

/// The menu-bar item's menu: the way back to the window and straight to what waits —
/// acceptance, the last cards, the map, settings; login item, quit.
struct MenuBarMenu: View {
    @Environment(RegistryModel.self) private var registry
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button { open(nil) } label: { Text(verbatim: "Открыть Practices") }
        Divider()
        let pending = registry.pending.count
        Button { open(.pending) } label: {
            Text(verbatim: pending > 0 ? "Ждут приёмки · \(pending)" : "Ждут приёмки — пусто")
        }
        .disabled(pending == 0)
        if !registry.recent.isEmpty {
            Divider()
            ForEach(registry.recent, id: \.self) { item in
                Button { open(item) } label: { Text(verbatim: label(of: item)) }
            }
        }
        Divider()
        Button { open(.map) } label: { Text(verbatim: "Карта") }
        Button { open(.settings) } label: { Text(verbatim: "Настройка") }
        Divider()
        LaunchAtLoginToggle()
        Button { NSApp.terminate(nil) } label: { Text(verbatim: "Выйти") }.keyboardShortcut("q")
    }

    private func open(_ item: MainWindow.SidebarItem?) {
        NSApp.activate()
        openWindow(id: MainWindow.id)
        if let item { registry.selection = item }
    }

    private func label(of item: MainWindow.SidebarItem) -> String {
        switch item {
        case .project(let id): "Проект \(id)"
        case .service(let id): "Сервис \(id)"
        case .practice(let ref): "Практика \(ref)"
        case .space(let id): "Пространство \(id)"
        default: item.rowID
        }
    }
}

/// Registers the app as a login item through SMAppService (like Tandem).
struct LaunchAtLoginToggle: View {
    @State private var enabled = SMAppService.mainApp.status == .enabled

    var body: some View {
        Toggle(isOn: $enabled) { Text(verbatim: "Запускать при входе") }
            .onChange(of: enabled) { _, on in
                do {
                    if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                } catch {
                    enabled = SMAppService.mainApp.status == .enabled
                }
            }
    }
}
