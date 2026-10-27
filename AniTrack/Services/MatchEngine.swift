import Foundation
import Observation

/// "Match %" for any show, everywhere in the app.
///
/// Layer 1 (instant, always): similarity of the show's genres/tags to your taste profile.
///   Costs ~50 dictionary lookups per show; results are memoized per show.
/// Layer 2 (AI refinement): if the show's synopsis has been embedded on-device (by For You,
///   by the charging-time pre-analysis, or by a scroll-stop batch), its semantic similarity to
///   your taste vector is blended in. Unseen shows are queued and analyzed in one small
///   low-priority batch after scrolling stops, never while you scroll.
/// Everything is rebuilt lazily when your list changes, so percentages follow your taste.
@Observable
@MainActor
final class MatchEngine {
    /// Bumped whenever percentages change, so badges redraw. Badges read only this + the memo.
    private(set) var version = 0

    @ObservationIgnored private var entries: [ListEntry] = []
    @ObservationIgnored private var dirty = true
    @ObservationIgnored private var profile = Recommender.TasteProfile()
    @ObservationIgnored private var weights: [Int: Double] = [:]
    @ObservationIgnored private var tagScale: (lo: Double, hi: Double) = (0, 1)
    @ObservationIgnored private var memo: [Int: Int] = [:]

    // AI layer
    @ObservationIgnored private var tasteVector: [Float]?
    @ObservationIgnored private var tasteRaw: [Float] = []           // before normalizing (for leave-one-out)
    @ObservationIgnored private var anchorWeights: [Int: Float] = [:] // shows that built the taste vector
    @ObservationIgnored private var semScale: (lo: Float, hi: Float) = (0, 1)
    @ObservationIgnored private var semantic: [Int: Float] = [:]     // normalized 0...1
    @ObservationIgnored private var pending: [Int: Media] = [:]
    @ObservationIgnored private var batchTask: Task<Void, Never>?
    @ObservationIgnored private var tasteTask: Task<Void, Never>?
    @ObservationIgnored var aiEnabled: () -> Bool = { true }

    /// Called by AppModel whenever the list changes (cheap: just marks the profile stale).
    func update(entries: [ListEntry]) {
        self.entries = entries
        dirty = true
        memo.removeAll(keepingCapacity: true)
        version &+= 1
    }

    // MARK: Profile

    private func rebuildIfNeeded() {
        guard dirty else { return }
        dirty = false
        let scored = entries.map(\.scoreValue).filter { $0 > 0 }
        let mean = scored.isEmpty ? 70 : scored.reduce(0, +) / Double(scored.count)
        let variance = scored.isEmpty ? 0 : scored.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(scored.count)
        let spread = sqrt(variance)

        var newProfile = Recommender.TasteProfile()
        var newWeights: [Int: Double] = [:]
        for e in entries {
            let w = Recommender.weight(for: e, mean: mean, spread: spread)
            newWeights[e.mediaId] = w
            if w != 0 { newProfile.add(e.media, weight: w) }
        }
        newProfile.finalize()
        profile = newProfile
        weights = newWeights

        // Calibrate: your well-liked shows define "very high match", the spread of your list "low".
        // Each list show is compared with the rest of your list (leave-one-out), never with itself.
        let loo: (ListEntry) -> Double = { newProfile.similarity(to: $0.media, excludingWeight: newWeights[$0.mediaId] ?? 0) }
        let liked = entries.filter { (newWeights[$0.mediaId] ?? 0) > 0.5 }.map(loo).sorted()
        let all = entries.filter { $0.status != .PLANNING }.map(loo).sorted()
        let hi = liked.isEmpty ? 0.6 : liked[min(liked.count - 1, Int(Double(liked.count) * 0.75))]
        let lo = all.isEmpty ? 0.0 : min(all[Int(Double(all.count - 1) * 0.1)], hi * 0.4)
        tagScale = (lo, max(hi, lo + 0.05))

        // The AI layer depends on the profile too: refresh it in the background.
        semantic.removeAll()
        tasteVector = nil
        refreshTasteVector()
    }

    // MARK: Public

    /// Match % for any show, including ones you've finished or rated (those are matched against
    /// the rest of your list, so a show can't match itself). nil only while your list is empty.
    func match(for media: Media) -> Int? {
        _ = version   // observe changes
        rebuildIfNeeded()
        guard profile.norm > 0 else { return nil }
        if let cached = memo[media.id] { return cached }

        let raw = profile.similarity(to: media, excludingWeight: weights[media.id] ?? 0)
        var value = max(0, min(1, (raw - tagScale.lo) / (tagScale.hi - tagScale.lo)))
        if let sem = semantic[media.id] {
            value = 0.55 * value + 0.45 * Double(sem)
        } else if aiEnabled() {
            queueForAI(media)
        }
        let percent = Int((50 + 49 * value).rounded())
        memo[media.id] = percent
        return percent
    }

