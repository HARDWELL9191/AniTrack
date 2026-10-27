import SwiftUI

struct DiscoverView: View {
    @Environment(AppModel.self) private var model
    @Namespace private var zoom

    @State private var query = ""
    @State private var results: [Media] = []
    @State private var isSearching = false

    @State private var trending: [Media] = []
    @State private var thisSeason: [Media] = []
    @State private var nextSeason: [Media] = []
    @State private var topRated: [Media] = []
    @State private var loadedSections = false
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
            .searchable(text: $query, prompt: "Search anime")
            .task(id: query) { await search() }
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

    private var searchResults: some View {
        List {
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

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { results = []; return }
        // Debounce typing so we don't hammer the API (and the battery).
        try? await Task.sleep(nanoseconds: 450_000_000)
        guard !Task.isCancelled else { return }
        isSearching = true
        defer { isSearching = false }
        do {
            let found = try await model.browse(search: text, sort: ["SEARCH_MATCH"], perPage: 30)
            if !Task.isCancelled { results = found }
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
