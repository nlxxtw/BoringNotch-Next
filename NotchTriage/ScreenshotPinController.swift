import AppKit

/// Floating always-on-top pin for a captured screenshot (QQ-style 贴图).
@MainActor
final class ScreenshotPinController {
    static let shared = ScreenshotPinController()

    private var panels: [UUID: ScreenshotPinPanel] = [:]

    func pin(_ image: NSImage) {
        let id = UUID()
        let panel = ScreenshotPinPanel(image: image) { [weak self] in
            self?.panels[id] = nil
        }
        panels[id] = panel
        panel.show()
    }

    func pin(cgImage: CGImage, scale: CGFloat) {
        pin(ScreenshotExport.pasteboardImage(from: cgImage, scale: scale))
    }

    func pinClipboardImage() -> Bool {
        let pb = NSPasteboard.general
        // Prefer TIFF/NSImage reps that preserve Retina size over raw PNG-as-1x.
        if let image = NSImage(pasteboard: pb) {
            pin(image)
            return true
        }
        return false
    }
}

@MainActor
private final class ScreenshotPinPanel: NSPanel {
    private let onClose: () -> Void

    init(image: NSImage, onClose: @escaping () -> Void) {
        self.onClose = onClose
        let size = Self.fittedSize(for: image)
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false

        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true

        let imageView = NSImageView(frame: container.bounds.insetBy(dx: 4, dy: 4))
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 8
        imageView.layer?.masksToBounds = true
        imageView.layer?.borderWidth = 1
        imageView.layer?.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
        // Match the bitmap's native Retina scale — not always NSScreen.main.
        imageView.layer?.contentsScale = Self.bitmapScale(for: image)
        imageView.autoresizingMask = [.width, .height]
        container.addSubview(imageView)

        let close = NSButton(
            frame: NSRect(x: size.width - 28, y: size.height - 28, width: 22, height: 22)
        )
        close.bezelStyle = .inline
        close.isBordered = false
        close.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "关闭")
        close.contentTintColor = .white
        close.autoresizingMask = [.minXMargin, .minYMargin]
        close.target = self
        close.action = #selector(closePin)
        container.addSubview(close)

        contentView = container

        let host = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.screens.first(where: { $0.displayID == CGMainDisplayID() })
            ?? NSScreen.main
        if let screen = host {
            let frame = screen.visibleFrame
            setFrameOrigin(
                NSPoint(
                    x: frame.midX - size.width / 2,
                    y: frame.midY - size.height / 2
                )
            )
        }
    }

    @objc private func closePin() {
        orderOut(nil)
        onClose()
    }

    func show() {
        orderFrontRegardless()
    }

    private static func fittedSize(for image: NSImage) -> NSSize {
        // Display up to ~900pt while keeping aspect; underlying bitmap stays full-res Retina.
        let maxSide: CGFloat = 900
        let point = image.size
        guard point.width > 0, point.height > 0 else {
            return NSSize(width: 200, height: 150)
        }
        let scale = min(1, maxSide / max(point.width, point.height))
        return NSSize(
            width: max(160, point.width * scale) + 8,
            height: max(120, point.height * scale) + 8
        )
    }

    private static func bitmapScale(for image: NSImage) -> CGFloat {
        if let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first,
           rep.size.width > 0 {
            return max(1, CGFloat(rep.pixelsWide) / rep.size.width)
        }
        return ScreenshotExport.scale(forDisplayID: nil)
    }
}
