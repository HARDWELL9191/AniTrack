import Foundation

/// Anime: opening / ending / recap times from AniSkip (api.aniskip.com), the open skip database
/// for anime. AniSkip knows a show by its MyAnimeList ID, where every season or cour is its own
/// entry that counts its episodes from 1, so a server's "series + season + episode" is first
/// turned into "MyAnimeList ID + episode" with the open anime ID list (Fribb/anime-lists, the
/// AniDB / TVDB / TMDB / AniList / MyAnimeList crosswalk), which also tells whether a title is
/// anime at all. The list is downloaded once a week and kept as a small index.
/// The same logic as the desktop app's aniskip.ts.
enum AniSkip {
    /// What the server knows about the title being played.
    struct Query: Sendable {
        var movie = false
        var tvdb: Int?            // the series' (or movie's) IDs
        var tmdb: Int?
        var imdb: String?
        var mal: Int?             // IDs from anime metadata plugins
        var anilist: Int?
        var anidb: Int?
        var season: Int?
        var episode: Int?
        /// The episode has its own TVDB ID: the server's numbers are most likely TVDB's.
        var tvdbNumbering = true
        /// Anime by the server's own account: an Anime / Anime Movies library, an "Anime" genre,
        /// or anime plugin IDs.
        var hint = false
    }

    struct Target: Equatable, Sendable {
        var mal: Int
        var episode: Int
    }

    // MARK: The anime ID index

    /// What is kept of the anime ID list.
    struct Index: Codable, Sendable {
        var at: Double                      // when it was downloaded (seconds since 1970)
        /// Entries with a TVDB or TMDB series ID:
        /// [mal, tvdb, tvdbSeason, tvdbOffset, tmdb, tmdbSeason, tmdbOffset, rank].
        var shows: [[Int]]
        var movieTmdb: [String: Int]        // TMDB movie ID → MyAnimeList ID (0: anime, but no single entry)
        var movieImdb: [String: Int]        // IMDb ID → MyAnimeList ID, movies only
        var anilist: [String: Int]          // AniList ID → MyAnimeList ID
        var anidb: [String: Int]            // AniDB ID → MyAnimeList ID
    }

