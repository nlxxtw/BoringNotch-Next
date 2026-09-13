import XCTest

@testable import NotchTriage

final class LyricsServiceTests: XCTestCase {
    func testParseLRCExtractsTimedLines() {
        let lrc = """
        [00:12.00]第一句
        [00:18.50]第二句歌词
        [1:02.5]第三句
        """

        let lines = LyricsService.parseLRC(lrc)

        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0].time, 12, accuracy: 0.001)
        XCTAssertEqual(lines[0].text, "第一句")
        XCTAssertEqual(lines[1].time, 18.5, accuracy: 0.001)
        XCTAssertEqual(lines[2].time, 62.5, accuracy: 0.001)
    }

    func testPayloadSelectsCurrentLineAndProgress() {
        let payload = LyricsPayload(
            plainText: "",
            syncedLines: [
                LyricsSyncedLine(time: 0, text: "intro"),
                LyricsSyncedLine(time: 10, text: "verse"),
                LyricsSyncedLine(time: 20, text: "chorus"),
            ]
        )

        XCTAssertEqual(payload.line(at: 0), "intro")
        XCTAssertEqual(payload.line(at: 10), "verse")
        XCTAssertEqual(payload.line(at: 15), "verse")
        XCTAssertEqual(payload.line(at: 25), "chorus")
        XCTAssertEqual(payload.lineProgress(at: 15), 0.5, accuracy: 0.001)
    }

    func testLyricsPeekSurfaceWidthIsStable() {
        let compact: CGFloat = 220
        let playing = NotchLayout.lyricsPeekSurfaceWidth(
            compactSurfaceWidth: compact,
            showsTransport: true
        )
        let hovered = NotchLayout.peekSurfaceWidth(compactSurfaceWidth: compact)
        // Same silhouette as a normal peek — do not widen for lyrics/transport.
        XCTAssertEqual(playing, hovered)
        XCTAssertEqual(playing, compact)
    }

    func testLyricsPolicyAllowsMusicAppsAndBlocksBrowsers() {
        let spotify = MediaSnapshot(
            sourceName: "Spotify",
            bundleIdentifier: "com.spotify.client",
            title: "Song",
            artist: "Artist",
            duration: 200,
            elapsed: 10,
            isPlaying: true
        )
        let qq = MediaSnapshot(
            sourceName: "QQ 音乐",
            bundleIdentifier: "com.tencent.QQMusicMac",
            title: "歌",
            artist: "歌手",
            duration: 200,
            elapsed: 10,
            isPlaying: true
        )
        let chrome = MediaSnapshot(
            sourceName: "Chrome",
            bundleIdentifier: "com.google.Chrome",
            title: "YouTube video",
            artist: "Channel",
            duration: 600,
            elapsed: 10,
            isPlaying: true
        )
        let safari = MediaSnapshot(
            sourceName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            title: "Bilibili",
            artist: "",
            duration: 0,
            elapsed: 0,
            isPlaying: true
        )

        XCTAssertTrue(spotify.supportsLyricsPeek)
        XCTAssertTrue(qq.supportsLyricsPeek)
        XCTAssertFalse(chrome.supportsLyricsPeek)
        XCTAssertFalse(safari.supportsLyricsPeek)

        let unknownPlayer = MediaSnapshot(
            sourceName: "第三方播放器",
            bundleIdentifier: "com.example.CoolMusic",
            title: "Track",
            artist: "A",
            duration: 100,
            elapsed: 1,
            isPlaying: true
        )
        XCTAssertFalse(
            MediaLyricsPolicy.supportsLyrics(for: unknownPlayer)
        )
        XCTAssertTrue(
            MediaLyricsPolicy.supportsLyrics(
                for: unknownPlayer,
                customBundleIdentifiers: ["com.example.CoolMusic"]
            )
        )
    }

    func testParseMusicDLSearchHTMLExtractsKugouMatches() {
        let html = """
        <a href="/music/download_lrc?id=ABC123&source=kugou&name=%e7%a8%bb%e9%a6%99&artist=%e5%91%a8%e6%9d%b0%e4%bc%a6&album=X&duration=223" class="btn-lyric"></a>
        <a href="/music/download_lrc?id=LIVE1&source=kugou&name=%e7%a8%bb%e9%a6%99%20(Live)&artist=%e5%91%a8%e6%9d%b0%e4%bc%a6&album=&duration=200"></a>
        <a href="/music/download_lrc?id=OTHER&source=netease&name=foo&artist=bar&duration=100"></a>
        """

        let matches = LyricsService.parseMusicDLSearchHTML(html, allowedSource: "kugou")
        XCTAssertEqual(matches.count, 2)
        XCTAssertEqual(matches[0].id, "ABC123")
        XCTAssertEqual(matches[0].source, "kugou")
        XCTAssertEqual(matches[0].name, "稻香")
        XCTAssertEqual(matches[0].artist, "周杰伦")

        let best = LyricsService.pickBestMatch(
            from: matches,
            title: "稻香",
            artist: "周杰伦"
        )
        XCTAssertEqual(best?.id, "ABC123")
    }

    func testSourceMappingPrefersAppThenKugou() {
        XCTAssertEqual(
            LyricsSourceMapping.musicDLSources(
                bundleIdentifier: "com.tencent.QQMusicMac",
                sourceName: "QQ 音乐"
            ),
            ["qq", "kugou"]
        )
        XCTAssertEqual(
            LyricsSourceMapping.musicDLSources(
                bundleIdentifier: "com.netease.163music",
                sourceName: "网易云音乐"
            ),
            ["netease", "kugou"]
        )
        XCTAssertEqual(
            LyricsSourceMapping.musicDLSources(
                bundleIdentifier: "com.soda.music",
                sourceName: "汽水音乐"
            ),
            ["soda", "kugou"]
        )
        XCTAssertEqual(
            LyricsSourceMapping.musicDLSources(
                bundleIdentifier: "com.spotify.client",
                sourceName: "Spotify"
            ),
            ["kugou"]
        )
    }

    func testSodaMusicIsAllowedForLyricsPeek() {
        let soda = MediaSnapshot(
            sourceName: "汽水音乐",
            bundleIdentifier: "com.soda.music",
            title: "歌",
            artist: "歌手",
            duration: 200,
            elapsed: 10,
            isPlaying: true
        )
        XCTAssertTrue(soda.supportsLyricsPeek)
    }
}
