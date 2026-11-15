import Foundation

/// Intro / recap / credits times from the open, community-run skip databases, for episodes and
/// movies the server has no media segments for (the same two databases Infuse uses):
///   - TheIntroDB (api.theintrodb.org, API v4): asked first. Intro, recap, credits, preview.
///   - IntroDB (api.introdb.app): fills intro, recap or credits TheIntroDB doesn't have.
/// Anime is different: it is looked up in AniSkip only (see AniSkip.swift), never in those two.
/// All are read without an account or a key. Only the title's TVDB / TMDB / IMDb / MyAnimeList
/// ID, the season and episode number and the runtime are sent; nothing about the server, the
/// user or the file. The same logic as the desktop app's skipdb.ts.
enum SkipDatabase {
    /// The segment types a database can fill in (ads are never in them).
    static let types = ["Intro", "Recap", "Outro", "Preview"]

    /// What identifies a title in the databases.
    struct Lookup: Sendable {
        var itemId: String
        var movie: Bool
        var tvdb: Int?            // the series' (or movie's) TVDB ID
        var tmdb: Int?
        var imdb: String?         // "tt…"
        var season: Int?
        var episode: Int?
        var tvdbEpisode: Int?     // the episode's own TVDB ID: the same episode in every episode order
        var mapping: String?      // the series' episode order on the server, when it isn't the default one
        var durationMs: Double    // 0 = unknown
        var anime = AniSkip.Query()   // what tells whether it's anime, and where AniSkip has it
    }

    // MARK: Lookup

    /// Provider IDs are matched without regard to case ("Tvdb", "tvdb", "TVDB").
    private static func provider(_ ids: [String: String]?, _ name: String) -> String? {
        guard let ids else { return nil }
        for (key, value) in ids where key.lowercased() == name && !value.isEmpty { return value }
        return nil
    }

    private static func positiveInt(_ text: String?) -> Int? {
        guard let t = text?.trimmingCharacters(in: .whitespaces), !t.isEmpty,
              t.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(t), n > 0 else { return nil }
        return n
    }

    private static func imdbId(_ text: String?) -> String? {
        guard let t = text?.trimmingCharacters(in: .whitespaces), t.hasPrefix("tt"), t.count > 2,
              t.dropFirst(2).allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return t
    }

    /// Jellyfin's display orders that are TVDB episode orders TheIntroDB can convert from.
    private static let orders: Set<String> = ["dvd", "absolute", "alternate", "regional", "altdvd", "alttwo"]

    /// The anime side of a lookup: the title's own IDs (a movie's, or an episode's series').
    private static func animeQuery(owner: BaseItem, animeLibrary: Bool, genres: [[String]?]) -> AniSkip.Query {
        let ids = owner.providerIds
        var q = AniSkip.Query()
        q.tvdb = positiveInt(provider(ids, "tvdb"))
        q.tmdb = positiveInt(provider(ids, "tmdb"))
        q.imdb = imdbId(provider(ids, "imdb"))
        q.mal = positiveInt(provider(ids, "myanimelist") ?? provider(ids, "mal"))
        q.anilist = positiveInt(provider(ids, "anilist"))
        q.anidb = positiveInt(provider(ids, "anidb"))
        let genre = genres.contains { list in
            (list ?? []).contains { $0.trimmingCharacters(in: .whitespaces).lowercased() == "anime" }
        }
        q.hint = animeLibrary || genre || q.mal != nil || q.anilist != nil || q.anidb != nil
        return q
    }

    /// The lookup for an episode (with its series) or a movie; nil when it can't be looked up.
    /// `animeLibrary`: the title is in a library named Anime or Anime Movies.
    static func lookup(item: BaseItem, series: BaseItem?, animeLibrary: Bool = false) -> Lookup? {
        let durationMs = max(0, (Double(item.runTimeTicks ?? 0) / 10_000).rounded())
        if item.kind == .movie {
            var anime = animeQuery(owner: item, animeLibrary: animeLibrary, genres: [item.genres])
            anime.movie = true
            let l = Lookup(itemId: item.id, movie: true,
                           tvdb: positiveInt(provider(item.providerIds, "tvdb")),
                           tmdb: positiveInt(provider(item.providerIds, "tmdb")),
                           imdb: imdbId(provider(item.providerIds, "imdb")),
                           season: nil, episode: nil, tvdbEpisode: nil, mapping: nil, durationMs: durationMs,
                           anime: anime)
            return l.tvdb != nil || l.tmdb != nil || l.imdb != nil || anime.hint ? l : nil
        }
        guard item.kind == .episode, let series,
              let season = item.parentIndexNumber, let episode = item.indexNumber,
              season >= 0, episode >= 1 else { return nil }
        // One file holding several episodes: the times of its first episode don't fit the file.
        if let end = item.indexNumberEnd, end != episode { return nil }
        let order = (series.displayOrder ?? "").lowercased()
        var anime = animeQuery(owner: series, animeLibrary: animeLibrary, genres: [series.genres, item.genres])
        anime.season = season
        anime.episode = episode
        anime.tvdbNumbering = positiveInt(provider(item.providerIds, "tvdb")) != nil
        let l = Lookup(itemId: item.id, movie: false,
                       tvdb: positiveInt(provider(series.providerIds, "tvdb")),
                       tmdb: positiveInt(provider(series.providerIds, "tmdb")),
                       imdb: imdbId(provider(series.providerIds, "imdb")),
                       season: season, episode: episode,
                       tvdbEpisode: positiveInt(provider(item.providerIds, "tvdb")),
                       mapping: orders.contains(order) ? order : nil, durationMs: durationMs,
                       anime: anime)
        return l.tvdb != nil || l.tmdb != nil || l.imdb != nil || anime.hint ? l : nil
    }

