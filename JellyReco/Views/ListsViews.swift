import SwiftUI

// MARK: - Shared pieces

/// "On your server" filter of the lists.
enum ServerFilter: Int, CaseIterable, Identifiable {
    case all, onServer, notOnServer
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .all: "All"
        case .onServer: "On your server"
        case .notOnServer: "Not on server yet"
        }
    }
    var symbol: String {
        switch self {
        case .all: "bookmark"
        case .onServer: "server.rack"
        case .notOnServer: "icloud.and.arrow.down"
        }
    }
    func keeps(onServer: Bool) -> Bool {
        switch self {
        case .all: true
        case .onServer: onServer
        case .notOnServer: !onServer
        }
    }
}

/// Everything on your Jellyfin server, indexed every way a saved title could match it: the ids
/// Jellyfin stored (AniList, MyAnimeList, TMDB, IMDb), then any of its names (movies within a year).
struct ServerTitleIndex {
    private var anilist: [Int: BaseItem] = [:]
    private var mal: [Int: BaseItem] = [:]
    private var tmdb: [String: BaseItem] = [:]
    private var imdb: [String: BaseItem] = [:]
    private var byName: [String: [BaseItem]] = [:]

    init() {}

    init(items: [BaseItem]) {
        for item in items where item.kind == .series || item.kind == .movie {
            let kind = item.kind == .series ? "s" : "m"
            for (key, value) in item.providerIds ?? [:] {
                switch key.lowercased() {
                case "anilist": if let n = Int(value) { anilist[n] = item }
                case "myanimelist", "mal": if let n = Int(value) { mal[n] = item }
                case "tmdb": tmdb["\(kind):\(value)"] = item
                case "imdb": imdb[value] = item
                default: break
                }
            }
            for name in Set([item.displayName, item.originalTitle].compactMap { $0 }) {
                let key = TitleKey.make(name)
                guard key.count >= 3 else { continue }
                byName["\(kind):\(key)", default: []].append(item)
            }
        }
    }

    private func named(_ names: [String], movie: Bool, year: Int?) -> BaseItem? {
        for name in names {
            guard let same = byName["\(movie ? "m" : "s"):\(TitleKey.make(name))"] else { continue }
            let sameYear = same.first { item in
                guard let a = year, let b = item.productionYear else { return true }
                return abs(a - b) <= 1
            }
            // A remake isn't the film you have; a show's later seasons are the same show.
            if let hit = sameYear ?? (movie ? nil : same.first) { return hit }
        }
        return nil
    }

    /// The server copy of an AniList show, if you have it.
    func item(for m: Media) -> BaseItem? {
        if let hit = anilist[m.id] { return hit }
        if let id = m.idMal, let hit = mal[id] { return hit }
        return named(m.allTitles, movie: m.isMovie, year: m.seasonYear)
    }

    /// The server copy of a saved For You pick, if it has been added since.
    func item(for t: ExternalTitle) -> BaseItem? {
        if t.isAniList {
            if let hit = anilist[t.sourceId] { return hit }
        } else {
            if let hit = tmdb["\(t.isMovie ? "m" : "s"):\(t.sourceId)"] { return hit }
            if let id = t.imdbId, let hit = imdb[id] { return hit }
        }
        return named([t.title, t.originalTitle].compactMap { $0 }, movie: t.isMovie, year: t.year)
    }
}

