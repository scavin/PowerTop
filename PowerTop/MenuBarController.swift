import AppKit
import Observation
import SwiftUI

@MainActor
final class MenuBarController: NSObject {
    private let monitor: PowerMonitor
    private let preferences = DisplayPreferences()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var appearanceObservation: NSKeyValueObservation?
    private var detailWindowController: NSWindowController?
    private lazy var powerPopover = PowerPopover(monitor: monitor, preferences: preferences) { [weak self] in self?.openDetails() }
    private var stopped = false

    init(monitor: PowerMonitor) {
        self.monitor = monitor
        super.init()
        statusItem.autosaveName = "PowerTop"
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(togglePopover)
        button.imagePosition = .imageLeading
        button.font = .monospacedDigitSystemFont(ofSize: button.font?.pointSize ?? NSFont.systemFontSize, weight: .regular)
        button.setAccessibilityLabel("PowerTop")
        appearanceObservation = button.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.updateLabel() }
        }
        observePower()
    }

    private func observePower() {
        guard !stopped else { return }
        withObservationTracking {
            updateLabel()
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.observePower() }
        }
    }

    private func updateLabel() {
        guard !stopped, let button = statusItem.button else { return }
        let data = monitor.currentData
        let isDark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        button.image = monitor.hasData
            ? MenuBarBatteryIcon.image(percentage: data.batteryPercent,
                                       isCharging: monitor.isOnExternalPower,
                                       colorScheme: isDark ? .dark : .light)
            : NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: nil)
        let metric = preferences.menuBarPowerMetric
        let power = metric.formattedPower(from: monitor.hasData ? data : nil)
        button.title = preferences.showMenuBarPower ? " " + power : ""
        button.toolTip = preferences.showMenuBarPower
            ? "\(metric.title): \(power)\n\(metric.explanation)\n\(data.powerSourceDescription)"
            : data.powerSourceDescription
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        powerPopover.toggle(from: button)
    }

    private func openDetails() {
        powerPopover.popover.performClose(nil)
        if detailWindowController == nil {
            let controller = NSHostingController(rootView: DetailWindowView(monitor: monitor))
            let window = NSWindow(contentViewController: controller)
            window.title = String(localized: "PowerTop Details")
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 560, height: 640))
            window.contentMinSize = NSSize(width: 520, height: 500)
            window.isReleasedWhenClosed = false
            window.center()
            detailWindowController = NSWindowController(window: window)
        }
        detailWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func stop() {
        stopped = true
        appearanceObservation = nil
        powerPopover.popover.close()
        detailWindowController?.close()
        NSStatusBar.system.removeStatusItem(statusItem)
    }
}
