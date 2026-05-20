import SwiftUI

@main
struct PowerTopApp: App {
    @State private var monitor = PowerMonitor()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            PopoverView(monitor: monitor)
        } label: {
            Label {
                Text(String(format: "%.1fW", monitor.currentData.systemPowerW))
            } icon: {
                Image(systemName: monitor.currentData.isOnAC ? "bolt.fill" : "battery.50")
            }
        }
        .menuBarExtraStyle(.window)

        Window(String(localized: "PowerTop Details"), id: "detail") {
            DetailWindowView(monitor: monitor)
                .frame(minWidth: 520, minHeight: 500)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 560, height: 640)

        Settings {
            EmptyView()
        }
    }

    init() {
        monitor.start()
    }
}
