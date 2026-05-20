import Foundation
import IOKit

func getIOServiceProperties(className: String) -> [String: Any]? {
    let matching = IOServiceMatching(className)
    var iterator: io_iterator_t = 0

    let kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
    guard kr == KERN_SUCCESS else { return nil }
    defer { IOObjectRelease(iterator) }

    let service = IOIteratorNext(iterator)
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }

    var properties: Unmanaged<CFMutableDictionary>?
    let propResult = IORegistryEntryCreateCFProperties(
        service,
        &properties,
        kCFAllocatorDefault,
        0
    )
    guard propResult == KERN_SUCCESS, let props = properties?.takeRetainedValue() else {
        return nil
    }

    return props as? [String: Any]
}

func extractInt(from dict: [String: Any], key: String) -> Int? {
    guard let value = dict[key] else { return nil }
    if let intVal = value as? Int { return intVal }
    // Handle UInt64 overflow: IOKit stores some signed values (e.g. BatteryPower) as UInt64.
    // A negative value like -15034 gets stored as 18446744073709536582 (UInt64).
    // `as? Int` fails because it exceeds Int64.max, so we must use bitPattern conversion.
    if let uint64Val = value as? UInt64 {
        return Int(Int64(bitPattern: uint64Val))
    }
    if let numVal = value as? NSNumber { return numVal.intValue }
    return nil
}

func extractBool(from dict: [String: Any], key: String) -> Bool? {
    guard let value = dict[key] else { return nil }
    if let boolVal = value as? Bool { return boolVal }
    if let numVal = value as? NSNumber { return numVal.boolValue }
    return nil
}

func extractString(from dict: [String: Any], key: String) -> String? {
    return dict[key] as? String
}

func extractDict(from dict: [String: Any], key: String) -> [String: Any]? {
    return dict[key] as? [String: Any]
}

func extractIntArray(from dict: [String: Any], key: String) -> [Int]? {
    guard let value = dict[key] else { return nil }
    if let arr = value as? [Int] { return arr }
    if let arr = value as? [NSNumber] { return arr.map { $0.intValue } }
    return nil
}