    private static func number(_ value: Any?) -> Int? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        guard d.isFinite, d == d.rounded(), abs(d) < 1e15 else { return nil }
        return Int(d)
    }
    private static func positive(_ value: Any?) -> Int { max(0, number(value) ?? 0) }
    private static func season(_ value: Any?, has: Bool) -> Int {
        if let n = number(value), n >= 0 { return n }
        return has ? 1 : -1
    }

    /// The index of the downloaded list (an array of entries; every field of an entry is optional).
    static func buildIndex(_ list: Any?, at: Double) -> Index? {
        guard let list = list as? [Any] else { return nil }
        var index = Index(at: at, shows: [], movieTmdb: [:], movieImdb: [:], anilist: [:], anidb: [:])
        func once(_ map: inout [String: Int], _ key: String, _ mal: Int) {
            if let old = map[key], old != mal { map[key] = 0 } else { map[key] = mal }
        }
        for raw in list {
            guard let e = raw as? [String: Any] else { continue }
            let mal = positive(e["mal_id"])
            let type = (e["type"] as? String ?? "").uppercased()
            let movie = type == "MOVIE"
            let tm = e["themoviedb_id"] as? [String: Any] ?? [:]
            let seasons = e["season"] as? [String: Any] ?? [:]
            let offsets = e["episode_offset"] as? [String: Any] ?? [:]
            let tvdb = positive(e["tvdb_id"]), tmdb = positive(tm["tv"])
            if tvdb > 0 || tmdb > 0 {
                index.shows.append([mal, tvdb, season(seasons["tvdb"], has: tvdb > 0), positive(offsets["tvdb"]),
                                    tmdb, season(seasons["tmdb"], has: tmdb > 0), positive(offsets["tmdb"]),
                                    movie ? 2 : (type == "TV" ? 0 : 1)])
            }
            for id in tm["movie"] as? [Any] ?? [] where positive(id) > 0 {
                once(&index.movieTmdb, String(positive(id)), mal)
            }
            if movie {
                for id in e["imdb_id"] as? [Any] ?? [] {
                    if let s = id as? String, s.hasPrefix("tt"), s.count > 2, s.dropFirst(2).allSatisfy({ $0.isASCII && $0.isNumber }) {
                        once(&index.movieImdb, s, mal)
                    }
                }
            }
            if mal > 0, positive(e["anilist_id"]) > 0 { index.anilist[String(positive(e["anilist_id"]))] = mal }
            if mal > 0, positive(e["anidb_id"]) > 0 { index.anidb[String(positive(e["anidb_id"]))] = mal }
        }
        return index.shows.count > 1000 ? index : nil   // a list this short is not the list
    }

    /// The index with its rows by series ID.
    struct Lookup: Sendable {
        let index: Index
        let byTvdb: [Int: [[Int]]]
        let byTmdb: [Int: [[Int]]]

        init(_ index: Index) {
            self.index = index
            var a: [Int: [[Int]]] = [:], b: [Int: [[Int]]] = [:]
            for row in index.shows where row.count == 8 {
                if row[1] > 0 { a[row[1], default: []].append(row) }
                if row[4] > 0 { b[row[4], default: []].append(row) }
            }
            byTvdb = a
            byTmdb = b
        }
    }

    /// Loads the index: from memory, else the saved one, downloaded again when it's a week old
    /// (a saved one stays in use when that fails).
    private actor Store {
        private var memory: Lookup?
        private var loadedSaved = false
        private var loading: Task<Void, Never>?
        private var lastTry = Date.distantPast

        func lookup() async -> Lookup? {
            if memory == nil, !loadedSaved {
                loadedSaved = true
                if let saved = DiskCache.load(Index.self, name: "skipdb-anime-index") { memory = Lookup(saved) }
            }
            if let memory, Date().timeIntervalSince1970 - memory.index.at < 7 * 86_400 { return memory }
            if loading == nil, Date().timeIntervalSince(lastTry) > 600 {
                lastTry = Date()
                loading = Task { await self.download() }
            }
            if let loading {
                await loading.value
                self.loading = nil
            }
            return memory
        }

        private func download() async {
            guard let url = URL(string: "https://raw.githubusercontent.com/Fribb/anime-lists/master/anime-list-full.json") else { return }
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            guard let (data, response) = try? await AniSkip.session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data),
                  let index = AniSkip.buildIndex(json, at: Date().timeIntervalSince1970) else { return }
            memory = Lookup(index)
            DiskCache.saveInBackground(index, name: "skipdb-anime-index")
        }
    }
    private static let store = Store()

    fileprivate static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.httpCookieStorage = nil
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    // MARK: From a server title to MyAnimeList ID + episode

    private static func fromRows(_ rows: [[Int]]?, _ at: Int, season: Int, episode: Int) -> Target? {
        var best: [Int]?
        for row in rows ?? [] {
            let offset = row[at + 2]
            if row[at + 1] != season || row[7] == 2 || offset >= episode { continue }
            if let b = best, !(offset > b[at + 2] || (offset == b[at + 2] && row[7] < b[7])) { continue }
            best = row
        }
        guard let row = best, row[0] > 0 else { return nil }
        return Target(mal: row[0], episode: episode - row[at + 2])
    }

    /// Whether the title is anime, and where AniSkip would have it (most likely first).
    static func targets(_ q: Query, _ lookup: Lookup?) -> (anime: Bool, targets: [Target]) {
        let index = lookup?.index
        var targets: [Target] = []
        func add(_ t: Target?) {
            if let t, t.mal > 0, t.episode > 0, !targets.contains(t) { targets.append(t) }
        }
        var direct = q.mal ?? 0
        if direct == 0, let id = q.anilist { direct = index?.anilist[String(id)] ?? 0 }
        if direct == 0, let id = q.anidb { direct = index?.anidb[String(id)] ?? 0 }
        var known = q.hint || q.mal != nil || q.anilist != nil || q.anidb != nil
        if q.movie {
            if direct > 0 { add(Target(mal: direct, episode: 1)) }
            let byTmdb = q.tmdb.flatMap { index?.movieTmdb[String($0)] }
            let byImdb = q.imdb.flatMap { index?.movieImdb[$0] }
            if byTmdb != nil || byImdb != nil { known = true }
            if let byTmdb, byTmdb > 0 { add(Target(mal: byTmdb, episode: 1)) }
            if let byImdb, byImdb > 0 { add(Target(mal: byImdb, episode: 1)) }
            return (known, targets)
        }
        let tvdbRows = q.tvdb.flatMap { lookup?.byTvdb[$0] }
        let tmdbRows = q.tmdb.flatMap { lookup?.byTmdb[$0] }
        if !(tvdbRows ?? []).isEmpty || !(tmdbRows ?? []).isEmpty { known = true }
        let season = q.season ?? -1, episode = q.episode ?? 0
        guard episode >= 1 else { return (known, targets) }
        // An anime plugin's ID names one entry: the series as the server has it, when it isn't a later season.
        if direct > 0, season <= 1 { add(Target(mal: direct, episode: episode)) }
        if season >= 1 {
            let byTvdb = fromRows(tvdbRows, 1, season: season, episode: episode)
            let byTmdb = fromRows(tmdbRows, 4, season: season, episode: episode)
            // The server's numbers are TVDB's or TMDB's; the more likely one first, the other after it.
            for t in (q.tvdbNumbering ? [byTvdb, byTmdb] : [byTmdb, byTvdb]) { add(t) }
        }
        return (known, targets)
    }

    // MARK: AniSkip

    static func url(_ t: Target, durationMs: Double) -> URL? {
        // The file's length picks the times made for a file of that length (0: unknown, the top-voted ones).
        let length = durationMs > 0 ? String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), durationMs / 1000) : "0"
        return URL(string: "https://api.aniskip.com/v2/skip-times/\(t.mal)/\(t.episode)?types=op&types=ed&types=mixed-op&types=mixed-ed&types=recap&episodeLength=\(length)")
    }

    /// AniSkip's answer: { found, results: [{ interval: { startTime, endTime }, skipType }] }, in seconds.
    static func parse(_ body: Any?, make: (_ type: String, _ startMs: Double, _ endMs: Double) -> MediaSegment?) -> [MediaSegment] {
        guard let results = (body as? [String: Any])?["results"] as? [Any] else { return [] }
        let types = ["op": "Intro", "ed": "Outro", "recap": "Recap", "mixed-op": "Intro", "mixed-ed": "Outro"]
        var plain: [MediaSegment] = [], mixed: [MediaSegment] = []
        for entry in results.prefix(12) {
            guard let o = entry as? [String: Any], let kind = o["skipType"] as? String, let type = types[kind],
                  let interval = o["interval"] as? [String: Any],
                  let start = (interval["startTime"] as? NSNumber)?.doubleValue,
                  let end = (interval["endTime"] as? NSNumber)?.doubleValue,
                  start.isFinite, end.isFinite, start >= 0, end > start,
                  let seg = make(type, start * 1000, end * 1000) else { continue }
            if kind.hasPrefix("mixed") { mixed.append(seg) } else { plain.append(seg) }
        }
        // An opening or ending mixed with the story only stands in when there's no plain one.
        let have = Set(plain.map(\.type))
        return plain + mixed.filter { !have.contains($0.type) }
    }

    /// Whether the title is anime (with the list when it can be had), and its AniSkip segments.
    /// `complete` is false when AniSkip couldn't be reached (ask again next time).
    static func segments(_ q: Query, durationMs: Double,
                         make: (_ type: String, _ startMs: Double, _ endMs: Double) -> MediaSegment?) async -> (anime: Bool, segments: [MediaSegment], complete: Bool) {
        let resolved = Self.targets(q, await store.lookup())
        guard resolved.anime else { return (false, [], true) }
        var complete = true
        for t in resolved.targets.prefix(3) {
            guard let address = Self.url(t, durationMs: durationMs) else { continue }
            var request = URLRequest(url: address)
            request.timeoutInterval = 8
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("JellyReco (iOS)", forHTTPHeaderField: "User-Agent")
            guard let (data, response) = try? await session.data(for: request),
                  let http = response as? HTTPURLResponse else { complete = false; continue }
            if http.statusCode == 404 || http.statusCode == 400 { continue }   // no times for this entry / episode
            guard http.statusCode == 200, let json = try? JSONSerialization.jsonObject(with: data) else { complete = false; continue }
            let found = parse(json, make: make)
            if !found.isEmpty { return (true, found, true) }
        }
        return (true, [], complete)
    }
}
