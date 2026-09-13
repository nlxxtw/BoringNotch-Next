import AppKit
import SwiftUI

enum AlbumArtPalette {
    /// Dominant-ish average from artwork/app icon; falls back to `fallback`.
    /// - Parameters:
    ///   - minimumBrightness: Lift dark covers so bars stay visible (menu bar needs higher).
    ///   - saturationBoost: Push muted album averages toward vivid spectrum colors.
    static func spectrumTint(
        for snapshot: MediaSnapshot,
        fallback: Color = Color(red: 0.35, green: 0.78, blue: 0.98),
        minimumBrightness: CGFloat = 0.45,
        saturationBoost: CGFloat = 0
    ) -> Color {
        if let image = image(for: snapshot),
           let color = averageColor(
            of: image,
            minimumBrightness: minimumBrightness,
            saturationBoost: saturationBoost
           ) {
            return Color(nsColor: color)
        }
        return fallback
    }

    /// Menu-bar chrome: brighter auto-pick so bars read on light/dark system menu bars.
    static func menuBarSpectrumTint(
        for snapshot: MediaSnapshot,
        ringFallback: Color
    ) -> Color {
        spectrumTint(
            for: snapshot,
            fallback: ringFallback,
            minimumBrightness: 0.68,
            saturationBoost: 0.28
        )
    }

    static func image(for snapshot: MediaSnapshot) -> NSImage? {
        if let data = snapshot.artworkData,
           let image = NSImage(data: data) {
            return image
        }
        guard let bundleIdentifier = snapshot.bundleIdentifier,
              let url = NSWorkspace.shared.urlForApplication(
                  withBundleIdentifier: bundleIdentifier
              ) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private static func averageColor(
        of image: NSImage,
        minimumBrightness: CGFloat,
        saturationBoost: CGFloat
    ) -> NSColor? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let sampleSize = 16
        guard let context = CGContext(
            data: nil,
            width: sampleSize,
            height: sampleSize,
            bitsPerComponent: 8,
            bytesPerRow: sampleSize * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .medium
        context.draw(
            cgImage,
            in: CGRect(x: 0, y: 0, width: sampleSize, height: sampleSize)
        )
        guard let data = context.data else { return nil }

        let pointer = data.bindMemory(to: UInt32.self, capacity: sampleSize * sampleSize)
        var totalRed: UInt64 = 0
        var totalGreen: UInt64 = 0
        var totalBlue: UInt64 = 0
        let count = sampleSize * sampleSize
        for i in 0..<count {
            let pixel = pointer[i]
            totalRed += UInt64(pixel & 0xFF)
            totalGreen += UInt64((pixel >> 8) & 0xFF)
            totalBlue += UInt64((pixel >> 16) & 0xFF)
        }

        var red = CGFloat(totalRed) / CGFloat(count) / 255
        var green = CGFloat(totalGreen) / CGFloat(count) / 255
        var blue = CGFloat(totalBlue) / CGFloat(count) / 255

        let brightness = (red + green + blue) / 3
        if brightness < minimumBrightness {
            let lift = minimumBrightness - brightness
            red = min(1, red + lift)
            green = min(1, green + lift)
            blue = min(1, blue + lift)
        }

        if saturationBoost > 0 {
            let maxC = max(red, green, blue)
            let minC = min(red, green, blue)
            let delta = maxC - minC
            if delta > 0.02 {
                let mid = (red + green + blue) / 3
                red = min(1, mid + (red - mid) * (1 + saturationBoost))
                green = min(1, mid + (green - mid) * (1 + saturationBoost))
                blue = min(1, mid + (blue - mid) * (1 + saturationBoost))
            } else {
                // Near-gray covers → bias toward vivid cyan so bars still pop.
                red = min(1, red * 0.55 + 0.25)
                green = min(1, green * 0.55 + 0.72)
                blue = min(1, blue * 0.55 + 0.98)
            }
        }

        return NSColor(calibratedRed: red, green: green, blue: blue, alpha: 1)
    }
}
