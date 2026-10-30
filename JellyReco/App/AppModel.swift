import Foundation
import Observation
import SwiftUI

enum AppPhase: Equatable {
    case launching
    case signedOut
    case ready
}

enum AppTab: Hashable {
    case home, forYou, library, search, settings
}

/// What the player is asked to play: an item plus where to start and which tracks.
struct PlaybackRequest: Identifiable, Equatable {
    let id = UUID()
    var item: BaseItem
    var startSeconds: Double? = nil       // nil = resume point (or the start)
    var mediaSourceId: String? = nil
    var audioIndex: Int? = nil
    var subtitleIndex: Int? = nil
    /// Episodes after this one, for autoplay / "next episode".
    var queue: [BaseItem] = []
    static func == (a: PlaybackRequest, b: PlaybackRequest) -> Bool { a.id == b.id }
}

@Observable
@MainActor
final class AppModel {
    let settings = AppSettings()
    let store = ServerStore()
    let reco = RecoEngine()

    var phase: AppPhase = .launching
    var selectedTab: AppTab = .home
    private(set) var client: JellyfinClient?
    private(set) var user: UserDto?
    private(set) var serverInfo: SystemInfo?
    private(set) var libraries: [BaseItem] = []
    var errorMessage: String?
    var playback: PlaybackRequest?
    var isLocked = false

    /// Played/favorite changes made in this session, applied over any item the app shows,
    /// so a tick set on one screen shows everywhere straight away.
    private(set) var userDataOverrides: [String: UserItemData] = [:]
    /// Bumped after playback or watched changes so shelves reload.
    private(set) var contentVersion = 0
    /// My List (plan to watch), newest first. Stored on the server in this user's private
    /// JellyReco storage, so it follows the account to every device and survives reinstalls.
    private(set) var watchlist: [String] = []
    @ObservationIgnored private var storage: DisplayPreferencesDto?

    var isAdmin: Bool { user?.policy?.isAdministrator ?? false }
    var serverName: String { store.currentServer?.name ?? serverInfo?.serverName ?? "Jellyfin" }

    // MARK: Launch

    func bootstrap() async {
        guard phase == .launching else { return }
        if settings.requireFaceID { isLocked = true }
        guard let server = store.currentServer, let user = store.currentUser,
              let url = server.url, let token = store.token(for: user) else {
            phase = .signedOut
            return
        }
        let client = JellyfinClient(baseURL: url, token: token, userId: user.id)
        self.client = client
        phase = .ready
        reco.attach(model: self)
        await refreshSession()
    }

    /// Re-validates the token, refreshes the user and libraries (works offline-tolerantly).
    func refreshSession() async {
        guard let client else { return }
        do {
            let me = try await client.me()
            user = me
            if let sid = store.currentServerId { store.updateUser(me, on: sid) }
            async let views = client.userViews()
            async let info = try? client.get("/System/Info", as: SystemInfo.self)
            libraries = (try? await views) ?? libraries
            serverInfo = await info
            await loadWatchlist()
            await client.reportCapabilities()
        } catch JellyfinError.http(401, _) {
            errorMessage = JellyfinError.http(401, nil).errorDescription
            signOutCurrentUser(revoke: false)
        } catch {
            // Server unreachable: try the other saved addresses (LAN ↔ remote) before giving up.
            if await switchToReachableAddress() { await refreshSession() }
        }
    }

    private func switchToReachableAddress() async -> Bool {
        guard let server = store.currentServer, server.urls.count > 1, let token = client?.token,
              let userId = client?.userId else { return false }
        for candidate in server.urls.dropFirst() {
            guard let url = URL(string: candidate) else { continue }
            let probe = JellyfinClient(baseURL: url)
            if (try? await probe.publicInfo()) != nil {
                var urls = server.urls
                urls.removeAll { $0 == candidate }
                urls.insert(candidate, at: 0)
                store.setURLs(urls, for: server.id)
                client = JellyfinClient(baseURL: url, token: token, userId: userId)
                return true
            }
        }
        return false
    }

    // MARK: Sign-in

    func signIn(server info: PublicSystemInfo, url: URL, result: AuthenticationResult) {
        guard let user = result.user, let token = result.accessToken else {
            errorMessage = "The server didn't return a session."
            return
        }
        let saved = store.upsert(server: info, url: url)
        store.addUser(user, token: token, to: saved.id)
        client = JellyfinClient(baseURL: url, token: token, userId: user.id)
        self.user = user
        userDataOverrides = [:]
        libraries = []
        phase = .ready
        selectedTab = .home
        reco.attach(model: self)
        reco.reset()
        Task { await refreshSession() }
    }

    func switchTo(server: SavedServer, user: SavedUser) {
        guard let url = server.url, let token = store.token(for: user) else {
            errorMessage = "Sign in to \(server.name) again."
            return
        }
        store.currentServerId = server.id
        store.currentUserId = user.id
        client = JellyfinClient(baseURL: url, token: token, userId: user.id)
        self.user = nil
        userDataOverrides = [:]
        libraries = []
        watchlist = []
        storage = nil
        settings.dismissedPicks = []
        reco.reset()
        phase = .ready
        selectedTab = .home
        contentVersion &+= 1
        Task { await refreshSession() }
    }

