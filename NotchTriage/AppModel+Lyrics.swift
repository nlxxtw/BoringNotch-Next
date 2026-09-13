import Foundation
import SwiftUI

extension AppModel {
    /// Auto-lower the notch for lyrics only while a known music app is playing.
    var showsMediaLyricsPeek: Bool {
        showNotchLyrics
            && media != .idle
            && media.isPlaying
            && lyricsEligible(for: media)
    }

    /// Menu-bar strip visibility — same eligibility as notch, independent toggle.
    var showsMenuBarLyricsStrip: Bool {
        showMenuBarLyrics
            && media != .idle
            && media.isPlaying
            && lyricsEligible(for: media)
    }

    var currentLyricsLine: String {
        lyricsPayload.line(at: media.estimatedElapsed())
    }

    func lyricsEligible(for snapshot: MediaSnapshot) -> Bool {
        MediaLyricsPolicy.supportsLyrics(
            for: snapshot,
            customBundleIdentifiers: Set(customMusicBundleIdentifiers)
        )
    }

    func applyMediaSnapshot(_ snapshot: MediaSnapshot) {
        let previous = media
        var next = snapshot
        // Keep the last cover when a progress-only update omits artwork bytes.
        if next.artworkData == nil,
           previous != .idle,
           previous.title == next.title,
           previous.artist == next.artist,
           previous.bundleIdentifier == next.bundleIdentifier {
            next.artworkData = previous.artworkData
        }
        media = next
        applyHealth(
            next == .idle
                ? .warning("未检测到正在播放的曲目")
                : .ready("正在读取 \(next.sourceName)"),
            to: .media
        )

        let trackChanged = previous == .idle
            || next == .idle
            || previous.title != next.title
            || previous.artist != next.artist
            || previous.bundleIdentifier != next.bundleIdentifier

        let canShowLyrics = lyricsEligible(for: next)
        if !canShowLyrics {
            if lyricsEligible(for: previous) || lyricsPayload.hasContent || isFetchingLyrics {
                lyricsService.cancel()
                lyricsPayload = .empty
                isFetchingLyrics = false
            }
            return
        }

        if trackChanged {
            lyricsService.refresh(for: next) { [weak self] (payload: LyricsPayload, fetching: Bool) in
                guard let self else { return }
                self.lyricsPayload = payload
                self.isFetchingLyrics = fetching
            }
        } else if next == .idle {
            lyricsPayload = .empty
            isFetchingLyrics = false
        }
    }

    func addCustomMusicBundleIdentifier(_ raw: String) -> Bool {
        let id = MediaLyricsPolicy.normalizeBundleIdentifier(raw)
        guard !id.isEmpty else { return false }
        guard !customMusicBundleIdentifiers.contains(id) else { return true }
        customMusicBundleIdentifiers.append(id)
        customMusicBundleIdentifiers.sort()
        objectWillChange.send()
        // Re-evaluate current track against the new allowlist.
        applyMediaSnapshot(media)
        return true
    }

    func removeCustomMusicBundleIdentifier(_ raw: String) {
        let id = MediaLyricsPolicy.normalizeBundleIdentifier(raw)
        customMusicBundleIdentifiers.removeAll { $0 == id }
        applyMediaSnapshot(media)
    }

    func lyricsPeekExtraWidth(at date: Date = Date()) -> CGFloat {
        0
    }
}
