import Foundation
import NaturalLanguage

/// On-device semantic similarity using Apple's Natural Language framework.
///
/// Primary model: NLContextualEmbedding, Apple's on-device transformer. iOS runs it through
/// Core ML and schedules it on the Neural Engine when it can (apps can't pin NL models to a
/// compute unit themselves). Fallback: the built-in NLEmbedding sentence model.
///
/// Efficiency:
/// - each synopsis is embedded once, then read back from a compact binary cache (Float32);
/// - work runs off the main thread at utility priority and yields between items;
/// - the model stays loaded for a short idle window so back-to-back rounds ("load more")
///   don't pay the load cost again, then it's unloaded to free memory;
/// - callers skip the AI pass entirely in Low Power Mode or when the phone is hot.
actor SemanticEngine {
    static let shared = SemanticEngine()

    private enum Backend: String { case contextual, sentence }

    private var contextual: NLContextualEmbedding?
    private var sentence: NLEmbedding?
    private var backend: Backend?
    private var idleUnload: Task<Void, Never>?

    private var cache: [Int: [Float]] = [:]
    private var cacheLoadedFor: Backend?
    private var cacheDirty = false
    private static let maxCached = 4000
    private static let idleSeconds: UInt64 = 45

    /// Whether the AI pass should run right now (battery/thermal friendly).
    static var shouldRunNow: Bool {
        let info = ProcessInfo.processInfo
        if info.isLowPowerModeEnabled { return false }
        switch info.thermalState {
        case .serious, .critical: return false
        default: return true
        }
    }

    private func cacheURL(_ backend: Backend) -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("embeddings-\(backend.rawValue)-v2.bin")
    }

    // MARK: Model lifecycle

    private func requestAssets(_ model: NLContextualEmbedding) async -> Bool {
        await withCheckedContinuation { continuation in
            model.requestAssets { result, error in
                continuation.resume(returning: error == nil && result == .available)
            }
        }
    }

    private func prepare() async -> Backend? {
        idleUnload?.cancel()
        if let backend { return backend }
        if let model = NLContextualEmbedding(language: .english) {
            var ready = model.hasAvailableAssets
            if !ready { ready = await requestAssets(model) }
            if ready {
                do {
                    try model.load()
                    contextual = model
                    backend = .contextual
                    return backend
                } catch {
                    // Known iOS issue: assets present but load fails. Fall back below.
                }
            }
        }
        if let model = NLEmbedding.sentenceEmbedding(for: .english) {
            sentence = model
            backend = .sentence
            return backend
        }
        return nil
    }

    private func scheduleUnload() {
        idleUnload?.cancel()
        idleUnload = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.idleSeconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.unloadNow()
        }
    }

    private func unloadNow() {
        contextual?.unload()
        contextual = nil
        sentence = nil
        backend = nil
    }

    // MARK: Binary cache  ("ATE2" | Int32 dim | Int32 count | count × (Int64 id, dim × Float32))

    private func loadCache(for backend: Backend) {
        guard cacheLoadedFor != backend else { return }
        cache = [:]
        cacheLoadedFor = backend
        guard let data = try? Data(contentsOf: cacheURL(backend), options: .mappedIfSafe), data.count >= 12 else { return }
        data.withUnsafeBytes { raw in
            guard raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self) == 0x32455441 else { return }  // "ATE2"
            let dim = Int(raw.loadUnaligned(fromByteOffset: 4, as: Int32.self))
            let count = Int(raw.loadUnaligned(fromByteOffset: 8, as: Int32.self))
            let stride = 8 + dim * 4
            guard dim > 0, count >= 0, data.count >= 12 + count * stride else { return }
            var offset = 12
            for _ in 0..<count {
                let id = Int(raw.loadUnaligned(fromByteOffset: offset, as: Int64.self))
                var vector = [Float](repeating: 0, count: dim)
                for i in 0..<dim {
                    vector[i] = raw.loadUnaligned(fromByteOffset: offset + 8 + i * 4, as: Float.self)
                }
                cache[id] = vector
                offset += stride
            }
        }
    }

    private func saveCache() {
        guard cacheDirty, let backend = cacheLoadedFor, let dim = cache.values.first?.count else { return }
        if cache.count > Self.maxCached {
            for key in cache.keys.shuffled().prefix(cache.count - Self.maxCached) { cache[key] = nil }
        }
        let items = cache.filter { $0.value.count == dim }
        var data = Data(capacity: 12 + items.count * (8 + dim * 4))
        func append<T>(_ value: T) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
        append(UInt32(0x32455441))
        append(Int32(dim))
        append(Int32(items.count))
        for (id, vector) in items {
            append(Int64(id))
            vector.withUnsafeBytes { data.append(contentsOf: $0) }
        }
        try? data.write(to: cacheURL(backend), options: .atomic)
        cacheDirty = false
    }

    // MARK: Embedding

    static func text(for media: Media) -> String {
        let title = media.title.english ?? media.title.romaji ?? media.title.userPreferred ?? ""
        let genres = (media.genres ?? []).joined(separator: ", ")
        let tags = media.visibleTags.prefix(6).map(\.name).joined(separator: ", ")
        // ~500 chars of synopsis keeps the input inside the model's sequence length (less work, same signal).
        let synopsis = String(media.plainDescription.prefix(500))
        return "\(title). \(genres). \(tags). \(synopsis)"
    }

    private func embed(_ text: String) -> [Float]? {
        switch backend {
        case .contextual:
            guard let model = contextual,
                  let result = try? model.embeddingResult(for: text, language: .english) else { return nil }
            var sum = [Float](repeating: 0, count: model.dimension)
            var count = 0
            result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
                let n = min(vector.count, sum.count)
                for i in 0..<n { sum[i] += Float(vector[i]) }
                count += 1
                return true
            }
            guard count > 0 else { return nil }
            return Self.normalized(sum)   // mean-pooling direction == sum direction after normalizing
        case .sentence:
            guard let vector = sentence?.vector(for: text) else { return nil }
            return Self.normalized(vector.map(Float.init))
        case .none:
            return nil
        }
    }

    static func normalized(_ v: [Float]) -> [Float] {
        var sumSquares: Float = 0
        for x in v { sumSquares += x * x }
        let norm = sumSquares.squareRoot()
        guard norm > 0 else { return v }
        return v.map { $0 / norm }
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        for i in 0..<a.count { dot += a[i] * b[i] }
        return dot // both are already unit length
    }

    /// Vectors that are already known, without ever loading the model (used by match badges).
    func cachedVectors(for ids: [Int]) -> [Int: [Float]] {
        for backend in [Backend.contextual, .sentence] where cacheLoadedFor == nil {
            if FileManager.default.fileExists(atPath: cacheURL(backend).path) { loadCache(for: backend); break }
        }
        var result: [Int: [Float]] = [:]
        for id in ids { if let v = cache[id] { result[id] = v } }
        return result
    }

    /// Returns unit vectors for the given media. Cached vectors cost nothing; the model is only
    /// loaded if at least one show hasn't been embedded before.
    func vectors(for media: [Media]) async -> [Int: [Float]] {
        // Cache-only fast path: no model load when everything is already known.
        for backend in [Backend.contextual, .sentence] where cacheLoadedFor == nil {
            if FileManager.default.fileExists(atPath: cacheURL(backend).path) { loadCache(for: backend); break }
        }
        var result: [Int: [Float]] = [:]
        var missing: [Media] = []
        for item in media {
            if let cached = cache[item.id] { result[item.id] = cached } else { missing.append(item) }
        }
        guard !missing.isEmpty else { return result }

        guard let backend = await prepare() else { return result }
        if cacheLoadedFor != backend {
            loadCache(for: backend)
            result = [:]
            missing = []
            for item in media {
                if let cached = cache[item.id] { result[item.id] = cached } else { missing.append(item) }
            }
        }
        for (index, item) in missing.enumerated() {
            if Task.isCancelled { break }
            if let vector = embed(Self.text(for: item)) {
                cache[item.id] = vector
                result[item.id] = vector
                cacheDirty = true
            }
            if index % 8 == 7 { await Task.yield() }
        }
        saveCache()
        scheduleUnload()
        return result
    }
}