    func signOutCurrentUser(revoke: Bool = true) {
        let old = client
        if revoke { Task { await old?.logout() } }
        if let sid = store.currentServerId, let uid = store.currentUserId { store.removeUser(uid, from: sid) }
        client = nil
        user = nil
        libraries = []
        userDataOverrides = [:]
        watchlist = []
        storage = nil
        reco.reset()
        DiskCache.clearPersonal()
        // Another saved account on any server: switch to it; otherwise back to sign-in.
        if let server = store.servers.first(where: { !$0.users.isEmpty }), let next = server.users.first {
            switchTo(server: server, user: next)
        } else {
            phase = .signedOut
        }
    }

    func addAnotherAccount() {
        phase = .signedOut
    }

    // MARK: User data

    func userData(for item: BaseItem) -> UserItemData? {
        userDataOverrides[item.id] ?? item.userData
    }

    func isPlayed(_ item: BaseItem) -> Bool { userData(for: item)?.played ?? false }
    func isFavorite(_ item: BaseItem) -> Bool { userData(for: item)?.isFavorite ?? false }

    func togglePlayed(_ item: BaseItem) async {
        guard let client else { return }
        let target = !isPlayed(item)
        var optimistic = userData(for: item) ?? UserItemData()
        optimistic.played = target
        if target { optimistic.playbackPositionTicks = 0; optimistic.playedPercentage = nil }
        userDataOverrides[item.id] = optimistic
        do {
            let data = try await client.setPlayed(item.id, target)
            var merged = data
            merged.played = target
            userDataOverrides[item.id] = merged
            contentVersion &+= 1
            reco.listChanged()
            if target { await removeFromWatchlist([listId(item)]) }
        } catch {
            userDataOverrides[item.id] = item.userData
            errorMessage = error.localizedDescription
        }
    }

    func toggleFavorite(_ item: BaseItem) async {
        guard let client else { return }
        let target = !isFavorite(item)
        var optimistic = userData(for: item) ?? UserItemData()
        optimistic.isFavorite = target
        userDataOverrides[item.id] = optimistic
        do {
            var data = try await client.setFavorite(item.id, target)
            data.isFavorite = target
            if data.played == nil { data.played = optimistic.played }
            userDataOverrides[item.id] = data
            reco.listChanged()
        } catch {
            userDataOverrides[item.id] = item.userData
            errorMessage = error.localizedDescription
        }
    }

    // MARK: My List (plan to watch) — saved on the server

    /// My List and synced settings, from this account's storage on the server.
    func loadWatchlist() async {
        guard let client else { return }
        if let prefs = try? await client.loadAppStorage() {
            storage = prefs
            let raw = (prefs.customPrefs?["watchlist"] ?? nil) ?? ""
            watchlist = raw.split(separator: ",").map(String.init).filter { !$0.isEmpty }
            if let json = prefs.customPrefs?["settings"] ?? nil, !json.isEmpty {
                settings.importJSON(json)
            } else {
                scheduleSettingsSync()   // first device for this account: upload what's here
            }
        }
        settings.onChange = { [weak self] in self?.scheduleSettingsSync() }
    }

    @ObservationIgnored private var settingsSyncTask: Task<Void, Never>?

