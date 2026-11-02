import Foundation
import Observation

/// Your server's library, as For You and the match % see it: built only from what's on the
/// server (your libraries, what you've finished, favourited, are watching or gave up on).
/// Same recipe as AniReco's AI picks:
///
/// 1. Taste profile: genres, tags and studios of what you liked (finished, favourites, likes,
///    in progress) push up; what you abandoned or marked "Not for me" pushes down. History in
///    the library you're browsing counts 1.5×, the rest still helps.
/// 2. "Fans also liked": Jellyfin's own Similar items for your strongest likes (the library
///    equivalent of AniList fan recommendations).
/// 3. On-device AI: Apple's Natural Language model embeds each overview on the iPhone and
///    compares it with a taste vector built from your favourites. Cached on disk; skipped in
///    Low Power Mode or when the phone is hot.
/// "Why would I like this?" is written by Apple Intelligence on device, only when asked.
@Observable
@MainActor
final class RecoEngine {
    // Public state
    private(set) var isBuilding = false
    private(set) var lastError: String?
    /// Bumped when match percentages change.
    private(set) var version = 0
    /// Bumped whenever the library snapshot changes (For You and My List re-check "already on
    /// your server" against it).
    private(set) var libraryRevision = 0

    @ObservationIgnored private weak var model: AppModel?
    /// Every movie/series in every eligible library, keyed by library id.
    @ObservationIgnored private var snapshot: [String: [BaseItem]] = [:]
    @ObservationIgnored private var itemLibrary: [String: String] = [:]
    @ObservationIgnored private var byId: [String: BaseItem] = [:]
    @ObservationIgnored private var profile = TasteProfile()
    @ObservationIgnored private var weights: [String: Double] = [:]
    @ObservationIgnored private var tagScale: (lo: Double, hi: Double) = (0, 1)
    @ObservationIgnored private var fan: [String: Double] = [:]
    @ObservationIgnored private var semantic: [String: Float] = [:]
    @ObservationIgnored private var matchMemo: [String: Int] = [:]
    @ObservationIgnored private var buildTask: Task<Void, Never>?
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var dirty = true
    /// A build ran to its end for this account (a cancelled or failed one leaves this false).
    @ObservationIgnored private var built = false
    /// Changes since start-up: a build only clears `dirty` if nothing changed while it ran.
    @ObservationIgnored private var changes = 0
    /// Only the newest build owns `isBuilding` (a cancelled one finishing late mustn't clear it).
    @ObservationIgnored private var buildGeneration = 0
    /// Bumped on account change: work started for the previous account must not land here.
    @ObservationIgnored private var epoch = 0
    @ObservationIgnored private var similarCache: [String: (items: [String], at: Date)] = [:]
    /// When the libraries were last read from the server, and titles to re-read before the next
    /// ranking (what was just played: its watched state changed on the server).
    @ObservationIgnored private var snapshotAt: Date?
    @ObservationIgnored private var refreshIds: Set<String> = []
    /// Server ids on My List (looked up for every title while ranking).
    @ObservationIgnored private var myListIds: Set<String> = []

    func attach(model: AppModel) { self.model = model }

    /// Account change: everything goes, including a build or refresh still running for the old
    /// account (its results must never land in the new one).
    func reset() {
        buildTask?.cancel()
        buildTask = nil
        debounce?.cancel()
        debounce = nil
        epoch &+= 1
        buildGeneration &+= 1
        isBuilding = false
        lastError = nil
        refreshIds = []
        snapshotAt = nil
        profileReady = false
        built = false
        snapshot = [:]
        itemLibrary = [:]
        byId = [:]
        profile = TasteProfile()
        weights = [:]
        fan = [:]
        semantic = [:]
        matchMemo = [:]
        similarCache = [:]
        dirty = true
        version &+= 1
        libraryRevision &+= 1
    }

