import AppKit
import SwiftUI

/// Live dim overlay per display. Select on the real desktop; capture after mouse-up.
@MainActor
final class ScreenshotOverlayController: NSObject {
    private let screenFrame: CGRect
    private let displayID: CGDirectDisplayID
    private let scaleFactor: CGFloat
    private let state: ScreenshotOverlayState
    private var panel: NSPanel?
    private var overlayView: ScreenshotOverlayView?
    private var toolbarPanel: NSPanel?
    private var previewPanel: NSPanel?
    private var longShotControlPanel: NSPanel?
    private var displayObserver: NSObjectProtocol?
    private let longCapturer = ScreenshotLongCapturer()
    private var captureTask: Task<Void, Never>?
    private var longShotTask: Task<Void, Never>?

    private static var overlayLevel: NSWindow.Level {
        NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
    }

    init(
        screenFrame: CGRect,
        displayID: CGDirectDisplayID,
        scaleFactor: CGFloat,
        state: ScreenshotOverlayState
    ) {
        self.screenFrame = screenFrame
        self.displayID = displayID
        self.scaleFactor = scaleFactor
        self.state = state
        super.init()
    }

    func present() {
        let view = ScreenshotOverlayView(displayID: displayID, scaleFactor: scaleFactor)
        view.state = state
        view.controller = self
        view.frame = NSRect(origin: .zero, size: screenFrame.size)
        overlayView = view

        let panel = NSPanel(
            contentRect: screenFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = Self.overlayLevel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.contentView = view
        panel.setFrame(screenFrame, display: true)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel

        displayObserver = NotificationCenter.default.addObserver(
            forName: .screenshotOverlayNeedsDisplay,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.overlayView?.refresh() }
        }
    }

    func bindAsActionTarget() {
        state.imageProvider = { [weak self] in self?.compositedImage() }
        state.cgImageProvider = { [weak self] in self?.compositedCGImage() }
        state.onRequestLongShot = { [weak self] in self?.startLongShot() }
        state.onFinishLongShot = { [weak self] in self?.finishLongShot() }
        state.onCancelLongShot = { [weak self] in self?.cancelLongShot() }
        state.onChromeLayoutNeeded = { [weak self] in self?.repositionChrome() }
        state.onInvalidate = {
            NotificationCenter.default.post(name: .screenshotOverlayNeedsDisplay, object: nil)
        }
    }

    func commitPendingText() {
        overlayView?.commitInlineText(discardEmpty: true)
    }

    func dismiss() {
        captureTask?.cancel()
        longShotTask?.cancel()
        longCapturer.cancel()
        if let displayObserver {
            NotificationCenter.default.removeObserver(displayObserver)
            self.displayObserver = nil
        }
        hideChrome()
        hideLongShotControls()
        panel?.orderOut(nil)
        panel = nil
        overlayView = nil
    }

    func setOverlayVisible(_ visible: Bool) {
        if visible { panel?.orderFrontRegardless() } else { panel?.orderOut(nil) }
    }

    var containsGlobalMouse: Bool {
        screenFrame.contains(NSEvent.mouseLocation)
    }

    func makeKey() {
        panel?.makeKeyAndOrderFront(nil)
    }

    /// Capture the live desktop region (overlay hidden so it is not in the shot).
    func finalizeSelectionForEdit() {
        guard state.selectionDisplayID == displayID,
              let sel = state.selection, sel.width > 2, sel.height > 2 else { return }

        captureTask?.cancel()
        hideChrome()
        let viewSelection = sel

        captureTask = Task { @MainActor in
            setOverlayVisible(false)
            state.onLongShotWillStart?()
            // Yield so orderOut lands in the compositor, then brief settle (40ms was often short).
            await Task.yield()
            try? await Task.sleep(nanoseconds: 80_000_000)
            defer {
                state.onLongShotDidEnd?()
                setOverlayVisible(true)
            }
            do {
                let image = try await ScreenshotDisplayCapture.captureOverlaySelection(
                    selection: viewSelection,
                    displayID: displayID,
                    screenFrame: screenFrame
                )
                guard !Task.isCancelled else { return }
                state.replacementCrop = image
                state.captureScale = ScreenshotExport.scale(for: image, pointSize: viewSelection.size)
                if state.phase != .editing {
                    state.annotations = []
                }
                state.phase = .editing
                state.tool = .move
                state.statusMessage = nil
                showChrome()
                overlayView?.refresh()
            } catch {
                guard !Task.isCancelled else { return }
                state.replacementCrop = nil
                state.captureScale = nil
                state.phase = .selecting
                state.statusMessage = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                NotificationCenter.default.post(name: .screenshotOverlayNeedsDisplay, object: nil)
            }
        }
    }

