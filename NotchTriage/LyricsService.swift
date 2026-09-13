import AppKit
import Foundation

struct LyricsSyncedLine: Equatable, Sendable {
    var time: TimeInterval
    var text: String
}

struct LyricsPayload: Equatable, Sendable {
    var plainText: String
    var syncedLines: [LyricsSyncedLine]

    static let empty = LyricsPayload(plainText: "", syncedLines: [])

    var hasContent: Bool {
        !syncedLines.isEmpty || !plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func lineIndex(at elapsed: TimeInterval) -> Int? {
        guard !syncedLines.isEmpty else { return nil }
        var low = 0
        var high = syncedLines.count - 1
        var idx = 0
        while low <= high {
            let mid = (low + high) / 2
            if syncedLines[mid].time <= elapsed {
                idx = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return idx
    }

    func line(at elapsed: TimeInterval) -> String {
        if let idx = lineIndex(at: elapsed) {
            return syncedLines[idx].text
        }
        let trimmed = plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return trimmed
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            ?? trimmed
    }

    /// Approximate karaoke fill within the current synced line.
    func lineProgress(at elapsed: TimeInterval) -> Double {
        guard let idx = lineIndex(at: elapsed) else { return 0 }
        let start = syncedLines[idx].time
        let end: TimeInterval
        if idx + 1 < syncedLines.count {
            end = syncedLines[idx + 1].time
        } else {
            end = start + 4
        }
        guard end > start else { return 0 }
        return min(1, max(0, (elapsed - start) / (end - start)))
    }
}

/// Resolves music-dl `sources=` values from the playing app.
enum LyricsSourceMapping {
    static let kugou = "kugou"

    /// App-mapped source first, then Kugou if not already included.
    static func musicDLSources(
        bundleIdentifier: String?,
        sourceName: String
    ) -> [String] {
        var ordered: [String] = []
        func push(_ source: String) {
            guard !ordered.contains(source) else { return }
            ordered.append(source)
        }

        let id = (bundleIdentifier ?? "").lowercased()
        let name = sourceName.lowercased()

        if id.contains("qqmusic") || name.contains("qq") {
            push("qq")
        } else if id.contains("netease")
                    || id.contains("163music")
                    || id.contains("cloudmusic")
                    || name.contains("网易") {
            push("netease")
        } else if id.contains("soda")
                    || id.contains("qishui")
                    || name.contains("汽水") {
            push("soda")
        } else if id.contains("kugou") || name.contains("酷狗") {
            push("kugou")
        } else if id.contains("kuwo") || name.contains("酷我") {
            push("kuwo")
        } else if id.contains("com.apple.music")
                    || id.contains("com.apple.itunes")
                    || name.contains("apple music") {
            push("apple")
        }

        push(kugou)
        return ordered
    }
}

/// Fetches synced lyrics: app-mapped music-dl → Kugou → LRCLIB.
@MainActor
final class LyricsService {
    static var musicDLBaseURL: URL? { LyricsAPIConfig.musicDLBaseURL }
    static let lrclibBaseURL = URL(string: "https://lrclib.net")!
    static let requestTimeout: TimeInterval = 10

    private var fetchTask: Task<Void, Never>?
    private var activeTrackKey: String?

    func cancel() {
        fetchTask?.cancel()
        fetchTask = nil
        activeTrackKey = nil
    }

    func refresh(
        for snapshot: MediaSnapshot,
        onUpdate: @escaping @MainActor (LyricsPayload, Bool) -> Void
    ) {
        guard snapshot != .idle else {
            cancel()
            onUpdate(.empty, false)
            return
        }

        let title = snapshot.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty,
              title != MediaSnapshot.idle.title else {
            cancel()
            onUpdate(.empty, false)
            return
        }

        let artist = snapshot.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = "\(snapshot.bundleIdentifier ?? "")|\(title)|\(artist)"
        guard key != activeTrackKey else { return }

        activeTrackKey = key
        fetchTask?.cancel()
        onUpdate(.empty, true)

        let bundleIdentifier = snapshot.bundleIdentifier
        let sourceName = snapshot.sourceName
        let duration = snapshot.duration

        fetchTask = Task { @MainActor in
            let payload = await Self.fetchLyricsCascade(
                title: title,
                artist: artist,
                duration: duration,
                bundleIdentifier: bundleIdentifier,
                sourceName: sourceName
            )
            guard !Task.isCancelled, self.activeTrackKey == key else { return }
            onUpdate(payload, false)
        }
    }

    /// App-mapped API → Kugou → LRCLIB. Stops on first hit.
    static func fetchLyricsCascade(
        title: String,
        artist: String,
        duration: TimeInterval,
        bundleIdentifier: String?,
        sourceName: String
    ) async -> LyricsPayload {
        let cleanTitle = normalizedQuery(title)
        let cleanArtist = normalizedQuery(artist)
        let sources = LyricsSourceMapping.musicDLSources(
            bundleIdentifier: bundleIdentifier,
            sourceName: sourceName
        )

        for source in sources {
            if Task.isCancelled { return .empty }
            let payload = await fetchFromMusicDL(
                title: cleanTitle,
                artist: cleanArtist,
                source: source
            )
            if payload.hasContent { return payload }
        }

        if Task.isCancelled { return .empty }
        return await fetchFromLRCLIB(
            title: cleanTitle,
            artist: cleanArtist,
            duration: duration
        )
    }

    /// music-dl web API: HTML search → `/music/lyric` LRC for one source.
    private static func fetchFromMusicDL(
        title: String,
        artist: String,
        source: String
    ) async -> LyricsPayload {
        guard musicDLBaseURL != nil else { return .empty }
        guard let match = await searchMusicDLSong(
            title: title,
            artist: artist,
            source: source
        ) else {
            return .empty
        }

        do {
            guard let url = lyricURL(for: match) else { return .empty }
            var request = URLRequest(url: url)
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            request.setValue("text/plain,*/*", forHTTPHeaderField: "Accept")
            request.timeoutInterval = requestTimeout

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return .empty
            }
            guard let lrc = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !lrc.isEmpty,
                  !isEmptyLyricPlaceholder(lrc) else {
                return .empty
            }

            let synced = parseLRC(lrc)
            return LyricsPayload(plainText: lrc, syncedLines: synced)
        } catch {
            return .empty
        }
    }

    private static func searchMusicDLSong(
        title: String,
        artist: String,
        source: String
    ) async -> MusicDLSongMatch? {
        guard let base = musicDLBaseURL else { return nil }
        var components = URLComponents(
            url: base.appendingPathComponent("music/search"),
            resolvingAgainstBaseURL: false
        )
        let query = [title, artist]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "type", value: "song"),
            URLQueryItem(name: "sources", value: source),
        ]
        guard let url = components?.url else { return nil }

        do {
            var request = URLRequest(url: url)
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            request.setValue("text/html", forHTTPHeaderField: "Accept")
            request.timeoutInterval = requestTimeout

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let html = String(data: data, encoding: .utf8) else {
                return nil
            }

            let matches = parseMusicDLSearchHTML(html, allowedSource: source)
            return pickBestMatch(from: matches, title: title, artist: artist)
        } catch {
            return nil
        }
    }

