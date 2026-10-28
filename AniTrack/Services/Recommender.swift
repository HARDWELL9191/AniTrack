import Foundation

struct Recommendation: Identifiable, Hashable, Codable {
    var id: Int { media.id }
    let media: Media
    let score: Double
    let match: Int
    let because: [String]
    let sharedHighlights: [String]
}

/// One category's feed of picks. Grows in "rounds": when you reach the end, the next round
/// digs deeper (next page of fan recommendations, next page of category/tag exploration).
struct RecommendationResult: Codable {
    var picks: [Recommendation]
    var generatedAt: Date
    /// Fingerprint of the list the picks were built from; picks are rebuilt only when it changes.
    var fingerprint: Int
    var usedOnDeviceAI: Bool
    /// How many rounds have been loaded so far.
    var round: Int
    /// True when several deeper rounds found nothing new.
    var exhausted: Bool

    mutating func remove(_ mediaId: Int) {
        picks.removeAll { $0.id == mediaId }
    }
}

/// Builds a taste profile from the user's list and ranks candidates by a blend of
/// (1) AniList fan recommendations from the shows you rated highly,
/// (2) genre/tag similarity to your taste profile,
/// (3) on-device semantic similarity of synopses (Natural Language embeddings), and
/// (4) overall community score.
enum Recommender {
    struct Options {
        var hideChinese: Bool
        var includeUnreleased: Bool
        var dismissed: Set<Int>
        var titleLanguage: TitleLanguage
        var useOnDeviceAI: Bool
        var category: AnimeCategory?
        /// False in Low Power Mode or when the phone is hot; not part of the fingerprint, so
        /// saved picks stay valid and the AI pass simply resumes later.
        var aiAllowedNow: Bool = true
    }

    /// Uses FNV-1a (not Swift's Hasher, which is randomly seeded per launch) so it survives restarts.
    static func fingerprint(entries: [ListEntry], options: Options) -> Int {
        var text = ""
        for e in entries.sorted(by: { $0.id < $1.id }) {
            text += "\(e.id):\(e.status.rawValue):\(Int(e.scoreValue));"
        }
        text += "|\(options.hideChinese)|\(options.includeUnreleased)|\(options.useOnDeviceAI)|\(options.category?.id ?? "any")|"
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return Int(truncatingIfNeeded: hash)
    }

    // MARK: Taste profile

    struct TasteProfile {
        var features: [String: Double] = [:]
        var norm: Double = 0

        static func vector(for media: Media) -> [String: Double] {
            var v: [String: Double] = [:]
            for genre in media.genres ?? [] { v["g:" + genre] = 1.0 }
            for tag in media.tags ?? [] {
                let rank = Double(tag.rank ?? 50) / 100.0
                if rank >= 0.3 { v["t:" + tag.name] = rank }
            }
            return v
        }

        mutating func add(_ media: Media, weight: Double) {
            for (key, value) in Self.vector(for: media) {
                features[key, default: 0] += value * weight
            }
        }

        mutating func finalize() {
            norm = sqrt(features.values.reduce(0) { $0 + $1 * $1 })
        }

        func similarity(to media: Media) -> Double {
            guard norm > 0 else { return 0 }
            let v = Self.vector(for: media)
            let vNorm = sqrt(v.values.reduce(0) { $0 + $1 * $1 })
            guard vNorm > 0 else { return 0 }
            var dot = 0.0
            for (key, value) in v { dot += value * (features[key] ?? 0) }
            return dot / (norm * vNorm)
        }

