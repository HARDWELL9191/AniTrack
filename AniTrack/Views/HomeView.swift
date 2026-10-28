import SwiftUI

/// Suggestion-first Home: your picks, the best matches airing this season, which planned
/// show fits you best right now, and what's trending, all with personal match %.
struct HomeView: View {
    @State private var path = NavigationPath()
    @Environment(AppModel.self) private var model
    @Namespace private var zoom
    @State private var trending: [Media] = []
    @State private var season: [Media] = []
    // Discovery beyond your usual taste
    @State private var gems: [Media] = []
    @State private var outside: [Media] = []
    @State private var outsideGenres: [String] = []
    @State private var surprise: [Media] = []

    var body: some View {
        NavigationStack(path: $path) {
            // A plain scrolling page (not a List): inside a List each row of covers is one cell,
            // so a long-press lifted the whole row and used the first cover's menu.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                if let viewer = model.viewer {
                    ProfileHeader(viewer: viewer)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(Color(.secondarySystemGroupedBackground),
                                    in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                        .padding(.horizontal, 16)
                }

                pickedForYou

                let bestThisSeason = seasonBestMatches
                if !bestThisSeason.isEmpty {
                    let s = AppModel.currentSeason()
                    HomeSection {
                        cardRow(bestThisSeason)
                    } header: {
                        Label("Best matches · \(s.season.capitalized) \(String(s.year))", systemImage: "sparkles")
                    }
                }

                let planning = planningByMatch
                if !planning.isEmpty {
                    HomeSection {
                        cardRow(planning, suggestions: false)
                    } header: {
                        sectionHeader("Start next · best fit from Planning", action: "All") { model.selectedTab = .lists }
                    }
                }

                if !trending.isEmpty {
                    HomeSection {
                        cardRow(trending)
                    } header: {
                        Label("Trending now", systemImage: "flame")
                    }
                }

                // Beyond your usual: these aren't sorted by match on purpose.
                if !gems.isEmpty {
                    HomeSection {
                        cardRow(gems)
                    } header: {
                        Label("Hidden gems", systemImage: "diamond")
                    }
                }

                if !outside.isEmpty {
                    HomeSection {
                        cardRow(outside)
                    } header: {
                        Label("Outside your usual · \(outsideGenres.joined(separator: " & "))", systemImage: "safari")
                    }
                }

                if !surprise.isEmpty {
                    HomeSection {
                        cardRow(surprise)
                    } header: {
                        sectionHeader("Surprise me", systemImage: "dice", action: "Shuffle") {
                            Task { await loadSurprise() }
                        }
                    }
                }

                let watching = model.shows(in: [.CURRENT, .REPEATING]).map(\.entry)
                    .sorted { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }
                if !watching.isEmpty {
                    HomeSection {
                        cardRow(watching.map(\.media), suggestions: false)
                    } header: {
                        Text("Currently watching")
                    }
                }

                if model.entries.isEmpty && model.listLoadedOnce && !model.isLoadingList {
                    Text("Add a few shows you liked (Discover → search), and Home fills up with suggestions.")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 20)
                }
                }
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Home")
            // Large title on the same row as the toolbar buttons (no empty row above it).
            .toolbarTitleDisplayMode(.inlineLarge)
            .mediaDestination(zoom: zoom)
            .environment(\.zoomNamespace, zoom)
            .refreshable {
                await model.reloadAll()
                await loadShelves(force: true)
            }
            .task { await loadShelves() }
            .task(id: model.entries.count) {
                // Uses the saved picks; only rebuilds when your list changed.
                if !model.entries.isEmpty { await model.generateRecommendations() }
            }
            .overlay {
                if model.entries.isEmpty && (model.isLoadingList || !model.listLoadedOnce) {
                    ProgressView("Loading your list…")
                }
            }
        }
        .pushDetailAction($path)
    }

    /// This season's shows you haven't added, ordered by your match (cheap: memoized per show).
    private var seasonBestMatches: [Media] {
        season
            .filter { model.entry(for: $0.id) == nil }
            .compactMap { m in model.matcher.match(for: m).map { (m, $0) } }
            .sorted { $0.1 > $1.1 }
            .prefix(15)
            .map(\.0)
    }

    /// Your Planning list, best fit first: answers "what should I start next?".
    private var planningByMatch: [Media] {
        model.shows(in: [.PLANNING]).map(\.entry)
            .map { ($0.media, model.matcher.match(for: $0.media) ?? 0) }
            .sorted { $0.1 > $1.1 }
            .prefix(15)
            .map(\.0)
    }
}

