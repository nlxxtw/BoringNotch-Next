import AppKit
import Combine
import SwiftUI

@MainActor
final class ScreenshotOverlayState: ObservableObject {
    enum Phase { case selecting, editing, longShot }

    @Published var phase: Phase = .selecting
    @Published var tool: ScreenshotTool = .move {
        didSet { onChromeLayoutNeeded?() }
    }
    @Published var selection: CGRect?
    @Published var selectionDisplayID: CGDirectDisplayID?
    @Published var annotations: [ScreenshotAnnotation] = []
    @Published var strokeColor: NSColor = .systemRed {
        didSet { onInvalidate?() }
    }
    @Published var lineWidth: CGFloat = 3
    @Published var textFontSize: CGFloat = 16 {
        didSet {
            onInvalidate?()
            onChromeLayoutNeeded?()
        }
    }
    @Published var canUndo = false
    @Published var longShotBusy = false
    @Published var longShotPreview: NSImage?
    @Published var longShotFrameCount = 0
    @Published var statusMessage: String?

    var replacementCrop: CGImage?
    private var undoStack: [[ScreenshotAnnotation]] = []

    var imageProvider: (() -> NSImage?)?
    var cgImageProvider: (() -> CGImage?)?
    var onCancel: (() -> Void)?
    var onComplete: ((NSImage) -> Void)?
    var onCompleteCG: ((CGImage) -> Void)?
    var onRequestLongShot: (() -> Void)?
    var onFinishLongShot: (() -> Void)?
    var onCancelLongShot: (() -> Void)?
    var onOCR: ((NSImage) -> Void)?
    var onOCRCG: ((CGImage) -> Void)?
    var onPin: ((NSImage) -> Void)?
    var onPinCG: ((CGImage) -> Void)?
    var onSave: ((NSImage) -> Void)?
    var onSaveData: ((Data) -> Void)?
    var onCopy: ((NSImage) -> Void)?
    var onHideAllChrome: (() -> Void)?
    var onLongShotWillStart: (() -> Void)?
    var onLongShotDidEnd: (() -> Void)?
    var onInvalidate: (() -> Void)?
    var onChromeLayoutNeeded: (() -> Void)?
    var onWillFinish: (() -> Void)?

    func pushUndo() {
        undoStack.append(annotations)
        canUndo = true
    }

    func undo() {
        guard let last = undoStack.popLast() else { return }
        annotations = last
        canUndo = !undoStack.isEmpty
        onInvalidate?()
    }

    func addAnnotation(_ ann: ScreenshotAnnotation) {
        pushUndo()
        annotations.append(ann)
        onInvalidate?()
    }

    func currentImage() -> NSImage? { imageProvider?() }

    func currentCGImage() -> CGImage? { cgImageProvider?() }

    func requestOCR() {
        onWillFinish?()
        if let cg = currentCGImage() {
            onOCRCG?(cg)
            return
        }
        if let image = currentImage() {
            onOCR?(image)
        }
    }

    func finish() {
        onWillFinish?()
        if let cg = cgImageProvider?() {
            onCompleteCG?(cg)
            return
        }
        guard let image = currentImage() else { return }
        onComplete?(image)
    }

    func cancel() { onCancel?() }
}

struct ScreenshotToolbarView: View {
    @ObservedObject var state: ScreenshotOverlayState

    private let textSizes: [CGFloat] = [12, 14, 16, 18, 24, 32, 48]
    private let palette: [NSColor] = [
        .black, .darkGray, NSColor(calibratedRed: 0.55, green: 0.05, blue: 0.05, alpha: 1),
        NSColor(calibratedRed: 0.72, green: 0.35, blue: 0.1, alpha: 1),
        NSColor(calibratedRed: 0.55, green: 0.5, blue: 0.1, alpha: 1),
        NSColor(calibratedRed: 0.1, green: 0.45, blue: 0.15, alpha: 1),
        NSColor(calibratedRed: 0.1, green: 0.25, blue: 0.55, alpha: 1),
        NSColor(calibratedRed: 0.4, green: 0.15, blue: 0.55, alpha: 1),
        .white, .lightGray, .systemRed, .systemYellow, .systemGreen,
        .systemBlue, .systemPink, .systemTeal
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                ForEach(ScreenshotTool.allCases) { tool in
                    Button {
                        state.tool = tool
                    } label: {
                        toolLabel(tool)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(state.tool == tool ? Color.white.opacity(0.22) : Color.white.opacity(0.08))
                            )
                    }
                    .buttonStyle(.plain)
                }

                divider

                Button { state.undo() } label: { label("撤销", "arrow.uturn.backward") }
                    .buttonStyle(.plain)
                    .disabled(!state.canUndo)

                divider

