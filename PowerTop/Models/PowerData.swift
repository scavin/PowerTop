import Foundation

enum PowerDataSource {
    case telemetry
    case legacy
}

enum BatteryCellTelemetryLayout: Equatable {
    /// Pack-level `CellVoltage` / `Qmax` arrays — one entry per physical cell.
    case perCellArrays
    /// Bank/cell nodes — voltage and Qmax per series group, currents per parallel cell.
    /// `parallelCountKnown` is false when no cell nodes were found (topology shows series groups only).
    case seriesParallel(seriesCount: Int, parallelCount: Int, parallelCountKnown: Bool)
}

struct BatteryParallelCellCurrent: Equatable {
    let bankID: Int
    let cellID: Int
    let currentMA: Int
}

struct PowerData {
    // Core power metrics
    let systemPowerW: Double          // System consumption, excluding battery charging
    let batteryPowerW: Double         // Normalized signed power: positive=discharge, negative=charge
    let acInputW: Double              // SystemPowerIn / 1000 — total DC from charger
    let hasACInputReading: Bool       // Distinguishes a measured zero from missing telemetry
    let acAdapterWattage: Int
    let batteryPercent: Int
    let isOnAC: Bool
    let isCharging: Bool
    let fullyCharged: Bool
    let wallPowerW: Double?
    let adapterEfficiencyLossW: Double?
    let systemVoltageMV: Int?
    let systemCurrentMA: Int?
    let batteryVoltageMV: Int?
    let batteryAmperageMA: Int?
    let batteryTemperatureC: Double?
    let cycleCount: Int?
    let adapterDescription: String?
    let dataSource: PowerDataSource
    let isPowerEstimated: Bool
    let hasPowerDataConflict: Bool    // Opposite directions or an impossible power balance
    let timestamp: Date

    // Battery health
    let batteryHealthPercent: Int?
    let designCapacityMAH: Int?
    let rawMaxCapacityMAH: Int?
    let nominalChargeCapacityMAH: Int?
    let designCycleCount: Int?

    // Charging details
    let chargingVoltageMV: Int?
    let chargingCurrentMA: Int?
    let notChargingReason: Int?
    let vacVoltageLimit: Int?

    // Cell-level data
    let cellVoltagesMV: [Int]?
    let stateOfCharge: Int?
    let qmaxMAH: [Int]?
    let dailyMinSoc: Int?
    let dailyMaxSoc: Int?

    // Lifetime statistics
    let totalOperatingTimeMin: Int?
    let lifetimeMaxTempC: Int?
    let lifetimeMinTempC: Int?
    let lifetimeAvgTempC: Int?
    let lifetimeMaxPackVoltageMV: Int?
    let lifetimeMinPackVoltageMV: Int?
    let lifetimeMaxChargeCurrentMA: Int?
    let lifetimeMaxDischargeCurrentMA: Int?

    // Device info
    let batterySerial: String?
    let deviceName: String?
    let instantAmperageMA: Int?
    let atCriticalLevel: Bool?
    let permanentFailureStatus: Int?
    let batteryCellDisconnectCount: Int?

    // Additional upstream telemetry. Mutable fields allow snapshot enrichment
    // without duplicating the full initializer when smoothing time estimates.
    var batteryCellLayout: BatteryCellTelemetryLayout? = nil
    var batterySeriesGroups: [BatterySeriesGroup] = []
    var batteryParallelCellCurrents: [BatteryParallelCellCurrent]? = nil
    var chargeLimitPercent: Int = 100
    var chargeLimitSource: BatteryChargeLimitSource = .none
    var avgTimeToEmptyMinutes: Int? = nil
    var avgTimeToFullMinutes: Int? = nil
    var remainingCapacityMAH: Int? = nil
    var fullChargeCapacityMAH: Int? = nil
    var averageSystemPowerW: Double? = nil
    var batteryManufactureDate: String? = nil
    var smoothedDischargePowerW: Double? = nil
    var smoothedChargePowerW: Double? = nil

    var batterySupplementalW: Double { isSupplementalDischarge ? max(0, batteryPowerW) : 0 }
    var headerPowerW: Double {
        !effectiveIsOnAC || isSupplementalDischarge ? systemPowerW : effectiveACOutputW
    }

