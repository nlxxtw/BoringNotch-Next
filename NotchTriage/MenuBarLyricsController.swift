import AppKit
import Combine
import SwiftUI

/// Menu-bar lyrics strip — same behavior as the notch chin:
/// idle = lyrics only; mouse hover = prev / play-pause / next.
/// Transparent chrome so it matches the system menu bar (no black pill).
struct MenuBarLyricsView: View {
    @ObservedObject var model: AppModel
    var onHoverChange: ((Bool) -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    private var showTransport: Bool {
        isHovering && model.mediaCommandAvailability.transportAvailable
    }

    private var spectrumTint: Color {
        AlbumArtPalette.menuBarSpectrumTint(
            for: model.media,
            ringFallback: model.ringAppearance.style(for: .media).start.color
        )
    }

    var body: some View {
        TimelineView(
            .animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)
        ) { context in
            // Fixed trailing spectrum (like before): lyrics fill the middle and
            // scroll left when long. Only the old 6pt gaps are eased to 5pt.
            HStack(spacing: 5) {
                CircularAlbumArt(snapshot: model.media, size: 20, chrome: .menuBar)

                WalkingLyricLine(
                    text: lyricText(at: context.date),
                    progress: lyricProgress(at: context.date),
                    isLoading: model.isFetchingLyrics,
                    fontSize: 14,
                    sungColor: Color.primary.opacity(0.94),
                    unsungColor: Color.primary.opacity(0.40)
                )
                .frame(maxWidth: .infinity, alignment: .leading)

                if showTransport {
                    HStack(spacing: 1) {
                        menuBarTransportButton(command: .previousTrack)
                        menuBarTransportButton(command: .togglePlayPause)
                        menuBarTransportButton(command: .nextTrack)
                    }
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                }

                MusicSpectrumBars(
                    isPlaying: model.media.isPlaying,
                    tint: spectrumTint,
                    barCount: 4,
                    barWidth: 2.0,
                    spacing: 1.4,
                    height: 13
                )
            }
            .padding(.horizontal, 4)
            .frame(
                width: showTransport
                    ? MenuBarLyricsController.expandedWidth
                    : MenuBarLyricsController.compactWidth,
                height: 24
            )
            .animation(
                reduceMotion ? .linear(duration: 0.01) : .easeOut(duration: 0.16),
                value: showTransport
            )
        }
        .background(Color.clear)
        .onHover { hovering in
            isHovering = hovering
            onHoverChange?(hovering)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(model.currentLyricsLine.isEmpty ? model.media.title : model.currentLyricsLine)
    }

    private func menuBarTransportButton(command: MediaCommand) -> some View {
        let enabled = model.isMediaCommandEnabled(command)
        let sending = model.mediaCommandInFlight == command
        let symbol: String = {
            if command == .togglePlayPause {
                return model.media.isPlaying ? "pause.fill" : "play.fill"
            }
            return command.systemImage
        }()

        return Button {
            model.sendMediaCommand(command)
        } label: {
            Group {
                if sending {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: command == .togglePlayPause ? 9.5 : 9, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(command == .togglePlayPause ? 0.95 : 0.8))
                }
            }
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(sending ? 0.75 : (enabled ? 1 : 0.35))
        .help(model.localized(command.title))
    }

    private func lyricText(at date: Date) -> String {
        if model.isFetchingLyrics, !model.lyricsPayload.hasContent {
            return "歌词加载中…"
        }
        let line = model.lyricsPayload.line(at: model.media.estimatedElapsed(at: date))
        if line.isEmpty {
            return model.media == .idle ? "" : (model.media.title.isEmpty ? "…" : model.media.title)
        }
        return line
    }

    private func lyricProgress(at date: Date) -> Double {
        model.lyricsPayload.lineProgress(at: model.media.estimatedElapsed(at: date))
    }
}

/// Hosts an `NSStatusItem` with notch-equivalent lyrics + hover transport.
@MainActor
final class MenuBarLyricsController {
    static let compactWidth: CGFloat = 236
    static let expandedWidth: CGFloat = 308

    private weak var model: AppModel?
    private var statusItem: NSStatusItem?
    private var hostingView: NSHostingView<MenuBarLyricsView>?
    private var cancellables = Set<AnyCancellable>()
    private var isHovering = false

    func attach(model: AppModel) {
        self.model = model
        cancellables.removeAll()

        Publishers.CombineLatest4(
            model.$showMenuBarLyrics,
            model.$media,
            model.$lyricsPayload,
            model.$customMusicBundleIdentifiers
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _, _, _, _ in
            self?.sync()
        }
        .store(in: &cancellables)

        model.$isFetchingLyrics
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.sync() }
            .store(in: &cancellables)

        model.$ringAppearance
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.sync() }
            .store(in: &cancellables)

        sync()
    }

    func detach() {
        cancellables.removeAll()
        tearDownItem()
        model = nil
    }

    private func sync() {
        guard let model else {
            tearDownItem()
            return
        }
        let shouldShow = model.showsMenuBarLyricsStrip
        if shouldShow {
            ensureItem(model: model)
            statusItem?.isVisible = true
            applyWidth()
        } else {
            isHovering = false
            statusItem?.isVisible = false
            if !model.showMenuBarLyrics {
                tearDownItem()
            }
        }
    }

    private func ensureItem(model: AppModel) {
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: Self.compactWidth)
            item.isVisible = true
            statusItem = item
        }
        guard let button = statusItem?.button else { return }
        button.title = ""
        button.image = nil
        button.appearsDisabled = false
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.clear.cgColor

        let root = MenuBarLyricsView(model: model) { [weak self] hovering in
            self?.isHovering = hovering
            self?.applyWidth()
        }

        if hostingView == nil {
            let hosting = NSHostingView(rootView: root)
            hostingView = hosting
            button.addSubview(hosting)
        } else {
            hostingView?.rootView = root
        }

        applyWidth()
    }

    private func applyWidth() {
        let width = isHovering ? Self.expandedWidth : Self.compactWidth
        statusItem?.length = width
        guard let button = statusItem?.button, let hostingView else { return }
        let height: CGFloat = 24
        hostingView.frame = NSRect(
            x: 0,
            y: ((button.bounds.height - height) / 2).rounded(.down),
            width: width,
            height: height
        )
        button.frame.size.width = width
    }

    private func tearDownItem() {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        statusItem = nil
        hostingView = nil
        isHovering = false
    }
}
