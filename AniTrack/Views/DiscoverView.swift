import SwiftUI

struct DiscoverView: View {
    @State private var path = NavigationPath()
    @Environment(AppModel.self) private var model
    @Namespace private var zoom

    @State private var query = ""
    @State private var searchCategory: AnimeCategory?
    @State private var showAllCategories = false
    @State private var results: [Media] = []
    @State private var isSearching = false
    @State private var lastSearchKey = ""
    @State private var searchError: String?

    @State private var trending: [Media] = []
    @State private var thisSeason: [Media] = []
    @State private var nextSeason: [Media] = []
    @State private var topRated: [Media] = []
    @State private var loadedSections = false
    @State private var isLoadingSections = false
    @State private var isVisible = false
    @State private var shelvesSavedAt: Date?
    @State private var pendingShelves: SavedShelves?
    @State private var browseCategory: AnimeCategory?
    @State private var sectionError: String?

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    browseSections
                } else {
                    searchResults
                }
            }
            .navigationTitle("Discover")
            // Large title on the same row as the toolbar buttons (no empty row above it).
            .toolbarTitleDisplayMode(.inlineLarge)
            .mediaDestination(zoom: zoom)
            .environment(\.zoomNamespace, zoom)
            .navigationDestination(for: AnimeCategory.self) { CategoryBrowseView(category: $0) }
            // Always visible (iOS otherwise hides it until you pull the page down).
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search anime or a category")
            .task(id: "\(query)|\(searchCategory?.id ?? "")") { await search() }
            .sheet(isPresented: $showAllCategories) {
                AllCategoriesSheet { picked in
                    showAllCategories = false
                    browseCategory = picked
                }
                .presentationDetents([.medium, .large])
            }
            .navigationDestination(item: $browseCategory) { CategoryBrowseView(category: $0) }
            .task { await loadSections() }
            .onDisappear { isVisible = false }
        }
        .pushDetailAction($path)
    }

    private var browseSections: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if let sectionError {
                    Text(sectionError).foregroundStyle(.secondary).padding()
                }
                let current = AppModel.currentSeason()
                let upcoming = AppModel.currentSeason(offset: 1)
                categoryGrid
                if !trending.isEmpty { HorizontalMediaSection(title: "Trending now", items: trending) }
                if !thisSeason.isEmpty {
                    HorizontalMediaSection(title: "Popular this season · \(current.season.capitalized) \(String(current.year))",
                                           items: thisSeason)
                }
                if !nextSeason.isEmpty {
                    HorizontalMediaSection(title: "Coming next season · \(upcoming.season.capitalized) \(String(upcoming.year))",
                                           items: nextSeason)
                }
                if !topRated.isEmpty { HorizontalMediaSection(title: "All-time top rated", items: topRated) }
                // Only while there's nothing to show yet (a refresh behind saved shelves
                // never shows a spinner).
                if isLoadingSections && trending.isEmpty && thisSeason.isEmpty && nextSeason.isEmpty && topRated.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                }
            }
            .padding(.vertical)
        }
        .refreshable { await refreshShelves() }
    }

    /// Minimal "Browse by category" dropdown; picking one opens that category's page.
    private var categoryGrid: some View {
        HStack {
            Text("Categories").font(.title3.weight(.bold))
            Spacer()
            Menu {
                Section("Genres") {
                    ForEach(model.featuredCategories.filter { $0.kind == .genre }) { category in
                        Button(category.name) { browseCategory = category }
                    }
                }
                Section("Tags") {
                    ForEach(model.featuredCategories.filter { $0.kind == .tag }) { category in
                        Button(category.name) { browseCategory = category }
                    }
                }
                Divider()
                Button { showAllCategories = true } label: {
                    Label("All categories…", systemImage: "magnifyingglass")
                }
            } label: {
                HStack(spacing: 6) {
                    Text("Browse")
                    Image(systemName: "chevron.down").font(.caption.weight(.semibold))
                }
                .font(.subheadline.weight(.semibold))
            }
            .menuStyle(.button)
            .buttonStyle(.glass)
        }
        .padding(.horizontal)
    }

    private var searchResults: some View {
        List {
            Section {
                CategoryChipsBar(selected: $searchCategory)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            // Typing a category name ("isekai", "romance") offers to browse that whole category.
            let matchingCategories = categoriesMatching(query)
            if !matchingCategories.isEmpty {
                Section("Categories") {
                    ForEach(matchingCategories) { category in
                        NavigationLink(value: category) {
                            Label("Browse \(category.name)", systemImage: category.kind == .genre ? "square.stack.fill" : "tag.fill")
                        }
                    }
                }
            }
            if isSearching && results.isEmpty {
                HStack { Spacer(); ProgressView(); Spacer() }
            } else if !isSearching && results.isEmpty, let searchError {
                // Not "no results": the search itself didn't go through (typing again retries).
                ContentUnavailableView("Couldn't search", systemImage: "wifi.exclamationmark",
                                       description: Text(searchError))
            } else if !isSearching && results.isEmpty {
                ContentUnavailableView.search(text: query)
            }
            ForEach(results) { media in
                NavigationLink(value: MediaLink(id: media.id)) { MediaRow(media: media) }
            }
        }
        .listStyle(.plain)
    }

    private func categoriesMatching(_ text: String) -> [AnimeCategory] {
        let needle = text.trimmingCharacters(in: .whitespaces)
        guard needle.count >= 3 else { return [] }
        let source = model.allCategories.isEmpty ? AnimeCategory.featured : model.allCategories
        return Array(source.filter { $0.name.localizedCaseInsensitiveContains(needle) }.prefix(4))
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { results = []; lastSearchKey = ""; searchError = nil; return }
        let key = "\(text)|\(searchCategory?.id ?? "")"
        guard key != lastSearchKey else { return }   // back from a detail page: keep results
        // Debounce typing so we don't hammer the API (and the battery).
        try? await Task.sleep(nanoseconds: 450_000_000)
        guard !Task.isCancelled else { return }
        isSearching = true
        defer { isSearching = false }
        do {
            let found = try await model.browse(search: text, sort: ["SEARCH_MATCH"], category: searchCategory, perPage: 30)
            if !Task.isCancelled {
                results = found
                lastSearchKey = key
                searchError = nil
            }
        } catch {
            if !Task.isCancelled && !AppModel.isCancellation(error) {
                results = []
                searchError = "Check your connection and try again. (\(error.localizedDescription))"
            }
        }
    }

    // MARK: Shelves (saved on the phone)
    //
    // Discover opens instantly with the shelves from last time, all four at once. Shelves under
    // 6 hours old are used as they are (no requests). Older ones are fetched behind the screen
    // and swapped in only while Discover isn't on screen, so cards never change under you.
    // Pull to refresh fetches and shows fresh shelves right away.

    private struct SavedShelves: Codable {
        var trending: [Media]
        var thisSeason: [Media]
        var nextSeason: [Media]
        var topRated: [Media]
        var savedAt: Date
        /// The season the shelves were built for ("FALL-2026"); a new season starts fresh.
        var seasonKey: String
    }

    private static let shelvesFile = "discover-shelves-v1"
    private static let shelvesMaxAge: TimeInterval = 6 * 3_600
    private static var currentSeasonKey: String {
        let s = AppModel.currentSeason()
        return "\(s.season)-\(s.year)"
    }

    private func loadSections() async {
        isVisible = true
        // Fresh shelves that arrived while you were elsewhere: show them now, all at once.
        if let pending = pendingShelves {
            pendingShelves = nil
            show(pending)
        }
        if !loadedSections, let saved = await DiskCache.loadInBackground(SavedShelves.self, name: Self.shelvesFile),
           saved.seasonKey == Self.currentSeasonKey, trending.isEmpty && thisSeason.isEmpty {
            show(saved)
            loadedSections = true
            shelvesSavedAt = saved.savedAt
        }
        let stale = shelvesSavedAt.map { Date().timeIntervalSince($0) > Self.shelvesMaxAge } ?? true
        guard !loadedSections || stale else { return }
        // Nothing to show yet: load with the spinner. Otherwise refresh behind the screen.
        await fetchShelves(showWhenDone: !loadedSections)
    }

    /// Pull to refresh: always fresh, shown right away.
    private func refreshShelves() async {
        await fetchShelves(showWhenDone: true)
    }

    private func fetchShelves(showWhenDone: Bool) async {
        guard !isLoadingSections else { return }
        isLoadingSections = true
        defer { isLoadingSections = false }
        let current = AppModel.currentSeason()
        let upcoming = AppModel.currentSeason(offset: 1)
        // All four at once, with one shared first-season lookup.
        let results = await model.browseShelves([
            .init(sort: ["TRENDING_DESC", "POPULARITY_DESC"]),
            .init(sort: ["POPULARITY_DESC"], season: current.season, seasonYear: current.year),
            .init(sort: ["POPULARITY_DESC"], season: upcoming.season, seasonYear: upcoming.year),
            .init(sort: ["SCORE_DESC"])
        ])
        let failures = results.compactMap { result -> Error? in
            if case .failure(let error) = result { return error }
            return nil
        }
        // A shelf that failed keeps what it had.
        func items(_ index: Int, _ old: [Media]) -> [Media] { (try? results[index].get()) ?? old }
        let fresh = SavedShelves(trending: items(0, trending), thisSeason: items(1, thisSeason),
                                 nextSeason: items(2, nextSeason), topRated: items(3, topRated),
                                 savedAt: Date(), seasonKey: Self.currentSeasonKey)
        // Cancelled (you left the tab mid-load) isn't an error: just try again next time.
        let realFailures = failures.filter { !AppModel.isCancellation($0) }
        if failures.isEmpty {
            DiskCache.saveInBackground(fresh, name: Self.shelvesFile)
            shelvesSavedAt = fresh.savedAt
        }
        if showWhenDone || !isVisible || !query.trimmingCharacters(in: .whitespaces).isEmpty {
            show(fresh)   // asked for, or not on screen right now
        } else if failures.isEmpty {
            pendingShelves = fresh   // on screen: swapped in next time Discover appears
        }
        sectionError = realFailures.count == results.count && trending.isEmpty && thisSeason.isEmpty
            ? realFailures.first?.localizedDescription : nil
        // Anything missing is fetched again the next time Discover appears.
        loadedSections = failures.isEmpty || loadedSections
    }

    private func show(_ shelves: SavedShelves) {
        trending = shelves.trending
        thisSeason = shelves.thisSeason
        nextSeason = shelves.nextSeason
        topRated = shelves.topRated
    }
}
