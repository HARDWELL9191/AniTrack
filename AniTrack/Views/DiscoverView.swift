import SwiftUI

struct DiscoverView: View {
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
    @State private var browseCategory: AnimeCategory?
    @State private var sectionError: String?

    var body: some View {
        NavigationStack {
            Group {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    browseSections
                } else {
                    searchResults
                }
            }
            .navigationTitle("Discover")
            .mediaDestination(zoom: zoom)
            .environment(\.zoomNamespace, zoom)
            .navigationDestination(for: AnimeCategory.self) { CategoryBrowseView(category: $0) }
            .searchable(text: $query, prompt: "Search anime or a category")
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
                if !loadedSections {
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

    /// Glass tiles for the featured categories; "All categories" opens the full searchable list.
    private var categoryGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Categories").font(.title3.weight(.bold))
                Spacer()
                Button("All categories") { showAllCategories = true }
                    .font(.subheadline)
            }
            .padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                GlassEffectContainer(spacing: 10) {
                    LazyHGrid(rows: [GridItem(.fixed(44)), GridItem(.fixed(44))], spacing: 10) {
                        ForEach(model.featuredCategories) { category in
                            NavigationLink(value: category) {
                                Text(category.name)
                                    .font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 16)
                                    .frame(height: 40)
                                    .glassEffect(.regular.tint(tint(for: category)).interactive(), in: .capsule)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
    }

    private func tint(for category: AnimeCategory) -> Color {
        let palette: [Color] = [Theme.accent, Theme.pink, .purple, .orange, .teal, .indigo, .mint]
        let index = abs(category.name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }) % palette.count
        return palette[index].opacity(0.35)
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
        guard !loadedSections else { return }
        let current = AppModel.currentSeason()
        let upcoming = AppModel.currentSeason(offset: 1)
        do {
            async let t = model.browse(sort: ["TRENDING_DESC", "POPULARITY_DESC"])
            async let s = model.browse(sort: ["POPULARITY_DESC"], season: current.season, seasonYear: current.year)
            async let n = model.browse(sort: ["POPULARITY_DESC"], season: upcoming.season, seasonYear: upcoming.year)
            async let r = model.browse(sort: ["SCORE_DESC"])
            trending = try await t
            thisSeason = try await s
            nextSeason = try await n
            topRated = try await r
            sectionError = nil
        } catch {
            sectionError = error.localizedDescription
        }
        loadedSections = true
    }
}
