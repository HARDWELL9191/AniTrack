import Foundation
import Observation

@Observable
@MainActor
final class AppModel {
    let client = AniListClient()
    let settings = AppSettings()

    private(set) var mode: AccountMode = .none
    private(set) var viewer: Viewer?
    private(set) var entries: [ListEntry] = []
    private(set) var isLoadingList = false
    private(set) var didBootstrap = false
    var errorMessage: String?

    // Recommendations ("Hoshi" picks)
    private(set) var recommendations: RecommendationResult?
    private(set) var isLoadingRecommendations = false
    var recommendationError: String?

    private let defaults = UserDefaults.standard
    private static let tokenKey = "anilistToken"

    var canEdit: Bool { mode == .loggedIn }

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
        loadCachedList()
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
        recommendations = nil
        await reloadAll()
    }

    func useUsername(_ name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        defaults.set(trimmed, forKey: "readOnlyUsername")
        mode = .username(trimmed)
        recommendations = nil
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
        recommendations = nil
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
            DiskCache.save(result, name: cacheName("list"))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Shows the last saved list instantly (and offline) while the network refresh runs.
    private func loadCachedList() {
        guard entries.isEmpty, viewer != nil,
              let cached = DiskCache.load([ListEntry].self, name: cacheName("list")) else { return }
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
        entries.first { $0.mediaId == mediaId }
    }

    func entries(in statuses: [ListStatus]) -> [ListEntry] {
        entries.filter { statuses.contains($0.status) }
            .sorted { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }
    }

    func count(of status: ListStatus) -> Int {
        entries.filter { $0.status == status }.count
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
                page: Int = 1,
                perPage: Int = 25) async throws -> [Media] {
        var vars: [String: Any] = ["page": page, "perPage": perPage, "sort": sort, "isAdult": false]
        if let search, !search.isEmpty { vars["search"] = search }
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

    private var recommendationOptions: Recommender.Options {
        Recommender.Options(hideChinese: settings.hideChinese,
                            includeUnreleased: settings.includeUnreleased,
                            dismissed: settings.dismissedPicks,
                            titleLanguage: settings.titleLanguage,
                            useOnDeviceAI: settings.useOnDeviceAI)
    }

    /// Battery-friendly: reuses saved picks unless your list changed or they're over 3 days old.
    func generateRecommendations(force: Bool = false) async {
        guard !isLoadingRecommendations else { return }
        guard !entries.isEmpty else {
            recommendationError = "Your list is empty. Add and rate a few shows first."
            return
        }
        let fingerprint = Recommender.fingerprint(entries: entries, options: recommendationOptions)
        if !force {
            if recommendations == nil { recommendations = DiskCache.load(RecommendationResult.self, name: cacheName("picks")) }
            if let current = recommendations,
               current.fingerprint == fingerprint,
               Date().timeIntervalSince(current.generatedAt) < 3 * 86_400 {
                return
            }
        }
        isLoadingRecommendations = true
        recommendationError = nil
        defer { isLoadingRecommendations = false }
        do {
            let result = try await Recommender.run(entries: entries, client: client, options: recommendationOptions)
            recommendations = result
            DiskCache.save(result, name: cacheName("picks"))
        } catch {
            recommendationError = error.localizedDescription
        }
    }

    func dismissPick(_ mediaId: Int) {
        settings.dismissedPicks.insert(mediaId)
        recommendations?.remove(mediaId)
        if var saved = recommendations {
            // Keep the cached picks valid after a dismissal instead of forcing a full rebuild.
            saved.fingerprint = Recommender.fingerprint(entries: entries, options: recommendationOptions)
            recommendations = saved
            DiskCache.save(saved, name: cacheName("picks"))
        }
    }

    private func cacheName(_ kind: String) -> String {
        "\(kind)-\(viewer?.id ?? 0)"
    }

    func resetDismissedPicks() {
        settings.dismissedPicks = []
        recommendations = nil
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
