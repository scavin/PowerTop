import XCTest
@testable import PowerTop

final class PowerFlowTests: XCTestCase {
    private static func properties(
        charging: Bool = true, amperage: Int = -500, voltage: Int = 12000,
        input: Int = 18702, load: Int = 24721, battery: Int = -6019
    ) -> [String: Any] {
        ["CurrentCapacity": 72, "MaxCapacity": 100,
         "ExternalConnected": true, "IsCharging": charging,
         "Voltage": voltage, "Amperage": amperage,
         "AdapterDetails": ["Watts": 100],
         "PowerTelemetryData": ["SystemPowerIn": input, "SystemLoad": load,
                                "BatteryPower": battery]]
    }

    @MainActor
    func testNegativeCurrentCannotBecomeChargingThroughStaleFlag() {
        let data = PowerMonitor(readBatteryProperties: { Self.properties() }).currentData
        XCTAssertFalse(data.isCharging)
        XCTAssertFalse(data.isBatteryCharging)
        XCTAssertEqual(data.batteryChargeRateW, 0)
        XCTAssertEqual(data.batteryPowerW, 6.019, accuracy: 0.001)
        XCTAssertEqual(data.systemPowerW, 24.721, accuracy: 0.001)
        XCTAssertTrue(data.isSupplementalDischarge)
        XCTAssertEqual(data.batteryProvidesW, 6.019, accuracy: 0.001)
        XCTAssertEqual(MenuBarPowerMetric.batteryNet.formattedPower(from: data), "−6.0W")
    }

    @MainActor
    func testCapturedOppositeDirectionsAreUnavailableUntilTheyAgree() {
        // Captured on this Mac: the power block says -6.019 W, but V*I says +4.176 W.
        var props = Self.properties(amperage: 348, voltage: 12001)
        let monitor = PowerMonitor(readBatteryProperties: { props })
        let conflict = monitor.currentData
        XCTAssertFalse(conflict.isBatteryCharging)
        XCTAssertFalse(conflict.isSupplementalDischarge)
        XCTAssertEqual(conflict.formattedPower(conflict.systemPowerW), "— W")
        for metric in MenuBarPowerMetric.allCases {
            XCTAssertEqual(metric.formattedPower(from: conflict), "— W")
        }

        props["Amperage"] = -500
        monitor.refresh()
        XCTAssertEqual(MenuBarPowerMetric.system.formattedPower(from: monitor.currentData), "24.7W")
        XCTAssertEqual(MenuBarPowerMetric.batteryNet.formattedPower(from: monitor.currentData), "−6.0W")
    }

    @MainActor
    func testChargingTelemetryCannotOverrideOppositeSignedCurrent() {
        let data = PowerMonitor(readBatteryProperties: {
            Self.properties(amperage: -1000, input: 80000, load: 20000, battery: 60000)
        }).currentData
        XCTAssertFalse(data.isBatteryCharging)
        XCTAssertFalse(data.isCharging)
        XCTAssertEqual(MenuBarPowerMetric.batteryNet.formattedPower(from: data), "— W")
    }

    @MainActor
    func testLegacyNegativeCurrentPreservesDischargeDirection() {
        var props = Self.properties()
        props.removeValue(forKey: "PowerTelemetryData")
        let data = PowerMonitor(readBatteryProperties: { props }).currentData
        XCTAssertFalse(data.isCharging)
        XCTAssertFalse(data.isBatteryCharging)
        XCTAssertEqual(data.batteryPowerW, 6)
        XCTAssertEqual(MenuBarPowerMetric.batteryNet.formattedPower(from: data), "≈−6.0W")
    }

    @MainActor
    func testZeroCurrentAndZeroBatteryPowerDoNotUseStaleChargingFlag() {
        let data = PowerMonitor(readBatteryProperties: {
            Self.properties(amperage: 0, input: 20000, load: 20000, battery: 0)
        }).currentData
        XCTAssertFalse(data.isCharging)
        XCTAssertFalse(data.isBatteryCharging)
        XCTAssertEqual(data.batteryChargeRateW, 0)
        XCTAssertEqual(MenuBarPowerMetric.batteryNet.formattedPower(from: data), "0.0W")
    }

    @MainActor
    func testMeasuredZeroInputWhileConnectedIsNotInferredAsNormalACPower() {
        let data = PowerMonitor(readBatteryProperties: {
            Self.properties(charging: false, amperage: -2000, input: 0, load: 24000, battery: -24000)
        }).currentData
        XCTAssertTrue(data.effectiveIsOnAC)
        XCTAssertEqual(data.effectiveACOutputW, 0)
        XCTAssertTrue(data.isSupplementalDischarge)
        XCTAssertEqual(data.batteryProvidesW, 24)
        XCTAssertEqual(MenuBarPowerMetric.adapterInput.formattedPower(from: data), "0.0W")
        XCTAssertEqual(MenuBarPowerMetric.batteryNet.formattedPower(from: data), "−24.0W")
    }

    @MainActor
    func testMeasuredChargeDoesNotDependOnChargingFlag() {
        let data = PowerMonitor(readBatteryProperties: {
            Self.properties(charging: false, amperage: 5000, input: 80000, load: 20000, battery: 60000)
        }).currentData
        XCTAssertTrue(data.isCharging)
        XCTAssertTrue(data.isBatteryCharging)
        XCTAssertEqual(data.systemPowerW, 20)
        XCTAssertEqual(MenuBarPowerMetric.batteryNet.formattedPower(from: data), "+60.0W")
    }

    @MainActor
    func testMissingBatteryTelemetryFallsBackToSignedCurrent() {
        var props = Self.properties(amperage: -1000, input: 20000, load: 32000)
        props["PowerTelemetryData"] = ["SystemPowerIn": 20000, "SystemLoad": 32000]
        let data = PowerMonitor(readBatteryProperties: { props }).currentData
        XCTAssertFalse(data.isBatteryCharging)
        XCTAssertEqual(data.batteryPowerW, 12)
        XCTAssertEqual(data.systemPowerW, 32)
        XCTAssertTrue(data.isPowerEstimated)
    }

    @MainActor
    func testZeroInputWithStaleChargeDoesNotInventAdapterOutput() {
        let data = PowerMonitor(readBatteryProperties: {
            Self.properties(amperage: 5000, input: 0, load: 20000, battery: 60000)
        }).currentData
        XCTAssertTrue(data.hasACInputReading)
        XCTAssertEqual(data.effectiveACOutputW, 0)
        XCTAssertFalse(data.isBatteryCharging)
        XCTAssertEqual(MenuBarPowerMetric.adapterInput.formattedPower(from: data), "— W")
    }

    @MainActor
    func testUnsignedIOKitDischargeKeepsItsSign() {
        var props = Self.properties()
        props["Amperage"] = UInt64(bitPattern: -500)
        props["PowerTelemetryData"] = ["SystemPowerIn": 18702, "SystemLoad": 24721,
                                        "BatteryPower": UInt64(bitPattern: -6019)] as [String: Any]
        let data = PowerMonitor(readBatteryProperties: { props }).currentData
        XCTAssertFalse(data.isBatteryCharging)
        XCTAssertEqual(data.systemPowerW, 24.721, accuracy: 0.001)
        XCTAssertEqual(MenuBarPowerMetric.batteryNet.formattedPower(from: data), "−6.0W")
    }
}
