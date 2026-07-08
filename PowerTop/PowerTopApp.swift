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
final class AppDelegate: NSObject, NSApplicationDelegate {
    let monitor = PowerMonitor()
    private var didStart = false

    private func startIfNeeded() {
        guard !didStart else { return }
        didStart = true
        monitor.start()
    }

    nonisolated func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            startIfNeeded()
        }
    }

    nonisolated func applicationDidBecomeActive(_ notification: Notification) {
        Task { @MainActor in
            monitor.refreshNow()
        }
    }

    nonisolated func applicationWillTerminate(_ notification: Notification) {
        Task { @MainActor in
            monitor.stop()
        }
    }
}

@main
struct PowerTopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private var monitor: PowerMonitor { appDelegate.monitor }

    var body: some Scene {
        MenuBarExtra {
            PopoverView(monitor: monitor)
        } label: {
            MenuBarLabelView(monitor: monitor)
                .id(monitor.uiRefreshToken)
        }
        .menuBarExtraStyle(.window)

        Window(String(localized: "PowerTop Details"), id: "detail") {
            DetailWindowView(monitor: monitor)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: DetailWindowView.preferredWidth, height: 640)
        .windowResizability(.contentSize)
    }
}
