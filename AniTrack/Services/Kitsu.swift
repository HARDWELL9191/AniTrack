import Foundation

// MARK: - Age rating

/// Kitsu's age rating, shown as PG / 13+ / 17+ / 18+.
/// Kitsu folds MyAnimeList's PG-13 into "PG" and says "Teens 13 or older" in the guide text,
/// so that's what tells 13+ apart. When unsure, the lower age is shown (PG), never a guess.
struct AgeRating: Codable, Hashable {
    var code: String?    // G, PG, R, R18
    var guide: String?   // "Teens 13 or older", "Mild Nudity", "17+ (violence & profanity)"…

    var label: String? {
        switch code?.uppercased() {
        case "R18": return "18+"
        case "R": return "17+"
        case "PG":
            if let g = guide?.lowercased(), g.contains("13") { return "13+" }
            return "PG"
        case "G": return "PG"
        default: return nil
        }
    }

    /// For the details page: "13+ · Teens 13 or older".
    var explanation: String? {
        guard let label else { return nil }
        if let g = guide?.trimmingCharacters(in: .whitespacesAndNewlines), !g.isEmpty {
            return "\(label) · \(g)"
        }
        switch code?.uppercased() {
        case "G": return "PG · All ages"
        case "PG": return "PG · Parental guidance"
        case "R": return "17+ · Restricted"
        case "R18": return "18+ · Adults only"
        default: return label
        }
    }
}

// MARK: - Episodes

struct EpisodeInfo: Identifiable, Codable, Hashable {
    var number: Int
    var title: String?
    var description: String?
    var thumbnail: String?
    var id: Int { number }
}

// MARK: - Kitsu client

