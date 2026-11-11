import XCTest
import AppKit
@testable import PowerTop

final class PopoverAnchorTests: XCTestCase {
    @MainActor
    func testBatteryModeShrinkKeepsTopNextToMenuBar() async {
        let result = MenuBarPopoverAnchor.frameKeepingTopEdge(
            NSRect(x: 900, y: 250, width: 280, height: 360),
            at: 790,
            screen: NSRect(x: 0, y: 0, width: 1440, height: 800)
        )
        XCTAssertEqual(result.maxY, 790)
        XCTAssertEqual(result.minY, 430)
        XCTAssertEqual(result.minX, 900)
        XCTAssertEqual(result.size, NSSize(width: 280, height: 360))
    }

    @MainActor
    func testChargingModeGrowthKeepsTheSameTopEdge() async {
        let result = MenuBarPopoverAnchor.frameKeepingTopEdge(
            NSRect(x: 900, y: 430, width: 280, height: 540),
            at: 790,
            screen: NSRect(x: 0, y: 0, width: 1440, height: 800)
        )
        XCTAssertEqual(result.maxY, 790)
        XCTAssertEqual(result.minY, 250)
    }

    @MainActor
    func testResizingOnSecondDisplayUsesItsScreenCoordinates() async {
        let result = MenuBarPopoverAnchor.frameKeepingTopEdge(
            NSRect(x: -1200, y: -400, width: 280, height: 360),
            at: 390,
            screen: NSRect(x: -1440, y: -500, width: 1440, height: 900)
        )
        XCTAssertEqual(result.maxY, 390)
        XCTAssertEqual(result.minX, -1200)
    }

    @MainActor
    func testTallContentStaysWithinTheScreenBottom() async {
        let result = MenuBarPopoverAnchor.frameKeepingTopEdge(
            NSRect(x: 900, y: 0, width: 280, height: 900),
            at: 790,
            screen: NSRect(x: 0, y: 0, width: 1440, height: 800)
        )
        XCTAssertEqual(result.minY, 0)
    }

    @MainActor
    func testWindowResizeNotificationPreservesTopAndStopsAfterDismissal() async {
        // Exercise actual AppKit resizing without ordering a test window onto
        // the user's desktop. Only visibility is stubbed for this test.
        final class TestWindow: NSWindow {
            override var isVisible: Bool { true }
        }
        let window = TestWindow(
            contentRect: NSRect(x: 100, y: 100, width: 280, height: 500),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let anchor = MenuBarPopoverAnchor.AnchorView()
        anchor.isPresented = true
        window.contentView = anchor
        NotificationCenter.default.post(name: NSWindow.didExposeNotification, object: window)
        let top = window.frame.maxY

        window.setFrame(NSRect(x: 100, y: 100, width: 280, height: 300), display: false)
        NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: window)
        XCTAssertEqual(window.frame.maxY, top, accuracy: 0.5)

        anchor.isPresented = false
        window.setFrame(NSRect(x: 100, y: 100, width: 280, height: 250), display: false)
        NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: window)
        XCTAssertEqual(window.frame.minY, 100, accuracy: 0.5)
        anchor.stopObserving()
        window.contentView = nil
        window.close()
    }
}
