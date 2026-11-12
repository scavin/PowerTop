import XCTest
@testable import PowerTop

final class BatteryTelemetryTests: XCTestCase {
    func testBankReadingsRemainThreeGroupsAndSixPhysicalSlots() throws {
        let banks: [[String: Any]] = [2, 0, 1].map { id in
            ["BankID": id, "BatteryData": ["CellVoltage": 3861 + id * 6, "Qmax": 5946 - id * 24]]
        }
        let cells: [[String: Any]] = (0..<3).flatMap { bank in
            (0..<2).map { cell in ["BankID": bank, "CellID": cell, "CellData": ["CellCurrent": 60 + cell]] }
        }
        let telemetry = try XCTUnwrap(readBatteryCellTelemetry(packBatteryData: nil,
            registry: .init(banks: banks, cells: cells)))
        XCTAssertEqual(telemetry.layout, .seriesParallel(seriesCount: 3, parallelCount: 2, parallelCountKnown: true))
        XCTAssertEqual(telemetry.groups.map(\.bankID), [0, 1, 2])
        XCTAssertEqual(telemetry.groups.map(\.qmaxMAH), [5946, 5922, 5898])
        XCTAssertEqual(telemetry.parallelCellCurrents.count, 6)
        XCTAssertNil(telemetry.voltagesMV, "A group's measurement must not masquerade as six independent cell readings")
    }

    func testPartialBankMeasurementsKeepTheirIdentityAndDoNotInventTopology() throws {
        let registry = BatteryRegistrySnapshot(banks: [
            ["BankID": 0, "BatteryData": ["CellVoltage": 3861]],
            ["BankID": 1, "BatteryData": ["Qmax": 5922]]
        ], cells: [["BankID": 0, "CellID": 0], ["BankID": 0, "CellID": 1]])
        let data = try XCTUnwrap(readBatteryCellTelemetry(packBatteryData: nil, registry: registry))
        XCTAssertEqual(data.groups, [.init(bankID: 0, voltageMV: 3861, qmaxMAH: nil),
                                     .init(bankID: 1, voltageMV: nil, qmaxMAH: 5922)])
        XCTAssertEqual(data.layout, .seriesParallel(seriesCount: 2, parallelCount: 1, parallelCountKnown: false))
    }

    func testPackArraysStillWorkWithoutBankServices() throws {
        let data = try XCTUnwrap(readBatteryCellTelemetry(packBatteryData: ["CellVoltage": [3861, 3868], "Qmax": [5900, 5890]], registry: .init()))
        XCTAssertEqual(data.layout, .perCellArrays)
        XCTAssertEqual(data.voltagesMV, [3861, 3868])
        XCTAssertEqual(data.qmaxMAH, [5900, 5890])
    }

    @MainActor
    func testUnavailableOptionalReadsDisappearOnRefreshWhileMeasuredZeroRemains() {
        var available = true
        let monitor = PowerMonitor(readBatteryProperties: {
            ["CurrentCapacity": 0, "MaxCapacity": 100,
             "Serial": "  ", "DeviceName": "",
             "BatteryData": ["RemainingCapacity": 0]]
        }, readBatteryRegistry: {
            available ? .init(pack: ["BatteryData": ["LifetimeData": ["TotalOperatingTime": 0],
                                                       "BatteryCellDisconnectCount": 0]],
                              banks: [["BankID": 0, "BatteryData": ["CellVoltage": 3861]]]) : .init()
        })
        XCTAssertEqual(monitor.currentData.totalOperatingTimeMin, 0)
        XCTAssertEqual(monitor.currentData.batteryCellDisconnectCount, 0)
        XCTAssertFalse(monitor.currentData.batterySeriesGroups.isEmpty)
        available = false
        monitor.refresh()
        let data = monitor.currentData
        XCTAssertNil(data.totalOperatingTimeMin)
        XCTAssertNil(data.batteryCellDisconnectCount)
        XCTAssertNil(data.batteryCellLayout)
        XCTAssertTrue(data.batterySeriesGroups.isEmpty)
        XCTAssertNil(data.batterySerial)
        XCTAssertNil(data.deviceName)
        XCTAssertEqual(data.remainingCapacityMAH, 0)
        XCTAssertEqual(data.batteryPercent, 0)
        XCTAssertNil(readBatteryCellTelemetry(packBatteryData: ["CellVoltage": [0, -1], "Qmax": []], registry: .init()))
    }

    @MainActor
    func testCapturedPackLocationRestoresLifetimeHealthTemperatureAndSafetyFields() {
        let pack: [String: Any] = ["BatteryData": [
            "StateOfCharge": 64, "Temperature": 3659, "DailyMinSoc": 65, "DailyMaxSoc": 100,
            "DesignCapacity": 6000, "BatteryCellDisconnectCount": 0,
            "LifetimeData": ["MaximumTemperature": 42, "MinimumTemperature": 19,
                             "AverageTemperature": 265, "TotalOperatingTime": 9386,
                             "MaximumChargeCurrent": 6607, "MaximumDischargeCurrent": -4239]
        ]]
        let monitor = PowerMonitor(readBatteryProperties: {
            ["CurrentCapacity": 64, "MaxCapacity": 100, "Voltage": 12000, "Amperage": -500,
             "BatteryData": ["FullChargeCapacity": 5700, "RemainingCapacity": 3600]]
        }, readBatteryRegistry: { .init(pack: pack) })
        let data = monitor.currentData
        XCTAssertEqual(data.batteryHealthPercent, 95)
        XCTAssertEqual(data.batteryTemperatureC, 36.59)
        XCTAssertEqual(data.stateOfCharge, 64)
        XCTAssertEqual(data.lifetimeMaxTempC, 42)
        XCTAssertEqual(data.lifetimeAvgTempC.map { Double($0) / 10 }, 26.5)
        XCTAssertEqual(data.totalOperatingTimeMin, 9386)
        XCTAssertEqual(data.lifetimeMaxDischargeCurrentMA, 4239)
        XCTAssertEqual(data.batteryCellDisconnectCount, 0)
    }

    func testManufactureDateRequiresExplicitValidNonFutureDate() {
        func encoded(_ text: String) -> Int {
            text.utf8.enumerated().reduce(0) { $0 | (Int($1.element) << ($1.offset * 8)) }
        }
        let reference = ISO8601DateFormatter().date(from: "2026-11-13T00:00:00Z")!
        XCTAssertEqual(formatBatteryManufactureDate(encoded("340101"), relativeTo: reference), "2026-01-01")
        XCTAssertNil(formatBatteryManufactureDate(encoded("350101"), relativeTo: reference))
        XCTAssertNil(formatBatteryManufactureDate(encoded("340230"), relativeTo: reference))
        XCTAssertNil(parseBatteryManufactureDate(from: ["ManufacturerData": Data("340101".utf8)]))
    }
}