/// Community score out of 10 with a mood face (AniReco's ScoreBadge); `score` is 0–100.
struct ListScoreBadge: View {
    let score: Int?
    var body: some View {
        if let score, score > 0 {
            Label(String(format: "%.1f/10", Double(score) / 10),
                  systemImage: score >= 75 ? "face.smiling.inverse" : (score >= 60 ? "face.smiling" : "face.dashed"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(score >= 75 ? .green : (score >= 60 ? .orange : .red))
        }
    }
}

/// The wand and the pink match bubble of a list row.
struct ListMatchBadge: View {
    let value: Int?
    var body: some View {
        if let value {
            HStack(spacing: 5) {
                Image(systemName: "wand.and.stars").font(.caption.weight(.semibold)).foregroundStyle(Theme.pink)
                MatchBubble(value: value)
            }
        }
    }
}

/// AniReco's list row: cover, title, one line of facts, then score · match · age.
struct ListRow<Badges: View>: View {
    let imageURL: URL?
    let title: String
    let subtitle: String
    var placeholder = "film"
    var notOnServer = false
    @ViewBuilder let badges: () -> Badges

    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(url: imageURL, placeholderSymbol: placeholder)
                .frame(width: 54, height: 78)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 10) { badges() }
            }
            Spacer(minLength: 0)
            if notOnServer {
                Image(systemName: "icloud.and.arrow.down")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Not on your server yet")
            }
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

/// A row pressed: AniReco's rounded grey highlight.
struct ListRowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                if configuration.isPressed {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(.systemGray5))
                        .padding(-8)
                }
            }
    }
}

/// Age labels ordered from 18+ down to PG; titles without one last.
private func ageRank(_ label: String?) -> Int {
    switch label {
    case "18+": 4
    case "17+": 3
    case "13+": 2
    case "PG": 1
    default: 0
    }
}

/// Keeps the server's library index fresh for a list (rebuilt only when the library changed).
private struct ServerIndexLoader: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var index: ServerTitleIndex
    @State private var revision = -1

    func body(content: Content) -> some View {
        content.task(id: model.reco.libraryRevision) {
            if model.reco.libraryItems.isEmpty { await model.reco.ensureBuilt() }
            guard revision != model.reco.libraryRevision else { return }
            index = ServerTitleIndex(items: model.reco.libraryItems)
            revision = model.reco.libraryRevision
        }
    }
}

// MARK: - Anime lists (AniReco's Lists, on your AniList account)

/// Your AniList lists, exactly like AniReco's Lists tab: the lists dropdown on the right, a filter
/// on the left (on your server or not, and AniReco's categories), sorting in the top right.
/// Anime saved to My List on your server (from an anime library) show under Planning too.
struct AnimeListsView: View {
    @Environment(AppModel.self) private var model

    enum Sort: String, CaseIterable, Identifiable {
        case match = "Best match"
        case added = "Recently added"
        case updated = "Last updated"
        case title = "Title"
        case score = "My score"
        case average = "Average score"
        case age = "Age rating"
        var id: String { rawValue }
    }

    @State private var status: ListStatus = .CURRENT
    @State private var showingNotForMe = false
    @State private var userPickedStatus = false
    @State private var sort: Sort = .updated
    @State private var text = ""
    @State private var server: ServerFilter = .all
    @State private var category: AnimeCategory?
    @State private var showAllCategories = false
    @State private var index = ServerTitleIndex()
    @State private var detail: ExternalTitle?

    private var anilist: AniListService { model.anilist }
    private var language: TitleLanguage { anilist.language }

    // MARK: Rows

    private enum Row: Identifiable {
        case show(AniListService.ShowRow)
        case server(MyListEntry, BaseItem)
        var id: String {
            switch self {
            case .show(let r): "a:\(r.id)"
            case .server(let e, _): "s:\(e.id)"
            }
        }
    }

    /// Anime libraries' titles saved to My List on your server that aren't on your AniList list.
    private var serverAnime: [(MyListEntry, BaseItem)] {
        let onList = Set(anilist.entries.compactMap { index.item(for: $0.media)?.id })
        return model.myList.compactMap { entry -> (MyListEntry, BaseItem)? in
            guard let id = entry.serverId, let item = model.reco.libraryItem(id), isAnimeLibrary(id),
                  !onList.contains(item.id) else { return nil }
            return (entry, item)
        }
    }

    private func isAnimeLibrary(_ itemId: String) -> Bool {
        guard let lib = model.reco.libraryId(of: itemId) else { return false }
        return AniListLibrary(libraryName: model.libraries.first { $0.id == lib }?.name) != nil
    }

