import AppKit
import SwiftUI

/// Lightweight floating preview for clipboard-history images.
@MainActor
final class ClipboardImagePreviewController {
    static let shared = ClipboardImagePreviewController()

    private var panel: NSPanel?

    func show(image: NSImage, title: String = "图片预览") {
        hide()

        let previewSize = fittedSize(for: image)
        let total = NSSize(
            width: max(320, previewSize.width + 28),
            height: previewSize.height + 72
        )

        let root = ClipboardImagePreviewView(
            image: image,
            title: title,
            previewSize: previewSize,
            onDismiss: { [weak self] in self?.hide() },
            onCopy: {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.writeObjects([image])
            }
        )
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: total)

        let panel = NSPanel(
            contentRect: hosting.frame,
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
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

    func show(data: Data, title: String = "图片预览") {
        guard let image = NSImage(data: data) else { return }
        show(image: image, title: title)
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }

    private func fittedSize(for image: NSImage) -> NSSize {
        let maxWidth: CGFloat = 640
        let maxHeight: CGFloat = 480
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

private struct ClipboardImagePreviewView: View {
    let image: NSImage
    let title: String
    let previewSize: NSSize
    let onDismiss: () -> Void
    let onCopy: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))

            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: previewSize.width, height: previewSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            HStack(spacing: 8) {
                Button {
                    onCopy()
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.white.opacity(0.12))
                        )
                }
                .buttonStyle(.plain)

                Button(action: onDismiss) {
                    Text("关闭")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.black.opacity(0.9))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.white.opacity(0.92))
                        )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.black.opacity(0.92))
        }
    }
}
