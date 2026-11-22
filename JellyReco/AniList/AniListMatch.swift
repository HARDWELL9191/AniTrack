import Foundation
import Observation

/// "Match %" for any anime (AniReco's MatchEngine): how close a show is to your AniList list.
///
/// Layer 1 (instant): similarity of the show's genres and tags to your taste profile.
/// Layer 2 (AI, when on): if the show's synopsis has been analysed on the phone, its similarity to
/// your taste vector is blended in. Unseen shows are analysed in one small batch after scrolling
/// stops. Shows you rated follow your score. Rebuilt lazily whenever your list changes.
@Observable
@MainActor
final class AniListMatchEngine {
    /// Bumped whenever percentages change, so rows redraw.
    private(set) var version = 0

    @ObservationIgnored private var entries: [ListEntry] = []
    @ObservationIgnored private var dirty = true
    @ObservationIgnored private var profile = Recommender.TasteProfile()
    @ObservationIgnored private var weights: [Int: Double] = [:]
    @ObservationIgnored private var ratings: [Int: Double] = [:]
    @ObservationIgnored private var tagScale: (lo: Double, hi: Double) = (0, 1)
    @ObservationIgnored private var memo: [Int: Int] = [:]

    @ObservationIgnored private var tasteVector: [Float]?
    @ObservationIgnored private var tasteRaw: [Float] = []
    @ObservationIgnored private var anchorWeights: [Int: Float] = [:]
    @ObservationIgnored private var semScale: (lo: Float, hi: Float) = (0, 1)
    @ObservationIgnored private var semantic: [Int: Float] = [:]
    @ObservationIgnored private var pending: [Int: Media] = [:]
    @ObservationIgnored private var batchTask: Task<Void, Never>?
    @ObservationIgnored private var tasteTask: Task<Void, Never>?
    @ObservationIgnored var aiEnabled: () -> Bool = { true }

    func update(entries: [ListEntry]) {
        self.entries = entries
        dirty = true
        memo.removeAll(keepingCapacity: true)
        version &+= 1
    }

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
        ratings = Dictionary(entries.filter { $0.scoreValue > 0 }.map { ($0.mediaId, min(1, $0.scoreValue / 100)) },
                             uniquingKeysWith: { a, _ in a })

        // Your well-liked shows define "very high match", the spread of your list "low"; each list
        // show is compared with the rest of your list, never with itself.
        let loo: (ListEntry) -> Double = { newProfile.similarity(to: $0.media, excludingWeight: newWeights[$0.mediaId] ?? 0) }
        let liked = entries.filter { (newWeights[$0.mediaId] ?? 0) > 0.5 }.map(loo).sorted()
        let all = entries.filter { $0.status != .PLANNING }.map(loo).sorted()
        let hi = liked.isEmpty ? 0.6 : liked[min(liked.count - 1, Int(Double(liked.count) * 0.75))]
        let lo = all.isEmpty ? 0.0 : min(all[Int(Double(all.count - 1) * 0.1)], hi * 0.4)
        tagScale = (lo, max(hi, lo + 0.05))

