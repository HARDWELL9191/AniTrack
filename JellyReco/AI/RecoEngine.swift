import Foundation
import Observation

/// A personal pick from the user's own Jellyfin library.
struct Pick: Identifiable, Hashable, Codable {
    var id: String { item.id }
    let item: BaseItem
    let score: Double
    let because: [String]
    let highlights: [String]
}

/// For You, built only from what's on the server: your libraries, what you've finished,
/// favourited, are watching or gave up on. Same recipe as AniReco's AI picks:
///
/// 1. Taste profile: genres, tags and studios of what you liked (finished, favourites, likes,
///    in progress) push up; what you abandoned or marked "Not for me" pushes down. History in
///    the library you're browsing counts 1.5×, the rest still helps.
/// 2. "Fans also liked": Jellyfin's own Similar items for your ~12 strongest likes (the
///    library equivalent of AniList fan recommendations).
/// 3. On-device AI re-rank: Apple's Natural Language model embeds each overview on the iPhone
///    and compares it with a taste vector built from your favourites. Cached on disk; skipped in
///    Low Power Mode or when the phone is hot.
/// 4. Community rating as a small quality nudge.
/// "Why would I like this?" is written by Apple Intelligence on device, only when asked.
@Observable
@MainActor
final class RecoEngine {
    // Public state
    private(set) var isBuilding = false
    private(set) var lastError: String?
    private(set) var builtAt: Date?
    private(set) var usedAI = false
    /// Ranked picks per source (library id or `RecoSource.all`).
    private(set) var picks: [String: [Pick]] = [:]
    /// Genres available in each source, most common first (the second dropdown).
    private(set) var genres: [String: [String]] = [:]
    /// Bumped when match percentages change.
    private(set) var version = 0

    @ObservationIgnored private weak var model: AppModel?
    /// Every movie/series in every eligible library, keyed by library id.
    @ObservationIgnored private var snapshot: [String: [BaseItem]] = [:]
    @ObservationIgnored private var itemLibrary: [String: String] = [:]
    @ObservationIgnored private var byId: [String: BaseItem] = [:]
    @ObservationIgnored private var profile = TasteProfile()
    @ObservationIgnored private var weights: [String: Double] = [:]
    @ObservationIgnored private var tagScale: (lo: Double, hi: Double) = (0, 1)
    @ObservationIgnored private var fan: [String: Double] = [:]
    @ObservationIgnored private var semantic: [String: Float] = [:]
    @ObservationIgnored private var matchMemo: [String: Int] = [:]
    @ObservationIgnored private var buildTask: Task<Void, Never>?
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var dirty = true
    @ObservationIgnored private var similarCache: [String: (items: [String], at: Date)] = [:]

    func attach(model: AppModel) { self.model = model }

    func reset() {
        buildTask?.cancel()
        picks = [:]
        genres = [:]
        snapshot = [:]
        itemLibrary = [:]
        byId = [:]
        profile = TasteProfile()
        weights = [:]
        fan = [:]
        semantic = [:]
        matchMemo = [:]
        similarCache = [:]
        builtAt = nil
        dirty = true
        version &+= 1
    }

