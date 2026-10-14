import SwiftUI

struct LyricLine: Equatable {
    var time: Double
    var text: String
}

/// Time-synced lyrics from LRCLIB, a free, open lyrics database. Fetched once per song and kept for the session.
@Observable
final class LyricsStore {
    static let shared = LyricsStore()
    /// Lines for the song playing now; empty when there are none.
    private(set) var lines: [LyricLine] = []
    private(set) var loading = false
    private(set) var instrumental = false
    private var key = ""
    private var cache: [String: [LyricLine]] = [:]

    /// Called on every Now Playing update; only does work when the song changes.
    func trackChanged(_ info: NowPlaying?) {
        let prefs = Settings.shared.prefs
        // Song titles only go to LRCLIB while lyrics are actually on screen somewhere.
        let wanted = prefs.lyricsEnabled && (prefs.mediaShowLyrics || prefs.lyricsInGlance)
        guard wanted, let info, !info.title.isEmpty else {
            key = ""
            lines = []
            loading = false
            return
        }
        let newKey = "\(info.title)|\(info.artist)"
        guard newKey != key else { return }
        key = newKey
        instrumental = false
        if let cached = cache[newKey] {
            lines = cached
            loading = false
            return
        }
        lines = []
        loading = true
        fetch(info) { [weak self] lines, instrumental, reached in
            guard let self else { return }
            if reached { cache[newKey] = lines }  // a dropped connection isn't "no lyrics"
            guard key == newKey else { return }
            loading = false
            self.instrumental = instrumental
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { self.lines = lines }
        }
    }

    /// `reached`: LRCLIB answered (lyrics or a definite "none").
    private func fetch(_ info: NowPlaying, done: @escaping ([LyricLine], Bool, Bool) -> Void) {
        var components = URLComponents(string: "https://lrclib.net/api/get")!
        components.queryItems = [.init(name: "track_name", value: Self.cleanTitle(info.title)),
                                 .init(name: "artist_name", value: info.artist)]
        if !info.album.isEmpty { components.queryItems?.append(.init(name: "album_name", value: info.album)) }
        if info.duration > 0 { components.queryItems?.append(.init(name: "duration", value: String(Int(info.duration.rounded())))) }
        request(components.url!) { json, _ in
            if let json = json as? [String: Any], let lines = Self.lines(from: json) {
                return DispatchQueue.main.async { done(lines, json["instrumental"] as? Bool ?? false, true) }
            }
            // No exact match (album or length differ): search and take the closest synced result.
            var search = URLComponents(string: "https://lrclib.net/api/search")!
            search.queryItems = [.init(name: "track_name", value: Self.cleanTitle(info.title)),
                                 .init(name: "artist_name", value: info.artist)]
            self.request(search.url!) { json, reached in
                let results = (json as? [[String: Any]] ?? [])
                    .filter { $0["syncedLyrics"] is String }
                    .sorted { abs(($0["duration"] as? Double ?? 0) - info.duration) < abs(($1["duration"] as? Double ?? 0) - info.duration) }
                let lines = results.first.flatMap(Self.lines(from:)) ?? []
                DispatchQueue.main.async { done(lines, false, reached) }
            }
        }
    }

