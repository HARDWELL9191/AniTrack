import Foundation

/// Which libraries For You runs on AniList (as in AniReco) instead of the Jellyfin server:
/// the ones named exactly "Anime" (shows) or "Anime Movies" (movies), in any letter case.
enum AniListLibrary: String {
    case shows, movies

    init?(libraryName: String?) {
        let name = (libraryName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        switch name {
        case "anime": self = .shows
        case "anime movies": self = .movies
        default: return nil
        }
    }

    var noun: String { self == .movies ? "anime movie" : "anime" }
}

extension Media {
    /// What the on-device model embeds (AniReco's recipe), keyed by AniList id + a content hash.
    var embeddingInput: SemanticEngine.Input {
        let name = title.english ?? title.romaji ?? title.userPreferred ?? ""
        let genres = (self.genres ?? []).joined(separator: ", ")
        let tags = visibleTags.prefix(6).map(\.name).joined(separator: ", ")
        let text = "\(name). \(genres). \(tags). \(String(plainDescription.prefix(500)))"
        return SemanticEngine.Input(key: "anilist:\(id)|\(SemanticEngine.stableKey(text))", text: text)
    }

    /// Every name this show goes by (for matching it with your server).
    var allTitles: [String] {
        [title.english, title.romaji, title.native, title.userPreferred].compactMap { $0 }.filter { !$0.isEmpty }
    }
}

extension TitleLanguage {
    /// AniList's own account option ("ENGLISH", "ROMAJI_STYLISED", "NATIVE"…).
    init(anilistOption: String?) {
        let o = (anilistOption ?? "").uppercased()
        if o.hasPrefix("ENGLISH") { self = .english } else if o.hasPrefix("NATIVE") { self = .native } else { self = .romaji }
    }
}

extension ExternalTitle {
    /// An AniList show shaped like a For You title, so every card, sheet and list shows it.
    init(anilist m: Media, language: TitleLanguage) {
        let shown = m.displayTitle(language)
        let other = [m.title.romaji, m.title.english, m.title.native].compactMap { $0 }.first { $0 != shown }
        let lang: String? = switch m.countryOfOrigin {
        case "JP": "ja"
        case "CN": "zh"
        case "KR": "ko"
        case "TW": "zh"
        default: nil
        }
        self.init(source: .anilist,
                  sourceId: m.id,
                  title: shown,
                  originalTitle: other,
                  originalLanguage: lang,
                  year: m.seasonYear,
                  overview: m.plainDescription,
                  genres: m.genres ?? [],
                  tags: m.visibleTags.filter { ($0.rank ?? 0) >= 40 }.prefix(12).map(\.name),
                  posterURL: m.coverURL.flatMap(URL.init(string:)),
                  backdropURL: m.bannerImage.flatMap(URL.init(string:)),
                  score: (m.averageScore ?? m.meanScore).map { Double($0) / 10 },
                  voteCount: nil,
                  popularity: m.popularity.map(Double.init),
                  episodes: m.episodes,
                  seasons: nil,
                  runtime: m.isMovie ? m.duration : nil,
                  imdbId: nil,
                  tvdbId: nil,
                  status: m.statusLabel,
                  isAdult: m.isAdult == true,
                  ageRating: nil,
                  ageRatingCountry: nil,
                  format: m.format)
    }
}

/// Everything on your Jellyfin server, indexed every way an AniList show could match it:
/// the AniList / MyAnimeList ids Jellyfin stored (anime metadata plugins), then any of its
/// titles. Shows match by name (later seasons are the same show), movies within a year.
struct AniListOwnedIndex: Sendable {
    private var anilistIds: Set<Int> = []
    private var malIds: Set<Int> = []
    private var showTitles: Set<String> = []
    private var movieTitles: [String: [Int?]] = [:]   // normalized title → years

    init() {}

    init(items: [BaseItem]) {
        for item in items where item.kind == .series || item.kind == .movie {
            let ids = item.providerIds ?? [:]
            func provider(_ names: String...) -> Int? {
                for (key, value) in ids where names.contains(where: { key.caseInsensitiveCompare($0) == .orderedSame }) {
                    if let n = Int(value) { return n }
                }
                return nil
            }
            if let a = provider("AniList") { anilistIds.insert(a) }
            if let m = provider("MyAnimeList", "Mal") { malIds.insert(m) }
            for name in [item.name, item.originalTitle].compactMap({ $0 }) {
                let key = TitleKey.make(name)
                guard key.count >= 3 else { continue }
                if item.kind == .series { showTitles.insert(key) } else { movieTitles[key, default: []].append(item.productionYear) }
            }
        }
    }

    var isEmpty: Bool { anilistIds.isEmpty && malIds.isEmpty && showTitles.isEmpty && movieTitles.isEmpty }

    func contains(_ m: Media) -> Bool {
        if anilistIds.contains(m.id) { return true }
        if let mal = m.idMal, malIds.contains(mal) { return true }
        for name in m.allTitles {
            let key = TitleKey.make(name)
            guard key.count >= 3 else { continue }
            if m.isMovie {
                guard let years = movieTitles[key] else { continue }
                if m.seasonYear == nil || years.contains(where: { $0 == nil || abs(($0 ?? 0) - (m.seasonYear ?? 0)) <= 1 }) { return true }
            } else if showTitles.contains(key) {
                return true
            }
        }
        return false
    }

    func contains(_ t: ExternalTitle) -> Bool {
        guard t.isAniList else { return false }
        if anilistIds.contains(t.sourceId) { return true }
        for name in [t.title, t.originalTitle].compactMap({ $0 }) {
            let key = TitleKey.make(name)
            guard key.count >= 3 else { continue }
            if t.isMovie {
                guard let years = movieTitles[key] else { continue }
                if t.year == nil || years.contains(where: { $0 == nil || abs(($0 ?? 0) - (t.year ?? 0)) <= 1 }) { return true }
            } else if showTitles.contains(key) {
                return true
            }
        }
        return false
    }
}
