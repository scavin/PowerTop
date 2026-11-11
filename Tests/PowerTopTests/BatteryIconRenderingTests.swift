import XCTest
import SwiftUI
import AppKit
@testable import PowerTop

final class BatteryIconRenderingTests: XCTestCase {
    func testChargingIconHasNeutralShellGreenFillAndBlackBolt() async {
        await MainActor.run {
            let renderer = ImageRenderer(content:
                BatteryIconView(percentage: 73, isCharging: true, width: 100)
                    .padding(4)
                    .background(.white)
                    .environment(\.colorScheme, .light)
            )
            renderer.scale = 2
            guard let image = renderer.cgImage else {
                XCTFail("Could not render charging battery")
                return
            }
            let bitmap = NSBitmapImageRep(cgImage: image)
            var green = 0
            var gray = 0
            var black = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    if c.greenComponent > c.redComponent + 0.2,
                       c.greenComponent > c.blueComponent + 0.2 { green += 1 }
                    if abs(c.redComponent - c.greenComponent) < 0.02,
                       abs(c.greenComponent - c.blueComponent) < 0.02,
                       c.redComponent > 0.3, c.redComponent < 0.7 { gray += 1 }
                    if max(c.redComponent, c.greenComponent, c.blueComponent) < 0.2 { black += 1 }
                }
            }
            XCTAssertGreaterThan(green, 100, "The capacity fill should be green")
            XCTAssertGreaterThan(gray, 100, "The shell should remain neutral gray")
            XCTAssertGreaterThan(black, 100, "The bolt should remain black in light appearance")
        }
    }

    func testChargingBoltHasSpaceAboveAndBelowAtAppAndMenuSizes() async {
        await MainActor.run {
            for width: CGFloat in [18, 28, 30] {
                let renderer = ImageRenderer(content:
                    BatteryIconView(percentage: 73, isCharging: true, width: width)
                )
                renderer.scale = 3
                guard let image = renderer.cgImage else {
                    XCTFail("Could not render battery at width \(width)")
                    continue
                }
                let bitmap = NSBitmapImageRep(cgImage: image)
                for x in 0..<bitmap.pixelsWide {
                    XCTAssertLessThan(bitmap.colorAt(x: x, y: 0)?.alphaComponent ?? 1, 0.01,
                                      "The bolt should not touch the top edge at width \(width)")
                    XCTAssertLessThan(bitmap.colorAt(x: x, y: bitmap.pixelsHigh - 1)?.alphaComponent ?? 1, 0.01,
                                      "The bolt should not touch the bottom edge at width \(width)")
                }
            }
        }
    }

    func testMenuBarImageHasTransparentMarginsOnEverySide() async {
        await MainActor.run {
            let image = MenuBarBatteryIcon.image(percentage: 73, isCharging: true)
            XCTAssertEqual(image.size, NSSize(width: 30, height: 18))
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                XCTFail("Could not read menu bar bitmap")
                return
            }
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            for x in 0..<bitmap.pixelsWide {
                XCTAssertLessThan(bitmap.colorAt(x: x, y: 0)?.alphaComponent ?? 1, 0.01)
                XCTAssertLessThan(bitmap.colorAt(x: x, y: bitmap.pixelsHigh - 1)?.alphaComponent ?? 1, 0.01)
            }
            for y in 0..<bitmap.pixelsHigh {
                XCTAssertLessThan(bitmap.colorAt(x: 0, y: y)?.alphaComponent ?? 1, 0.01)
                XCTAssertLessThan(bitmap.colorAt(x: bitmap.pixelsWide - 1, y: y)?.alphaComponent ?? 1, 0.01)
            }
        }
    }
}
