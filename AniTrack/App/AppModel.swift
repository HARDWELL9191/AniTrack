import Foundation
import Observation

@Observable
@MainActor
final class AppModel {
    let client = AniListClient()
    let settings = AppSettings()
    /// Match % for every show (instant genre/tag layer + cached on-device AI layer).
    let matcher = MatchEngine()

    private(set) var mode: AccountMode = .none
    private(set) var viewer: Viewer?
    private(set) var entries: [ListEntry] = [] {
        didSet {
            entryIndex = Dictionary(entries.indices.map { (entries[$0].mediaId, $0) }, uniquingKeysWith: { a, _ in a })
            matcher.update(entries: entries)
        }
    }
    /// mediaId → position in `entries`, so every cover/badge lookup is O(1) instead of a scan.
    @ObservationIgnored private var entryIndex: [Int: Int] = [:]
    private(set) var isLoadingList = false
    private(set) var didBootstrap = false
    var errorMessage: String?

    // Recommendations ("Hoshi" picks), one feed per category ("any" = no category).
    private(set) var feeds: [String: RecommendationResult] = [:]
    private(set) var loadingFeeds: Set<String> = []
    private(set) var loadingMore: Set<String> = []
    var recommendationError: String?

    // Categories (AniList genres + tags), loaded once and cached.
    private(set) var allCategories: [AnimeCategory] = []

    // Lets Home jump to another tab.
    var selectedTab: AppTab = .home

    /// When set, a quick "how did you like it?" sheet appears (scores sharpen picks the most).
    var ratePrompt: Media?

    private let defaults = UserDefaults.standard
    private static let tokenKey = "anilistToken"

    var canEdit: Bool { mode == .loggedIn }

    init() {
        let settings = self.settings
        matcher.aiEnabled = { settings.useOnDeviceAI && SemanticEngine.shouldRunNow }
    }

