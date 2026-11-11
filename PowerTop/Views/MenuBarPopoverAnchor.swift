import SwiftUI
import AppKit

/// MenuBarExtra can resize its window while keeping the lower edge fixed.
/// Keep the original top edge when conditional rows change the content height.
struct MenuBarPopoverAnchor: NSViewRepresentable {
    let isPresented: Bool

    func makeNSView(context: Context) -> AnchorView { AnchorView() }

    func updateNSView(_ nsView: AnchorView, context: Context) {
        nsView.isPresented = isPresented
    }

    static func dismantleNSView(_ nsView: AnchorView, coordinator: ()) {
        nsView.stopObserving()
    }

    static func frameKeepingTopEdge(_ frame: NSRect, at topEdge: CGFloat, screen: NSRect?) -> NSRect {
        var result = frame
        result.origin.y = topEdge - frame.height
        if let screen { result.origin.y = max(result.origin.y, screen.minY) }
        return result
    }

    final class AnchorView: NSView {
        var isPresented = false {
            didSet {
                if !isPresented { topEdge = nil }
            }
        }

        private var topEdge: CGFloat?
        private var observers: [NSObjectProtocol] = []
        private var isRepositioning = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard let window else { return }
            let center = NotificationCenter.default
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didExposeNotification, NSWindow.didUpdateNotification] {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.captureTopEdgeIfNeeded() }
                })
            }
            observers.append(center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.keepTopEdge() }
            })
            for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.topEdge = nil }
                })
            }
        }

        func stopObserving() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            topEdge = nil
        }

        private func captureTopEdgeIfNeeded() {
            guard isPresented, let window, window.isVisible, topEdge == nil else { return }
            // Capture after AppKit has positioned the newly shown popover,
            // rather than using its temporary frame during construction.
            topEdge = window.frame.maxY
        }

        private func keepTopEdge() {
            guard isPresented, let window, window.isVisible,
                  let topEdge, !isRepositioning else { return }
            let frame = MenuBarPopoverAnchor.frameKeepingTopEdge(
                window.frame, at: topEdge, screen: window.screen?.visibleFrame
            )
            guard abs(frame.minY - window.frame.minY) > 0.5 else { return }
            isRepositioning = true
            window.setFrameOrigin(frame.origin)
            isRepositioning = false
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}
