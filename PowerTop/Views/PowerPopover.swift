import AppKit
import Observation
import SwiftUI

/// AppKit owns the menu-bar anchor and rounded background. Update its actual
/// content size when SwiftUI removes or adds power-data rows.
@MainActor
final class PowerPopover: NSObject, NSPopoverDelegate {
    let popover = NSPopover()
    let hostingController: NSHostingController<PopoverView>
    private let monitor: PowerMonitor
    private let preferences: DisplayPreferences
    private weak var anchorButton: NSStatusBarButton?
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?
    private var menuObservers: [NSObjectProtocol] = []
    private var trackingMenus: Set<ObjectIdentifier> = []
    private var anchorObservers: [NSObjectProtocol] = []
    private var reanchorPending = false
    private var stopped = false

    init(monitor: PowerMonitor, preferences: DisplayPreferences, openDetails: @escaping () -> Void) {
        self.monitor = monitor
        self.preferences = preferences
        hostingController = NSHostingController(rootView: PopoverView(monitor: monitor, preferences: preferences, openDetails: openDetails))
        super.init()
        hostingController.sizingOptions = [.preferredContentSize]
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = hostingController
        popover.delegate = self
        observeContent()
    }

    private func observeContent() {
        guard !stopped else { return }
        withObservationTracking {
            _ = monitor.currentData
            _ = monitor.hasData
            _ = preferences.showMenuBarPower
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
        scheduleReanchor()
    }

    func toggle(from button: NSStatusBarButton) {
        guard !stopped else { return }
        observeAnchor(button)
        if popover.isShown {
            popover.performClose(nil)
        } else {
            updateContentSize()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            startDismissMonitors()
        }
    }

    private func observeAnchor(_ button: NSStatusBarButton) {
        guard anchorButton !== button else { return }
        anchorObservers.forEach { NotificationCenter.default.removeObserver($0) }
        anchorObservers.removeAll()
        anchorButton = button
        button.postsFrameChangedNotifications = true
        var anchors: [(Notification.Name, AnyObject)] = [(NSView.frameDidChangeNotification, button)]
        if let window = button.window { anchors.append((NSWindow.didMoveNotification, window)) }
        for (name, object) in anchors {
            anchorObservers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.scheduleReanchor() }
            })
        }
    }

    func scheduleReanchor() {
        guard popover.isShown, !reanchorPending, !stopped else { return }
        reanchorPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reanchorPending = false
            guard !self.stopped, self.popover.isShown, let button = self.anchorButton else { return }
            button.window?.contentView?.layoutSubtreeIfNeeded()
            self.popover.positioningRect = button.bounds
            self.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func startDismissMonitors() {
        stopDismissMonitors()
        for name in [NSMenu.didBeginTrackingNotification, NSMenu.didEndTrackingNotification] {
            menuObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let menu = notification.object as? NSMenu else { return }
                MainActor.assumeIsolated { () -> Void in
                    if name == NSMenu.didBeginTrackingNotification {
                        self?.trackingMenus.insert(ObjectIdentifier(menu))
                    } else {
                        self?.trackingMenus.remove(ObjectIdentifier(menu))
                    }
                }
            })
        }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            // Picker and settings menus can extend beyond the popover's frame.
            // Decide before AppKit ends menu tracking for the selected item.
            guard MainActor.assumeIsolated({ self?.trackingMenus.isEmpty != false }) else { return event }
            let point = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
            Task { @MainActor in self?.dismissIfOutside(point) }
            return event
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            let point = NSEvent.mouseLocation
            Task { @MainActor in self?.dismissIfOutside(point) }
        }
    }

    private func dismissIfOutside(_ point: NSPoint) {
        guard popover.isShown else { return }
        if let window = popover.contentViewController?.view.window, window.frame.contains(point) { return }
        if let button = anchorButton, let window = button.window,
           window.convertToScreen(button.convert(button.bounds, to: nil)).contains(point) { return }
        popover.performClose(nil)
    }

    private func stopDismissMonitors() {
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        localClickMonitor = nil
        globalClickMonitor = nil
        menuObservers.forEach { NotificationCenter.default.removeObserver($0) }
        menuObservers.removeAll()
        trackingMenus.removeAll()
    }

    func popoverDidClose(_ notification: Notification) {
        stopDismissMonitors()
        anchorButton?.highlight(false)
    }

    func stop() {
        stopped = true
        stopDismissMonitors()
        anchorObservers.forEach { NotificationCenter.default.removeObserver($0) }
        anchorObservers.removeAll()
        popover.close()
    }
}
