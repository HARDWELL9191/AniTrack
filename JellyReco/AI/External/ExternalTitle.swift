import Foundation

/// A title from TMDB recommended because of what you watched on your server.
/// Never something your server already has (checked by TMDB/IMDb/TVDB id and by title).
struct ExternalTitle: Codable, Hashable, Identifiable {
    enum Source: String, Codable { case tmdbMovie, tmdbTV }

    var id: String { "\(source.rawValue):\(sourceId)" }
    let source: Source
    let sourceId: Int
    var title: String
    var originalTitle: String?
    var originalLanguage: String?
    var year: Int?
    var overview: String
    var genres: [String]
    var tags: [String] = []
    var posterURL: URL?
    var backdropURL: URL?
    /// TMDB user score, 0–10.
    var score: Double?
    var voteCount: Int?
    var popularity: Double?
    var episodes: Int?
    var seasons: Int?
    var runtime: Int?
    var imdbId: String?
    var tvdbId: Int?
    var status: String?
    var isAdult = false
    /// TMDB certification ("PG-13", "TV-MA", "12"…) and the country it's from ("US").
    var ageRating: String?
    var ageRatingCountry: String?

    var isMovie: Bool { source == .tmdbMovie }
    var isAnime: Bool { originalLanguage == "ja" && genres.contains("Animation") }

    var webURL: URL? {
        URL(string: "https://www.themoviedb.org/\(isMovie ? "movie" : "tv")/\(sourceId)")
    }

    /// The age bubble, as in AniReco: PG, 13+, 17+ or 18+.
    var ageLabel: String? { ageRating.flatMap(TMDBCertification.bucket) }

    /// For the details page: "13+ · PG-13 (United States)".
    var ageExplanation: String? {
        guard let label = ageLabel, let raw = ageRating else { return nil }
        let country = ageRatingCountry.flatMap { Locale.current.localizedString(forRegionCode: $0) }
        return "\(label) · \(raw)\(country.map { " (\($0))" } ?? "")"
    }

    var imdbURL: URL? { imdbId.flatMap { URL(string: "https://www.imdb.com/title/\($0)/") } }

    var metaLine: String {
        var parts: [String] = [isAnime ? (isMovie ? "Anime movie" : "Anime") : (isMovie ? "Movie" : "TV show")]
        if let y = year { parts.append("\(y)") }
        if let s = seasons, !isMovie { parts.append(s == 1 ? "1 season" : "\(s) seasons") }
        if let r = runtime, isMovie, r > 0 { parts.append(Fmt.runtime(Double(r * 60))) }
        return parts.joined(separator: " · ")
    }

    /// Text the on-device model embeds (same recipe as library items, so they compare).
    var embeddingInput: SemanticEngine.Input {
        let text = "\(title). \(genres.joined(separator: ", ")). \(tags.prefix(6).joined(separator: ", ")). \(String(overview.prefix(500)))"
        return SemanticEngine.Input(key: "\(id)|\(SemanticEngine.stableKey(text))", text: text)
    }
}

/// Titles normalized for matching ("Mushoku Tensei: Jobless Reincarnation Season 2" → "mushokutenseijoblessreincarnation").
enum TitleKey {
    private static let tail = try! NSRegularExpression(
        pattern: "\\b(\\d+(st|nd|rd|th)\\s+season|season\\s*\\d*|part\\s*\\d+|cour\\s*\\d+|final season|the movie)\\b.*$",
        options: [.caseInsensitive])

    private static let alphanumerics = CharacterSet.alphanumerics

    static func make(_ s: String) -> String {
        var t = s.lowercased().folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
        t = tail.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "")
        // Built in place (a String per character used to be made and joined: this runs for every
        // title on the server when checking what you already have).
        var key = String.UnicodeScalarView()
        for scalar in t.unicodeScalars where alphanumerics.contains(scalar) { key.append(scalar) }
        return String(key)
    }
}

// Lenient reading (My List / Not for me are shared with other devices and the PC app): only the
// title's identity is required; any other field that's missing takes its default instead of
// making the whole saved list unreadable. In an extension, so the memberwise initializer stays.
extension ExternalTitle {
    private enum Keys: String, CodingKey {
        case source, sourceId, title, originalTitle, originalLanguage, year, overview, genres, tags, posterURL, backdropURL
        case score, voteCount, popularity, episodes, seasons, runtime, imdbId, tvdbId, status, isAdult, ageRating, ageRatingCountry
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        func opt<T: Decodable>(_ type: T.Type, _ key: Keys) -> T? { (try? c.decodeIfPresent(type, forKey: key)) ?? nil }
        self.init(source: try c.decode(Source.self, forKey: .source),
                  sourceId: try c.decode(Int.self, forKey: .sourceId),
                  title: opt(String.self, .title) ?? "",
                  originalTitle: opt(String.self, .originalTitle),
                  originalLanguage: opt(String.self, .originalLanguage),
                  year: opt(Int.self, .year),
                  overview: opt(String.self, .overview) ?? "",
                  genres: opt([String].self, .genres) ?? [],
                  tags: opt([String].self, .tags) ?? [],
                  posterURL: opt(URL.self, .posterURL),
                  backdropURL: opt(URL.self, .backdropURL),
                  score: opt(Double.self, .score),
                  voteCount: opt(Int.self, .voteCount),
                  popularity: opt(Double.self, .popularity),
                  episodes: opt(Int.self, .episodes),
                  seasons: opt(Int.self, .seasons),
                  runtime: opt(Int.self, .runtime),
                  imdbId: opt(String.self, .imdbId),
                  tvdbId: opt(Int.self, .tvdbId),
                  status: opt(String.self, .status),
                  isAdult: opt(Bool.self, .isAdult) ?? false,
                  ageRating: opt(String.self, .ageRating),
                  ageRatingCountry: opt(String.self, .ageRatingCountry))
    }
}
