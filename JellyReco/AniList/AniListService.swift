import Foundation
import Observation
import SwiftUI

/// For You on the Anime / Anime Movies libraries, the AniReco way: your AniList account is
/// the list. Picks are learned from your AniList list (AniReco's recommender), "Add to My List"
/// puts a show on your AniList Planning list (every season), "Not for me" files it in a private,
/// hidden "Not for me" custom list on AniList, "Already seen" marks it Completed. Anything
/// already on your Jellyfin server is never picked.
///
/// The AniList login belongs to the Jellyfin account it was made in (each person on a shared
/// iPhone has their own); the token is kept in the iOS Keychain.
@Observable
@MainActor
final class AniListService {
    let client = AniListClient()
    /// Age ratings for AniList covers (Kitsu, as in AniReco).
    let ages = AgeRatings()
    @ObservationIgnored private weak var model: AppModel?

    private(set) var viewer: Viewer?
    private(set) var entries: [ListEntry] = [] {
        didSet {
            entryIndex = Dictionary(entries.indices.map { (entries[$0].mediaId, $0) }, uniquingKeysWith: { a, _ in a })
            franchises = ListFranchises(entries.map(\.media))
        }
    }
    @ObservationIgnored private var entryIndex: [Int: Int] = [:]
    @ObservationIgnored private(set) var franchises = ListFranchises()
    private(set) var isLoadingList = false
    /// True once AniList answered for your list at least once (or failed).
    private(set) var listLoadedOnce = false
    private(set) var isLoggingIn = false
    /// Why the list couldn't be read (offline, AniList down), shown instead of "your list is empty".
    private(set) var listError: String?

    // Picks, one feed per library kind and category.
    private(set) var feeds: [String: RecommendationResult] = [:]
    private(set) var loadingFeeds: Set<String> = []
    private(set) var loadingMore: Set<String> = []
    private(set) var feedErrors: [String: String] = [:]
    /// AniList's genres and tags (featured first), for the category dropdown.
    private(set) var categories: [AnimeCategory] = []

    /// "How did you like it?" after "Already seen" (scores sharpen picks the most).
    var ratePrompt: Media?

    /// Shows marked "Not for me" (AniList ids).
    private(set) var dismissed: Set<Int> = []
    /// Their details, for the Not for me screen.
    private(set) var notForMeMedia: [Int: Media] = [:]

    @ObservationIgnored private var accountKey: String?
    @ObservationIgnored private var forceRebuild: Set<String> = []
    @ObservationIgnored private var generationTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var moreTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var showSyncTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    private let defaults = UserDefaults.standard

    func attach(model: AppModel) { self.model = model }

    // MARK: Account

    /// Observed copy of "the client has a token" (the client itself isn't observable).
    private(set) var isLoggedIn = false

    private func useToken(_ token: String?) {
        client.token = token
        isLoggedIn = token?.isEmpty == false
    }

    var language: TitleLanguage {
        if let raw = model?.settings.anilistTitleLanguage, let chosen = TitleLanguage(rawValue: raw) { return chosen }
        return TitleLanguage(anilistOption: viewer?.options?.titleLanguage)
    }

    private var tokenKey: String? { accountKey.map { "anilist-token|\($0)" } }

    /// The Jellyfin account in use: its own AniList login. Called before anything reads the
    /// AniList state; switching Jellyfin accounts puts the previous account's AniList away.
    func syncAccount() {
        guard let model else { return }
        let key: String? = {
            guard let sid = model.store.currentServerId, let uid = model.client?.userId else { return nil }
            return "\(sid)|\(uid)"
        }()
        guard key != accountKey else { return }
        clearState()
        accountKey = key
        guard let tokenKey, let token = Keychain.get(tokenKey), !token.isEmpty else { return }
        useToken(token)
        loadAccount()
    }

    /// Loads the profile and the list once per account (later refreshes: `refreshList`).
    func loadAccount() {
        guard isLoggedIn, loadTask == nil else { return }
        let task = Task { await reloadAll() }
        loadTask = task
        Task {
            await task.value
            if loadTask == task { loadTask = nil }
        }
    }

    func reloadAll() async {
        useCachedViewer()
        await loadCachedList()
        await loadViewer()
        await refreshList()
    }

    func logIn(token: String) async {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        syncAccount()
        guard !trimmed.isEmpty, let tokenKey else { return }
        Keychain.set(trimmed, for: tokenKey)
        clearState(keepAccount: true)
        useToken(trimmed)
        isLoggingIn = true
        defer { isLoggingIn = false }
        await reloadAll()
    }