        /// Similarity to the profile *without* this show's own contribution (leave-one-out), so a
        /// show on your list is matched against the rest of your taste instead of against itself.
        func similarity(to media: Media, excludingWeight w: Double) -> Double {
            guard w != 0 else { return similarity(to: media) }
            let v = Self.vector(for: media)
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

        /// The features the candidate shares with your strongest likes, for the "why" chips.
        func highlights(for media: Media, limit: Int = 3) -> [String] {
            Self.vector(for: media)
                .compactMap { key, value -> (String, Double)? in
                    let w = (features[key] ?? 0) * value
                    return w > 0 ? (key, w) : nil
                }
                .sorted { $0.1 > $1.1 }
                .prefix(limit)
                .map { String($0.0.dropFirst(2)) }
        }

        func top(prefix: String, count: Int) -> [String] {
            features.filter { $0.key.hasPrefix(prefix) && $0.value > 0 }
                .sorted { $0.value > $1.value }
                .prefix(count)
                .map { String($0.key.dropFirst(prefix.count)) }
        }
    }

    /// How strongly an entry says "I liked this" (positive) or "not for me" (negative).
    static func weight(for entry: ListEntry, mean: Double, spread: Double) -> Double {
        let score = entry.scoreValue
        if score > 0 {
            switch entry.status {
            case .COMPLETED, .REPEATING, .PLANNING:
                // Finished/rewatching/planned always counts as liked; your rating sets how much.
                // Curved so favorites dominate: 10/10 → 2.0, 9 → 1.69, 8 → 1.39, 6 → 0.91, 4 → 0.57.
                let t = min(1, score / 100)
                return 0.3 + 1.7 * t * t
            case .DROPPED:
                return -1.0 - 0.5 * (1 - min(1, score / 100))
            default:
                // Watching/paused: relative to your own scoring habits.
                let w = (score - mean) / max(spread, 8) + 0.6
                return min(2.0, max(-1.0, w))
            }
        }
        switch entry.status {
        case .COMPLETED, .REPEATING: return 0.7
        case .CURRENT: return 0.5
        case .PLANNING: return 0.5   // you liked it enough to plan it
        case .PAUSED: return 0.1
        case .DROPPED: return -1.0
        }
    }

    // MARK: Seasons

    static func collapseSeasons(candidates: inout [Int: Media],
                                collab: inout [Int: Double],
                                reasons: inout [Int: [String]],
                                onList: [Int: ListEntry],
                                client: AniListClient) async {
        let franchises = ListFranchises(onList.values.map(\.media))
        let later = candidates.values.filter(\.isLaterSeason)
        // Saved answers are reused (no requests); new ones are looked up and saved.
        var found: [Int: SeasonRoots.Found] = [:]
        if !later.isEmpty {
            found = await SeasonRoots.resolve(later, known: candidates, client: client, waitOnRateLimit: true)
        }

        var result: [Int: Media] = [:]
        for (id, media) in candidates {
            // Another season of a show already on your list (strict title match): you know it.
            if franchises.contains(media) { continue }
            guard media.isLaterSeason else {
                result[id] = result[id] ?? media
                continue
            }
            // (The walk only follows prequels of the same show, so the chain is this show.)
            let f = found[id]
            if f?.chain.contains(where: { onList[$0] != nil }) == true { continue }
            // Earliest TV/ONA season of this same show. If it can't be identified (offline),
            // the pick is kept as it is: a show is never dropped on a guess.
            let root = f?.root ?? media
            if root.id != id {
                if onList[root.id] != nil || franchises.contains(root) { continue }
                collab[root.id, default: 0] += collab[id] ?? 0
                for reason in reasons[id] ?? [] where !(reasons[root.id] ?? []).contains(reason) {
                    reasons[root.id, default: []].append(reason)
                }
            }
            result[root.id] = root
        }
        candidates = result
    }

    // MARK: Run one round