extension HomeView {
    /// The AI row: same feed as For You (no category), shown as cards.
    @ViewBuilder
    var pickedForYou: some View {
        let picks = model.picks(for: nil)
        if !picks.isEmpty || model.isLoadingFeed(nil) {
            HomeSection {
                if picks.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Hoshi is picking shows for you…").foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 20)
                } else {
                    cardRow(Array(picks.prefix(20).map(\.media)), width: 140)
                }
            } header: {
                sectionHeader("Picked for you", systemImage: "wand.and.stars", action: "See all") {
                    model.selectedTab = .forYou
                }
            }
        }
    }

    func sectionHeader(_ title: String, systemImage: String? = nil, action: String, perform: @escaping () -> Void) -> some View {
        HStack {
            if let systemImage {
                Label(title, systemImage: systemImage)
            } else {
                Text(title)
            }
            Spacer()
            Button(action, action: perform)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tint)   // stays blue inside the grey header
        }
    }

    /// Horizontal row of cover cards under a Home shelf header. Suggestion rows drop a show as soon
    /// as you plan it, watch it or say "Not for me" (the next one slides into its place);
    /// rows of your own list (Planning, Currently watching) pass `suggestions: false`.
    func cardRow(_ items: [Media], width: CGFloat = 104,
                 suggestions: Bool = true) -> some View {
        let shown = suggestions
            ? items.filter { model.entry(for: $0.id) == nil && !model.settings.dismissedPicks.contains($0.id) }
            : items
        return ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(shown) { media in
                    NavigationLink(value: MediaLink(id: media.id)) {
                        MediaCard(media: media, width: width)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .animation(.snappy, value: shown.map(\.id))
        }
    }

    /// Two light requests, once per launch (or on pull to refresh).
    func loadShelves(force: Bool = false) async {
        guard season.isEmpty || force else { return }
        let current = AppModel.currentSeason()
        async let seasonal = model.browse(sort: ["POPULARITY_DESC"], season: current.season,
                                          seasonYear: current.year, firstSeasonsOnly: true, perPage: 50)
        async let hot = model.browse(sort: ["TRENDING_DESC", "POPULARITY_DESC"], firstSeasonsOnly: true, perPage: 20)
        if let items = try? await seasonal { season = items }
        if let items = try? await hot { trending = items.filter { model.entry(for: $0.id) == nil } }
        await loadDiscovery()
    }

    /// Hidden gems, a couple of genres you rarely watch, and a random well-rated mix.
    /// Three light requests; nothing here touches the AI or your taste data.
    func loadDiscovery() async {
        let usual = usualGenres
        let allGenres = model.allCategories.filter { $0.kind == .genre }.map(\.name)
        let pool = (allGenres.isEmpty ? AnimeCategory.featured.filter { $0.kind == .genre }.map(\.name) : allGenres)
            .filter { !usual.contains($0) && $0 != "Hentai" }
        let picked = Array(pool.shuffled().prefix(2))

        async let gemsReq = model.browse(sort: ["SCORE_DESC"], minScore: 78, maxPopularity: 45_000,
                                         minPopularity: 4_000, firstSeasonsOnly: true,
                                         page: Int.random(in: 1...3), perPage: 25)
        async let outsideReq = model.browse(sort: ["SCORE_DESC", "POPULARITY_DESC"], genres: picked.isEmpty ? nil : picked,
                                            excludeGenres: usual.isEmpty ? nil : Array(usual.prefix(3)),
                                            minScore: 72, minPopularity: 8_000, firstSeasonsOnly: true, perPage: 25)
        if let items = try? await gemsReq { gems = notOnList(items).shuffled() }
        if let items = try? await outsideReq {
            outside = notOnList(items)
            outsideGenres = picked
        }
        await loadSurprise()
    }

    func loadSurprise() async {
        if let items = try? await model.browse(sort: ["SCORE_DESC"], minScore: 70, minPopularity: 15_000,
                                               firstSeasonsOnly: true, page: Int.random(in: 1...30), perPage: 25) {
            withAnimation(.snappy) { surprise = notOnList(items).shuffled() }
        }
    }

    private func notOnList(_ items: [Media]) -> [Media] {
        items.filter { model.entry(for: $0.id) == nil }
    }

    /// Genres you watch most (from shows you finished, are watching or planned).
    private var usualGenres: [String] {
        var counts: [String: Int] = [:]
        for e in model.entries where e.status != .DROPPED {
            for g in e.media.genres ?? [] { counts[g, default: 0] += 1 }
        }
        return counts.sorted { $0.value > $1.value }.prefix(4).map(\.key)
    }
}

/// One Home shelf: a grey header (with an optional action like "See all") above its row.
struct HomeSection<Content: View, Header: View>: View {
    @ViewBuilder var content: Content
    @ViewBuilder var header: Header

    init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header) {
        self.content = content()
        self.header = header()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
            content
        }
    }
}

struct ProfileHeader: View {
    @Environment(AppModel.self) private var model
    let viewer: Viewer

    var body: some View {
        HStack(spacing: 14) {
            AsyncImage(url: viewer.avatar?.large.flatMap(URL.init(string:))) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Circle().fill(.gray.opacity(0.2))
            }
            .frame(width: 56, height: 56)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(viewer.name).font(.title3.bold())
                let stats = model.listStats
                Text("\(model.showCount(of: .COMPLETED)) seen · \(model.showCount(of: .PLANNING)) planned · \(model.showCount(of: .DROPPED)) dropped")
                    .font(.caption).foregroundStyle(.secondary)
                Text(stats.meanScore.map { "Your average score \(String(format: "%.1f", $0))/10" } ?? "Rate shows to sharpen your picks")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