    private func matchesText(_ names: [String?]) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return true }
        return names.compactMap { $0 }.contains { $0.localizedCaseInsensitiveContains(t) }
    }

    private func count(_ s: ListStatus) -> Int {
        anilist.showCount(of: s) + (s == .PLANNING ? serverAnime.count : 0)
    }

    private var rows: [Row] {
        var shows = anilist.shows(in: [status]).filter { row in
            server.keeps(onServer: index.item(for: row.entry.media) != nil)
                && (category?.matches(row.entry.media) ?? true)
                && ([row.entry.media.title] + row.foldedTitles).contains { matchesText([$0.english, $0.romaji, $0.native]) }
        }
        sortShows(&shows)
        var result = shows.map(Row.show)
        if status == .PLANNING, server != .notOnServer, category == nil {
            result += serverAnime
                .filter { matchesText([$0.1.displayName, $0.1.originalTitle]) }
                .map { Row.server($0.0, $0.1) }
        }
        return result
    }

    private func sortShows(_ list: inout [AniListService.ShowRow]) {
        switch sort {
        case .updated: list.sort { ($0.entry.updatedAt ?? 0) > ($1.entry.updatedAt ?? 0) }
        case .added: list.sort { ($0.entry.createdAt ?? $0.entry.updatedAt ?? 0) > ($1.entry.createdAt ?? $1.entry.updatedAt ?? 0) }
        case .title: list.sort { $0.entry.media.displayTitle(language).localizedCompare($1.entry.media.displayTitle(language)) == .orderedAscending }
        case .score: list.sort { $0.entry.scoreValue > $1.entry.scoreValue }
        case .average: list.sort { ($0.entry.media.averageScore ?? 0) > ($1.entry.media.averageScore ?? 0) }
        case .age:
            list.sort {
                let a = ageRank(anilist.ages.rating(for: $0.entry.mediaId)?.label), b = ageRank(anilist.ages.rating(for: $1.entry.mediaId)?.label)
                return a != b ? a > b
                    : $0.entry.media.displayTitle(language).localizedCompare($1.entry.media.displayTitle(language)) == .orderedAscending
            }
        case .match:
            // Rated/finished shows fall back to your score.
            let keys = Dictionary(list.map { ($0.id, anilist.matcher.match(for: $0.entry.media) ?? Int($0.entry.scoreValue)) },
                                  uniquingKeysWith: { a, _ in a })
            list.sort { (keys[$0.id] ?? 0) > (keys[$1.id] ?? 0) }
        }
    }

    private var notForMeRows: [Media] {
        anilist.notForMeTitles
            .filter { server.keeps(onServer: index.item(for: $0) != nil) && (category?.matches($0) ?? true)
                && matchesText([$0.title.english, $0.title.romaji, $0.title.native]) }
            .sorted { $0.displayTitle(language).localizedCompare($1.displayTitle(language)) == .orderedAscending }
    }

    // MARK: Body

    var body: some View {
        List {
            controls
                .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 12, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            if !anilist.isLoggedIn {
                AniListConnectCard(library: .shows)
                    .listRowSeparator(.hidden)
            } else if showingNotForMe {
                notForMeSection
            } else {
                let shown = rows
                if shown.isEmpty {
                    Text(anilist.isLoadingList || !anilist.listLoadedOnce ? "Loading…"
                         : (text.isEmpty && server == .all && category == nil
                            ? "No shows marked \(status.label.lowercased())." : "No matches."))
                        .foregroundStyle(.secondary)
                }
                ForEach(shown) { row in
                    switch row {
                    case .show(let r): showRow(r)
                    case .server(let entry, let item): serverRow(entry, item)
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Anime lists")
        .searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: "Filter this list")
        .refreshable { await anilist.refreshList() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort", selection: $sort) {
                        ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
                    }
                } label: { Image(systemName: "arrow.up.arrow.down") }
                .accessibilityLabel("Sort")
            }
        }
        .modifier(ServerIndexLoader(index: $index))
        .task {
            anilist.syncAccount()
            if anilist.categories.isEmpty { await anilist.loadCategories() }
        }
        .onAppear { pickDefaultStatus() }
        .onChange(of: anilist.entries.count) { _, _ in pickDefaultStatus() }
        .task(id: "\(sort.rawValue)|\(status.rawValue)") {
            guard sort == .age else { return }
            for row in anilist.shows(in: [status]) { anilist.ages.request(id: row.entry.mediaId, mal: row.entry.media.idMal) }
        }
        .sheet(item: $detail) { ExternalDetailSheet(title: $0) }
    }

    // MARK: Controls

    private var controls: some View {
        HStack {
            filterMenu
            Spacer(minLength: 8)
            listsMenu
        }
    }

    /// On your server or not, and AniReco's categories (popular genres and tags, "All categories…").
    private var filterMenu: some View {
        let label = [server == .all ? nil : server.label, category?.name].compactMap { $0 }.joined(separator: " · ")
        return Menu {
            Section("Show") {
                ForEach(ServerFilter.allCases) { f in
                    Button { server = f } label: { Label(f.label, systemImage: server == f ? "checkmark" : f.symbol) }
                }
            }
            AniCategoryMenuItems(selected: $category, showAll: $showAllCategories)
        } label: {
            DropdownLabel(text: label.isEmpty ? "All" : label, symbol: "line.3.horizontal.decrease")
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .accessibilityLabel("Filter")
        .sheet(isPresented: $showAllCategories) {
            AniAllCategoriesSheet { picked in
                category = picked
                showAllCategories = false
            }
            .presentationDetents([.medium, .large])
        }
    }

    /// AniReco's lists dropdown: the current list and its count.
    private var listsMenu: some View {
        Menu {
            ForEach(ListStatus.allCases) { s in
                Button {
                    userPickedStatus = true
                    showingNotForMe = false
                    status = s
                } label: {
                    Label("\(s.label) (\(count(s)))", systemImage: s == status && !showingNotForMe ? "checkmark" : s.symbol)
                }
            }
            Divider()
            Button {
                userPickedStatus = true
                showingNotForMe = true
            } label: {
                Label("Not for me (\(anilist.dismissed.count))", systemImage: showingNotForMe ? "checkmark" : "hand.thumbsdown")
            }
        } label: {
            HStack(spacing: 6) {
                if showingNotForMe {
                    Image(systemName: "hand.thumbsdown").frame(height: 0)
                    Text("Not for me (\(anilist.dismissed.count))")
                } else {
                    Image(systemName: status.symbol).frame(height: 0)
                    Text("\(status.label) (\(count(status)))")
                }
                Image(systemName: "chevron.down").font(.caption.weight(.semibold)).frame(height: 0)
            }
            .lineLimit(1)
            .menuButtonHeight()
            .font(.subheadline.weight(.semibold))
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .accessibilityLabel("Lists")
    }

    /// Opens on the first list that has shows, unless you already picked one.
    private func pickDefaultStatus() {
        guard !userPickedStatus, !showingNotForMe, count(status) == 0 else { return }
        let order: [ListStatus] = [.CURRENT, .REPEATING, .PLANNING, .COMPLETED, .PAUSED, .DROPPED]
        if let first = order.first(where: { count($0) > 0 }) { status = first }
    }

    // MARK: Rows

    private func subtitle(_ entry: ListEntry, extraSeasons: Int) -> String {
        var parts: [String] = []
        if extraSeasons > 0 { parts.append("\(extraSeasons + 1) seasons") }
        if entry.scoreValue > 0 { parts.append("Your score ★ \(Self.score(entry.scoreValue))") }
        parts.append(entry.media.formatLabel)
        if let season = entry.media.seasonLabel { parts.append(season) }
        return parts.joined(separator: " · ")
    }

    private static func score(_ raw: Double) -> String {
        let ten = raw / 10
        return ten == ten.rounded() ? String(Int(ten)) : String(format: "%.1f", ten)
    }

    private func animeRow(_ media: Media, subtitle: String) -> some View {
        let owned = index.item(for: media)
        return Button {
            if let owned, let open = openDetails { open(owned) } else { detail = anilist.title(for: media) }
        } label: {
            ListRow(imageURL: media.thumbURL.flatMap(URL.init(string:)), title: media.displayTitle(language),
                    subtitle: subtitle, placeholder: "tv", notOnServer: owned == nil) {
                ListScoreBadge(score: media.averageScore)
                ListMatchBadge(value: anilist.matcher.match(for: media))
                AniListAgeBubble(id: media.id)
            }
        }
        .buttonStyle(ListRowPressStyle())
        .contextMenu {
            if let owned, let open = openDetails {
                Button("Open on your server", systemImage: "play.rectangle") { open(owned) }
            }
            Button("Details", systemImage: "info.circle") { detail = anilist.title(for: media) }
        }
    }

    @Environment(\.openDetails) private var openDetails

    private func showRow(_ r: AniListService.ShowRow) -> some View {
        animeRow(r.entry.media, subtitle: subtitle(r.entry, extraSeasons: r.extraSeasons))
            // AniReco: swipe left removes the show (every season), swipe right marks it completed.
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) {
                    Task { await anilist.removeFromPlanning(r.entry.mediaId) }
                } label: { Label("Remove", systemImage: "trash") }
            }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                if r.entry.status != .COMPLETED {
                    Button {
                        Task { await anilist.markCompleted(r.entry.media) }
                    } label: { Label("Completed", systemImage: "checkmark.circle.fill") }
                    .tint(.green)
                }
            }
    }

    private func serverRow(_ entry: MyListEntry, _ item: BaseItem) -> some View {
        Button { openDetails?(item) } label: {
            ServerItemRow(item: item)
        }
        .buttonStyle(ListRowPressStyle())
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                Task { await model.removeFromMyList(entry) }
            } label: { Label("Remove", systemImage: "trash") }
        }
    }

    @ViewBuilder
    private var notForMeSection: some View {
        let shows = notForMeRows
        if shows.isEmpty {
            Text(anilist.dismissed.isEmpty ? "Nothing here. Shows you mark \"Not for me\" in For You appear here."
                 : (text.isEmpty && server == .all && category == nil ? "Loading…" : "No matches."))
                .foregroundStyle(.secondary)
        } else {
            Text("Hidden from your picks. Swipe left on a show to bring it back.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .listRowSeparator(.hidden)
        }
        ForEach(shows) { media in
            animeRow(media, subtitle: [media.formatLabel, media.seasonLabel].compactMap { $0 }.joined(separator: " · "))
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button {
                        Task { await anilist.undoNotForMe(media.id) }
                    } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                    .tint(.blue)
                }
        }
    }
}

