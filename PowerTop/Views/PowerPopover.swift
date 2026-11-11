import AppKit
import Observation
import SwiftUI

/// AppKit owns the menu-bar anchor and rounded background. Update its actual
/// content size when SwiftUI removes or adds power-data rows.
@MainActor
final class PowerPopover {
    let popover = NSPopover()
    let hostingController: NSHostingController<PopoverView>
    private let monitor: PowerMonitor

    init(monitor: PowerMonitor, preferences: DisplayPreferences, openDetails: @escaping () -> Void) {
        self.monitor = monitor
        hostingController = NSHostingController(rootView: PopoverView(monitor: monitor, preferences: preferences, openDetails: openDetails))
        hostingController.sizingOptions = [.preferredContentSize]
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = hostingController
        observeContent()
    }

    private func observeContent() {
        withObservationTracking {
            _ = monitor.currentData
            _ = monitor.hasData
        } onChange: { [weak self] in
            // Observation fires before assignment. Measure after SwiftUI has
            // received the new sample, outside its current layout transaction.
            DispatchQueue.main.async {
                self?.updateContentSize()
                self?.observeContent()
            }
        }
        updateContentSize()
    }

    private func updateContentSize() {
        hostingController.view.layoutSubtreeIfNeeded()
        let size = hostingController.view.fittingSize
        guard size.width > 0, size.height > 0, popover.contentSize != size else { return }
        popover.contentSize = size
    }

    func toggle(from button: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            updateContentSize()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