    static func parseMusicDLSearchHTML(
        _ html: String,
        allowedSource: String? = nil
    ) -> [MusicDLSongMatch] {
        guard let regex = try? NSRegularExpression(
            pattern: #"href=["']/music/download_lrc\?([^"']+)["']"#,
            options: [.caseInsensitive]
        ) else {
            return []
        }

        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        var results: [MusicDLSongMatch] = []
        var seen = Set<String>()

        for match in matches {
            guard match.numberOfRanges >= 2 else { continue }
            let query = ns.substring(with: match.range(at: 1))
            guard let song = MusicDLSongMatch(query: query) else { continue }
            if let allowedSource, song.source != allowedSource { continue }
            let key = "\(song.id)|\(song.name)|\(song.artist)"
            guard seen.insert(key).inserted else { continue }
            results.append(song)
        }
        return results
    }

    static func pickBestMatch(
        from matches: [MusicDLSongMatch],
        title: String,
        artist: String
    ) -> MusicDLSongMatch? {
        guard !matches.isEmpty else { return nil }
        let wantTitle = normalizeForMatch(title)
        let wantArtist = normalizeForMatch(artist)

        func score(_ song: MusicDLSongMatch) -> Int {
            let gotTitle = normalizeForMatch(song.name)
            let gotArtist = normalizeForMatch(song.artist)
            var value = 0
            if gotTitle == wantTitle { value += 100 }
            else if gotTitle.contains(wantTitle) || wantTitle.contains(gotTitle) { value += 60 }
            if !wantArtist.isEmpty {
                if gotArtist == wantArtist { value += 40 }
                else if gotArtist.contains(wantArtist) || wantArtist.contains(gotArtist) { value += 20 }
            }
            let lowered = gotTitle.lowercased()
            if lowered.contains("remix") || lowered.contains("live") || lowered.contains("纯音乐") {
                value -= 25
            }
            return value
        }

        return matches.max(by: { score($0) < score($1) })
    }