    private static func url(_ base: String, _ query: [(String, String)]) -> URL? {
        var c = URLComponents(string: base)
        c?.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        return c?.url
    }

    /// TheIntroDB's address for a lookup: one ID per request, as its API reads the numbers by that
    /// ID's own numbering.
    static func theIntroDBURL(_ l: Lookup) -> URL? {
        var q: [(String, String)] = []
        if l.movie {
            if let tmdb = l.tmdb { q.append(("tmdb_id", String(tmdb))) }
            else if let imdb = l.imdb { q.append(("imdb_id", imdb)) }
            else if let tvdb = l.tvdb { q.append(("tvdb_id", String(tvdb))) }
            else { return nil }
        } else {
            guard let season = l.season, let episode = l.episode else { return nil }
            if let tvdb = l.tvdb, let pinned = l.tvdbEpisode {
                // The episode's own TVDB ID names the episode whatever order the numbers are in.
                q.append(("tvdb_id", String(tvdb)))
                q.append(("tvdb_episode_id", String(pinned)))
            } else if let tmdb = l.tmdb {
                q.append(("tmdb_id", String(tmdb)))
            } else if let tvdb = l.tvdb {
                q.append(("tvdb_id", String(tvdb)))
                if let mapping = l.mapping { q.append(("mapping", mapping)) }
            } else if let imdb = l.imdb {
                q.append(("imdb_id", imdb))
            } else { return nil }
            q.append(("season", String(season)))
            q.append(("episode", String(episode)))
        }
        if l.durationMs > 0 { q.append(("duration_ms", String(Int(l.durationMs)))) }
        return url("https://api.theintrodb.org/v4/media", q)
    }

    /// IntroDB's address for a lookup (it knows titles by IMDb ID only).
    static func introDBURL(_ l: Lookup) -> URL? {
        guard let imdb = l.imdb else { return nil }
        var q: [(String, String)] = [("imdb_id", imdb)]
        if l.movie {
            q.append(("is_movie", "true"))
        } else {
            guard let season = l.season, let episode = l.episode else { return nil }
            q.append(("season", String(season)))
            q.append(("episode", String(episode)))
        }
        return url("https://api.introdb.app/segments", q)
    }

    // MARK: Answers

    /// A time in a database's answer: a number that isn't negative (null, text and the like: nil).
    private static func ms(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let v = n.doubleValue
        return v.isFinite && v >= 0 ? v : nil
    }

    /// One database entry as a media segment, or nil when it can't be right for this file.
    static func segment(source: String, type: String, startMs: Double?, endMs: Double?, _ l: Lookup) -> MediaSegment? {
        let duration = l.durationMs
        let start = max(0, startMs ?? 0)            // no start: from the beginning
        var end = endMs ?? duration                 // no end: to the end of the file
        if duration > 0 { end = min(end, duration) }
        guard end - start >= 2000 else { return nil }
        if duration > 0 {
            // An intro in the second half or credits in the first belong to another cut or another episode.
            let early = type == "Intro" || type == "Recap"
            if early ? start >= duration / 2 : start < duration / 2 { return nil }
        }
        let a = Int64(start.rounded()), b = Int64(end.rounded())
        return MediaSegment(id: "skipdb:\(source):\(type):\(a)", itemId: l.itemId, type: type,
                            startTicks: a * 10_000, endTicks: b * 10_000)
    }