/// Kitsu's free public API (no account or key). Used for two things only: age ratings and
/// episode descriptions/thumbnails. Shows are matched by their AniList id, so there's no
/// title guessing. Ratings are saved on the phone for good; a show without one is
/// re-checked after a day.
actor KitsuClient {
    static let shared = KitsuClient()

    private static let base = "https://kitsu.app/api/edge"
    private static let cacheName = "kitsu-ratings-v1"
    /// Shows without a rating yet are checked again after this long.
    private static let recheckAfter: TimeInterval = 86_400

    struct Mapping: Codable {
        var kitsuId: String?
        var rating: AgeRating?
        var checkedAt: Date
    }

    private var mappings: [Int: Mapping] = [:]
    private var loaded = false
    private var saveTask: Task<Void, Never>?

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    private func loadIfNeeded() async {
        guard !loaded else { return }
        loaded = true
        if let saved = await DiskCache.loadInBackground([Int: Mapping].self, name: Self.cacheName) {
            mappings.merge(saved) { current, _ in current }
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)   // one write per burst of lookups
            guard !Task.isCancelled else { return }
            DiskCache.saveInBackground(self.mappings, name: Self.cacheName)
        }
    }

    /// Ratings already saved on the phone (no network).
    func savedRatings(for ids: [Int]) async -> [Int: AgeRating] {
        await loadIfNeeded()
        var result: [Int: AgeRating] = [:]
        for id in ids { if let r = mappings[id]?.rating { result[id] = r } }
        return result
    }

    /// A show to look up: its AniList id, plus its MyAnimeList id as a backup (Kitsu links
    /// some shows, e.g. brand-new ones, only by their MyAnimeList id).
    struct Lookup: Hashable {
        let id: Int
        let mal: Int?
    }

    /// Looks up ratings, 10 shows per request. `failed` is true when Kitsu couldn't be
    /// reached, so the caller can try again later instead of treating the shows as unknown.
    /// A rating, once found, is kept for good; a show without one (Kitsu often rates new
    /// shows a while after they start airing) is checked again after a day.
    func ratings(for lookups: [Lookup]) async -> (found: [Int: AgeRating], failed: Bool) {
        await loadIfNeeded()
        var found: [Int: AgeRating] = [:]
        var toFetch: [Lookup] = []
        let now = Date()
        for lookup in Set(lookups) {
            if let m = mappings[lookup.id] {
                if let r = m.rating { found[lookup.id] = r; continue }
                if now.timeIntervalSince(m.checkedAt) < Self.recheckAfter { continue }
            }
            toFetch.append(lookup)
        }
        var failed = false
        var start = 0
        while start < toFetch.count {
            let chunk = Array(toFetch[start..<min(start + 10, toFetch.count)])
            start += 10
            guard var fetched = await fetchMappings(site: "anilist/anime", ids: chunk.map(\.id)) else {
                failed = true
                break
            }
            // Backup: shows Kitsu hasn't linked to AniList yet, by their MyAnimeList id.
            let unlinked = chunk.filter { fetched[$0.id] == nil && $0.mal != nil }
            if !unlinked.isEmpty,
               let byMal = await fetchMappings(site: "myanimelist/anime", ids: unlinked.compactMap(\.mal)) {
                for lookup in unlinked {
                    if let mal = lookup.mal, let m = byMal[mal] { fetched[lookup.id] = m }
                }
            }
            for lookup in chunk {
                let m = fetched[lookup.id] ?? Mapping(kitsuId: mappings[lookup.id]?.kitsuId, rating: nil, checkedAt: now)
                mappings[lookup.id] = m
                if let r = m.rating { found[lookup.id] = r }
            }
        }
        if !toFetch.isEmpty { scheduleSave() }
        return (found, failed)
    }

    /// Kitsu's own id for a show (needed for its episode list).
    func kitsuId(for lookup: Lookup) async -> String? {
        await loadIfNeeded()
        if let id = mappings[lookup.id]?.kitsuId { return id }
        _ = await ratings(for: [lookup])
        return mappings[lookup.id]?.kitsuId
    }

    /// Kitsu mappings for up to 10 ids of one site, keyed by that site's id.
    private func fetchMappings(site: String, ids: [Int]) async -> [Int: Mapping]? {
        let list = ids.map(String.init).joined(separator: ",")
        let url = "\(Self.base)/mappings?filter%5BexternalSite%5D=\(site)&filter%5BexternalId%5D=\(list)"
            + "&include=item&page%5Blimit%5D=20&fields%5Banime%5D=ageRating,ageRatingGuide"
        guard let response: MappingResponse = await get(url) else { return nil }
        var ratingsByKitsuId: [String: AgeRating] = [:]
        for item in response.included ?? [] where item.type == "anime" {
            ratingsByKitsuId[item.id] = AgeRating(code: item.attributes?.ageRating,
                                                  guide: item.attributes?.ageRatingGuide)
        }
        var result: [Int: Mapping] = [:]
        for row in response.data ?? [] {
            guard let external = row.attributes?.externalId.flatMap(Int.init),
                  let item = row.relationships?.item?.data, item.type == "anime",
                  result[external] == nil else { continue }
            let rating = ratingsByKitsuId[item.id]
            result[external] = Mapping(kitsuId: item.id,
                                       rating: rating?.label == nil ? nil : rating,
                                       checkedAt: Date())
        }
        return result
    }

    /// One page (20) of Kitsu episodes, in order.
    func episodes(kitsuId: String, offset: Int) async -> (episodes: [EpisodeInfo], total: Int?)? {
        let url = "\(Self.base)/anime/\(kitsuId)/episodes?page%5Blimit%5D=20&page%5Boffset%5D=\(offset)&sort=number"
            + "&fields%5Bepisodes%5D=number,canonicalTitle,description,synopsis,thumbnail"
        guard let response: EpisodesResponse = await get(url) else { return nil }
        let episodes = (response.data ?? []).compactMap { row -> EpisodeInfo? in
            guard let a = row.attributes, let number = a.number else { return nil }
            let text = [a.description, a.synopsis].compactMap { $0 }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            return EpisodeInfo(number: number,
                               title: a.canonicalTitle?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                               description: text,
                               thumbnail: a.thumbnail?.original)
        }
        return (episodes, response.meta?.count)
    }

    private func get<T: Decodable>(_ urlString: String) async -> T? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.api+json", forHTTPHeaderField: "Accept")
        guard let result = try? await session.data(for: request),
              (result.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(T.self, from: result.0)
    }

    // MARK: JSON:API shapes

    private struct MappingResponse: Decodable {
        struct Row: Decodable {
            struct Attributes: Decodable { let externalId: String? }
            struct Relationships: Decodable {
                struct Item: Decodable {
                    struct Ref: Decodable { let id: String; let type: String }
                    let data: Ref?
                }
                let item: Item?
            }
            let attributes: Attributes?
            let relationships: Relationships?
        }
        struct Included: Decodable {
            struct Attributes: Decodable { let ageRating: String?; let ageRatingGuide: String? }
            let id: String
            let type: String
            let attributes: Attributes?
        }
        let data: [Row]?
        let included: [Included]?
    }

    private struct EpisodesResponse: Decodable {
        struct Row: Decodable {
            struct Attributes: Decodable {
                struct Thumb: Decodable { let original: String? }
                let number: Int?
                let canonicalTitle: String?
                let description: String?
                let synopsis: String?
                let thumbnail: Thumb?
            }
            let attributes: Attributes?
        }
        struct Meta: Decodable { let count: Int? }
        let data: [Row]?
        let meta: Meta?
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Seasons

/// The TV/ONA seasons of a show, in order, from AniList's prequel/sequel links. Walks through
/// OVAs and movies between seasons (e.g. Slime S1 → OVA → S2) but only lists the seasons.
actor SeasonChain {
    static let shared = SeasonChain()
    private var cache: [Int: [Media]] = [:]

    func seasons(for media: Media, client: AniListClient) async -> [Media] {
        if let cached = cache[media.id] { return cached }
        var known: [Int: Media] = [media.id: media]
        var visited: Set<Int> = [media.id]
        var before: [Media] = []
        var after: [Media] = []
        var back = Self.link(of: media, "PREQUEL")
        var forward = Self.link(of: media, "SEQUEL")

        for _ in 0..<12 {
            let wanted = [back, forward].compactMap { $0 }.filter { known[$0] == nil }
            if !wanted.isEmpty {
                guard let data = try? await client.run(Queries.mediaByIds,
                                                       variables: ["ids": wanted, "perPage": wanted.count],
                                                       as: PageData.self) else { break }
                for m in data.page.media { known[m.id] = m }
            }
            var moved = false
            if let id = back, !visited.contains(id), let m = known[id] {
                visited.insert(id)
                if Seasons.isSeries(m.format) { before.insert(m, at: 0) }
                back = Self.link(of: m, "PREQUEL")
                moved = true
            } else { back = nil }
            if let id = forward, !visited.contains(id), let m = known[id] {
                visited.insert(id)
                if Seasons.isSeries(m.format) { after.append(m) }
                forward = Self.link(of: m, "SEQUEL")
                moved = true
            } else { forward = nil }
            if !moved { break }
        }
        let result = before + [media] + after
        for m in result { cache[m.id] = result }
        return result
    }

    /// Next/previous entry: a TV/ONA season if there is one, otherwise any anime in between.
    private static func link(of media: Media, _ type: String) -> Int? {
        let edges = (media.relations?.edges ?? []).filter {
            $0.relationType == type && ($0.node?.type == nil || $0.node?.type == "ANIME")
        }
        return (edges.first { Seasons.isSeries($0.node?.format) } ?? edges.first)?.node?.id
    }
}

// MARK: - Episode lists

/// Episodes of one show: AniList's streaming episodes (titles + thumbnails) first, Kitsu for
/// descriptions and any missing thumbnails/titles. Saved on the phone and refreshed so
/// details added later show up: airing shows every 12 hours, finished shows with missing
/// descriptions or thumbnails daily, complete finished shows monthly. A saved list is shown
/// instantly while the refresh happens.
actor EpisodeService {
    static let shared = EpisodeService()

    struct Page: Codable {
        var episodes: [EpisodeInfo]
        var total: Int
        var kitsuId: String?
        var kitsuLoaded: Int
        var kitsuTotal: Int?
        var savedAt: Date
        var finished: Bool

        /// Every episode has a description and a thumbnail (nothing left to fill in).
        var complete: Bool {
            episodes.allSatisfy { $0.description != nil && $0.thumbnail != nil }
        }
    }

    private var memory: [Int: Page] = [:]

    private func cacheName(_ id: Int) -> String { "episodes-\(id)" }

    /// Whatever is saved for this show, however old (shown instantly while refreshing).
    func saved(for mediaId: Int) async -> Page? {
        if let page = memory[mediaId] { return page }
        let page = await DiskCache.loadInBackground(Page.self, name: cacheName(mediaId))
        if let page { memory[mediaId] = page }
        return page
    }

    func isStale(_ page: Page) -> Bool { !isFresh(page) }

    func firstPage(for media: Media, client: AniListClient) async -> Page {
        if let page = memory[media.id], isFresh(page) { return page }
        if let saved = await DiskCache.loadInBackground(Page.self, name: cacheName(media.id)), isFresh(saved) {
            memory[media.id] = saved
            return saved
        }
        async let streaming = streamingEpisodes(media.id, laterPart: Self.hasSeriesPrequel(media), client: client)
        async let kitsuId = KitsuClient.shared.kitsuId(for: .init(id: media.id, mal: media.idMal))
        let fromAniList = await streaming
        let kid = await kitsuId
        var kitsu: (episodes: [EpisodeInfo], total: Int?)? = nil
        if let kid { kitsu = await KitsuClient.shared.episodes(kitsuId: kid, offset: 0) }

        let total = Self.episodeCount(media: media, anilist: fromAniList.count, kitsu: kitsu?.total)
        var merged = Self.merge(count: total, anilist: fromAniList, kitsu: kitsu?.episodes ?? [])
        // A refresh only ever adds: anything saved before (e.g. a refresh while offline, or
        // descriptions loaded with "Show more") is kept where the new data has nothing.
        var old = memory[media.id]
        if old == nil { old = await DiskCache.loadInBackground(Page.self, name: cacheName(media.id)) }
        if let old {
            let previous = Dictionary(old.episodes.map { ($0.number, $0) }, uniquingKeysWith: { a, _ in a })
            merged = merged.map { fresh in
                guard let p = previous[fresh.number] else { return fresh }
                var e = fresh
                if e.title == nil { e.title = p.title }
                if e.description == nil { e.description = p.description }
                if e.thumbnail == nil { e.thumbnail = p.thumbnail }
                return e
            }
        }
        let page = Page(episodes: merged, total: total, kitsuId: kid,
                        kitsuLoaded: kitsu?.episodes.count ?? 0, kitsuTotal: kitsu?.total,
                        savedAt: Date(), finished: media.status == "FINISHED")
        memory[media.id] = page
        DiskCache.saveInBackground(page, name: cacheName(media.id))
        return page
    }

    /// Loads Kitsu's next 20 descriptions for long shows (AniList data is already complete).
    func loadMore(mediaId: Int) async -> Page? {
        guard var page = memory[mediaId], let kid = page.kitsuId,
              page.kitsuLoaded < (page.kitsuTotal ?? 0) else { return memory[mediaId] }
        guard let more = await KitsuClient.shared.episodes(kitsuId: kid, offset: page.kitsuLoaded) else { return page }
        page.kitsuLoaded += max(more.episodes.count, 1)
        var byNumber = Dictionary(page.episodes.map { ($0.number, $0) }, uniquingKeysWith: { a, _ in a })
        for k in more.episodes where k.number >= 1 && k.number <= page.total {
            var e = byNumber[k.number] ?? EpisodeInfo(number: k.number)
            if e.title == nil { e.title = k.title }
            if e.description == nil { e.description = k.description }
            if e.thumbnail == nil { e.thumbnail = k.thumbnail }
            byNumber[k.number] = e
        }
        page.episodes = byNumber.values.sorted { $0.number < $1.number }
        memory[mediaId] = page
        DiskCache.saveInBackground(page, name: cacheName(mediaId))
        return page
    }

    private func isFresh(_ page: Page) -> Bool {
        let age = Date().timeIntervalSince(page.savedAt)
        if !page.finished { return age < 12 * 3_600 }
        return page.complete ? age < 30 * 86_400 : age < 86_400
    }

    /// Aired episodes only for airing shows; never more than what anyone knows about.
    private static func episodeCount(media: Media, anilist: Int, kitsu: Int?) -> Int {
        if media.status == "NOT_YET_RELEASED" { return 0 }
        if media.status == "RELEASING", let next = media.nextAiringEpisode?.episode {
            return max(0, next - 1)
        }
        return media.episodes ?? max(anilist, kitsu ?? 0)
    }

    private static func merge(count: Int, anilist: [EpisodeInfo], kitsu: [EpisodeInfo]) -> [EpisodeInfo] {
        let a = Dictionary(anilist.map { ($0.number, $0) }, uniquingKeysWith: { x, _ in x })
        let k = Dictionary(kitsu.map { ($0.number, $0) }, uniquingKeysWith: { x, _ in x })
        guard count > 0 else { return [] }
        return (1...count).map { n in
            EpisodeInfo(number: n,
                        title: a[n]?.title ?? k[n]?.title,
                        description: k[n]?.description,
                        thumbnail: a[n]?.thumbnail ?? k[n]?.thumbnail)
        }
    }

    /// Season 2+, or the second cour of a season (has a TV/ONA entry before it).
    private static func hasSeriesPrequel(_ media: Media) -> Bool {
        (media.relations?.edges ?? []).contains {
            $0.relationType == "PREQUEL" && Seasons.isSeries($0.node?.format)
        }
    }

    private func streamingEpisodes(_ id: Int, laterPart: Bool, client: AniListClient) async -> [EpisodeInfo] {
        guard let data = try? await client.run(Queries.streamingEpisodes, variables: ["id": id],
                                               as: StreamingEpisodesData.self) else { return [] }
        var result: [EpisodeInfo] = []
        let raw = data.media?.streamingEpisodes ?? []
        for (index, ep) in raw.reversed().enumerated() {   // AniList lists them newest first
            let (number, title, special) = Self.parse(ep.title, fallback: index + 1)
            guard number >= 1, !special else { continue }    // "Episode 0" / "Episode 24.5" specials
            result.append(EpisodeInfo(number: number, title: title, description: nil, thumbnail: ep.thumbnail))
        }
        // Later parts on streaming sites often keep counting ("Episode 12" is this part's
        // episode 1): shift so the first one is 1. A first season whose list doesn't start at
        // episode 1 is another season's list (an AniList data mix-up), so it isn't used.
        if let first = result.map(\.number).min(), first > 1 {
            guard laterPart else { return [] }
            result = result.map { var e = $0; e.number -= first - 1; return e }
        }
        return result
    }

    /// "Episode 12 - The Title" → (12, "The Title", false); "Episode 24.5 - Recap" is a special.
    static func parse(_ raw: String?, fallback: Int) -> (Int, String?, Bool) {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return (fallback, nil, false) }
        if let match = raw.firstMatch(of: #/^(?:Episode|Ep\.?)\s*(\d+)(\.\d+)?\s*[-–—:]?\s*(.*)$/#.ignoresCase()) {
            let number = Int(match.1) ?? fallback
            let title = String(match.3).trimmingCharacters(in: .whitespaces)
            return (number, title.isEmpty ? nil : title, match.2 != nil)
        }
        return (fallback, raw, false)
    }
}
