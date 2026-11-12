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
    private var renderedLabelSignature = ""

    init(monitor: PowerMonitor) {
        self.monitor = monitor
        super.init()
        statusItem.autosaveName = "PowerTop"
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(togglePopover)
        button.sendAction(on: [.leftMouseDown])
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
        let metric = preferences.menuBarPowerMetric
        let power = metric.formattedPower(from: monitor.hasData ? data : nil,
                                          capped: preferences.capMenuBarPower,
                                          showWarnings: preferences.showPowerWarnings)
        let signature = "\(monitor.hasData)|\(data.batteryPercent)|\(monitor.isOnExternalPower)|\(isDark)|\(preferences.showMenuBarPower)|\(power)"
        if signature != renderedLabelSignature {
            renderedLabelSignature = signature
            button.image = monitor.hasData
                ? MenuBarBatteryIcon.image(percentage: data.batteryPercent,
                                           isCharging: monitor.isOnExternalPower,
                                           colorScheme: isDark ? .dark : .light)
                : NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: nil)
            button.title = preferences.showMenuBarPower ? " " + power : ""
            let textWidth = (button.title as NSString).size(withAttributes: [.font: button.font ?? NSFont.systemFont(ofSize: 12)]).width
            let nextWidth = max(24, ceil(textWidth + (button.image?.size.width ?? 0)) + 12)
            if abs(statusItem.length - nextWidth) > 0.5 {
                statusItem.length = nextWidth
                powerPopover.scheduleReanchor()
            }
        }
        let fullPower = metric.formattedPower(from: monitor.hasData ? data : nil)
        if monitor.hasData {
            button.toolTip = preferences.showMenuBarPower
                ? "\(data.batteryPercent)% · \(metric.title): \(fullPower)\n\(metric.explanation)\n\(data.powerSourceDescription)"
                : "\(data.batteryPercent)% · \(data.powerSourceDescription)"
        } else {
            button.toolTip = String(localized: "Reading Power Data")
        }
        button.setAccessibilityLabel(button.toolTip)
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        DispatchQueue.main.async { [weak self] in self?.powerPopover.toggle(from: button) }
    }

    private func openDetails() {
        powerPopover.popover.performClose(nil)
        if detailWindowController == nil {
            let controller = NSHostingController(rootView: DetailWindowView(monitor: monitor))
            let window = NSWindow(contentViewController: controller)
            window.title = String(localized: "PowerTop Details")
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: DetailWindowView.preferredWidth, height: 640))
            window.contentMinSize = NSSize(width: DetailWindowView.preferredWidth, height: 500)
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
        powerPopover.stop()
        detailWindowController?.close()
        NSStatusBar.system.removeStatusItem(statusItem)
    }
}
