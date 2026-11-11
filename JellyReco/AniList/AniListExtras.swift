import Foundation
import Observation

// Ported from AniReco (Kitsu age ratings for AniList covers, and a show's season chain).

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

// MARK: - Kitsu client

/// Kitsu's free public API (no account or key), for the age ratings on AniList covers.
/// Shows are matched by their AniList id, so there's no title guessing. Ratings are saved on
/// the phone for good; a show without one is re-checked after a day.
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
        var failed = false

        for _ in 0..<12 {
            let wanted = [back, forward].compactMap { $0 }.filter { known[$0] == nil }
            if !wanted.isEmpty {
                guard let data = try? await client.run(Queries.mediaByIds,
                                                       variables: ["ids": wanted, "perPage": wanted.count],
                                                       as: PageData.self) else { failed = true; break }
                for m in data.page.media { known[m.id] = m }
            }
            var moved = false
            if let id = back, !visited.contains(id), let m = known[id] {
                visited.insert(id)
                if m.isSeason { before.insert(m, at: 0) }
                back = Self.link(of: m, "PREQUEL")
                moved = true
            } else { back = nil }
            if let id = forward, !visited.contains(id), let m = known[id] {
                visited.insert(id)
                if m.isSeason { after.append(m) }
                forward = Self.link(of: m, "SEQUEL")
                moved = true
            } else { forward = nil }
            if !moved { break }
        }
        var result = before + [media] + after
        // Every season that's shown as this show anywhere in the app is in its dropdown, even
        // when the franchise splits into two sequels the walk above doesn't both follow
        // (Dragon Ball → Z → GT, and Super).
        let extras = await Self.foldedSeasons(for: result)
        let present = Set(result.map(\.id))
        var added = extras.filter { !present.contains($0.id) && $0.isSeason }
        var seenAdded: Set<Int> = []
        added = added.filter { seenAdded.insert($0.id).inserted }
        if !added.isEmpty {
            // Saved copies can be up to a week old: fetch them fresh (one request), so an airing
            // season shows its current episodes. Offline, the saved copies are used.
            if let data = try? await client.run(Queries.mediaByIds,
                                                 variables: ["ids": added.map(\.id), "perPage": min(added.count, 50)],
                                                 as: PageData.self) {
                let fresh = Dictionary(data.page.media.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                added = added.map { fresh[$0.id] ?? $0 }
            }
            var seen: Set<Int> = []
            result = (result + added).filter { seen.insert($0.id).inserted }.sorted(by: Self.airedBefore)
        }
        // A failed request (offline, page left mid-load) gives a partial chain: show it,
        // but don't keep it, so the next visit finds every season.
        if !failed { for m in result { cache[m.id] = result } }
        return result
    }

    /// First seasons and later seasons tied together by the app's "first season" lookups.
    private static func foldedSeasons(for chain: [Media]) async -> [Media] {
        var rootIds: [Int] = chain.first.map { [$0.id] } ?? []
        var extras: [Media] = []
        for m in chain {
            if let saved = await SeasonCache.shared.root(for: m.id), !rootIds.contains(saved.root.id) {
                rootIds.append(saved.root.id)
                extras.append(saved.root)
            }
        }
        for id in rootIds { extras += await SeasonCache.shared.laterSeasons(ofRoot: id) }
        return extras
    }

    /// Air order: year, then season of the year; unknown dates go last.
    private static func airedBefore(_ a: Media, _ b: Media) -> Bool {
        let order = ["WINTER": 0, "SPRING": 1, "SUMMER": 2, "FALL": 3]
        let ka = (a.seasonYear ?? Int.max, order[a.season ?? ""] ?? 4, a.id)
        let kb = (b.seasonYear ?? Int.max, order[b.season ?? ""] ?? 4, b.id)
        return ka < kb
    }

    /// Next/previous entry: a TV/ONA season if there is one, otherwise any anime in between.
    private static func link(of media: Media, _ type: String) -> Int? {
        let edges = (media.relations?.edges ?? []).filter {
            $0.relationType == type && ($0.node?.type == nil || $0.node?.type == "ANIME")
        }
        return (edges.first { Seasons.isSeries($0.node?.format) } ?? edges.first)?.node?.id
    }
}

// MARK: - Age ratings for covers

/// Age ratings for the covers on screen. Covers ask as they appear; requests are gathered for
/// a moment and sent in batches. Ratings are saved for good by KitsuClient, so a cover you've
/// seen before shows its rating instantly, with no request.
@Observable
@MainActor
final class AgeRatings {
    private(set) var ratings: [Int: AgeRating] = [:]

    @ObservationIgnored private var requested: Set<Int> = []
    @ObservationIgnored private var pending: [Int: KitsuClient.Lookup] = [:]
    @ObservationIgnored private var task: Task<Void, Never>?

    func rating(for mediaId: Int) -> AgeRating? { ratings[mediaId] }

    func request(_ media: Media) { request(id: media.id, mal: media.idMal) }

    func request(id: Int, mal: Int?) {
        guard ratings[id] == nil, !requested.contains(id) else { return }
        requested.insert(id)
        pending[id] = KitsuClient.Lookup(id: id, mal: mal)
        guard task == nil else { return }
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)   // collect the covers that just appeared
            await self?.flush()
        }
    }

    private func flush() async {
        while !pending.isEmpty {
            let batch = Array(pending.values.prefix(30))
            for lookup in batch { pending[lookup.id] = nil }
            let saved = await KitsuClient.shared.savedRatings(for: batch.map(\.id))
            if !saved.isEmpty { ratings.merge(saved) { _, new in new } }
            let missing = batch.filter { saved[$0.id] == nil }
            guard !missing.isEmpty else { continue }
            let (found, failed) = await KitsuClient.shared.ratings(for: missing)
            if !found.isEmpty { ratings.merge(found) { _, new in new } }
            if failed {
                // Kitsu unreachable: forget these so they're asked again next time they appear.
                requested.subtract(missing.map(\.id).filter { found[$0] == nil })
                requested.subtract(pending.keys)
                pending.removeAll()
            }
        }
        task = nil
    }
}