    func handleAuthCallback(_ url: URL) async {
        guard let token = AniListAuth.token(from: url) else {
            model?.errorMessage = "AniList login failed: AniList didn't send an access token back."
            return
        }
        await logIn(token: token)
    }

    func logOut() {
        if let tokenKey { Keychain.set(nil, for: tokenKey) }
        clearState(keepAccount: true)
    }

    /// Forgets everything of the current AniList account in memory (saved picks stay on disk,
    /// per AniList account, so logging back in is instant).
    private func clearState(keepAccount: Bool = false) {
        if !keepAccount { accountKey = nil }
        useToken(nil)
        viewer = nil
        entries = []
        listLoadedOnce = false
        isLoadingList = false
        listError = nil
        feeds = [:]
        feedErrors = [:]
        forceRebuild = []
        dismissed = []
        notForMeMedia = [:]
        notForMeEntries = [:]
        pendingNotForMe = []
        notForMeLoadedFor = nil
        notForMeListReady = false
        notForMeSync?.cancel(); notForMeSync = nil
        showSyncTask?.cancel(); showSyncTask = nil
        loadTask?.cancel(); loadTask = nil
        generationTasks.values.forEach { $0.cancel() }
        moreTasks.values.forEach { $0.cancel() }
        generationTasks = [:]; moreTasks = [:]
        loadingFeeds = []; loadingMore = []
        ratePrompt = nil
    }

    private func cacheName(_ kind: String) -> String { "reco-anilist-\(kind)-\(viewer?.id ?? 0)" }

    private func useCachedViewer() {
        guard viewer == nil, let accountKey,
              let cached = DiskCache.load(Viewer.self, name: "reco-anilist-viewer-\(Self.safe(accountKey))") else { return }
        viewer = cached
    }

    private func loadViewer() async {
        guard isLoggedIn else { return }
        do {
            let fresh = try await client.run(Queries.viewer, as: ViewerData.self, waitOnRateLimit: viewer == nil).viewer
            guard isLoggedIn else { return }
            if viewer?.id != fresh.id { notForMeLoadedFor = nil }
            viewer = fresh
            if let accountKey { DiskCache.save(fresh, name: "reco-anilist-viewer-\(Self.safe(accountKey))") }
            ensureNotForMeLoaded()
        } catch {
            if isAuthError(error) {
                model?.errorMessage = "Your AniList login expired. Log in again in Settings → For You."
                logOut()
            } else if viewer == nil && !Self.isCancellation(error) {
                feedErrors["login"] = error.localizedDescription
            }
        }
    }

    func refreshList() async {
        guard isLoggedIn, let userId = viewer?.id else { listLoadedOnce = true; return }
        isLoadingList = true
        defer { isLoadingList = false; listLoadedOnce = true }
        do {
            let data = try await client.run(Queries.listCollection, variables: ["userId": userId], as: CollectionData.self)
            guard viewer?.id == userId else { return }
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
            // A "Not for me" entry never appears in your lists or shapes your taste.
            if !notForMe.isEmpty { result.removeAll { notForMe[$0.mediaId] == $0.id } }
            entries = result
            listError = nil
            DiskCache.saveInBackground(result, name: cacheName("list"))
            mergeNotForMe(remote: notForMe)
            removeKnownFromFeeds()
            model?.migrateAnimeListsToAniList()
        } catch {
            if isAuthError(error) {
                model?.errorMessage = "Your AniList login expired. Log in again in Settings → For You."
                logOut()
            } else if !Self.isCancellation(error) {
                listError = "Couldn't read your AniList list: \(error.localizedDescription)"
            }
        }
    }

    private func loadCachedList() async {
        guard entries.isEmpty, viewer != nil,
              let cached = await DiskCache.loadInBackground([ListEntry].self, name: cacheName("list")),
              entries.isEmpty else { return }
        entries = cached
    }