        semantic.removeAll()
        tasteVector = nil
        refreshTasteVector()
    }

    /// Match % for any show, including finished or rated ones (matched against the rest of your
    /// list). nil only while your list is empty.
    func match(for media: Media) -> Int? {
        _ = version
        rebuildIfNeeded()
        guard profile.norm > 0 else { return nil }
        if let cached = memo[media.id] { return cached }

        let raw = profile.similarity(to: media, excludingWeight: weights[media.id] ?? 0)
        var z = max(-1, min(1, (raw - tagScale.lo) / (tagScale.hi - tagScale.lo)))
        if let sem = semantic[media.id] {
            z = 0.55 * z + 0.45 * Double(sem)
        } else if aiEnabled() {
            queueForAI(media)
        }
        let percent: Int
        if let rating = ratings[media.id] {
            let predicted = max(0, min(1, z))
            percent = Int((20 + 79 * (0.95 * rating + 0.05 * predicted)).rounded())
        } else if z >= 0 {
            percent = Int((50 + 49 * min(z, 1)).rounded())
        } else {
            percent = Int((50 + 30 * z).rounded())
        }
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
        let anchorInputs = anchors.map(\.embeddingInput)
        let referenceInputs = reference.map(\.embeddingInput)
        tasteTask = Task { [weak self] in
            let byKey = await Task.detached(priority: .utility) {
                await SemanticEngine.shared.vectors(for: anchorInputs)
            }.value
            guard !Task.isCancelled else { return }
            var taste: [Float] = []
            var anchorW: [Int: Float] = [:]
            for (media, input) in zip(anchors, anchorInputs) {
                guard let v = byKey[input.key] else { continue }
                if taste.isEmpty { taste = [Float](repeating: 0, count: v.count) }
                SemanticEngine.accumulate(v, scale: Float(w[media.id] ?? 0), into: &taste)
                anchorW[media.id] = Float(w[media.id] ?? 0)
            }
            guard !taste.isEmpty else { return }
            let raw = taste
            taste = SemanticEngine.normalized(taste)
            let refByKey = await SemanticEngine.shared.cachedVectors(for: referenceInputs)
            var sims: [Float] = []
            for (media, input) in zip(reference, referenceInputs) {
                guard let v = refByKey[input.key], v.count == raw.count else { continue }
                sims.append(AniListMatchEngine.leaveOneOutCosine(raw: raw, vector: v, weight: anchorW[media.id] ?? 0))
            }
            sims.sort()
            guard let self, !Task.isCancelled else { return }
            self.tasteRaw = raw
            self.anchorWeights = anchorW
            self.semScale = sims.count >= 3 ? (sims[Int(Double(sims.count - 1) * 0.1)], sims[Int(Double(sims.count - 1) * 0.9)]) : (0.5, 0.95)
            self.tasteVector = taste
            if !self.pending.isEmpty { self.scheduleBatch() }
            // Shows already shown before the taste vector was ready: use whatever is analysed.
            let shown = self.entries.map(\.media).filter { self.memo[$0.id] != nil }
            await self.applyCached(shown)
        }
    }

    private func applyCached(_ media: [Media]) async {
        guard let taste = tasteVector, !media.isEmpty else { return }
        let inputs = media.map(\.embeddingInput)
        let byKey = await SemanticEngine.shared.cachedVectors(for: inputs)
        var vectors: [Int: [Float]] = [:]
        for (m, input) in zip(media, inputs) { if let v = byKey[input.key] { vectors[m.id] = v } }
        apply(vectors, taste: taste)
    }

    private func apply(_ vectors: [Int: [Float]], taste: [Float]) {
        guard !vectors.isEmpty else { return }
        let span = max(semScale.hi - semScale.lo, 0.0001)
        var changed = false
        for (id, v) in vectors where v.count == taste.count {
            let cosine = anchorWeights[id].map { Self.leaveOneOutCosine(raw: tasteRaw, vector: v, weight: $0) }
                ?? SemanticEngine.cosine(taste, v)
            semantic[id] = max(-1, min(1, (cosine - semScale.lo) / span))
            memo[id] = nil
            pending[id] = nil
            changed = true
        }
        if changed { version &+= 1 }
    }

    /// Cosine between a unit vector and the taste vector with that show's own share removed.
    nonisolated static func leaveOneOutCosine(raw: [Float], vector v: [Float], weight w: Float) -> Float {
        let rv = SemanticEngine.cosine(raw, v)
        let rr = SemanticEngine.cosine(raw, raw)
        let normSq = rr - 2 * w * rv + w * w
        guard normSq > 1e-9 else { return 0 }
        return (rv - w) / normSq.squareRoot()
    }

    private func queueForAI(_ media: Media) {
        guard pending[media.id] == nil else { return }
        pending[media.id] = media
        scheduleBatch()
    }

    /// Work starts only once scrolling has settled.
    private func scheduleBatch() {
        batchTask?.cancel()
        batchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            await self?.runBatch()
        }
    }

    private func runBatch() async {
        guard aiEnabled(), let taste = tasteVector else { return }
        let batch = Array(pending.values.prefix(30))
        guard !batch.isEmpty else { return }
        for m in batch { pending[m.id] = nil }
        let inputs = batch.map(\.embeddingInput)
        let byKey = await Task.detached(priority: .background) {
            await SemanticEngine.shared.vectors(for: inputs)
        }.value
        var vectors: [Int: [Float]] = [:]
        for (m, input) in zip(batch, inputs) { if let v = byKey[input.key] { vectors[m.id] = v } }
        apply(vectors, taste: taste)
        if !pending.isEmpty { scheduleBatch() }
    }
}
