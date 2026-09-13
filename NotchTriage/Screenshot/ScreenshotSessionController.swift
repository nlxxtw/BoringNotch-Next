import AppKit

/// Live dim → drag region on real desktop → adjust → ✓ copy / ✕ cancel.
@MainActor
final class ScreenshotSessionController {
    static let shared = ScreenshotSessionController()

    private var overlays: [ScreenshotOverlayController] = []
    private var state: ScreenshotOverlayState?
    private var isRunning = false
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var failsafeTask: Task<Void, Never>?
    private var onEndedHandler: (() -> Void)?
    private var onFeedbackHandler: ((String?) -> Void)?

    private init() {}

    var isActive: Bool { isRunning }

    func cancelIfRunning() {
        guard isRunning else { return }
        let ended = onEndedHandler
        let feedback = onFeedbackHandler
        finishOverlays()
        ScreenshotPreviewController.shared.hide()
        feedback?("已取消截图")
        ended?()
    }

    func start(
        pinAfterCapture: Bool,
        onFeedback: @escaping (String?) -> Void,
        onEnded: @escaping () -> Void,
        onOCR: @escaping (CGImage) -> Void
    ) {
        if isRunning {
            cancelIfRunning()
            return
        }

        isRunning = true
        onEndedHandler = onEnded
        onFeedbackHandler = onFeedback

        guard ScreenshotPermission.ensureScreenRecording() else {
            ScreenshotPermission.openScreenRecordingSettings()
            finishOverlays()
            onFeedback("需要屏幕录制权限")
            onEnded()
            return
        }

        let state = ScreenshotOverlayState()
        self.state = state

        state.onCancel = { [weak self] in
            self?.cancelIfRunning()
        }
        state.onCompleteCG = { [weak self] cgImage in
            let scale: CGFloat
            if let sel = self?.state?.selection {
                scale = ScreenshotExport.scale(for: cgImage, pointSize: sel.size)
            } else {
                scale = NSScreen.main?.backingScaleFactor ?? 2
            }
            ScreenshotExport.writePasteboard(cgImage, scale: scale)
            let nsImage = ScreenshotExport.pasteboardImage(from: cgImage, scale: scale)
            if pinAfterCapture {
                ScreenshotPinController.shared.pin(nsImage)
            }
            let ended = self?.onEndedHandler
            let feedback = self?.onFeedbackHandler
            self?.finishOverlays()
            feedback?(pinAfterCapture ? "已复制并贴图" : "已复制到剪贴板")
            ended?()
        }
        state.onComplete = { [weak self] image in
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([image])
            if pinAfterCapture { ScreenshotPinController.shared.pin(image) }
            let ended = self?.onEndedHandler
            let feedback = self?.onFeedbackHandler
            self?.finishOverlays()
            feedback?(pinAfterCapture ? "已复制并贴图" : "已复制到剪贴板")
            ended?()
        }
        state.onOCR = { image in
            guard let cg = ScreenshotOCRService.cgImage(from: image) else { return }
            onOCR(cg)
        }
        state.onOCRCG = { onOCR($0) }
        state.onPin = { [weak self] image in
            ScreenshotPinController.shared.pin(image)
            self?.onFeedbackHandler?("已贴图")
        }
        state.onPinCG = { [weak self] cg in
            let scale: CGFloat
            if let sel = self?.state?.selection {
                scale = ScreenshotExport.scale(for: cg, pointSize: sel.size)
            } else {
                scale = NSScreen.main?.backingScaleFactor ?? 2
            }
            ScreenshotPinController.shared.pin(cgImage: cg, scale: scale)
            self?.onFeedbackHandler?("已贴图")
        }
        state.onSave = { [weak self] image in
            self?.onFeedbackHandler?(
                ScreenshotSavePanel.savePNG(image) ? "已保存" : "已取消保存"
            )
        }
        state.onSaveData = { [weak self] data in
            self?.onFeedbackHandler?(
                ScreenshotSavePanel.savePNGData(data) ? "已保存" : "已取消保存"
            )
        }
        state.onCopy = { [weak self] image in
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([image])
            self?.onFeedbackHandler?("已复制到剪贴板")
        }
        state.onHideAllChrome = { [weak self] in
            self?.overlays.forEach { $0.hideChrome() }
        }
        state.onLongShotWillStart = { [weak self] in
            self?.overlays.forEach { $0.setOverlayVisible(false) }
        }
        state.onLongShotDidEnd = { [weak self] in
            self?.overlays.forEach { $0.setOverlayVisible(true) }
        }
        state.onWillFinish = { [weak self] in
            self?.overlays.forEach { $0.commitPendingText() }
        }

        overlays = NSScreen.screens.map { screen in
            ScreenshotOverlayController(
                screenFrame: screen.frame,
                displayID: screen.displayID,
                scaleFactor: screen.backingScaleFactor,
                state: state
            )
        }
        for o in overlays { o.present() }
        NSApp.activate(ignoringOtherApps: true)
        installKeys(state: state)
        startFailsafe()
        onFeedback("在桌面上拖拽框选；可调大小；✕取消 ✓复制")
    }

    private func installKeys(state: ScreenshotOverlayState) {
        removeKeys()
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                if state.phase == .longShot, state.longShotBusy {
                    state.onCancelLongShot?()
                } else {
                    state.cancel()
                }
                return nil
            }
            if (event.keyCode == 36 || event.keyCode == 76),
               state.phase == .longShot, state.longShotBusy {
                state.onFinishLongShot?()
                return nil
            }
            if (event.keyCode == 36 || event.keyCode == 76),
               state.selection != nil, state.phase == .editing, state.replacementCrop != nil {
                state.finish(); return nil
            }
            if event.modifierFlags.contains(.command),
               event.charactersIgnoringModifiers == "z" {
                state.undo(); return nil
            }
            return event
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            Task { @MainActor in
                guard let self, let state = self.state else { return }
                if keyCode == 53 {
                    if state.phase == .longShot, state.longShotBusy {
                        state.onCancelLongShot?()
                    } else {
                        self.cancelIfRunning()
                    }
                    return
                }
                if (keyCode == 36 || keyCode == 76),
                   state.phase == .longShot, state.longShotBusy {
                    state.onFinishLongShot?()
                }
            }
        }
    }

    private func removeKeys() {
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor); self.localKeyMonitor = nil }
        if let globalKeyMonitor { NSEvent.removeMonitor(globalKeyMonitor); self.globalKeyMonitor = nil }
    }

    private func startFailsafe() {
        failsafeTask?.cancel()
        failsafeTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled, self.isRunning else { return }
                // Long-shot waits on the user — don't kill the session mid-scroll.
                if self.state?.phase == .longShot {
                    continue
                }
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                guard !Task.isCancelled, self.isRunning else { return }
                if self.state?.phase == .longShot {
                    continue
                }
                self.cancelIfRunning()
                return
            }
        }
    }

    private func finishOverlays() {
        failsafeTask?.cancel()
        failsafeTask = nil
        removeKeys()
        overlays.forEach { $0.dismiss() }
        overlays = []
        state = nil
        isRunning = false
        onEndedHandler = nil
        onFeedbackHandler = nil
    }
}