// MARK: - Movies / TV Shows

/// A server movie or show in a list row.
struct ServerItemRow: View {
    @Environment(AppModel.self) private var model
    let item: BaseItem

    var body: some View {
        ListRow(imageURL: model.client?.posterURL(item, width: 162), title: item.displayName,
                subtitle: Self.facts(item), placeholder: item.kind == .series ? "tv" : "film") {
            ListScoreBadge(score: item.communityRating.map { Int(($0 * 10).rounded()) })
            ListMatchBadge(value: model.reco.match(for: item))
            if let age = item.officialRating.flatMap(TMDBCertification.bucket) { GlassLabel(text: age) }
        }
    }

    static func facts(_ item: BaseItem) -> String {
        var parts: [String] = [item.kind == .series ? "TV show" : "Movie"]
        if let y = item.productionYear { parts.append("\(y)") }
        if item.kind == .series, let n = item.childCount, n > 0 { parts.append(n == 1 ? "1 season" : "\(n) seasons") }
        if item.kind == .movie, let ticks = item.runTimeTicks, ticks > 0 { parts.append(Fmt.runtime(Double(ticks) / 10_000_000)) }
        return parts.joined(separator: " · ")
    }
}

/// My List's movies or TV shows (everything but anime, which lives on AniList): "On your server"
/// on the left, a genre dropdown on the right, sorting in the top right.
struct TitleListView: View {
    enum Kind: Hashable {
        case movies, shows
        var title: String { self == .movies ? "Movie list" : "TV Show list" }
        var noun: String { self == .movies ? "movies" : "shows" }
    }

