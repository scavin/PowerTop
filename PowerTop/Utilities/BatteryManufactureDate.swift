import Foundation

func parseBatteryManufactureDate(from properties: [String: Any]) -> String? {
    let batteryData = extractDict(from: properties, key: "BatteryData")
    guard let encodedDate = extractInt(from: properties, key: "ManufactureDate")
        ?? batteryData.flatMap({ extractInt(from: $0, key: "ManufactureDate") }) else {
        return nil
    }
    return formatBatteryManufactureDate(encodedDate)
}

/// Decodes the six reversed ASCII digits used by recent Apple Silicon battery packs.
///
/// The decoded digits are `YYMMDD`, where `YY` is years since 1992. Apple does not
/// document this representation, so reject values that are not exact, valid, and non-future.
func formatBatteryManufactureDate(
    _ encodedDate: Int,
    relativeTo currentDate: Date = Date()
) -> String? {
    guard encodedDate > 0 else { return nil }
    let rawValue = UInt64(encodedDate)
    guard rawValue <= 0xFFFF_FFFF_FFFF else { return nil }

    func asciiDigit(at shift: Int) -> Int? {
        let byte = UInt8((rawValue >> shift) & 0xFF)
        guard (48...57).contains(byte) else { return nil }
        return Int(byte - 48)
    }

    guard let yearTens = asciiDigit(at: 0),
          let yearOnes = asciiDigit(at: 8),
          let monthTens = asciiDigit(at: 16),
          let monthOnes = asciiDigit(at: 24),
          let dayTens = asciiDigit(at: 32),
          let dayOnes = asciiDigit(at: 40) else {
        return nil
    }

    let year = 1992 + yearTens * 10 + yearOnes
    let month = monthTens * 10 + monthOnes
    let day = dayTens * 10 + dayOnes

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    var components = DateComponents()
    components.calendar = calendar
    components.timeZone = calendar.timeZone
    components.year = year
    components.month = month
    components.day = day

    guard let date = calendar.date(from: components), date <= currentDate else { return nil }
    let validated = calendar.dateComponents([.year, .month, .day], from: date)
    guard validated.year == year, validated.month == month, validated.day == day else {
        return nil
    }

    return String(format: "%04d-%02d-%02d", year, month, day)
}

