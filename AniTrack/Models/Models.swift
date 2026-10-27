import Foundation

// MARK: - Core media

struct MediaTitle: Codable, Hashable {
    var romaji: String?
    var english: String?
    var native: String?
    var userPreferred: String?
}

struct CoverImage: Codable, Hashable {
    var large: String?
    var extraLarge: String?
    var color: String?
}

struct AiringEpisode: Codable, Hashable {
    var episode: Int
    var airingAt: Int
    var timeUntilAiring: Int
}

struct MediaTag: Codable, Hashable {
    var name: String
    var rank: Int?
    var isMediaSpoiler: Bool?
    var category: String?
}

struct Media: Codable, Identifiable, Hashable {
    var id: Int
    var title: MediaTitle
    var coverImage: CoverImage?
    var bannerImage: String?
    var format: String?
    var status: String?
    var episodes: Int?
    var duration: Int?
    var season: String?
    var seasonYear: Int?
    var averageScore: Int?
    var meanScore: Int?
    var popularity: Int?
    var genres: [String]?
    var countryOfOrigin: String?
    var isAdult: Bool?
    var siteUrl: String?
    var nextAiringEpisode: AiringEpisode?
    var description: String?
    var tags: [MediaTag]?
    /// Only filled by suggestion queries (which season comes before/after this one).
    var relations: MediaRelations?

    func displayTitle(_ language: TitleLanguage) -> String {
        let t = title
        switch language {
        case .english:
            return t.english ?? t.romaji ?? t.userPreferred ?? t.native ?? "Untitled"
        case .romaji:
            return t.romaji ?? t.english ?? t.userPreferred ?? t.native ?? "Untitled"
        case .native:
            return t.native ?? t.romaji ?? t.english ?? t.userPreferred ?? "Untitled"
        }
    }

    var coverURL: String? { coverImage?.extraLarge ?? coverImage?.large }
    /// Smaller image for list-row thumbnails (≈230 px wide instead of ≈460 px): less data to download and decode.
    var thumbURL: String? { coverImage?.large ?? coverImage?.extraLarge }

    /// Episodes a viewer can currently watch.
    var availableEpisodes: Int? {
        if let next = nextAiringEpisode { return max(0, next.episode - 1) }
        if status == "FINISHED" { return episodes }
        return nil
    }