    enum Sort: String, CaseIterable, Identifiable {
        case match = "Best match"
        case added = "Recently added"
        case title = "Title"
        case average = "Average score"
        case age = "Age rating"
        case year = "Year"
        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.openDetails) private var openDetails
    let kind: Kind

    @State private var server: ServerFilter = .all
    @State private var genre: String?
    @State private var sort: Sort = .added
    @State private var text = ""
    @State private var index = ServerTitleIndex()
    @State private var loaded: [String: BaseItem] = [:]
    @State private var detail: ExternalTitle?

    /// One saved title, as a server item (yours, or added since it was saved) or a For You pick.
    private struct Row: Identifiable {
        let entry: MyListEntry
        let item: BaseItem?
        let external: ExternalTitle?
        var id: String { entry.id }
        var name: String { item?.displayName ?? external?.title ?? entry.name ?? "" }
        var genres: [String] { item?.genres ?? external?.genres ?? [] }
        var year: Int? { item?.productionYear ?? external?.year }
        var score: Int? { (item?.communityRating ?? external?.score).map { Int(($0 * 10).rounded()) } }
        var age: String? { item?.officialRating.flatMap(TMDBCertification.bucket) ?? external?.ageLabel }
    }

    private func serverItem(_ id: String) -> BaseItem? { model.reco.libraryItem(id) ?? loaded[id] }

