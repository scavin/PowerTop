import XCTest
import AppKit
@testable import PowerTop

final class PowerPopoverTests: XCTestCase {
    @MainActor
    private func settleLayout(_ content: PowerPopover) async throws {
        for _ in 0..<5 {
            content.hostingController.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @MainActor
    func testNativePopoverResizesForUnplugReplugAndDoesNotRetainTheOldContainer() async throws {
        var plugged = true
        let monitor = PowerMonitor(readBatteryProperties: {
            var props: [String: Any] = ["CurrentCapacity": 74, "MaxCapacity": 100,
                "Voltage": 11820, "CycleCount": 162, "DesignCycleCount9C": 1000]
            props["ExternalConnected"] = plugged
            props["IsCharging"] = plugged
            props["AdapterDetails"] = plugged ? ["Watts": 100] : [String: Int]()
            props["Amperage"] = plugged ? 2000 : -2200
            props["PowerTelemetryData"] = ["SystemLoad": 27100, "SystemPowerIn": plugged ? 70000 : 0,
                "BatteryPower": plugged ? 23640 : -27100]
            return props
        })
        let content = PowerPopover(monitor: monitor, preferences: DisplayPreferences(), openDetails: {})
        let window = NSWindow(contentViewController: content.hostingController)
        window.isReleasedWhenClosed = false
        defer { window.contentViewController = nil; window.close() }
        try await settleLayout(content)
        let chargingSize = content.popover.contentSize
        XCTAssertEqual(chargingSize.width, 280, accuracy: 0.5)
        XCTAssertGreaterThan(chargingSize.height, 300)

        plugged = false
        monitor.refresh()
        try await settleLayout(content)
        let batterySize = content.popover.contentSize
        XCTAssertEqual(batterySize.width, 280, accuracy: 0.5)
        XCTAssertLessThan(batterySize.height, chargingSize.height - 30)
        XCTAssertEqual(content.hostingController.view.fittingSize.height, batterySize.height, accuracy: 0.5)

        plugged = true
        monitor.refresh()
        try await settleLayout(content)
        XCTAssertEqual(content.popover.contentSize.height, chargingSize.height, accuracy: 0.5)
        XCTAssertEqual(content.popover.behavior, .transient)
        XCTAssertFalse(content.popover.animates)
    }

    @MainActor
    func testLoadingPlaceholderExpandsToNativePreferredContentSize() async throws {
        var props: [String: Any]?
        let monitor = PowerMonitor(readBatteryProperties: { props })
        let content = PowerPopover(monitor: monitor, preferences: DisplayPreferences(), openDetails: {})
        let window = NSWindow(contentViewController: content.hostingController)
        window.isReleasedWhenClosed = false
        defer { window.contentViewController = nil; window.close() }
        try await settleLayout(content)
        let loadingHeight = content.popover.contentSize.height

        props = ["CurrentCapacity": 74, "MaxCapacity": 100, "ExternalConnected": false,
                 "IsCharging": false, "Voltage": 11820, "Amperage": -2200]
        monitor.refresh()
        try await settleLayout(content)
        XCTAssertGreaterThan(content.popover.contentSize.height, loadingHeight)
        XCTAssertEqual(content.popover.contentSize, content.hostingController.preferredContentSize)
    }
}
