import XCTest
@testable import PowerTop

final class BatteryEstimateTests: XCTestCase {
    @MainActor
    private func sample(charging: Bool = false, limit: Int = 100, systemTime: Int = 65535,
                        conflict: Bool = false, input: Int = 18000, battery: Int = -6000) -> PowerData {
        PowerMonitor(readBatteryProperties: {
            ["CurrentCapacity": 50, "MaxCapacity": 100, "ExternalConnected": true,
             "Voltage": 12000, "Amperage": conflict ? 500 : (charging ? 1000 : -500),
             "BatteryData": ["RemainingCapacity": 3000, "FullChargeCapacity": 6000,
                             "StateOfCharge": 50, "AvgTimeToEmpty": systemTime, "AvgTimeToFull": systemTime],
             "PowerTelemetryData": ["SystemPowerIn": input, "BatteryPower": battery, "SystemLoad": 24000]]
        }, readChargeLimit: { _, _ in .init(percent: limit, source: limit < 100 ? .macOSSetting : .none) }).currentData
    }

    @MainActor
    func testSupplementalDischargeEstimatesOnlyTheSixWattsLeavingTheBattery() {
        let data = sample()
        XCTAssertEqual(data.systemPowerW, 24)
        XCTAssertEqual(data.estimatedTimeRemainingMinutes, 360, "36 Wh / 6 W, not 36 Wh / 24 W")
        XCTAssertTrue(data.estimatedTimeIsComputed)
    }

    @MainActor
    func testChargeEstimateTargetsConfiguredEightyPercentInsteadOfOneHundred() {
        let limited = sample(charging: true, limit: 80, input: 32000, battery: 12000)
        let full = sample(charging: true, input: 32000, battery: 12000)
        XCTAssertEqual(limited.estimatedTimeRemainingMinutes, 108)
        XCTAssertEqual(full.estimatedTimeRemainingMinutes, 180)
    }

    @MainActor
    func testSystemEstimateTakesPriorityAndConflictSuppressesBothEstimateSources() {
        let system = sample(systemTime: 110)
        XCTAssertEqual(system.estimatedTimeRemainingMinutes, 110)
        XCTAssertFalse(system.estimatedTimeIsComputed)
        let conflict = sample(systemTime: 110, conflict: true)
        XCTAssertTrue(conflict.hasPowerDataConflict)
        XCTAssertNil(conflict.estimatedTimeRemainingMinutes)
        XCTAssertNil(conflict.estimatedTimeRemainingText)
    }

    func testChargeLimitDoesNotTreatDailyHistoryAsAnActiveLimit() {
        XCTAssertEqual(resolveBatteryChargeLimit(dailyMaxSoc: 80), .full)
        XCTAssertEqual(resolveBatteryChargeLimit(dailyMaxSoc: 80, notChargingReason: 0x0100_0000),
                       .init(percent: 80, source: .optimizedCharging))
        XCTAssertEqual(resolveBatteryChargeLimit(dailyMaxSoc: 80, macOSLimit: 90, alDenteLimit: 75),
                       .init(percent: 75, source: .alDente))
        XCTAssertNil(isValidBatteryTimeMinutes(65535))
        XCTAssertNil(isValidBatteryTimeMinutes(0))
    }

    @MainActor
    func testBurstRefreshesDoNotAdvanceThePowerSmoothingWindow() throws {
        var smoother = BatteryTimeEstimator()
        let now = Date(timeIntervalSince1970: 1000)
        let sixWatts = sample()
        let twelveWatts = sample(input: 12000, battery: -12000)
        XCTAssertEqual(smoother.smoothedPower(for: sixWatts, at: now).dischargeW, 6)
        XCTAssertEqual(smoother.smoothedPower(for: twelveWatts, at: now).dischargeW, 6)
        let afterThirtySeconds = try XCTUnwrap(smoother.smoothedPower(for: twelveWatts, at: now.addingTimeInterval(30)).dischargeW)
        XCTAssertEqual(afterThirtySeconds, 6 + (1 - exp(-1)) * 6, accuracy: 0.001)
        XCTAssertNil(smoother.smoothedPower(for: sample(conflict: true), at: now.addingTimeInterval(31)).dischargeW)
    }
}
