import XCTest
import CoreFoundation
import AppKit
@testable import PowerTop

final class PowerMonitorTests: XCTestCase {
    func testFirstFrameAlreadyHasRealBatteryLevel() async {
        await MainActor.run {
            let monitor = PowerMonitor(readBatteryProperties: { Self.sample(level: 81) })
            XCTAssertTrue(monitor.hasData)
            XCTAssertEqual(monitor.currentData.batteryPercent, 81)
        }
    }

    func testFailedReadKeepsLastValidSample() async {
        await MainActor.run {
            var sample: [String: Any]? = Self.sample(level: 81)
            let monitor = PowerMonitor(readBatteryProperties: { sample })
            let timestamp = monitor.currentData.timestamp
            sample = nil
            monitor.refresh()
            XCTAssertTrue(monitor.hasData)
            XCTAssertEqual(monitor.currentData.batteryPercent, 81)
            XCTAssertEqual(monitor.currentData.timestamp, timestamp)
            sample = Self.sample(level: 82)
            monitor.refresh()
            XCTAssertEqual(monitor.currentData.batteryPercent, 82)
        }
    }

    func testIncompletePlugInSampleKeepsBatteryLevelAndUpdatesCharging() async {
        await MainActor.run {
            var sample = Self.sample(level: 81)
            let monitor = PowerMonitor(readBatteryProperties: { sample })
            sample = [
                "ExternalConnected": true,
                "IsCharging": true,
                "Amperage": 2000,
                "Voltage": 12000
            ]
            monitor.refresh()
            XCTAssertEqual(monitor.currentData.batteryPercent, 81)
            XCTAssertTrue(monitor.currentData.isBatteryCharging)
            sample["CurrentCapacity"] = 82
            sample["MaxCapacity"] = 0
            monitor.refresh()
            XCTAssertEqual(monitor.currentData.batteryPercent, 81)
            sample["MaxCapacity"] = 100
            monitor.refresh()
            XCTAssertEqual(monitor.currentData.batteryPercent, 82)
        }
    }

    func testUnknownBatteryIsNotPublishedAsZeroButRealZeroIsValid() async {
        await MainActor.run {
            var sample: [String: Any]? = nil
            let monitor = PowerMonitor(readBatteryProperties: { sample })
            XCTAssertFalse(monitor.hasData)
            sample = ["MaxCapacity": 100]
            monitor.refresh()
            XCTAssertFalse(monitor.hasData)
            sample = Self.sample(level: 0)
            monitor.refresh()
            XCTAssertTrue(monitor.hasData)
            XCTAssertEqual(monitor.currentData.batteryPercent, 0)
        }
    }

    func testACIndicatorAppearsBeforeChargingTelemetryAndEstimateWindowEnds() async {
        await MainActor.run {
            var sample = Self.sample(level: 81)
            sample["PowerTelemetryData"] = ["SystemLoad": 12000, "SystemPowerIn": 0, "BatteryPower": -12000]
            let monitor = PowerMonitor(readBatteryProperties: { sample })
            monitor.start()
            defer { monitor.stop() }
            XCTAssertFalse(monitor.isOnExternalPower)
            XCTAssertFalse(monitor.currentData.isPowerEstimated)

            sample["AdapterDetails"] = ["Watts": 70]
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)

            XCTAssertTrue(monitor.isOnExternalPower)
            XCTAssertFalse(monitor.currentData.isBatteryCharging)
            XCTAssertTrue(monitor.currentData.isPowerEstimated)
        }
    }

    func testUnplugClearsIndicatorWithStaleChargingTelemetry() async {
        await MainActor.run {
            var sample = Self.sample(level: 81)
            sample["AdapterDetails"] = ["Watts": 70]
            sample["ExternalConnected"] = true
            sample["IsCharging"] = true
            let monitor = PowerMonitor(readBatteryProperties: { sample })
            monitor.start()
            defer { monitor.stop() }
            XCTAssertTrue(monitor.isOnExternalPower)

            sample["AdapterDetails"] = [String: Any]()
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)

            XCTAssertFalse(monitor.isOnExternalPower)
            XCTAssertFalse(monitor.currentData.isBatteryCharging)
        }
    }

    func testACIndicatorDoesNotWaitForSuccessfulFullBatteryRead() async {
        await MainActor.run {
            let base = Self.sample(level: 81)
            var pending: [[String: Any]?] = []
            let monitor = PowerMonitor(readBatteryProperties: {
                pending.isEmpty ? base : pending.removeFirst()
            })
            monitor.start()
            defer { monitor.stop() }
            var connected = base
            connected["AdapterDetails"] = ["Watts": 70]
            pending = [connected, nil]

            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)

            XCTAssertTrue(monitor.isOnExternalPower)
            XCTAssertEqual(monitor.currentData.batteryPercent, 81)
            XCTAssertFalse(monitor.currentData.isBatteryCharging)
        }
    }

    func testObservationInvalidatesSourceBeforeCallbackContextDies() async {
        await MainActor.run {
            var observation: PowerSourceObservation? = PowerSourceObservation(onChange: {})
            guard let source = observation?.source else {
                XCTFail("Could not create IOPS notification source")
                return
            }
            XCTAssertTrue(CFRunLoopSourceIsValid(source))
            observation = nil
            XCTAssertFalse(CFRunLoopSourceIsValid(source))
        }
    }

    func testStartedMonitorDoesNotLeakThroughNotificationsOrTimers() async {
        await MainActor.run {
            weak var releasedMonitor: PowerMonitor?
            autoreleasepool {
                let monitor = PowerMonitor(readBatteryProperties: { Self.sample(level: 81) })
                releasedMonitor = monitor
                monitor.start()
                monitor.start() // Starting twice must not add another callback source.
            }
            XCTAssertNil(releasedMonitor)
        }
    }

    @MainActor
    func testStopCancelsQueuedTransitionRefreshes() async {
        var reads = 0
        var sample = Self.sample(level: 81)
        let monitor = PowerMonitor(readBatteryProperties: {
            reads += 1
            return sample
        })
        monitor.start()
        sample["AdapterDetails"] = ["Watts": 100]
        sample["ExternalConnected"] = true
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        monitor.stop()
        let readsAfterStop = reads
        try? await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertEqual(reads, readsAfterStop)
        withExtendedLifetime(monitor) {}
    }

    private static func sample(level: Int) -> [String: Any] {
        [
            "CurrentCapacity": level,
            "MaxCapacity": 100,
            "ExternalConnected": false,
            "IsCharging": false,
            "Amperage": -1000,
            "Voltage": 12000
        ]
    }
}
