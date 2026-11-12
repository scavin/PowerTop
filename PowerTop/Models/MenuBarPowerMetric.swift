import Foundation

enum MenuBarPowerMetric: String, CaseIterable, Identifiable {
    case system
    case adapterInput
    case batteryNet
    case automatic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: String(localized: "System Power")
        case .adapterInput: String(localized: "Adapter Input")
        case .batteryNet: String(localized: "Battery Net")
        case .automatic: String(localized: "Automatic")
        }
    }

    var explanation: String {
        switch self {
        case .system: String(localized: "Computer operating power, excluding battery charging.")
        case .adapterInput: String(localized: "Total adapter power delivered to the Mac. Zero when unplugged.")
        case .batteryNet: String(localized: "Battery net power: + charging, − discharging.")
        case .automatic: String(localized: "Adapter input while charging; system power otherwise.")
        }
    }

    func formattedPower(from data: PowerData?, capped: Bool = false, showWarnings: Bool = false) -> String {
        let full = uncappedPower(from: data)
        guard let data, !data.hasPowerDataConflict else { return full }
        let watts: Double
        switch self {
        case .system: watts = data.systemPowerW
        case .adapterInput: watts = data.effectiveACOutputW
        case .batteryNet: watts = -data.batteryPowerW
        case .automatic: watts = data.isBatteryCharging ? data.effectiveACOutputW : data.systemPowerW
        }
        let exceedsCap = capped && abs(watts) > 99
        var text = full
        if exceedsCap, full != "— W" {
            let prefix = full.hasPrefix("≈") ? "≈" : ""
            text = prefix + (watts < 0 ? "≤−99W" : (self == .batteryNet ? "≥+99W" : "≥99W"))
        }
        if showWarnings, !data.isPowerEstimated, data.isSupplementalDischarge || exceedsCap {
            text = "⚠ " + text
        }
        return text
    }

    private func uncappedPower(from data: PowerData?) -> String {
        guard let data else { return "— W" }
        switch self {
        case .automatic:
            return (data.isBatteryCharging ? Self.adapterInput : Self.system).uncappedPower(from: data)
        case .system:
            return data.formattedPower(data.systemPowerW, compact: true)
        case .adapterInput:
            guard data.effectiveIsOnAC else { return "0.0W" }
            guard !data.hasPowerDataConflict else { return "— W" }
            // effectiveACOutputW can be inferred when adapter telemetry is
            // missing, even after the transition-estimation window has ended.
            let estimated = data.isPowerEstimated || !data.hasACInputReading
            return String(format: "%@%.1fW", estimated ? "≈" : "", data.effectiveACOutputW)
        case .batteryNet:
            guard !data.hasPowerDataConflict else { return "— W" }
            // PowerData uses positive for discharge; the UI's net-flow sign
            // uses positive for power entering the battery instead.
            let watts = data.isBatteryCharging ? data.batteryChargeRateW : -data.batteryPowerW
            // A stale charging sample must not claim charging after unplugging.
            guard data.effectiveIsOnAC || watts <= 0 else { return "— W" }
            let magnitude = abs(watts) < 0.05 ? 0 : abs(watts)
            let sign = magnitude == 0 ? "" : (watts > 0 ? "+" : "−")
            return String(format: "%@%@%.1fW", data.isPowerEstimated ? "≈" : "", sign, magnitude)
        }
    }
}