    /// Something was watched / favourited / listed: re-rank a little later (several changes →
    /// one pass). The libraries aren't downloaded again for that: your changes are already known
    /// here, and only the titles in `refreshing` (just played) are re-read. A full re-read happens
    /// when the last one is over 15 minutes old.
    func listChanged(refreshing ids: [String] = []) {
        dirty = true
        changes &+= 1
        refreshIds.formUnion(ids)
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.refreshAfterChange()
        }
    }

    private func refreshAfterChange() async {
        if buildTask != nil {
            // A full read is already on its way; changes made while it ran are applied below.
            await build(force: false)
            if !dirty || Task.isCancelled { return }
        }
        guard let at = snapshotAt, Date().timeIntervalSince(at) < 15 * 60, !snapshot.isEmpty, let reader = model?.reader else {
            await build(force: true)
            return
        }
        let started = epoch
        let ids = refreshIds
        refreshIds = []
        if !ids.isEmpty { await reread(ids, reader: reader) }
        if Task.isCancelled || epoch != started { return }
        if model?.settings.useOnDeviceAI == false { semantic = [:] }   // AI turned off: no AI in the match %
        rebuildProfile()
        dirty = false
    }

    /// Fresh copies of a few titles (and the shows of played episodes), put into the snapshot.
    private func reread(_ ids: Set<String>, reader: LibraryReader) async {
        let started = epoch
        var q = JellyfinClient.ItemQuery()
        q.ids = Array(ids.prefix(100))
        q.recursive = true
        q.limit = nil
        q.isMissing = nil
        q.fields = Self.libraryFields
        guard let played = try? await reader.items(q).items else { return }
        guard epoch == started else { return }
        let shows = Set(played.compactMap { $0.kind == .episode || $0.kind == .season ? $0.seriesId : nil }).filter { byId[$0] != nil }
        var fresh = played.filter { byId[$0.id] != nil }
        if !shows.isEmpty {
            q.ids = Array(shows.prefix(100))
            fresh += (try? await reader.items(q).items) ?? []
        }
        guard !Task.isCancelled, epoch == started else { return }
        var changed = false
        for item in fresh {
            guard let lib = itemLibrary[item.id], let i = snapshot[lib]?.firstIndex(where: { $0.id == item.id }) else { continue }
            snapshot[lib]?[i] = item
            byId[item.id] = item
            changed = true
        }
        if changed { libraryRevision &+= 1 }
    }

    static let libraryFields = ["Overview", "Genres", "Tags", "Studios", "ProductionYear", "CommunityRating", "OfficialRating",
                                "RecursiveItemCount", "ChildCount", "ProductionLocations", "OriginalTitle", "DateCreated",
                                "PrimaryImageAspectRatio", "Status", "EndDate", "RunTimeTicks", "ProviderIds"]

    // MARK: Sources (first dropdown)

    struct Source: Identifiable, Hashable {
        let id: String
        let name: String
        let collectionType: String?
    }

    /// The user's own libraries by name (never one called "placeholder"), plus All.
    var sources: [Source] {
        guard let model else { return [] }
        let libs = model.libraries
            .filter { ["movies", "tvshows", "mixed", "homevideos", ""].contains($0.collectionType ?? "") }
            .filter { !RecoSource.isExcluded($0.name) }
            .map { Source(id: $0.id, name: $0.displayName, collectionType: $0.collectionType) }
        return libs + [Source(id: RecoSource.all, name: "All", collectionType: nil)]
    }

    /// The source to show: the saved choice if it still exists, else the library named Anime.
    var currentSourceId: String {
        guard let model else { return RecoSource.all }
        let list = sources
        let saved = model.settings.recoSource
        if !saved.isEmpty, list.contains(where: { $0.id == saved }) { return saved }
        return defaultSourceId(in: list)
    }

    func defaultSourceId(in list: [Source]) -> String {
        if let exact = list.first(where: { $0.name.compare("Anime", options: .caseInsensitive) == .orderedSame }) {
            return exact.id
        }
        if let anime = list.first(where: { $0.name.localizedCaseInsensitiveContains("anime")
                && !$0.name.localizedCaseInsensitiveContains("movie") && !$0.name.localizedCaseInsensitiveContains("film") }) {
            return anime.id
        }
        return list.first?.id ?? RecoSource.all
    }

    func sourceName(_ id: String) -> String {
        sources.first { $0.id == id }?.name ?? "All"
    }

    // MARK: Building

    /// True once the library list and your watch signals are known (For You needs only this,
    /// not the slower "fans also liked" and on-device AI pass that follow).
    @ObservationIgnored private(set) var profileReady = false

    /// Waits only for the library list and your history (never for the AI pass).
    func ensureProfile() async {
        if profileReady && !byId.isEmpty { return }
        // The library list arrives with the account (e.g. right after switching): wait for it
        // instead of reading no libraries at all.
        var waited = 0
        while waited < 240, model?.reader != nil, model?.libraries.isEmpty == true {   // up to 60 s
            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: 250_000_000)
            waited += 1
        }
        Task { await self.ensureBuilt() }
        for n in 0..<240 {   // up to 60 s
            try? await Task.sleep(nanoseconds: 250_000_000)
            if profileReady && !byId.isEmpty { return }
            if lastError != nil && !isBuilding { return }
            if n >= 4 && !isBuilding && buildTask == nil { return }   // the build ended without a library
        }
    }

    func ensureBuilt() async {
        if !built || snapshot.isEmpty {
            await build(force: false)
        } else if dirty {
            debounce?.cancel()
            await refreshAfterChange()
        }
    }

    /// Re-reads the libraries in the background when the last read is over 15 minutes old (or
    /// never finished), so titles added to the server since are known as yours.
    func refreshIfStale() {
        guard buildTask == nil, !byId.isEmpty else { return }
        if let at = snapshotAt, Date().timeIntervalSince(at) < 15 * 60 { return }
        Task { await build(force: false) }
    }

    func build(force: Bool) async {
        if let buildTask, !force {
            await buildTask.value
            return
        }
        buildTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runBuild()
        }
        buildTask = task
        await task.value
        if buildTask == task { buildTask = nil }
    }

    private func runBuild() async {
        guard let model, let reader = model.reader else { return }
        buildGeneration &+= 1
        let generation = buildGeneration
        isBuilding = true
        lastError = nil
        defer { if buildGeneration == generation { isBuilding = false } }

        // 0) Fast start: last snapshot from disk while the fresh one loads.
        let cacheName = "reco-\(model.store.currentServerId ?? "s")-\(reader.userId ?? "u")"
        if snapshot.isEmpty, let saved = await DiskCache.loadInBackground([String: [BaseItem]].self, name: cacheName) {
            if Task.isCancelled { return }
            ingest(saved)
            rebuildProfile()
            profileReady = true
        }

        // 1) Fresh snapshot of every eligible library. With no library list yet (still loading),
        // nothing is read: an empty read would replace the saved snapshot with nothing.
        let libraries = sources.filter { $0.id != RecoSource.all }
        if !libraries.isEmpty {
            let pendingBefore = refreshIds
            do {
                var fresh: [String: [BaseItem]] = [:]
                for source in libraries {
                    if Task.isCancelled { return }
                    fresh[source.id] = try await fetchLibrary(source, reader: reader)
                }
                if Task.isCancelled { return }   // e.g. the account changed while reading
                ingest(fresh)
                snapshotAt = Date()
                // Titles played while this read ran may have been read before they changed.
                refreshIds.subtract(pendingBefore)
                DiskCache.saveInBackground(fresh, name: cacheName)
            } catch {
                if AppModel.isCancellation(error) || Task.isCancelled { return }
                if snapshot.isEmpty {
                    lastError = error.localizedDescription
                    return
                }
            }
        }

        // 2) Taste profile + Similar ("fans also liked") from your strongest likes.
        let seenChanges = changes
        if !model.settings.useOnDeviceAI { semantic = [:] }   // AI turned off: no AI in the match %
        rebuildProfile()
        profileReady = true
        await collectSimilar(reader: reader)
        if Task.isCancelled { return }

        // 3) The on-device AI pass over the best unwatched titles of each library.
        if model.settings.useOnDeviceAI && SemanticEngine.shouldRunNow {
            let shortlist = await semanticShortlist()
            if Task.isCancelled { return }
            await runSemantic(shortlist: shortlist)
            if Task.isCancelled { return }
        }
        built = true
        if changes == seenChanges { dirty = false }
    }

    private func fetchLibrary(_ source: Source, reader: LibraryReader) async throws -> [BaseItem] {
        var q = JellyfinClient.ItemQuery()
        q.parentId = source.id
        q.recursive = true
        switch source.collectionType {
        case "movies": q.includeItemTypes = [.movie]
        case "tvshows": q.includeItemTypes = [.series]
        default: q.includeItemTypes = [.movie, .series]
        }
        q.fields = Self.libraryFields
        q.sortBy = ["SortName"]
        q.limit = 400
        q.isMissing = nil
        var all: [BaseItem] = []
        while true {
            let page = try await reader.items(q)
            let items = page.items ?? []
            all += items
            q.startIndex += items.count
            if items.isEmpty || all.count >= (page.totalRecordCount ?? 0) || all.count > 20_000 { break }
        }
        return all
    }

    private func ingest(_ libs: [String: [BaseItem]]) {
        snapshot = libs
        itemLibrary = [:]
        byId = [:]
        for (lib, items) in libs {
            for item in items {
                itemLibrary[item.id] = lib
                byId[item.id] = item
            }
        }
        libraryRevision &+= 1
    }

    // MARK: Signals

    /// How strongly your history says "liked" (positive) or "not for me" (negative); nil = no signal.
    private func signal(for item: BaseItem) -> Double? {
        guard let model else { return nil }
        if model.isNotForMe(item) { return -1.0 }
        let ud = model.userData(for: item) ?? UserItemData()
        // On My List = liked enough to plan it (like AniReco's Planning).
        var w: Double? = myListIds.contains(item.id) ? 0.5 : nil
        let daysSince = ud.lastPlayedDate.map { Date().timeIntervalSince($0) / 86_400 } ?? 0

        if ud.played == true {
            w = 1.0 + min(0.4, Double(max(0, (ud.playCount ?? 1) - 1)) * 0.2)   // rewatched = loved
        } else if item.kind == .series {
            let total = item.recursiveItemCount ?? 0
            let unplayed = ud.unplayedItemCount ?? total
            let watched = max(0, total - unplayed)
            if total > 0 && watched > 0 {
                let frac = Double(watched) / Double(total)
                if frac < 0.35 && daysSince > 60 {
                    w = -0.6                                  // tried it, gave up
                } else if model.settings.includeWatchingAsLiked {
                    w = 0.4 + 0.6 * frac
                }
            }
        } else if let pct = ud.playedPercentage, pct > 0 {
            w = (pct < 25 && daysSince > 30) ? -0.4 : (model.settings.includeWatchingAsLiked ? max(w ?? 0, 0.4) : w)
        }
        if ud.isFavorite == true { w = max(w ?? 0, 0) + 0.9 }
        if let likes = ud.likes { w = likes ? max(w ?? 0, 0) + 0.5 : -1.0 }
        return w
    }

    private func isCandidate(_ item: BaseItem) -> Bool {
        guard let model else { return false }
        if model.isNotForMe(item) || myListIds.contains(item.id) { return false }
        let ud = model.userData(for: item)
        if ud?.played == true || ud?.isFavorite == true { return false }
        if (ud?.playedPercentage ?? 0) > 0 { return false }
        if item.kind == .series {
            let total = item.recursiveItemCount ?? 0
            if total == 0 { return false }                     // no episodes on the server yet
            if let unplayed = ud?.unplayedItemCount, unplayed < total { return false }
        }
        return true
    }

    private func rebuildProfile() {
        myListIds = Set(model?.myList.compactMap(\.serverId) ?? [])
        var p = TasteProfile()
        var w: [String: Double] = [:]
        var likedVectors: [(vector: [String: Double], weight: Double)] = []
        for item in byId.values {
            guard let s = signal(for: item) else { continue }
            w[item.id] = s
            let v = TasteProfile.vector(for: item)   // once per title (also used for the calibration below)
            p.add(vector: v, weight: s)
            if s > 0.5 { likedVectors.append((v, s)) }
        }
        p.finalize()
        profile = p
        weights = w
        // Calibrate "very high match" on your well-liked titles (each vs. the rest of your history).
        let liked = likedVectors.map { p.similarity(toVector: $0.vector, excludingWeight: $0.weight) }.sorted()
        let all = byId.values.prefix(2000).map { p.similarity(to: $0, excludingWeight: w[$0.id] ?? 0) }.sorted()
        let hi = liked.isEmpty ? 0.55 : liked[min(liked.count - 1, Int(Double(liked.count) * 0.75))]
        let lo = all.isEmpty ? 0.0 : min(all[Int(Double(all.count - 1) * 0.1)], hi * 0.4)
        tagScale = (lo, max(hi, lo + 0.05))
        matchMemo = [:]
        version &+= 1
    }

    /// Jellyfin's Similar items for your strongest likes = "people who liked X".
    private func collectSimilar(reader: LibraryReader) async {
        let seeds = weights.filter { $0.value > 0.6 }
            .sorted { a, b in
                let ra = byId[a.key]?.userData?.lastPlayedDate ?? .distantPast
                let rb = byId[b.key]?.userData?.lastPlayedDate ?? .distantPast
                return a.value == b.value ? ra > rb : a.value > b.value
            }
            .prefix(16)
        var votes: [String: Double] = [:]
        var results: [(String, [String])] = []
        var toFetch: [String] = []
        for (seedId, _) in seeds {
            if let hit = similarCache[seedId], Date().timeIntervalSince(hit.at) < 3 * 86_400 {
                results.append((seedId, hit.items))
            } else {
                toFetch.append(seedId)
            }
        }
        let fetched = await withTaskGroup(of: (String, [String]).self, returning: [(String, [String])].self) { group in
            for seedId in toFetch {
                group.addTask {
                    let ids = (try? await reader.similar(seedId, limit: 30))?.map(\.id) ?? []
                    return (seedId, ids)
                }
            }
            var out: [(String, [String])] = []
            for await r in group { out.append(r) }
            return out
        }
        // The account may have changed while asking: nothing from the old one lands here.
        if Task.isCancelled { return }
        for (seedId, ids) in fetched where !ids.isEmpty { similarCache[seedId] = (ids, Date()) }
        results += fetched
        for (seedId, ids) in results {
            let seedWeight = weights[seedId] ?? 0.5
            for (rank, id) in ids.enumerated() {
                votes[id, default: 0] += seedWeight * (1 - Double(rank) / 32)
            }
        }
        let maxVote = max(votes.values.max() ?? 1, 0.0001)
        fan = votes.mapValues { min(1, $0 / maxVote) }
        matchMemo = [:]
        version &+= 1
    }

    // MARK: AI pass

    static func embeddingInput(_ item: BaseItem) -> SemanticEngine.Input {
        let genres = (item.genres ?? []).joined(separator: ", ")
        let tags = (item.tags ?? []).prefix(6).joined(separator: ", ")
        let text = "\(item.displayName). \(genres). \(tags). \(String(item.plainOverview.prefix(500)))"
        return SemanticEngine.Input(key: "\(item.id)|\(SemanticEngine.stableKey(text))", text: text)
    }

    /// The best ~120 unwatched titles of each library and of All, by taste, "fans also liked" and
    /// rating (history in a library counts 1.5× for that library): what the AI pass compares.
    /// Scored off the main thread.
    private func semanticShortlist() async -> [BaseItem] {
        myListIds = Set(model?.myList.compactMap(\.serverId) ?? [])
        let candidates = snapshot.mapValues { $0.filter(isCandidate) }
        var history: [(library: String?, weight: Double, item: BaseItem)] = []
        for (id, w) in weights {
            if let item = byId[id] { history.append((itemLibrary[id], w, item)) }
        }
        let base = profile
        let fan = self.fan
        return await Task.detached(priority: .utility) {
            Self.shortlist(candidates: candidates, history: history, base: base, fan: fan, perSource: 120)
        }.value
    }

    private nonisolated static func shortlist(candidates: [String: [BaseItem]],
                                              history: [(library: String?, weight: Double, item: BaseItem)],
                                              base: TasteProfile, fan: [String: Double], perSource: Int) -> [BaseItem] {
        let historyVectors = history.map { (library: $0.library, weight: $0.weight, vector: TasteProfile.vector(for: $0.item)) }
        func score(_ item: BaseItem, _ similarity: Double) -> Double {
            let c = fan[item.id] ?? 0
            let q = (item.communityRating ?? 6.5) / 10
            return 0.45 * c + 0.40 * max(0, similarity) + 0.15 * q
        }
        var result: [BaseItem] = []
        var taken: Set<String> = []
        func take(_ scored: [(BaseItem, Double)]) {
            for (item, _) in scored.sorted(by: { $0.1 > $1.1 }).prefix(perSource) where taken.insert(item.id).inserted {
                result.append(item)
            }
        }
        var all: [(BaseItem, Double)] = []
        var inAll: Set<String> = []
        for (lib, items) in candidates {
            // History in this library counts 1.5×: a tailored profile per library.
            var p = TasteProfile()
            for h in historyVectors { p.add(vector: h.vector, weight: h.library == lib ? h.weight * 1.5 : h.weight) }
            p.finalize()
            var scored: [(BaseItem, Double)] = []
            scored.reserveCapacity(items.count)
            for item in items {
                let v = TasteProfile.vector(for: item)   // once, for this library and for All
                scored.append((item, score(item, p.similarity(toVector: v))))
                if inAll.insert(item.id).inserted { all.append((item, score(item, base.similarity(toVector: v)))) }
            }
            take(scored)
        }
        take(all)
        return result
    }

    private func runSemantic(shortlist: [BaseItem]) async {
        // Anchors: your strongest likes and dislikes. Candidates: the shortlist.
        let anchors = weights.filter { abs($0.value) >= 0.4 }
            .sorted { abs($0.value) > abs($1.value) }
            .prefix(50)
            .compactMap { byId[$0.key] }
            .filter { !$0.plainOverview.isEmpty }
        guard !anchors.isEmpty else { return }
        // A title can be both (thumbs up/down but not watched yet): keyed by id, never a duplicate key.
        let embedded = anchors + shortlist
        let inputs = embedded.map(Self.embeddingInput)
        var keyOf: [String: String] = [:]
        for (item, input) in zip(embedded, inputs) { keyOf[item.id] = input.key }
        let vectors = await Task.detached(priority: .utility) {
            await SemanticEngine.shared.vectors(for: inputs)
        }.value
        guard !Task.isCancelled else { return }

        var taste: [Float] = []
        for a in anchors {
            guard let key = keyOf[a.id], let v = vectors[key] else { continue }
            if taste.isEmpty { taste = [Float](repeating: 0, count: v.count) }
            SemanticEngine.accumulate(v, scale: Float(weights[a.id] ?? 0), into: &taste)
        }
        guard !taste.isEmpty else { return }
        taste = SemanticEngine.normalized(taste)

        var sims: [String: Float] = [:]
        for item in shortlist {
            guard let key = keyOf[item.id], let v = vectors[key] else { continue }
            sims[item.id] = SemanticEngine.cosine(taste, v)
        }
        let sorted = sims.values.sorted()
        guard sorted.count >= 3 else { return }
        let lo = sorted[Int(Double(sorted.count - 1) * 0.1)], hi = sorted[Int(Double(sorted.count - 1) * 0.9)]
        let span = max(hi - lo, 0.0001)
        semantic = sims.mapValues { max(-1, min(1, ($0 - lo) / span)) }
        matchMemo = [:]
        version &+= 1
    }

    // MARK: Match %

    /// Personal match % for any movie/series in your libraries (nil until history exists).
    func match(for item: BaseItem) -> Int? {
        _ = version
        guard profile.norm > 0 else { return nil }
        let target: BaseItem
        if item.kind == .episode || item.kind == .season, let sid = item.seriesId, let series = byId[sid] {
            target = series
        } else {
            target = byId[item.id] ?? item
        }
        guard target.kind == .movie || target.kind == .series else { return nil }
        if let memo = matchMemo[target.id] { return memo }
        let raw = profile.similarity(to: target, excludingWeight: weights[target.id] ?? 0)
        var z = max(-1, min(1, (raw - tagScale.lo) / (tagScale.hi - tagScale.lo)))
        if let sem = semantic[target.id] { z = 0.55 * z + 0.45 * Double(sem) }
        if let f = fan[target.id], f > 0, z < 1 { z += (1 - z) * 0.5 * f }
        let percent = z >= 0 ? Int((50 + 49 * min(z, 1)).rounded()) : Int((50 + 30 * z).rounded())
        matchMemo[target.id] = percent
        return percent
    }

    /// "More like this": unwatched titles on your server close to this specific one.
    /// Local only. Candidates are Jellyfin's similar items plus the closest titles by genres,
    /// tags and studio; the on-device AI then compares their overviews with this title's.
    func moreLike(_ item: BaseItem) async -> [BaseItem] {
        guard let model, let reader = model.reader else { return [] }
        if snapshot.isEmpty { await ensureBuilt() }
        let baseId = item.kind == .episode || item.kind == .season ? (item.seriesId ?? item.id) : item.id
        var base = item
        if let known = byId[baseId] {
            base = known
        } else if let fetched = try? await reader.item(baseId) {
            base = fetched
        }

        var pool: [String: BaseItem] = [:]
        for s in (try? await reader.similar(baseId, limit: 40)) ?? [] { pool[s.id] = byId[s.id] ?? s }
        var single = TasteProfile()
        single.add(base, weight: 1)
        single.finalize()
        let one = single
        let baseKind = base.kind, baseItemId = base.id
        let sameKind = byId.values.filter { $0.kind == baseKind && $0.id != baseItemId }
        // Closest by genres, tags and studio: scored off the main thread (the whole library).
        let byTags = await Task.detached(priority: .userInitiated) {
            Array(sameKind.map { ($0, one.similarity(to: $0, sameLibraryBoost: nil)) }
                .sorted { $0.1 > $1.1 }
                .prefix(80))
        }.value
        var tagScore: [String: Double] = [:]
        for (c, s) in byTags {
            pool[c.id] = c
            tagScore[c.id] = s
        }
        pool[base.id] = nil
        let candidates = pool.values.filter { !model.isPlayed($0) && !model.isNotForMe($0) }
        guard !candidates.isEmpty else { return [] }

        var semantic: [String: Float] = [:]
        if model.settings.useOnDeviceAI && SemanticEngine.shouldRunNow {
            let baseInput = Self.embeddingInput(base)
            let inputs = candidates.map(Self.embeddingInput)
            let vectors = await Task.detached(priority: .userInitiated) {
                await SemanticEngine.shared.vectors(for: [baseInput] + inputs)
            }.value
            if let bv = vectors[baseInput.key] {
                for (c, input) in zip(candidates, inputs) {
                    if let v = vectors[input.key] { semantic[c.id] = SemanticEngine.cosine(bv, v) }
                }
            }
        }
        let sims = semantic.values.sorted()
        let lo = sims.first ?? 0, hi = sims.last ?? 1
        let span = max(hi - lo, 0.0001)
        func score(_ c: BaseItem) -> Double {
            let tag = tagScore[c.id] ?? one.similarity(to: c, sameLibraryBoost: nil)
            let mine = Double(match(for: c) ?? 60) / 100
            if let s = semantic[c.id] {
                return 0.45 * Double((s - lo) / span) + 0.35 * tag + 0.20 * mine
            }
            return 0.65 * tag + 0.35 * mine
        }
        // Each title scored once, then sorted.
        return candidates.map { ($0, score($0)) }.sorted { $0.1 > $1.1 }.prefix(30).map(\.0)
    }

    // MARK: For the discovery engine (For You)

    /// Your history as (title, weight) — positive liked, negative disliked. Titles in the given
    /// library count 1.5×, so "Anime" picks lean on your anime history.
    func history(boosting sourceId: String) -> [(item: BaseItem, weight: Double)] {
        weights.compactMap { id, w in
            guard let item = byId[id] else { return nil }
            let boost = sourceId == RecoSource.all || itemLibrary[id] == sourceId ? 1.5 : 1.0
            return (item, w * boost)
        }
    }

    /// Every movie and show on the server (for "already in your library" checks).
    var libraryItems: [BaseItem] { Array(byId.values) }

    func libraryId(of itemId: String) -> String? { itemLibrary[itemId] }

    func source(_ id: String) -> Source? { sources.first { $0.id == id } }

    /// Titles you loved most (for explanations).
    func topLiked(in sourceId: String, limit: Int = 8) -> [String] {
        weights.filter { $0.value > 0.6 && (sourceId == RecoSource.all || itemLibrary[$0.key] == sourceId) }
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .compactMap { byId[$0.key]?.displayName }
    }
}

