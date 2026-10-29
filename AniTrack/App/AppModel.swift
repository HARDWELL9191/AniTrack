import Foundation
import Observation
import SwiftUI

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
            franchises = ListFranchises(entries.map(\.media))
            grouping = nil   // worked out again on next use
        }
    }
    /// mediaId → position in `entries`, so every cover/badge lookup is O(1) instead of a scan.
    @ObservationIgnored private var entryIndex: [Int: Int] = [:]
    /// Shows on your list by title, so other seasons of them aren't suggested.
    @ObservationIgnored private(set) var franchises = ListFranchises()
    private(set) var isLoadingList = false
    /// True once AniList has answered for your list at least once (or failed): until then an
    /// empty list means "still loading", never "your list is empty".
    private(set) var listLoadedOnce = false
    private(set) var didBootstrap = false
    var errorMessage: String?

    // Recommendations ("Hoshi" picks), one feed per category ("any" = no category).
    private(set) var feeds: [String: RecommendationResult] = [:]
    private(set) var loadingFeeds: Set<String> = []
    private(set) var loadingMore: Set<String> = []
    /// Picks errors per feed (category), so one category's error never shows on another.
    private(set) var recommendationErrors: [String: String] = [:]

    func recommendationError(for category: AnimeCategory?) -> String? {
        recommendationErrors[Self.feedKey(category)]
    }

    // Categories (AniList genres + tags), loaded once and cached.
    private(set) var allCategories: [AnimeCategory] = []

    /// Set when pick settings change, so the next visit rebuilds instead of reusing saved picks.
    @ObservationIgnored private var forceRebuild: Set<String> = []

    // Lets Home jump to another tab.
    var selectedTab: AppTab = .home

    /// When set, a quick "how did you like it?" sheet appears (scores sharpen picks the most).
    var ratePrompt: Media?
    /// The same prompt when "Already watched" is used inside a sheet ("More like this"):
    /// shown by that sheet, since nothing can open on top of it from the main screen.
    var sheetRatePrompt: Media?
    /// "More like this" / "Why would I like this?" opened from a card's long-press menu.
    var cardSheet: CardSheet?
    /// Age ratings for covers (Kitsu), saved on the phone for good.
    let ages = AgeRatings()

    private let defaults = UserDefaults.standard
    private static let tokenKey = "anilistToken"

    var canEdit: Bool { mode == .loggedIn }

    init() {
        let settings = self.settings
        matcher.aiEnabled = { settings.useOnDeviceAI && SemanticEngine.shouldRunNow }
        // Low Power Mode off / phone cooled down: let the AI part of match % catch up.
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange,
                     ProcessInfo.thermalStateDidChangeNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if SemanticEngine.shouldRunNow { self?.aiAvailabilityChanged() }
                }
            }
        }
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
        // Your last known profile and list first: instant, offline too, and never stuck behind a
        // slow or rate-limited AniList. Fresh data replaces them as soon as it arrives.
        useCachedViewer()
        await loadCachedList()
        await loadCachedFanSignal()
        await loadViewer()
        await refreshList()
    }

    /// The saved profile, if it belongs to this account (logout clears it).
    private func useCachedViewer() {
        guard viewer == nil, let cached = DiskCache.load(Viewer.self, name: "viewer") else { return }
        switch mode {
        case .loggedIn:
            viewer = cached
        case .username(let name):
            if cached.name.caseInsensitiveCompare(name) == .orderedSame { viewer = cached }
        case .none:
            break
        }
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
        listLoadedOnce = false
        feeds = [:]
        notForMeSync?.cancel()
        notForMeSync = nil
        notForMeEntries = [:]
        pendingNotForMe = []
        notForMeListReady = false
        notForMeLoadedFor = nil
        notForMeMedia = [:]
        recommendationErrors = [:]
        forceRebuild = []
        // Builds still running for the old account must not land in the next one.
        showSyncTask?.cancel()
        showSyncTask = nil
        generationTasks.values.forEach { $0.cancel() }
        moreTasks.values.forEach { $0.cancel() }
        generationTasks = [:]
        moreTasks = [:]
        loadingFeeds = []
        loadingMore = []
        matcher.resetSignals()
        // Only your personal data: AI analysis, age ratings, categories and episode lists
        // aren't tied to an account and would just cost battery/data to rebuild.
        DiskCache.clearPersonal()
    }

    // MARK: - Loading

    func loadViewer() async {
        do {
            switch mode {
            case .loggedIn:
                viewer = try await client.run(Queries.viewer, as: ViewerData.self,
                                              waitOnRateLimit: viewer == nil).viewer
            case .username(let name):
                viewer = try await client.run(Queries.userByName, variables: ["name": name], as: UserData.self,
                                              waitOnRateLimit: viewer == nil).user
            case .none:
                viewer = nil
            }
            if let viewer {
                DiskCache.save(viewer, name: "viewer")
                useDismissedPicks(of: viewer.id)
            }
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
                // Offline: fall back to the last known profile so the cached list still shows,
                // and only bother you with an error if there's nothing to show.
                if viewer == nil { viewer = DiskCache.load(Viewer.self, name: "viewer") }
                if viewer == nil && !Self.isCancellation(error) { errorMessage = error.localizedDescription }
            }
        }
    }

    func refreshList() async {
        guard let userId = viewer?.id else { listLoadedOnce = true; return }
        isLoadingList = true
        defer {
            isLoadingList = false
            listLoadedOnce = true
        }
        do {
            let data = try await client.run(Queries.listCollection,
                                            variables: ["userId": userId],
                                            as: CollectionData.self)
            var seen = Set<Int>()
            var result: [ListEntry] = []
            var notForMe: [Int: Int] = [:]   // mediaId → entry id
            for group in data.collection?.lists ?? [] where group.isCustomList == true && group.name == Self.notForMeList {
                for entry in group.entries ?? [] {
                    notForMe[entry.mediaId] = entry.id
                    notForMeMedia[entry.mediaId] = entry.media
                }
            }
            for group in data.collection?.lists ?? [] where group.isCustomList != true {
                for entry in group.entries ?? [] where !seen.contains(entry.id) {
                    seen.insert(entry.id)
                    result.append(entry)
                }
            }
            // A "Not for me" entry should never appear in your lists or shape your taste.
            if !notForMe.isEmpty { result.removeAll { notForMe[$0.mediaId] == $0.id } }
            entries = result
            DiskCache.saveInBackground(result, name: cacheName("list"))
            if case .loggedIn = mode { mergeNotForMe(remote: notForMe) }
        } catch {
            if entries.isEmpty && !Self.isCancellation(error) { errorMessage = error.localizedDescription }
        }
    }

    /// Shows the last saved list instantly (and offline) while the network refresh runs.
    private func loadCachedList() async {
        guard entries.isEmpty, viewer != nil,
              let cached = await DiskCache.loadInBackground([ListEntry].self, name: cacheName("list")),
              entries.isEmpty else { return }
        entries = cached
    }

    /// Fan-recommendation strengths from earlier picks builds, so match % has them right away.
    private func loadCachedFanSignal() async {
        guard viewer != nil,
              let cached = await DiskCache.loadInBackground([Int: Double].self, name: cacheName("fans2")) else { return }
        matcher.addFanSignal(cached)
    }

    /// "Not for me" belongs to one account. Switching to another (e.g. a different username in
    /// read-only mode) puts the previous one's away and brings this one's back. Logged-in
    /// accounts are then brought in line with AniList's own copy on the list refresh.
    private func useDismissedPicks(of viewerId: Int) {
        let ownerKey = "dismissedPicks-owner"
        let owner = defaults.object(forKey: ownerKey) as? Int
        guard owner != viewerId else { return }
        defaults.set(viewerId, forKey: ownerKey)
        guard let owner else { return }   // first run: what's saved already belongs to this account
        defaults.set(Array(settings.dismissedPicks), forKey: "dismissedPicks-\(owner)")
        settings.dismissedPicks = Set(defaults.array(forKey: "dismissedPicks-\(viewerId)") as? [Int] ?? [])
    }

    private func isAuthError(_ error: Error) -> Bool {
        // Only a clear "not logged in" answer logs you out. A bare HTTP 400 can also be an error
        // page during an AniList outage; real expired tokens come with an "Invalid token" message.
        if case APIError.http(let code) = error, code == 401 { return true }
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

    /// Your list as shows: a later season sits under an earlier season of the same show that's
    /// in the same list (Completed S1 + S2 + S3 → one row, "+2 seasons"). A season that's alone
    /// in a list (watching S2 while S1 is completed) keeps its own row. AniList still has one
    /// entry per season; this only changes how they're shown.
    struct ShowRow: Identifiable {
        let entry: ListEntry
        /// The show's other seasons on your list, folded under this row.
        let extraSeasons: Int
        /// Their titles (so the Lists filter finds the show by any season's name).
        let foldedTitles: [MediaTitle]
        var id: Int { entry.id }
    }

    /// Your list as shows, not seasons: every later season is folded into the show's earliest
    /// season on your list, whichever list each one is in, so a show appears once, in the
    /// list of that row ("8 seasons"). AniList still keeps one entry per season.
    private struct Grouping {
        var folded: Set<Int> = []              // later seasons folded into another row
        var extra: [Int: Int] = [:]            // shown mediaId → seasons folded under it
        var titles: [Int: [MediaTitle]] = [:]
    }
    /// Worked out once per list change (Lists asks for it many times per redraw: every
    /// status count in its dropdown, the rows, Home's rows).
    @ObservationIgnored private var grouping: Grouping?

    func shows(in statuses: [ListStatus]) -> [ShowRow] {
        let wanted = Set(statuses)
        let g = grouping ?? makeGrouping()
        return entries
            .filter { wanted.contains($0.status) && !g.folded.contains($0.mediaId) }
            .map { ShowRow(entry: $0, extraSeasons: g.extra[$0.mediaId] ?? 0, foldedTitles: g.titles[$0.mediaId] ?? []) }
    }

    private func makeGrouping() -> Grouping {
        var extra: [Int: Int] = [:]
        var titles: [Int: [MediaTitle]] = [:]
        var folded: Set<Int> = []
        for e in entries where e.media.isLaterSeason {
            var current = e.media
            var visited: Set<Int> = [e.mediaId]
            var anchor: Int?
            while let previous = current.prequelId, visited.count < 15, !visited.contains(previous),
                  let earlier = entry(for: previous) {
                visited.insert(previous)
                if earlier.media.isSeason { anchor = earlier.mediaId }   // keeps going: the earliest wins
                current = earlier.media
            }
            if let anchor {
                folded.insert(e.mediaId)
                extra[anchor, default: 0] += 1
                titles[anchor, default: []].append(e.media.title)
            }
        }
        let result = Grouping(folded: folded, extra: extra, titles: titles)
        grouping = result
        return result
    }

    /// Shows (not seasons) in one list.
    func showCount(of status: ListStatus) -> Int { shows(in: [status]).count }

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
        let saved = try await writeEntry(media: media, status: status, progress: progress, scoreRaw: scoreRaw)
        var list = entries
        Self.apply(saved, media: media, status: status, to: &list)
        entries = list   // one change: one taste/match recalculation
        // Planned/added from anywhere (detail page, Home, search): it, and other seasons of
        // the same show, leave your saved picks right away.
        removeKnownFromFeeds()
        return saved
    }

    /// Sends one entry to AniList (turning a "Not for me" marker back into a normal entry).
    /// Doesn't touch your local list: callers apply the result, so several writes can land as
    /// a single change.
    private func writeEntry(media: Media, status: ListStatus, progress: Int?, scoreRaw: Int?) async throws -> EntryLite {
        detailCache[media.id] = nil   // its page would show the old status
        var vars: [String: Any] = ["mediaId": media.id, "status": status.rawValue]
        if let progress { vars["progress"] = max(0, progress) }
        if let scoreRaw { vars["scoreRaw"] = min(100, max(0, scoreRaw)) }
        ensureNotForMeLoaded()
        let wasNotForMe = notForMeEntries[media.id] != nil
        if wasNotForMe {
            // Same AniList entry: turn it back into a normal, visible one.
            vars["private"] = false
            vars["hiddenFromStatusLists"] = false
            vars["customLists"] = [String]()
        }
        let saved = try await client.run(Queries.saveEntry, variables: vars, as: SaveEntryData.self).entry
        if wasNotForMe || settings.dismissedPicks.contains(media.id) {
            notForMeEntries[media.id] = nil
            pendingNotForMe.remove(media.id)
            settings.dismissedPicks.remove(media.id)
            saveNotForMeState()
        }
        return saved
    }

    private static func apply(_ saved: EntryLite, media: Media, status: ListStatus, to list: inout [ListEntry]) {
        let now = Int(Date().timeIntervalSince1970)
        if let index = list.firstIndex(where: { $0.mediaId == media.id }) {
            var updated = list[index]
            updated.status = saved.status ?? status
            updated.progress = saved.progress
            updated.score = saved.score
            updated.updatedAt = saved.updatedAt ?? now
            list[index] = updated
        } else {
            list.append(ListEntry(id: saved.id, mediaId: media.id, status: saved.status ?? status,
                                  score: saved.score, progress: saved.progress,
                                  updatedAt: saved.updatedAt ?? now, media: media, createdAt: now))
        }
    }

    /// Removes picks that are on your list, or another season of a show on your list.
    func removeKnownFromFeeds() {
        for (key, value) in feeds {
            let known = value.picks.filter { entry(for: $0.id) != nil || franchises.contains($0.media) }.map(\.id)
            guard !known.isEmpty else { continue }
            withAnimation(.snappy) { for id in known { feeds[key]?.remove(id) } }   // next card slides in
            if let updated = feeds[key] { DiskCache.saveInBackground(updated, name: feedCacheName(key: key)) }
        }
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
    /// Returns false if AniList couldn't be updated.
    @discardableResult
    func markCompleted(_ media: Media, askRating: Bool = true, inSheet: Bool = false) async -> Bool {
        let existing = entry(for: media.id)
        let progress = media.episodes ?? media.availableEpisodes ?? existing?.progress
        do {
            // scoreRaw nil = AniList keeps whatever score you already gave it.
            try await save(media: media, status: .COMPLETED, progress: progress, scoreRaw: nil)
            if askRating && (existing?.scoreValue ?? 0) == 0 {
                if inSheet { sheetRatePrompt = media } else { ratePrompt = media }
            }
            // It's on your list now, so it no longer belongs in any picks feed (not a dislike).
            removeFromFeeds(media.id)
            updateOtherSeasons(of: media, .watched)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func delete(entryId: Int) async throws {
        if let mediaId = entries.first(where: { $0.id == entryId })?.mediaId { detailCache[mediaId] = nil }
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
                genres: [String]? = nil,
                excludeGenres: [String]? = nil,
                minScore: Int? = nil,
                maxPopularity: Int? = nil,
                minPopularity: Int? = nil,
                firstSeasonsOnly: Bool = false,
                page: Int = 1,
                perPage: Int = 25) async throws -> [Media] {
        try await browsePage(search: search, sort: sort, season: season, seasonYear: seasonYear, status: status,
                             category: category, genres: genres, excludeGenres: excludeGenres,
                             minScore: minScore, maxPopularity: maxPopularity, minPopularity: minPopularity,
                             firstSeasonsOnly: firstSeasonsOnly, page: page, perPage: perPage).media
    }

    /// Like `browse`, plus whether AniList has another page (judged before shows are hidden
    /// locally, so hiding e.g. Chinese animation never stops endless scrolling early).
    func browsePage(search: String? = nil,
                    sort: [String],
                    season: String? = nil,
                    seasonYear: Int? = nil,
                    status: String? = nil,
                    category: AnimeCategory? = nil,
                    genres: [String]? = nil,
                    excludeGenres: [String]? = nil,
                    minScore: Int? = nil,
                    maxPopularity: Int? = nil,
                    minPopularity: Int? = nil,
                    firstSeasonsOnly: Bool = false,
                    page: Int = 1,
                    perPage: Int = 25) async throws -> (media: [Media], hasNextPage: Bool) {
        let raw = try await rawPage(search: search, sort: sort, season: season, seasonYear: seasonYear,
                                    status: status, category: category, genres: genres,
                                    excludeGenres: excludeGenres, minScore: minScore,
                                    maxPopularity: maxPopularity, minPopularity: minPopularity,
                                    page: page, perPage: perPage)
        // A later season is shown as its first season (its own seasons are in the details
        // page's dropdown).
        let collapsed = await SeasonRoots.collapse(raw.media, client: client)
        let searching = !(search ?? "").isEmpty
        return (finish(collapsed, searching: searching, category: category, firstSeasonsOnly: firstSeasonsOnly),
                raw.hasNextPage)
    }

    /// One Discover shelf.
    struct ShelfSpec: Sendable {
        let sort: [String]
        var season: String? = nil
        var seasonYear: Int? = nil
    }

    /// Several shelves at once, with one shared first-season lookup: a show that's in two
    /// shelves is looked up once, and every shelf is ready at the same moment. Each result is
    /// that shelf's shows, or its error (one failing shelf never blanks the others).
    /// `waitOnRateLimit: false` for a refresh behind shelves that are already showing: if
    /// AniList is busy it gives up at once (the saved shelves stay) instead of waiting.
    func browseShelves(_ specs: [ShelfSpec], waitOnRateLimit: Bool = true) async -> [Result<[Media], Error>] {
        var raw: [Result<[Media], Error>] = Array(repeating: .success([]), count: specs.count)
        await withTaskGroup(of: (Int, Result<[Media], Error>).self) { group in
            for (index, spec) in specs.enumerated() {
                group.addTask {
                    do {
                        let page = try await self.rawPage(sort: spec.sort, season: spec.season,
                                                          seasonYear: spec.seasonYear,
                                                          waitOnRateLimit: waitOnRateLimit)
                        return (index, .success(page.media))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            for await (index, result) in group { raw[index] = result }
        }
        var known: [Int: Media] = [:]
        for result in raw { for m in (try? result.get()) ?? [] { known[m.id] = m } }
        let later = known.values.filter(\.isLaterSeason)
        var found: [Int: SeasonRoots.Found] = [:]
        if !later.isEmpty {
            found = await SeasonRoots.resolve(Array(later), known: known, client: client, waitOnRateLimit: false)
        }
        return raw.map { result in
            result.map { finish(SeasonRoots.apply($0, found: found), searching: false, category: nil, firstSeasonsOnly: false) }
        }
    }

    /// The local filters every browse result goes through.
    private func finish(_ items: [Media], searching: Bool, category: AnimeCategory?, firstSeasonsOnly: Bool) -> [Media] {
        let adultOK = category?.isAdultOnly == true
        return items.filter { media in
            if media.isAdult == true && !adultOK { return false }   // a first season fetched by id
            if media.isMovie && !searching { return false }
            if settings.hideChinese && media.countryOfOrigin == "CN" { return false }
            // "Not for me" stays out of every shelf and category page (search still finds it).
            if !searching && settings.dismissedPicks.contains(media.id) { return false }
            // Suggestion shelves: a show where you already have another season is skipped.
            if firstSeasonsOnly && franchises.contains(media) { return false }
            return true
        }
    }

    /// One page from AniList as it comes (with relations), before any local filtering.
    private func rawPage(search: String? = nil,
                         sort: [String],
                         season: String? = nil,
                         seasonYear: Int? = nil,
                         status: String? = nil,
                         category: AnimeCategory? = nil,
                         genres: [String]? = nil,
                         excludeGenres: [String]? = nil,
                         minScore: Int? = nil,
                         maxPopularity: Int? = nil,
                         minPopularity: Int? = nil,
                         page: Int = 1,
                         perPage: Int = 25,
                         waitOnRateLimit: Bool = true) async throws -> (media: [Media], hasNextPage: Bool) {
        var vars: [String: Any] = ["page": page, "perPage": perPage, "sort": sort,
                                   "isAdult": category?.isAdultOnly == true]
        if let genres, !genres.isEmpty { vars["genres"] = genres }
        if let excludeGenres, !excludeGenres.isEmpty { vars["genresNot"] = excludeGenres }
        if let minScore { vars["scoreGreater"] = minScore }
        if let maxPopularity { vars["popularityLesser"] = maxPopularity }
        if let minPopularity { vars["popularityGreater"] = minPopularity }
        let searching = !(search ?? "").isEmpty
        if searching { vars["search"] = search } else { vars["formatNot"] = ["MOVIE"] }
        if let category { vars.merge(category.browseVariables) { a, _ in a } }
        if let season { vars["season"] = season }
        if let seasonYear { vars["seasonYear"] = seasonYear }
        if let status { vars["status"] = status }
        // With relations, so later seasons can be told apart and shown as their first season.
        let data = try await client.run(Queries.browseWithRelations, variables: vars, as: PageData.self,
                                        waitOnRateLimit: waitOnRateLimit)
        let hasNext = data.page.pageInfo?.hasNextPage ?? (data.page.media.count >= perPage)
        return (data.page.media, hasNext)
    }

    /// Details pages seen in the last 10 minutes, kept in memory: going back to a show (or
    /// opening it again from another row) is instant and its zoom never waits on the network.
    @ObservationIgnored private var detailCache: [Int: (detail: MediaDetail, at: Date)] = [:]

    func cachedDetail(id: Int) -> MediaDetail? {
        guard let hit = detailCache[id], Date().timeIntervalSince(hit.at) < 600 else { return nil }
        return hit.detail
    }

    func detail(id: Int) async throws -> MediaDetail {
        if let hit = cachedDetail(id: id) { return hit }
        let loaded = try await client.run(Queries.detail, variables: ["id": id], as: MediaDetailData.self).media
        if detailCache.count > 40 { detailCache.removeAll(keepingCapacity: true) }
        detailCache[id] = (loaded, Date())
        return loaded
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
        return cacheName("feed3-\(safe)")
    }

    /// Battery-friendly: reuses saved picks unless your list changed or they're over 3 days old.
    /// In-flight builds, owned by the model: leaving a tab (which cancels that screen's tasks)
    /// never cancels a build, and a second screen asking for the same feed just waits for it.
    @ObservationIgnored private var generationTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var moreTasks: [String: Task<Void, Never>] = [:]

    func generateRecommendations(category: AnimeCategory? = nil, force: Bool = false) async {
        let key = Self.feedKey(category)
        if let running = generationTasks[key] {
            await running.value
            guard force else { return }   // a refresh asked for while building: rebuild after it
            if generationTasks[key] != nil { return }
        }
        let task = Task {
            await self.performGenerate(category: category, force: force)
            self.generationTasks[key] = nil
        }
        generationTasks[key] = task
        await task.value
    }

    func loadMorePicks(category: AnimeCategory? = nil) async {
        let key = Self.feedKey(category)
        if let running = moreTasks[key] {
            await running.value
            return
        }
        let task = Task {
            await self.performLoadMore(category: category)
            self.moreTasks[key] = nil
        }
        moreTasks[key] = task
        await task.value
    }

    /// A cancelled request is not something to show you.
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let url = error as? URLError, url.code == .cancelled { return true }
        return false
    }

    private func performGenerate(category: AnimeCategory?, force: Bool) async {
        let key = Self.feedKey(category)
        guard !loadingFeeds.contains(key) else { return }
        guard !entries.isEmpty else {
            // Only once your list has really loaded; before that it's just not here yet.
            if listLoadedOnce { recommendationErrors[key] = "Your list is empty. Add and rate a few shows first." }
            return
        }
        let options = recommendationOptions(category)
        let fingerprint = Recommender.fingerprint(entries: entries, options: options)
        let mustRebuild = force || forceRebuild.contains(key)
        forceRebuild.remove(key)
        if !mustRebuild {
            if feeds[key] == nil {
                feeds[key] = await DiskCache.loadInBackground(RecommendationResult.self, name: feedCacheName(category))
            }
            if var current = feeds[key], !current.picks.isEmpty {
                let age = Date().timeIntervalSince(current.generatedAt)
                // Same list: keep for 3 days. List changed (you planned/finished/rated something):
                // keep a fresh feed for a day so For You doesn't reshuffle under your thumb; the
                // match % and the next "load more" round already use your updated taste.
                if (current.fingerprint == fingerprint && age < 3 * 86_400) || age < 86_400 {
                    // Drop anything now on your list or excluded by your current settings.
                    let onList = current.picks.filter { !stillWanted($0.media) }.map(\.id)
                    if !onList.isEmpty {
                        for id in onList { current.remove(id) }
                        feeds[key] = current
                        DiskCache.saveInBackground(current, name: feedCacheName(category))
                    }
                    return
                }
            }
        }
        loadingFeeds.insert(key)
        recommendationErrors[key] = nil
        let account = viewer?.id
        let picks: [Recommendation]
        do {
            let (found, usedAI, fans) = try await Recommender.run(entries: entries, client: client, options: options)
            guard viewer?.id == account, !Task.isCancelled else { loadingFeeds.remove(key); return }   // logged out meanwhile
            matcher.addFanSignal(fans)
            DiskCache.saveInBackground(matcher.fanSnapshot, name: cacheName("fans2"))
            // Built from the list as it was when the build started: anything you planned,
            // watched or dismissed meanwhile stays out.
            picks = found.filter { stillWanted($0.media) }
            let result = RecommendationResult(picks: picks, generatedAt: Date(), fingerprint: fingerprint,
                                              usedOnDeviceAI: usedAI, round: 1, exhausted: false)
            feeds[key] = result
            DiskCache.saveInBackground(result, name: feedCacheName(category))
        } catch {
            loadingFeeds.remove(key)
            if !Self.isCancellation(error) { recommendationErrors[key] = error.localizedDescription }
            return
        }
        loadingFeeds.remove(key)
        // A thin first round (small list or narrow category): top it up right away.
        if picks.count < 10 { await loadMorePicks(category: category) }
    }

    /// Called when you get near the end of the feed: digs one round deeper and appends.
    /// While it runs you keep using the feed (planning, dismissing), so the result is added to
    /// the feed as it is *now*, never written over it with the copy from before.
    private func performLoadMore(category: AnimeCategory?) async {
        let key = Self.feedKey(category)
        guard let start = feeds[key], !start.exhausted,
              !loadingMore.contains(key), !loadingFeeds.contains(key) else { return }
        loadingMore.insert(key)
        defer { loadingMore.remove(key) }

        let options = recommendationOptions(category)
        let account = viewer?.id
        let generatedAt = start.generatedAt
        var shown = Set(start.picks.map(\.id))
        var round = start.round
        var added: [Recommendation] = []
        var usedAI = false
        var emptyRounds = 0
        var failed = false
        // Try up to 3 deeper rounds to find something new before calling it the end.
        while emptyRounds < 3 {
            round += 1
            do {
                let (more, ai, fans) = try await Recommender.run(entries: entries, client: client, options: options,
                                                             round: round, exclude: shown)
                guard viewer?.id == account, !Task.isCancelled else { return }   // logged out meanwhile
                matcher.addFanSignal(fans)
                DiskCache.saveInBackground(matcher.fanSnapshot, name: cacheName("fans2"))
                let fresh = more.filter { !shown.contains($0.id) }
                if fresh.isEmpty {
                    emptyRounds += 1
                    continue
                }
                added = fresh
                usedAI = ai
                shown.formUnion(fresh.map(\.id))
                break
            } catch {
                if !Self.isCancellation(error) { recommendationErrors[key] = error.localizedDescription }
                failed = true
                break
            }
        }
        // The feed was rebuilt or cleared meanwhile (refresh, settings change): this is stale.
        guard var latest = feeds[key], latest.generatedAt == generatedAt else { return }
        let present = Set(latest.picks.map(\.id))
        latest.picks += added.filter { !present.contains($0.id) && stillWanted($0.media) }
        latest.round = max(latest.round, round)
        latest.usedOnDeviceAI = latest.usedOnDeviceAI || usedAI
        if !failed && emptyRounds >= 3 { latest.exhausted = true }
        feeds[key] = latest
        DiskCache.saveInBackground(latest, name: feedCacheName(category))
    }

    /// Whether a pick still belongs in a feed: not on your list (or another season of it), not
    /// dismissed, and allowed by your current settings.
    private func stillWanted(_ media: Media) -> Bool {
        if entry(for: media.id) != nil || franchises.contains(media) { return false }
        if settings.dismissedPicks.contains(media.id) { return false }
        if settings.hideChinese && media.countryOfOrigin == "CN" { return false }
        if media.isMovie || media.isLaterSeason { return false }
        if !settings.includeUnreleased && media.status == "NOT_YET_RELEASED" { return false }
        return true
    }

    /// Takes a show out of every picks feed (it's on your list now). Not a dislike.
    func removeFromFeeds(_ mediaId: Int) {
        for key in Array(feeds.keys) where feeds[key]?.picks.contains(where: { $0.id == mediaId }) == true {
            feeds[key]?.remove(mediaId)
            if let updated = feeds[key] { DiskCache.saveInBackground(updated, name: feedCacheName(key: key)) }
        }
    }

    /// "Plan to watch": adds the show (every season) to Planning; it then leaves Home rows and
    /// picks. Returns false if AniList couldn't be updated.
    @discardableResult
    func planToWatch(_ media: Media) async -> Bool {
        do {
            try await save(media: media, status: .PLANNING, progress: nil, scoreRaw: nil)
            removeFromFeeds(media.id)
            updateOtherSeasons(of: media, .planned)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    // MARK: - Whole show
    //
    // The app treats a show as one thing (its seasons live in the details page's dropdown),
    // but AniList keeps one entry per season. So show-level changes are copied to the other
    // seasons in the background, gently spaced, and your AniList stays complete:
    // planned → the rest are planned too; watched → all completed (an airing season becomes
    // Watching, an unreleased one Planning); removed → all removed; your score → every season
    // you haven't scored yourself. Progress always stays per season.

    enum ShowChange: Equatable {
        case planned
        case watched
        case removed
        case scored(Int)
    }

    @ObservationIgnored private var showSyncTask: Task<Void, Never>?

    /// All seasons of the show `media` belongs to: TV/ONA entries with the same title, from the
    /// same chain the season dropdown shows (named spin-off series are left alone).
    private func otherSeasons(of media: Media) async -> [Media] {
        guard media.isSeason else { return [] }
        let chain = await SeasonChain.shared.seasons(for: media, client: client)
        return chain.filter {
            $0.id != media.id && $0.isSeason && Seasons.sameShow(media.title, $0.title)
        }
    }

    func updateOtherSeasons(of media: Media, _ change: ShowChange) {
        guard case .loggedIn = mode else { return }
        let previous = showSyncTask
        let account = viewer?.id
        // One after another, so two quick changes never race each other.
        showSyncTask = Task {
            await previous?.value
            guard viewer?.id == account else { return }
            let seasons = await otherSeasons(of: media)
            var failed = false
            // Collected and applied to your list once at the end: saving four seasons used to
            // change the list four times, and every change redraws every match badge.
            var written: [(EntryLite, Media, ListStatus)] = []
            var removed: Set<Int> = []
            func write(_ season: Media, _ status: ListStatus, progress: Int?, score: Int?) async throws {
                let saved = try await self.writeEntry(media: season, status: status, progress: progress, scoreRaw: score)
                written.append((saved, season, status))
            }
            var removedEntries: [Int: ListEntry] = [:]   // mediaId → entry taken off the list
            if change == .removed {
                // Gone from your list at once; AniList is caught up in the background below.
                for season in seasons { if let e = entry(for: season.id) { removedEntries[season.id] = e } }
                let ids = Set(removedEntries.values.map(\.id))
                if !ids.isEmpty { entries.removeAll { ids.contains($0.id) } }
            }
            for season in seasons {
                guard viewer?.id == account, !Task.isCancelled else { break }   // what's written still lands
                let current = entry(for: season.id) ?? removedEntries[season.id]
                do {
                    var wrote = true
                    switch change {
                    case .planned:
                        if current == nil {
                            try await write(season, .PLANNING, progress: nil, score: nil)
                        } else { wrote = false }
                    case .watched:
                        if current?.status == .COMPLETED { wrote = false; break }
                        switch season.status {
                        case "NOT_YET_RELEASED":
                            if current == nil {
                                try await write(season, .PLANNING, progress: nil, score: nil)
                            } else { wrote = false }
                        case "RELEASING":
                            let aired = season.availableEpisodes ?? current?.progress
                            try await write(season, .CURRENT,
                                            progress: max(aired ?? 0, current?.progressValue ?? 0), score: nil)
                        default:
                            try await write(season, .COMPLETED,
                                            progress: season.episodes ?? current?.progress, score: nil)
                        }
                    case .removed:
                        if let current {
                            detailCache[season.id] = nil
                            _ = try await client.run(Queries.deleteEntry, variables: ["id": current.id],
                                                     as: DeleteEntryData.self)
                            removed.insert(current.id)
                        } else { wrote = false }
                    case .scored(let score):
                        if let current, current.scoreValue == 0, score > 0 {
                            try await write(season, current.status, progress: nil, score: score)
                        } else { wrote = false }
                    }
                    if wrote { try? await Task.sleep(nanoseconds: Self.writeSpacing) }
                } catch {
                    failed = true
                }
            }
            if (!written.isEmpty || !removed.isEmpty), viewer?.id == account {
                var list = entries
                for (saved, season, status) in written { Self.apply(saved, media: season, status: status, to: &list) }
                list.removeAll { removed.contains($0.id) }
                entries = list
                removeKnownFromFeeds()
            }
            if failed && change == .removed && viewer?.id == account { await refreshList() }
            if failed {
                errorMessage = "Couldn't update every season of \(media.displayTitle(settings.titleLanguage)) on AniList. Try again in a moment."
            }
        }
    }

    /// Removes the show from your list: this entry, then its other seasons.
    /// Leaves your list at once (the row never jumps back while AniList answers); if AniList
    /// says no, it comes back and the error is shown.
    func removeShow(_ media: Media, entryId: Int) async throws {
        detailCache[media.id] = nil
        let removed = entries.first { $0.id == entryId }
        entries.removeAll { $0.id == entryId }
        do {
            _ = try await client.run(Queries.deleteEntry, variables: ["id": entryId], as: DeleteEntryData.self)
        } catch {
            if let removed, !entries.contains(where: { $0.id == entryId }) { entries.append(removed) }
            throw error
        }
        updateOtherSeasons(of: media, .removed)
    }

    /// The on-device AI setting changed, or Low Power Mode / heat ended: bring the AI part of
    /// match % back right away (saved analysis is reused). Turning AI off changes nothing.
    func aiAvailabilityChanged() {
        matcher.aiAvailabilityChanged()
    }

    func dismissPick(_ mediaId: Int, media: Media? = nil) {
        if let media, notForMeMedia[mediaId] == nil { notForMeMedia[mediaId] = media }
        settings.dismissedPicks.insert(mediaId)
        ensureNotForMeLoaded()
        if case .loggedIn = mode, notForMeEntries[mediaId] == nil {
            pendingNotForMe.insert(mediaId)
            saveNotForMeState()
            syncNotForMe()
        }
        removeFromFeeds(mediaId)
    }

    private func cacheName(_ kind: String) -> String {
        "\(kind)-\(viewer?.id ?? 0)"
    }

    func resetDismissedPicks() {
        ensureNotForMeLoaded()
        let toDelete = Array(notForMeEntries)
        settings.dismissedPicks = []
        pendingNotForMe = []
        saveNotForMeState()
        invalidatePicks()
        guard case .loggedIn = mode, !toDelete.isEmpty else {
            notForMeEntries = [:]
            saveNotForMeState()
            return
        }
        isResettingNotForMe = true
        Task {
            defer { isResettingNotForMe = false }
            for (index, item) in toDelete.enumerated() {
                if index > 0 { try? await Task.sleep(nanoseconds: Self.writeSpacing) }
                do {
                    _ = try await client.run(Queries.deleteEntry, variables: ["id": item.value], as: DeleteEntryData.self)
                    notForMeEntries[item.key] = nil
                } catch {
                    // Couldn't reach AniList: what's left stays synced and shows up again; retry later.
                    settings.dismissedPicks.formUnion(notForMeEntries.keys)
                    errorMessage = "Couldn't reset all \"Not for me\" shows on AniList. Try again later."
                    break
                }
            }
            saveNotForMeState()
        }
    }

    // MARK: - "Not for me", synced through AniList
    //
    // Each dismissed show becomes a private AniList entry (visible only to you, never on your
    // followers' feed), hidden from your status lists, in a custom list named "Not for me".
    // The app reads that list back on every refresh, so it survives reinstalls and works across
    // devices. In read-only username mode it stays on this iPhone.

    static let notForMeList = "Not for me"
    /// AniList is currently strict about request rates: space writes ~2s apart.
    private static let writeSpacing: UInt64 = 2_100_000_000

    /// mediaId → AniList entry id of synced "Not for me" shows.
    @ObservationIgnored private var notForMeEntries: [Int: Int] = [:]
    /// Dismissed here but not uploaded yet (offline, or just tapped).
    @ObservationIgnored private var pendingNotForMe: Set<Int> = []
    @ObservationIgnored private var notForMeSync: Task<Void, Never>?
    private(set) var isResettingNotForMe = false
    /// Show details for the "Not for me" list in Lists (synced ones arrive with your list).
    private(set) var notForMeMedia: [Int: Media] = [:]

    /// Fetches details for dismissed shows that aren't known yet (local-only or older ones).
    /// Returns false if AniList couldn't be reached.
    @discardableResult
    func loadNotForMeMedia() async -> Bool {
        let missing = Array(settings.dismissedPicks.filter { notForMeMedia[$0] == nil })
        var start = 0
        while start < missing.count {
            let chunk = Array(missing[start..<min(start + 50, missing.count)])
            start += 50
            guard let data = try? await client.run(Queries.mediaByIds,
                                                    variables: ["ids": chunk, "perPage": chunk.count],
                                                    as: PageData.self) else { return false }
            for m in data.page.media { notForMeMedia[m.id] = m }
        }
        return true
    }

    /// Brings one show back: it can be suggested again (and leaves AniList's "Not for me" list).
    func undoNotForMe(_ mediaId: Int) async {
        ensureNotForMeLoaded()
        settings.dismissedPicks.remove(mediaId)
        pendingNotForMe.remove(mediaId)
        saveNotForMeState()
        guard case .loggedIn = mode, let entryId = notForMeEntries[mediaId] else { return }
        do {
            _ = try await client.run(Queries.deleteEntry, variables: ["id": entryId], as: DeleteEntryData.self)
            notForMeEntries[mediaId] = nil
            saveNotForMeState()
        } catch {
            settings.dismissedPicks.insert(mediaId)   // still on AniList: keep it consistent
            errorMessage = "Couldn't update AniList. Try again in a moment."
        }
    }

    /// Whether AniList's own record for this show is just a "Not for me" marker.
    func isNotForMeEntry(_ lite: EntryLite?) -> Bool {
        guard let lite else { return false }
        return notForMeEntries[lite.mediaId] == lite.id
    }

    private var notForMeKey: String { "notForMe-\(viewer?.id ?? 0)" }

    @ObservationIgnored private var notForMeLoadedFor: Int?

    /// Loads this account's saved sync state once (before anything reads or writes it).
    private func ensureNotForMeLoaded() {
        guard let id = viewer?.id, notForMeLoadedFor != id else { return }
        notForMeLoadedFor = id
        loadNotForMeState()
    }

    private func loadNotForMeState() {
        let stored = defaults.dictionary(forKey: notForMeKey + "-entries") as? [String: Int] ?? [:]
        notForMeEntries = Dictionary(stored.compactMap { k, v in Int(k).map { ($0, v) } }, uniquingKeysWith: { a, _ in a })
        pendingNotForMe = Set(defaults.array(forKey: notForMeKey + "-pending") as? [Int] ?? [])
    }

    private func saveNotForMeState() {
        guard viewer != nil, notForMeLoadedFor == viewer?.id else { return }
        defaults.set(Dictionary(uniqueKeysWithValues: notForMeEntries.map { (String($0.key), $0.value) }),
                     forKey: notForMeKey + "-entries")
        defaults.set(Array(pendingNotForMe), forKey: notForMeKey + "-pending")
    }

    /// AniList is the source of truth; shows dismissed here but not yet uploaded are kept and sent.
    private func mergeNotForMe(remote: [Int: Int]) {
        ensureNotForMeLoaded()
        let migratedKey = notForMeKey + "-migrated"
        if !defaults.bool(forKey: migratedKey) {
            // First sync: upload what was dismissed before syncing existed.
            pendingNotForMe.formUnion(settings.dismissedPicks.subtracting(remote.keys).filter { entry(for: $0) == nil })
            defaults.set(true, forKey: migratedKey)
        }
        pendingNotForMe.subtract(remote.keys)
        notForMeEntries = remote
        let merged = Set(remote.keys).union(pendingNotForMe)
        if merged != settings.dismissedPicks {
            settings.dismissedPicks = merged
            for id in merged { for key in feeds.keys { feeds[key]?.remove(id) } }
        }
        saveNotForMeState()
        syncNotForMe()
    }

    /// Uploads pending dismissals one by one, gently. Safe to call any time.
    private func syncNotForMe() {
        guard case .loggedIn = mode, !pendingNotForMe.isEmpty, notForMeSync == nil else { return }
        notForMeSync = Task {
            defer { notForMeSync = nil }
            guard await ensureNotForMeListExists() else { return }
            var first = true
            while let mediaId = pendingNotForMe.first {
                if !first { try? await Task.sleep(nanoseconds: Self.writeSpacing) }
                first = false
                // Added to your list meanwhile: it's not a dismissal any more.
                if entry(for: mediaId) != nil || !settings.dismissedPicks.contains(mediaId) {
                    pendingNotForMe.remove(mediaId)
                    continue
                }
                do {
                    let saved = try await client.run(Queries.saveNotForMe,
                                                     variables: ["mediaId": mediaId, "lists": [Self.notForMeList]],
                                                     as: NotForMeData.self).entry
                    notForMeEntries[saved.mediaId] = saved.id
                    pendingNotForMe.remove(mediaId)
                    saveNotForMeState()
                } catch {
                    break   // offline or rate limited: the rest goes up on the next refresh
                }
            }
            saveNotForMeState()
        }
    }

    /// Adds "Not for me" to your custom lists, keeping every list you already have.
    @ObservationIgnored private var notForMeListReady = false
    private func ensureNotForMeListExists() async -> Bool {
        if notForMeListReady { return true }
        guard let data = try? await client.run(Queries.listOptions, as: ListOptionsData.self),
              let current = data.viewer?.mediaListOptions?.animeList?.customLists else {
            return false   // couldn't read your lists: never risk overwriting them
        }
        if current.contains(Self.notForMeList) {
            notForMeListReady = true
            return true
        }
        guard let updated = try? await client.run(Queries.updateCustomLists,
                                                  variables: ["lists": current + [Self.notForMeList]],
                                                  as: UpdateUserListsData.self),
              updated.user?.mediaListOptions?.animeList?.customLists?.contains(Self.notForMeList) == true else {
            return false
        }
        notForMeListReady = true
        try? await Task.sleep(nanoseconds: Self.writeSpacing)
        return true
    }

    /// Pick settings changed: rebuild every feed on its next visit.
    func invalidatePicks() {
        forceRebuild.formUnion(feeds.keys)
        forceRebuild.insert("any")
        feeds = [:]
    }

    // MARK: - Categories

    /// Loads AniList's genres and tags once (cached for a week). Featured chips come first.
    func loadCategories() async {
        if !allCategories.isEmpty { return }
        struct Cached: Codable { let categories: [AnimeCategory]; let savedAt: Date }
        // v2: now includes the Hentai genre (shown only when picked).
        if let cached = DiskCache.load(Cached.self, name: "categories2"),
           Date().timeIntervalSince(cached.savedAt) < 7 * 86_400, !cached.categories.isEmpty {
            allCategories = cached.categories
            return
        }
        do {
            let data = try await client.run(Queries.categories, as: CategoryCollectionData.self)
            let genres = (data.genres ?? []).map(AnimeCategory.genre)
            let tags = (data.tags ?? [])
                .filter { $0.isAdult != true && $0.isGeneralSpoiler != true }
                .map { AnimeCategory.tag($0.name) }
            let known = Set((genres + tags).map(\.id))
            let featured = AnimeCategory.featured.filter { known.contains($0.id) }
            let rest = (genres + tags)
                .filter { !featured.contains($0) }
                .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
            allCategories = featured + rest
            DiskCache.save(Cached(categories: allCategories, savedAt: Date()), name: "categories2")
        } catch {
            // Cancelled (screen left mid-load): leave it empty so it loads properly next time.
            if Self.isCancellation(error) { return }
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
