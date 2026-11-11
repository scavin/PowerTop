import Foundation

enum MenuBarPowerMetric: String, CaseIterable, Identifiable {
    case system
    case adapterInput
    case batteryNet

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: String(localized: "System Power")
        case .adapterInput: String(localized: "Adapter Input")
        case .batteryNet: String(localized: "Battery Net")
        }
    }

    var explanation: String {
        switch self {
        case .system: String(localized: "Computer operating power, excluding battery charging.")
        case .adapterInput: String(localized: "Total adapter power delivered to the Mac. Zero when unplugged.")
        case .batteryNet: String(localized: "Battery net power: + charging, − discharging.")
        }
    }

    func formattedPower(from data: PowerData?) -> String {
        guard let data else { return "— W" }
        switch self {
        case .system:
            return data.formattedPower(data.systemPowerW, compact: true)
        case .adapterInput:
            guard data.effectiveIsOnAC else { return "0.0W" }
            // effectiveACOutputW can be inferred when adapter telemetry is
            // missing, even after the transition-estimation window has ended.
            let estimated = data.isPowerEstimated || data.acInputW <= 0
            return String(format: "%@%.1fW", estimated ? "≈" : "", data.effectiveACOutputW)
        case .batteryNet:
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
