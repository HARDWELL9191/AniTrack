import Foundation
import Observation

/// One For You pick: a title from TMDB that is NOT on your server.
struct ExternalPick: Identifiable, Hashable, Codable {
    var id: String { title.id }
    var title: ExternalTitle
    let score: Double
    var match: Int
    let because: [String]
    let highlights: [String]
}

/// For You: finds new titles to get, from TMDB, based on what you watched on your server.
///
/// 1. Taste: what you finished, favourited, are watching, gave up on or marked "Not for me"
///    in the chosen library (counts 1.5×) and the rest of your server, read through a
///    read-only reader (the AI can't change anything on the server).
/// 2. Your strongest likes are found on TMDB by the ids Jellyfin already stored for them
///    (TMDB, else IMDb/TVDB, else a title search), and TMDB's "people who liked this also
///    liked" lists are collected, weighted by how much you liked each one.
/// 3. Well-rated titles in your favourite genres are added (anime = Animation + Japanese).
/// 4. Anything already on your server is removed (TMDB/IMDb/TVDB id or title + year), as are
///    titles on My List, marked Seen or Not for me.
/// 5. The short list is re-ranked on the iPhone: genre/keyword match with your taste and
///    Apple's on-device language model comparing each overview with your favourites.
@Observable
@MainActor
final class DiscoveryEngine {
    private(set) var picks: [String: [ExternalPick]] = [:]
    /// Running builds, their errors, status and generation are per build (`buildKey`): a library's
    /// full build and a category build of it run side by side, so picking a category no longer
    /// cancels the full build.
    private(set) var isBuilding: Set<String> = []
    private(set) var errors: [String: String] = [:]
    private(set) var builtAt: [String: Date] = [:]
    private(set) var usedAI = false
    /// What the build is doing right now, per build (shown under the spinner).
    private(set) var status: [String: String] = [:]
    @ObservationIgnored private var generation: [String: Int] = [:]
    /// Picks category builds added while the library's full build was running: kept when it lands
    /// (its list would otherwise drop them).
    @ObservationIgnored private var addedDuringFullBuild: [String: [ExternalPick]] = [:]
    private(set) var version = 0

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var tmdb: TMDBClient?
    @ObservationIgnored private var tmdbKeyInUse = ""
    @ObservationIgnored private var idMap: [String: Int] = [:]      // library item id → TMDB id
    @ObservationIgnored private var idMapLoaded = false
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    /// Bumped on account change: work started for the previous account must not land here.
    @ObservationIgnored private var epoch = 0

    func attach(model: AppModel) { self.model = model }
    #if DEBUG
    /// UI test only: the old broken state (engine not connected to the app).
    func detachForTesting() { model = nil }
    #endif

    func reset() {
        for t in tasks.values { t.cancel() }
        tasks = [:]
        epoch &+= 1
        // Builds still running for the old account no longer own their library's spinner,
        // status or error message.
        generation = generation.mapValues { $0 + 1 }
        picks = [:]
        errors = [:]
        status = [:]
        isBuilding = []
        addedDuringFullBuild = [:]
        builtAt = [:]
        version &+= 1
    }

    /// A new TMDB key: forget results and errors made without it and build again.
    func keyChanged() {
        reset()
        guard hasKey, let id = model?.reco.currentSourceId else { return }
        Task { await build(id, genre: nil) }
    }

    var hasKey: Bool { !(model?.settings.tmdbKey.trimmingCharacters(in: .whitespaces).isEmpty ?? true) }

