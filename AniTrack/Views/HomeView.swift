import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Namespace private var zoom
    @State private var trending: [Media] = []

    var body: some View {
        NavigationStack {
            List {
                if let viewer = model.viewer {
                    Section { ProfileHeader(viewer: viewer) }
                }

                let watching = model.entries(in: [.CURRENT, .REPEATING])
                let planning = model.entries(in: [.PLANNING])
                let completed = model.entries(in: [.COMPLETED])
                let behind = watching.filter { entry in
                    guard let available = entry.media.availableEpisodes else { return false }
                    return available > entry.progressValue
                }
                let airing = watching
                    .filter { $0.media.nextAiringEpisode != nil }
                    .sorted { ($0.media.nextAiringEpisode?.airingAt ?? 0) < ($1.media.nextAiringEpisode?.airingAt ?? 0) }

                if !behind.isEmpty {
                    Section("Ready to watch") {
                        ForEach(behind) { WatchingRow(entry: $0) }
                    }
                }

                pickedForYou

                if !airing.isEmpty {
                    Section("Airing schedule") {
                        ForEach(airing) { entry in
                            NavigationLink(value: MediaLink(id: entry.mediaId)) {
                                MediaRow(media: entry.media,
                                         subtitle: Fmt.airing(entry.media.nextAiringEpisode))
                            }
                        }
                    }
                }

                Section("Watching (\(watching.count))") {
                    if watching.isEmpty && !model.isLoadingList {
                        Text(planning.isEmpty
                             ? "Nothing in progress. Find something in Discover or For You."
                             : "Nothing in progress. Start something from Up next.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(watching) { WatchingRow(entry: $0) }
                }

                if !planning.isEmpty {
                    Section {
                        cardRow(planning.prefix(15).map(\.media)) { _ in nil }
                    } header: {
                        sectionHeader("Up next from Planning", action: "All") { model.selectedTab = .lists }
                    }
                }

                if !trending.isEmpty {
                    let season = AppModel.currentSeason()
                    Section {
                        cardRow(trending) { _ in nil }
                    } header: {
                        Text("Trending · \(season.season.capitalized) \(String(season.year))")
                    }
                }

                if !completed.isEmpty {
                    Section("Recently completed") {
                        ForEach(completed.prefix(5)) { entry in
                            NavigationLink(value: MediaLink(id: entry.mediaId)) {
                                MediaRow(media: entry.media,
                                         subtitle: entry.scoreValue > 0 ? "Your score ★ \(Fmt.score(entry.score))" : "Completed")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Home")
            .mediaDestination(zoom: zoom)
            .environment(\.zoomNamespace, zoom)
            .refreshable {
                await model.reloadAll()
                await loadTrending(force: true)
            }
            .task { await loadTrending() }
            .task(id: model.entries.count) {
                // Uses the saved picks; only rebuilds when your list changed.
                if !model.entries.isEmpty { await model.generateRecommendations() }
            }
            .overlay {
                if model.isLoadingList && model.entries.isEmpty { ProgressView("Loading your list…") }
            }
        }
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
                    cardRow(Array(picks.prefix(15).map(\.media))) { media in
                        picks.first { $0.id == media.id }.map { "\($0.match)% match" }
                    }
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
    func cardRow(_ items: [Media], caption: @escaping (Media) -> String?) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(items) { media in
                    NavigationLink(value: MediaLink(id: media.id)) {
                        VStack(alignment: .leading, spacing: 4) {
                            MediaCard(media: media, width: 104)
                            if let text = caption(media) {
                                Text(text)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Theme.pink)
                            }
                        }
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

    func loadTrending(force: Bool = false) async {
        guard trending.isEmpty || force else { return }
        let season = AppModel.currentSeason()
        if let items = try? await model.browse(sort: ["TRENDING_DESC", "POPULARITY_DESC"],
                                               season: season.season, seasonYear: season.year, perPage: 15) {
            trending = items
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
                let days = Double(stats.minutes) / 1440
                Text("\(stats.count) anime · \(stats.episodes) eps · \(String(format: "%.1f", days)) days")
                    .font(.caption).foregroundStyle(.secondary)
                Text("\(model.count(of: .PLANNING)) planned" + (stats.meanScore.map { " · mean score \(String(format: "%.1f", $0))" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct WatchingRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.zoomNamespace) private var zoom
    let entry: ListEntry
    @State private var isSaving = false

    var body: some View {
        NavigationLink(value: MediaLink(id: entry.mediaId)) {
            HStack(spacing: 12) {
                CoverImageView(url: entry.media.thumbURL, color: entry.media.coverImage?.color,
                               width: 54, height: 78, cornerRadius: 6)
                    .zoomSource(id: entry.mediaId, in: zoom)
                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.media.displayTitle(model.settings.titleLanguage))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    ProgressView(value: progressFraction)
                        .tint(Theme.accent)
                    HStack {
                        Text(progressText).font(.caption).foregroundStyle(.secondary)
                        if let airing = Fmt.airing(entry.media.nextAiringEpisode) {
                            Text("· \(airing)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 4)
                if model.canEdit {
                    Button {
                        Task {
                            isSaving = true
                            await model.incrementProgress(entry)
                            isSaving = false
                        }
                    } label: {
                        Group {
                            if isSaving {
                                ProgressView()
                            } else {
                                Text("+1").font(.subheadline.bold())
                            }
                        }
                        .frame(width: 48, height: 34)
                        .glassEffect(.regular.tint(Theme.accent.opacity(0.3)).interactive(), in: .capsule)
                    }
                    // Borderless keeps the tap on the button instead of opening the row.
                    .buttonStyle(.borderless)
                    .sensoryFeedback(.increase, trigger: entry.progressValue)
                    .disabled(isSaving)
                }
            }
        }
    }

    private var progressText: String {
        if let total = entry.media.episodes { return "\(entry.progressValue)/\(total)" }
        return "\(entry.progressValue)/?"
    }

    private var progressFraction: Double {
        let total = entry.media.episodes ?? entry.media.availableEpisodes ?? 0
        guard total > 0 else { return 0 }
        return min(1, Double(entry.progressValue) / Double(total))
    }
}