    private static func lyricURL(for song: MusicDLSongMatch) -> URL? {
        guard let base = musicDLBaseURL else { return nil }
        var components = URLComponents(
            url: base.appendingPathComponent("music/lyric"),
            resolvingAgainstBaseURL: false
        )
        var items = [
            URLQueryItem(name: "id", value: song.id),
            URLQueryItem(name: "source", value: song.source),
            URLQueryItem(name: "name", value: song.name),
            URLQueryItem(name: "artist", value: song.artist),
            URLQueryItem(name: "album", value: song.album),
            URLQueryItem(name: "duration", value: String(song.duration)),
            URLQueryItem(name: "format", value: "line"),
        ]
        if let extra = song.extra, !extra.isEmpty {
            items.append(URLQueryItem(name: "extra", value: extra))
        }
        components?.queryItems = items
        return components?.url
    }

    /// Public LRCLIB fallback (no API key). May return Traditional Chinese.
    private static func fetchFromLRCLIB(
        title: String,
        artist: String,
        duration: TimeInterval
    ) async -> LyricsPayload {
        var components = URLComponents(
            url: lrclibBaseURL.appendingPathComponent("api/search"),
            resolvingAgainstBaseURL: false
        )
        var items = [URLQueryItem(name: "track_name", value: title)]
        if !artist.isEmpty {
            items.append(URLQueryItem(name: "artist_name", value: artist))
        }
        components?.queryItems = items
        guard let url = components?.url else { return .empty }

        do {
            var request = URLRequest(url: url)
            request.setValue(
                "NotchTriage (https://github.com/nlxxtw/Notch-Triage)",
                forHTTPHeaderField: "User-Agent"
            )
            request.timeoutInterval = requestTimeout

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return .empty
            }

            let records = try JSONDecoder().decode([LRCLIBSearchRecord].self, from: data)
            guard let best = pickBestLRCLIB(
                from: records,
                title: title,
                artist: artist,
                duration: duration
            ) else {
                return .empty
            }

            let lrc = (best.syncedLyrics ?? best.plainLyrics ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !lrc.isEmpty, !isEmptyLyricPlaceholder(lrc) else { return .empty }

            let synced = parseLRC(lrc)
            return LyricsPayload(plainText: lrc, syncedLines: synced)
        } catch {
            return .empty
        }
    }