    private func client() -> TMDBClient? {
        guard let key = model?.settings.tmdbKey.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return nil }
        if tmdb == nil || key != tmdbKeyInUse {
            tmdb = TMDBClient(key: key)
            tmdbKeyInUse = key
        }
        return tmdb
    }

    // MARK: What a library means

    enum Kind { case animeShows, animeMovies, movies, shows, mixed, all }

    func kind(of sourceId: String) -> Kind {
        guard sourceId != RecoSource.all, let src = model?.reco.source(sourceId) else { return .all }
        let name = src.name.lowercased()
        let moviesish = name.contains("movie") || name.contains("film") || src.collectionType == "movies"
        if name.contains("anime") { return moviesish ? .animeMovies : .animeShows }
        switch src.collectionType {
        case "movies": return .movies
        case "tvshows": return .shows
        default: return moviesish ? .movies : .mixed
        }
    }

    private var hasAnimeLibrary: Bool {
        model?.reco.sources.contains { $0.name.localizedCaseInsensitiveContains("anime") } ?? false
    }

    // MARK: Public

    func visiblePicks(for sourceId: String, genre: String?) -> [ExternalPick] {
        _ = version
        guard let model else { return [] }
        let hidden = model.externalHidden
        // Picks saved earlier (on this phone, or before the library was last read) are checked
        // again against what's on the server now.
        let owned = ownedIndex(exact: false)
        return (picks[sourceId] ?? []).filter { p in
            !hidden.contains(p.id) && (genre == nil || p.title.genres.contains(genre!)) && !(owned?.contains(p.title) ?? false)
        }
    }

    @ObservationIgnored private var owned: (revision: Int, mapped: Int, index: OwnedIndex)?

    /// Everything on the server, indexed for "already yours" checks. Built again only when the
    /// library snapshot changes (or, with `exact`, when more TMDB ids of your titles are known):
    /// indexing every title used to be redone on every build and every "More like this".
    private func ownedIndex(exact: Bool) -> OwnedIndex? {
        guard let reco = model?.reco else { return nil }
        let revision = reco.libraryRevision   // read here, so For You updates when the library does
        if let owned, owned.revision == revision, !exact || owned.mapped == idMap.count { return owned.index }
        let items = reco.libraryItems
        guard !items.isEmpty else { return nil }
        let index = OwnedIndex(items: items, idMap: idMap)
        owned = (revision, idMap.count, index)
        return index
    }

    /// A library's full build is keyed by the library; a category build by library and category.
    private func buildKey(_ sourceId: String, _ genre: String?) -> String {
        genre.map { "\(sourceId)|genre:\($0)" } ?? sourceId
    }

    /// For the view of a library + category: a category also fills from the library's full build,
    /// so its spinner shows while either runs; "Any category" follows the full build only.
    func isBuildingPicks(_ sourceId: String, genre: String?) -> Bool {
        isBuilding.contains(buildKey(sourceId, genre)) || isBuilding.contains(sourceId)
    }

    func buildStatus(_ sourceId: String, genre: String?) -> String? {
        status[buildKey(sourceId, genre)] ?? status[sourceId]
    }

    func buildError(_ sourceId: String, genre: String?) -> String? {
        errors[buildKey(sourceId, genre)]
    }

    func genres(for sourceId: String) -> [String] {
        var counts: [String: Int] = [:]
        for p in picks[sourceId] ?? [] { for g in p.title.genres { counts[g, default: 0] += 1 } }
        return counts.filter { $0.value >= 2 }.sorted { $0.value > $1.value }.map(\.key)
    }

    /// Picks saved on this phone are used as they are while less than 12 hours old (it used to
    /// rebuild from TMDB on every launch, 100+ requests); pull down on For You for fresh ones.
    func ensureBuilt(_ sourceId: String) async {
        if picks[sourceId] == nil || (picks[sourceId]?.isEmpty ?? true) {
            let started = epoch
            let name = cacheName(sourceId)
            if let saved = await DiskCache.loadInBackground([ExternalPick].self, name: name), !saved.isEmpty {
                guard epoch == started else { return }   // the account changed meanwhile
                picks[sourceId] = saved
                version &+= 1
                let at = await DiskCache.loadInBackground(Date.self, name: name + "-at")
                guard epoch == started else { return }
                if let at, Date().timeIntervalSince(at) < 12 * 3600 {
                    builtAt[sourceId] = at
                    return
                }
            }
            guard epoch == started else { return }
            await build(sourceId, genre: nil)
        }
    }

    private func cacheName(_ sourceId: String) -> String {
        "reco-ext-\(model?.store.currentServerId ?? "s")-\(model?.client?.userId ?? "u")-\(sourceId)"
    }

    func build(_ sourceId: String, genre: String?) async {
        let key = buildKey(sourceId, genre)
        if let running = tasks[key] { running.cancel() }
        // One category build per library at a time (as before); the full build keeps running.
        if genre != nil {
            let prefix = buildKey(sourceId, "")
            for (k, t) in tasks where k != key && k.hasPrefix(prefix) { t.cancel() }
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.run(sourceId, genre: genre)
        }
        tasks[key] = task
        await task.value
    }

    // MARK: Build

    private func run(_ sourceId: String, genre: String?) async {
        guard let model else { return }
        let key = buildKey(sourceId, genre)
        guard let tmdb = client() else {
            errors[key] = TMDBError.noKey.localizedDescription
            return
        }
        // Only the newest build of a library (or of a library's category) owns its spinner and
        // status (an older, cancelled build finishing late must not hide the spinner of the one
        // still running).
        let gen = (generation[key] ?? 0) + 1
        generation[key] = gen
        isBuilding.insert(key)
        errors[key] = nil
        if genre == nil { addedDuringFullBuild[sourceId] = nil }
        defer {
            if generation[key] == gen {
                isBuilding.remove(key)
                status[key] = nil
            }
        }
        func step(_ text: String) { if generation[key] == gen { status[key] = text } }
        func fail(_ text: String) {
            // (A category build cancelled by another category is not an error.)
            guard generation[key] == gen, !Task.isCancelled else { return }
            errors[key] = text
            if genre == nil, picks[sourceId] == nil { picks[sourceId] = [] }
        }
        await tmdb.resetStats()

        step("Reading your library…")
        await model.reco.ensureProfile()
        if model.reco.libraryItems.isEmpty {
            fail(model.reco.lastError.map { "Couldn't read your library: \($0)" } ?? "Couldn't read your library from the server. Pull down to try again.")
            return
        }
        // A fresh look at the server when the last one is old, so new titles there are known as
        // yours (picks are checked against it again when it arrives).
        if genre == nil { model.reco.refreshIfStale() }
        await loadIdMap()
        step("Connecting to TMDB…")
        do { try await tmdb.loadGenres() } catch {
            fail(error.localizedDescription)
            return
        }

        let kind = kind(of: sourceId)
        // Everything you watched teaches; this library's history counts 1.5×.
        let history = model.reco.history(boosting: sourceId)
        guard !history.isEmpty else {
            fail("Finish or favourite a few titles on your server first: For You learns from them.")
            return
        }

        // Profile from your history (genres, tags, studios), boosted for this library.
        var profile = TasteProfile()
        for h in history { profile.add(h.item, weight: h.weight) }
        profile.finalize()

        // 1) Seeds on TMDB: your strongest likes of the right kind.
        let wantsTV: Bool? = {
            switch kind {
            case .animeShows, .shows: return true
            case .animeMovies, .movies: return false
            default: return nil
            }
        }()
        let seeds = history
            .filter { $0.weight > 0.6 }
            .filter { wantsTV == nil || ($0.item.kind == .series) == wantsTV! }
            .filter { item in
                switch kind {
                case .animeShows, .animeMovies: return model.reco.libraryId(of: item.item.id) == sourceId || isAnimeLike(item.item)
                default: return true
                }
            }
            .sorted { $0.weight > $1.weight }
            .prefix(18)
        var votes: [String: Double] = [:]
        var reasons: [String: [String]] = [:]
        var candidates: [String: ExternalTitle] = [:]
        step("Finding \(seeds.count) of your favourites on TMDB…")

        await withTaskGroup(of: (BaseItem, Double, [ExternalTitle]).self) { group in
            for seed in seeds {
                group.addTask { [weak self] in
                    guard let self, let tmdbId = await self.tmdbId(for: seed.item, client: tmdb) else { return (seed.item, seed.weight, []) }
                    let tv = seed.item.kind == .series
                    let page1 = (try? await tmdb.recommendations(tmdbId: tmdbId, tv: tv)) ?? []
                    let page2 = seed.weight > 1.2 ? ((try? await tmdb.recommendations(tmdbId: tmdbId, tv: tv, page: 2)) ?? []) : []
                    return (seed.item, seed.weight, page1 + page2)
                }
            }
            for await (seed, weight, recs) in group {
                for (rank, rec) in recs.enumerated() {
                    votes[rec.id, default: 0] += weight * (1 - Double(rank) / 45)
                    candidates[rec.id] = candidates[rec.id] ?? rec
                    if !(reasons[rec.id] ?? []).contains(seed.displayName) { reasons[rec.id, default: []].append(seed.displayName) }
                }
            }
        }

        // 2) Explore: well-rated titles in your top genres (and the chosen category).
        step("Exploring your favourite genres…")
        let topGenres = profile.top(prefix: "g:", count: 4)
        let animeFilter: Bool? = {
            switch kind {
            case .animeShows, .animeMovies: return true
            case .movies, .shows, .mixed: return hasAnimeLibrary ? false : nil
            case .all: return nil
            }
        }()
        let types: [Bool] = wantsTV.map { [$0] } ?? [true, false]
        for tv in types {
            var genreIds = await topGenres.asyncCompactMap { await tmdb.genreId(named: $0, tv: tv) }
            if let genre, let gid = await tmdb.genreId(named: genre, tv: tv) { genreIds = [gid] }
            // The discover pages are asked for together, not one after another; results are
            // merged in the same order as before, so the picks come out the same.
            let minVotes = animeFilter == true ? 80 : 300
            var requests: [(genre: Int?, page: Int)] = []
            for gid in genreIds.prefix(3) { for page in 1...2 { requests.append((genre: gid, page: page)) } }
            if genre == nil { requests.append((genre: nil, page: 1)) }
            let pages = await withTaskGroup(of: (Int, [ExternalTitle]).self) { group -> [[ExternalTitle]] in
                for (i, r) in requests.enumerated() {
                    group.addTask {
                        let list = r.genre == nil
                            ? (try? await tmdb.discover(tv: tv, genreIds: [], anime: animeFilter, page: 1, sort: "popularity.desc", minVotes: 150)) ?? []
                            : (try? await tmdb.discover(tv: tv, genreIds: [r.genre!], anime: animeFilter, page: r.page, minVotes: minVotes)) ?? []
                        return (i, list)
                    }
                }
                var out = [[ExternalTitle]](repeating: [], count: requests.count)
                for await (i, list) in group { out[i] = list }
                return out
            }
            for list in pages { for t in list { candidates[t.id] = candidates[t.id] ?? t } }
        }
        if Task.isCancelled { return }
        if candidates.isEmpty {
            let stats = (await tmdb.failed, await tmdb.lastFailure)
            fail(stats.0 > 0
                 ? "TMDB didn't answer (\(stats.0) requests failed). \(stats.1 ?? "")"
                 : "TMDB found nothing for your favourites. Pull down to try again.")
            return
        }

        // 3) Never anything you already have, have seen, wished for or rejected.
        step("Removing what you already have…")
        guard let owned = ownedIndex(exact: true) else {
            fail("Couldn't read your library from the server. Pull down to try again.")
            return
        }
        let hidden = model.externalHidden
        let thisYear = Calendar.current.component(.year, from: Date())
        func allowed(_ t: ExternalTitle) -> Bool {
            if owned.contains(t) || hidden.contains(t.id) || t.isAdult { return false }
            if let wantsTV, t.isMovie == wantsTV { return false }
            if animeFilter == true && !t.isAnime { return false }
            if animeFilter == false && t.isAnime { return false }
            if t.overview.isEmpty || (t.voteCount ?? 0) < 15 { return false }
            if let y = t.year, y > thisYear { return false }
            return t.year != nil
        }
        let maxVote = max(votes.values.max() ?? 1, 0.0001)
        struct Scored { var title: ExternalTitle; let collab: Double; var tag: Double; let quality: Double; var score: Double }
        var scored: [Scored] = candidates.values.filter(allowed).map { t in
            let c = (votes[t.id] ?? 0) / maxVote
            let tag = max(0, profile.similarity(to: Self.pseudoItem(t), sameLibraryBoost: nil))
            let q = Self.quality(t)
            return Scored(title: t, collab: c, tag: tag, quality: q, score: 0.45 * c + 0.35 * tag + 0.20 * q)
        }
        scored.sort { $0.score > $1.score }
        var shortlist = Array(scored.prefix(90))

        // 4) Details for the short list: keywords (tags) and IMDb/TVDB ids — then check ownership again.
        step("Reading details of \(shortlist.count) titles…")
        let detailed = await withTaskGroup(of: (Int, ExternalTitle).self, returning: [Int: ExternalTitle].self) { group in
            for (i, s) in shortlist.enumerated() { group.addTask { (i, await tmdb.details(s.title)) } }
            var out: [Int: ExternalTitle] = [:]
            for await (i, t) in group { out[i] = t }
            return out
        }
        for i in shortlist.indices { if let d = detailed[i] { shortlist[i].title = d } }
        shortlist = shortlist.filter { !owned.contains($0.title) }
        for i in shortlist.indices {
            shortlist[i].tag = max(0, profile.similarity(to: Self.pseudoItem(shortlist[i].title), sameLibraryBoost: nil))
        }

        // 5) On-device AI: overviews compared with your favourites' (and away from dislikes).
        var semantic: [String: Double] = [:]
        var nearest: [String: [String]] = [:]
        let aiOn = model.settings.useOnDeviceAI && SemanticEngine.shouldRunNow && !shortlist.isEmpty
        if aiOn { step("Ranking with on-device AI…") }
        if aiOn {
            let anchors = history.filter { abs($0.weight) >= 0.5 && !$0.item.plainOverview.isEmpty }
                .sorted { abs($0.weight) > abs($1.weight) }.prefix(50)
            let extDislikes = model.externalNotForMe.prefix(40)
            let inputs = anchors.map { RecoEngine.embeddingInput($0.item) } + extDislikes.map(\.embeddingInput)
                + shortlist.map(\.title.embeddingInput)
            // The on-device model can be slow to load the first time: never wait more than 25 s.
            let vectors: [String: [Float]] = await withTaskGroup(of: [String: [Float]]?.self) { group in
                group.addTask { await Task.detached(priority: .utility) { await SemanticEngine.shared.vectors(for: inputs) }.value }
                group.addTask { try? await Task.sleep(nanoseconds: 25_000_000_000); return nil }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first ?? [:]
            }
            var taste: [Float] = []
            var likedVectors: [(String, [Float])] = []
            for a in anchors {
                guard let v = vectors[RecoEngine.embeddingInput(a.item).key] else { continue }
                if taste.isEmpty { taste = [Float](repeating: 0, count: v.count) }
                SemanticEngine.accumulate(v, scale: Float(a.weight), into: &taste)
                if a.weight > 0.8 { likedVectors.append((a.item.displayName, v)) }
            }
            for d in extDislikes {
                guard let v = vectors[d.embeddingInput.key], !taste.isEmpty else { continue }
                SemanticEngine.accumulate(v, scale: -0.8, into: &taste)
            }
            if !taste.isEmpty {
                taste = SemanticEngine.normalized(taste)
                var raw: [String: Float] = [:]
                for s in shortlist {
                    guard let v = vectors[s.title.embeddingInput.key] else { continue }
                    raw[s.title.id] = SemanticEngine.cosine(taste, v)
                    nearest[s.title.id] = likedVectors.map { ($0.0, SemanticEngine.cosine($0.1, v)) }
                        .sorted { $0.1 > $1.1 }.prefix(2).map(\.0)
                }
                let sorted = raw.values.sorted()
                if let lo = sorted.first, let hi = sorted.last {
                    let span = max(hi - lo, 0.0001)
                    semantic = raw.mapValues { Double(($0 - lo) / span) }
                }
            }
        }
        usedAI = !semantic.isEmpty

        for i in shortlist.indices {
            let s = shortlist[i]
            if let sem = semantic[s.title.id] {
                shortlist[i].score = 0.30 * s.collab + 0.24 * s.tag + 0.34 * sem + 0.12 * s.quality
            } else {
                shortlist[i].score = 0.45 * s.collab + 0.37 * s.tag + 0.18 * s.quality
            }
        }
        shortlist.sort { $0.score > $1.score }
        let top = max(shortlist.first?.score ?? 1, 0.0001)
        let result = shortlist.prefix(60).map { s -> ExternalPick in
            let ratio = s.score / top
            let because = Array((reasons[s.title.id] ?? nearest[s.title.id] ?? []).prefix(3))
            return ExternalPick(title: s.title, score: s.score,
                                match: Int((max(0.5, min(0.99, 0.56 + 0.43 * ratio)) * 100).rounded()),
                                because: because,
                                highlights: profile.highlights(for: Self.pseudoItem(s.title)))
        }
        if Task.isCancelled || generation[key] != gen { return }
        if result.isEmpty {
            fail(candidates.isEmpty ? "TMDB found nothing." :
                 "Everything TMDB suggested (\(candidates.count) titles) is already on your server, on My List, or marked Seen / Not for me. Pull down to try again, or pick another category.")
            return
        }
        if let genre {
            // A category build adds to the library's list instead of replacing it.
            var merged = picks[sourceId] ?? []
            let known = Set(merged.map(\.id))
            let added = result.filter { !known.contains($0.id) && $0.title.genres.contains(genre) }
            merged += added
            picks[sourceId] = merged
            if isBuilding.contains(sourceId) { addedDuringFullBuild[sourceId, default: []] += added }
        } else {
            // What category builds added while this one ran stays (after this build's picks).
            let ids = Set(result.map(\.id))
            let kept = (addedDuringFullBuild[sourceId] ?? []).filter { !ids.contains($0.id) }
            addedDuringFullBuild[sourceId] = nil
            picks[sourceId] = Array(result) + kept
        }
        builtAt[sourceId] = Date()
        version &+= 1
        DiskCache.saveInBackground(picks[sourceId] ?? [], name: cacheName(sourceId))
        if genre == nil { DiskCache.saveInBackground(Date(), name: cacheName(sourceId) + "-at") }
        saveIdMap()
    }

    /// "More like this" for an outside title: TMDB's also-liked list, minus anything you have.
    func moreLike(_ title: ExternalTitle) async -> [ExternalTitle] {
        guard let model, let tmdb = client() else { return [] }
        await loadIdMap()
        let recs = (try? await tmdb.recommendations(tmdbId: title.sourceId, tv: !title.isMovie)) ?? []
        let owned = ownedIndex(exact: true)
        let hidden = model.externalHidden
        return recs.filter { !(owned?.contains($0) ?? false) && !hidden.contains($0.id) && !$0.isAdult }
    }

    func details(_ title: ExternalTitle) async -> ExternalTitle {
        guard let tmdb = client() else { return title }
        return await tmdb.details(title)
    }

    /// Age ratings found for covers, kept on the phone: each cover used to look its title up on
    /// TMDB again every session (one request per cover, in grids of hundreds).
    @ObservationIgnored private var ages: [String: String]?
    @ObservationIgnored private var agesLoad: Task<[String: String], Never>?
    @ObservationIgnored private var agesSave: Task<Void, Never>?

    func ageRating(_ title: ExternalTitle) async -> String? {
        if let r = title.ageRating { return r }
        if ages == nil {
            // One read of the saved ratings for the whole grid (every cover used to read and decode
            // the file itself, and a late read could drop ratings found meanwhile).
            let load = agesLoad ?? Task { await DiskCache.loadInBackground([String: String].self, name: "tmdb-ages") ?? [:] }
            agesLoad = load
            let loaded = await load.value
            if ages == nil { ages = loaded }
        }
        if let hit = ages?[title.id] { return hit }
        guard let found = await details(title).ageRating else { return nil }
        ages?[title.id] = found
        agesSave?.cancel()
        agesSave = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let ages = self?.ages else { return }
            DiskCache.saveInBackground(ages, name: "tmdb-ages")
        }
        return found
    }

    // MARK: Helpers

    private func isAnimeLike(_ item: BaseItem) -> Bool {
        let genres = (item.genres ?? []).map { $0.lowercased() }
        return genres.contains("anime") || (genres.contains("animation") && (item.productionLocations ?? []).contains { $0.localizedCaseInsensitiveContains("japan") })
    }

    /// A TMDB title shaped like a library item, so the same taste profile can score it.
    static func pseudoItem(_ t: ExternalTitle) -> BaseItem {
        var b = BaseItem(id: t.id, name: t.title)
        b.genres = t.genres.flatMap(Self.splitGenre)
        b.tags = t.tags
        b.productionYear = t.year
        b.type = t.isMovie ? .movie : .series
        return b
    }

    /// TMDB TV uses combined genres ("Action & Adventure"); Jellyfin libraries usually have both halves.
    static func splitGenre(_ g: String) -> [String] {
        g.contains("&") ? g.components(separatedBy: "&").map { $0.trimmingCharacters(in: .whitespaces) } + [g] : [g]
    }

    static func quality(_ t: ExternalTitle) -> Double {
        let s = (t.score ?? 6) / 10
        let confidence = min(1, log10(Double(max(t.voteCount ?? 1, 1))) / 4)   // 10k votes = full confidence
        return s * (0.6 + 0.4 * confidence)
    }

    /// TMDB id of a library title: from Jellyfin's own ids first, a search only as a last resort.
    nonisolated private func tmdbId(for item: BaseItem, client: TMDBClient) async -> Int? {
        if let known = await MainActor.run(body: { idMap[item.id] }) { return known }
        let ids = item.providerIds ?? [:]
        func provider(_ name: String) -> String? {
            ids.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
        let tv = item.kind == .series
        var found: Int?
        if let t = provider("Tmdb"), let n = Int(t) { found = n }
        if found == nil, let imdb = provider("Imdb"), !imdb.isEmpty { found = await client.find(externalId: imdb, source: "imdb_id", tv: tv) }
        if found == nil, let tvdb = provider("Tvdb"), !tvdb.isEmpty, tv { found = await client.find(externalId: tvdb, source: "tvdb_id", tv: tv) }
        if found == nil { found = await client.search(title: item.originalTitle ?? item.displayName, year: item.productionYear, tv: tv) }
        if found == nil, item.originalTitle != nil { found = await client.search(title: item.displayName, year: item.productionYear, tv: tv) }
        if let found { await MainActor.run { self.idMap[item.id] = found } }
        return found
    }

    private func loadIdMap() async {
        guard !idMapLoaded else { return }
        idMapLoaded = true
        if let saved = await DiskCache.loadInBackground([String: Int].self, name: "tmdb-idmap") {
            idMap.merge(saved) { a, _ in a }
        }
    }

    private func saveIdMap() {
        DiskCache.saveInBackground(idMap, name: "tmdb-idmap")
    }
}

