import AppKit
import ApplicationServices
import CoreVideo
import ScreenCaptureKit

enum ScreenshotPermission {
    static func ensureScreenRecording() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        _ = CGRequestScreenCaptureAccess()
        return CGPreflightScreenCaptureAccess()
    }

    static func hasAccessibility() -> Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    static func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

enum ScreenshotCaptureError: LocalizedError {
    case permissionDenied, noDisplay, captureFailed, invalidCrop

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "需要屏幕录制权限才能截图（系统设置 → 隐私 → 屏幕录制）"
        case .noDisplay: return "找不到显示器"
        case .captureFailed: return "截取屏幕失败"
        case .invalidCrop: return "裁剪区域无效"
        }
    }
}

enum ScreenshotDisplayCapture {
    struct FrozenDisplay: Sendable {
        let screenFrame: CGRect
        let displayID: CGDirectDisplayID
        let scaleFactor: CGFloat
        let image: CGImage
    }

    static func freezeAllDisplays() async throws -> [FrozenDisplay] {
        guard ScreenshotPermission.ensureScreenRecording() else {
            throw ScreenshotCaptureError.permissionDenied
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        var out: [FrozenDisplay] = []
        for screen in NSScreen.screens {
            let id = screen.displayID
            guard let display = content.displays.first(where: { $0.displayID == id }) else { continue }
            let image = try await captureDisplay(display, excludingSelf: false)
            let scale = CGFloat(image.width) / max(screen.frame.width, 1)
            out.append(FrozenDisplay(
                screenFrame: screen.frame,
                displayID: id,
                scaleFactor: scale,
                image: image
            ))
        }
        guard !out.isEmpty else { throw ScreenshotCaptureError.noDisplay }
        return out
    }

    /// Capture using the overlay’s flipped (top-left) selection — same coords the user drew.
    /// Full-display SC frame + Quartz Y crop. No `sourceRect` (its origin differs by SDK and caused A→B shifts).
    static func captureOverlaySelection(
        selection: CGRect,
        displayID: CGDirectDisplayID,
        screenFrame: CGRect
    ) async throws -> CGImage {
        guard ScreenshotPermission.ensureScreenRecording() else {
            throw ScreenshotCaptureError.permissionDenied
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ScreenshotCaptureError.noDisplay
        }

        var sel = selection.integral
        sel = sel.intersection(CGRect(origin: .zero, size: screenFrame.size))
        guard sel.width >= 1, sel.height >= 1 else {
            throw ScreenshotCaptureError.invalidCrop
        }

        let full = try await captureDisplay(display, excludingSelf: true)
        return try cropViewSelection(
            image: full,
            selection: sel,
            viewSize: screenFrame.size
        )
    }

    /// AppKit-global rect (bottom-left). Converts back to overlay view coords, then same crop path.
    static func captureRegion(_ rect: CGRect) async throws -> CGImage {
        guard let screen = NSScreen.screens
            .filter({ $0.frame.intersects(rect) })
            .max(by: { $0.frame.intersection(rect).area < $1.frame.intersection(rect).area })
            ?? NSScreen.main else {
            throw ScreenshotCaptureError.noDisplay
        }
        let clamped = rect.intersection(screen.frame)
        guard clamped.width >= 1, clamped.height >= 1 else {
            throw ScreenshotCaptureError.invalidCrop
        }
        // Inverse of overlay viewRectToGlobal.
        let viewSelection = CGRect(
            x: clamped.minX - screen.frame.minX,
            y: screen.frame.height - (clamped.maxY - screen.frame.minY),
            width: clamped.width,
            height: clamped.height
        )
        return try await captureOverlaySelection(
            selection: viewSelection,
            displayID: screen.displayID,
            screenFrame: screen.frame
        )
    }

    static func captureDisplay(
        _ display: SCDisplay,
        excludingSelf: Bool
    ) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let excluded: [SCRunningApplication]
        if excludingSelf {
            excluded = content.applications.filter {
                $0.bundleIdentifier == Bundle.main.bundleIdentifier
            }
        } else {
            excluded = []
        }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: excluded,
            exceptingWindows: []
        )
        let config = SCStreamConfiguration()
        config.showsCursor = false
        config.width = display.width
        config.height = display.height
        config.scalesToFit = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        if #available(macOS 14.0, *) {
            config.captureResolution = .best
        }
        return try await performCapture(filter: filter, configuration: config)
    }

    private static func performCapture(
        filter: SCContentFilter,
        configuration: SCStreamConfiguration
    ) async throws -> CGImage {
        try await withThrowingTaskGroup(of: CGImage.self) { group in
            group.addTask {
                try await SCScreenshotManager.captureImage(
                    contentFilter: filter,
                    configuration: configuration
                )
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 8_000_000_000)
                throw ScreenshotCaptureError.captureFailed
            }
            guard let image = try await group.next() else {
                throw ScreenshotCaptureError.captureFailed
            }
            group.cancelAll()
            return image
        }
    }

    /// Overlay selection is top-left / flipped-view. CGImage.cropping is bottom-left.
    static func cropViewSelection(
        image: CGImage,
        selection: CGRect,
        viewSize: CGSize
    ) throws -> CGImage {
        let pixel = ScreenshotPixelMath.pixelRect(
            viewRect: selection,
            imageWidth: image.width,
            imageHeight: image.height,
            viewSize: viewSize
        )
        guard pixel.width >= 1, pixel.height >= 1,
              let cropped = image.cropping(to: pixel) else {
            throw ScreenshotCaptureError.invalidCrop
        }
        return cropped
    }
}

