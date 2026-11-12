import Foundation
import AppKit
import IOKit
import IOKit.ps
import Observation
import ServiceManagement

@MainActor
@Observable
final class PowerMonitor {
    var currentData: PowerData = .empty
    private(set) var hasData = false
    // Connection presentation is independent of charging telemetry and the
    // 15-second power-estimation window.
    private(set) var isOnExternalPower = false
    var launchAtLoginError: String?
    var launchAtLogin: Bool {
        didSet {
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                launchAtLoginError = nil
            } catch {
                launchAtLogin = oldValue
                launchAtLoginError = error.localizedDescription
            }
        }
    }

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var adapterProbeTimer: Timer?
    @ObservationIgnored private var powerSourceObservation: PowerSourceObservation?
    @ObservationIgnored private var lastAdapterSignature: AdapterSignature?
    @ObservationIgnored private var adapterConnectedOverride: Bool?
    @ObservationIgnored private var adapterEstimateUntil: Date?
    @ObservationIgnored private var transitionRefreshGeneration = 0
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private var timeEstimator = BatteryTimeEstimator()
    @ObservationIgnored private var isSleeping = false
    @ObservationIgnored private let readBatteryRegistry: () -> BatteryRegistrySnapshot
    @ObservationIgnored private let readChargeLimit: (Int?, Int?) -> ResolvedBatteryChargeLimit
    @ObservationIgnored private let readBatteryProperties: () -> [String: Any]?
    private let updateInterval: TimeInterval = 2.0
    private let adapterProbeInterval: TimeInterval = 0.25

    private struct AdapterSignature: Equatable {
        let wattage: Int
        let description: String?

        var isConnected: Bool { wattage > 0 }
    }

    init(
        readBatteryProperties: (() -> [String: Any]?)? = nil,
        readBatteryRegistry: (() -> BatteryRegistrySnapshot)? = nil,
        readChargeLimit: ((Int?, Int?) -> ResolvedBatteryChargeLimit)? = nil
    ) {
        let usesLiveRegistry = readBatteryProperties == nil
        self.readBatteryProperties = readBatteryProperties ?? { getIOServiceProperties(className: "AppleSmartBattery") }
        self.readBatteryRegistry = readBatteryRegistry ?? (usesLiveRegistry ? { .read() } : { .init() })
        self.readChargeLimit = readChargeLimit ?? (usesLiveRegistry
            ? { readResolvedBatteryChargeLimit(dailyMaxSoc: $0, notChargingReason: $1) }
            : { _, _ in .full })
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
        // Seed the first icon before SwiftUI displays the menu bar label.
        updateData()
    }

    deinit {
        timer?.invalidate()
        adapterProbeTimer?.invalidate()
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        isSleeping = false
        let adapterSignature = readAdapterSignature()
        lastAdapterSignature = adapterSignature
        adapterConnectedOverride = adapterSignature?.isConnected
        if let adapterSignature { isOnExternalPower = adapterSignature.isConnected }
        updateData()
        scheduleTimer()
        scheduleAdapterProbeTimer()
        setupPowerSourceNotification()

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemDidSleep),
            name: NSWorkspace.willSleepNotification, object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification, object: nil
        )
    }

    func stop() {
        isRunning = false
        timeEstimator.reset()
        transitionRefreshGeneration += 1
        timer?.invalidate()
        timer = nil
        adapterProbeTimer?.invalidate()
        adapterProbeTimer = nil
        powerSourceObservation?.invalidate()
        powerSourceObservation = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func systemDidSleep() {
        isSleeping = true
        transitionRefreshGeneration += 1
        timeEstimator.reset()
        timer?.invalidate()
        timer = nil
        adapterProbeTimer?.invalidate()
        adapterProbeTimer = nil
    }

    @objc private func systemDidWake() {
        guard isRunning else { return }
        isSleeping = false
        pollAdapterChanges()
        updateData()
        scheduleTimer()
        scheduleAdapterProbeTimer()
    }

    // MARK: - IOPS Power Source Notification

    private func setupPowerSourceNotification() {
        powerSourceObservation = PowerSourceObservation { [weak self] in
            guard let self, self.isRunning, !self.isSleeping else { return }
            self.handlePowerSourceEvent()
        }
    }

    /// IOPS's explicit connection event takes precedence over a cached adapter
    /// dictionary. Polling AdapterDetails still provides fast PD renegotiation.
    func handlePowerSourceEvent() {
        if let props = readBatteryProperties(),
           let connected = extractBool(from: props, key: "ExternalConnected") {
            if connected != isOnExternalPower {
                adapterEstimateUntil = Date().addingTimeInterval(15)
                timeEstimator.reset()
            }
            adapterConnectedOverride = connected
            isOnExternalPower = connected
        }
        scheduleTransitionRefreshes()
    }

    // MARK: - Timer

    private func scheduleTimer() {
        timer?.invalidate()
        let refreshTimer = Timer(timeInterval: updateInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRunning, !self.isSleeping else { return }
                self.updateData()
            }
        }
        RunLoop.main.add(refreshTimer, forMode: .common)
        timer = refreshTimer
    }

    /// AdapterDetails updates much sooner than the rest of the battery telemetry
    /// when a USB-C PD adapter is attached, removed, or renegotiated. Probe only
    /// that lightweight property so a charger transition can trigger immediate
    /// full-data refreshes instead of waiting for stale IOPS values to expire.
    private func scheduleAdapterProbeTimer() {
        adapterProbeTimer?.invalidate()
        let probeTimer = Timer(timeInterval: adapterProbeInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRunning, !self.isSleeping else { return }
                self.pollAdapterChanges()
            }
        }
        RunLoop.main.add(probeTimer, forMode: .common)
        adapterProbeTimer = probeTimer
    }

    private func pollAdapterChanges() {
        guard let signature = readAdapterSignature() else { return }

        guard let previous = lastAdapterSignature else {
            lastAdapterSignature = signature
            adapterConnectedOverride = signature.isConnected
            isOnExternalPower = signature.isConnected
            return
        }
        guard signature != previous else { return }

        lastAdapterSignature = signature
        // During a transition, AdapterDetails is authoritative because
        // ExternalConnected and SystemPowerIn commonly retain their old values.
        adapterConnectedOverride = signature.isConnected
        isOnExternalPower = signature.isConnected
        // The remaining power telemetry can describe the previous adapter for
        // many seconds. Do not render that stale flow while PD renegotiates.
        adapterEstimateUntil = Date().addingTimeInterval(15)
        scheduleTransitionRefreshes()
    }

    private func scheduleTransitionRefreshes() {
        transitionRefreshGeneration += 1
        let generation = transitionRefreshGeneration

        for delay: TimeInterval in [0, 0.1, 0.25, 0.5, 1, 1.5, 2, 3, 5, 8, 12] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.isRunning, !self.isSleeping, self.transitionRefreshGeneration == generation else { return }
                self.updateData()
            }
        }
    }

    func refresh() {
        updateData()
    }

    private func updateData() {
        let useAdapterEstimate = adapterEstimateUntil.map { Date() < $0 } ?? false
        guard var data = readPowerData(
            adapterConnectedOverride: adapterConnectedOverride,
            useAdapterEstimate: useAdapterEstimate
        ) else { return } // A failed read must not reset the icon to 0%.
        let smoothed = timeEstimator.smoothedPower(for: data)
        data.smoothedDischargePowerW = smoothed.dischargeW
        data.smoothedChargePowerW = smoothed.chargeW
        self.currentData = data
        hasData = true
        isOnExternalPower = adapterConnectedOverride ?? data.effectiveIsOnAC
    }

    // MARK: - IOKit Reading

    private func readAdapterSignature() -> AdapterSignature? {
        guard let props = readBatteryProperties() else {
            return nil
        }
        let adapterDetails = extractDict(from: props, key: "AdapterDetails")
        return AdapterSignature(
            wattage: adapterDetails.flatMap { extractInt(from: $0, key: "Watts") }
                ?? ((adapterDetails == nil && (extractBool(from: props, key: "ExternalConnected") ?? false)) ? 1 : 0),
            description: adapterDetails.flatMap { extractString(from: $0, key: "Description") }
        )
    }

    private func readPowerData(
        adapterConnectedOverride: Bool?,
        useAdapterEstimate: Bool
    ) -> PowerData? {
        guard let props = readBatteryProperties() else {
            return nil
        }

        let registry = readBatteryRegistry()
        let batteryData = extractDict(from: props, key: "BatteryData")
        let packData = registry.pack.flatMap { extractDict(from: $0, key: "BatteryData") }
        let capacitySnapshot = readBatteryCapacitySnapshot(from: props, registry: registry)

        // Basic battery info
        let rawIsOnAC = extractBool(from: props, key: "ExternalConnected") ?? false
        let isOnAC = adapterConnectedOverride ?? rawIsOnAC
        let fullyCharged = extractBool(from: props, key: "FullyCharged") ?? false
        let currentCapacity = extractInt(from: props, key: "CurrentCapacity")
        let maxCapacity = extractInt(from: props, key: "MaxCapacity")
        let batteryPercent: Int
        if let currentCapacity, let maxCapacity,
           maxCapacity > 0, currentCapacity >= 0, currentCapacity <= maxCapacity {
            batteryPercent = Int(Double(currentCapacity) * 100 / Double(maxCapacity))
        } else if hasData {
            batteryPercent = currentData.batteryPercent
        } else {
            return nil
        }
        let voltage = extractInt(from: props, key: "Voltage")
        let amperage = extractInt(from: props, key: "Amperage")
        let temperature = capacitySnapshot.temperatureCentidegrees
        let cycleCount = extractInt(from: props, key: "CycleCount")

        // Device info
        let batterySerial = extractString(from: props, key: "Serial")
        let deviceName = extractString(from: props, key: "DeviceName")
        let instantAmperage = extractInt(from: props, key: "InstantAmperage")
        let atCriticalLevel = extractBool(from: props, key: "AtCriticalLevel")
        let permanentFailure = extractInt(from: props, key: "PermanentFailureStatus")
            ?? packData.flatMap { extractInt(from: $0, key: "PermanentFailureStatus") }
        let cellDisconnectCount = extractInt(from: props, key: "BatteryCellDisconnectCount")
            ?? packData.flatMap { extractInt(from: $0, key: "BatteryCellDisconnectCount") }

        // Battery health
        let designCapacity = capacitySnapshot.designCapacityMAH
        let rawMaxCapacity = capacitySnapshot.rawMaxCapacityMAH
        let nominalChargeCapacity = capacitySnapshot.nominalChargeCapacityMAH
        let designCycleCount = extractInt(from: props, key: "DesignCycleCount9C")
            ?? extractInt(from: props, key: "DesignCycleCount70")
        let batteryHealthPercent = capacitySnapshot.healthPercent

        // Adapter details
        let adapterDetails = extractDict(from: props, key: "AdapterDetails")
        let acAdapterWattage = adapterDetails.flatMap { extractInt(from: $0, key: "Watts") } ?? 0
        let adapterDescription = adapterDetails.flatMap { extractString(from: $0, key: "Description") }

        // Charger data
        let chargerData = extractDict(from: props, key: "ChargerData")
        let chargingVoltage = chargerData.flatMap { extractInt(from: $0, key: "ChargingVoltage") }
        let chargingCurrent = chargerData.flatMap { extractInt(from: $0, key: "ChargingCurrent") }
        let notChargingReason = chargerData.flatMap { extractInt(from: $0, key: "NotChargingReason") }
        let vacVoltageLimit = chargerData.flatMap { extractInt(from: $0, key: "VacVoltageLimit") }
            ?? packData.flatMap { extractInt(from: $0, key: "VacVoltageLimit") }

        let cellTelemetry = readBatteryCellTelemetry(packBatteryData: batteryData, registry: registry)
        let cellVoltages = cellTelemetry?.voltagesMV
        let qmax = cellTelemetry?.qmaxMAH
        let stateOfCharge = capacitySnapshot.stateOfCharge
        let dailyMinSoc = capacitySnapshot.dailyMinSoc
        let dailyMaxSoc = capacitySnapshot.dailyMaxSoc
        let chargeLimit = readChargeLimit(dailyMaxSoc, notChargingReason)
        let manufactureDate = parseBatteryManufactureDate(from: props)
            ?? registry.pack.flatMap { parseBatteryManufactureDate(from: $0) }

        // LifetimeData
        let packLifetimeData = packData.flatMap { extractDict(from: $0, key: "LifetimeData") } ?? [:]
        let lifetimeData = packLifetimeData.merging(
            batteryData.flatMap { extractDict(from: $0, key: "LifetimeData") } ?? [:]
        ) { _, main in main }
        let totalOpTime = extractInt(from: lifetimeData, key: "TotalOperatingTime")
        let ltMaxTemp = extractInt(from: lifetimeData, key: "MaximumTemperature")
        let ltMinTemp = extractInt(from: lifetimeData, key: "MinimumTemperature")
        let ltAvgTemp = extractInt(from: lifetimeData, key: "AverageTemperature")
        let ltMaxVoltage = extractInt(from: lifetimeData, key: "MaximumPackVoltage")
        let ltMinVoltage = extractInt(from: lifetimeData, key: "MinimumPackVoltage")
        func lifetimeCurrent(_ key: String) -> Int? {
            guard let value = extractInt(from: lifetimeData, key: key), (-100_000..<100_000).contains(value) else { return nil }
            return abs(value)
        }
        let ltMaxChargeCurrent = lifetimeCurrent("MaximumChargeCurrent")
        let ltMaxDischargeCurrent = lifetimeCurrent("MaximumDischargeCurrent")

        // PowerTelemetryData
        let telemetry = extractDict(from: props, key: "PowerTelemetryData")

        let buildResult: (
            _ systemPowerW: Double, _ batteryPowerW: Double,
            _ acInputW: Double,
            _ wallPowerW: Double?, _ adapterLossW: Double?,
            _ sysVoltage: Int?, _ sysCurrent: Int?,
            _ dataSource: PowerDataSource, _ isEstimated: Bool,
            _ hasACInputReading: Bool, _ hasConflict: Bool
        ) -> PowerData = { spw, bpw, aiw, wall, loss, sv, sc, ds, estimated, hasInput, conflict in
            var result = PowerData(
                systemPowerW: spw, batteryPowerW: bpw, acInputW: aiw,
                hasACInputReading: hasInput,
                acAdapterWattage: acAdapterWattage, batteryPercent: batteryPercent,
                isOnAC: isOnAC, isCharging: isOnAC && !conflict && bpw < -0.5, fullyCharged: fullyCharged,
                wallPowerW: wall, adapterEfficiencyLossW: loss,
                systemVoltageMV: sv, systemCurrentMA: sc,
                batteryVoltageMV: voltage, batteryAmperageMA: amperage,
                batteryTemperatureC: temperature.map { Double($0) / 100.0 },
                cycleCount: cycleCount, adapterDescription: adapterDescription,
                dataSource: ds, isPowerEstimated: estimated, hasPowerDataConflict: conflict, timestamp: Date(),
                batteryHealthPercent: batteryHealthPercent,
                designCapacityMAH: designCapacity, rawMaxCapacityMAH: rawMaxCapacity,
                nominalChargeCapacityMAH: nominalChargeCapacity,
                designCycleCount: designCycleCount,
                chargingVoltageMV: chargingVoltage, chargingCurrentMA: chargingCurrent,
                notChargingReason: notChargingReason, vacVoltageLimit: vacVoltageLimit,
                cellVoltagesMV: cellVoltages, stateOfCharge: stateOfCharge,
                qmaxMAH: qmax, dailyMinSoc: dailyMinSoc, dailyMaxSoc: dailyMaxSoc,
                totalOperatingTimeMin: totalOpTime,
                lifetimeMaxTempC: ltMaxTemp, lifetimeMinTempC: ltMinTemp,
                lifetimeAvgTempC: ltAvgTemp,
                lifetimeMaxPackVoltageMV: ltMaxVoltage,
                lifetimeMinPackVoltageMV: ltMinVoltage,
                lifetimeMaxChargeCurrentMA: ltMaxChargeCurrent,
                lifetimeMaxDischargeCurrentMA: ltMaxDischargeCurrent,
                batterySerial: batterySerial, deviceName: deviceName,
                instantAmperageMA: instantAmperage,
                atCriticalLevel: atCriticalLevel,
                permanentFailureStatus: permanentFailure,
                batteryCellDisconnectCount: cellDisconnectCount
            )
            result.batteryCellLayout = cellTelemetry?.layout
            result.batterySeriesGroups = cellTelemetry?.groups ?? []
            result.batteryParallelCellCurrents = cellTelemetry?.parallelCellCurrents
            result.chargeLimitPercent = chargeLimit.percent
            result.chargeLimitSource = chargeLimit.source
            result.remainingCapacityMAH = capacitySnapshot.remainingCapacityMAH
            result.fullChargeCapacityMAH = capacitySnapshot.fullChargeCapacityMAH
            result.avgTimeToEmptyMinutes = batteryData.flatMap { extractInt(from: $0, key: "AvgTimeToEmpty") }
                ?? extractInt(from: props, key: "AvgTimeToEmpty")
            result.avgTimeToFullMinutes = batteryData.flatMap { extractInt(from: $0, key: "AvgTimeToFull") }
                ?? extractInt(from: props, key: "AvgTimeToFull")
            result.batteryManufactureDate = manufactureDate
            if let telemetry,
               let accumulated = extractInt(from: telemetry, key: "AccumulatedSystemLoad"),
               let count = extractInt(from: telemetry, key: "SystemLoadAccumulatorCount"), count > 0, accumulated >= 0 {
                result.averageSystemPowerW = Double(accumulated) / Double(count) / 1000
            }
            return result
        }

        // Amperage is positive while charging and negative while discharging.
        // Preserve its sign (including a valid zero), then normalize to
        // PowerData's convention: positive = discharge, negative = charge.
        let currentBatteryPowerW: Double? = {
            guard let a = amperage, let v = voltage, v > 0 else { return nil }
            return -Double(a) * Double(v) / 1_000_000.0
        }()

        if let telem = telemetry {
            let systemLoad = extractInt(from: telem, key: "SystemLoad") ?? 0
            let systemPowerIn = extractInt(from: telem, key: "SystemPowerIn")
            let batteryPower = extractInt(from: telem, key: "BatteryPower")
            let wallEnergy = extractInt(from: telem, key: "WallEnergyEstimate")
            let adapterLoss = extractInt(from: telem, key: "AdapterEfficiencyLoss")
            let sysVoltage = extractInt(from: telem, key: "SystemVoltageIn")
            let sysCurrent = extractInt(from: telem, key: "SystemCurrentIn")

            // SystemPowerIn can retain its last non-zero sample after the
            // adapter is unplugged. ExternalConnected is the authoritative
            // source for whether AC is physically present, so discard stale
            // AC telemetry while running on battery.
            let reportedACInputW = systemPowerIn.map { max(0, Double($0) / 1000.0) }
            let acInputW = isOnAC ? (reportedACInputW ?? 0) : 0
            // IOKit BatteryPower uses positive values for charging and negative
            // values for discharging. PowerData exposes the opposite convention:
            // positive = discharge, negative = charge.
            let telemetryBatteryPowerW = batteryPower.map { -Double($0) / 1000.0 }
            // These groups can update at different times. Neither direction
            // is safe to present when both report significant opposing flows.
            let hasDirectionConflict: Bool = {
                guard let current = currentBatteryPowerW, let telemetry = telemetryBatteryPowerW else { return false }
                return (current > 0.5 && telemetry < -0.5)
                    || (current < -0.5 && telemetry > 0.5)
            }()
            let hasImpossibleBalance: Bool = {
                guard isOnAC, let input = reportedACInputW, let battery = telemetryBatteryPowerW else { return false }
                // A reported zero is not a missing field. Do not turn zero
                // input plus stale charging into an invented adapter output.
                return input + battery < -0.5
                    || (input == 0 && abs(battery) <= 0.5 && abs(systemLoad) > 500)
            }()
            let hasConflict = hasDirectionConflict || hasImpossibleBalance

            // AdapterDetails changes promptly, while the telemetry block may
            // remain frozen on the previous PD contract. During that window,
            // derive a conservative topology from current system load and the
            // new adapter rating. Also reject impossible telemetry such as a
            // 20 W adapter allegedly supplying 55 W.
            let telemetryExceedsAdapter = isOnAC
                && acAdapterWattage > 0
                && (reportedACInputW ?? 0) > Double(acAdapterWattage) * 1.1
            if useAdapterEstimate || telemetryExceedsAdapter {
                let estimatedSystemPowerW = abs(Double(systemLoad) / 1000.0)
                let estimatedACInputW = isOnAC
                    ? min(estimatedSystemPowerW, Double(acAdapterWattage))
                    : 0
                let estimatedBatteryPowerW = isOnAC
                    ? max(estimatedSystemPowerW - estimatedACInputW, 0)
                    : estimatedSystemPowerW

                return buildResult(
                    estimatedSystemPowerW,
                    estimatedBatteryPowerW,
                    estimatedACInputW,
                    wallEnergy.map { Double($0) / 1000.0 },
                    adapterLoss.map { Double($0) / 1000.0 },
                    sysVoltage,
                    sysCurrent,
                    .telemetry,
                    true,
                    false,
                    hasConflict
                )
            }

            // Prefer input and signed battery power from the SAME telemetry
            // block. System = AC input + discharge (or minus charging). Do not
            // mix input with an absolute current selected by a stale flag.
            var batteryPowerW = telemetryBatteryPowerW ?? currentBatteryPowerW ?? 0
            var systemPowerW = abs(Double(systemLoad) / 1000.0)
            let hasACInputReading = reportedACInputW != nil
            var isEstimated = telemetryBatteryPowerW == nil || reportedACInputW == nil
            if isOnAC {
                let balancedSystemPowerW = acInputW + batteryPowerW
                if hasACInputReading, balancedSystemPowerW >= 0,
                   acInputW > 0 || batteryPowerW > 0 || systemPowerW == 0 {
                    systemPowerW = balancedSystemPowerW
                } else {
                    // Use SystemLoad when input is missing. Contradictory
                    // measured input remains unavailable, never inferred.
                    isEstimated = true
                }
            } else {
                // Discard charging/input telemetry left over after unplugging.
                if let current = currentBatteryPowerW, current >= 0,
                   (reportedACInputW ?? 0) > 0 || batteryPowerW < 0 {
                    batteryPowerW = current
                }
                if batteryPowerW > 0 {
                    systemPowerW = batteryPowerW
                } else {
                    batteryPowerW = systemPowerW
                }
                isEstimated = isEstimated || (reportedACInputW ?? 0) > 0
                    || (telemetryBatteryPowerW ?? 0) < 0
            }

            // Fallback: if systemPowerW is still 0, try SystemVoltage×SystemCurrent
            if systemPowerW == 0, let sv = sysVoltage, let sc = sysCurrent, sv > 0, sc > 0 {
                systemPowerW = Double(sv) * Double(sc) / 1_000_000.0
            }

            return buildResult(
                systemPowerW, batteryPowerW, acInputW,
                wallEnergy.map { Double($0) / 1000.0 },
                adapterLoss.map { Double($0) / 1000.0 },
                sysVoltage, sysCurrent, .telemetry, isEstimated,
                hasACInputReading, hasConflict
            )
        }

        // Fallback: calculate from Amperage x Voltage
        let batteryPowerW = currentBatteryPowerW ?? 0
        let systemPowerW = max(batteryPowerW, 0)

        return buildResult(systemPowerW, batteryPowerW, 0, nil, nil, nil, nil, .legacy, true, false, false)
    }
}