    var plainDescription: String {
        guard var text = description, !text.isEmpty else { return "No synopsis available." }
        text = text.replacingOccurrences(of: "<br>", with: "\n")
            .replacingOccurrences(of: "<br/>", with: "\n")
            .replacingOccurrences(of: "<br />", with: "\n")
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = ["&quot;": "\"", "&amp;": "&", "&#039;": "'", "&apos;": "'",
                        "&lt;": "<", "&gt;": ">", "&mdash;": "—", "&ndash;": "–", "&hellip;": "…"]
        for (k, v) in entities { text = text.replacingOccurrences(of: k, with: v) }
        while text.contains("\n\n\n") { text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var formatLabel: String {
        switch format {
        case "TV": return "TV"
        case "TV_SHORT": return "TV Short"
        case "MOVIE": return "Movie"
        case "SPECIAL": return "Special"
        case "OVA": return "OVA"
        case "ONA": return "ONA"
        case "MUSIC": return "Music"
        default: return format?.capitalized ?? "—"
        }
    }

    var statusLabel: String {
        switch status {
        case "RELEASING": return "Airing"
        case "FINISHED": return "Finished"
        case "NOT_YET_RELEASED": return "Upcoming"
        case "CANCELLED": return "Cancelled"
        case "HIATUS": return "Hiatus"
        default: return status?.capitalized ?? "—"
        }
    }

    var seasonLabel: String? {
        guard let season, let seasonYear else { return seasonYear.map(String.init) }
        return "\(season.capitalized) \(seasonYear)"
    }

    var visibleTags: [MediaTag] {
        (tags ?? []).filter { $0.isMediaSpoiler != true }
    }
}

/// Minimal relation data: enough to tell numbered seasons of one show apart.
struct MediaRelations: Codable, Hashable {
    struct Node: Codable, Hashable {
        let id: Int
        let type: String?
        let format: String?
        let title: MediaTitle?
    }
    struct Edge: Codable, Hashable { let relationType: String?; let node: Node? }
    var edges: [Edge]?
}

/// Seasons vs. everything else. Only *numbered TV seasons of the same show* are collapsed;
/// movies, OVAs, specials and sequels with their own name stay separate recommendations.
enum Seasons {
    static let seriesFormats: Set<String> = ["TV", "TV_SHORT", "ONA"]

    static func normalized(_ s: String?) -> String {
        (s ?? "").lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    /// Same base title: e.g. "Tensei shitara Slime Datta Ken 2nd Season" vs "Tensei shitara Slime Datta Ken".
    static func sameShow(_ a: MediaTitle?, _ b: MediaTitle?) -> Bool {
        for (x, y) in [(a?.romaji, b?.romaji), (a?.english, b?.english)] {
            let p = normalized(x), q = normalized(y)
            guard !p.isEmpty, !q.isEmpty else { continue }
            let common = zip(p, q).prefix { $0 == $1 }.count
            let shorter = min(p.count, q.count)
            // Short titles ("Bleach") just need to be a full prefix; longer ones share >= 60%.
            if common >= min(shorter, max(8, shorter * 6 / 10)) { return true }
        }
        return false
    }

    static func isSeries(_ format: String?) -> Bool { format.map(seriesFormats.contains) ?? false }

    static func words(_ s: String?) -> [String] {
        (s ?? "").lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}

/// Shows (TV/ONA series) already on your list, indexed by the first word of their titles, so
/// "Slime" Season 1 is recognised as known when Season 2 is on your list. Purely local and fast.
/// A title only matches when one is a whole-word prefix of the other and at least two words
/// long ("Shingeki no Kyojin" ↔ "Shingeki no Kyojin Season 3", but not "Monster" ↔ "Monster Musume").
struct ListFranchises {
    private var byFirstWord: [String: [[String]]] = [:]

    init(_ media: [Media] = []) {
        for m in media where Seasons.isSeries(m.format) {
            for title in [m.title.romaji, m.title.english] {
                let w = Seasons.words(title)
                guard w.count >= 2 else { continue }
                byFirstWord[w[0], default: []].append(w)
            }
        }
    }

    func contains(_ media: Media) -> Bool {
        guard Seasons.isSeries(media.format) else { return false }   // movies/OVAs are fine to suggest
        for title in [media.title.romaji, media.title.english] {
            let w = Seasons.words(title)
            guard w.count >= 2, let group = byFirstWord[w[0]] else { continue }
            for other in group {
                let n = min(w.count, other.count)
                if n >= 2 && w.prefix(n) == other.prefix(n) { return true }
            }
        }
        return false
    }
}

extension Media {
    /// The entry right before this one in the same show (any format: AniList sometimes puts an
    /// OVA between seasons, e.g. Slime S1 → Coleus OVA → S2). Series formats are preferred.
    var prequelId: Int? {
        let edges = (relations?.edges ?? []).filter { edge in
            guard edge.relationType == "PREQUEL", let node = edge.node else { return false }
            return (node.type == nil || node.type == "ANIME") && Seasons.sameShow(title, node.title)
        }
        return (edges.first { Seasons.isSeries($0.node?.format) } ?? edges.first)?.node?.id
    }

    /// Set when this is Season 2+ of a TV/ONA show (movies, OVAs and renamed sequels: nil).
    var previousSeasonId: Int? { Seasons.isSeries(format) ? prequelId : nil }

    /// Later TV seasons of this same show.
    var nextSeasonIds: [Int] {
        guard Seasons.isSeries(format) else { return [] }
        return (relations?.edges ?? []).compactMap { edge in
            guard edge.relationType == "SEQUEL", let node = edge.node, node.type == nil || node.type == "ANIME",
                  Seasons.isSeries(node.format), Seasons.sameShow(title, node.title) else { return nil }
            return node.id
        }
    }

    /// Season 2+ of a show (as opposed to a first season, movie, OVA or renamed sequel).
    var isLaterSeason: Bool { previousSeasonId != nil }
}

enum TitleLanguage: String, CaseIterable, Identifiable {
    case english, romaji, native
    var id: String { rawValue }
    var label: String {
        switch self {
        case .english: return "English"
        case .romaji: return "Romaji"
        case .native: return "Native (日本語)"
        }
    }
}

// MARK: - List entries

enum ListStatus: String, Codable, CaseIterable, Identifiable {
    case CURRENT, PLANNING, COMPLETED, PAUSED, DROPPED, REPEATING

    var id: String { rawValue }

    var label: String {
        switch self {
        case .CURRENT: return "Watching"
        case .PLANNING: return "Planning"
        case .COMPLETED: return "Completed"
        case .PAUSED: return "Paused"
        case .DROPPED: return "Dropped"
        case .REPEATING: return "Rewatching"
        }
    }

    var symbol: String {
        switch self {
        case .CURRENT: return "play.circle.fill"
        case .PLANNING: return "bookmark.fill"
        case .COMPLETED: return "checkmark.circle.fill"
        case .PAUSED: return "pause.circle.fill"
        case .DROPPED: return "xmark.circle.fill"
        case .REPEATING: return "arrow.clockwise.circle.fill"
        }
    }
}

struct ListEntry: Codable, Identifiable, Hashable {
    var id: Int
    var mediaId: Int
    var status: ListStatus
    var score: Double?
    var progress: Int?
    var updatedAt: Int?
    var media: Media

    var scoreValue: Double { score ?? 0 }
    var progressValue: Int { progress ?? 0 }
}

/// List entry without the nested media (returned by mutations and Media.mediaListEntry).
struct EntryLite: Codable, Hashable {
    var id: Int
    var mediaId: Int
    var status: ListStatus?
    var score: Double?
    var progress: Int?
    var updatedAt: Int?
}

// MARK: - User

struct Avatar: Codable, Hashable { var large: String? }

struct UserOptions: Codable, Hashable {
    var titleLanguage: String?
    var displayAdultContent: Bool?
}

struct AnimeStats: Codable, Hashable {
    var count: Int?
    var episodesWatched: Int?
    var meanScore: Double?
    var minutesWatched: Int?
}

struct UserStats: Codable, Hashable { var anime: AnimeStats? }

struct Viewer: Codable, Hashable {
    var id: Int
    var name: String
    var avatar: Avatar?
    var bannerImage: String?
    var options: UserOptions?
    var statistics: UserStats?
}

// MARK: - Detail extras

struct StudioNode: Codable, Hashable { var name: String }
struct StudioConnection: Codable, Hashable { var nodes: [StudioNode]? }

struct RelatedMedia: Codable, Hashable, Identifiable {
    var id: Int
    var type: String?
    var format: String?
    var title: MediaTitle
    var coverImage: CoverImage?
}

struct RelationEdge: Codable, Hashable {
    var relationType: String?
    var node: RelatedMedia?

    var relationLabel: String {
        (relationType ?? "Related").replacingOccurrences(of: "_", with: " ").capitalized
    }
}

struct RelationConnection: Codable, Hashable { var edges: [RelationEdge]? }

struct RecNode: Codable, Hashable {
    var rating: Int?
    var mediaRecommendation: Media?
}

struct RecConnection: Codable, Hashable { var nodes: [RecNode]? }

struct MediaDetail: Decodable {
    let media: Media
    let studios: StudioConnection?
    let relations: RelationConnection?
    let recommendations: RecConnection?
    let mediaListEntry: EntryLite?

    private enum Keys: String, CodingKey {
        case studios, relations, recommendations, mediaListEntry
    }

    init(from decoder: Decoder) throws {
        media = try Media(from: decoder)
        let c = try decoder.container(keyedBy: Keys.self)
        studios = try c.decodeIfPresent(StudioConnection.self, forKey: .studios)
        relations = try c.decodeIfPresent(RelationConnection.self, forKey: .relations)
        recommendations = try c.decodeIfPresent(RecConnection.self, forKey: .recommendations)
        mediaListEntry = try c.decodeIfPresent(EntryLite.self, forKey: .mediaListEntry)
    }
}

// MARK: - GraphQL response wrappers

struct ViewerData: Decodable {
    let viewer: Viewer
    enum CodingKeys: String, CodingKey { case viewer = "Viewer" }
}

struct UserData: Decodable {
    let user: Viewer
    enum CodingKeys: String, CodingKey { case user = "User" }
}

struct MediaListGroup: Decodable {
    let name: String?
    let status: ListStatus?
    let isCustomList: Bool?
    let entries: [ListEntry]?
}

struct MediaListCollection: Decodable { let lists: [MediaListGroup]? }

struct CollectionData: Decodable {
    let collection: MediaListCollection?
    enum CodingKeys: String, CodingKey { case collection = "MediaListCollection" }
}

struct PageInfo: Decodable { let hasNextPage: Bool? }

struct MediaPage: Decodable {
    let pageInfo: PageInfo?
    let media: [Media]
}

struct PageData: Decodable {
    let page: MediaPage
    enum CodingKeys: String, CodingKey { case page = "Page" }
}

struct SeedMedia: Decodable {
    let id: Int
    let recommendations: RecConnection?
}

struct SeedPage: Decodable { let media: [SeedMedia] }

struct SeedPageData: Decodable {
    let page: SeedPage
    enum CodingKeys: String, CodingKey { case page = "Page" }
}

struct MediaDetailData: Decodable {
    let media: MediaDetail
    enum CodingKeys: String, CodingKey { case media = "Media" }
}

struct SaveEntryData: Decodable {
    let entry: EntryLite
    enum CodingKeys: String, CodingKey { case entry = "SaveMediaListEntry" }
}

struct DeletedResult: Decodable { let deleted: Bool? }

struct DeleteEntryData: Decodable {
    let result: DeletedResult?
    enum CodingKeys: String, CodingKey { case result = "DeleteMediaListEntry" }
}

// MARK: - Categories (AniList genres and tags)

struct AnimeCategory: Codable, Hashable, Identifiable {
    enum Kind: String, Codable { case genre, tag }
    let name: String
    let kind: Kind
    var id: String { "\(kind.rawValue):\(name)" }

    static func genre(_ name: String) -> AnimeCategory { AnimeCategory(name: name, kind: .genre) }
    static func tag(_ name: String) -> AnimeCategory { AnimeCategory(name: name, kind: .tag) }

    /// Quick picks shown as chips; anything AniList doesn't know is filtered out at runtime.
    static let featured: [AnimeCategory] = [
        .tag("Isekai"), .genre("Romance"), .genre("Ecchi"), .genre("Action"), .genre("Fantasy"),
        .tag("Reincarnation"), .tag("Harem"), .genre("Comedy"), .tag("Magic"), .tag("Super Power"),
        .genre("Adventure"), .genre("Slice of Life"), .tag("School"), .genre("Drama"), .tag("Demons"),
        .genre("Mystery"), .genre("Psychological"), .genre("Sci-Fi"), .tag("Revenge"), .genre("Supernatural"),
        .genre("Horror"), .genre("Sports"), .genre("Mecha"), .genre("Thriller")
    ]

    /// Whether a show belongs to this category (tags need a decent relevance rank).
    func matches(_ media: Media) -> Bool {
        switch kind {
        case .genre: return media.genres?.contains(name) == true
        case .tag: return media.tags?.contains { $0.name == name && ($0.rank ?? 0) >= 45 } == true
        }
    }

    /// GraphQL variables that filter a browse query to this category.
    var browseVariables: [String: Any] {
        kind == .genre ? ["genres": [name]] : ["tags": [name]]
    }
}

struct TagInfo: Decodable {
    let name: String
    let category: String?
    let isAdult: Bool?
    let isGeneralSpoiler: Bool?
}

struct CategoryCollectionData: Decodable {
    let genres: [String]?
    let tags: [TagInfo]?
    enum CodingKeys: String, CodingKey {
        case genres = "GenreCollection"
        case tags = "MediaTagCollection"
    }
}

/// Used for navigation to a detail page.
struct MediaLink: Hashable {
    let id: Int
}
