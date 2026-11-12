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
    private var menuBarController: MenuBarController?

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
        menuBarController = MenuBarController(monitor: monitor)
    }

    func applicationWillTerminate(_ notification: Notification) {
        menuBarController?.stop()
        monitor.stop()
    }
}

@main
@MainActor
enum PowerTopApp {
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let delegate = PowerTopAppDelegate()
        application.delegate = delegate
        // NSApplication's delegate is weak. Own it for the whole event loop,
        // without a SwiftUI scene that can open an unwanted Settings window.
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}
