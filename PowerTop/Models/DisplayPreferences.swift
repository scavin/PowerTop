import Foundation
import Observation

@MainActor
@Observable
final class DisplayPreferences {
    private let defaults: UserDefaults

    var showMenuBarPower: Bool {
        didSet { defaults.set(showMenuBarPower, forKey: "showMenuBarPower") }
    }

    var menuBarPowerMetric: MenuBarPowerMetric {
        didSet { defaults.set(menuBarPowerMetric.rawValue, forKey: "menuBarPowerMetric") }
    }

    var capMenuBarPower: Bool {
        didSet { defaults.set(capMenuBarPower, forKey: "capMenuBarPower") }
    }

    var showPowerWarnings: Bool {
        didSet { defaults.set(showPowerWarnings, forKey: "showPowerWarnings") }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showMenuBarPower = defaults.bool(forKey: "showMenuBarPower")
        menuBarPowerMetric = defaults.string(forKey: "menuBarPowerMetric")
            .flatMap(MenuBarPowerMetric.init(rawValue:)) ?? .system
        capMenuBarPower = defaults.bool(forKey: "capMenuBarPower")
        showPowerWarnings = defaults.bool(forKey: "showPowerWarnings")
    }
}