    private func isAnimeLibrary(_ itemId: String) -> Bool {
        guard let lib = model.reco.libraryId(of: itemId) else { return false }
        return AniListLibrary(libraryName: model.libraries.first { $0.id == lib }?.name) != nil
    }

    /// This kind's titles on My List (anime libraries and AniList picks go to Anime lists).
    private var all: [Row] {
        model.myList.compactMap { entry -> Row? in
            if let id = entry.serverId {
                guard let item = serverItem(id), !isAnimeLibrary(id) else { return nil }
                guard (kind == .movies) == (item.kind == .movie), item.kind == .movie || item.kind == .series else { return nil }
                return Row(entry: entry, item: item, external: nil)
            }
            guard let ext = entry.external, !ext.isAniList, (kind == .movies) == ext.isMovie else { return nil }
            return Row(entry: entry, item: index.item(for: ext), external: ext)
        }
    }

    private func onServer(_ r: Row) -> Bool { r.item != nil }

    private var genres: [String] {
        Array(Set(all.flatMap(\.genres))).sorted { $0.localizedCompare($1) == .orderedAscending }
    }

    private var rows: [Row] {
        let t = text.trimmingCharacters(in: .whitespaces)
        var list = all.filter { r in
            server.keeps(onServer: onServer(r))
                && (genre.map { r.genres.contains($0) } ?? true)
                && (t.isEmpty || [r.name, r.item?.originalTitle, r.external?.originalTitle].compactMap { $0 }
                    .contains { $0.localizedCaseInsensitiveContains(t) })
        }
        let byName: (Row, Row) -> Bool = { $0.name.localizedCompare($1.name) == .orderedAscending }
        switch sort {
        case .added: list.sort { $0.entry.addedAt > $1.entry.addedAt }
        case .title: list.sort(by: byName)
        case .average: list.sort { ($0.score ?? 0) > ($1.score ?? 0) }
        case .year: list.sort { ($0.year ?? 0) != ($1.year ?? 0) ? ($0.year ?? 0) > ($1.year ?? 0) : byName($0, $1) }
        case .age: list.sort { ageRank($0.age) != ageRank($1.age) ? ageRank($0.age) > ageRank($1.age) : byName($0, $1) }
        case .match:
            let keys = Dictionary(list.map { ($0.id, $0.item.flatMap { model.reco.match(for: $0) } ?? -1) }, uniquingKeysWith: { a, _ in a })
            list.sort { (keys[$0.id] ?? -1) != (keys[$1.id] ?? -1) ? (keys[$0.id] ?? -1) > (keys[$1.id] ?? -1) : byName($0, $1) }
        }
        return list
    }

