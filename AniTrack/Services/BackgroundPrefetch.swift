import BackgroundTasks
import Foundation

/// Charging-time pre-analysis. iOS runs this only while the iPhone is on external power and
/// idle (typically overnight). It embeds synopses of shows you're likely to see (your list, your
/// picks, this season's trending and popular shows, and fan recommendations for your favorites)
/// so match badges and For You already have full AI accuracy during the day.
///
/// Kept deliberately light: at most `maxNewPerRun` new shows per charge, in small chunks at
/// background priority, stopping immediately if iOS asks, the phone gets hot, or power is unplugged.
enum BackgroundPrefetch {
    static let identifier = "com.tim.anitrack.prefetch"
    private static let maxNewPerRun = 250
    private static let chunkSize = 25

    /// Call once, before the app finishes launching.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let task = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(task)
        }
    }

    /// Ask iOS for the next charging window (at most every few hours).
    static func schedule() {
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = true
        request.earliestBeginDate = Date(timeIntervalSinceNow: 3 * 3600)
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handle(_ task: BGProcessingTask) {
        schedule()   // keep the cycle going
        let work = Task.detached(priority: .background) {
            await run()
        }
        task.expirationHandler = { work.cancel() }
        Task.detached(priority: .background) {
            let ok = await work.value
            task.setTaskCompleted(success: ok)
        }
    }

    private static func shouldContinue() -> Bool {
        if Task.isCancelled { return false }
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical: return false
        default: return true
        }
    }

    /// Returns true when it finished normally.
    @discardableResult
    static func run() async -> Bool {
        guard UserDefaults.standard.object(forKey: "useOnDeviceAI") as? Bool ?? true else { return true }
        guard let viewer = DiskCache.load(Viewer.self, name: "viewer") else { return true }

        let client = AniListClient()
        client.token = Keychain.get("anilistToken")

        // 1) What you already have locally (no network).
        let entries = DiskCache.load([ListEntry].self, name: "list-\(viewer.id)") ?? []
        let feed = DiskCache.load(RecommendationResult.self, name: "feed3-any-\(viewer.id)")
        var pool: [Int: Media] = [:]
        for e in entries { pool[e.mediaId] = e.media }
        for p in feed?.picks ?? [] { pool[p.media.id] = p.media }

        // 2) A few cheap requests for shows you're likely to browse soon.
        let season = currentSeason()
        let browses: [[String: Any]] = [
            ["page": 1, "perPage": 50, "sort": ["TRENDING_DESC"], "season": season.0, "seasonYear": season.1, "isAdult": false],
            ["page": 1, "perPage": 50, "sort": ["TRENDING_DESC", "POPULARITY_DESC"], "isAdult": false],
            ["page": 1, "perPage": 50, "sort": ["POPULARITY_DESC"], "isAdult": false]
        ]
        for vars in browses {
            guard shouldContinue() else { return false }
            if let data = try? await client.run(Queries.browse, variables: vars, as: PageData.self) {
                for m in data.page.media { pool[m.id] = m }
            }
            try? await Task.sleep(nanoseconds: 700_000_000)
        }
        let favorites = entries
            .filter { $0.status != .DROPPED && $0.status != .PAUSED && ($0.scoreValue >= 70 || $0.scoreValue == 0) }
            .sorted { $0.scoreValue > $1.scoreValue }
            .prefix(12)
            .map(\.mediaId)
        if !favorites.isEmpty, shouldContinue(),
           let data = try? await client.run(Queries.seedRecommendations,
                                            variables: ["ids": Array(favorites), "perPage": favorites.count,
                                                        "recsPage": 1, "recsPerMedia": 8],
                                            as: SeedPageData.self) {
            for seed in data.page.media {
                for node in seed.recommendations?.nodes ?? [] {
                    if let m = node.mediaRecommendation { pool[m.id] = m }
                }
            }
        }

        // 3) Embed only what's new, capped per charge, in small chunks.
        let known = await SemanticEngine.shared.cachedVectors(for: Array(pool.keys))
        let missing = pool.values
            .filter { known[$0.id] == nil && $0.isAdult != true }
            .sorted { ($0.popularity ?? 0) > ($1.popularity ?? 0) }
            .prefix(maxNewPerRun)
        var index = missing.startIndex
        while index < missing.endIndex {
            guard shouldContinue() else { return false }
            let end = missing.index(index, offsetBy: chunkSize, limitedBy: missing.endIndex) ?? missing.endIndex
            _ = await SemanticEngine.shared.vectors(for: Array(missing[index..<end]))
            index = end
            try? await Task.sleep(nanoseconds: 200_000_000)   // breathe between chunks
        }
        return true
    }

    private static func currentSeason() -> (String, Int) {
        let cal = Calendar(identifier: .gregorian)
        let month = cal.component(.month, from: Date())
        let year = cal.component(.year, from: Date())
        return (["WINTER", "SPRING", "SUMMER", "FALL"][(month - 1) / 3], year)
    }
}