    // MARK: - Computed properties

    func formattedPower(_ watts: Double, compact: Bool = false) -> String {
        guard !hasPowerDataConflict else { return "— W" }
        let prefix = isPowerEstimated ? "≈" : ""
        return String(format: compact ? "%@%.1fW" : "%@%.1f W", prefix, watts)
    }

    /// Whether we can confidently determine we're on battery (no AC at all).
    /// When ExternalConnected=false AND SystemPowerIn=0, even if IsCharging is stale=true,
    /// we know we're on battery because no AC power is flowing.
    private var clearlyOnBattery: Bool {
        !isOnAC && acInputW == 0
    }

    /// Effective AC status — uses multiple signals with safety overrides for stale data.
    var effectiveIsOnAC: Bool {
        // Safety: if no AC detected at all, ignore stale IsCharging flag
        if clearlyOnBattery { return false }
        if isCharging { return true }
        if acInputW > 0 { return true }
        return isOnAC
    }

    /// Effective AC output in watts.
    /// Uses SystemPowerIn when available; estimates only when the reading is missing.
    var effectiveACOutputW: Double {
        if !effectiveIsOnAC { return 0 }
        if hasACInputReading { return acInputW }
        // Infer only when the input reading is missing; a measured zero is real.
        return max(0, systemPowerW - batteryPowerW)
    }

    /// Whether the battery is actively charging.
    /// A charging flag alone cannot override measured discharge or idle power.
    var isBatteryCharging: Bool {
        isOnAC && !hasPowerDataConflict && batteryPowerW < -0.5
    }

    /// Battery charge rate in watts (positive value).
    var batteryChargeRateW: Double {
        if !isBatteryCharging { return 0 }
        return -batteryPowerW
    }

    /// How much power the AC adapter provides
    var acProvidesW: Double {
        effectiveACOutputW
    }

    /// How much power the battery provides to the system (discharge only)
    var batteryProvidesW: Double {
        if hasPowerDataConflict { return 0 }
        if !effectiveIsOnAC { return systemPowerW }
        return max(batteryPowerW, 0)
    }

    /// How much power the battery is receiving (charging)
    var batteryChargingW: Double {
        batteryChargeRateW
    }

    var powerSourceDescription: String {
        if hasPowerDataConflict {
            return isOnAC ? String(localized: "AC Powered") : String(localized: "Battery Discharging")
        }
        if isBatteryCharging { return String(localized: "AC Charging") }
        if !effectiveIsOnAC { return String(localized: "Battery Discharging") }
        if isSupplementalDischarge { return String(localized: "AC + Battery Powered") }
        if fullyCharged { return String(localized: "AC Fully Charged") }
        return String(localized: "AC Powered")
    }

    /// Battery is supplementing AC (AC can't provide enough power alone)
    var isSupplementalDischarge: Bool {
        isOnAC && !hasPowerDataConflict && batteryPowerW > 0.5
    }

    var validAvgTimeToEmptyMinutes: Int? {
        isValidBatteryTimeMinutes(avgTimeToEmptyMinutes)
    }

    var validAvgTimeToFullMinutes: Int? {
        isValidBatteryTimeMinutes(avgTimeToFullMinutes)
    }

    /// Remaining stored energy (Wh) from coulomb count × pack voltage.
    var remainingEnergyWh: Double? {
        if let remaining = remainingCapacityMAH, let voltage = batteryVoltageMV, remaining > 0, voltage > 0 {
            return Double(remaining) * Double(voltage) / 1_000_000.0
        }
        guard let capacity = fullChargeCapacityMAH ?? rawMaxCapacityMAH ?? nominalChargeCapacityMAH,
              capacity > 0, let voltage = batteryVoltageMV, voltage > 0 else { return nil }
        let soc = stateOfCharge ?? batteryPercent
        guard soc > 0 else { return nil }
        return Double(capacity) * Double(soc) / 100.0 * Double(voltage) / 1_000_000.0
    }

