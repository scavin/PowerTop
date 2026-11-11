import SwiftUI
import AppKit

// Adapted from theMomax/BatteryView's SFSymbolStyle and SFBoltModifier.
// Copyright (c) 2021 Max Obermeier. MIT; see ThirdPartyNotices.txt.
struct BatteryIconView: View {
    let percentage: Int
    let isCharging: Bool
    var color: Color = .primary
    var width: CGFloat = 28

    private var level: CGFloat { CGFloat(min(max(percentage, 0), 100)) / 100 }

    var body: some View {
        ZStack(alignment: .leading) {
            if isCharging {
                battery.mask(symbolMask("battery.100.bolt"))
                Image(systemName: "bolt.fill")
                    .font(symbolFont)
                    .foregroundStyle(color)
                    .scaleEffect(0.6)
                    .offset(x: width * 0.2)
            } else {
                battery
            }
        }
        .frame(width: width, height: width / 2.15)
        .accessibilityLabel(Text("\(String(localized: "Battery Level")) \(min(max(percentage, 0), 100))%"))
    }

    private var symbolFont: Font {
        .system(size: 200 * width / 294, weight: .light)
    }

    private var battery: some View {
        ZStack(alignment: .leading) {
            Image(systemName: "battery.0")
                .font(symbolFont)
                .foregroundStyle(color.opacity(0.55))
            RoundedRectangle(cornerRadius: width * 0.04, style: .continuous)
                .fill(color)
                .frame(width: width * 0.688 * level, height: width * 0.276)
                .offset(x: width * 0.18)
        }
        .mask(symbolMask("battery.100"))
    }

    private func symbolMask(_ name: String) -> some View {
        ZStack {
            Color.white
            Image(systemName: name)
                .font(symbolFont)
                .foregroundStyle(.black)
        }
        .compositingGroup()
        .colorInvert()
        .luminanceToAlpha()
    }
}

// MenuBarExtra reliably supports Image/Text labels. Render the custom SwiftUI
// drawing to an image, and cache by battery state rather than by power sample.
@MainActor
enum MenuBarBatteryIcon {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(percentage: Int, isCharging: Bool) -> NSImage {
        let percent = min(max(percentage, 0), 100)
        let key = "\(percent)-\(isCharging)" as NSString
        if let image = cache.object(forKey: key) { return image }

        let color: Color = isCharging ? .green : percent <= 20 ? .red : percent <= 50 ? .orange : .black
        let renderer = ImageRenderer(content:
            BatteryIconView(percentage: percent, isCharging: isCharging, color: color)
                .environment(\.colorScheme, .light)
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
        let image = NSImage(cgImage: bitmap, size: NSSize(width: 28, height: 28 / 2.15))
        image.isTemplate = !isCharging && percent > 50
        cache.setObject(image, forKey: key)
        return image
    }
}