    // MARK: AI layer

    private func refreshTasteVector() {
        tasteTask?.cancel()
        guard aiEnabled() else { return }
        let anchors = entries
            .filter { abs(weights[$0.mediaId] ?? 0) >= 0.4 }
            .sorted { abs(weights[$0.mediaId] ?? 0) > abs(weights[$1.mediaId] ?? 0) }
            .prefix(40)
            .map(\.media)
        guard !anchors.isEmpty else { return }
        let w = weights
        let reference = entries.filter { $0.status != .PLANNING }.prefix(150).map(\.media)
        tasteTask = Task { [weak self] in
            let vectors = await Task.detached(priority: .utility) {
                await SemanticEngine.shared.vectors(for: Array(anchors))
            }.value
            guard !Task.isCancelled else { return }
            var taste: [Float] = []
            for media in anchors {
                guard let v = vectors[media.id] else { continue }
                if taste.isEmpty { taste = [Float](repeating: 0, count: v.count) }
                SemanticEngine.accumulate(v, scale: Float(w[media.id] ?? 0), into: &taste)
            }
            guard !taste.isEmpty else { return }
            let raw = taste
            var anchorW: [Int: Float] = [:]
            for media in anchors where vectors[media.id] != nil { anchorW[media.id] = Float(w[media.id] ?? 0) }
            taste = SemanticEngine.normalized(taste)
            // Calibrate on whatever part of your list is already embedded (no extra model work),
            // each show compared with the taste of the *rest* of your list.
            let refVectors = await SemanticEngine.shared.cachedVectors(for: reference.map(\.id))
            let sims = refVectors.compactMap { id, v -> Float? in
                guard v.count == raw.count else { return nil }
                return MatchEngine.leaveOneOutCosine(raw: raw, vector: v, weight: anchorW[id] ?? 0)
            }.sorted()
            guard let self, !Task.isCancelled else { return }
            self.tasteRaw = raw
            self.anchorWeights = anchorW
            if sims.count >= 3 {
                self.semScale = (sims[Int(Double(sims.count - 1) * 0.1)], sims[Int(Double(sims.count - 1) * 0.9)])
            } else {
                self.semScale = (0.5, 0.95)
            }
            self.tasteVector = taste
            await self.applyCached(ids: Array(self.memo.keys))
        }
    }

    /// Uses already-embedded shows immediately (no model load).
    private func applyCached(ids: [Int]) async {
        guard let taste = tasteVector, !ids.isEmpty else { return }
        let vectors = await SemanticEngine.shared.cachedVectors(for: ids)
        apply(vectors, taste: taste)
        // Covers that were queued before the taste vector was ready get analyzed now.
        if !pending.isEmpty { scheduleBatch() }
    }

    private func apply(_ vectors: [Int: [Float]], taste: [Float]) {
        guard !vectors.isEmpty else { return }
        let span = max(semScale.hi - semScale.lo, 0.0001)
        var changed = false
        for (id, v) in vectors where v.count == taste.count {
            let cosine = anchorWeights[id].map { Self.leaveOneOutCosine(raw: tasteRaw, vector: v, weight: $0) }
                ?? SemanticEngine.cosine(taste, v)
            semantic[id] = max(0, min(1, (cosine - semScale.lo) / span))
            memo[id] = nil
            pending[id] = nil
            changed = true
        }
        if changed { version &+= 1 }
    }

    /// Cosine between a unit vector and the taste vector with that show's own share removed.
    nonisolated static func leaveOneOutCosine(raw: [Float], vector v: [Float], weight w: Float) -> Float {
        let rv = SemanticEngine.cosine(raw, v)                  // dot product (v is unit length)
        let rr = SemanticEngine.cosine(raw, raw)                // |raw|²
        let normSq = rr - 2 * w * rv + w * w
        guard normSq > 1e-9 else { return 0 }
        return (rv - w) / normSq.squareRoot()
    }

    private func queueForAI(_ media: Media) {
        guard pending[media.id] == nil else { return }
        pending[media.id] = media
        scheduleBatch()
    }

    /// Restarts the timer on every new cover: work starts only once scrolling has settled.
    private func scheduleBatch() {
        batchTask?.cancel()
        batchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            await self?.runBatch()
        }
    }

    private func runBatch() async {
        guard aiEnabled(), let taste = tasteVector else { return }
        let batch = Array(pending.values.prefix(30))
        guard !batch.isEmpty else { return }
        for m in batch { pending[m.id] = nil }
        let vectors = await Task.detached(priority: .utility) {
            await SemanticEngine.shared.vectors(for: batch)
        }.value
        apply(vectors, taste: taste)
        // More covers were queued meanwhile? Handle them after another quiet moment.
        if !pending.isEmpty { scheduleBatch() }
    }
}
