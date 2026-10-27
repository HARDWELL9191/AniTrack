import Foundation

struct Recommendation: Identifiable, Hashable, Codable {
    var id: Int { media.id }
    let media: Media
    let score: Double
    let match: Int
    let because: [String]
    let sharedHighlights: [String]
    let onPlanning: Bool
}

struct RecommendationResult: Codable {
    /// New shows that aren't on your list (or are only on Planning).
    var discover: [Recommendation]
    /// Ranked picks from your own Planning list.
    var planning: [Recommendation]
    let generatedAt: Date
    /// Fingerprint of the list the picks were built from; picks are rebuilt only when it changes.
    var fingerprint: Int = 0
    /// True when on-device semantic similarity was part of the ranking.
    var usedOnDeviceAI: Bool = false

    mutating func remove(_ mediaId: Int) {
        discover.removeAll { $0.id == mediaId }
        planning.removeAll { $0.id == mediaId }
    }
}

/// Builds a taste profile from the user's list and ranks candidates by a blend of
/// (1) AniList community recommendations from the shows you rated highly,
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
    }

    /// Changes whenever something that affects the picks changes.
    /// Uses FNV-1a (not Swift's Hasher, which is randomly seeded per launch) so it survives restarts.
    static func fingerprint(entries: [ListEntry], options: Options) -> Int {
        var text = ""
        for e in entries.sorted(by: { $0.id < $1.id }) {
            text += "\(e.id):\(e.status.rawValue):\(Int(e.scoreValue));"
        }
        text += "|\(options.hideChinese)|\(options.includeUnreleased)|\(options.useOnDeviceAI)|"
        text += options.dismissed.sorted().map(String.init).joined(separator: ",")
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

        /// The features the candidate shares with your strongest likes, for the "why" line.
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
        case .PLANNING: return 0
        }
    }

    // MARK: Run

    static func run(entries: [ListEntry], client: AniListClient, options: Options) async throws -> RecommendationResult {
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
        let planningIds = Set(entries.filter { $0.status == .PLANNING }.map(\.mediaId))

        // Seeds: your strongest likes, newest first among equals.
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

        // 1) Community recommendations from your top shows.
        let seedList = Array(seeds)
        var start = 0
        let batchSize = 6
        while start < seedList.count {
            let batch = Array(seedList[start..<min(start + batchSize, seedList.count)])
            start += batchSize
            let ids = batch.map(\.mediaId)
            let data: SeedPageData
            do {
                data = try await client.run(Queries.seedRecommendations,
                                            variables: ["ids": ids, "perPage": ids.count, "recsPerMedia": 8],
                                            as: SeedPageData.self)
            } catch {
                // One failed batch shouldn't kill the whole run.
                if start <= batchSize { throw error } else { continue }
            }
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
            try await Task.sleep(nanoseconds: 300_000_000)
        }

        // 2) Explore by your top tags and genres to surface shows nobody linked yet.
        let excludeIds = Array(onList.keys.filter { !planningIds.contains($0) })
        let topTags = profile.top(prefix: "t:", count: 3)
        let topGenres = profile.top(prefix: "g:", count: 2)
        var explorations: [[String: Any]] = []
        if !topTags.isEmpty {
            explorations.append(["tags": topTags, "sort": ["SCORE_DESC"], "page": 1, "perPage": 40,
                                 "isAdult": false, "excludeIds": excludeIds])
        }
        if !topGenres.isEmpty {
            var vars: [String: Any] = ["genres": topGenres, "sort": ["POPULARITY_DESC"],
                                       "page": 1, "perPage": 40, "isAdult": false, "excludeIds": excludeIds]
            if let firstTag = topTags.first { vars["tags"] = [firstTag] }
            explorations.append(vars)
        }
        for vars in explorations {
            if let data = try? await client.run(Queries.browse, variables: vars, as: PageData.self) {
                for media in data.page.media where candidates[media.id] == nil {
                    candidates[media.id] = media
                }
            }
            try await Task.sleep(nanoseconds: 300_000_000)
        }

        // Planning entries are always candidates for the Planning picker.
        for id in planningIds { if let e = onList[id] { candidates[id] = candidates[id] ?? e.media } }

        // 3) Score.
        let maxCollab = max(collab.values.max() ?? 1, 0.0001)

        func allowed(_ m: Media) -> Bool {
            if m.isAdult == true { return false }
            if options.hideChinese && m.countryOfOrigin == "CN" { return false }
            if m.format == "MUSIC" { return false }
            if !options.includeUnreleased && m.status == "NOT_YET_RELEASED" { return false }
            if options.dismissed.contains(m.id) { return false }
            return true
        }

        // Cheap first pass (no AI) to pick a short list worth spending the AI work on.
        struct Scored { let media: Media; let collab: Double; let tagSim: Double; let quality: Double; var score: Double }
        var preScored: [Scored] = []
        for (id, media) in candidates {
            if let entry = onList[id], entry.status != .PLANNING { continue }
            guard allowed(media) else { continue }
            let c = (collab[id] ?? 0) / maxCollab
            let sim = max(0, profile.similarity(to: media))
            let quality = Double(media.averageScore ?? media.meanScore ?? 60) / 100
            preScored.append(Scored(media: media, collab: c, tagSim: sim, quality: quality,
                                    score: 0.5 * c + 0.38 * sim + 0.12 * quality))
        }
        preScored.sort { $0.score > $1.score }
        let shortList = Array(preScored.filter { !planningIds.contains($0.media.id) }.prefix(120))
            + Array(preScored.filter { planningIds.contains($0.media.id) }.prefix(120))

        // 4) On-device semantic re-rank: embed synopses of your strongest likes/dislikes and the
        //    short list, build a "taste vector", and compare. Embeddings are cached on disk.
        var usedAI = false
        var scoredCandidates: [(media: Media, score: Double)] = shortList.map { item -> (media: Media, score: Double) in
            (media: item.media, score: item.score)
        }
        if options.useOnDeviceAI {
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
                guard v.count == taste.count else { continue }
                for i in 0..<v.count { taste[i] += w * v[i] }
            }
            taste = SemanticEngine.normalized(taste)

            if !taste.isEmpty {
                // Re-scale cosine (embeddings of similar-length text cluster tightly) to 0...1 within this batch.
                let sims = shortList.map { item -> Float in
                    guard let v = vectors[item.media.id] else { return 0 }
                    return SemanticEngine.cosine(taste, v)
                }
                let lo = sims.min() ?? 0, hi = sims.max() ?? 1
                let span = max(hi - lo, 0.0001)
                scoredCandidates = zip(shortList, sims).map { item, sim -> (media: Media, score: Double) in
                    let semantic = Double((sim - lo) / span)
                    let score = 0.38 * item.collab + 0.24 * item.tagSim + 0.28 * semantic + 0.10 * item.quality
                    return (item.media, score)
                }
                usedAI = true
            }
        }
        scoredCandidates.sort { $0.score > $1.score }
        let top = max(scoredCandidates.first?.score ?? 1, 0.0001)

        func makeRec(_ item: (media: Media, score: Double)) -> Recommendation {
            let ratio = item.score / top
            let match = Int((min(0.99, 0.55 + 0.44 * ratio) * 100).rounded())
            return Recommendation(media: item.media,
                                  score: item.score,
                                  match: match,
                                  because: Array((reasons[item.media.id] ?? []).prefix(3)),
                                  sharedHighlights: profile.highlights(for: item.media),
                                  onPlanning: planningIds.contains(item.media.id))
        }

        let discover = scoredCandidates
            .filter { !planningIds.contains($0.media.id) }
            .prefix(60)
            .map(makeRec)
        let planning = scoredCandidates
            .filter { planningIds.contains($0.media.id) }
            .map(makeRec)

        return RecommendationResult(discover: Array(discover), planning: planning, generatedAt: Date(),
                                    fingerprint: fingerprint(entries: entries, options: options),
                                    usedOnDeviceAI: usedAI)
    }
}