    /// Returns new picks for `round` (1 = first screen). `exclude` holds IDs already shown.
    static func run(entries: [ListEntry],
                    client: AniListClient,
                    options: Options,
                    round: Int = 1,
                    exclude: Set<Int> = []) async throws -> (picks: [Recommendation], usedAI: Bool, fanSignal: [Int: Double]) {
        let scored = entries.map(\.scoreValue).filter { $0 > 0 }
        let mean = scored.isEmpty ? 70 : scored.reduce(0, +) / Double(scored.count)
        let variance = scored.isEmpty ? 0 : scored.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(scored.count)
        let spread = sqrt(variance)

        var profile = TasteProfile()
        var weights: [Int: Double] = [:]
        for entry in entries {
            let w = weight(for: entry, mean: mean, spread: spread)
            weights[entry.mediaId] = w
            if w != 0 { profile.add(entry.media, weight: w) }
        }
        profile.finalize()

        let onList = Dictionary(entries.map { ($0.mediaId, $0) }, uniquingKeysWith: { a, _ in a })

        // Seeds: your strongest likes (Planning included), newest first among equals.
        let seeds = entries
            .filter { (weights[$0.mediaId] ?? 0) > 0.3 }
            .sorted {
                let a = weights[$0.mediaId] ?? 0, b = weights[$1.mediaId] ?? 0
                return a == b ? ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) : a > b
            }
            .prefix(30)

        var collab: [Int: Double] = [:]
        var reasons: [Int: [String]] = [:]
        var candidates: [Int: Media] = [:]

        // 1) Fan recommendations from your top shows (deeper pages on later rounds).
        let seedList = Array(seeds)
        var start = 0
        let batchSize = 6
        var firstBatch = true
        while start < seedList.count {
            let batch = Array(seedList[start..<min(start + batchSize, seedList.count)])
            start += batchSize
            let ids = batch.map(\.mediaId)
            do {
                let data = try await client.run(Queries.seedRecommendations,
                                                variables: ["ids": ids, "perPage": ids.count,
                                                            "recsPage": round, "recsPerMedia": 8],
                                                as: SeedPageData.self)
                for seedMedia in data.page.media {
                    guard let seed = onList[seedMedia.id] else { continue }
                    let seedWeight = weights[seedMedia.id] ?? 0.5
                    let seedTitle = seed.media.displayTitle(options.titleLanguage)
                    for node in seedMedia.recommendations?.nodes ?? [] {
                        guard let rec = node.mediaRecommendation, rec.id != seedMedia.id else { continue }
                        let rating = Double(max(node.rating ?? 0, 0))
                        guard rating > 0 else { continue }
                        collab[rec.id, default: 0] += seedWeight * log(1 + rating)
                        candidates[rec.id] = rec
                        if !(reasons[rec.id] ?? []).contains(seedTitle) {
                            reasons[rec.id, default: []].append(seedTitle)
                        }
                    }
                }
            } catch {
                // One failed batch shouldn't kill the whole round, but a failing first batch means
                // something's wrong (offline, rate limit), so surface it.
                if firstBatch && round == 1 { throw error }
            }
            firstBatch = false
            try await Task.sleep(nanoseconds: 300_000_000)
        }

        // 2) Explore beyond what fans linked: your top tags/genres, and the chosen category.
        // Only your list is excluded here: excluding shows already picked too would shift every
        // page and skip unseen shows in deeper rounds (picked ones are filtered out below).
        let excludeIds = Array(onList.keys)
        let topTags = profile.top(prefix: "t:", count: 3)
        let topGenres = profile.top(prefix: "g:", count: 2)
        var explorations: [[String: Any]] = []
        let adultOnly = options.category?.isAdultOnly == true
        let base: [String: Any] = ["page": round, "perPage": 40, "isAdult": adultOnly, "excludeIds": excludeIds,
                                   "formatNot": ["MOVIE"]]

        if let category = options.category {
            // Category mode: the category is the main source, ranked by your taste below.
            var byScore = base.merging(category.browseVariables) { a, _ in a }
            byScore["sort"] = ["SCORE_DESC"]
            var byPopularity = base.merging(category.browseVariables) { a, _ in a }
            byPopularity["sort"] = ["POPULARITY_DESC"]
            explorations += [byScore, byPopularity]
            if let tag = topTags.first, category.kind == .genre {
                var mixed = base.merging(category.browseVariables) { a, _ in a }
                mixed["tags"] = [tag]
                mixed["sort"] = ["SCORE_DESC"]
                explorations.append(mixed)
            }
        } else {
            if !topTags.isEmpty {
                var vars = base
                vars["tags"] = topTags
                vars["sort"] = ["SCORE_DESC"]
                explorations.append(vars)
            }
            if !topGenres.isEmpty {
                var vars = base
                vars["genres"] = topGenres
                vars["sort"] = ["POPULARITY_DESC"]
                if let firstTag = topTags.first { vars["tags"] = [firstTag] }
                explorations.append(vars)
            }
        }
        for vars in explorations {
            if let data = try? await client.run(Queries.browseWithRelations, variables: vars, as: PageData.self) {
                for media in data.page.media where candidates[media.id] == nil {
                    candidates[media.id] = media
                }
            }
            try await Task.sleep(nanoseconds: 300_000_000)
        }

