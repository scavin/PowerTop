import SwiftUI
import AppKit
import BatteryView

// Use BatteryView's unmodified SFSymbolStyle and Multicolor configuration.
// Keep its font, masks, fill geometry, and colors. Disable its legacy implicit
// spring so opening the popover does not animate the initial layout into place.
struct BatteryIconView: View {
    let percentage: Int
    let isCharging: Bool
    var width: CGFloat = 28

    var body: some View {
        Battery(
            .constant(Float(min(max(percentage, 0), 100)) / 100),
            .constant(isCharging ? .charging : .unplugged)
        )
        .batteryStyle(SFSymbolStyle(animation: nil))
        .frame(width: width, height: width / 2.15)
        // Reserve space outside the original drawing for the charging bolt's
        // optical overshoot; never crop or change the library's inner geometry.
        .padding(.vertical, width * 0.06)
        .fixedSize()
        .accessibilityLabel(Text("\(String(localized: "Battery Level")) \(min(max(percentage, 0), 100))%"))
        .transaction {
            $0.animation = nil
            $0.disablesAnimations = true
        }
    }
}

// MenuBarExtra reliably supports Image/Text labels. Render the custom SwiftUI
// drawing to an image, and cache by battery state rather than by power sample.
@MainActor
enum MenuBarBatteryIcon {
    private static let cache = NSCache<NSString, NSImage>()
    private static let canvasSize = NSSize(width: 30, height: 18)

    static func image(percentage: Int, isCharging: Bool, colorScheme: ColorScheme = .light) -> NSImage {
        let percent = min(max(percentage, 0), 100)
        let key = "\(percent)-\(isCharging)-\(colorScheme)" as NSString
        if let image = cache.object(forKey: key) { return image }

        let renderer = ImageRenderer(content:
            BatteryIconView(percentage: percent, isCharging: isCharging)
                .frame(width: canvasSize.width, height: canvasSize.height)
                .environment(\.colorScheme, colorScheme)
        )
        renderer.scale = 4
        guard let bitmap = renderer.cgImage else {
            let step = Int((Double(percent) / 25).rounded()) * 25
            // Never cache a renderer failure as a permanent empty battery.
            return NSImage(
                systemSymbolName: isCharging ? "battery.100.bolt" : "battery.\(step)",
                accessibilityDescription: nil
            )!
        }
        let image = NSImage(cgImage: bitmap, size: canvasSize)
        image.isTemplate = !isCharging && percent > 20
        cache.setObject(image, forKey: key)
        return image
    }
}
