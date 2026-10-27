import Foundation
import NaturalLanguage

/// On-device semantic similarity using Apple's Natural Language framework.
///
/// Primary model: NLContextualEmbedding (transformer model, downloaded once by iOS and run
/// with hardware acceleration, which on recent iPhones means the Neural Engine where iOS
/// decides it's best). Fallback: the built-in NLEmbedding sentence model.
///
/// Battery: every synopsis is embedded once and cached on disk, work runs at utility priority
/// off the main thread, and the model is unloaded as soon as a batch finishes.
actor SemanticEngine {
    static let shared = SemanticEngine()

    private enum Backend: String { case contextual, sentence }

    private var contextual: NLContextualEmbedding?
    private var sentence: NLEmbedding?
    private var backend: Backend?

    private var cache: [Int: [Float]] = [:]
    private var cacheLoadedFor: Backend?
    private var cacheDirty = false

    private func cacheURL(_ backend: Backend) -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("embeddings-\(backend.rawValue)-v1.json")
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

    private func release() {
        contextual?.unload()
        contextual = nil
        sentence = nil
        backend = nil
    }

    // MARK: Cache

    private func loadCache(for backend: Backend) {
        guard cacheLoadedFor != backend else { return }
        cache = [:]
        if let data = try? Data(contentsOf: cacheURL(backend)),
           let decoded = try? JSONDecoder().decode([String: [Float]].self, from: data) {
            for (key, value) in decoded { if let id = Int(key) { cache[id] = value } }
        }
        cacheLoadedFor = backend
    }

    private func saveCache() {
        guard cacheDirty, let backend = cacheLoadedFor else { return }
        // Keep the cache bounded (~4000 shows ≈ a few MB).
        if cache.count > 4000 {
            for key in cache.keys.shuffled().prefix(cache.count - 4000) { cache[key] = nil }
        }
        let encodable = Dictionary(uniqueKeysWithValues: cache.map { (String($0.key), $0.value) })
        if let data = try? JSONEncoder().encode(encodable) {
            try? data.write(to: cacheURL(backend), options: .atomic)
        }
        cacheDirty = false
    }

    // MARK: Embedding

    static func text(for media: Media) -> String {
        let title = media.title.english ?? media.title.romaji ?? media.title.userPreferred ?? ""
        let genres = (media.genres ?? []).joined(separator: ", ")
        let tags = media.visibleTags.prefix(6).map(\.name).joined(separator: ", ")
        let synopsis = String(media.plainDescription.prefix(600))
        return "\(title). \(genres). \(tags). \(synopsis)"
    }

    private func embed(_ text: String) -> [Float]? {
        switch backend {
        case .contextual:
            guard let model = contextual,
                  let result = try? model.embeddingResult(for: text, language: .english) else { return nil }
            var sum = [Double](repeating: 0, count: model.dimension)
            var count = 0
            result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
                let n = min(vector.count, sum.count)
                for i in 0..<n { sum[i] += vector[i] }
                count += 1
                return true
            }
            guard count > 0 else { return nil }
            return Self.normalized(sum.map { Float($0 / Double(count)) })
        case .sentence:
            guard let vector = sentence?.vector(for: text) else { return nil }
            return Self.normalized(vector.map(Float.init))
        case .none:
            return nil
        }
    }

    static func normalized(_ v: [Float]) -> [Float] {
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return v }
        return v.map { $0 / norm }
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        for i in 0..<a.count { dot += a[i] * b[i] }
        return dot // both are already unit length
    }

    /// Returns unit vectors for the given media, using the disk cache where possible.
    func vectors(for media: [Media]) async -> [Int: [Float]] {
        guard let backend = await prepare() else { return [:] }
        loadCache(for: backend)
        var result: [Int: [Float]] = [:]
        for (index, item) in media.enumerated() {
            if let cached = cache[item.id] {
                result[item.id] = cached
                continue
            }
            if let vector = embed(Self.text(for: item)) {
                cache[item.id] = vector
                result[item.id] = vector
                cacheDirty = true
            }
            if index % 8 == 0 { await Task.yield() }
        }
        saveCache()
        release()
        return result
    }

    var backendName: String {
        switch backend {
        case .contextual: return "Contextual embedding"
        case .sentence: return "Sentence embedding"
        case .none: return "Not loaded"
        }
    }
}