        // 2b) One pick per show: Season 2+ becomes Season 1, and shows you already have
        //     (any season on your list) are skipped. Movies/OVAs/renamed sequels stay separate.
        await collapseSeasons(candidates: &candidates, collab: &collab, reasons: &reasons,
                              onList: onList, client: client)

        // 3) Cheap first pass (no AI) to pick a short list worth spending the AI work on.
        let maxCollab = max(collab.values.max() ?? 1, 0.0001)
        // How strongly fans of the shows you loved recommend each show (0...1), for match %.
        let fanSignal = collab.mapValues { min(1, max(0, $0 / maxCollab)) }

        func allowed(_ m: Media) -> Bool {
            if onList[m.id] != nil || exclude.contains(m.id) { return false }
            // Adult shows only when the Hentai category is picked.
            if m.isAdult == true && !adultOnly { return false }
            if options.hideChinese && m.countryOfOrigin == "CN" { return false }
            if m.format == "MUSIC" || m.isMovie { return false }   // movies only via search
            if !options.includeUnreleased && m.status == "NOT_YET_RELEASED" { return false }
            if options.dismissed.contains(m.id) { return false }
            if let category = options.category, !category.matches(m) { return false }
            return true
        }

        struct Scored { let media: Media; let collab: Double; let tagSim: Double; let quality: Double; let score: Double }
        var preScored: [Scored] = []
        for (id, media) in candidates where allowed(media) {
            let c = (collab[id] ?? 0) / maxCollab
            let sim = max(0, profile.similarity(to: media))
            let quality = Double(media.averageScore ?? media.meanScore ?? 60) / 100
            preScored.append(Scored(media: media, collab: c, tagSim: sim, quality: quality,
                                    score: 0.5 * c + 0.38 * sim + 0.12 * quality))
        }
        preScored.sort { $0.score > $1.score }
        let shortList = Array(preScored.prefix(80))

        // 4) On-device semantic re-rank: embed synopses of your strongest likes/dislikes and the
        //    short list, build a "taste vector", and compare. Embeddings are cached on disk.
        var usedAI = false
        var ranked: [(media: Media, score: Double)] = shortList.map { item -> (media: Media, score: Double) in
            (media: item.media, score: item.score)
        }
        if options.useOnDeviceAI && options.aiAllowedNow && !shortList.isEmpty {
            let anchors = entries
                .filter { abs(weights[$0.mediaId] ?? 0) >= 0.4 }
                .sorted { abs(weights[$0.mediaId] ?? 0) > abs(weights[$1.mediaId] ?? 0) }
                .prefix(40)
                .map(\.media)
            let toEmbed = Array(anchors) + shortList.map(\.media)
            let vectors = await Task.detached(priority: .utility) {
                await SemanticEngine.shared.vectors(for: toEmbed)
            }.value

            var taste: [Float] = []
            for media in anchors {
                guard let v = vectors[media.id] else { continue }
                let w = Float(weights[media.id] ?? 0)
                if taste.isEmpty { taste = [Float](repeating: 0, count: v.count) }
                SemanticEngine.accumulate(v, scale: w, into: &taste)
            }
            taste = SemanticEngine.normalized(taste)

            if !taste.isEmpty {
                // Rescale cosine within this batch (embeddings of similar text cluster tightly).
                // A show without a synopsis vector (no synopsis, or analysis skipped) gets a
                // neutral 0.5 instead of the lowest score, and doesn't stretch the scale.
                let sims = shortList.map { item -> Float? in
                    vectors[item.media.id].map { SemanticEngine.cosine(taste, $0) }
                }
                let known = sims.compactMap { $0 }
                let lo = known.min() ?? 0, hi = known.max() ?? 1
                let span = max(hi - lo, 0.0001)
                ranked = zip(shortList, sims).map { item, sim -> (media: Media, score: Double) in
                    let semantic = sim.map { Double(($0 - lo) / span) } ?? 0.5
                    return (media: item.media,
                            score: 0.38 * item.collab + 0.24 * item.tagSim + 0.28 * semantic + 0.10 * item.quality)
                }
                usedAI = true
            }
        }
        ranked.sort { $0.score > $1.score }