    private func isAuthError(_ error: Error) -> Bool {
        if case AniListError.http(let code) = error, code == 401 { return true }
        if case AniListError.graphQL(let msg) = error, msg.localizedCaseInsensitiveContains("invalid token")
            || msg.localizedCaseInsensitiveContains("unauthorized") { return true }
        return false
    }

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let url = error as? URLError, url.code == .cancelled { return true }
        return false
    }

    private static func safe(_ s: String) -> String {
        s.replacingOccurrences(of: "[^A-Za-z0-9]", with: "_", options: .regularExpression)
    }

    // MARK: Your list

    func entry(for mediaId: Int) -> ListEntry? {
        guard let index = entryIndex[mediaId], index < entries.count else { return nil }
        let entry = entries[index]
        return entry.mediaId == mediaId ? entry : entries.first { $0.mediaId == mediaId }
    }

    func isPlanned(_ mediaId: Int) -> Bool { entry(for: mediaId)?.status == .PLANNING }

    /// Your AniList Planning list, newest first (My List shows it).
    var planning: [ListEntry] {
        entries.filter { $0.status == .PLANNING }.sorted { ($0.createdAt ?? $0.updatedAt ?? 0) > ($1.createdAt ?? $1.updatedAt ?? 0) }
    }

    /// Your strongest likes on AniList (for "Why would I like this?").
    func topLiked(limit: Int = 8) -> [String] {
        entries.filter { [.COMPLETED, .REPEATING, .CURRENT].contains($0.status) }
            .sorted { ($0.scoreValue, $0.updatedAt ?? 0) > ($1.scoreValue, $1.updatedAt ?? 0) }
            .prefix(limit)
            .map { $0.media.displayTitle(language) }
    }

    // MARK: Picks

    static func feedKey(_ library: AniListLibrary, _ category: AnimeCategory?) -> String {
        "\(library.rawValue)|\(category?.id ?? "any")"
    }

    func picks(_ library: AniListLibrary, _ category: AnimeCategory?) -> [Recommendation] {
        let all = feeds[Self.feedKey(library, category)]?.picks ?? []
        let owned = ownedIndex()
        return all.filter { stillWanted($0.media, library, owned: owned) }
    }

    /// The picks shaped like For You's titles, so the same cards and sheets show them.
    func externalPicks(_ library: AniListLibrary, _ category: AnimeCategory?) -> [ExternalPick] {
        picks(library, category).map {
            ExternalPick(title: title(for: $0.media), score: $0.score, match: $0.match,
                         because: $0.because, highlights: $0.sharedHighlights)
        }
    }

    @ObservationIgnored private var titleCache: [Int: (language: TitleLanguage, title: ExternalTitle)] = [:]

    func title(for media: Media) -> ExternalTitle {
        let lang = language
        if let hit = titleCache[media.id], hit.language == lang { return hit.title }
        let t = ExternalTitle(anilist: media, language: lang)
        if titleCache.count > 2000 { titleCache.removeAll(keepingCapacity: true) }
        titleCache[media.id] = (lang, t)
        return t
    }

    func feed(_ library: AniListLibrary, _ category: AnimeCategory?) -> RecommendationResult? {
        feeds[Self.feedKey(library, category)]
    }

    func isBuilding(_ library: AniListLibrary, _ category: AnimeCategory?) -> Bool {
        loadingFeeds.contains(Self.feedKey(library, category))
    }

    func isLoadingMore(_ library: AniListLibrary, _ category: AnimeCategory?) -> Bool {
        loadingMore.contains(Self.feedKey(library, category))
    }

    func error(_ library: AniListLibrary, _ category: AnimeCategory?) -> String? {
        feedErrors[Self.feedKey(library, category)]
    }

    private func recommendationOptions(_ library: AniListLibrary, _ category: AnimeCategory?) -> Recommender.Options {
        let s = model?.settings
        return Recommender.Options(hideChinese: s?.anilistHideChinese ?? true,
                                   includeUnreleased: s?.anilistIncludeUnreleased ?? false,
                                   dismissed: dismissed,
                                   titleLanguage: language,
                                   useOnDeviceAI: s?.useOnDeviceAI ?? true,
                                   category: category,
                                   movies: library == .movies,
                                   owned: ownedIndex(),
                                   aiAllowedNow: SemanticEngine.shouldRunNow)
    }

    @ObservationIgnored private var owned: (revision: Int, index: AniListOwnedIndex)?

    /// Your Jellyfin server, indexed for "already yours" (rebuilt when the library changes).
    func ownedIndex() -> AniListOwnedIndex {
        guard let reco = model?.reco else { return AniListOwnedIndex() }
        if let owned, owned.revision == reco.libraryRevision { return owned.index }
        let index = AniListOwnedIndex(items: reco.libraryItems)
        if !reco.libraryItems.isEmpty { owned = (reco.libraryRevision, index) }
        return index
    }

    /// Not on your AniList list (or another season of it), not dismissed, not on your server,
    /// right for the library (Anime: shows, Anime Movies: movies) and allowed by your settings.
    private func stillWanted(_ media: Media, _ library: AniListLibrary, owned: AniListOwnedIndex) -> Bool {
        if entry(for: media.id) != nil || franchises.contains(media) { return false }
        if dismissed.contains(media.id) { return false }
        if (model?.settings.anilistHideChinese ?? true) && media.countryOfOrigin == "CN" { return false }
        if library == .movies ? !media.isMovie : (media.isMovie || media.isLaterSeason) { return false }
        if !(model?.settings.anilistIncludeUnreleased ?? false) && media.status == "NOT_YET_RELEASED" { return false }
        if owned.contains(media) { return false }
        return true
    }

    private func feedCacheName(_ key: String) -> String { cacheName("feed-\(Self.safe(key))") }

    /// Saved picks are reused unless your list changed or they're over 3 days old (AniReco's rule).
    func generate(_ library: AniListLibrary, _ category: AnimeCategory?, force: Bool = false) async {
        let key = Self.feedKey(library, category)
        if let running = generationTasks[key] {
            await running.value
            guard force else { return }
            if generationTasks[key] != nil { return }
        }
        let task = Task {
            await self.performGenerate(library, category, force: force)
            self.generationTasks[key] = nil
        }
        generationTasks[key] = task
        await task.value
    }

    func loadMore(_ library: AniListLibrary, _ category: AnimeCategory?) async {
        let key = Self.feedKey(library, category)
        if let running = moreTasks[key] { await running.value; return }
        let task = Task {
            await self.performLoadMore(library, category)
            self.moreTasks[key] = nil
        }
        moreTasks[key] = task
        await task.value
    }

    private func performGenerate(_ library: AniListLibrary, _ category: AnimeCategory?, force: Bool) async {
        let key = Self.feedKey(library, category)
        guard isLoggedIn, !loadingFeeds.contains(key) else { return }
        if viewer == nil || !listLoadedOnce {
            if let loadTask { await loadTask.value } else if viewer == nil { await reloadAll() }
        }
        guard viewer != nil else {
            feedErrors[key] = feedErrors["login"] ?? "Couldn't reach AniList. Pull down to try again."
            return
        }
        guard !entries.isEmpty else {
            if let listError { feedErrors[key] = listError }
            else if listLoadedOnce { feedErrors[key] = "Your AniList list is empty. Add and rate a few shows on AniList first." }
            return
        }
        // The library snapshot (what's on your server) arrives with For You's library read.
        if model?.reco.libraryItems.isEmpty == true { await model?.reco.ensureBuilt() }
        let options = recommendationOptions(library, category)
        let fingerprint = Recommender.fingerprint(entries: entries, options: options)
        let mustRebuild = force || forceRebuild.contains(key)
        forceRebuild.remove(key)
        if !mustRebuild {
            if feeds[key] == nil {
                feeds[key] = await DiskCache.loadInBackground(RecommendationResult.self, name: feedCacheName(key))
            }
            if let current = feeds[key], !current.picks.isEmpty {
                let age = Date().timeIntervalSince(current.generatedAt)
                if (current.fingerprint == fingerprint && age < 3 * 86_400) || age < 86_400 { return }
            }
        }
        loadingFeeds.insert(key)
        feedErrors[key] = nil
        let account = viewer?.id
        var found: [Recommendation] = []
        do {
            let (picks, usedAI, _) = try await Recommender.run(entries: entries, client: client, options: options)
            guard viewer?.id == account, !Task.isCancelled else { loadingFeeds.remove(key); return }
            let owned = ownedIndex()
            found = picks.filter { stillWanted($0.media, library, owned: owned) }
            let result = RecommendationResult(picks: found, generatedAt: Date(), fingerprint: fingerprint,
                                              usedOnDeviceAI: usedAI, round: 1, exhausted: false)
            feeds[key] = result
            DiskCache.saveInBackground(result, name: feedCacheName(key))
        } catch {
            loadingFeeds.remove(key)
            if !Self.isCancellation(error) { feedErrors[key] = error.localizedDescription }
            return
        }
        loadingFeeds.remove(key)
        // A thin first round (small list, narrow category, much already on your server): top up.
        if found.count < 10 { await loadMore(library, category) }
    }

    private func performLoadMore(_ library: AniListLibrary, _ category: AnimeCategory?) async {
        let key = Self.feedKey(library, category)
        guard let start = feeds[key], !start.exhausted, !loadingMore.contains(key), !loadingFeeds.contains(key) else { return }
        loadingMore.insert(key)
        defer { loadingMore.remove(key) }
        let options = recommendationOptions(library, category)
        let account = viewer?.id
        let generatedAt = start.generatedAt
        var shown = Set(start.picks.map(\.id))
        var round = start.round
        var added: [Recommendation] = []
        var usedAI = false
        var emptyRounds = 0
        var failed = false
        // Up to 3 deeper rounds to find something new before calling it the end.
        while emptyRounds < 3 {
            round += 1
            do {
                let (more, ai, _) = try await Recommender.run(entries: entries, client: client, options: options,
                                                             round: round, exclude: shown)
                guard viewer?.id == account, !Task.isCancelled else { return }
                let fresh = more.filter { !shown.contains($0.id) }
                if fresh.isEmpty { emptyRounds += 1; continue }
                added = fresh
                usedAI = ai
                shown.formUnion(fresh.map(\.id))
                break
            } catch {
                if !Self.isCancellation(error) { feedErrors[key] = error.localizedDescription }
                failed = true
                break
            }
        }
        guard var latest = feeds[key], latest.generatedAt == generatedAt else { return }
        let present = Set(latest.picks.map(\.id))
        let owned = ownedIndex()
        latest.picks += added.filter { !present.contains($0.id) && stillWanted($0.media, library, owned: owned) }
        latest.round = max(latest.round, round)
        latest.usedOnDeviceAI = latest.usedOnDeviceAI || usedAI
        if !failed && emptyRounds >= 3 { latest.exhausted = true }
        feeds[key] = latest
        DiskCache.saveInBackground(latest, name: feedCacheName(key))
    }

    /// Takes a show out of every feed (it's on your list now, or dismissed).
    func removeFromFeeds(_ mediaId: Int) {
        for key in Array(feeds.keys) where feeds[key]?.picks.contains(where: { $0.id == mediaId }) == true {
            feeds[key]?.remove(mediaId)
            if let updated = feeds[key] { DiskCache.saveInBackground(updated, name: feedCacheName(key)) }
        }
    }

    private func removeKnownFromFeeds() {
        for (key, value) in feeds {
            let known = value.picks.filter { entry(for: $0.id) != nil || franchises.contains($0.media) || dismissed.contains($0.id) }.map(\.id)
            guard !known.isEmpty else { continue }
            for id in known { feeds[key]?.remove(id) }
            if let updated = feeds[key] { DiskCache.saveInBackground(updated, name: feedCacheName(key)) }
        }
    }

    /// Pick settings changed: rebuild every feed on its next visit.
    func invalidatePicks() {
        forceRebuild.formUnion(feeds.keys)
        for library in [AniListLibrary.shows, .movies] { forceRebuild.insert(Self.feedKey(library, nil)) }
        feeds = [:]
    }

    /// AniList's genres and tags, loaded once (cached for a week). Featured ones first.
    func loadCategories() async {
        if !categories.isEmpty { return }
        struct Cached: Codable { let categories: [AnimeCategory]; let savedAt: Date }
        if let cached = DiskCache.load(Cached.self, name: "anilist-categories"),
           Date().timeIntervalSince(cached.savedAt) < 7 * 86_400, !cached.categories.isEmpty {
            categories = cached.categories
            return
        }
        do {
            let data = try await client.run(Queries.categories, as: CategoryCollectionData.self, waitOnRateLimit: false)
            let genres = (data.genres ?? []).map(AnimeCategory.genre)
            let tags = (data.tags ?? []).filter { $0.isAdult != true && $0.isGeneralSpoiler != true }.map { AnimeCategory.tag($0.name) }
            let known = Set((genres + tags).map(\.id))
            let featured = AnimeCategory.featured.filter { known.contains($0.id) }
            let rest = (genres + tags).filter { !featured.contains($0) }
                .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
            categories = featured + rest
            DiskCache.save(Cached(categories: categories, savedAt: Date()), name: "anilist-categories")
        } catch {
            if !Self.isCancellation(error) { categories = AnimeCategory.featured }
        }
    }

    // MARK: Writing to your AniList

    /// AniList is strict about request rates: writes go ~2 s apart.
    static let writeSpacing: UInt64 = 2_100_000_000

    @discardableResult
    func save(media: Media, status: ListStatus, progress: Int?, scoreRaw: Int?) async throws -> EntryLite {
        let saved = try await writeEntry(media: media, status: status, progress: progress, scoreRaw: scoreRaw)
        var list = entries
        Self.apply(saved, media: media, status: status, to: &list)
        entries = list
        removeKnownFromFeeds()
        return saved
    }

    private func writeEntry(media: Media, status: ListStatus, progress: Int?, scoreRaw: Int?) async throws -> EntryLite {
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
        if wasNotForMe || dismissed.contains(media.id) {
            notForMeEntries[media.id] = nil
            pendingNotForMe.remove(media.id)
            dismissed.remove(media.id)
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

    /// "Add to My List": the show (every season) goes on your AniList Planning list.
    @discardableResult
    func planToWatch(_ media: Media) async -> Bool {
        do {
            try await save(media: media, status: .PLANNING, progress: nil, scoreRaw: nil)
            removeFromFeeds(media.id)
            updateOtherSeasons(of: media, .planned)
            return true
        } catch {
            model?.errorMessage = "Couldn't add it to your AniList: \(error.localizedDescription)"
            return false
        }
    }

    /// "Already seen": Completed on AniList (your score stays), then "How did you like it?".
    @discardableResult
    func markCompleted(_ media: Media, askRating: Bool = true) async -> Bool {
        let existing = entry(for: media.id)
        let progress = media.episodes ?? media.availableEpisodes ?? existing?.progress
        do {
            try await save(media: media, status: .COMPLETED, progress: progress, scoreRaw: nil)
            if askRating && (existing?.scoreValue ?? 0) == 0 { ratePrompt = media }
            removeFromFeeds(media.id)
            updateOtherSeasons(of: media, .watched)
            return true
        } catch {
            model?.errorMessage = "Couldn't update your AniList: \(error.localizedDescription)"
            return false
        }
    }

    /// Off your Planning list (and its other seasons'), as AniReco's "Remove".
    func removeFromPlanning(_ mediaId: Int) async {
        guard let entry = entry(for: mediaId) else { return }
        entries.removeAll { $0.id == entry.id }
        do {
            _ = try await client.run(Queries.deleteEntry, variables: ["id": entry.id], as: DeleteEntryData.self)
            updateOtherSeasons(of: entry.media, .removed)
        } catch {
            if !entries.contains(where: { $0.id == entry.id }) { entries.append(entry) }
            model?.errorMessage = "Couldn't update your AniList: \(error.localizedDescription)"
        }
    }

    /// The rating from "How did you like it?" (1–10), for this show and its unscored seasons.
    func rate(_ media: Media, _ value: Int) async -> Bool {
        do {
            let status = entry(for: media.id)?.status ?? .COMPLETED
            try await save(media: media, status: status, progress: nil, scoreRaw: value * 10)
            updateOtherSeasons(of: media, .scored(value * 10))
            return true
        } catch {
            model?.errorMessage = "Couldn't save the score on AniList: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: Whole show (AniReco): AniList keeps one entry per season; the app treats a show as one.

    enum ShowChange: Equatable { case planned, watched, removed, scored(Int) }

    private func otherSeasons(of media: Media) async -> [Media] {
        guard media.isSeason else { return [] }
        let chain = await SeasonChain.shared.seasons(for: media, client: client)
        return chain.filter { $0.id != media.id && $0.isSeason && Seasons.sameShow(media.title, $0.title) }
    }

    func updateOtherSeasons(of media: Media, _ change: ShowChange) {
        guard isLoggedIn else { return }
        let previous = showSyncTask
        let account = viewer?.id
        showSyncTask = Task {
            await previous?.value
            guard viewer?.id == account else { return }
            let seasons = await otherSeasons(of: media)
            var failed = false
            var written: [(EntryLite, Media, ListStatus)] = []
            var removed: Set<Int> = []
            func write(_ season: Media, _ status: ListStatus, progress: Int?, score: Int?) async throws {
                let saved = try await self.writeEntry(media: season, status: status, progress: progress, scoreRaw: score)
                written.append((saved, season, status))
            }
            var removedEntries: [Int: ListEntry] = [:]
            if change == .removed {
                for season in seasons { if let e = entry(for: season.id) { removedEntries[season.id] = e } }
                let ids = Set(removedEntries.values.map(\.id))
                if !ids.isEmpty { entries.removeAll { ids.contains($0.id) } }
            }
            for season in seasons {
                guard viewer?.id == account, !Task.isCancelled else { break }
                let current = entry(for: season.id) ?? removedEntries[season.id]
                do {
                    var wrote = true
                    switch change {
                    case .planned:
                        if current == nil { try await write(season, .PLANNING, progress: nil, score: nil) } else { wrote = false }
                    case .watched:
                        if current?.status == .COMPLETED { wrote = false; break }
                        switch season.status {
                        case "NOT_YET_RELEASED":
                            if current == nil { try await write(season, .PLANNING, progress: nil, score: nil) } else { wrote = false }
                        case "RELEASING":
                            let aired = season.availableEpisodes ?? current?.progress
                            try await write(season, .CURRENT, progress: max(aired ?? 0, current?.progressValue ?? 0), score: nil)
                        default:
                            try await write(season, .COMPLETED, progress: season.episodes ?? current?.progress, score: nil)
                        }
                    case .removed:
                        if let current {
                            _ = try await client.run(Queries.deleteEntry, variables: ["id": current.id], as: DeleteEntryData.self)
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
                model?.errorMessage = "Couldn't update every season of \(media.displayTitle(language)) on AniList. Try again in a moment."
            }
        }
    }

    // MARK: "Not for me", synced through AniList (as in AniReco)
    //
    // Each dismissed show becomes a private AniList entry (visible only to you, never on your
    // followers' feed), hidden from your status lists, in a custom list named "Not for me".
    // It's read back on every refresh, so it's the same in AniReco and on every device.

    static let notForMeList = "Not for me"

    /// mediaId → AniList entry id of synced "Not for me" shows.
    @ObservationIgnored private var notForMeEntries: [Int: Int] = [:]
    /// Dismissed here but not uploaded yet (offline, or just tapped).
    @ObservationIgnored private var pendingNotForMe: Set<Int> = []
    @ObservationIgnored private var notForMeSync: Task<Void, Never>?
    @ObservationIgnored private var notForMeLoadedFor: Int?
    @ObservationIgnored private var notForMeListReady = false

    private var notForMeKey: String { "anilist-notForMe-\(viewer?.id ?? 0)" }

    func isDismissed(_ mediaId: Int) -> Bool { dismissed.contains(mediaId) }

    /// "Not for me" on a pick: off every feed now, onto AniList's private list in the background.
    func dismiss(_ media: Media) {
        ensureNotForMeLoaded()
        notForMeMedia[media.id] = notForMeMedia[media.id] ?? media
        dismissed.insert(media.id)
        if notForMeEntries[media.id] == nil {
            pendingNotForMe.insert(media.id)
            saveNotForMeState()
            syncNotForMe()
        } else {
            saveNotForMeState()
        }
        removeFromFeeds(media.id)
    }

    /// Brings one show back: it can be picked again (and leaves AniList's "Not for me" list).
    func undoNotForMe(_ mediaId: Int) async {
        ensureNotForMeLoaded()
        dismissed.remove(mediaId)
        pendingNotForMe.remove(mediaId)
        saveNotForMeState()
        guard let entryId = notForMeEntries[mediaId] else { return }
        do {
            _ = try await client.run(Queries.deleteEntry, variables: ["id": entryId], as: DeleteEntryData.self)
            notForMeEntries[mediaId] = nil
            saveNotForMeState()
        } catch {
            dismissed.insert(mediaId)   // still on AniList: keep it consistent
            saveNotForMeState()
            model?.errorMessage = "Couldn't update AniList. Try again in a moment."
        }
    }

    /// The "Not for me" shows, newest knowledge first (for the Not for me screen).
    var notForMeTitles: [Media] {
        dismissed.compactMap { notForMeMedia[$0] }.sorted { $0.id > $1.id }
    }

    private func ensureNotForMeLoaded() {
        guard let id = viewer?.id, notForMeLoadedFor != id else { return }
        notForMeLoadedFor = id
        let stored = defaults.dictionary(forKey: notForMeKey + "-entries") as? [String: Int] ?? [:]
        notForMeEntries = Dictionary(stored.compactMap { k, v in Int(k).map { ($0, v) } }, uniquingKeysWith: { a, _ in a })
        pendingNotForMe = Set(defaults.array(forKey: notForMeKey + "-pending") as? [Int] ?? [])
        dismissed = Set(notForMeEntries.keys).union(pendingNotForMe)
        if let saved = DiskCache.load([Int: Media].self, name: cacheName("notforme")) {
            notForMeMedia.merge(saved) { current, _ in current }
        }
    }

    private func saveNotForMeState() {
        guard viewer != nil, notForMeLoadedFor == viewer?.id else { return }
        defaults.set(Dictionary(uniqueKeysWithValues: notForMeEntries.map { (String($0.key), $0.value) }),
                     forKey: notForMeKey + "-entries")
        defaults.set(Array(pendingNotForMe), forKey: notForMeKey + "-pending")
        let shown = notForMeMedia.filter { dismissed.contains($0.key) }
        DiskCache.saveInBackground(shown, name: cacheName("notforme"))
    }

    /// AniList is the source of truth; shows dismissed here but not uploaded yet are kept and sent.
    private func mergeNotForMe(remote: [Int: Int]) {
        ensureNotForMeLoaded()
        pendingNotForMe.subtract(remote.keys)
        pendingNotForMe = pendingNotForMe.filter { entry(for: $0) == nil }
        notForMeEntries = remote
        dismissed = Set(remote.keys).union(pendingNotForMe)
        saveNotForMeState()
        syncNotForMe()
    }

    /// Uploads pending dismissals one by one, gently. Safe to call any time.
    private func syncNotForMe() {
        guard isLoggedIn, !pendingNotForMe.isEmpty, notForMeSync == nil else { return }
        notForMeSync = Task {
            defer { notForMeSync = nil }
            guard await ensureNotForMeListExists() else { return }
            var first = true
            while let mediaId = pendingNotForMe.first {
                if !first { try? await Task.sleep(nanoseconds: Self.writeSpacing) }
                first = false
                if Task.isCancelled { break }
                // Added to your list meanwhile: it's not a dismissal any more.
                if entry(for: mediaId) != nil || !dismissed.contains(mediaId) {
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

    /// Adds "Not for me" to your AniList custom lists, keeping every list you already have.
    private func ensureNotForMeListExists() async -> Bool {
        if notForMeListReady { return true }
        guard let data = try? await client.run(Queries.listOptions, as: ListOptionsData.self),
              let current = data.viewer?.mediaListOptions?.animeList?.customLists else {
            return false   // couldn't read your lists: never risk overwriting them
        }
        if current.contains(Self.notForMeList) { notForMeListReady = true; return true }
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

    // MARK: Details

    /// AniList's page for a show (its fan recommendations feed "More like this").
    func detail(id: Int) async throws -> MediaDetail {
        try await client.run(Queries.detail, variables: ["id": id], as: MediaDetailData.self).media
    }

    /// "More like this": AniList's fan recommendations, minus anything on your list, dismissed or
    /// on your server. Later seasons shown as their first season.
    func moreLike(_ mediaId: Int) async -> [Media] {
        guard let d = try? await detail(id: mediaId) else { return [] }
        let recs = (d.recommendations?.nodes ?? []).compactMap(\.mediaRecommendation)
        let collapsed = await SeasonRoots.collapse(recs, client: client)
        let owned = ownedIndex()
        let hideChinese = model?.settings.anilistHideChinese ?? true
        return collapsed.filter { m in
            m.id != mediaId && entry(for: m.id) == nil && !franchises.contains(m) && !dismissed.contains(m.id)
                && m.isAdult != true && !(hideChinese && m.countryOfOrigin == "CN") && !owned.contains(m)
        }
    }

    /// One show by AniList id (for a title that came without its full details).
    func media(id: Int) async -> Media? {
        if let e = entry(for: id) { return e.media }
        if let m = notForMeMedia[id] { return m }
        if let m = feeds.values.lazy.flatMap(\.picks).first(where: { $0.id == id })?.media { return m }
        return try? await client.run(Queries.mediaByIds, variables: ["ids": [id], "perPage": 1], as: PageData.self).page.media.first
    }

    /// Best AniList match for a TMDB anime (moving old My List / Not for me entries over).
    /// nil: AniList doesn't know it; throws when AniList couldn't be asked.
    func find(_ t: ExternalTitle) async throws -> Media? {
        let vars: [String: Any] = ["page": 1, "perPage": 10, "search": t.title, "sort": ["SEARCH_MATCH"]]
        let data = try await client.run(Queries.browse, variables: vars, as: PageData.self)
        let key = TitleKey.make(t.title)
        let original = t.originalTitle.map(TitleKey.make)
        let candidates = data.page.media.filter { $0.isMovie == t.isMovie && $0.format != "MUSIC" }
        func yearOK(_ m: Media) -> Bool {
            guard let a = t.year, let b = m.seasonYear else { return true }
            return abs(a - b) <= 1
        }
        // Same name (any of its titles) and year first, then the top search hit of the right kind and year.
        if let exact = candidates.first(where: { m in
            yearOK(m) && m.allTitles.contains { let k = TitleKey.make($0); return k == key || k == original }
        }) { return exact }
        return candidates.first(where: yearOK)
    }
}

/// AniList's implicit-grant login (as in AniReco, with JellyReco's own redirect URL).
enum AniListAuth {
    /// Must match the redirect URL of your AniList API client (anilist.co/settings/developer).
    static let callbackScheme = "jellyreco"
    static let redirectURL = "jellyreco://auth"

    static func authorizeURL(clientId: String) -> URL? {
        let trimmed = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, Int(trimmed) != nil else { return nil }
        return URL(string: "https://anilist.co/api/v2/oauth/authorize?client_id=\(trimmed)&response_type=token")
    }

    /// Pulls access_token out of jellyreco://auth#access_token=...&token_type=Bearer&expires_in=...
    static func token(from url: URL) -> String? {
        let raw = url.fragment ?? url.query ?? ""
        for pair in raw.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2, parts[0] == "access_token" { return parts[1].removingPercentEncoding ?? parts[1] }
        }
        return nil
    }
}
