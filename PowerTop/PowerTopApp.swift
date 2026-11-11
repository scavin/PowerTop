import SwiftUI
import AppKit
import Darwin

private final class SingleInstanceGuard {
    private let fileDescriptor: Int32

    init?() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.kdolphin.PowerTop"
        let lockName = bundleID.replacingOccurrences(of: "/", with: "_") + ".lock"
        let lockPath = (NSTemporaryDirectory() as NSString).appendingPathComponent(lockName)
        let descriptor = Darwin.open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)

        guard descriptor >= 0 else { return nil }
        var lock = flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        guard Darwin.fcntl(descriptor, F_SETLK, &lock) != -1 else {
            Darwin.close(descriptor)
            return nil
        }

        fileDescriptor = descriptor
    }

    deinit {
        Darwin.close(fileDescriptor)
    }
}

@MainActor
final class PowerTopAppDelegate: NSObject, NSApplicationDelegate {
    let monitor = PowerMonitor()
    private var instanceGuard: SingleInstanceGuard?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let instanceGuard = SingleInstanceGuard() else {
            if let bundleID = Bundle.main.bundleIdentifier {
                let currentPID = ProcessInfo.processInfo.processIdentifier
                NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                    .first { $0.processIdentifier != currentPID }?
                    .activate(options: [])
            }
            NSApp.terminate(nil)
            return
        }
        self.instanceGuard = instanceGuard
        monitor.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
    }
}

private struct PowerMenuBarLabel: View {
    let monitor: PowerMonitor
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Label {
            let data = monitor.currentData
            Text(monitor.hasData ? data.formattedPower(data.systemPowerW, compact: true) : "— W")
                .monospacedDigit()
        } icon: {
            if monitor.hasData {
                Image(nsImage: MenuBarBatteryIcon.image(
                    percentage: monitor.currentData.batteryPercent,
                    isCharging: monitor.currentData.isBatteryCharging,
                    colorScheme: colorScheme
                ))
                .renderingMode(monitor.currentData.isBatteryCharging || monitor.currentData.batteryPercent <= 20 ? .original : .template)
            } else {
                Image(systemName: "ellipsis.circle")
            }
        }
        .help(monitor.currentData.powerSourceDescription)
    }
}

@main
struct PowerTopApp: App {
    @NSApplicationDelegateAdaptor(PowerTopAppDelegate.self) private var appDelegate
    private var monitor: PowerMonitor { appDelegate.monitor }

    var body: some Scene {
        MenuBarExtra {
            PopoverView(monitor: monitor)
        } label: {
            PowerMenuBarLabel(monitor: monitor)
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

}