    /// Calls back with the JSON (nil if none) and whether the server answered at all.
    private func request(_ url: URL, done: @escaping (Any?, Bool) -> Void) {
        var request = URLRequest(url: url)
        request.setValue("notchd (https://github.com/\(Updater.repo))", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10
        URLSession.shared.dataTask(with: request) { data, response, _ in
            guard let status = (response as? HTTPURLResponse)?.statusCode else { return done(nil, false) }
            guard status == 200, let data else { return done(nil, status == 404) }
            done(try? JSONSerialization.jsonObject(with: data), true)
        }.resume()
    }

    private static func lines(from json: [String: Any]) -> [LyricLine]? {
        guard let synced = json["syncedLyrics"] as? String else { return nil }
        let lines = parse(synced)
        return lines.isEmpty ? nil : lines
    }

    /// "Song (Remastered 2011)" and "Song - Live" search better as "Song".
    static func cleanTitle(_ title: String) -> String {
        var t = title
        for pattern in [#"\s*[\(\[][^\)\]]*(remaster|live|version|edit|mix|mono|stereo|deluxe)[^\)\]]*[\)\]]"#,
                        #"\s+-\s+.*(remaster|live|version|edit|mix).*$"#] {
            t = t.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// Parses LRC: "[01:23.45] words", several time tags per line allowed, metadata tags skipped.
    static func parse(_ lrc: String) -> [LyricLine] {
        let tag = try! NSRegularExpression(pattern: #"\[(\d+):(\d+(?:[.:]\d+)?)\]"#)
        var lines: [LyricLine] = []
        for raw in lrc.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            let range = NSRange(line.startIndex..., in: line)
            let matches = tag.matches(in: line, range: range)
            guard let last = matches.last, let end = Range(last.range, in: line) else { continue }
            let text = line[end.upperBound...].trimmingCharacters(in: .whitespaces)
            for match in matches {
                guard let m = Range(match.range(at: 1), in: line), let s = Range(match.range(at: 2), in: line),
                      let minutes = Double(line[m]),
                      let seconds = Double(line[s].replacingOccurrences(of: ":", with: ".")) else { continue }
                lines.append(LyricLine(time: minutes * 60 + seconds, text: text))
            }
        }
        return lines.sorted { $0.time < $1.time }
    }

    /// Index of the line being sung at `position`, nil before the first one.
    static func index(in lines: [LyricLine], at position: Double) -> Int? {
        var low = 0, high = lines.count - 1, found: Int?
        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].time <= position { found = mid; low = mid + 1 } else { high = mid - 1 }
        }
        return found
    }

    func current(at position: Double) -> String? {
        Self.index(in: lines, at: position).map { lines[$0].text }.flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// Three lines around the current one, the sung line bright, scrolling as the song plays.
struct LyricsView: View {
    let info: NowPlaying
    private var store = LyricsStore.shared

    init(info: NowPlaying) { self.info = info }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { timeline in
            let lines = store.lines
            let position = info.position(at: timeline.date) + 0.3  // sung a hair early reads better than late
            let index = LyricsStore.index(in: lines, at: position)
            VStack(alignment: .leading, spacing: 3) {
                if lines.isEmpty {
                    Text(store.loading ? "Looking for lyrics…" : store.instrumental ? "Instrumental" : "No lyrics for this song")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(-1...1, id: \.self) { offset in
                        let i = (index ?? -1) + offset
                        let text = lines.indices.contains(i) ? lines[i].text : ""
                        Text(text.isEmpty ? " " : text)
                            .font(.system(size: offset == 0 ? 12 : 10, weight: offset == 0 ? .semibold : .regular))
                            .foregroundStyle(offset == 0 ? AnyShapeStyle(info.tint) : AnyShapeStyle(.secondary))
                            .lineLimit(1)
                            .id("\(i)")
                            .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                                    removal: .move(edge: .top).combined(with: .opacity)))
                    }
                }
            }
            .font(.system(size: 11))
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.spring(response: 0.45, dampingFraction: 0.8), value: index)
        }
    }
}

/// The media Glance: the line being sung when lyrics are on, otherwise title and artist.
struct MediaGlance: View {
    let info: NowPlaying
    private var lyrics = LyricsStore.shared

    init(info: NowPlaying) { self.info = info }

    var body: some View {
        let prefs = Settings.shared.prefs
        if prefs.lyricsEnabled, prefs.lyricsInGlance, info.playing, !lyrics.lines.isEmpty {
            TimelineView(.periodic(from: .now, by: 0.25)) { timeline in
                let line = lyrics.current(at: info.position(at: timeline.date) + 0.3)
                HStack(spacing: 5) {
                    Image(systemName: "quote.opening").font(.system(size: 8)).foregroundStyle(info.tint)
                    Text(line ?? info.title).fontWeight(.semibold)
                        .id(line)
                        .transition(.push(from: .bottom))
                }
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: line)
            }
        } else {
            Text(info.title).fontWeight(.semibold)
            if !info.artist.isEmpty { Text("— \(info.artist)").foregroundStyle(.secondary) }
        }
    }
}
