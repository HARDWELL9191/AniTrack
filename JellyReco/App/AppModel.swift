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
    /// "More like this" opened from any card's long-press menu (one sheet for the whole app).
    var moreLikeItem: BaseItem?
    var isLocked = false

    /// Played/favorite changes made in this session, applied over any item the app shows,
    /// so a tick set on one screen shows everywhere straight away.
    private(set) var userDataOverrides: [String: UserItemData] = [:]
    /// Bumped after playback or watched changes so shelves reload.
    private(set) var contentVersion = 0
    /// My List: anything you want to watch — titles on your server and For You picks that
    /// aren't on it yet — newest first. Saved in your account's JellyReco storage on the server.
    private(set) var myList: [MyListEntry] = [] { didSet { updateHidden() } }
    /// For You picks you said you've already seen elsewhere / don't want.
    private(set) var externalSeen: [ExternalTitle] = [] { didSet { updateHidden() } }
    private(set) var externalNotForMe: [ExternalTitle] = [] { didSet { updateHidden() } }
    /// For You never shows these again. Kept up to date when the lists change (it used to be
    /// rebuilt on every read, which For You and "More like this" do once per title).
    private(set) var externalHidden: Set<String> = []
    private func updateHidden() {
        externalHidden = Set(myList.compactMap { $0.external?.id }).union(externalSeen.map(\.id)).union(externalNotForMe.map(\.id))
    }
    @ObservationIgnored private var storage: DisplayPreferencesDto?

    /// The engines read your settings and library through this model. Connected once, here,
    /// so no sign-in route (password, Quick Connect, saved account, account switch) can leave
    /// For You unable to see your TMDB key.
    init() {
        reco.attach(model: self)
        discovery.attach(model: self)
        // Installed here (not after the server answers) so a saved key always starts For You.
        settings.onTMDBKeyChange = { [weak self] in
            guard let self else { return }
            self.markDirty("tmdbkey")
            self.discovery.keyChanged()
        }
    }

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

    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    /// Re-validates the token, refreshes the user and libraries (works offline-tolerantly).
    /// One refresh at a time: a caller that comes while one is running (Home's first load right
    /// after launch / sign-in, pull-to-refresh) waits for that one instead of starting a second.
    func refreshSession() async {
        if let running = refreshTask { await running.value; return }
        let task = Task { await self.performRefresh(triedOtherAddresses: false) }
        refreshTask = task
        await task.value
        if refreshTask == task { refreshTask = nil }
    }

    private func performRefresh(triedOtherAddresses: Bool) async {
        guard let client else { return }
        do {
            let me = try await client.me()
            guard client === self.client else { return }   // the account changed meanwhile
            user = me
            // Autoplay of the next episode is a Jellyfin account setting: follow it.
            if let auto = me.configuration?.enableNextEpisodeAutoPlay, settings.autoPlayNext != auto {
                settings.autoPlayNext = auto
            }
            if let sid = store.currentServerId { store.updateUser(me, on: sid) }
            async let views = client.userViews()
            async let info = try? client.get("/System/Info", as: SystemInfo.self)
            let fetchedViews = try? await views
            let fetchedInfo = await info
            guard client === self.client else { return }
            libraries = fetchedViews ?? libraries
            serverInfo = fetchedInfo
            await loadAccountStorage()
            await client.reportCapabilities()
        } catch JellyfinError.http(401, _) {
            guard client === self.client else { return }
            errorMessage = JellyfinError.http(401, nil).errorDescription
            signOutCurrentUser(revoke: false)
        } catch {
            // Server unreachable: try the other saved addresses (LAN ↔ remote), once, before giving
            // up. Only for network errors: a server that answers with an error (500, bad data) at
            // every address would otherwise be switched back and forth forever.
            guard !triedOtherAddresses, error is URLError, client === self.client else { return }
            if await switchToReachableAddress() { await performRefresh(triedOtherAddresses: true) }
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
        resetAccountState()
        client = JellyfinClient(baseURL: url, token: token, userId: user.id)
        self.user = user
        phase = .ready
        selectedTab = .home
        reco.attach(model: self)
        discovery.attach(model: self)
        Task { await refreshSession() }
    }

    func switchTo(server: SavedServer, user: SavedUser) {
        guard let url = server.url, let token = store.token(for: user) else {
            errorMessage = "Sign in to \(server.name) again."
            return
        }
        store.currentServerId = server.id
        store.currentUserId = user.id
        resetAccountState()
        client = JellyfinClient(baseURL: url, token: token, userId: user.id)
        self.user = nil
        phase = .ready
        selectedTab = .home
        Task { await refreshSession() }
    }

    func signOutCurrentUser(revoke: Bool = true) {
        let old = client
        if revoke { Task { await old?.logout() } }
        if let sid = store.currentServerId, let uid = store.currentUserId { store.removeUser(uid, from: sid) }
        resetAccountState()
        client = nil
        user = nil
        DiskCache.clearPersonal()
        // Another saved account on any server: switch to it; otherwise back to sign-in.
        if let server = store.servers.first(where: { !$0.users.isEmpty }), let next = server.users.first {
            switchTo(server: server, user: next)
        } else {
            phase = .signedOut
        }
    }

    /// Removing a saved server or account also signs those sessions out on the server (they used
    /// to stay valid there, listed under Devices).
    func removeSavedServer(_ server: SavedServer) {
        let wasCurrent = server.id == store.currentServerId
        revoke(server.users, on: server)
        store.removeServer(server.id)
        if wasCurrent { signOutCurrentUser(revoke: false) }
    }

    func removeSavedUser(_ user: SavedUser, from server: SavedServer) {
        if server.id == store.currentServerId && user.id == store.currentUserId {
            signOutCurrentUser(revoke: true)
            return
        }
        revoke([user], on: server)
        store.removeUser(user.id, from: server.id)
    }

    private func revoke(_ users: [SavedUser], on server: SavedServer) {
        guard let url = server.url else { return }
        let sessions = users.compactMap { u in store.token(for: u).map { JellyfinClient(baseURL: url, token: $0, userId: u.id) } }
        Task { for c in sessions { await c.logout() } }
    }

    func addAnotherAccount() {
        phase = .signedOut
    }

    /// Everything that belongs to the signed-in account, cleared on every account change (sign in,
    /// switch, sign out), so a new account never shows (or saves into its storage) the previous
    /// account's My List, Not for me, hidden picks or a half-finished save.
    private func resetAccountState() {
        refreshTask?.cancel(); refreshTask = nil
        flushTask?.cancel(); flushTask = nil
        settingsSyncTask?.cancel(); settingsSyncTask = nil
        playback = nil
        user = nil
        libraries = []
        userDataOverrides = [:]
        storage = nil
        storageLoaded = false
        dirty = [:]
        myList = []; externalSeen = []; externalNotForMe = []
        settings.dismissedPicks = []
        reco.reset()
        discovery.reset()
        contentVersion &+= 1
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
            // A finished movie / show leaves My List. Not an episode or season: those stand for their
            // show on the list, and ticking one episode mustn't remove the whole show.
            if target, [.movie, .series, .video].contains(item.kind), isOnMyList(item) { await toggleMyList(item) }
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

    /// The first load of this account's storage succeeded. Until then nothing is written: a save
    /// before it would replace the server's lists with whatever (little) this device has.
    @ObservationIgnored private var storageLoaded = false
    /// Keys changed here and not saved yet, with a counter per change (a change made while a save
    /// is on its way stays pending for the next one).
    @ObservationIgnored private var dirty: [String: Int] = [:]
    @ObservationIgnored private var flushTask: Task<Void, Never>?

    /// For You lists and synced settings, from this account's storage on the server.
    /// A key with an unsaved change here keeps this device's value (it's the newer one).
    func loadAccountStorage() async {
        guard let client else { return }
        if let prefs = try? await client.loadAppStorage(), client === self.client {
            storage = prefs
            let custom = prefs.customPrefs ?? [:]
            let firstLoad = !storageLoaded
            func value(_ key: String) -> String? { custom[key] ?? nil }

            let serverList = Self.decodeList(value("mylist"))
            if dirty["mylist"] == nil {
                myList = serverList
            } else if firstLoad {
                // Added here before the server answered: keep those, on top of the server's list.
                let ids = Set(myList.map(\.id))
                myList = myList + serverList.filter { !ids.contains($0.id) }
            }
            // Older builds kept For You picks in a separate "wishlist": fold them into My List.
            let legacy = Self.decodeTitles(value("wishlist"))
            if !legacy.isEmpty {
                for t in legacy where !myList.contains(where: { $0.external?.id == t.id }) {
                    myList.append(MyListEntry(external: t))
                }
                markDirty("mylist", "wishlist")
            }
            for list in [ExternalList.seenelsewhere, .notforme] {
                let server = Self.decodeTitles(value(list.rawValue))
                let local = list == .seenelsewhere ? externalSeen : externalNotForMe
                let merged: [ExternalTitle]
                if dirty[list.rawValue] == nil { merged = server }
                else if firstLoad { let ids = Set(local.map(\.id)); merged = local + server.filter { !ids.contains($0.id) } }
                else { merged = local }
                if list == .seenelsewhere { externalSeen = merged } else { externalNotForMe = merged }
            }
            // TMDB key: the phone's copy and the server's copy keep each other filled in.
            let serverKey = (value("tmdbkey") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if settings.tmdbKey.isEmpty && !serverKey.isEmpty {
                settings.tmdbKey = serverKey
            } else if !settings.tmdbKey.isEmpty && serverKey != settings.tmdbKey {
                markDirty("tmdbkey")
            }
            // Settings: the server's copy, unless a change made here is still waiting to be saved
            // (importing then put the old values back, and the pending save uploaded them).
            if let json = value("settings"), !json.isEmpty {
                if dirty["settings"] == nil { settings.importJSON(json) }
            } else {
                markDirty("settings")   // first device for this account: upload what's here
            }
            storageLoaded = true
            scheduleFlush()   // anything changed before the first load can be saved now
        }
        settings.onChange = { [weak self] in self?.scheduleSettingsSync() }
    }

    @ObservationIgnored private var settingsSyncTask: Task<Void, Never>?

    /// Saves settings to the server a moment after the last change (one request per burst). The
    /// change counts as pending right away, so a refresh in between doesn't undo it.
    func scheduleSettingsSync() {
        dirty["settings", default: 0] += 1
        settingsSyncTask?.cancel()
        settingsSyncTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.scheduleFlush()
        }
    }

    /// Marks keys as changed and saves them (together with anything else pending) shortly.
    private func markDirty(_ keys: String...) {
        for k in keys { dirty[k, default: 0] += 1 }
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard flushTask == nil, storageLoaded, !dirty.isEmpty else { return }
        let token = UUID()
        flushToken = token
        flushTask = Task { [weak self] in
            await Task.yield()   // changes made in the same moment go in the same save
            await self?.flushStorage()
            // (A save cancelled by an account change mustn't clear the new account's save.)
            if self?.flushToken == token { self?.flushTask = nil }
        }
    }
    @ObservationIgnored private var flushToken: UUID?

    /// Saves the pending keys, one save at a time. Jellyfin replaces the whole stored record on
    /// every save, so each save starts from a fresh copy of it (keeping what other devices wrote)
    /// and puts in the current value of every pending key. If that copy can't be read, nothing is
    /// written (writing over an old or empty copy would erase the other keys); the keys stay
    /// pending and go with the next change or refresh.
    private func flushStorage() async {
        while storageLoaded, !dirty.isEmpty, let client {
            let pending = dirty
            guard let fresh = try? await client.loadAppStorage() else { return }
            guard client === self.client, storageLoaded else { return }
            var prefs = fresh
            var custom = prefs.customPrefs ?? [:]
            for key in pending.keys {
                if let v = currentValue(key) { custom[key] = .some(v) }
            }
            prefs.customPrefs = custom
            do {
                try await client.saveAppStorage(prefs)
                guard client === self.client else { return }
                storage = prefs
                for (key, n) in pending where dirty[key] == n { dirty[key] = nil }
            } catch {
                report(error)
                return
            }
        }
    }

    /// This device's current value for a stored key.
    private func currentValue(_ key: String) -> String? {
        switch key {
        case "mylist": return Self.encodeList(myList)
        case "notforme": return Self.encodeTitles(externalNotForMe)
        case "seenelsewhere": return Self.encodeTitles(externalSeen)
        case "settings": return settings.exportJSON()
        case "tmdbkey": return settings.tmdbKey
        case "wishlist": return "[]"
        default: return nil
        }
    }

    // MARK: My List & Not for me — saved on the server

    enum ExternalList: String { case seenelsewhere, notforme }

    /// One element that may fail to decode on its own (the rest of the list still loads).
    private struct Lossy<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }

    /// Element by element: one entry this build can't read (written by a newer app, or by the PC
    /// app) no longer makes the whole list come back empty, which the next save then stored.
    private static func decodeTitles(_ json: String?) -> [ExternalTitle] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        return ((try? JSONDecoder().decode([Lossy<ExternalTitle>].self, from: data)) ?? []).compactMap(\.value)
    }

    private static func slim(_ t: ExternalTitle) -> ExternalTitle {
        var c = t
        c.overview = String(t.overview.prefix(400))
        c.tags = Array(t.tags.prefix(8))
        return c
    }

    private static func encodeTitles(_ list: [ExternalTitle]) -> String {
        // Up to 1500 (was 500: the oldest Not for me titles silently dropped off and came back on
        // For You). The PC app keeps the same limit.
        let slimmed = list.prefix(1500).map(slim)
        return String(data: (try? JSONEncoder().encode(Array(slimmed))) ?? Data(), encoding: .utf8) ?? "[]"
    }

    private static func decodeList(_ json: String?) -> [MyListEntry] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        return ((try? JSONDecoder().decode([Lossy<MyListEntry>].self, from: data)) ?? []).compactMap(\.value)
    }

    private static func encodeList(_ list: [MyListEntry]) -> String {
        let slimmed = list.prefix(1000).map { e -> MyListEntry in
            var c = e
            c.external = e.external.map(slim)
            return c
        }
        return String(data: (try? JSONEncoder().encode(Array(slimmed))) ?? Data(), encoding: .utf8) ?? "[]"
    }

    /// Episodes and seasons go on My List as their show.
    private func listId(_ item: BaseItem) -> String {
        (item.kind == .episode || item.kind == .season) ? (item.seriesId ?? item.id) : item.id
    }

    func isOnMyList(_ item: BaseItem) -> Bool { myList.contains { $0.serverId == listId(item) } }
    func isOnMyList(_ t: ExternalTitle) -> Bool { myList.contains { $0.external?.id == t.id } }

    func toggleMyList(_ item: BaseItem) async {
        let id = listId(item)
        if let i = myList.firstIndex(where: { $0.serverId == id }) {
            myList.remove(at: i)
        } else {
            let name = (item.kind == .episode || item.kind == .season) ? (item.seriesName ?? item.displayName) : item.displayName
            myList.insert(MyListEntry(serverId: id, name: name), at: 0)
        }
        reco.listChanged()
        saveMyList()
    }

    func toggleMyList(_ t: ExternalTitle) async {
        if let i = myList.firstIndex(where: { $0.external?.id == t.id }) {
            myList.remove(at: i)
        } else {
            myList.insert(MyListEntry(external: t), at: 0)
            externalNotForMe.removeAll { $0.id == t.id }
            externalSeen.removeAll { $0.id == t.id }
            saveExternal(.notforme)
            saveExternal(.seenelsewhere)
        }
        saveMyList()
    }

    func removeFromMyList(_ entry: MyListEntry) async {
        myList.removeAll { $0.id == entry.id }
        reco.listChanged()
        saveMyList()
    }

    /// My List and the For You lists save together (one request per action, not three).
    private func saveMyList() { markDirty("mylist") }

    func markSeenElsewhere(_ t: ExternalTitle) async {
        externalSeen.removeAll { $0.id == t.id }
        externalSeen.insert(t, at: 0)
        if myList.contains(where: { $0.external?.id == t.id }) {
            myList.removeAll { $0.external?.id == t.id }
            saveMyList()
        }
        saveExternal(.seenelsewhere)
    }

    func markExternalNotForMe(_ t: ExternalTitle, _ on: Bool = true) async {
        externalNotForMe.removeAll { $0.id == t.id }
        if on {
            externalNotForMe.insert(t, at: 0)
            if myList.contains(where: { $0.external?.id == t.id }) {
                myList.removeAll { $0.external?.id == t.id }
                saveMyList()
            }
        }
        saveExternal(.notforme)
    }

    func unmarkSeen(_ t: ExternalTitle) async {
        externalSeen.removeAll { $0.id == t.id }
        saveExternal(.seenelsewhere)
    }

    func clearExternal(_ list: ExternalList) async {
        switch list {
        case .seenelsewhere: externalSeen = []
        case .notforme: externalNotForMe = []
        }
        saveExternal(list)
    }

    private func saveExternal(_ list: ExternalList) { markDirty(list.rawValue) }

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
        reco.listChanged(refreshing: itemIds)   // their watched state changed on the server

    }

    // MARK: Playback

    @ObservationIgnored private var playTask: Task<Void, Never>?

    /// One play request at a time: a second tap while the first is still looking up the episode
    /// replaces it instead of opening two players.
    func play(_ item: BaseItem, from start: Double? = nil, audio: Int? = nil, subtitle: Int? = nil,
              mediaSourceId: String? = nil) {
        playTask?.cancel()
        playTask = Task {
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
            guard !Task.isCancelled, playback == nil else { return }
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

    /// The next episodes (up to 50), fetched from this episode on instead of the whole series.
    func episodesAfter(_ episode: BaseItem) async -> [BaseItem] {
        guard let client, let sid = episode.seriesId else { return [] }
        var list = (try? await client.episodes(seriesId: sid, startItemId: episode.id, limit: 80)) ?? []
        if list.first?.id != episode.id { list = (try? await client.episodes(seriesId: sid)) ?? [] }
        guard let index = list.firstIndex(where: { $0.id == episode.id }) else { return [] }
        return Array(list[(index + 1)...].filter { $0.locationType != "Virtual" }.prefix(50))
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
