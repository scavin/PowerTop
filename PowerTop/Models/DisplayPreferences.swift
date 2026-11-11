import Foundation
import Observation

@MainActor
@Observable
final class DisplayPreferences {
    private let defaults: UserDefaults

    var showMenuBarPower: Bool {
        didSet { defaults.set(showMenuBarPower, forKey: "showMenuBarPower") }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showMenuBarPower = defaults.bool(forKey: "showMenuBarPower")
    }
}
