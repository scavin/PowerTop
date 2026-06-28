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

@main
struct PowerTopApp: App {
    private static let instanceGuard = SingleInstanceGuard()
    @State private var monitor = PowerMonitor()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            PopoverView(monitor: monitor)
        } label: {
            Label {
                Text(monitor.currentData.formattedPower(monitor.currentData.systemPowerW, compact: true))
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
        guard Self.instanceGuard != nil else {
            DispatchQueue.main.async {
                if let bundleID = Bundle.main.bundleIdentifier {
                    let currentPID = ProcessInfo.processInfo.processIdentifier
                    NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                        .first { $0.processIdentifier != currentPID }?
                        .activate(options: [])
                }
                NSApp.terminate(nil)
            }
            return
        }

        monitor.start()
    }
}
