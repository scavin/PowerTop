import Foundation

struct BatterySeriesGroup: Equatable {
    let bankID: Int
    let voltageMV: Int?
    let qmaxMAH: Int?
}

/// Read each service once per full refresh. Keeping the raw snapshot injectable
/// also prevents fixture tests from accidentally using the host's real battery.
struct BatteryRegistrySnapshot {
    var pack: [String: Any]? = nil
    var banks: [[String: Any]] = []
    var cells: [[String: Any]] = []

    static func read() -> Self {
        Self(pack: getIOServiceProperties(className: "AppleSmartBatteryPack"),
             banks: getAllIOServiceProperties(className: "AppleSmartBatteryBank"),
             cells: getAllIOServiceProperties(className: "AppleSmartBatteryCell"))
    }

    var firstBankData: [String: Any]? {
        banks.sorted { (extractInt(from: $0, key: "BankID") ?? 0) < (extractInt(from: $1, key: "BankID") ?? 0) }
            .compactMap { extractDict(from: $0, key: "BatteryData") }.first
    }
}

struct BatteryCapacitySnapshot {
    let designCapacityMAH: Int?
    let fullChargeCapacityMAH: Int?
    let rawMaxCapacityMAH: Int?
    let nominalChargeCapacityMAH: Int?
    let remainingCapacityMAH: Int?
    let stateOfCharge: Int?
    let dailyMinSoc: Int?
    let dailyMaxSoc: Int?
    let temperatureCentidegrees: Int?

    var healthPercent: Int? {
        guard let design = designCapacityMAH, design > 0,
              let full = rawMaxCapacityMAH ?? fullChargeCapacityMAH ?? nominalChargeCapacityMAH,
              full > 0 else { return nil }
        return min(100, Int(Double(full) * 100 / Double(design)))
    }
}

func readBatteryCapacitySnapshot(from props: [String: Any], registry: BatteryRegistrySnapshot) -> BatteryCapacitySnapshot {
    let data = extractDict(from: props, key: "BatteryData") ?? [:]
    let pack = registry.pack.flatMap { extractDict(from: $0, key: "BatteryData") } ?? [:]
    let bank = registry.firstBankData ?? [:]
    func topOrData(_ key: String) -> Int? {
        extractInt(from: props, key: key) ?? extractInt(from: data, key: key)
            ?? extractInt(from: pack, key: key)
    }
    func dataOrTop(_ key: String) -> Int? {
        extractInt(from: data, key: key) ?? extractInt(from: props, key: key)
            ?? extractInt(from: pack, key: key)
    }
    func percentage(_ key: String) -> Int? {
        guard let value = dataOrTop(key) ?? extractInt(from: bank, key: key),
              (0...100).contains(value) else { return nil }
        return value
    }
    func positive(_ value: Int?) -> Int? { value.flatMap { $0 > 0 ? $0 : nil } }
    return BatteryCapacitySnapshot(
        designCapacityMAH: positive(topOrData("DesignCapacity")),
        fullChargeCapacityMAH: positive(dataOrTop("FullChargeCapacity")),
        rawMaxCapacityMAH: positive(topOrData("AppleRawMaxCapacity"))
            ?? positive(extractInt(from: bank, key: "AppleRawMaxCapacity")),
        nominalChargeCapacityMAH: positive(topOrData("NominalChargeCapacity")),
        remainingCapacityMAH: dataOrTop("RemainingCapacity").flatMap { $0 >= 0 ? $0 : nil },
        stateOfCharge: percentage("StateOfCharge"),
        dailyMinSoc: percentage("DailyMinSoc"), dailyMaxSoc: percentage("DailyMaxSoc"),
        temperatureCentidegrees: topOrData("Temperature") ?? extractInt(from: bank, key: "Temperature")
    )
}

struct BatteryCellTelemetry {
    let layout: BatteryCellTelemetryLayout
    let groups: [BatterySeriesGroup]
    let voltagesMV: [Int]?
    let qmaxMAH: [Int]?
    let parallelCellCurrents: [BatteryParallelCellCurrent]
}

func readBatteryCellTelemetry(packBatteryData: [String: Any]?, registry: BatteryRegistrySnapshot) -> BatteryCellTelemetry? {
    var groups: [BatterySeriesGroup] = []
    var bankIDs = Set<Int>()
    for (index, props) in registry.banks.enumerated() {
        let bankID = extractInt(from: props, key: "BankID") ?? index
        guard bankIDs.insert(bankID).inserted else { continue }
        let data = extractDict(from: props, key: "BatteryData") ?? [:]
        let voltage = extractInt(from: data, key: "CellVoltage").flatMap { $0 > 0 ? $0 : nil }
        let qmax = extractInt(from: data, key: "Qmax").flatMap { $0 > 0 ? $0 : nil }
        groups.append(BatterySeriesGroup(bankID: bankID, voltageMV: voltage, qmaxMAH: qmax))
    }
    groups.sort { $0.bankID < $1.bankID }

    var slots: [Int: Set<Int>] = [:]
    var currents: [BatteryParallelCellCurrent] = []
    for props in registry.cells {
        guard let bankID = extractInt(from: props, key: "BankID"), bankIDs.contains(bankID),
              let cellID = extractInt(from: props, key: "CellID"),
              slots[bankID, default: []].insert(cellID).inserted else { continue }
        if let data = extractDict(from: props, key: "CellData"),
           let current = extractInt(from: data, key: "CellCurrent") {
            currents.append(BatteryParallelCellCurrent(bankID: bankID, cellID: cellID, currentMA: current))
        }
    }
    currents.sort { $0.bankID == $1.bankID ? $0.cellID < $1.cellID : $0.bankID < $1.bankID }
    if groups.contains(where: { $0.voltageMV != nil || $0.qmaxMAH != nil }) || !currents.isEmpty {
        let counts = Set(slots.values.map(\.count))
        let known = slots.count == bankIDs.count && counts.count == 1
        let parallelCount = known ? (counts.first ?? 1) : 1
        // Keep bank IDs attached to optional fields: compacting two independent
        // arrays would pair one bank's voltage with another bank's capacity.
        return BatteryCellTelemetry(
            layout: .seriesParallel(seriesCount: groups.count, parallelCount: parallelCount, parallelCountKnown: known),
            groups: groups, voltagesMV: nil, qmaxMAH: nil, parallelCellCurrents: currents
        )
    }
    let packSources = [packBatteryData, registry.pack.flatMap { extractDict(from: $0, key: "BatteryData") }].compactMap { $0 }
    let voltages = packSources.compactMap { extractIntArray(from: $0, key: "CellVoltage") }
        .first { $0.contains { $0 > 0 } }
    let capacities = packSources.compactMap { extractIntArray(from: $0, key: "Qmax") }
        .first { $0.contains { $0 > 0 } }
    guard voltages != nil || capacities != nil else { return nil }
    return BatteryCellTelemetry(layout: .perCellArrays, groups: [], voltagesMV: voltages,
                                qmaxMAH: capacities, parallelCellCurrents: [])
}

/// macOS uses 65535 as the invalid battery-time sentinel.
func isValidBatteryTimeMinutes(_ value: Int?) -> Int? {
    value.flatMap { $0 > 0 && $0 < 65_535 ? $0 : nil }
}