    // MARK: - Lifecycle

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        if let token = Keychain.get(Self.tokenKey), !token.isEmpty {
            client.token = token
            mode = .loggedIn
        } else if let name = defaults.string(forKey: "readOnlyUsername"), !name.isEmpty {
            mode = .username(name)
        }
        if mode != .none { await reloadAll() }
    }

    func reloadAll() async {
        await loadViewer()
        await loadCachedList()
        await refreshList()
    }

    // MARK: - Auth

    func handleAuthCallback(_ url: URL) {
        guard let token = AniListAuth.token(from: url) else {
            errorMessage = "Login failed: AniList didn't return an access token."
            return
        }
        Task { await useToken(token) }
    }

    func useToken(_ token: String) async {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Keychain.set(trimmed, for: Self.tokenKey)
        defaults.removeObject(forKey: "readOnlyUsername")
        client.token = trimmed
        mode = .loggedIn
        feeds = [:]
        await reloadAll()
    }

    func useUsername(_ name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        defaults.set(trimmed, forKey: "readOnlyUsername")
        mode = .username(trimmed)
        feeds = [:]
        await reloadAll()
        if viewer == nil {
            // Username not found or private profile: go back to welcome screen.
            defaults.removeObject(forKey: "readOnlyUsername")
            mode = .none
        }
    }

    func logOut() {
        Keychain.set(nil, for: Self.tokenKey)
        defaults.removeObject(forKey: "readOnlyUsername")
        client.token = nil
        mode = .none
        viewer = nil
        entries = []
        feeds = [:]
        DiskCache.clearAll()
    }

    // MARK: - Loading

    func loadViewer() async {
        do {
            switch mode {
            case .loggedIn:
                viewer = try await client.run(Queries.viewer, as: ViewerData.self).viewer
            case .username(let name):
                viewer = try await client.run(Queries.userByName, variables: ["name": name], as: UserData.self).user
            case .none:
                viewer = nil
            }
            if let viewer { DiskCache.save(viewer, name: "viewer") }
            if let lang = viewer?.options?.titleLanguage, defaults.object(forKey: "titleLanguage") == nil {
                if lang.hasPrefix("ENGLISH") { settings.titleLanguage = .english }
                else if lang.hasPrefix("NATIVE") { settings.titleLanguage = .native }
                else { settings.titleLanguage = .romaji }
            }
        } catch {
            if case .loggedIn = mode, isAuthError(error) {
                errorMessage = "Your AniList login expired. Please log in again."
                logOut()
            } else {
                // Offline: fall back to the last known profile so the cached list still shows.
                if viewer == nil { viewer = DiskCache.load(Viewer.self, name: "viewer") }
                errorMessage = error.localizedDescription
            }
        }
    }

    func refreshList() async {
        guard let userId = viewer?.id else { return }
        isLoadingList = true
        defer { isLoadingList = false }
        do {
            let data = try await client.run(Queries.listCollection,
                                            variables: ["userId": userId],
                                            as: CollectionData.self)
            var seen = Set<Int>()
            var result: [ListEntry] = []
            for group in data.collection?.lists ?? [] where group.isCustomList != true {
                for entry in group.entries ?? [] where !seen.contains(entry.id) {
                    seen.insert(entry.id)
                    result.append(entry)
                }
            }
            entries = result
            DiskCache.saveInBackground(result, name: cacheName("list"))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Shows the last saved list instantly (and offline) while the network refresh runs.
    private func loadCachedList() async {
        guard entries.isEmpty, viewer != nil,
              let cached = await DiskCache.loadInBackground([ListEntry].self, name: cacheName("list")),
              entries.isEmpty else { return }
        entries = cached
    }

    private func isAuthError(_ error: Error) -> Bool {
        if case APIError.http(let code) = error, code == 401 || code == 400 { return true }
        if case APIError.graphQL(let msg) = error, msg.localizedCaseInsensitiveContains("invalid token")
            || msg.localizedCaseInsensitiveContains("unauthorized") { return true }
        return false
    }

    // MARK: - Queries on the local list

    func entry(for mediaId: Int) -> ListEntry? {
        guard let index = entryIndex[mediaId], index < entries.count else { return nil }
        let entry = entries[index]   // reading `entries` keeps SwiftUI observation working
        return entry.mediaId == mediaId ? entry : entries.first { $0.mediaId == mediaId }
    }

    func entries(in statuses: [ListStatus]) -> [ListEntry] {
        entries.filter { statuses.contains($0.status) }
            .sorted { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }
    }

    func count(of status: ListStatus) -> Int {
        entries.filter { $0.status == status }.count
    }

    struct ListStats {
        var count: Int
        var episodes: Int
        var minutes: Int
        var meanScore: Double?
    }

    /// Counted from your own list, because AniList's account statistics update with a delay.
    var listStats: ListStats {
        let counted = entries.filter { $0.status != .PLANNING }
        let episodes = counted.reduce(0) { $0 + $1.progressValue }
        let minutes = counted.reduce(0) { $0 + $1.progressValue * ($1.media.duration ?? 24) }
        let scores = entries.map(\.scoreValue).filter { $0 > 0 }
        let mean = scores.isEmpty ? nil : scores.reduce(0, +) / Double(scores.count) / 10
        return ListStats(count: counted.count, episodes: episodes, minutes: minutes, meanScore: mean)
    }

    // MARK: - Editing

    @discardableResult
    func save(media: Media, status: ListStatus, progress: Int?, scoreRaw: Int?) async throws -> EntryLite {
        var vars: [String: Any] = ["mediaId": media.id, "status": status.rawValue]
        if let progress { vars["progress"] = max(0, progress) }
        if let scoreRaw { vars["scoreRaw"] = min(100, max(0, scoreRaw)) }
        let saved = try await client.run(Queries.saveEntry, variables: vars, as: SaveEntryData.self).entry

        if let index = entries.firstIndex(where: { $0.mediaId == media.id }) {
            entries[index].status = saved.status ?? status
            entries[index].progress = saved.progress
            entries[index].score = saved.score
            entries[index].updatedAt = saved.updatedAt ?? Int(Date().timeIntervalSince1970)
        } else {
            entries.append(ListEntry(id: saved.id, mediaId: media.id, status: saved.status ?? status,
                                     score: saved.score, progress: saved.progress,
                                     updatedAt: saved.updatedAt ?? Int(Date().timeIntervalSince1970),
                                     media: media))
        }
        return saved
    }

    func incrementProgress(_ entry: ListEntry) async {
        let next = entry.progressValue + 1
        var status = entry.status
        if let total = entry.media.episodes, next >= total {
            status = .COMPLETED
        } else if status == .PLANNING || status == .PAUSED {
            status = .CURRENT
        }
        do {
            try await save(media: entry.media, status: status, progress: next, scoreRaw: nil)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Marks a show as fully watched and moves it to Completed (keeps your score if you have one).
    func markCompleted(_ media: Media) async {
        let existing = entry(for: media.id)
        let progress = media.episodes ?? media.availableEpisodes ?? existing?.progress
        do {
            // scoreRaw nil = AniList keeps whatever score you already gave it.
            try await save(media: media, status: .COMPLETED, progress: progress, scoreRaw: nil)
            if (existing?.scoreValue ?? 0) == 0 { ratePrompt = media }
            // It's on your list now, so it no longer belongs in any picks feed (not a dislike).
            for key in feeds.keys { feeds[key]?.remove(media.id) }
            for (key, value) in feeds { DiskCache.saveInBackground(value, name: feedCacheName(key: key)) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(entryId: Int) async throws {
        _ = try await client.run(Queries.deleteEntry, variables: ["id": entryId], as: DeleteEntryData.self)
        entries.removeAll { $0.id == entryId }
    }

    // MARK: - Browsing

    func browse(search: String? = nil,
                sort: [String],
                season: String? = nil,
                seasonYear: Int? = nil,
                status: String? = nil,
                category: AnimeCategory? = nil,
                page: Int = 1,
                perPage: Int = 25) async throws -> [Media] {
        var vars: [String: Any] = ["page": page, "perPage": perPage, "sort": sort, "isAdult": false]
        if let search, !search.isEmpty { vars["search"] = search }
        if let category { vars.merge(category.browseVariables) { a, _ in a } }
        if let season { vars["season"] = season }
        if let seasonYear { vars["seasonYear"] = seasonYear }
        if let status { vars["status"] = status }
        let data = try await client.run(Queries.browse, variables: vars, as: PageData.self)
        return data.page.media.filter { !(settings.hideChinese && $0.countryOfOrigin == "CN") }
    }

    func detail(id: Int) async throws -> MediaDetail {
        try await client.run(Queries.detail, variables: ["id": id], as: MediaDetailData.self).media
    }

    // MARK: - Recommendations

    static func feedKey(_ category: AnimeCategory?) -> String { category?.id ?? "any" }

    private func recommendationOptions(_ category: AnimeCategory?) -> Recommender.Options {
        Recommender.Options(hideChinese: settings.hideChinese,
                            includeUnreleased: settings.includeUnreleased,
                            dismissed: settings.dismissedPicks,
                            titleLanguage: settings.titleLanguage,
                            useOnDeviceAI: settings.useOnDeviceAI,
                            category: category,
                            aiAllowedNow: SemanticEngine.shouldRunNow)
    }

    func feed(for category: AnimeCategory?) -> RecommendationResult? {
        feeds[Self.feedKey(category)]
    }

    func picks(for category: AnimeCategory?) -> [Recommendation] {
        feed(for: category)?.picks ?? []
    }

    func isLoadingFeed(_ category: AnimeCategory?) -> Bool {
        loadingFeeds.contains(Self.feedKey(category))
    }

    func isLoadingMore(_ category: AnimeCategory?) -> Bool {
        loadingMore.contains(Self.feedKey(category))
    }

    private func feedCacheName(_ category: AnimeCategory?) -> String {
        feedCacheName(key: Self.feedKey(category))
    }

    private func feedCacheName(key: String) -> String {
        let safe = key.replacingOccurrences(of: "[^A-Za-z0-9]", with: "_", options: .regularExpression)
        return cacheName("feed-\(safe)")
    }

    /// Battery-friendly: reuses saved picks unless your list changed or they're over 3 days old.
    func generateRecommendations(category: AnimeCategory? = nil, force: Bool = false) async {
        let key = Self.feedKey(category)
        guard !loadingFeeds.contains(key) else { return }
        guard !entries.isEmpty else {
            recommendationError = "Your list is empty. Add and rate a few shows first."
            return
        }
        let options = recommendationOptions(category)
        let fingerprint = Recommender.fingerprint(entries: entries, options: options)
        if !force {
            if feeds[key] == nil {
                feeds[key] = await DiskCache.loadInBackground(RecommendationResult.self, name: feedCacheName(category))
            }
            if let current = feeds[key],
               current.fingerprint == fingerprint,
               Date().timeIntervalSince(current.generatedAt) < 3 * 86_400,
               !current.picks.isEmpty {
                return
            }
        }
        loadingFeeds.insert(key)
        recommendationError = nil
        let picks: [Recommendation]
        do {
            let (found, usedAI) = try await Recommender.run(entries: entries, client: client, options: options)
            picks = found
            let result = RecommendationResult(picks: found, generatedAt: Date(), fingerprint: fingerprint,
                                              usedOnDeviceAI: usedAI, round: 1, exhausted: false)
            feeds[key] = result
            DiskCache.saveInBackground(result, name: feedCacheName(category))
        } catch {
            loadingFeeds.remove(key)
            recommendationError = error.localizedDescription
            return
        }
        loadingFeeds.remove(key)
        // A thin first round (small list or narrow category): top it up right away.
        if picks.count < 10 { await loadMorePicks(category: category) }
    }

    /// Called when you get near the end of the feed: digs one round deeper and appends.
    func loadMorePicks(category: AnimeCategory? = nil) async {
        let key = Self.feedKey(category)
        guard var current = feeds[key], !current.exhausted,
              !loadingMore.contains(key), !loadingFeeds.contains(key) else { return }
        loadingMore.insert(key)
        defer { loadingMore.remove(key) }

        let options = recommendationOptions(category)
        var shown = Set(current.picks.map(\.id))
        var emptyRounds = 0
        // Try up to 3 deeper rounds to find something new before calling it the end.
        while emptyRounds < 3 {
            let round = current.round + 1
            current.round = round
            do {
                let (more, usedAI) = try await Recommender.run(entries: entries, client: client, options: options,
                                                               round: round, exclude: shown)
                let fresh = more.filter { !shown.contains($0.id) }
                if fresh.isEmpty {
                    emptyRounds += 1
                    continue
                }
                current.picks += fresh
                current.usedOnDeviceAI = current.usedOnDeviceAI || usedAI
                shown.formUnion(fresh.map(\.id))
                break
            } catch {
                recommendationError = error.localizedDescription
                feeds[key] = current
                return
            }
        }
        if emptyRounds >= 3 { current.exhausted = true }
        feeds[key] = current
        DiskCache.saveInBackground(current, name: feedCacheName(category))
    }

    func dismissPick(_ mediaId: Int) {
        settings.dismissedPicks.insert(mediaId)
        for key in feeds.keys {
            feeds[key]?.remove(mediaId)
        }
        for (key, value) in feeds {
            DiskCache.saveInBackground(value, name: feedCacheName(key: key))
        }
    }

    private func cacheName(_ kind: String) -> String {
        "\(kind)-\(viewer?.id ?? 0)"
    }

    func resetDismissedPicks() {
        settings.dismissedPicks = []
        feeds = [:]
    }

    // MARK: - Categories

    /// Loads AniList's genres and tags once (cached for a week). Featured chips come first.
    func loadCategories() async {
        if !allCategories.isEmpty { return }
        struct Cached: Codable { let categories: [AnimeCategory]; let savedAt: Date }
        if let cached = DiskCache.load(Cached.self, name: "categories"),
           Date().timeIntervalSince(cached.savedAt) < 7 * 86_400, !cached.categories.isEmpty {
            allCategories = cached.categories
            return
        }
        do {
            let data = try await client.run(Queries.categories, as: CategoryCollectionData.self)
            let genres = (data.genres ?? []).filter { $0 != "Hentai" }.map(AnimeCategory.genre)
            let tags = (data.tags ?? [])
                .filter { $0.isAdult != true && $0.isGeneralSpoiler != true }
                .map { AnimeCategory.tag($0.name) }
            let known = Set((genres + tags).map(\.id))
            let featured = AnimeCategory.featured.filter { known.contains($0.id) }
            let rest = (genres + tags)
                .filter { !featured.contains($0) }
                .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
            allCategories = featured + rest
            DiskCache.save(Cached(categories: allCategories, savedAt: Date()), name: "categories")
        } catch {
            // Offline: fall back to the built-in featured list.
            allCategories = AnimeCategory.featured
        }
    }

    /// The quick-pick chips (featured categories AniList confirmed exist).
    var featuredCategories: [AnimeCategory] {
        let featured = AnimeCategory.featured
        guard !allCategories.isEmpty else { return featured }
        let known = Set(allCategories.map(\.id))
        return featured.filter { known.contains($0.id) }
    }

    // MARK: - Seasons

    static func currentSeason(offset: Int = 0, date: Date = Date()) -> (season: String, year: Int) {
        let cal = Calendar(identifier: .gregorian)
        let month = cal.component(.month, from: date)
        var year = cal.component(.year, from: date)
        let seasons = ["WINTER", "SPRING", "SUMMER", "FALL"]
        var index = (month - 1) / 3 + offset
        while index > 3 { index -= 4; year += 1 }
        while index < 0 { index += 4; year -= 1 }
        return (seasons[index], year)
    }
}