    /// Saves settings to the server a moment after the last change (one request per burst).
    func scheduleSettingsSync() {
        settingsSyncTask?.cancel()
        settingsSyncTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.saveStorage { custom in
                if let json = self?.settings.exportJSON() { custom["settings"] = json }
            }
        }
    }

    /// Read-modify-write of the account's JellyReco storage (keeps keys written by other devices).
    private func saveStorage(_ change: (inout [String: String?]) -> Void) async {
        guard let client else { return }
        var prefs = (try? await client.loadAppStorage()) ?? storage ?? DisplayPreferencesDto()
        var custom = prefs.customPrefs ?? [:]
        change(&custom)
        prefs.customPrefs = custom
        do {
            try await client.saveAppStorage(prefs)
            storage = prefs
        } catch {
            report(error)
        }
    }

    func isOnWatchlist(_ item: BaseItem) -> Bool { watchlist.contains(listId(item)) }

    /// Episodes and seasons go on the list as their show.
    private func listId(_ item: BaseItem) -> String {
        (item.kind == .episode || item.kind == .season) ? (item.seriesId ?? item.id) : item.id
    }

    func toggleWatchlist(_ item: BaseItem) async {
        let id = listId(item)
        if watchlist.contains(id) { await setWatchlist(watchlist.filter { $0 != id }) }
        else { await setWatchlist([id] + watchlist) }
    }

    func removeFromWatchlist(_ ids: [String]) async {
        let drop = Set(ids)
        guard watchlist.contains(where: drop.contains) else { return }
        await setWatchlist(watchlist.filter { !drop.contains($0) })
    }

    private func setWatchlist(_ new: [String]) async {
        guard let client else { return }
        let old = watchlist
        watchlist = new
        reco.listChanged()
        guard (try? await client.loadAppStorage()) != nil || storage != nil else {
            watchlist = old
            errorMessage = "Couldn't reach your server to save My List."
            return
        }
        await saveStorage { custom in custom["watchlist"] = new.prefix(2000).joined(separator: ",") }
    }

    // MARK: Not for me — Jellyfin's own thumbs-down, saved on the server

    func isNotForMe(_ item: BaseItem) -> Bool {
        settings.dismissedPicks.contains(item.id) || userData(for: item)?.likes == false
    }

    func setNotForMe(_ item: BaseItem, _ on: Bool) async {
        guard let client else { return }
        if on { settings.dismissedPicks.insert(item.id) } else { settings.dismissedPicks.remove(item.id) }
        var data = userData(for: item) ?? UserItemData()
        data.likes = on ? false : nil
        userDataOverrides[item.id] = data
        reco.listChanged()
        do {
            var saved = try await client.setLikes(item.id, on ? false : nil)
            saved.likes = on ? false : nil
            userDataOverrides[item.id] = saved
            if on { await removeFromWatchlist([item.id]) }
        } catch {
            report(error)
        }
    }

    /// Clears every thumbs-down this account has, on the server too.
    func resetNotForMe() async {
        guard let client else { return }
        var q = JellyfinClient.ItemQuery()
        q.filters = ["Dislikes"]
        q.includeItemTypes = [.movie, .series]
        q.limit = 2000
        let disliked = (try? await client.items(q).items) ?? []
        for item in disliked {
            _ = try? await client.setLikes(item.id, nil)
            var data = userData(for: item) ?? UserItemData()
            data.likes = nil
            userDataOverrides[item.id] = data
        }
        settings.dismissedPicks = []
        reco.listChanged()
    }

    /// After playback: forget overrides for what was played so fresh server data shows.
    func playbackEnded(itemIds: [String]) {
        for id in itemIds { userDataOverrides[id] = nil }
        contentVersion &+= 1
        reco.listChanged()
        // Finished titles leave My List (checked against fresh server data).
        Task {
            guard let client, !watchlist.isEmpty else { return }
            var q = JellyfinClient.ItemQuery()
            q.ids = watchlist
            q.filters = ["IsPlayed"]
            q.limit = 500
            let done = (try? await client.items(q).items)?.map(\.id) ?? []
            await removeFromWatchlist(done)
        }
    }

    // MARK: Playback

    func play(_ item: BaseItem, from start: Double? = nil, audio: Int? = nil, subtitle: Int? = nil,
              mediaSourceId: String? = nil) {
        Task {
            var target = item
            // A series/season plays its next-up (or first) episode.
            if item.kind == .series || item.kind == .season {
                guard let ep = await nextEpisode(for: item) else {
                    errorMessage = "Nothing to play here yet."
                    return
                }
                target = ep
            }
            var queue: [BaseItem] = []
            if target.kind == .episode { queue = await episodesAfter(target) }
            playback = PlaybackRequest(item: target, startSeconds: start, mediaSourceId: mediaSourceId,
                                       audioIndex: audio, subtitleIndex: subtitle, queue: queue)
        }
    }

    private func nextEpisode(for item: BaseItem) async -> BaseItem? {
        guard let client else { return nil }
        let seriesId = item.kind == .series ? item.id : (item.seriesId ?? item.parentId ?? item.id)
        if item.kind == .series, let up = try? await client.nextUp(seriesId: seriesId, limit: 1, enableRewatching: true).first {
            return up
        }
        let eps = (try? await client.episodes(seriesId: seriesId, seasonId: item.kind == .season ? item.id : nil)) ?? []
        return eps.first { !($0.userData?.played ?? false) } ?? eps.first
    }

    func episodesAfter(_ episode: BaseItem) async -> [BaseItem] {
        guard let client, let sid = episode.seriesId else { return [] }
        let all = (try? await client.episodes(seriesId: sid)) ?? []
        guard let index = all.firstIndex(where: { $0.id == episode.id }) else { return [] }
        return Array(all[(index + 1)...].filter { $0.locationType != "Virtual" }.prefix(50))
    }

    // MARK: Helpers

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let url = error as? URLError, url.code == .cancelled { return true }
        return false
    }

    func report(_ error: Error) {
        guard !Self.isCancellation(error) else { return }
        errorMessage = error.localizedDescription
    }

    /// Libraries of the given collection types (movies, tvshows, …).
    func libraries(of types: Set<String>) -> [BaseItem] {
        libraries.filter { types.contains($0.collectionType ?? "") }
    }

    var videoLibraries: [BaseItem] {
        libraries.filter { ["movies", "tvshows", "homevideos", "musicvideos", "boxsets", "mixed", ""].contains($0.collectionType ?? "") }
    }

    var hasLiveTV: Bool { libraries.contains { $0.collectionType == "livetv" } }

    func bumpContent() { contentVersion &+= 1 }
}
