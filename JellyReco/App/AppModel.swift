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
    let discovery = DiscoveryEngine()

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
    /// For You titles (from TMDB, not on the server): want to get / already seen elsewhere /
    /// not for me. Saved on the server like My List.
    private(set) var wishlist: [ExternalTitle] = []
    private(set) var externalSeen: [ExternalTitle] = []
    private(set) var externalNotForMe: [ExternalTitle] = []
    var externalHidden: Set<String> {
        Set(wishlist.map(\.id)).union(externalSeen.map(\.id)).union(externalNotForMe.map(\.id))
    }
    @ObservationIgnored private var storage: DisplayPreferencesDto?

    var isAdmin: Bool { user?.policy?.isAdministrator ?? false }
    /// Read-only access for the AI engines (GET requests only).
    var reader: LibraryReader? { client.map(LibraryReader.init) }
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
        discovery.attach(model: self)
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
            await loadAccountStorage()
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
        discovery.attach(model: self)
        reco.reset()
        discovery.reset()
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
        storage = nil
        settings.dismissedPicks = []
        wishlist = []; externalSeen = []; externalNotForMe = []
        reco.reset()
        discovery.reset()
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
        wishlist = []; externalSeen = []; externalNotForMe = []
        storage = nil
        reco.reset()
        discovery.reset()
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

    // MARK: Account storage on the server (For You lists, synced settings)

    /// For You lists and synced settings, from this account's storage on the server.
    func loadAccountStorage() async {
        guard let client else { return }
        if let prefs = try? await client.loadAppStorage() {
            storage = prefs
            wishlist = Self.decodeTitles(prefs.customPrefs?["wishlist"] ?? nil)
            externalSeen = Self.decodeTitles(prefs.customPrefs?["seenelsewhere"] ?? nil)
            externalNotForMe = Self.decodeTitles(prefs.customPrefs?["notforme"] ?? nil)
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


    // MARK: For You lists (TMDB titles) — saved on the server

    enum ExternalList: String { case wishlist, seenelsewhere, notforme }

    private static func decodeTitles(_ json: String?) -> [ExternalTitle] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([ExternalTitle].self, from: data)) ?? []
    }

    private static func encodeTitles(_ list: [ExternalTitle]) -> String {
        // Overviews trimmed so the stored lists stay small.
        let slim = list.prefix(500).map { t -> ExternalTitle in
            var c = t
            c.overview = String(t.overview.prefix(400))
            c.tags = Array(t.tags.prefix(8))
            return c
        }
        return String(data: (try? JSONEncoder().encode(Array(slim))) ?? Data(), encoding: .utf8) ?? "[]"
    }

    func isOnWishlist(_ t: ExternalTitle) -> Bool { wishlist.contains { $0.id == t.id } }

    func toggleWishlist(_ t: ExternalTitle) async {
        if isOnWishlist(t) { wishlist.removeAll { $0.id == t.id } } else { wishlist.insert(t, at: 0) }
        await saveExternal(.wishlist)
    }

    func markSeenElsewhere(_ t: ExternalTitle) async {
        externalSeen.removeAll { $0.id == t.id }
        externalSeen.insert(t, at: 0)
        wishlist.removeAll { $0.id == t.id }
        await saveExternal(.seenelsewhere)
        await saveExternal(.wishlist)
    }

    func markExternalNotForMe(_ t: ExternalTitle, _ on: Bool = true) async {
        externalNotForMe.removeAll { $0.id == t.id }
        if on {
            externalNotForMe.insert(t, at: 0)
            wishlist.removeAll { $0.id == t.id }
            await saveExternal(.wishlist)
        }
        await saveExternal(.notforme)
    }

    func clearExternal(_ list: ExternalList) async {
        switch list {
        case .wishlist: wishlist = []
        case .seenelsewhere: externalSeen = []
        case .notforme: externalNotForMe = []
        }
        await saveExternal(list)
    }

    private func saveExternal(_ list: ExternalList) async {
        let value: [ExternalTitle]
        switch list {
        case .wishlist: value = wishlist
        case .seenelsewhere: value = externalSeen
        case .notforme: value = externalNotForMe
        }
        let json = Self.encodeTitles(value)
        await saveStorage { custom in custom[list.rawValue] = json }
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

    }

    // MARK: Playback

    func play(_ item: BaseItem, from start: Double? = nil, audio: Int? = nil, subtitle: Int? = nil,
              mediaSourceId: String? = nil) {
        Task {
            var target = item
            // A plain folder plays its first video (in name order).
            if item.isFolder == true && ![.series, .season, .boxSet].contains(item.kind), let client {
                var q = JellyfinClient.ItemQuery()
                q.parentId = item.id
                q.recursive = true
                q.sortBy = ["SortName"]
                q.mediaTypesVideo = true
                q.limit = 1
                guard let first = try? await client.items(q).items?.first else {
                    errorMessage = "There's no video in this folder."
                    return
                }
                target = first
            }
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
