import XCTest
import AppKit
import SwiftUI
@testable import PowerTop

final class PowerPopoverTests: XCTestCase {
    @MainActor
    func testRichDetailsAndPowerOptionsFitTheirNativeContainers() async throws {
        let monitor = PowerMonitor(readBatteryProperties: {
            ["CurrentCapacity": 64, "MaxCapacity": 100, "ExternalConnected": true,
             "Voltage": 12000, "Amperage": -500, "CycleCount": 162, "DesignCycleCount9C": 1000,
             "AdapterDetails": ["Watts": 140, "Description": "USB-C Power Adapter"],
             "BatteryData": ["DesignCapacity": 6000, "FullChargeCapacity": 5700, "RemainingCapacity": 3600],
             "PowerTelemetryData": ["SystemPowerIn": 18000, "BatteryPower": -6000, "SystemLoad": 24000]]
        }, readBatteryRegistry: {
            .init(pack: ["BatteryData": ["Temperature": 3659,
                "LifetimeData": ["MaximumTemperature": 42, "MinimumTemperature": 19, "AverageTemperature": 265,
                                 "TotalOperatingTime": 9386, "MaximumChargeCurrent": 6607, "MaximumDischargeCurrent": -4239]]],
                  banks: (0..<3).map { ["BankID": $0, "BatteryData": ["CellVoltage": 3861 + $0 * 6, "Qmax": 5946 - $0 * 24]] },
                  cells: (0..<3).flatMap { bank in (0..<2).map { ["BankID": bank, "CellID": $0, "CellData": ["CellCurrent": 60 + $0]] } })
        })
        let defaults = UserDefaults(suiteName: "PowerTopTests.Layout.\(UUID().uuidString)")!
        let preferences = DisplayPreferences(defaults: defaults)
        preferences.showMenuBarPower = true
        preferences.menuBarPowerMetric = .automatic
        let content = PowerPopover(monitor: monitor, preferences: preferences, openDetails: {})
        let popoverWindow = NSWindow(contentViewController: content.hostingController)
        let details = NSHostingController(rootView: DetailWindowView(monitor: monitor))
        let detailWindow = NSWindow(contentViewController: details)
        detailWindow.setContentSize(NSSize(width: DetailWindowView.preferredWidth, height: 2200))
        let minimalMonitor = PowerMonitor(readBatteryProperties: {
            ["CurrentCapacity": 64, "MaxCapacity": 100, "ExternalConnected": false,
             "Voltage": 12000, "Amperage": -500]
        })
        let minimalDetails = NSHostingController(rootView: DetailWindowView(monitor: minimalMonitor))
        let minimalWindow = NSWindow(contentViewController: minimalDetails)
        minimalWindow.setContentSize(NSSize(width: DetailWindowView.preferredWidth, height: 700))
        for window in [popoverWindow, detailWindow, minimalWindow] { window.isReleasedWhenClosed = false }
        defer {
            content.stop()
            for window in [popoverWindow, detailWindow, minimalWindow] { window.contentViewController = nil; window.close() }
        }
        try await settleLayout(content)
        details.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(content.popover.contentSize.width, 280, accuracy: 0.5)
        XCTAssertEqual(details.view.bounds.width, DetailWindowView.preferredWidth, accuracy: 0.5)
        let directory = ProcessInfo.processInfo.environment["POWERTOP_QA_DIR"]
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("PowerTop-Layout-QA").path
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            minimalDetails.view.layoutSubtreeIfNeeded()
            for (name, view) in [("popover", content.hostingController.view), ("details", details.view),
                                 ("details-unavailable", minimalDetails.view)] {
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
            }
            print("PowerTop layout previews: \(directory)")
        }
    }

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
