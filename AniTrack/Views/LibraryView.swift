import SwiftUI

struct LibraryView: View {
    @State private var path = NavigationPath()
    @Environment(AppModel.self) private var model
    @Namespace private var zoom

    enum SortOrder: String, CaseIterable, Identifiable {
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
    @State private var notForMeFailed = false
    @State private var userPickedStatus = false
    @State private var sort: SortOrder = .updated
    @State private var filter = ""

    /// One card per show (its other seasons on your lists are folded into it).
    private var rows: [AppModel.ShowRow] {
        var grouped = model.shows(in: [status])
        // The filter finds a show by the name of any of its seasons.
        let text = filter.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty {
            grouped = grouped.filter { row in
                ([row.entry.media.title] + row.foldedTitles).contains { t in
                    [t.english, t.romaji, t.native].compactMap { $0 }
                        .contains { $0.localizedCaseInsensitiveContains(text) }
                }
            }
        }
        let byId = Dictionary(grouped.map { ($0.entry.id, $0) }, uniquingKeysWith: { a, _ in a })
        return items(grouped.map(\.entry)).compactMap { byId[$0.id] }
    }

    private func items(_ source: [ListEntry]) -> [ListEntry] {
        var list = source   // (already filtered by `rows`)
        let lang = model.settings.titleLanguage
        switch sort {
        case .updated: list.sort { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }
        case .added: list.sort { ($0.createdAt ?? $0.updatedAt ?? 0) > ($1.createdAt ?? $1.updatedAt ?? 0) }
        case .title: list.sort { $0.media.displayTitle(lang).localizedCompare($1.media.displayTitle(lang)) == .orderedAscending }
        case .score: list.sort { $0.scoreValue > $1.scoreValue }
        case .average: list.sort { ($0.media.averageScore ?? 0) > ($1.media.averageScore ?? 0) }
        case .age:
            // 18+ first, down to PG; shows Kitsu hasn't rated go last. Ties: title.
            let rank: (ListEntry) -> Int = { e in
                switch model.ages.rating(for: e.mediaId)?.label {
                case "18+": return 4
                case "17+": return 3
                case "13+": return 2
                case "PG": return 1
                default: return 0
                }
            }
            list.sort {
                let a = rank($0), b = rank($1)
                return a != b ? a > b
                    : $0.media.displayTitle(lang).localizedCompare($1.media.displayTitle(lang)) == .orderedAscending
            }
        case .match:
            // Rated/finished shows have no match; fall back to your score for those.
            // Each show's % worked out once (not twice per comparison while sorting).
            let keys = Dictionary(list.map { ($0.id, model.matcher.match(for: $0.media) ?? Int($0.scoreValue)) },
                                  uniquingKeysWith: { a, _ in a })
            list.sort { (keys[$0.id] ?? 0) > (keys[$1.id] ?? 0) }
        }
        return list
    }

    /// Shows you marked "Not for me", filtered like the other lists.
    private var notForMeItems: [Media] {
        let lang = model.settings.titleLanguage
        var list = model.settings.dismissedPicks.compactMap { model.notForMeMedia[$0] }
        let text = filter.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty {
            list = list.filter { m in
                [m.title.english, m.title.romaji, m.title.native].compactMap { $0 }
                    .contains { $0.localizedCaseInsensitiveContains(text) }
            }
        }
        return list.sorted { $0.displayTitle(lang).localizedCompare($1.displayTitle(lang)) == .orderedAscending }
    }

    /// Card width for four across: measured from the screen, so every phone gets 4 equal columns.
    @State private var cardWidth: CGFloat = 0
    private static let columnCount = 4
    private static let columnSpacing: CGFloat = 10
    private static let sidePadding: CGFloat = 16

    private var columns: [GridItem] {
        Array(repeating: GridItem(.fixed(cardWidth), spacing: Self.columnSpacing, alignment: .top),
              count: Self.columnCount)
    }