/// Everything on the server, indexed every way a TMDB title could match it.
struct OwnedIndex {
    private var movieIds: Set<Int> = []
    private var tvIds: Set<Int> = []
    private var imdb: Set<String> = []
    private var tvdb: Set<Int> = []
    private var titles: [String: [Int?]] = [:]   // normalized title → years

    init(items: [BaseItem], idMap: [String: Int]) {
        for item in items {
            let ids = item.providerIds ?? [:]
            func provider(_ name: String) -> String? { ids.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value }
            let tmdbId = provider("Tmdb").flatMap(Int.init) ?? idMap[item.id]
            if let tmdbId { if item.kind == .series { tvIds.insert(tmdbId) } else { movieIds.insert(tmdbId) } }
            if let i = provider("Imdb"), !i.isEmpty { imdb.insert(i) }
            if let t = provider("Tvdb").flatMap(Int.init) { tvdb.insert(t) }
            for name in [item.name, item.originalTitle].compactMap({ $0 }) {
                titles[TitleKey.make(name), default: []].append(item.productionYear)
            }
        }
    }

    func contains(_ t: ExternalTitle) -> Bool {
        if t.isMovie ? movieIds.contains(t.sourceId) : tvIds.contains(t.sourceId) { return true }
        if let i = t.imdbId, imdb.contains(i) { return true }
        if let v = t.tvdbId, tvdb.contains(v) { return true }
        for name in [t.title, t.originalTitle].compactMap({ $0 }) {
            let key = TitleKey.make(name)
            guard key.count >= 3, let years = titles[key] else { continue }
            // Same title within a year (or no year known) = the same work.
            if t.year == nil || years.contains(where: { $0 == nil || abs(($0 ?? 0) - (t.year ?? 0)) <= 1 }) { return true }
            // A series you have under the same name (later seasons are part of the same TMDB show).
            if !t.isMovie { return true }
        }
        return false
    }
}

extension Sequence {
    func asyncCompactMap<T>(_ transform: (Element) async -> T?) async -> [T] {
        var out: [T] = []
        for e in self { if let v = await transform(e) { out.append(v) } }
        return out
    }
}