    var body: some View {
        List {
            controls
                .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 12, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            let shown = rows
            if shown.isEmpty {
                Text(model.myList.isEmpty || all.isEmpty
                     ? "No \(kind.noun) on My List yet. Add them with \"Add to My List\" on a title's page, on For You picks, or by long-pressing a poster."
                     : "No matches.")
                    .foregroundStyle(.secondary)
            }
            ForEach(shown) { row($0) }
        }
        .listStyle(.plain)
        .navigationTitle(kind.title)
        .searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: "Filter this list")
        .refreshable {
            await model.loadAccountStorage()
            await loadMissing(reload: true)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort", selection: $sort) {
                        ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
                    }
                } label: { Image(systemName: "arrow.up.arrow.down") }
                .accessibilityLabel("Sort")
            }
        }
        .modifier(ServerIndexLoader(index: $index))
        .task(id: model.myList.map(\.id) + ["\(model.reco.libraryRevision)"]) { await loadMissing() }
        .sheet(item: $detail) { ExternalDetailSheet(title: $0) }
    }

    private var controls: some View {
        let list = all
        func count(_ f: ServerFilter) -> Int { list.filter { f.keeps(onServer: onServer($0)) }.count }
        return HStack {
            Menu {
                ForEach(ServerFilter.allCases) { f in
                    Button { server = f } label: {
                        Label("\(f.label) (\(count(f)))", systemImage: server == f ? "checkmark" : f.symbol)
                    }
                }
            } label: {
                DropdownLabel(text: "\(server.label) (\(count(server)))", symbol: server.symbol)
            }
            .menuStyle(.button)
            .buttonStyle(.glass)
            .accessibilityLabel("On your server")
            Spacer(minLength: 8)
            Menu {
                Button { genre = nil } label: {
                    if genre == nil { Label("Any genre", systemImage: "checkmark") } else { Text("Any genre") }
                }
                if !genres.isEmpty {
                    Divider()
                    ForEach(genres, id: \.self) { g in
                        Button { genre = g } label: {
                            if genre == g { Label(g, systemImage: "checkmark") } else { Text(g) }
                        }
                    }
                }
            } label: {
                DropdownLabel(text: genre ?? "Any genre", symbol: "line.3.horizontal.decrease")
            }
            .menuStyle(.button)
            .buttonStyle(.glass)
            .accessibilityLabel("Genre")
        }
    }

    @ViewBuilder
    private func row(_ r: Row) -> some View {
        Group {
            if let item = r.item {
                Button { openDetails?(item) } label: { ServerItemRow(item: item) }
            } else if let ext = r.external {
                Button { detail = ext } label: {
                    ListRow(imageURL: ext.posterURL, title: ext.title, subtitle: ext.metaLine,
                            placeholder: ext.isMovie ? "film" : "tv", notOnServer: true) {
                        ListScoreBadge(score: r.score)
                        if let age = ext.ageLabel { GlassLabel(text: age) }
                    }
                }
            }
        }
        .buttonStyle(ListRowPressStyle())
        .contextMenu {
            if let ext = r.external, r.item == nil {
                Button("Details", systemImage: "info.circle") { detail = ext }
                Button("Already seen", systemImage: "eye") { Task { await model.markSeenElsewhere(ext) } }
                Button("Not for me", systemImage: "hand.thumbsdown") { Task { await model.markExternalNotForMe(ext) } }
            }
            Button("Remove from My List", systemImage: "bookmark.slash", role: .destructive) {
                Task { await model.removeFromMyList(r.entry) }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                Task { await model.removeFromMyList(r.entry) }
            } label: { Label("Remove", systemImage: "trash") }
        }
    }

    /// Saved server titles the library index doesn't have (yet), read in batches of 100.
    private func loadMissing(reload: Bool = false) async {
        guard let client = model.client else { return }
        let ids = model.myList.compactMap(\.serverId).filter { reload || (model.reco.libraryItem($0) == nil && loaded[$0] == nil) }
        guard !ids.isEmpty else { return }
        for start in stride(from: 0, to: ids.count, by: 100) {
            var q = JellyfinClient.ItemQuery()
            q.ids = Array(ids[start..<min(start + 100, ids.count)])
            q.limit = q.ids.count
            q.isMissing = nil
            for item in (try? await client.items(q).items) ?? [] { loaded[item.id] = item }
        }
    }
}
