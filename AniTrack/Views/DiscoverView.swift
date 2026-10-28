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

    @State private var trending: [Media] = []
    @State private var thisSeason: [Media] = []
    @State private var nextSeason: [Media] = []
    @State private var topRated: [Media] = []
    @State private var loadedSections = false
    @State private var isLoadingSections = false
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
                // Only while shelves are actually loading (one failed shelf used to leave it
                // spinning forever under the ones that did load).
                if isLoadingSections {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                }
            }
            .padding(.vertical)
        }
        .refreshable {
            loadedSections = false
            await loadSections()
        }
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
        guard !text.isEmpty else { results = []; lastSearchKey = ""; return }
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
            }
        } catch {
            if !Task.isCancelled { results = [] }
        }
    }

    private func loadSections() async {
        guard !loadedSections, !isLoadingSections else { return }
        isLoadingSections = true
        defer { isLoadingSections = false }
        let current = AppModel.currentSeason()
        let upcoming = AppModel.currentSeason(offset: 1)
        // Each shelf loads on its own: one failing doesn't blank the others.
        async let t = shelf(sort: ["TRENDING_DESC", "POPULARITY_DESC"])
        async let s = shelf(sort: ["POPULARITY_DESC"], season: current.season, year: current.year)
        async let n = shelf(sort: ["POPULARITY_DESC"], season: upcoming.season, year: upcoming.year)
        async let r = shelf(sort: ["SCORE_DESC"])
        // Shelves that already loaded are kept (only the missing ones matter on a retry).
        let results = [await t, await s, await n, await r]
        var failures: [Error] = []
        for (index, result) in results.enumerated() {
            switch result {
            case .success(let items):
                withAnimation(.snappy) {
                    switch index {
                    case 0: trending = items
                    case 1: thisSeason = items
                    case 2: nextSeason = items
                    default: topRated = items
                    }
                }
            case .failure(let error):
                failures.append(error)
            }
        }
        // Cancelled (you left the tab mid-load) isn't an error: just try again next time.
        let realFailures = failures.filter { !AppModel.isCancellation($0) }
        sectionError = realFailures.count == results.count ? realFailures.first?.localizedDescription : nil
        // Anything missing is fetched again the next time Discover appears.
        loadedSections = failures.isEmpty
    }

    private func shelf(sort: [String], season: String? = nil, year: Int? = nil) async -> Result<[Media], Error> {
        do {
            return .success(try await model.browse(sort: sort, season: season, seasonYear: year))
        } catch {
            return .failure(error)
        }
    }
}
