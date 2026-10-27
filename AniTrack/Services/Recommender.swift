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
            var w = (score - mean) / max(spread, 8) + 0.6
            if entry.status == .DROPPED { w = min(w, -0.5) }
            return min(2.0, max(-1.5, w))
        }
        switch entry.status {
        case .COMPLETED, .REPEATING: return 0.6
        case .CURRENT: return 0.5
        case .PAUSED: return 0.1
        case .DROPPED: return -1.0
        case .PLANNING: return 0.2   // you were interested enough to plan it
        }
    }

    // MARK: Run one round

    /// Returns new picks for `round` (1 = first screen). `exclude` holds IDs already shown.
    static func run(entries: [ListEntry],
                    client: AniListClient,
                    options: Options,
                    round: Int = 1,
                    exclude: Set<Int> = []) async throws -> (picks: [Recommendation], usedAI: Bool) {
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

        // Seeds: your strongest likes (never Planning), newest first among equals.
        let seeds = entries
            .filter { $0.status != .PLANNING && (weights[$0.mediaId] ?? 0) > 0.3 }
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
        let excludeIds = Array(Set(onList.keys).union(exclude))
        let topTags = profile.top(prefix: "t:", count: 3)
        let topGenres = profile.top(prefix: "g:", count: 2)
        var explorations: [[String: Any]] = []
        let base: [String: Any] = ["page": round, "perPage": 40, "isAdult": false, "excludeIds": excludeIds]

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
            if let data = try? await client.run(Queries.browse, variables: vars, as: PageData.self) {
                for media in data.page.media where candidates[media.id] == nil {
                    candidates[media.id] = media
                }
            }
            try await Task.sleep(nanoseconds: 300_000_000)
        }

        // 3) Cheap first pass (no AI) to pick a short list worth spending the AI work on.
        let maxCollab = max(collab.values.max() ?? 1, 0.0001)

        func allowed(_ m: Media) -> Bool {
            if onList[m.id] != nil || exclude.contains(m.id) { return false }
            if m.isAdult == true { return false }
            if options.hideChinese && m.countryOfOrigin == "CN" { return false }
            if m.format == "MUSIC" { return false }
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
        if options.useOnDeviceAI && !shortList.isEmpty {
            let anchors = entries
                .filter { $0.status != .PLANNING && abs(weights[$0.mediaId] ?? 0) >= 0.4 }
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
                guard v.count == taste.count else { continue }
                for i in 0..<v.count { taste[i] += w * v[i] }
            }
            taste = SemanticEngine.normalized(taste)

            if !taste.isEmpty {
                // Rescale cosine within this batch (embeddings of similar text cluster tightly).
                let sims = shortList.map { item -> Float in
                    guard let v = vectors[item.media.id] else { return 0 }
                    return SemanticEngine.cosine(taste, v)
                }
                let lo = sims.min() ?? 0, hi = sims.max() ?? 1
                let span = max(hi - lo, 0.0001)
                ranked = zip(shortList, sims).map { item, sim -> (media: Media, score: Double) in
                    let semantic = Double((sim - lo) / span)
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
        return (Array(picks), usedAI)
    }
}
