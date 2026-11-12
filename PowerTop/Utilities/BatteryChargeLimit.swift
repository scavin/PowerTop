import Foundation
import AppKit

enum BatteryChargeLimitSource: Equatable {
    case none
    case macOSSetting
    case optimizedCharging
    case alDente
}

struct ResolvedBatteryChargeLimit: Equatable {
    let percent: Int
    let source: BatteryChargeLimitSource

    static let full = ResolvedBatteryChargeLimit(percent: 100, source: .none)
}

private let optimizedChargingPauseReason: Int = 0x0100_0000

/// Resolves the effective charge target for time-to-full estimates.
func readResolvedBatteryChargeLimit(dailyMaxSoc: Int?, notChargingReason: Int?) -> ResolvedBatteryChargeLimit {
    resolveBatteryChargeLimit(dailyMaxSoc: dailyMaxSoc, notChargingReason: notChargingReason,
                              macOSLimit: readMacOSChargeLimitPercent(), alDenteLimit: readAlDenteChargeLimitPercent())
}

func resolveBatteryChargeLimit(
    dailyMaxSoc: Int?, notChargingReason: Int? = nil,
    macOSLimit: Int? = nil, alDenteLimit: Int? = nil
) -> ResolvedBatteryChargeLimit {
    let limits: [(Int?, BatteryChargeLimitSource)] = [(macOSLimit, .macOSSetting), (alDenteLimit, .alDente)]
    let active = limits.compactMap { value, source -> ResolvedBatteryChargeLimit? in
        guard let value, (1..<100).contains(value) else { return nil }
        return ResolvedBatteryChargeLimit(percent: value, source: source)
    }
    if let strictest = active.min(by: { $0.percent < $1.percent }) { return strictest }
    if isOptimizedChargingHoldActive(notChargingReason: notChargingReason),
       let maxSoc = dailyMaxSoc, (1..<100).contains(maxSoc) {
        return ResolvedBatteryChargeLimit(percent: maxSoc, source: .optimizedCharging)
    }
    return .full
}

func chargeLimitSourceLabel(_ source: BatteryChargeLimitSource) -> String? {
    switch source {
    case .none: return nil
    case .macOSSetting: return String(localized: "macOS setting")
    case .optimizedCharging: return String(localized: "Optimized Charging")
    case .alDente: return "AlDente"
    }
}

private func isOptimizedChargingHoldActive(notChargingReason: Int?) -> Bool {
    guard let reason = notChargingReason else { return false }
    return reason & optimizedChargingPauseReason != 0
}

private func readMacOSChargeLimitPercent() -> Int? {
    let domain = "com.apple.batteryui.charging.mac"
    let keys = [
        "com.apple.batteryui.charging.mac.limit",
        "limit",
    ]
    for key in keys {
        if let value = readPreferenceNumber(domain: domain, key: key) {
            return normalizedChargeLimitPercent(value)
        }
    }
    return nil
}

private func readAlDenteChargeLimitPercent() -> Int? {
    if let limit = readAlDenteProChargeLimitPercent() {
        return limit
    }
    let bundleID = "com.davidwernhart.AlDente"
    guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else { return nil }
    return readThirdPartyChargeLimitPercent(bundleID: bundleID, key: "chargeVal")
}

private func readAlDenteProChargeLimitPercent() -> Int? {
    let bundleID = "com.apphousekitchen.aldente-pro"
    guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else { return nil }
    if readPreferenceBool(domain: bundleID, key: "useTahoeNativeLimit") == true {
        return nil
    }
    return readThirdPartyChargeLimitPercent(bundleID: bundleID, key: "chargeVal")
}

private func readThirdPartyChargeLimitPercent(bundleID: String, key: String) -> Int? {
    normalizedChargeLimitPercent(readPreferenceNumber(domain: bundleID, key: key))
}

private func readPreferenceNumber(domain: String, key: String) -> Int? {
    if let value = CFPreferencesCopyAppValue(key as CFString, domain as CFString) {
        if let number = value as? NSNumber { return number.intValue }
        if let intValue = value as? Int { return intValue }
        if let doubleValue = value as? Double { return Int(doubleValue.rounded()) }
    }

    let plistName = domain.hasSuffix(".plist") ? domain : "\(domain).plist"
    let paths = [
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(plistName)").path,
        NSHomeDirectory() + "/Library/Preferences/" + plistName,
    ]
    for path in paths {
        guard let dict = NSDictionary(contentsOfFile: path) as? [String: Any],
              let value = dict[key] else { continue }
        if let intValue = value as? Int { return intValue }
        if let number = value as? NSNumber { return number.intValue }
        if let doubleValue = value as? Double { return Int(doubleValue.rounded()) }
    }
    return nil
}

private func readPreferenceBool(domain: String, key: String) -> Bool? {
    if let value = CFPreferencesCopyAppValue(key as CFString, domain as CFString) {
        if let boolValue = value as? Bool { return boolValue }
        if let number = value as? NSNumber { return number.boolValue }
    }

    let plistName = domain.hasSuffix(".plist") ? domain : "\(domain).plist"
    let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Preferences/\(plistName)").path
    guard let dict = NSDictionary(contentsOfFile: path) as? [String: Any],
          let value = dict[key] else { return nil }
    if let boolValue = value as? Bool { return boolValue }
    if let number = value as? NSNumber { return number.boolValue }
    return nil
}

private func normalizedChargeLimitPercent(_ value: Int?) -> Int? {
    guard let value, (1..<100).contains(value) else { return nil }
    return value
}