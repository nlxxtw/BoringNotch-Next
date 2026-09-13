import AppKit
import Foundation

extension AppModel {
    func startScreenshotLifecycle() {
        syncScreenshotHotkeyMonitor()
    }

    func stopScreenshotLifecycle() {
        screenshotHotkeyMonitor.stop()
        ScreenshotSessionController.shared.cancelIfRunning()
        ScreenshotPreviewController.shared.hide()
        replaceIsCapturingScreenshot(false)
    }

    func setScreenshotCaptureEnabled(_ enabled: Bool) {
        screenshotCaptureEnabled = enabled
        syncScreenshotHotkeyMonitor()
    }

    func setScreenshotPinAfterCapture(_ enabled: Bool) {
        screenshotPinAfterCapture = enabled
    }

    func setScreenshotHotkeyChord(_ chord: ScreenshotHotkeyChord) {
        screenshotHotkeyChord = chord
    }

    func beginRecordingScreenshotHotkey() {
        replaceIsRecordingScreenshotHotkey(true)
        screenshotHotkeyMonitor.stop()
    }

    func cancelRecordingScreenshotHotkey() {
        replaceIsRecordingScreenshotHotkey(false)
        syncScreenshotHotkeyMonitor()
    }

    func finishRecordingScreenshotHotkey(from event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.isEmpty,
              event.keyCode != 0x35 else {
            cancelRecordingScreenshotHotkey()
            return
        }
        screenshotHotkeyChord = ScreenshotHotkeyChord(
            keyCode: event.keyCode,
            modifiersRaw: flags.rawValue
        )
        replaceIsRecordingScreenshotHotkey(false)
        replaceScreenshotFeedback("快捷键已设为 \(screenshotHotkeyChord.displayString)")
        syncScreenshotHotkeyMonitor()
    }

    /// Live desktop select → adjust → ✓ copy / ✕ cancel.
    func captureRegionScreenshot() {
        guard screenshotCaptureEnabled else {
            replaceScreenshotFeedback("请先在设置中启用截图")
            return
        }

        if ScreenshotSessionController.shared.isActive {
            ScreenshotSessionController.shared.cancelIfRunning()
            replaceIsCapturingScreenshot(false)
            replaceScreenshotFeedback("已取消截图")
            return
        }

        // Recover stuck flag if a previous session ended without clearing it.
        if isCapturingScreenshot {
            replaceIsCapturingScreenshot(false)
        }

        ScreenshotPreviewController.shared.hide()
        replaceIsCapturingScreenshot(true)
        replaceScreenshotFeedback("拖拽框选…")

        ScreenshotSessionController.shared.start(
            pinAfterCapture: screenshotPinAfterCapture,
            onFeedback: { [weak self] message in
                self?.replaceScreenshotFeedback(message)
            },
            onEnded: { [weak self] in
                self?.replaceIsCapturingScreenshot(false)
            },
            onOCR: { [weak self] cgImage in
                self?.runOCR(on: cgImage)
            }
        )
    }

    func runOCR(on image: NSImage) {
        guard let cg = ScreenshotOCRService.cgImage(from: image) else {
            replaceScreenshotFeedback("无法读取图片")
            return
        }
        runOCR(on: cg, clipboardImage: image)
    }

    func runOCR(on cgImage: CGImage) {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let clipboardImage = ScreenshotExport.pasteboardImage(from: cgImage, scale: scale)
        runOCR(on: cgImage, clipboardImage: clipboardImage)
    }

    private func runOCR(on cgImage: CGImage, clipboardImage: NSImage) {
        Task { @MainActor in
            replaceScreenshotFeedback("正在识别文字…")
            do {
                let text = try await ScreenshotOCRService.recognizeText(in: cgImage)
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    replaceScreenshotFeedback("未识别到文字")
                    return
                }
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.writeObjects([clipboardImage])
                pb.setString(text, forType: .string)
                ScreenshotOCRResultPanel.shared.show(text: text)
                replaceScreenshotFeedback("OCR 完成，文字已复制")
            } catch {
                replaceScreenshotFeedback(
                    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                )
            }
        }
    }

    func pinClipboardScreenshot() {
        if ScreenshotPinController.shared.pinClipboardImage() {
            replaceScreenshotFeedback("已贴图")
        } else {
            replaceScreenshotFeedback("剪贴板里没有图片")
        }
    }

    func syncScreenshotHotkeyMonitor() {
        guard screenshotCaptureEnabled, !isRecordingScreenshotHotkey else {
            screenshotHotkeyMonitor.stop()
            return
        }
        screenshotHotkeyMonitor.start(chord: screenshotHotkeyChord) { [weak self] in
            self?.captureRegionScreenshot()
        }
    }
}