/// Shared view↔pixel mapping so capture crop and live mosaic stay aligned.
enum ScreenshotPixelMath {
    /// Flipped-view rect → Quartz (bottom-left) pixel rect.
    /// Rounds each edge independently to avoid the systematic 1px drift of floor(width).
    static func pixelRect(
        viewRect: CGRect,
        imageWidth: Int,
        imageHeight: Int,
        viewSize: CGSize
    ) -> CGRect {
        let sfX = CGFloat(imageWidth) / max(viewSize.width, 1)
        let sfY = CGFloat(imageHeight) / max(viewSize.height, 1)
        let x0 = (viewRect.minX * sfX).rounded(.toNearestOrAwayFromZero)
        let x1 = (viewRect.maxX * sfX).rounded(.toNearestOrAwayFromZero)
        let qBottom = (CGFloat(imageHeight) - viewRect.maxY * sfY).rounded(.toNearestOrAwayFromZero)
        let qTop = (CGFloat(imageHeight) - viewRect.minY * sfY).rounded(.toNearestOrAwayFromZero)
        return CGRect(
            x: x0,
            y: qBottom,
            width: max(1, x1 - x0),
            height: max(1, qTop - qBottom)
        ).intersection(CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))
    }
}

private extension CGRect {
    var area: CGFloat { max(0, width) * max(0, height) }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (deviceDescription[key] as? CGDirectDisplayID) ?? CGMainDisplayID()
    }
}

func ScreenshotNSImage(_ cg: CGImage, scale: CGFloat = 1) -> NSImage {
    ScreenshotExport.pasteboardImage(from: cg, scale: max(scale, 1))
}

enum ScreenshotExport {
    static func pasteboardImage(from cg: CGImage, scale: CGFloat) -> NSImage {
        let scale = max(scale, 1)
        let pointSize = NSSize(
            width: CGFloat(cg.width) / scale,
            height: CGFloat(cg.height) / scale
        )
        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = pointSize
        let image = NSImage(size: pointSize)
        image.addRepresentation(rep)
        return image
    }

    static func writePasteboard(_ cg: CGImage, scale: CGFloat) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let image = pasteboardImage(from: cg, scale: scale)
        pb.writeObjects([image])
        if let tiff = image.tiffRepresentation {
            pb.setData(tiff, forType: .tiff)
        }
        if let png = pngData(cg, scale: scale) {
            pb.setData(png, forType: .png)
        }
    }

    static func pngData(_ cg: CGImage, scale: CGFloat = 1) -> Data? {
        let scale = max(scale, 1)
        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = NSSize(
            width: CGFloat(cg.width) / scale,
            height: CGFloat(cg.height) / scale
        )
        return rep.representation(using: .png, properties: [:])
    }

    /// Single export scale from captured pixels ÷ selection point size.
    /// Snaps to 1×/2×/3× when close so pasteboard/pin metadata matches Retina.
    static func scale(for cg: CGImage, pointSize: CGSize) -> CGFloat {
        scale(pixelWidth: cg.width, pixelHeight: cg.height, pointSize: pointSize)
    }

    static func scale(pixelWidth: Int, pixelHeight: Int, pointSize: CGSize) -> CGFloat {
        let sx = CGFloat(pixelWidth) / max(pointSize.width, 1)
        let sy = CGFloat(pixelHeight) / max(pointSize.height, 1)
        let raw: CGFloat
        if abs(sx - sy) <= 0.05 {
            raw = (sx + sy) / 2
        } else {
            // Mild anisotropy: geometric mean avoids one-axis "zoom" in point size.
            raw = sqrt(max(sx, 0.01) * max(sy, 0.01))
        }
        return snapScale(raw)
    }

    /// Prefer the capture display — never assume `NSScreen.main` on multi-monitor.
    static func scale(forDisplayID displayID: CGDirectDisplayID?) -> CGFloat {
        if let displayID,
           let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) {
            return max(1, screen.backingScaleFactor)
        }
        if let screen = NSScreen.screens.first(where: { $0.displayID == CGMainDisplayID() }) {
            return max(1, screen.backingScaleFactor)
        }
        return max(1, NSScreen.main?.backingScaleFactor ?? 2)
    }

    static func snapScale(_ raw: CGFloat) -> CGFloat {
        let candidates: [CGFloat] = [1, 2, 3]
        if let match = candidates.first(where: { abs($0 - raw) < 0.12 }) {
            return match
        }
        return max(1, raw)
    }
}
