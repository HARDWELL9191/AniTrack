import Accelerate
import Foundation
import NaturalLanguage

/// On-device semantic similarity with Apple's Natural Language framework (same engine as AniReco).
///
/// Primary model: NLContextualEmbedding (on-device transformer, run through Core ML; iOS schedules
/// it on the Neural Engine when it can). Fallback: the built-in NLEmbedding sentence model.
///
/// - each overview is embedded once and kept in a compact append-only binary cache (Float32);
/// - vector math uses Accelerate;
/// - work runs off the main thread and yields between items;
/// - the model unloads after a short idle window;
/// - callers skip the AI pass in Low Power Mode or when the phone is hot.
actor SemanticEngine {
    static let shared = SemanticEngine()

    private enum Backend: String { case contextual, sentence }

    private var contextual: NLContextualEmbedding?
    private var sentence: NLEmbedding?
    private var backend: Backend?
    private var idleUnload: Task<Void, Never>?
    private var activeJobs = 0

    private var cache: [Int64: [Float]] = [:]
    private var cacheLoadedFor: Backend?
    private var cacheDim = 0
    private var unsaved: [Int64] = []
    private var recordsOnDisk = 0
    private static let maxCached = 6000
    private static let idleSeconds: UInt64 = 45
    private static let magic: UInt32 = 0x31464C47   // "GLF1"

    /// A piece of text to embed, identified by a stable key (Jellyfin item id + a content hash,
    /// so an edited overview is re-analysed).
    struct Input: Sendable {
        let key: String
        let text: String
    }

    static var shouldRunNow: Bool {
        let info = ProcessInfo.processInfo
        if info.isLowPowerModeEnabled { return false }
        switch info.thermalState {
        case .serious, .critical: return false
        default: return true
        }
    }

    /// Stable 64-bit FNV-1a (Swift's Hasher is seeded per launch, so it can't key a disk cache).
    static func stableKey(_ string: String) -> Int64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return Int64(bitPattern: hash)
    }

    private func cacheURL(_ backend: Backend) -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("jellyreco-embeddings-\(backend.rawValue)-v1.bin")
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
                    // Assets present but load failed: fall back below.
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
        guard activeJobs == 0 else { return }
        contextual?.unload()
        contextual = nil
        sentence = nil
        backend = nil
    }

    // MARK: Append-only cache ("GLF1" | Int32 dim | records: Int64 key + dim × Float32)

    private func loadCacheIfPresent() {
        guard cacheLoadedFor == nil else { return }
        for b in [Backend.contextual, .sentence] where FileManager.default.fileExists(atPath: cacheURL(b).path) {
            loadCache(for: b)
            return
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
            guard dim > 0 else { return }
            let stride = 8 + dim * 4
            cacheDim = dim
            var offset = 8
            while offset + stride <= raw.count {
                let id = raw.loadUnaligned(fromByteOffset: offset, as: Int64.self)
                var vector = [Float](repeating: 0, count: dim)
                vector.withUnsafeMutableBytes { dest in
                    dest.copyMemory(from: UnsafeRawBufferPointer(rebasing: raw[(offset + 8)..<(offset + stride)]))
                }
                cache[id] = vector
                recordsOnDisk += 1
                offset += stride
            }
        }
    }

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
        let exists = FileManager.default.fileExists(atPath: url.path)
        if !exists {
            data.append(header())
            recordsOnDisk = 0
        }
        for id in unsaved {
            guard let v = cache[id], v.count == cacheDim else { continue }
            append(id: id, vector: v, to: &data)
            recordsOnDisk += 1
        }
        if exists, let handle = try? FileHandle(forWritingTo: url) {
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

    private func append(id: Int64, vector: [Float], to data: inout Data) {
        withUnsafeBytes(of: id) { data.append(contentsOf: $0) }
        vector.withUnsafeBytes { data.append(contentsOf: $0) }
    }

    // MARK: Embedding

    private func embed(_ text: String) -> [Float]? {
        switch backend {
        case .contextual:
            guard let model = contextual,
                  let result = try? model.embeddingResult(for: text, language: .english) else { return nil }
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
        return vDSP.dot(a, b)
    }

    static func accumulate(_ v: [Float], scale: Float, into acc: inout [Float]) {
        guard v.count == acc.count else { return }
        acc = vDSP.add(multiplication: (a: v, b: scale), acc)
    }

    /// Already-known vectors only (never loads the model).
    func cachedVectors(for keys: [String]) -> [String: [Float]] {
        loadCacheIfPresent()
        var result: [String: [Float]] = [:]
        for key in keys { if let v = cache[Self.stableKey(key)] { result[key] = v } }
        return result
    }

    /// Unit vectors for the inputs; the model loads only if something is new.
    func vectors(for inputs: [Input]) async -> [String: [Float]] {
        loadCacheIfPresent()
        var result: [String: [Float]] = [:]
        var missing: [Input] = []
        for item in inputs {
            if let cached = cache[Self.stableKey(item.key)] { result[item.key] = cached } else { missing.append(item) }
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
            for item in inputs {
                if let cached = cache[Self.stableKey(item.key)] { result[item.key] = cached } else { missing.append(item) }
            }
        }
        for (index, item) in missing.enumerated() {
            if Task.isCancelled { break }
            let key = Self.stableKey(item.key)
            if let hit = cache[key] { result[item.key] = hit; continue }
            if let vector = embed(item.text) {
                cache[key] = vector
                result[item.key] = vector
                unsaved.append(key)
            }
            if index % 8 == 7 { await Task.yield() }
        }
        saveCache()
        return result
    }

    func clear() {
        cache = [:]
        unsaved = []
        recordsOnDisk = 0
        for b in [Backend.contextual, .sentence] { try? FileManager.default.removeItem(at: cacheURL(b)) }
        cacheLoadedFor = nil
    }
}
