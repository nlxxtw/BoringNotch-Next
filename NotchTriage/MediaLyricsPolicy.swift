import Foundation

/// Lyrics peek / fetch only for known music players — not browsers or video apps.
enum MediaLyricsPolicy {
    /// Exact bundle IDs for common Mac music clients.
    static let musicBundleIdentifiers: Set<String> = [
        "com.apple.music",
        "com.apple.itunes",
        "com.spotify.client",
        "com.tencent.qqmusicmac",
        "com.netease.163music",
        "com.netease.cloudmusicmac",
        "com.netease.macmusic",
        "com.soda.music",
        "com.kugou.mac",
        "com.kugou.kugoumac",
        "com.kuwo.kwmusicmac",
        "com.tidal.desktop",
        "com.aspiro.tidal",
        "com.deezer.deezerdesktop",
        "com.amazon.aiv.aivapp",
        "com.apple.amp.mediaplayeragent",
        "com.github.th-ch.youtube-music",
        "app.ytmd",
        "com.electron.youtube-music",
    ]

    /// Loose match for lesser-known / renamed music clients.
    private static let musicBundleKeywords: [String] = [
        "spotify",
        "qqmusic",
        "netease",
        "163music",
        "cloudmusic",
        "soda",
        "qishui",
        "kugou",
        "kuwo",
        "tidal",
        "deezer",
        "youtubemusic",
        "youtube-music",
        "ytmusic",
        "music.desktop",
        "foobar2000",
        "cider",
    ]

    /// Never treat these as lyric sources even if MediaRemote reports a title.
    private static let excludedBundleKeywords: [String] = [
        "chrome",
        "chromium",
        "safari",
        "firefox",
        "edge",
        "opera",
        "brave",
        "arc",
        "thebrowser",
        "vivaldi",
        "webkit",
        "vlc",
        "iina",
        "quicktime",
        "com.apple.tv",
        "mpv",
        "potplayer",
        "discord",
        "zoom.us",
        "teams",
        "slack",
        "wechat",
        "telegram",
        "podcasts",
    ]

    private static let knownMusicSourceNames: Set<String> = [
        "Apple Music",
        "Spotify",
        "QQ 音乐",
        "网易云音乐",
        "汽水音乐",
        "酷狗音乐",
        "酷我音乐",
        "TIDAL",
        "Deezer",
        "YouTube Music",
    ]

    static func normalizeBundleIdentifier(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Whether the now-playing source should drive lyrics peek + lyric fetch.
    static func supportsLyrics(
        for snapshot: MediaSnapshot,
        customBundleIdentifiers: Set<String> = []
    ) -> Bool {
        guard snapshot != .idle else { return false }

        if let raw = snapshot.bundleIdentifier,
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let id = normalizeBundleIdentifier(raw)
            if excludedBundleKeywords.contains(where: { id.contains($0) }) {
                return false
            }
            if musicBundleIdentifiers.contains(id) {
                return true
            }
            let custom = Set(customBundleIdentifiers.map(normalizeBundleIdentifier))
            if custom.contains(id) {
                return true
            }
            if musicBundleKeywords.contains(where: { id.contains($0) }) {
                return true
            }
            return false
        }

        // No bundle id: only trust already-labeled music sources (e.g. AX QQ Music).
        return knownMusicSourceNames.contains(snapshot.sourceName)
    }
}

extension MediaSnapshot {
    /// Built-in allowlist only (no custom IDs). Prefer AppModel.lyricsEligible(for:).
    var supportsLyricsPeek: Bool {
        MediaLyricsPolicy.supportsLyrics(for: self)
    }
}
