import Foundation

/// "People with your taste" (collaborative filtering), like Yuki.
///
/// 1. For a few of your favourite shows, look at public lists of people who finished them and
///    rated them highly: those are candidate "taste twins".
/// 2. Download each candidate's scores (scores only, no show details: small), and measure how
///    well their ratings agree with yours on the shows you both watched.
/// 3. Shows your closest twins loved and you haven't seen get a score (0...1).
///
/// It's network-only (no AI), ~35 small requests spaced ~2 s apart, run at most about once a
/// week, at low priority, never in Low Power Mode. The result is saved on the phone.
actor TasteTwins {
    static let shared = TasteTwins()

    struct Result: Codable {
        var computedAt: Date
        /// Fingerprint of your liked shows when this was computed.
        var likedFingerprint: Int
        /// Show id → how much your taste twins love it (0...1), best first in `ranked`.
        var scores: [Int: Double]
        var ranked: [Int]
        var twins: Int
    }

    private var running = false
    private static let spacing: UInt64 = 2_100_000_000   // AniList is strict about request rates
    private static let maxTwins = 30

    // MARK: Cache

    private func cacheName(_ viewerId: Int) -> String { "twins-\(viewerId)" }

    func cached(viewerId: Int) async -> Result? {
        await DiskCache.loadInBackground(Result.self, name: cacheName(viewerId))
    }

    static func likedFingerprint(_ weights: [Int: Double]) -> Int {
        var hash: UInt64 = 0xcbf29ce484222325
        for id in weights.filter({ $0.value > 0.5 }).keys.sorted() {
            for byte in String(id).utf8 { hash ^= UInt64(byte); hash = hash &* 0x100000001b3 }
            hash ^= 59; hash = hash &* 0x100000001b3
        }
        return Int(truncatingIfNeeded: hash)
    }

    /// Fresh enough: under a week old, or under a day old even if your favourites changed.
    static func isFresh(_ result: Result?, weights: [Int: Double]) -> Bool {
        guard let result else { return false }
        let age = Date().timeIntervalSince(result.computedAt)
        if age < 86_400 { return true }
        return age < 7 * 86_400 && result.likedFingerprint == likedFingerprint(weights)
    }

    // MARK: Compute

    /// Recomputes when stale. Returns the (new or cached) result, or nil if nothing is available.
    func refreshIfNeeded(viewerId: Int, entries: [ListEntry], weights: [Int: Double],
                         client: AniListClient) async -> Result? {
        let old = await cached(viewerId: viewerId)
        if Self.isFresh(old, weights: weights) || running { return old }
        guard !ProcessInfo.processInfo.isLowPowerModeEnabled else { return old }
        running = true
        defer { running = false }
        guard let fresh = await compute(entries: entries, weights: weights, client: client) else { return old }
        DiskCache.saveInBackground(fresh, name: cacheName(viewerId))
        return fresh
    }

    private func compute(entries: [ListEntry], weights: [Int: Double], client: AniListClient) async -> Result? {
        let mine = Dictionary(entries.map { ($0.mediaId, $0) }, uniquingKeysWith: { a, _ in a })
        // Favourites to find twins through: your most-liked finished shows.
        let anchors = entries
            .filter { ($0.status == .COMPLETED || $0.status == .REPEATING) && (weights[$0.mediaId] ?? 0) > 0.5 }
            .sorted { (weights[$0.mediaId] ?? 0) > (weights[$1.mediaId] ?? 0) }
            .prefix(6)
        guard anchors.count >= 2 else { return nil }   // too little to go on yet

        // 1) Candidate twins: people who rated your favourites highly.
        var hits: [Int: Int] = [:]
        var requests = 0
        for anchor in anchors {
            if Task.isCancelled { return nil }
            if requests > 0 { try? await Task.sleep(nanoseconds: Self.spacing) }
            requests += 1
            let page = Int.random(in: 1...4)
            guard let data = try? await client.run(Queries.showFans,
                                                   variables: ["mediaId": anchor.mediaId, "page": page],
                                                   as: ShowFansData.self) else { continue }
            for row in data.page?.mediaList ?? [] {
                guard let user = row.userId, let score = row.score, score >= 75 else { continue }
                hits[user, default: 0] += 1
            }
        }
        let candidates = hits.shuffled().sorted { $0.value > $1.value }   // ties in random order
            .prefix(Self.maxTwins).map(\.key)
        guard !candidates.isEmpty else { return nil }

        // 2) Their scores, and how well they agree with yours.
        struct Twin { let similarity: Double; let prefs: [Int: Double] }
        var twins: [Twin] = []
        for user in candidates {
            if Task.isCancelled { break }
            try? await Task.sleep(nanoseconds: Self.spacing)
            guard let data = try? await client.run(Queries.ratingsOnly, variables: ["userId": user],
                                                   as: RatingsOnlyData.self) else { continue }
            let rows = (data.collection?.lists ?? []).flatMap { $0.entries ?? [] }
            let scored = rows.compactMap(\.score).filter { $0 > 0 }
            guard scored.count >= 10 else { continue }   // unrated lists say nothing about taste
            let mean = scored.reduce(0, +) / Double(scored.count)
            let sd = max(8, sqrt(scored.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(scored.count)))

            // Preference per show: above their own average = liked, dropped = disliked.
            var prefs: [Int: Double] = [:]
            for row in rows {
                if let s = row.score, s > 0 {
                    prefs[row.mediaId] = max(-2, min(2, (s - mean) / sd))
                } else if row.status == .DROPPED {
                    prefs[row.mediaId] = -1
                }
            }
            // Agreement on shows you both have, weighted by how much each one matters to you.
            var agree = 0.0, norm = 0.0, overlap = 0
            for (id, pref) in prefs {
                guard let w = weights[id], w != 0, mine[id] != nil else { continue }
                agree += w * pref
                norm += w * w
                overlap += 1
            }
            guard overlap >= 2, norm > 0 else { continue }
            // Shrink small overlaps: two shared shows say less than ten.
            let similarity = agree / sqrt(norm) * Double(overlap) / Double(overlap + 4)
            if similarity > 0.05 { twins.append(Twin(similarity: similarity, prefs: prefs)) }
        }
        guard twins.count >= 3 else { return nil }

        // 3) What your twins love that you haven't seen. Needs at least two twins who liked it.
        var sum: [Int: Double] = [:]
        var support: [Int: Int] = [:]
        let totalSimilarity = twins.reduce(0) { $0 + $1.similarity }
        for twin in twins {
            for (id, pref) in twin.prefs where mine[id] == nil {
                sum[id, default: 0] += twin.similarity * pref
                if pref > 0.25 { support[id, default: 0] += 1 }
            }
        }
        var raw: [Int: Double] = [:]
        for (id, value) in sum where (support[id] ?? 0) >= 2 && value > 0 {
            raw[id] = value / totalSimilarity
        }
        let top = raw.values.max() ?? 0
        guard top > 0 else { return nil }
        let ranked = raw.sorted { $0.value > $1.value }.prefix(400)
        var scores: [Int: Double] = [:]
        for (id, value) in ranked { scores[id] = value / top }
        return Result(computedAt: Date(), likedFingerprint: Self.likedFingerprint(weights),
                      scores: scores, ranked: ranked.map(\.key), twins: twins.count)
    }
}