    /// Something was watched/favourited: rebuild a little later (several changes → one build).
    func listChanged() {
        dirty = true
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.build(force: true)
        }
    }

    // MARK: Sources (first dropdown)

    struct Source: Identifiable, Hashable {
        let id: String
        let name: String
        let collectionType: String?
    }

    /// The user's own libraries by name (never one called "placeholder"), plus All.
    var sources: [Source] {
        guard let model else { return [] }
        let libs = model.libraries
            .filter { ["movies", "tvshows", "mixed", "homevideos", ""].contains($0.collectionType ?? "") }
            .filter { !RecoSource.isExcluded($0.name) }
            .map { Source(id: $0.id, name: $0.displayName, collectionType: $0.collectionType) }
        return libs + [Source(id: RecoSource.all, name: "All", collectionType: nil)]
    }

    /// The source to show: the saved choice if it still exists, else the library named Anime.
    var currentSourceId: String {
        guard let model else { return RecoSource.all }
        let list = sources
        let saved = model.settings.recoSource
        if !saved.isEmpty, list.contains(where: { $0.id == saved }) { return saved }
        return defaultSourceId(in: list)
    }

    func defaultSourceId(in list: [Source]) -> String {
        if let exact = list.first(where: { $0.name.compare("Anime", options: .caseInsensitive) == .orderedSame }) {
            return exact.id
        }
        if let anime = list.first(where: { $0.name.localizedCaseInsensitiveContains("anime")
                && !$0.name.localizedCaseInsensitiveContains("movie") && !$0.name.localizedCaseInsensitiveContains("film") }) {
            return anime.id
        }
        return list.first?.id ?? RecoSource.all
    }

    func sourceName(_ id: String) -> String {
        sources.first { $0.id == id }?.name ?? "All"
    }

    /// "anime", "show", "movie" or "title": used in prompts and empty states.
    func noun(for sourceId: String) -> String {
        let source = sources.first { $0.id == sourceId }
        let name = source?.name.lowercased() ?? ""
        if name.contains("anime") { return name.contains("movie") || name.contains("film") ? "anime movie" : "anime" }
        switch source?.collectionType {
        case "movies": return "movie"
        case "tvshows": return "show"
        default: return "title"
        }
    }

    func picks(for sourceId: String, genre: String?) -> [Pick] {
        _ = version
        let all = picks[sourceId] ?? []
        let visible = all.filter { pick in
            !(model?.isNotForMe(pick.item) ?? false) && !(model?.isPlayed(pick.item) ?? false)
                && !(model?.watchlist.contains(pick.id) ?? false)
                && (genre == nil || (pick.item.genres ?? []).contains(genre!))
        }
        guard let genre, visible.count > 1 else { return visible }
        // Within a genre, what you finished *in that genre* (in this library) matters most:
        // re-rank with that history counting extra.
        let key = "\(sourceId)|\(genre)|\(version)"
        if let order = genreOrder[key] {
            let pos = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
            return visible.sorted { (pos[$0.id] ?? .max) < (pos[$1.id] ?? .max) }
        }
        var p = TasteProfile()
        for (id, w) in weights {
            guard let item = byId[id] else { continue }
            var scaled = w
            if sourceId == RecoSource.all || itemLibrary[id] == sourceId { scaled *= 1.5 }
            if (item.genres ?? []).contains(genre) { scaled *= 1.6 }
            p.add(item, weight: scaled)
        }
        p.finalize()
        let rescored = visible.map { pick -> (Pick, Double) in
            let sim = max(0, p.similarity(to: pick.item, sameLibraryBoost: nil))
            return (pick, 0.6 * pick.score + 0.4 * sim)
        }.sorted { $0.1 > $1.1 }.map(\.0)
        if genreOrder.count > 60 { genreOrder.removeAll() }
        genreOrder[key] = rescored.map(\.id)
        return rescored
    }

    @ObservationIgnored private var genreOrder: [String: [String]] = [:]

    // MARK: Building

    func ensureBuilt() async {
        if picks.isEmpty || dirty { await build(force: false) }
    }

    func build(force: Bool) async {
        if let buildTask, !force {
            await buildTask.value
            return
        }
        buildTask?.cancel()
        let task = Task { [weak self] in await self?.runBuild() }
        buildTask = task
        await task.value
        if buildTask == task { buildTask = nil }
    }

    private func runBuild() async {
        guard let model, let client = model.client else { return }
        isBuilding = true
        lastError = nil
        defer { isBuilding = false }

        // 0) Fast start: last snapshot from disk while the fresh one loads.
        let cacheName = "reco-\(model.store.currentServerId ?? "s")-\(client.userId ?? "u")"
        if snapshot.isEmpty, let saved = await DiskCache.loadInBackground([String: [BaseItem]].self, name: cacheName) {
            ingest(saved)
            rankAll(aiAllowed: false)
        }

        // 1) Fresh snapshot of every eligible library.
        do {
            var fresh: [String: [BaseItem]] = [:]
            for source in sources where source.id != RecoSource.all {
                if Task.isCancelled { return }
                fresh[source.id] = try await fetchLibrary(source, client: client)
            }
            ingest(fresh)
            DiskCache.saveInBackground(fresh, name: cacheName)
        } catch {
            if AppModel.isCancellation(error) { return }
            if snapshot.isEmpty {
                lastError = error.localizedDescription
                return
            }
        }

        // 2) Taste profile + Similar ("fans also liked") from your strongest likes.
        rebuildProfile()
        await collectSimilar(client: client)
        if Task.isCancelled { return }

        // 3) Rank every source; then the on-device AI pass.
        rankAll(aiAllowed: false)
        let aiAllowed = model.settings.useOnDeviceAI && SemanticEngine.shouldRunNow
        if aiAllowed {
            await runSemantic()
            if Task.isCancelled { return }
            rankAll(aiAllowed: true)
        }
        usedAI = aiAllowed && !semantic.isEmpty
        builtAt = Date()
        dirty = false
    }

    private func fetchLibrary(_ source: Source, client: JellyfinClient) async throws -> [BaseItem] {
        var q = JellyfinClient.ItemQuery()
        q.parentId = source.id
        q.recursive = true
        switch source.collectionType {
        case "movies": q.includeItemTypes = [.movie]
        case "tvshows": q.includeItemTypes = [.series]
        default: q.includeItemTypes = [.movie, .series]
        }
        q.fields = ["Overview", "Genres", "Tags", "Studios", "ProductionYear", "CommunityRating", "OfficialRating",
                    "RecursiveItemCount", "ChildCount", "ProductionLocations", "OriginalTitle", "DateCreated",
                    "PrimaryImageAspectRatio", "Status", "EndDate", "RunTimeTicks"]
        q.sortBy = ["SortName"]
        q.limit = 400
        q.isMissing = nil
        var all: [BaseItem] = []
        while true {
            let page = try await client.items(q)
            let items = page.items ?? []
            all += items
            q.startIndex += items.count
            if items.isEmpty || all.count >= (page.totalRecordCount ?? 0) || all.count > 20_000 { break }
        }
        return all
    }

    private func ingest(_ libs: [String: [BaseItem]]) {
        snapshot = libs
        itemLibrary = [:]
        byId = [:]
        for (lib, items) in libs {
            for item in items {
                itemLibrary[item.id] = lib
                byId[item.id] = item
            }
        }
        var genreCounts: [String: [String: Int]] = [:]
        for (lib, items) in libs {
            for item in items { for g in item.genres ?? [] { genreCounts[lib, default: [:]][g, default: 0] += 1 } }
        }
        var merged: [String: Int] = [:]
        for counts in genreCounts.values { merged.merge(counts, uniquingKeysWith: +) }
        var result: [String: [String]] = [:]
        for (lib, counts) in genreCounts {
            result[lib] = counts.filter { $0.value >= 2 }.sorted { $0.value > $1.value }.map(\.key)
        }
        result[RecoSource.all] = merged.filter { $0.value >= 2 }.sorted { $0.value > $1.value }.map(\.key)
        genres = result
    }

    // MARK: Signals

    /// How strongly your history says "liked" (positive) or "not for me" (negative); nil = no signal.
    private func signal(for item: BaseItem) -> Double? {
        guard let model else { return nil }
        if model.isNotForMe(item) { return -1.0 }
        let ud = model.userData(for: item) ?? UserItemData()
        var w: Double? = model.watchlist.contains(item.id) ? 0.5 : nil   // planned = liked enough to plan
        let daysSince = ud.lastPlayedDate.map { Date().timeIntervalSince($0) / 86_400 } ?? 0

        if ud.played == true {
            w = 1.0 + min(0.4, Double(max(0, (ud.playCount ?? 1) - 1)) * 0.2)   // rewatched = loved
        } else if item.kind == .series {
            let total = item.recursiveItemCount ?? 0
            let unplayed = ud.unplayedItemCount ?? total
            let watched = max(0, total - unplayed)
            if total > 0 && watched > 0 {
                let frac = Double(watched) / Double(total)
                if frac < 0.35 && daysSince > 60 {
                    w = -0.6                                  // tried it, gave up
                } else if model.settings.includeWatchingAsLiked {
                    w = 0.4 + 0.6 * frac
                }
            }
        } else if let pct = ud.playedPercentage, pct > 0 {
            w = (pct < 25 && daysSince > 30) ? -0.4 : (model.settings.includeWatchingAsLiked ? max(w ?? 0, 0.4) : w)
        }
        if ud.isFavorite == true { w = max(w ?? 0, 0) + 0.9 }
        if let likes = ud.likes { w = likes ? max(w ?? 0, 0) + 0.5 : -1.0 }
        return w
    }

    private func isCandidate(_ item: BaseItem) -> Bool {
        guard let model else { return false }
        if model.isNotForMe(item) || model.watchlist.contains(item.id) { return false }
        let ud = model.userData(for: item)
        if ud?.played == true || ud?.isFavorite == true { return false }
        if (ud?.playedPercentage ?? 0) > 0 { return false }
        if item.kind == .series {
            let total = item.recursiveItemCount ?? 0
            if total == 0 { return false }                     // no episodes on the server yet
            if let unplayed = ud?.unplayedItemCount, unplayed < total { return false }
        }
        return true
    }

    private func rebuildProfile() {
        var p = TasteProfile()
        var w: [String: Double] = [:]
        for item in byId.values {
            guard let s = signal(for: item) else { continue }
            w[item.id] = s
            p.add(item, weight: s)
        }
        p.finalize()
        profile = p
        weights = w
        // Calibrate "very high match" on your well-liked titles (each vs. the rest of your history).
        let liked = w.filter { $0.value > 0.5 }.compactMap { id, wt in byId[id].map { p.similarity(to: $0, excludingWeight: wt) } }.sorted()
        let all = byId.values.prefix(2000).map { p.similarity(to: $0, excludingWeight: w[$0.id] ?? 0) }.sorted()
        let hi = liked.isEmpty ? 0.55 : liked[min(liked.count - 1, Int(Double(liked.count) * 0.75))]
        let lo = all.isEmpty ? 0.0 : min(all[Int(Double(all.count - 1) * 0.1)], hi * 0.4)
        tagScale = (lo, max(hi, lo + 0.05))
        matchMemo = [:]
        version &+= 1
    }

    /// Jellyfin's Similar items for your strongest likes = "people who liked X".
    private func collectSimilar(client: JellyfinClient) async {
        let seeds = weights.filter { $0.value > 0.6 }
            .sorted { a, b in
                let ra = byId[a.key]?.userData?.lastPlayedDate ?? .distantPast
                let rb = byId[b.key]?.userData?.lastPlayedDate ?? .distantPast
                return a.value == b.value ? ra > rb : a.value > b.value
            }
            .prefix(16)
        var votes: [String: Double] = [:]
        var reasons: [String: [String]] = [:]
        var results: [(String, [String])] = []
        var toFetch: [String] = []
        for (seedId, _) in seeds {
            if let hit = similarCache[seedId], Date().timeIntervalSince(hit.at) < 3 * 86_400 {
                results.append((seedId, hit.items))
            } else {
                toFetch.append(seedId)
            }
        }
        let fetched = await withTaskGroup(of: (String, [String]).self, returning: [(String, [String])].self) { group in
            for seedId in toFetch {
                group.addTask {
                    let ids = (try? await client.similar(seedId, limit: 30))?.map(\.id) ?? []
                    return (seedId, ids)
                }
            }
            var out: [(String, [String])] = []
            for await r in group { out.append(r) }
            return out
        }
        for (seedId, ids) in fetched where !ids.isEmpty { similarCache[seedId] = (ids, Date()) }
        results += fetched
        for (seedId, ids) in results {
            let seedWeight = weights[seedId] ?? 0.5
            let title = byId[seedId]?.displayName ?? ""
            for (rank, id) in ids.enumerated() {
                votes[id, default: 0] += seedWeight * (1 - Double(rank) / 32)
                if !title.isEmpty, !(reasons[id] ?? []).contains(title) { reasons[id, default: []].append(title) }
            }
        }
        let maxVote = max(votes.values.max() ?? 1, 0.0001)
        fan = votes.mapValues { min(1, $0 / maxVote) }
        becauseSimilar = reasons
        matchMemo = [:]
        version &+= 1
    }

    @ObservationIgnored private var becauseSimilar: [String: [String]] = [:]

    // MARK: AI pass

    @ObservationIgnored private var tasteVector: [Float] = []
    @ObservationIgnored private var anchorVectors: [String: [Float]] = [:]

    static func embeddingInput(_ item: BaseItem) -> SemanticEngine.Input {
        let genres = (item.genres ?? []).joined(separator: ", ")
        let tags = (item.tags ?? []).prefix(6).joined(separator: ", ")
        let text = "\(item.displayName). \(genres). \(tags). \(String(item.plainOverview.prefix(500)))"
        return SemanticEngine.Input(key: "\(item.id)|\(SemanticEngine.stableKey(text))", text: text)
    }

    private func runSemantic() async {
        // Anchors: your strongest likes and dislikes. Candidates: the best ~120 of each source.
        let anchors = weights.filter { abs($0.value) >= 0.4 }
            .sorted { abs($0.value) > abs($1.value) }
            .prefix(50)
            .compactMap { byId[$0.key] }
            .filter { !$0.plainOverview.isEmpty }
        guard !anchors.isEmpty else { return }
        var shortlist: [BaseItem] = []
        var seen: Set<String> = []
        for list in picks.values {
            for pick in list.prefix(120) where seen.insert(pick.id).inserted { shortlist.append(pick.item) }
        }
        let inputs = (anchors + shortlist).map(Self.embeddingInput)
        let keyOf = Dictionary(uniqueKeysWithValues: (anchors + shortlist).map { ($0.id, Self.embeddingInput($0).key) })
        let vectors = await Task.detached(priority: .utility) {
            await SemanticEngine.shared.vectors(for: inputs)
        }.value
        guard !Task.isCancelled else { return }

        var taste: [Float] = []
        var anchorV: [String: [Float]] = [:]
        for a in anchors {
            guard let key = keyOf[a.id], let v = vectors[key] else { continue }
            if taste.isEmpty { taste = [Float](repeating: 0, count: v.count) }
            SemanticEngine.accumulate(v, scale: Float(weights[a.id] ?? 0), into: &taste)
            if (weights[a.id] ?? 0) > 0 { anchorV[a.id] = v }
        }
        guard !taste.isEmpty else { return }
        taste = SemanticEngine.normalized(taste)
        tasteVector = taste
        anchorVectors = anchorV

        var sims: [String: Float] = [:]
        for item in shortlist {
            guard let key = keyOf[item.id], let v = vectors[key] else { continue }
            sims[item.id] = SemanticEngine.cosine(taste, v)
            candidateVectors[item.id] = v
        }
        let sorted = sims.values.sorted()
        guard sorted.count >= 3 else { return }
        let lo = sorted[Int(Double(sorted.count - 1) * 0.1)], hi = sorted[Int(Double(sorted.count - 1) * 0.9)]
        let span = max(hi - lo, 0.0001)
        semantic = sims.mapValues { max(-1, min(1, ($0 - lo) / span)) }
        matchMemo = [:]
        version &+= 1
    }

    @ObservationIgnored private var candidateVectors: [String: [Float]] = [:]

    // MARK: Ranking

    private func rankAll(aiAllowed: Bool) {
        var result: [String: [Pick]] = [:]
        let maxQuality = 10.0
        func rank(_ items: [BaseItem], sourceId: String) -> [Pick] {
            var scored: [(BaseItem, Double)] = []
            for item in items where isCandidate(item) {
                let sim = max(0, profile.similarity(to: item, sameLibraryBoost: nil))
                let c = fan[item.id] ?? 0
                let q = (item.communityRating ?? 6.5) / maxQuality
                var score = 0.45 * c + 0.40 * sim + 0.15 * q
                if aiAllowed, let sem = semantic[item.id] {
                    let s = Double((sem + 1) / 2)
                    score = 0.30 * c + 0.25 * sim + 0.33 * s + 0.12 * q
                }
                scored.append((item, score))
            }
            scored.sort { $0.1 > $1.1 }
            return scored.prefix(200).map { item, score in
                Pick(item: item, score: score, because: because(for: item), highlights: profile.highlights(for: item))
            }
        }
        for (lib, items) in snapshot {
            // History in this library counts 1.5×: a tailored profile per source.
            result[lib] = withProfile(boostedFor: lib) { rank(items, sourceId: lib) }
        }
        result[RecoSource.all] = rank(Array(byId.values), sourceId: RecoSource.all)
        picks = result
    }

    /// Temporarily weights history from one library higher while ranking it.
    private func withProfile<T>(boostedFor lib: String, _ body: () -> T) -> T {
        let saved = profile
        var p = TasteProfile()
        for (id, w) in weights {
            guard let item = byId[id] else { continue }
            p.add(item, weight: itemLibrary[id] == lib ? w * 1.5 : w)
        }
        p.finalize()
        profile = p
        defer { profile = saved }
        return body()
    }

    private func because(for item: BaseItem) -> [String] {
        if let viaSimilar = becauseSimilar[item.id], !viaSimilar.isEmpty { return Array(viaSimilar.prefix(3)) }
        if let v = candidateVectors[item.id], !anchorVectors.isEmpty {
            return anchorVectors.map { ($0.key, SemanticEngine.cosine($0.value, v)) }
                .sorted { $0.1 > $1.1 }
                .prefix(2)
                .compactMap { byId[$0.0]?.displayName }
        }
        let mine = Set(item.genres ?? [])
        return weights.filter { $0.value > 0.6 }
            .compactMap { id, _ in byId[id] }
            .map { ($0, Set($0.genres ?? []).intersection(mine).count) }
            .filter { $0.1 >= 2 }
            .sorted { $0.1 > $1.1 }
            .prefix(2)
            .map(\.0.displayName)
    }

    // MARK: Match %

    /// Personal match % for any movie/series in your libraries (nil until history exists).
    func match(for item: BaseItem) -> Int? {
        _ = version
        guard profile.norm > 0 else { return nil }
        let target: BaseItem
        if item.kind == .episode || item.kind == .season, let sid = item.seriesId, let series = byId[sid] {
            target = series
        } else {
            target = byId[item.id] ?? item
        }
        guard target.kind == .movie || target.kind == .series else { return nil }
        if let memo = matchMemo[target.id] { return memo }
        let raw = profile.similarity(to: target, excludingWeight: weights[target.id] ?? 0)
        var z = max(-1, min(1, (raw - tagScale.lo) / (tagScale.hi - tagScale.lo)))
        if let sem = semantic[target.id] { z = 0.55 * z + 0.45 * Double(sem) }
        if let f = fan[target.id], f > 0, z < 1 { z += (1 - z) * 0.5 * f }
        let percent = z >= 0 ? Int((50 + 49 * min(z, 1)).rounded()) : Int((50 + 30 * z).rounded())
        matchMemo[target.id] = percent
        return percent
    }

    /// Unwatched titles like this one, from your library, best match first ("More like this").
    func moreLike(_ item: BaseItem) async -> [BaseItem] {
        guard let client = model?.client else { return [] }
        let base = item.kind == .episode ? (item.seriesId ?? item.id) : item.id
        let similar = (try? await client.similar(base, limit: 40)) ?? []
        let unwatched = similar.filter { !($0.userData?.played ?? false) && !(model?.isNotForMe($0) ?? false) }
        return unwatched.sorted { (match(for: $0) ?? 0) > (match(for: $1) ?? 0) }
    }

    func titleFor(_ id: String) -> String? { byId[id]?.displayName }

    /// Titles you loved most (for explanations).
    func topLiked(in sourceId: String, limit: Int = 8) -> [String] {
        weights.filter { $0.value > 0.6 && (sourceId == RecoSource.all || itemLibrary[$0.key] == sourceId) }
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .compactMap { byId[$0.key]?.displayName }
    }

    func dismiss(_ item: BaseItem) {
        guard let model else { return }
        Task { await model.setNotForMe(item, true) }
    }

    func resetDismissed() {
        guard let model else { return }
        Task { await model.resetNotForMe() }
    }
}

