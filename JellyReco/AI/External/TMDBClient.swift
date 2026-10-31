import Foundation

enum TMDBError: LocalizedError {
    case noKey, badKey(String?), http(Int, String?), network(String)
    var errorDescription: String? {
        switch self {
        case .noKey: return "Add your free TMDB API key in Settings → Recommendations."
        case .badKey(let m): return "TMDB didn't accept the key\(m.map { ": \($0)" } ?? ""). Paste the API Read Access Token (the long one) or the API key."
        case .http(let c, let m): return "TMDB error \(c)\(m.map { ": \($0)" } ?? "")."
        case .network(let m): return "Couldn't reach TMDB: \(m)"
        }
    }
}

/// Read-only TMDB client (themoviedb.org API v3). Accepts either the v4 "API Read Access Token"
/// (sent as a Bearer header) or the short v3 "API key" (sent as `api_key`).
actor TMDBClient {
    private let key: String
    private let session: URLSession
    private var genreNames: [Int: String] = [:]
    private var detailCache: [String: ExternalTitle] = [:]

    static let imageBase = "https://image.tmdb.org/t/p/"

    init(key: String) {
        // Pasted keys often carry spaces, line breaks or quotes: keep only the key itself.
        self.key = key.components(separatedBy: .whitespacesAndNewlines).joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.httpMaximumConnectionsPerHost = 8
        session = URLSession(configuration: config)
    }

    private var isBearer: Bool { key.count > 40 }

    // Request statistics, so For You can say exactly what went wrong instead of showing nothing.
    private(set) var succeeded = 0
    private(set) var failed = 0
    private(set) var lastFailure: String?
    func resetStats() { succeeded = 0; failed = 0; lastFailure = nil }

    private func get(_ path: String, _ query: [String: String] = [:]) async throws -> Data {
        do {
            let data = try await rawGet(path, query)
            succeeded += 1
            return data
        } catch {
            if !(error is CancellationError) && (error as? URLError)?.code != .cancelled {
                failed += 1
                lastFailure = error.localizedDescription
            }
            throw error
        }
    }

    private func rawGet(_ path: String, _ query: [String: String]) async throws -> Data {
        guard !key.isEmpty else { throw TMDBError.noKey }
        var comps = URLComponents(string: "https://api.themoviedb.org/3" + path)!
        var items = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        items.append(URLQueryItem(name: "language", value: "en-US"))
        if !isBearer { items.append(URLQueryItem(name: "api_key", value: key)) }
        comps.queryItems = items
        var request = URLRequest(url: comps.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if isBearer { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        for attempt in 0..<4 {
            let (data, response): (Data, URLResponse)
            do {
                (data, response) = try await session.data(for: request)
            } catch let e as URLError where e.code != .cancelled {
                throw TMDBError.network(e.localizedDescription)
            }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 429 {   // rate limited: wait as told, then retry
                let wait = Double((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After") ?? "") ?? Double(attempt + 1)
                try await Task.sleep(nanoseconds: UInt64(min(wait, 10) * 1_000_000_000))
                continue
            }
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["status_message"] as? String
            if code == 401 { throw TMDBError.badKey(message) }
            guard (200..<300).contains(code) else { throw TMDBError.http(code, message) }
            return data
        }
        throw TMDBError.http(429, "Too many requests, try again in a minute")
    }

    /// Checks the key (used by Settings).
    func validate() async throws {
        #if DEBUG
        // UI tests only (never in the shipped app): a stand-in for a real key.
        if ProcessInfo.processInfo.environment["JELLYRECO_UITEST"] != nil, key.hasPrefix("uitestvalidkey") { return }
        #endif
        _ = try await get("/configuration")
    }

    // MARK: Genres

    func loadGenres() async throws {
        guard genreNames.isEmpty else { return }
        struct List: Decodable { let genres: [G] }
        struct G: Decodable { let id: Int; let name: String }
        for kind in ["movie", "tv"] {
            let list = try JSONDecoder().decode(List.self, from: try await get("/genre/\(kind)/list"))
            for g in list.genres { genreNames[g.id] = g.name }
        }
    }

    func genreId(named name: String, tv: Bool) -> Int? {
        // TV uses combined names ("Action & Adventure", "Sci-Fi & Fantasy").
        let lower = name.lowercased()
        if let exact = genreNames.first(where: { $0.value.lowercased() == lower }) { return exact.key }
        return genreNames.first(where: { $0.value.lowercased().contains(lower) || lower.contains($0.value.lowercased()) })?.key
    }

    // MARK: Results

    private struct Page: Decodable { let results: [Raw]; let totalPages: Int?
        enum CodingKeys: String, CodingKey { case results; case totalPages = "total_pages" }
    }

    private struct Raw: Decodable {
        let id: Int
        let title: String?
        let name: String?
        let originalTitle: String?
        let originalName: String?
        let originalLanguage: String?
        let overview: String?
        let posterPath: String?
        let backdropPath: String?
        let genreIds: [Int]?
        let releaseDate: String?
        let firstAirDate: String?
        let voteAverage: Double?
        let voteCount: Int?
        let popularity: Double?
        let adult: Bool?
        let mediaType: String?

        enum CodingKeys: String, CodingKey {
            case id, title, name, overview, popularity, adult
            case originalTitle = "original_title", originalName = "original_name", originalLanguage = "original_language"
            case posterPath = "poster_path", backdropPath = "backdrop_path", genreIds = "genre_ids"
            case releaseDate = "release_date", firstAirDate = "first_air_date"
            case voteAverage = "vote_average", voteCount = "vote_count", mediaType = "media_type"
        }
    }

    private func convert(_ r: Raw, tv: Bool) -> ExternalTitle {
        let date = (tv ? r.firstAirDate : r.releaseDate) ?? ""
        return ExternalTitle(
            source: tv ? .tmdbTV : .tmdbMovie,
            sourceId: r.id,
            title: (tv ? r.name : r.title) ?? r.name ?? r.title ?? "Untitled",
            originalTitle: tv ? r.originalName : r.originalTitle,
            originalLanguage: r.originalLanguage,
            year: Int(date.prefix(4)),
            overview: r.overview ?? "",
            genres: (r.genreIds ?? []).compactMap { genreNames[$0] },
            posterURL: r.posterPath.flatMap { URL(string: Self.imageBase + "w500" + $0) },
            backdropURL: r.backdropPath.flatMap { URL(string: Self.imageBase + "w1280" + $0) },
            score: r.voteAverage,
            voteCount: r.voteCount,
            popularity: r.popularity,
            isAdult: r.adult ?? false
        )
    }

    /// "People who liked this also liked" for one title.
    func recommendations(tmdbId: Int, tv: Bool, page: Int = 1) async throws -> [ExternalTitle] {
        try await loadGenres()
        let data = try await get("/\(tv ? "tv" : "movie")/\(tmdbId)/recommendations", ["page": "\(page)"])
        return try JSONDecoder().decode(Page.self, from: data).results.map { convert($0, tv: tv) }
    }

    /// Well-rated titles in genres, optionally anime only (Animation + Japanese original language).
    func discover(tv: Bool, genreIds: [Int], anime: Bool?, page: Int, sort: String = "vote_average.desc",
                  minVotes: Int = 200) async throws -> [ExternalTitle] {
        try await loadGenres()
        var q: [String: String] = ["page": "\(page)", "sort_by": sort, "include_adult": "false",
                                   "vote_count.gte": "\(minVotes)"]
        var genres = genreIds
        if anime == true {
            if !genres.contains(16) { genres.append(16) }
            q["with_original_language"] = "ja"
        } else if anime == false {
            q["without_genres"] = "16"   // movies/TV libraries: leave anime to the anime library
        }
        if !genres.isEmpty { q["with_genres"] = genres.map(String.init).joined(separator: ",") }
        let data = try await get("/discover/\(tv ? "tv" : "movie")", q)
        return try JSONDecoder().decode(Page.self, from: data).results.map { convert($0, tv: tv) }
    }

    /// Full details: keywords (tags), IMDb/TVDB ids, seasons, runtime.
    func details(_ title: ExternalTitle) async -> ExternalTitle {
        if let hit = detailCache[title.id] { return hit }
        let tv = !title.isMovie
        guard let data = try? await get("/\(tv ? "tv" : "movie")/\(title.sourceId)", ["append_to_response": "keywords,external_ids"]),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return title }
        var t = title
        let kw = (json["keywords"] as? [String: Any])
        let list = (kw?["keywords"] ?? kw?["results"]) as? [[String: Any]] ?? []
        t.tags = list.compactMap { $0["name"] as? String }
        let ext = json["external_ids"] as? [String: Any]
        t.imdbId = (ext?["imdb_id"] as? String) ?? (json["imdb_id"] as? String)
        t.tvdbId = ext?["tvdb_id"] as? Int
        t.seasons = json["number_of_seasons"] as? Int
        t.episodes = json["number_of_episodes"] as? Int
        t.runtime = json["runtime"] as? Int
        t.status = json["status"] as? String
        if let g = json["genres"] as? [[String: Any]] { t.genres = g.compactMap { $0["name"] as? String } }
        if detailCache.count > 3000 { detailCache.removeAll() }
        detailCache[title.id] = t
        return t
    }

    // MARK: Finding your library titles on TMDB

    /// TMDB id for an IMDb or TVDB id.
    func find(externalId: String, source: String, tv: Bool) async -> Int? {
        guard let data = try? await get("/find/\(externalId)", ["external_source": source]),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let list = json[tv ? "tv_results" : "movie_results"] as? [[String: Any]]
        return list?.first?["id"] as? Int
    }

    /// Best TMDB match for a title and year.
    func search(title: String, year: Int?, tv: Bool) async -> Int? {
        var q = ["query": title, "include_adult": "false"]
        if let year { q[tv ? "first_air_date_year" : "year"] = "\(year)" }
        guard let data = try? await get("/search/\(tv ? "tv" : "movie")", q),
              let page = try? JSONDecoder().decode(Page.self, from: data) else { return nil }
        let key = TitleKey.make(title)
        let best = page.results.first { TitleKey.make(($0.title ?? $0.name) ?? "") == key } ?? page.results.first
        return best?.id
    }
}
