import SwiftUI

/// Suggestion-first Home: your picks, the best matches airing this season, which planned
/// show fits you best right now, and what's trending, all with personal match %.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Namespace private var zoom
    @State private var trending: [Media] = []
    @State private var season: [Media] = []

    var body: some View {
        NavigationStack {
            List {
                if let viewer = model.viewer {
                    Section { ProfileHeader(viewer: viewer) }
                }

                pickedForYou

                let bestThisSeason = seasonBestMatches
                if !bestThisSeason.isEmpty {
                    let s = AppModel.currentSeason()
                    Section {
                        cardRow(bestThisSeason)
                    } header: {
                        Label("Best matches · \(s.season.capitalized) \(String(s.year))", systemImage: "sparkles")
                    }
                }

                let planning = planningByMatch
                if !planning.isEmpty {
                    Section {
                        cardRow(planning)
                    } header: {
                        sectionHeader("Start next · best fit from Planning", action: "All") { model.selectedTab = .lists }
                    }
                }

                if !trending.isEmpty {
                    Section {
                        cardRow(trending)
                    } header: {
                        Label("Trending now", systemImage: "flame")
                    }
                }

                let watching = model.entries(in: [.CURRENT, .REPEATING])
                if !watching.isEmpty {
                    Section {
                        cardRow(watching.map(\.media))
                    } header: {
                        Text("Currently watching")
                    }
                }

                if model.entries.isEmpty && !model.isLoadingList {
                    Section {
                        Text("Add a few shows you liked (Discover → search), and Home fills up with suggestions.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Home")
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
                if model.isLoadingList && model.entries.isEmpty { ProgressView("Loading your list…") }
            }
        }
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
        model.entries(in: [.PLANNING])
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
            Section {
                if picks.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Hoshi is picking shows for you…").foregroundStyle(.secondary)
                    }
                } else {
                    let matches = Dictionary(picks.prefix(20).map { ($0.id, $0.match) }, uniquingKeysWith: { a, _ in a })
                    cardRow(Array(picks.prefix(20).map(\.media)), matches: matches, width: 140)
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
                .textCase(nil)
        }
    }

    /// Horizontal row of cover cards inside a List section.
    func cardRow(_ items: [Media], matches: [Int: Int] = [:], width: CGFloat = 104) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(items) { media in
                    NavigationLink(value: MediaLink(id: media.id)) {
                        MediaCard(media: media, width: width, matchOverride: matches[media.id])
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
    }

    /// Two light requests, once per launch (or on pull to refresh).
    func loadShelves(force: Bool = false) async {
        guard season.isEmpty || force else { return }
        let current = AppModel.currentSeason()
        async let seasonal = model.browse(sort: ["POPULARITY_DESC"], season: current.season,
                                          seasonYear: current.year, perPage: 50)
        async let hot = model.browse(sort: ["TRENDING_DESC", "POPULARITY_DESC"], perPage: 20)
        if let items = try? await seasonal { season = items }
        if let items = try? await hot { trending = items.filter { model.entry(for: $0.id) == nil } }
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
                Text("\(model.count(of: .COMPLETED)) seen · \(model.count(of: .PLANNING)) planned · \(model.count(of: .DROPPED)) dropped")
                    .font(.caption).foregroundStyle(.secondary)
                Text(stats.meanScore.map { "Your average score \(String(format: "%.1f", $0))/10" } ?? "Rate shows to sharpen your picks")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