    static func pickBestLRCLIB(
        from records: [LRCLIBSearchRecord],
        title: String,
        artist: String,
        duration: TimeInterval
    ) -> LRCLIBSearchRecord? {
        let candidates = records.filter {
            !($0.instrumental ?? false)
                && (($0.syncedLyrics?.isEmpty == false) || ($0.plainLyrics?.isEmpty == false))
        }
        guard !candidates.isEmpty else { return nil }

        let wantTitle = normalizeForMatch(title)
        let wantArtist = normalizeForMatch(artist)

        func score(_ record: LRCLIBSearchRecord) -> Int {
            let gotTitle = normalizeForMatch(record.trackName ?? record.name ?? "")
            let gotArtist = normalizeForMatch(record.artistName ?? "")
            var value = 0
            if gotTitle == wantTitle { value += 100 }
            else if gotTitle.contains(wantTitle) || wantTitle.contains(gotTitle) { value += 60 }
            if !wantArtist.isEmpty {
                if gotArtist == wantArtist { value += 40 }
                else if gotArtist.contains(wantArtist) || wantArtist.contains(gotArtist) { value += 20 }
            }
            if let synced = record.syncedLyrics, !synced.isEmpty { value += 25 }
            if duration > 0, let remote = record.duration, remote > 0 {
                let delta = abs(remote - duration)
                if delta <= 2 { value += 20 }
                else if delta <= 5 { value += 10 }
                else if delta > 15 { value -= 20 }
            }
            return value
        }

        return candidates.max(by: { score($0) < score($1) })
    }

    private static func isEmptyLyricPlaceholder(_ lrc: String) -> Bool {
        let trimmed = lrc.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains("纯音乐") || trimmed.contains("无歌词")
    }

    static func parseLRC(_ lrc: String) -> [LyricsSyncedLine] {
        var result: [LyricsSyncedLine] = []
        let pattern = #"\[(\d{1,2}):(\d{2})(?:\.(\d{1,3}))?\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        for lineSub in lrc.split(separator: "\n") {
            let line = String(lineSub)
            let nsLine = line as NSString
            let matches = regex.matches(
                in: line,
                range: NSRange(location: 0, length: nsLine.length)
            )
            guard let match = matches.first else { continue }

            let minutes = Double(nsLine.substring(with: match.range(at: 1))) ?? 0
            let seconds = Double(nsLine.substring(with: match.range(at: 2))) ?? 0
            let fractionRange = match.range(at: 3)
            let fraction: Double
            if fractionRange.location != NSNotFound {
                let raw = nsLine.substring(with: fractionRange)
                let divisor = pow(10.0, Double(raw.count))
                fraction = (Double(raw) ?? 0) / divisor
            } else {
                fraction = 0
            }

            let time = minutes * 60 + seconds + fraction
            let textStart = match.range.location + match.range.length
            let text = nsLine.substring(from: textStart)
                .trimmingCharacters(in: .whitespaces)
            if !text.isEmpty {
                result.append(LyricsSyncedLine(time: time, text: text))
            }
        }

        return result.sorted { $0.time < $1.time }
    }

    private static func normalizedQuery(_ string: String) -> String {
        string
            .folding(options: .diacriticInsensitive, locale: .current)
            .replacingOccurrences(of: "\u{FFFD}", with: "")
    }

    private static func normalizeForMatch(_ string: String) -> String {
        normalizedQuery(string)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "　", with: "")
    }
}

struct MusicDLSongMatch: Equatable, Sendable {
    var id: String
    var source: String
    var name: String
    var artist: String
    var album: String
    var duration: Int
    var extra: String?

    init?(query: String) {
        guard let items = URLComponents(string: "https://x.local/?" + query)?.queryItems else {
            return nil
        }
        func value(_ name: String) -> String {
            items.first(where: { $0.name == name })?.value?
                .removingPercentEncoding
                ?? items.first(where: { $0.name == name })?.value
                ?? ""
        }

        let id = value("id")
        let source = value("source")
        guard !id.isEmpty, !source.isEmpty else { return nil }

        self.id = id
        self.source = source
        self.name = value("name")
        self.artist = value("artist")
        self.album = value("album")
        self.duration = Int(value("duration")) ?? 0
        let extraValue = value("extra")
        self.extra = extraValue.isEmpty ? nil : extraValue
    }
}

struct LRCLIBSearchRecord: Decodable, Equatable, Sendable {
    var id: Int?
    var name: String?
    var trackName: String?
    var artistName: String?
    var albumName: String?
    var duration: Double?
    var instrumental: Bool?
    var plainLyrics: String?
    var syncedLyrics: String?
}
