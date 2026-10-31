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

    static func make(_ s: String) -> String {
        var t = s.lowercased().folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
        t = tail.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "")
        return t.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }
}