    var body: some View {
        NavigationStack(path: $path) {
            // A grid of covers like Home (long-press a cover for everything a swipe used to do).
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    statusBar
                        .padding(.horizontal, Self.sidePadding)
                        .padding(.top, 4)
                    if showingNotForMe {
                        notForMeGrid
                    } else {
                        listGrid
                    }
                }
                .padding(.bottom, 24)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                let spacing = Self.columnSpacing * CGFloat(Self.columnCount - 1)
                let fitted = ((width - Self.sidePadding * 2 - spacing) / CGFloat(Self.columnCount)).rounded(.down)
                if fitted > 0, fitted != cardWidth { cardWidth = fitted }
            }
            .navigationTitle("Lists")
            // Large title on the same row as the toolbar buttons (no empty row above it).
            .toolbarTitleDisplayMode(.inlineLarge)
            .mediaDestination(zoom: zoom)
            .environment(\.zoomNamespace, zoom)
            // Always shown (like Discover), so the pull-to-refresh spinner sits under it.
            .searchable(text: $filter, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Filter this list")
            .refreshable {
                await model.refreshList()
                if showingNotForMe {
                    let ok = await model.loadNotForMeMedia()
                    notForMeFailed = !ok
                }
            }
            .onAppear { pickDefaultStatus() }
            .task(id: showingNotForMe) {
                if showingNotForMe {
                    let ok = await model.loadNotForMeMedia()
                    notForMeFailed = !ok
                }
            }
            .onChange(of: model.entries.count) { _, _ in pickDefaultStatus() }
            // Sorting by age: make sure every show in this list has its rating (saved on the
            // phone for good, so this costs nothing after the first time).
            .task(id: "\(sort.rawValue)|\(status.rawValue)") {
                guard sort == .age else { return }
                for row in model.shows(in: [status]) { model.ages.request(row.entry.media) }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Sort", selection: $sort) {
                            ForEach(SortOrder.allCases) { Text($0.rawValue).tag($0) }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                }
            }
        }
        .pushDetailAction($path)
    }

    /// Your shows in the picked list, four across.
    @ViewBuilder
    private var listGrid: some View {
        let shown = rows
        if shown.isEmpty {
            message(model.isLoadingList || !model.listLoadedOnce
                    ? "Loading…"
                    : (filter.trimmingCharacters(in: .whitespaces).isEmpty
                       ? "No shows marked \(status.label.lowercased())." : "No matches."))
        } else if cardWidth > 0 {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                ForEach(shown) { row in
                    card(row.entry.media)
                }
            }
            .padding(.horizontal, Self.sidePadding)
        }
    }

    /// Shows you marked "Not for me", same grid (long-press → Bring back).
    @ViewBuilder
    private var notForMeGrid: some View {
        let shows = notForMeItems
        if shows.isEmpty {
            message(model.settings.dismissedPicks.isEmpty
                    ? "Nothing here. Shows you mark \"Not for me\" in For You appear here."
                    : (!filter.isEmpty ? "No matches."
                       : (notForMeFailed ? "Couldn't load these shows. Pull down to try again." : "Loading…")))
        } else {
            Text("Hidden from your picks. Long-press a show and choose Bring back to see it again.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, Self.sidePadding)
            if cardWidth > 0 {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                    ForEach(shows) { media in
                        card(media)
                    }
                }
                .padding(.horizontal, Self.sidePadding)
            }
        }
    }

    private func card(_ media: Media) -> some View {
        NavigationLink(value: MediaLink(id: media.id)) {
            // Every show here is in the list you're looking at: no status icon on each cover.
            MediaCard(media: media, width: cardWidth, showsStatus: false)
        }
        .buttonStyle(.plain)
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Self.sidePadding)
            .padding(.top, 40)
    }

    /// Status dropdown: one glass button showing the current list and its count.
    private var statusBar: some View {
        HStack {
            Spacer()   // on the right, within thumb reach
            Menu {
                ForEach(ListStatus.allCases) { s in
                    Button {
                        userPickedStatus = true
                        showingNotForMe = false
                        status = s
                    } label: {
                        if s == status && !showingNotForMe {
                            Label("\(s.label) (\(model.showCount(of: s)))", systemImage: "checkmark")
                        } else {
                            Label("\(s.label) (\(model.showCount(of: s)))", systemImage: s.symbol)
                        }
                    }
                }
                Divider()
                Button {
                    userPickedStatus = true
                    showingNotForMe = true
                } label: {
                    Label("Not for me (\(model.settings.dismissedPicks.count))",
                          systemImage: showingNotForMe ? "checkmark" : "hand.thumbsdown")
                }
            } label: {
                HStack(spacing: 6) {
                    if showingNotForMe {
                        Image(systemName: "hand.thumbsdown")
                        Text("Not for me (\(model.settings.dismissedPicks.count))")
                    } else {
                        Image(systemName: status.symbol)
                        Text("\(status.label) (\(model.showCount(of: status)))")
                    }
                    Image(systemName: "chevron.down").font(.caption.weight(.semibold))
                }
                .font(.subheadline.weight(.semibold))
            }
            .menuStyle(.button)
            .buttonStyle(.glass)
        }
    }

    /// Opens on the first status that actually has shows, unless you already picked one.
    private func pickDefaultStatus() {
        guard !userPickedStatus, !showingNotForMe, model.showCount(of: status) == 0 else { return }
        let order: [ListStatus] = [.CURRENT, .REPEATING, .PLANNING, .COMPLETED, .PAUSED, .DROPPED]
        if let first = order.first(where: { model.showCount(of: $0) > 0 }) { status = first }
    }
}
