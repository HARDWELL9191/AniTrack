import BackgroundTasks
import Foundation

/// Two background jobs that get the app ready before you open it.
///
/// 1) Season lookups (light, also on battery): fetches the four Discover shelves and works out
///    the first season of every Season 2+ in them, saving the answers. Discover's first load then
///    has no lookups left to do. About 10 small requests, no AI. Runs in the light "background
///    refresh" slot iOS hands out on battery (~30 seconds), and again at the start of the
///    charging job.
/// 2) AI pre-analysis (charging only): embeds synopses of shows you're likely to see (your list,
///    your picks, this season's trending and popular shows, and fan recommendations for your
///    favorites) so match badges and For You already have full AI accuracy during the day.
///
/// Kept deliberately light: at most `maxNewPerRun` new shows per charge, in small chunks at
/// background priority, stopping immediately if iOS asks, the phone gets hot, or power is unplugged.
enum BackgroundPrefetch {
    static let identifier = "com.tim.anireco.prefetch"
    static let seasonsIdentifier = "com.tim.anireco.seasons"
    private static let maxNewPerRun = 250
    private static let chunkSize = 25
    /// Season lookups at most this often (both jobs share it, so they never repeat each other).
    private static let lookupInterval: TimeInterval = 4 * 3600
    private static let lookupKey = "seasonLookupAt"

    /// Call once, before the app finishes launching.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let task = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(task)
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: seasonsIdentifier, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handleSeasons(task)
        }
    }

    /// Ask iOS for the next charging window and the next light refresh (at most every few hours).
    static func schedule() {
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = true
        request.earliestBeginDate = Date(timeIntervalSinceNow: 3 * 3600)
        try? BGTaskScheduler.shared.submit(request)
        scheduleSeasons()
    }

    private static func scheduleSeasons() {
        let request = BGAppRefreshTaskRequest(identifier: seasonsIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: lookupInterval)
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

    private static func handleSeasons(_ task: BGAppRefreshTask) {
        scheduleSeasons()   // keep the cycle going
        let work = Task.detached(priority: .background) {
            await lookUpSeasons()
        }
        task.expirationHandler = { work.cancel() }
        Task.detached(priority: .background) {
            let ok = await work.value
            task.setTaskCompleted(success: ok)
        }
    }

    /// Discover's four shelves, fetched the way Discover fetches them, and the first season of
    /// every later season in them looked up and saved. Answers already saved cost nothing; only
    /// complete answers are saved, so anything cut short is simply redone next time.
    @discardableResult
    static func lookUpSeasons() async -> Bool {
        let defaults = UserDefaults.standard
        if let last = defaults.object(forKey: lookupKey) as? Date,
           Date().timeIntervalSince(last) < lookupInterval { return true }
        let client = AniListClient()   // public data: no account needed
        let current = currentSeason()
        let upcoming = currentSeason(offset: 1)
        let shelves: [[String: Any]] = [
            ["sort": ["TRENDING_DESC", "POPULARITY_DESC"]],
            ["sort": ["POPULARITY_DESC"], "season": current.0, "seasonYear": current.1],
            ["sort": ["POPULARITY_DESC"], "season": upcoming.0, "seasonYear": upcoming.1],
            ["sort": ["SCORE_DESC"]]
        ]
        var known: [Int: Media] = [:]
        var fetchedAll = true
        for shelf in shelves {
            guard shouldContinue() else { return false }
            var vars: [String: Any] = ["page": 1, "perPage": 25, "isAdult": false, "formatNot": ["MOVIE"]]
            vars.merge(shelf) { _, new in new }
            if let data = try? await client.run(Queries.browseWithRelations, variables: vars,
                                                as: PageData.self, waitOnRateLimit: false) {
                for m in data.page.media { known[m.id] = m }
            } else {
                fetchedAll = false
            }
        }
        guard shouldContinue() else { return false }
        let later = known.values.filter(\.isLaterSeason)
        var complete = true
        if !later.isEmpty {
            let found = await SeasonRoots.resolve(Array(later), known: known, client: client, waitOnRateLimit: false)
            complete = later.allSatisfy { found[$0.id]?.complete == true }
        }
        await SeasonCache.shared.flush()
        if fetchedAll && complete && !Task.isCancelled { defaults.set(Date(), forKey: lookupKey) }
        return !Task.isCancelled
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
        // Season lookups first (cheap), then the AI part.
        guard await lookUpSeasons() else { return false }
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
            ["page": 1, "perPage": 50, "sort": ["TRENDING_DESC"], "season": season.0, "seasonYear": season.1, "isAdult": false, "formatNot": ["MOVIE"]],
            ["page": 1, "perPage": 50, "sort": ["TRENDING_DESC", "POPULARITY_DESC"], "isAdult": false, "formatNot": ["MOVIE"]],
            ["page": 1, "perPage": 50, "sort": ["POPULARITY_DESC"], "isAdult": false, "formatNot": ["MOVIE"]]
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

        // 3) Embed only what's new, capped per charge, in small chunks. Movies only when they're
        //    on your list (they shape your taste); elsewhere the app doesn't suggest them.
        let listIds = Set(entries.map(\.mediaId))
        let known = await SemanticEngine.shared.cachedVectors(for: Array(pool.keys))
        let missing = pool.values
            .filter { known[$0.id] == nil && $0.isAdult != true && (!$0.isMovie || listIds.contains($0.id)) }
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

    private static func currentSeason(offset: Int = 0) -> (String, Int) {
        let cal = Calendar(identifier: .gregorian)
        let month = cal.component(.month, from: Date())
        var year = cal.component(.year, from: Date())
        var index = (month - 1) / 3 + offset
        while index > 3 { index -= 4; year += 1 }
        return (["WINTER", "SPRING", "SUMMER", "FALL"][index], year)
    }
}