        // Match % is relative to the best pick in this round, so later rounds stay comparable.
        let top = max(ranked.first?.score ?? 1, 0.0001)
        let roundPenalty = Double(round - 1) * 0.04
        let picks = ranked.prefix(40).map { item -> Recommendation in
            let ratio = item.score / top
            let match = Int((max(0.5, min(0.99, 0.55 + 0.44 * ratio - roundPenalty)) * 100).rounded())
            return Recommendation(media: item.media,
                                  score: item.score,
                                  match: match,
                                  because: Array((reasons[item.media.id] ?? []).prefix(3)),
                                  sharedHighlights: profile.highlights(for: item.media))
        }
        return (Array(picks), usedAI, fanSignal)
    }
}


/// Seasons fetched while collapsing Season 2+ into Season 1, kept for the app session
/// so endless-feed rounds don't request the same shows again.
actor SeasonCache {
    static let shared = SeasonCache()
    private var media: [Int: Media] = [:]

    // Later season → its first season, saved on the phone (refreshed weekly), so shelves,
    // search and For You don't look the same franchises up again on every launch. The later
    // season itself is kept too, so the first season's dropdown always lists it.
    struct Root {
        let root: Media
        /// Every entry walked from the later season back to the first (to spot one on your list).
        let chain: [Int]
    }
    private struct SavedRoot: Codable { let root: Media; let later: Media; let chain: [Int]; let savedAt: Date }
    private static let rootsFile = "season-roots-v2"
    private static let maxAge: TimeInterval = 7 * 86_400
    private var roots: [Int: SavedRoot] = [:]
    private var rootsLoaded = false
    private var saveTask: Task<Void, Never>?

    func root(for laterId: Int) async -> Root? {
        await loadRoots()
        guard let saved = roots[laterId], Date().timeIntervalSince(saved.savedAt) < Self.maxAge else { return nil }
        return Root(root: saved.root, chain: saved.chain)
    }

    /// Later seasons known to belong to this first season (for its season dropdown).
    func laterSeasons(ofRoot rootId: Int) async -> [Media] {
        await loadRoots()
        let now = Date()
        return roots.values
            .filter { $0.root.id == rootId && now.timeIntervalSince($0.savedAt) < Self.maxAge }
            .map(\.later)
    }

    func storeRoots(_ found: [(later: Media, root: Media, chain: [Int])]) async {
        guard !found.isEmpty else { return }
        await loadRoots()
        if roots.count > 3000 { roots.removeAll(keepingCapacity: true) }
        let now = Date()
        for item in found {
            roots[item.later.id] = SavedRoot(root: item.root, later: item.later, chain: item.chain, savedAt: now)
        }
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)   // one write per burst
            guard !Task.isCancelled else { return }
            DiskCache.saveInBackground(self.roots, name: Self.rootsFile)
        }
    }

    private func loadRoots() async {
        guard !rootsLoaded else { return }
        rootsLoaded = true
        if let saved = await DiskCache.loadInBackground([Int: SavedRoot].self, name: Self.rootsFile) {
            roots.merge(saved) { current, _ in current }
        }
    }

    func merged(with candidates: [Int: Media]) -> [Int: Media] {
        media.merging(candidates) { _, new in new }
    }

    func store(_ items: [Media]) {
        if media.count > 1500 { media.removeAll(keepingCapacity: true) }
        for m in items { media[m.id] = m }
    }
}

