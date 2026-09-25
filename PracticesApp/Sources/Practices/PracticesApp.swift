import SwiftUI
import AppKit
import PracticesCore

@main
struct PracticesApp: App {

    @State private var model = MonitorModel()

    init() {
        #if DEBUG
        DevRender.runIfRequested()
        #endif
    }

    var body: some Scene {
        MenuBarExtra {
            MonitorPopover()
                .environment(model)
        } label: {
            // The label always exists (it is the menu-bar item), unlike the lazy popover,
            // so monitoring starts here.
            MenuBarLabel()
                .environment(model)
                .task { model.start() }
        }
        .menuBarExtraStyle(.window)

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