    func showChrome() {
        bindAsActionTarget()
        guard let sel = state.selection, panel != nil else { return }
        repositionToolbar(selection: sel)
    }

    func hideChrome() {
        toolbarPanel?.orderOut(nil)
        toolbarPanel = nil
        previewPanel?.orderOut(nil)
        previewPanel = nil
    }

    func repositionChrome() {
        guard let sel = state.selection, toolbarPanel != nil else { return }
        repositionToolbar(selection: sel)
    }

    private func repositionToolbar(selection sel: CGRect) {
        let hosting = NSHostingView(rootView: ScreenshotToolbarView(state: state))
        hosting.frame = NSRect(x: 0, y: 0, width: 760, height: 120)
        let fit = hosting.fittingSize
        hosting.frame.size = NSSize(width: max(680, fit.width), height: max(52, fit.height))

        let panel: NSPanel
        if let existing = toolbarPanel {
            panel = existing
            panel.contentView = hosting
        } else {
            panel = NSPanel(
                contentRect: hosting.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.level = NSWindow.Level(rawValue: Self.overlayLevel.rawValue + 1)
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.contentView = hosting
            toolbarPanel = panel
        }

        let selGlobalX = screenFrame.minX + sel.minX
        let selGlobalBottom = screenFrame.minY + (screenFrame.height - sel.maxY)
        let selGlobalTop = selGlobalBottom + sel.height
        var origin = NSPoint(
            x: selGlobalX + (sel.width - hosting.frame.width) / 2,
            y: selGlobalBottom - hosting.frame.height - 10
        )
        if origin.y < screenFrame.minY + 8 { origin.y = selGlobalTop + 10 }
        origin.x = min(max(origin.x, screenFrame.minX + 8), screenFrame.maxX - hosting.frame.width - 8)
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
    }

    func showLongPreview(_ image: NSImage) {
        let hosting = NSHostingView(rootView: ScreenshotLongPreviewView(image: image))
        let size = NSSize(width: 180, height: 460)
        hosting.frame = NSRect(origin: .zero, size: size)
        let panel: NSPanel
        if let existing = previewPanel {
            panel = existing
            panel.contentView = hosting
        } else {
            panel = NSPanel(
                contentRect: hosting.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.level = NSWindow.Level(rawValue: Self.overlayLevel.rawValue + 1)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            previewPanel = panel
        }
        guard let sel = state.selection else { return }
        let selGlobalX = screenFrame.minX + sel.minX
        let selGlobalBottom = screenFrame.minY + (screenFrame.height - sel.maxY)
        var x = selGlobalX + sel.width + 12
        if x + size.width > screenFrame.maxX { x = selGlobalX - size.width - 12 }
        panel.setFrame(NSRect(x: x, y: selGlobalBottom, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
    }

    func compositedCGImage() -> CGImage? {
        guard state.selectionDisplayID == displayID,
              let sel = state.selection, sel.width > 2, sel.height > 2,
              let base = state.replacementCrop else { return nil }
        return ScreenshotAnnotationRenderer.render(
            base: base,
            annotations: state.annotations,
            selectionSize: sel.size
        )
    }

    func compositedImage() -> NSImage? {
        guard let cg = compositedCGImage() else { return nil }
        return ScreenshotExport.pasteboardImage(from: cg, scale: state.resolvedScale(for: cg))
    }

    func viewRectToGlobal(_ sel: CGRect) -> CGRect {
        let bottom = screenFrame.minY + (screenFrame.height - sel.maxY)
        return CGRect(x: screenFrame.minX + sel.minX, y: bottom, width: sel.width, height: sel.height)
    }

    private func startLongShot() {
        guard state.selectionDisplayID == displayID,
              let sel = state.selection else { return }
        guard !state.longShotBusy else { return }

        state.phase = .longShot
        state.longShotBusy = true
        state.longShotFrameCount = 1
        state.longShotPreview = nil
        state.statusMessage = "请先点击选区内窗口，再手动滚动；完成后点「完成拼接」"
        hideChrome()
        state.onLongShotWillStart?()
        showLongShotControls(selection: sel)

        let region = viewRectToGlobal(sel)
        let previewScale = state.captureScale
            ?? ScreenshotExport.scale(forDisplayID: displayID)
        longShotTask?.cancel()
        longShotTask = Task { @MainActor in
            defer {
                self.hideLongShotControls()
                self.state.onLongShotDidEnd?()
                self.state.longShotBusy = false
                if self.state.phase == .longShot {
                    self.state.phase = .editing
                }
                self.showChrome()
                if let preview = self.state.longShotPreview {
                    self.showLongPreview(preview)
                }
                self.overlayView?.refresh()
            }
            do {
                let result = try await longCapturer.capture(region: region) { [weak self] progress in
                    guard let self else { return }
                    let img = ScreenshotNSImage(progress.stitched, scale: previewScale)
                    self.state.longShotPreview = img
                    self.state.longShotFrameCount = progress.step + 1
                    self.state.statusMessage = "已拼接 \(progress.step + 1) 帧 · 继续滚动或完成"
                    self.showLongPreview(img)
                }
                state.replacementCrop = result
                let aspect = CGFloat(result.height) / CGFloat(max(result.width, 1))
                var newSel = sel
                newSel.size.height = min(
                    screenFrame.height - sel.minY,
                    max(sel.height, sel.width * aspect)
                )
                state.selection = newSel
                state.captureScale = ScreenshotExport.scale(for: result, pointSize: newSel.size)
                state.annotations = []
                state.longShotPreview = ScreenshotNSImage(result, scale: state.captureScale ?? previewScale)
                state.statusMessage = "长截图完成"
            } catch is CancellationError {
                state.statusMessage = "已取消长截图"
            } catch {
                state.statusMessage = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }

    private func finishLongShot() {
        guard state.longShotBusy else { return }
        state.statusMessage = "正在完成拼接…"
        longCapturer.requestFinish()
    }

    private func cancelLongShot() {
        guard state.longShotBusy else { return }
        longCapturer.cancel()
    }

    private func showLongShotControls(selection sel: CGRect) {
        let hosting = NSHostingView(rootView: ScreenshotLongShotControlView(state: state))
        hosting.frame = NSRect(x: 0, y: 0, width: 280, height: 110)
        let fit = hosting.fittingSize
        hosting.frame.size = NSSize(width: max(260, fit.width), height: max(96, fit.height))

        let panel: NSPanel
        if let existing = longShotControlPanel {
            panel = existing
            panel.contentView = hosting
        } else {
            panel = NSPanel(
                contentRect: hosting.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.level = NSWindow.Level(rawValue: Self.overlayLevel.rawValue + 2)
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            longShotControlPanel = panel
        }
        panel.contentView = hosting

        let selGlobalX = screenFrame.minX + sel.minX
        let selGlobalBottom = screenFrame.minY + (screenFrame.height - sel.maxY)
        let selGlobalTop = selGlobalBottom + sel.height
        var origin = NSPoint(
            x: selGlobalX + (sel.width - hosting.frame.width) / 2,
            y: selGlobalBottom - hosting.frame.height - 12
        )
        if origin.y < screenFrame.minY + 8 {
            origin.y = min(selGlobalTop + 12, screenFrame.maxY - hosting.frame.height - 8)
        }
        origin.x = min(
            max(origin.x, screenFrame.minX + 8),
            screenFrame.maxX - hosting.frame.width - 8
        )
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
    }

    private func hideLongShotControls() {
        longShotControlPanel?.orderOut(nil)
        longShotControlPanel = nil
    }
}