    var isAtChargeLimit: Bool {
        guard isBatteryCharging else { return false }
        let currentSoc = stateOfCharge ?? batteryPercent
        guard currentSoc >= chargeLimitPercent else { return false }
        // SOC can read above the hold point while the pack is still accepting charge.
        return batteryChargeRateW < 1.0
    }

    /// Energy still needed to reach the effective charge target (Wh).
    var energyToFullWh: Double? {
        guard isBatteryCharging, !isAtChargeLimit else { return nil }
        guard let full = fullChargeCapacityMAH ?? rawMaxCapacityMAH ?? nominalChargeCapacityMAH,
              full > 0,
              let voltage = batteryVoltageMV, voltage > 0 else { return nil }

        let currentSoc = stateOfCharge ?? batteryPercent
        guard currentSoc < chargeLimitPercent else { return nil }

        let targetCapacityMAH = full * chargeLimitPercent / 100
        if let remaining = remainingCapacityMAH, remaining > 0 {
            let deltaMAH = targetCapacityMAH - remaining
            if deltaMAH > 0 {
                return Double(deltaMAH) * Double(voltage) / 1_000_000.0
            }
        }

        let socDelta = chargeLimitPercent - currentSoc
        if socDelta > 0 {
            return Double(full) * Double(socDelta) / 100.0 * Double(voltage) / 1_000_000.0
        }
        return nil
    }

    private var dischargePowerForEstimateW: Double? {
        if let smoothed = smoothedDischargePowerW, smoothed >= 0.2 { return smoothed }
        if isSupplementalDischarge {
            // Only battery outflow drains the pack; system load includes AC contribution.
            return batterySupplementalW >= 0.2 ? batterySupplementalW : nil
        }
        if !effectiveIsOnAC {
            return systemPowerW >= 0.2 ? systemPowerW : nil
        }
        return nil
    }

    private var chargePowerForEstimateW: Double? {
        if let smoothed = smoothedChargePowerW, smoothed >= 0.2 { return smoothed }
        let rate = batteryChargeRateW
        return rate >= 0.2 ? rate : nil
    }

    private var computedTimeToEmptyMinutes: Int? {
        guard !hasPowerDataConflict && !isPowerEstimated, !isBatteryCharging else { return nil }
        guard !effectiveIsOnAC || isSupplementalDischarge else { return nil }
        guard let energyWh = remainingEnergyWh, let powerW = dischargePowerForEstimateW else { return nil }
        return Self.minutesFromEnergy(energyWh: energyWh, powerW: powerW)
    }

    private var computedTimeToFullMinutes: Int? {
        guard let energyWh = energyToFullWh, let powerW = chargePowerForEstimateW else { return nil }
        return Self.minutesFromEnergy(energyWh: energyWh, powerW: powerW)
    }

    /// Scale macOS time-to-full (100%) down when a lower charge target applies.
    private var scaledAvgTimeToFullForLimit: Int? {
        guard let avg = validAvgTimeToFullMinutes else { return nil }
        guard chargeLimitPercent < 100 else { return avg }
        let currentSoc = stateOfCharge ?? batteryPercent
        guard currentSoc < chargeLimitPercent else { return nil }
        let socToFull = 100 - currentSoc
        let socToTarget = chargeLimitPercent - currentSoc
        guard socToFull > 0, socToTarget > 0 else { return nil }
        return Self.cappedMinutes(avg * socToTarget / socToFull)
    }

    var estimatedTimeRemainingMinutes: Int? {
        guard !hasPowerDataConflict, !isPowerEstimated else { return nil }
        if isBatteryCharging {
            if isAtChargeLimit { return nil }
            if chargeLimitPercent < 100 {
                return computedTimeToFullMinutes ?? scaledAvgTimeToFullForLimit
            }
            return validAvgTimeToFullMinutes ?? computedTimeToFullMinutes
        }
        if !effectiveIsOnAC || isSupplementalDischarge {
            return validAvgTimeToEmptyMinutes ?? computedTimeToEmptyMinutes
        }
        return nil
    }

    /// True when macOS did not supply a valid AvgTimeTo* value and we used our own model.
    var estimatedTimeIsComputed: Bool {
        guard estimatedTimeRemainingMinutes != nil else { return false }
        if isBatteryCharging {
            if chargeLimitPercent < 100 { return true }
            return validAvgTimeToFullMinutes == nil
        }
        return validAvgTimeToEmptyMinutes == nil
    }