// MARK: - Taste profile (genres, tags, studios)

struct TasteProfile {
    var features: [String: Double] = [:]
    var norm: Double = 0

    static func vector(for item: BaseItem) -> [String: Double] {
        var v: [String: Double] = [:]
        for g in item.genres ?? [] { v["g:" + g] = 1.0 }
        for t in (item.tags ?? []).prefix(15) { v["t:" + t.lowercased()] = 0.6 }
        for s in (item.studios ?? []).prefix(3) { if let n = s.name { v["s:" + n] = 0.45 } }
        if let y = item.productionYear { v["d:\(y / 10 * 10)"] = 0.15 }
        return v
    }

    mutating func add(_ item: BaseItem, weight: Double) {
        add(vector: Self.vector(for: item), weight: weight)
    }

    /// `add` with the title's features already worked out (`vector(for:)`).
    mutating func add(vector v: [String: Double], weight: Double) {
        guard weight != 0 else { return }
        for (key, value) in v { features[key, default: 0] += value * weight }
    }

    mutating func finalize() {
        norm = sqrt(features.values.reduce(0) { $0 + $1 * $1 })
    }

    func similarity(to item: BaseItem, sameLibraryBoost: Double?) -> Double {
        similarity(toVector: Self.vector(for: item))
    }

    func similarity(toVector v: [String: Double]) -> Double {
        guard norm > 0 else { return 0 }
        let vNorm = sqrt(v.values.reduce(0) { $0 + $1 * $1 })
        guard vNorm > 0 else { return 0 }
        var dot = 0.0
        for (key, value) in v { dot += value * (features[key] ?? 0) }
        return dot / (norm * vNorm)
    }