// MARK: - Taste profile (genres, tags, studios)

struct TasteProfile {
    var features: [String: Double] = [:]
    var norm: Double = 0

    static func vector(for item: BaseItem) -> [String: Double] {
        var v: [String: Double] = [:]
        for g in item.genres ?? [] { v["g:" + g] = 1.0 }
        for t in (item.tags ?? []).prefix(15) { v["t:" + t.lowercased()] = 0.6 }
        for s in (item.studios ?? []).prefix(3) { if let n = s.name { v["s:" + n] = 0.45 } }
        if let y = item.productionYear { v["d:\(y / 10 * 10)"] = 0.15 }
        return v
    }

    mutating func add(_ item: BaseItem, weight: Double) {
        guard weight != 0 else { return }
        for (key, value) in Self.vector(for: item) { features[key, default: 0] += value * weight }
    }

    mutating func finalize() {
        norm = sqrt(features.values.reduce(0) { $0 + $1 * $1 })
    }

    func similarity(to item: BaseItem, sameLibraryBoost: Double?) -> Double {
        guard norm > 0 else { return 0 }
        let v = Self.vector(for: item)
        let vNorm = sqrt(v.values.reduce(0) { $0 + $1 * $1 })
        guard vNorm > 0 else { return 0 }
        var dot = 0.0
        for (key, value) in v { dot += value * (features[key] ?? 0) }
        return dot / (norm * vNorm)
    }

    /// Leave-one-out: a title in your history is compared with the rest of your taste.
    func similarity(to item: BaseItem, excludingWeight w: Double) -> Double {
        guard w != 0 else { return similarity(to: item, sameLibraryBoost: nil) }
        let v = Self.vector(for: item)
        let vNorm = sqrt(v.values.reduce(0) { $0 + $1 * $1 })
        guard vNorm > 0 else { return 0 }
        var normSq = norm * norm
        var dot = 0.0
        for (key, value) in v {
            let f = features[key] ?? 0
            let without = f - value * w
            normSq += without * without - f * f
            dot += value * without
        }
        guard normSq > 1e-9 else { return 0 }
        return dot / (sqrt(normSq) * vNorm)
    }

    func highlights(for item: BaseItem, limit: Int = 3) -> [String] {
        Self.vector(for: item)
            .compactMap { key, value -> (String, Double)? in
                guard !key.hasPrefix("d:") else { return nil }
                let w = (features[key] ?? 0) * value
                return w > 0 ? (key, w) : nil
            }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { String($0.0.dropFirst(2)).capitalized }
    }
}
