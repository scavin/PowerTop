import SwiftUI
import AppKit
import BatteryView

// Use BatteryView's unmodified SFSymbolStyle and Multicolor configuration.
// Its font, masks, fill geometry, colors, and animation remain in the library.
struct BatteryIconView: View {
    let percentage: Int
    let isCharging: Bool
    var width: CGFloat = 28

    var body: some View {
        Battery(
            .constant(Float(min(max(percentage, 0), 100)) / 100),
            .constant(isCharging ? .charging : .unplugged)
        )
        .batteryStyle(SFSymbolStyle())
        .frame(width: width, height: width / 2.15)
        // Reserve space outside the original drawing for the charging bolt's
        // optical overshoot; never crop or change the library's inner geometry.
        .padding(.vertical, width * 0.06)
        .fixedSize()
        .accessibilityLabel(Text("\(String(localized: "Battery Level")) \(min(max(percentage, 0), 100))%"))
    }
}

// MenuBarExtra reliably supports Image/Text labels. Render the custom SwiftUI
// drawing to an image, and cache by battery state rather than by power sample.
@MainActor
enum MenuBarBatteryIcon {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(percentage: Int, isCharging: Bool, colorScheme: ColorScheme = .light) -> NSImage {
        let percent = min(max(percentage, 0), 100)
        let key = "\(percent)-\(isCharging)-\(colorScheme)" as NSString
        if let image = cache.object(forKey: key) { return image }

        let renderer = ImageRenderer(content:
            BatteryIconView(percentage: percent, isCharging: isCharging)
                .environment(\.colorScheme, colorScheme)
        )
        renderer.scale = 3
        guard let bitmap = renderer.cgImage else {
            let step = Int((Double(percent) / 25).rounded()) * 25
            // Never cache a renderer failure as a permanent empty battery.
            return NSImage(
                systemSymbolName: isCharging ? "battery.100.bolt" : "battery.\(step)",
                accessibilityDescription: nil
            )!
        }
        let image = NSImage(cgImage: bitmap, size: NSSize(width: 28, height: 28 / 2.15 + 28 * 0.12))
        image.isTemplate = !isCharging && percent > 20
        cache.setObject(image, forKey: key)
        return image
    }
}