    var estimatedTimeRemainingText: String? {
        guard let minutes = estimatedTimeRemainingMinutes else { return nil }
        return Self.formatDuration(minutes: minutes)
    }

    var estimatedTimeRemainingLabel: String {
        if isBatteryCharging {
            if chargeLimitPercent < 100 {
                return String(format: String(localized: "Est. Time to %d%%"), chargeLimitPercent)
            }
            return String(localized: "Est. Time to Full")
        }
        return String(localized: "Est. Time to Empty")
    }

    var estimatedTimeFootnote: String? {
        guard isBatteryCharging, estimatedTimeIsComputed else { return nil }
        if chargeLimitPercent < 100, let source = chargeLimitSourceLabel(chargeLimitSource) {
            return String(
                format: String(localized: "Estimated to %d%% charge limit (%@)."),
                chargeLimitPercent,
                source
            )
        }
        return String(localized: "Estimated from remaining energy and recent power.")
    }

    private static func formatDuration(minutes: Int) -> String {
        let hours = minutes / 60
        let mins = minutes % 60
        if hours > 0 { return "\(hours)h \(mins)m" }
        return "\(mins)m"
    }

    private static func minutesFromEnergy(energyWh: Double, powerW: Double) -> Int? {
        guard powerW >= 0.2, energyWh > 0 else { return nil }
        return cappedMinutes(Int((energyWh / powerW) * 60.0))
    }

    private static func cappedMinutes(_ minutes: Int) -> Int {
        min(max(1, minutes), 99 * 60 + 59)
    }

    var notChargingReasonDescription: String? {
        guard let reason = notChargingReason, reason != 0 else { return nil }
        // Check individual bits/flags
        if reason & 0x01000000 != 0 { return String(localized: "Optimized Battery Charging") }
        if reason & 0x00000002 != 0 { return String(localized: "Temperature Too High") }
        if reason & 0x00000001 != 0 { return String(localized: "Battery Fully Charged") }
        if reason & 0x00000004 != 0 { return String(localized: "Battery Abnormal") }
        if reason & 0x00000080 != 0 { return String(localized: "Charger Power Insufficient") }
        // Fallback for unknown codes
        return String(format: String(localized: "Reason Code %1$@ (0x%2$@)"), "\(reason)", String(format: "%X", reason))
    }

    static let empty = PowerData(
        systemPowerW: 0, batteryPowerW: 0, acInputW: 0, hasACInputReading: false,
        acAdapterWattage: 0, batteryPercent: 0,
        isOnAC: false, isCharging: false, fullyCharged: false,
        wallPowerW: nil, adapterEfficiencyLossW: nil,
        systemVoltageMV: nil, systemCurrentMA: nil,
        batteryVoltageMV: nil, batteryAmperageMA: nil,
        batteryTemperatureC: nil, cycleCount: nil,
        adapterDescription: nil, dataSource: .telemetry,
        isPowerEstimated: false, hasPowerDataConflict: false, timestamp: Date(),
        batteryHealthPercent: nil, designCapacityMAH: nil, rawMaxCapacityMAH: nil,
        nominalChargeCapacityMAH: nil, designCycleCount: nil,
        chargingVoltageMV: nil, chargingCurrentMA: nil,
        notChargingReason: nil, vacVoltageLimit: nil,
        cellVoltagesMV: nil, stateOfCharge: nil, qmaxMAH: nil,
        dailyMinSoc: nil, dailyMaxSoc: nil,
        totalOperatingTimeMin: nil,
        lifetimeMaxTempC: nil, lifetimeMinTempC: nil, lifetimeAvgTempC: nil,
        lifetimeMaxPackVoltageMV: nil, lifetimeMinPackVoltageMV: nil,
        lifetimeMaxChargeCurrentMA: nil, lifetimeMaxDischargeCurrentMA: nil,
        batterySerial: nil, deviceName: nil,
        instantAmperageMA: nil, atCriticalLevel: nil,
        permanentFailureStatus: nil, batteryCellDisconnectCount: nil
    )
}
