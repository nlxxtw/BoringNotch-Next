import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Post-capture toolbar (after region is already on clipboard) — pin / OCR / save / etc.
@MainActor
final class ScreenshotPreviewController {
    static let shared = ScreenshotPreviewController()

    private var panel: NSPanel?

    struct Actions {
        var onPin: () -> Void
        var onOCR: () -> Void
        var onSave: () -> Void
        var onAnnotate: () -> Void
        var onLongCapture: () -> Void
        var onDone: () -> Void
    }

    func show(image: NSImage, actions: Actions) {
        hide()

        let previewSize = fittedPreviewSize(for: image)
        let total = NSSize(
            width: max(420, previewSize.width + 24),
            height: previewSize.height + 92
        )

        let root = ScreenshotPreviewView(
            image: image,
            previewSize: previewSize,
            actions: actions,
            onDismiss: { [weak self] in self?.hide() }
        )
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: total)

        let panel = NSPanel(
            contentRect: hosting.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.contentView = hosting

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(
                NSPoint(
                    x: frame.midX - total.width / 2,
                    y: frame.midY - total.height / 2
                )
            )
        }

        self.panel = panel
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }

    private func fittedPreviewSize(for image: NSImage) -> NSSize {
        let maxWidth: CGFloat = 520
        let maxHeight: CGFloat = 320
        let pixel = image.size
        guard pixel.width > 0, pixel.height > 0 else {
            return NSSize(width: 240, height: 160)
        }
        let scale = min(1, min(maxWidth / pixel.width, maxHeight / pixel.height))
        return NSSize(
            width: max(160, pixel.width * scale),
            height: max(100, pixel.height * scale)
        )
    }
}

private struct ScreenshotPreviewView: View {
    let image: NSImage
    let previewSize: NSSize
    let actions: ScreenshotPreviewController.Actions
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Text("拖动窗口可移动")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))

            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: previewSize.width, height: previewSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            HStack(spacing: 6) {
                tool("贴图", "pin", actions.onPin)
                tool("OCR", "text.viewfinder", actions.onOCR)
                tool("保存", "square.and.arrow.down", actions.onSave)
                tool("标注", "pencil.tip.crop.circle", actions.onAnnotate)
                tool("长截图", "rectangle.bottomhalf.inset.filled", actions.onLongCapture)
                Spacer(minLength: 4)
                Button {
                    onDismiss()
                    actions.onDone()
                } label: {
                    Text("完成")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.black.opacity(0.9))
                        .padding(.horizontal, 14)
                        .frame(height: 36)
                        .background(Capsule().fill(Color.white.opacity(0.92)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.black.opacity(0.88))
        }
    }

    private func tool(_ title: String, _ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                Text(title)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(.white.opacity(0.95))
            .frame(width: 56, height: 40)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.white.opacity(0.1))
            )
        }
        .buttonStyle(.plain)
    }
}

@MainActor
final class ScreenshotOCRResultPanel {
    static let shared = ScreenshotOCRResultPanel()
    private var panel: NSPanel?

    func show(text: String) {
        panel?.orderOut(nil)
        let root = OCRResultView(text: text) { [weak self] in
            self?.panel?.orderOut(nil)
            self?.panel = nil
        }
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: 420, height: 280)
        let panel = NSPanel(
            contentRect: hosting.frame,
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "OCR 结果"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.contentView = hosting
        panel.center()
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
    }
}

private struct OCRResultView: View {
    let text: String
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                Text(text.isEmpty ? "（无文字）" : text)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Text("\(text.count) 字")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("复制全部") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                Button("关闭", action: onClose)
            }
        }
        .padding(14)
    }
}

enum ScreenshotSavePanel {
    @MainActor
    static func savePNG(_ image: NSImage) -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "Screenshot \(timestamp()).png"
        panel.title = "保存截图"
        guard panel.runModal() == .OK, let url = panel.url else { return false }

        let data: Data?
        if let cg = ScreenshotOCRService.cgImage(from: image) {
            let scale = ScreenshotExport.scale(for: cg, pointSize: image.size)
            data = ScreenshotExport.pngData(cg, scale: scale)
        } else if let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff) {
            data = rep.representation(using: .png, properties: [:])
        } else {
            data = nil
        }
        guard let data else { return false }
        do {
            try data.write(to: url)
            return true
        } catch {
            return false
        }
    }

    @MainActor
    static func savePNGData(_ data: Data) -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "Screenshot \(timestamp()).png"
        panel.title = "保存截图"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            try data.write(to: url)
            return true
        } catch {
            return false
        }
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f.string(from: Date())
    }
}