    /// TheIntroDB's answer: { intro: [{ start_ms, end_ms }], recap: […], credits: […], preview: […] }.
    static func parseTheIntroDB(_ body: Any?, _ l: Lookup) -> [MediaSegment] {
        guard let o = body as? [String: Any] else { return [] }
        // An answer for another episode than the one asked for is not used (an episode named by
        // its own TVDB ID may come back under that order's numbers).
        if !l.movie, !(l.tvdb != nil && l.tvdbEpisode != nil) {
            if let season = ms(o["season"]), Int(season) != l.season { return [] }
            if let episode = ms(o["episode"]), Int(episode) != l.episode { return [] }
        }
        var out: [MediaSegment] = []
        for (key, type) in [("intro", "Intro"), ("recap", "Recap"), ("credits", "Outro"), ("preview", "Preview")] {
            guard let list = o[key] as? [Any] else { continue }
            for entry in list.prefix(6) {
                guard let e = entry as? [String: Any] else { continue }
                let start = ms(e["start_ms"]), end = ms(e["end_ms"])
                if start == nil && end == nil { continue }
                if let seg = segment(source: "tidb", type: type, startMs: start, endMs: end, l) { out.append(seg) }
            }
        }
        return out
    }

    /// IntroDB's answer: { intro: { start_ms, end_ms } | null, recap: …, outro: … }.
    static func parseIntroDB(_ body: Any?, _ l: Lookup) -> [MediaSegment] {
        guard let o = body as? [String: Any] else { return [] }
        var out: [MediaSegment] = []
        for (key, type) in [("intro", "Intro"), ("recap", "Recap"), ("outro", "Outro")] {
            guard let e = o[key] as? [String: Any] else { continue }
            guard let start = ms(e["start_ms"]) ?? ms(e["start_sec"]).map({ $0 * 1000 }),
                  let end = ms(e["end_ms"]) ?? ms(e["end_sec"]).map({ $0 * 1000 }) else { continue }
            if let seg = segment(source: "idb", type: type, startMs: start, endMs: end, l) { out.append(seg) }
        }
        return out
    }

    /// The server's segments, plus the databases' for the types the server has none of.
    static func merge(_ server: [MediaSegment], _ found: [MediaSegment]) -> [MediaSegment] {
        let have = Set(server.map(\.type))
        return (server + found.filter { !have.contains($0.type) }).sorted { $0.startTicks < $1.startTicks }
    }

    // MARK: Asking

    private enum Answer {
        case body(Any)
        case nothing          // the database has no entry (404)
        case unreachable      // no answer, or one that can't be read: ask again next time
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        config.httpCookieStorage = nil
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    private static func ask(_ url: URL) async -> Answer {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("JellyReco (iOS)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return .unreachable }
        if http.statusCode == 404 || http.statusCode == 204 { return .nothing }
        guard (200..<300).contains(http.statusCode), data.count < 1_000_000,
              let json = try? JSONSerialization.jsonObject(with: data) else { return .unreachable }
        return .body(json)
    }

    /// Answers kept for the session, by item.
    private actor Cache {
        private var found: [String: [MediaSegment]] = [:]
        func get(_ id: String) -> [MediaSegment]? { found[id] }
        func set(_ id: String, _ segments: [MediaSegment]) {
            if found.count >= 300 { found.removeAll() }
            found[id] = segments
        }
    }
    private static let cache = Cache()

    /// Segments from the databases for the types in `wanted`; none when there are none or the
    /// databases can't be reached.
    static func segments(for l: Lookup, wanted: [String]) async -> [MediaSegment] {
        guard !wanted.isEmpty else { return [] }
        var all: [MediaSegment]
        if let cached = await cache.get(l.itemId) {
            all = cached
        } else {
            all = []
            var complete = true
            // Anime: AniSkip only. Everything else: TheIntroDB, then IntroDB.
            let anime = await AniSkip.segments(l.anime, durationMs: l.durationMs) { type, start, end in
                segment(source: "aniskip", type: type, startMs: start, endMs: end, l)
            }
            if anime.anime {
                if anime.complete { await cache.set(l.itemId, anime.segments) }
                return anime.segments.filter { wanted.contains($0.type) }
            }
            if let first = theIntroDBURL(l) {
                switch await ask(first) {
                case .body(let json): all = parseTheIntroDB(json, l)
                case .nothing: break
                case .unreachable: complete = false
                }
            }
            // IntroDB only for what TheIntroDB doesn't have.
            let have = Set(all.map(\.type))
            if ["Intro", "Recap", "Outro"].contains(where: { !have.contains($0) }), let second = introDBURL(l) {
                switch await ask(second) {
                case .body(let json): all += parseIntroDB(json, l).filter { !have.contains($0.type) }
                case .nothing: break
                case .unreachable: complete = false
                }
            }
            // An answer is kept for the session; a database that couldn't be reached is asked again next time.
            if complete { await cache.set(l.itemId, all) }
        }
        return all.filter { wanted.contains($0.type) }
    }
}