    /// Leave-one-out: a title in your history is compared with the rest of your taste.
    func similarity(to item: BaseItem, excludingWeight w: Double) -> Double {
        similarity(toVector: Self.vector(for: item), excludingWeight: w)
    }

    func similarity(toVector v: [String: Double], excludingWeight w: Double) -> Double {
        guard w != 0 else { return similarity(toVector: v) }
        let vNorm = sqrt(v.values.reduce(0) { $0 + $1 * $1 })
        guard vNorm > 0 else { return 0 }
        var normSq = norm * norm
        var dot = 0.0
        for (key, value) in v {
            let f = features[key] ?? 0
            let without = f - value * w
            normSq += without * without - f * f
            dot += value * without
        }
        guard normSq > 1e-9 else { return 0 }
        return dot / (sqrt(normSq) * vNorm)
    }

    /// Your strongest features of one kind ("g:" genres, "t:" tags).
    func top(prefix: String, count: Int) -> [String] {
        features.filter { $0.key.hasPrefix(prefix) && $0.value > 0 }
            .sorted { $0.value > $1.value }
            .prefix(count)
            .map { String($0.key.dropFirst(prefix.count)) }
    }

    func highlights(for item: BaseItem, limit: Int = 3) -> [String] {
        Self.vector(for: item)
            .compactMap { key, value -> (String, Double)? in
                guard !key.hasPrefix("d:") else { return nil }
                let w = (features[key] ?? 0) * value
                return w > 0 ? (key, w) : nil
            }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { String($0.0.dropFirst(2)).capitalized }
    }
}
