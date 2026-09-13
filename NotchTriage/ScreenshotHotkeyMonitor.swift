import AppKit

/// Global hotkey monitor driven by a configurable chord.
@MainActor
final class ScreenshotHotkeyMonitor {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var wakeObserver: NSObjectProtocol?
    private var activeObserver: NSObjectProtocol?
    private var handler: (() -> Void)?
    private var chord: ScreenshotHotkeyChord = .default
    /// Suppress key-repeat floods and accidental double fires.
    private var lastFireAt: Date = .distantPast
    private let minInterval: TimeInterval = 0.45

    func start(chord: ScreenshotHotkeyChord, handler: @escaping () -> Void) {
        stopMonitorsOnly()
        self.chord = chord
        self.handler = handler
        installMonitors()
        installResyncObserversIfNeeded()
    }

    func stop() {
        removeResyncObservers()
        stopMonitorsOnly()
        handler = nil
    }

    private func stopMonitorsOnly() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }

    private func installMonitors() {
        let matches: NSEvent.EventTypeMask = .keyDown
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: matches) { [weak self] event in
            let keyCode = event.keyCode
            let modifiersRaw = event.modifierFlags.rawValue
            let isRepeat = event.isARepeat
            Task { @MainActor in
                self?.handle(keyCode: keyCode, modifiersRaw: modifiersRaw, isRepeat: isRepeat)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: matches) { [weak self] event in
            // Local monitors are delivered on the main thread.
            let consumed = self?.handle(
                keyCode: event.keyCode,
                modifiersRaw: event.modifierFlags.rawValue,
                isRepeat: event.isARepeat
            ) == true
            return consumed ? nil : event
        }
    }

    private func installResyncObserversIfNeeded() {
        guard wakeObserver == nil else { return }
        wakeObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.resyncMonitors() }
        }
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.resyncMonitors() }
        }
    }

    private func removeResyncObservers() {
        if let wakeObserver {
            NotificationCenter.default.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        if let activeObserver {
            NotificationCenter.default.removeObserver(activeObserver)
            self.activeObserver = nil
        }
    }

    /// Re-register monitors after sleep / activation — system can drop them silently.
    private func resyncMonitors() {
        guard handler != nil else { return }
        let chord = self.chord
        let handler = self.handler
        stopMonitorsOnly()
        self.chord = chord
        self.handler = handler
        installMonitors()
    }

    @discardableResult
    private func handle(keyCode: UInt16, modifiersRaw: UInt, isRepeat: Bool) -> Bool {
        guard !isRepeat else { return false }
        guard chord.matches(keyCode: keyCode, modifiersRaw: modifiersRaw) else { return false }
        let now = Date()
        guard now.timeIntervalSince(lastFireAt) >= minInterval else { return true }
        lastFireAt = now
        handler?()
        return true
    }
}