                action("OCR", "text.viewfinder") { state.requestOCR() }
                action("贴图", "pin") {
                    state.onWillFinish?()
                    if let cg = state.currentCGImage() {
                        state.onPinCG?(cg)
                    } else if let i = state.currentImage() {
                        state.onPin?(i)
                    }
                }
                action("保存", "square.and.arrow.down") {
                    if let cg = state.cgImageProvider?() {
                        let scale: CGFloat
                        if let sel = state.selection {
                            scale = ScreenshotExport.scale(for: cg, pointSize: sel.size)
                        } else {
                            scale = NSScreen.main?.backingScaleFactor ?? 2
                        }
                        if let data = ScreenshotExport.pngData(cg, scale: scale) {
                            state.onSaveData?(data)
                        }
                    } else if let i = state.currentImage() {
                        state.onSave?(i)
                    }
                }

                divider

                action(state.longShotBusy ? "拼接中" : "长截图", "rectangle.bottomhalf.inset.filled") {
                    state.onRequestLongShot?()
                }
                .disabled(state.longShotBusy)

                divider

                Button { state.cancel() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(width: 34, height: 34)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.white.opacity(0.1))
                        )
                }
                .buttonStyle(.plain)
                .help("取消")

                Button { state.finish() } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.black.opacity(0.9))
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color.white.opacity(0.92)))
                }
                .buttonStyle(.plain)
                .help("完成并复制")
            }

            if state.tool == .text {
                textFormatBar
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.black.opacity(0.88))
        }
    }

    private var textFormatBar: some View {
        HStack(spacing: 10) {
            Text("A")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))

            Picker("", selection: $state.textFontSize) {
                ForEach(textSizes, id: \.self) { size in
                    Text("\(Int(size))").tag(size)
                }
            }
            .labelsHidden()
            .frame(width: 64)
            .colorScheme(.dark)

            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color(nsColor: state.strokeColor))
                .frame(width: 22, height: 22)
                .overlay {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(.white.opacity(0.35), lineWidth: 1)
                }

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(16), spacing: 4), count: 8), spacing: 4) {
                ForEach(Array(palette.enumerated()), id: \.offset) { _, color in
                    Button {
                        state.strokeColor = color
                    } label: {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color(nsColor: color))
                            .frame(width: 16, height: 16)
                            .overlay {
                                if colorsMatch(color, state.strokeColor) {
                                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                                        .strokeBorder(.white, lineWidth: 1.5)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: 156)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.08))
        }
    }

    private func colorsMatch(_ a: NSColor, _ b: NSColor) -> Bool {
        let aa = a.usingColorSpace(NSColorSpace.deviceRGB) ?? a
        let bb = b.usingColorSpace(NSColorSpace.deviceRGB) ?? b
        return abs(aa.redComponent - bb.redComponent) < 0.02
            && abs(aa.greenComponent - bb.greenComponent) < 0.02
            && abs(aa.blueComponent - bb.blueComponent) < 0.02
    }

    private var divider: some View {
        Rectangle().fill(.white.opacity(0.15)).frame(width: 1, height: 28).padding(.horizontal, 4)
    }

    private func toolLabel(_ tool: ScreenshotTool) -> some View {
        VStack(spacing: 2) {
            if tool == .text {
                Text("A")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
            } else {
                Image(systemName: tool.symbol).font(.system(size: 12, weight: .semibold))
            }
            Text(tool.title).font(.system(size: 9, weight: .medium))
        }
        .foregroundStyle(.white.opacity(0.95))
        .frame(width: 48, height: 36)
    }

    private func action(_ title: String, _ symbol: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            label(title, symbol)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
    }

    private func label(_ title: String, _ symbol: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
            Text(title).font(.system(size: 9, weight: .medium))
        }
        .foregroundStyle(.white.opacity(0.95))
        .frame(width: 48, height: 36)
    }
}

struct ScreenshotLongPreviewView: View {
    let image: NSImage
    var body: some View {
        VStack(spacing: 6) {
            Text("长截图预览")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 160, maxHeight: 420)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.black.opacity(0.88))
        }
    }
}

/// Floating controls while the user manually scrolls during a long shot.
struct ScreenshotLongShotControlView: View {
    @ObservedObject var state: ScreenshotOverlayState

    var body: some View {
        VStack(spacing: 10) {
            Text("请在选区内手动滚动页面")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))
            Text(state.longShotFrameCount <= 1
                  ? "滚动后这里会自动拼接；完成后点「完成拼接」"
                  : "已拼接 \(state.longShotFrameCount) 帧 · 继续滚动或完成")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.62))
                .multilineTextAlignment(.center)

            HStack(spacing: 8) {
                Button {
                    state.onCancelLongShot?()
                } label: {
                    Text("取消")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(width: 88, height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.white.opacity(0.12))
                        )
                }
                .buttonStyle(.plain)

                Button {
                    state.onFinishLongShot?()
                } label: {
                    Text("完成拼接")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.black.opacity(0.9))
                        .frame(width: 108, height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.white.opacity(0.92))
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.black.opacity(0.9))
        }
    }
}