/// Later seasons are shown as their first season everywhere except the details page's season
/// dropdown: "Black Clover Season 2" in a shelf or search becomes "Black Clover".
enum SeasonRoots {
    struct Found {
        let root: Media?
        let chain: [Int]
        /// Whether the walk reached the start (nothing left to load).
        let complete: Bool
    }

    /// First seasons for these later seasons: saved answers first (no requests), the rest by
    /// walking prequels. `waitOnRateLimit: false` gives up at once when AniList is busy, so a
    /// shelf is never held up (the item then shows as it is and is sorted out next time).
    static func resolve(_ later: [Media], known start: [Int: Media], client: AniListClient,
                        waitOnRateLimit: Bool) async -> [Int: Found] {
        var result: [Int: Found] = [:]
        var toWalk: [Media] = []
        for media in later {
            if let saved = await SeasonCache.shared.root(for: media.id) {
                result[media.id] = Found(root: saved.root, chain: saved.chain, complete: true)
            } else {
                toWalk.append(media)
            }
        }
        guard !toWalk.isEmpty else { return result }
        var known = await SeasonCache.shared.merged(with: start)

        /// Walks prequels: the earliest TV/ONA entry, every id passed, and the next id to load.
        func walk(_ media: Media) -> (root: Media?, chain: [Int], next: Int?) {
            var visited: Set<Int> = [media.id]
            var chain: [Int] = []
            var current = media
            var root: Media?
            while let previous = current.prequelId, visited.count < 15, !visited.contains(previous) {
                visited.insert(previous)
                guard let earlier = known[previous] else { return (root, chain, previous) }
                chain.append(earlier.id)
                if earlier.isSeason { root = earlier }   // a one-off prologue never stands in
                current = earlier
            }
            return (root, chain, nil)
        }

        // Up to 10 hops: long franchises (JoJo Part 7 → Part 1) need that many.
        for _ in 0..<10 {
            let missing = Array(Set(toWalk.compactMap { walk($0).next }))
            guard !missing.isEmpty else { break }
            var fetched: [Media] = []
            var start = 0
            while start < missing.count {
                let chunk = Array(missing[start..<min(start + 50, missing.count)])
                start += 50
                if let data = try? await client.run(Queries.mediaByIds,
                                                     variables: ["ids": chunk, "perPage": chunk.count],
                                                     as: PageData.self, waitOnRateLimit: waitOnRateLimit) {
                    for m in data.page.media { known[m.id] = m; fetched.append(m) }
                }
            }
            guard !fetched.isEmpty else { break }   // offline or rate limited: use what we have
            await SeasonCache.shared.store(fetched)
        }

        // Only complete answers are saved, so an offline half-answer is redone next time.
        var complete: [(later: Media, root: Media, chain: [Int])] = []
        for media in toWalk {
            let w = walk(media)
            result[media.id] = Found(root: w.root, chain: w.chain, complete: w.next == nil)
            if let root = w.root, w.next == nil { complete.append((media, root, w.chain)) }
        }
        await SeasonCache.shared.storeRoots(complete)
        return result
    }

    /// Same order, each later season replaced by its first season, no duplicates. When the
    /// first season can't be found (offline), the earliest one found is used; never dropped.
    static func collapse(_ items: [Media], client: AniListClient) async -> [Media] {
        let later = items.filter(\.isLaterSeason)
        guard !later.isEmpty else { return items }
        let found = await resolve(later, known: Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }),
                                  client: client, waitOnRateLimit: false)
        return apply(items, found: found)
    }

    /// Swaps in first seasons already worked out (same order, no duplicates).
    static func apply(_ items: [Media], found: [Int: Found]) -> [Media] {
        var seen: Set<Int> = []
        var result: [Media] = []
        for media in items {
            let shown = found[media.id]?.root ?? media
            if seen.insert(shown.id).inserted { result.append(shown) }
        }
        return result
    }
}
