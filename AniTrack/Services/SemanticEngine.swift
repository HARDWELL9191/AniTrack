import Accelerate
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
/// - the cache file is append-only: a batch writes only its new vectors (a few KB) and the
///   file is compacted only occasionally, instead of rewriting megabytes every time;
/// - vector math (pooling, normalizing, dot products) uses Accelerate's SIMD routines;
/// - work runs off the main thread at utility priority and yields between items;
/// - the model stays loaded for a short idle window so back-to-back rounds don't reload it,
///   and is unloaded only when no job is using it;
/// - callers skip the AI pass entirely in Low Power Mode or when the phone is hot.
actor SemanticEngine {
    static let shared = SemanticEngine()

    private enum Backend: String { case contextual, sentence }

    private var contextual: NLContextualEmbedding?
    private var sentence: NLEmbedding?
    private var backend: Backend?
    private var idleUnload: Task<Void, Never>?
    /// Jobs currently inside `vectors(for:)`; the model is never unloaded while this is > 0.
    private var activeJobs = 0

    private var cache: [Int: [Float]] = [:]
    private var cacheLoadedFor: Backend?
    private var cacheDim = 0
    private var unsaved: [Int] = []          // ids embedded since the last append
    private var recordsOnDisk = 0            // includes superseded duplicates until compaction
    private static let maxCached = 4000
    private static let idleSeconds: UInt64 = 45
    private static let magic: UInt32 = 0x33455441   // "ATE3"

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
        return dir.appendingPathComponent("embeddings-\(backend.rawValue)-v3.bin")
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
            await self?.unloadIfIdle()
        }
    }

    private func unloadIfIdle() {
        guard activeJobs == 0 else { return }   // someone is still embedding: try again later
        contextual?.unload()
        contextual = nil
        sentence = nil
        backend = nil
    }

    // MARK: Append-only binary cache  ("ATE3" | Int32 dim | records: Int64 id + dim × Float32)

    private func loadCacheIfPresent() {
        guard cacheLoadedFor == nil else { return }
        removeOldCacheFormats()
        for b in [Backend.contextual, .sentence] where FileManager.default.fileExists(atPath: cacheURL(b).path) {
            loadCache(for: b)
            return
        }
    }

    /// One-time cleanup of caches written by older app versions (re-embedded lazily as needed).
    private func removeOldCacheFormats() {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        for b in ["contextual", "sentence"] {
            for old in ["embeddings-\(b)-v1.json", "embeddings-\(b)-v2.bin"] {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(old))
            }
        }
    }

    private func loadCache(for backend: Backend) {
        guard cacheLoadedFor != backend else { return }
        cache = [:]
        cacheDim = 0
        recordsOnDisk = 0
        unsaved = []
        cacheLoadedFor = backend
        guard let data = try? Data(contentsOf: cacheURL(backend), options: .mappedIfSafe), data.count >= 8 else { return }
        data.withUnsafeBytes { raw in
            guard raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self) == Self.magic else { return }
            let dim = Int(raw.loadUnaligned(fromByteOffset: 4, as: Int32.self))
            let stride = 8 + dim * 4
            guard dim > 0 else { return }
            cacheDim = dim
            var offset = 8
            while offset + stride <= raw.count {
                let id = Int(raw.loadUnaligned(fromByteOffset: offset, as: Int64.self))
                var vector = [Float](repeating: 0, count: dim)
                vector.withUnsafeMutableBytes { dest in
                    dest.copyMemory(from: UnsafeRawBufferPointer(rebasing: raw[(offset + 8)..<(offset + stride)]))
                }
                cache[id] = vector          // later records win
                recordsOnDisk += 1
                offset += stride
            }
        }
    }

    /// Appends only new vectors; compacts the file when it's mostly duplicates or too big.
    private func saveCache() {
        guard let backend = cacheLoadedFor, !unsaved.isEmpty else { return }
        if cacheDim == 0 { cacheDim = cache[unsaved[0]]?.count ?? 0 }
        guard cacheDim > 0 else { return }
        let url = cacheURL(backend)

        if cache.count > Self.maxCached {
            for key in cache.keys.shuffled().prefix(cache.count - Self.maxCached) { cache[key] = nil }
            compact(to: url)
            return
        }
        if recordsOnDisk > 0 && recordsOnDisk + unsaved.count > cache.count * 3 / 2 + 50 {
            compact(to: url)
            return
        }

        var data = Data()
        if !FileManager.default.fileExists(atPath: url.path) {
            data.append(header())
            recordsOnDisk = 0
        }
        for id in unsaved {
            guard let v = cache[id], v.count == cacheDim else { continue }
            append(id: id, vector: v, to: &data)
            recordsOnDisk += 1
        }
        if FileManager.default.fileExists(atPath: url.path), let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
        unsaved = []
    }

    private func compact(to url: URL) {
        var data = header()
        var written = 0
        for (id, v) in cache where v.count == cacheDim {
            append(id: id, vector: v, to: &data)
            written += 1
        }
        try? data.write(to: url, options: .atomic)
        recordsOnDisk = written
        unsaved = []
    }

    private func header() -> Data {
        var data = Data()
        withUnsafeBytes(of: Self.magic) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: Int32(cacheDim)) { data.append(contentsOf: $0) }
        return data
    }

    private func append(id: Int, vector: [Float], to data: inout Data) {
        withUnsafeBytes(of: Int64(id)) { data.append(contentsOf: $0) }
        vector.withUnsafeBytes { data.append(contentsOf: $0) }
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
            // Sum the token vectors with SIMD adds (mean pooling: the direction is the same after normalizing).
            var sum = [Double](repeating: 0, count: model.dimension)
            var count = 0
            result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
                if vector.count == sum.count { sum = vDSP.add(sum, vector) }
                count += 1
                return true
            }
            guard count > 0 else { return nil }
            return Self.normalized(vDSP.doubleToFloat(sum))
        case .sentence:
            guard let vector = sentence?.vector(for: text) else { return nil }
            return Self.normalized(vDSP.doubleToFloat(vector))
        case .none:
            return nil
        }
    }

    static func normalized(_ v: [Float]) -> [Float] {
        guard !v.isEmpty else { return v }
        let norm = vDSP.sumOfSquares(v).squareRoot()
        guard norm > 0 else { return v }
        return vDSP.divide(v, norm)
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        return vDSP.dot(a, b)   // both are already unit length
    }

    /// Adds `scale * v` into `into` (used to build the taste vector).
    static func accumulate(_ v: [Float], scale: Float, into acc: inout [Float]) {
        guard v.count == acc.count else { return }
        acc = vDSP.add(multiplication: (a: v, b: scale), acc)
    }

    /// Vectors that are already known, without ever loading the model (used by match badges).
    func cachedVectors(for ids: [Int]) -> [Int: [Float]] {
        loadCacheIfPresent()
        var result: [Int: [Float]] = [:]
        for id in ids { if let v = cache[id] { result[id] = v } }
        return result
    }

    /// Returns unit vectors for the given media. Cached vectors cost nothing; the model is only
    /// loaded if at least one show hasn't been embedded before.
    func vectors(for media: [Media]) async -> [Int: [Float]] {
        loadCacheIfPresent()
        var result: [Int: [Float]] = [:]
        var missing: [Media] = []
        for item in media {
            if let cached = cache[item.id] { result[item.id] = cached } else { missing.append(item) }
        }
        guard !missing.isEmpty else { return result }

        activeJobs += 1
        defer {
            activeJobs -= 1
            scheduleUnload()
        }
        guard let backend = await prepare() else { return result }
        if cacheLoadedFor != backend {
            saveCache()
            cacheLoadedFor = nil
            loadCache(for: backend)
            result = [:]
            missing = []
            for item in media {
                if let cached = cache[item.id] { result[item.id] = cached } else { missing.append(item) }
            }
        }
        for (index, item) in missing.enumerated() {
            if Task.isCancelled { break }
            if cache[item.id] != nil { result[item.id] = cache[item.id]; continue }   // another job got it meanwhile
            if let vector = embed(Self.text(for: item)) {
                cache[item.id] = vector
                result[item.id] = vector
                unsaved.append(item.id)
            }
            if index % 8 == 7 { await Task.yield() }
        }
        saveCache()
        return result
    }
}
