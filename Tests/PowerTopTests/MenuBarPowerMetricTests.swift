import XCTest
@testable import PowerTop

final class MenuBarPowerMetricTests: XCTestCase {
    @MainActor
    func testAutomaticModeCapsOnlyItsDisplayAndWarningsStayOptional() {
        let data = sample(onAC: true, charging: true, input: 140000, battery: 60000, load: 80000, amperage: 5000)
        XCTAssertEqual(MenuBarPowerMetric.automatic.formattedPower(from: data), "140.0W")
        XCTAssertEqual(MenuBarPowerMetric.automatic.formattedPower(from: data, capped: true), "≥99W")
        XCTAssertEqual(MenuBarPowerMetric.automatic.formattedPower(from: data, capped: true, showWarnings: true), "⚠ ≥99W")
        XCTAssertEqual(data.effectiveACOutputW, 140)
        let supplement = sample(onAC: true, charging: false, input: 18000, battery: -6000, load: 24000, amperage: -500)
        XCTAssertEqual(MenuBarPowerMetric.automatic.formattedPower(from: supplement), "24.0W")
        XCTAssertEqual(MenuBarPowerMetric.automatic.formattedPower(from: supplement, showWarnings: true), "⚠ 24.0W")
    }

    @MainActor
    private func sample(onAC: Bool, charging: Bool, input: Int, battery: Int, load: Int, amperage: Int) -> PowerData {
        let monitor = PowerMonitor(readBatteryProperties: {
            ["CurrentCapacity": 74, "MaxCapacity": 100,
             "ExternalConnected": onAC, "IsCharging": charging,
             "Voltage": 12000, "Amperage": amperage,
             "PowerTelemetryData": ["SystemPowerIn": input, "BatteryPower": battery, "SystemLoad": load]]
        })
        return monitor.currentData
    }

    @MainActor
    func testEightyWattInputSplitsIntoTwentyWattSystemAndSixtyWattBattery() {
        let data = sample(onAC: true, charging: true, input: 80000, battery: 60000, load: 80000, amperage: 5000)
        XCTAssertEqual(MenuBarPowerMetric.system.formattedPower(from: data), "20.0W")
        XCTAssertEqual(MenuBarPowerMetric.adapterInput.formattedPower(from: data), "80.0W")
        XCTAssertEqual(MenuBarPowerMetric.batteryNet.formattedPower(from: data), "+60.0W")
    }

    @MainActor
    func testBatteryNetShowsOutflowOnBatteryAndZeroWhenIdle() {
        let discharging = sample(onAC: false, charging: false, input: 0, battery: -12000, load: -12000, amperage: -1000)
        XCTAssertEqual(MenuBarPowerMetric.system.formattedPower(from: discharging), "12.0W")
        XCTAssertEqual(MenuBarPowerMetric.adapterInput.formattedPower(from: discharging), "0.0W")
        XCTAssertEqual(MenuBarPowerMetric.batteryNet.formattedPower(from: discharging), "−12.0W")

        let idle = sample(onAC: true, charging: false, input: 20000, battery: 0, load: 20000, amperage: 0)
        XCTAssertEqual(MenuBarPowerMetric.batteryNet.formattedPower(from: idle), "0.0W")
        XCTAssertEqual(MenuBarPowerMetric.adapterInput.formattedPower(from: idle), "20.0W")
    }

    @MainActor
    func testUnknownAndStaleSamplesAreNotReportedAsRealFlowsAndInferredInputIsMarked() {
        for metric in MenuBarPowerMetric.allCases {
            XCTAssertEqual(metric.formattedPower(from: nil), "— W")
        }
        let missingInput = PowerMonitor(readBatteryProperties: {
            ["CurrentCapacity": 74, "MaxCapacity": 100,
             "ExternalConnected": true, "IsCharging": true,
             "Voltage": 12000, "Amperage": 5000,
             "PowerTelemetryData": ["BatteryPower": 60000, "SystemLoad": 20000]]
        }).currentData
        XCTAssertEqual(MenuBarPowerMetric.adapterInput.formattedPower(from: missingInput), "≈80.0W")

        let staleCharge = sample(onAC: false, charging: true, input: 80000, battery: 60000, load: -12000, amperage: -1000)
        XCTAssertEqual(MenuBarPowerMetric.adapterInput.formattedPower(from: staleCharge), "0.0W")
        XCTAssertEqual(MenuBarPowerMetric.batteryNet.formattedPower(from: staleCharge), "— W")
    }
}
