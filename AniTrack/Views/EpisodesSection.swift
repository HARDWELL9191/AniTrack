import SwiftUI

/// Details page: a season dropdown and every episode with its thumbnail and description.
/// AniList gives the seasons, episode titles and thumbnails; Kitsu adds descriptions (and
/// fills missing thumbnails). Missing pieces are simply left out. The rest of the page never
/// waits on this: it loads in the background and is saved on the phone.
struct EpisodesSection: View {
    @Environment(AppModel.self) private var model
    let media: Media

    @State private var seasons: [Media]
    @State private var selectedId: Int
    @State private var page: EpisodeService.Page?
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var shownCount = 20
    @State private var expanded: Set<Int> = []

    init(media: Media) {
        self.media = media
        _seasons = State(initialValue: [media])
        _selectedId = State(initialValue: media.id)
    }

    private var selected: Media { seasons.first { $0.id == selectedId } ?? media }

    /// Movies, music videos and one-episode entries don't need an episode list.
    private var applies: Bool {
        switch media.format {
        case "MOVIE", "MUSIC": return false
        default: return media.episodes != 1
        }
    }

    var body: some View {
        if applies {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Episodes").font(.headline)
                    Spacer()
                    if seasons.count > 1 { seasonMenu }
                }
                content
            }
            .padding(.horizontal)
            .task(id: media.id) {
                let chain = await SeasonChain.shared.seasons(for: media, client: model.client)
                if chain.count > 1 { seasons = chain }
            }
            .task(id: selectedId) { await load() }
        }
    }

    // MARK: Season dropdown

    private var seasonMenu: some View {
        Menu {
            ForEach(Array(seasons.enumerated()), id: \.element.id) { index, season in
                Button {
                    selectedId = season.id
                } label: {
                    if season.id == selectedId {
                        Label(seasonName(index), systemImage: "checkmark")
                    } else {
                        Text(seasonName(index))
                    }
                    Text(seasonDetail(season))
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(seasonName(seasons.firstIndex { $0.id == selectedId } ?? 0))
                Image(systemName: "chevron.down").font(.caption.weight(.semibold))
            }
            .font(.subheadline.weight(.semibold))
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
    }

    private func seasonName(_ index: Int) -> String { "Season \(index + 1)" }

    private func seasonDetail(_ season: Media) -> String {
        var parts = [season.displayTitle(model.settings.titleLanguage)]
        if let year = season.seasonYear { parts.append(String(year)) }
        if let eps = season.episodes { parts.append("\(eps) eps") }
        return parts.joined(separator: " · ")
    }

    // MARK: Episodes

    @ViewBuilder
    private var content: some View {
        if let page, page.total > 0 {
            LazyVStack(alignment: .leading, spacing: 14) {
                // No thumbnails anywhere for this season: a clean list of titles, no empty boxes.
                let hasThumbnails = page.episodes.contains { $0.thumbnail != nil }
                ForEach(page.episodes.prefix(shownCount)) { episode in
                    EpisodeRow(episode: episode, expanded: expanded.contains(episode.number),
                               showThumbnail: hasThumbnails)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard episode.description != nil else { return }
                            withAnimation(.snappy) {
                                if expanded.contains(episode.number) { expanded.remove(episode.number) }
                                else { expanded.insert(episode.number) }
                            }
                        }
                }
            }
            if page.episodes.count > shownCount {
                Button {
                    Task { await showMore() }
                } label: {
                    if isLoadingMore {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text("Show more episodes (\(page.episodes.count - shownCount) left)")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.glass)
                .disabled(isLoadingMore)
            }
        } else if isLoading {
            HStack(spacing: 10) {
                ProgressView()
                Text("Loading episodes…").foregroundStyle(.secondary)
            }
        } else if selected.status == "NOT_YET_RELEASED" {
            Text("Not aired yet.").foregroundStyle(.secondary).font(.subheadline)
        } else {
            Text("No episode details available for this season.")
                .foregroundStyle(.secondary).font(.subheadline)
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        shownCount = 20
        expanded = []
        let season = selected
        // Show what's saved right away; refresh only if it's due (new descriptions/thumbnails).
        if let saved = await EpisodeService.shared.saved(for: season.id), season.id == selectedId {
            page = saved
            guard await EpisodeService.shared.isStale(saved) else { return }
        }
        let result = await EpisodeService.shared.firstPage(for: season, client: model.client)
        guard season.id == selectedId else { return }   // switched season meanwhile
        page = result
    }

    /// Reveals 20 more; for long shows also fetches Kitsu's next descriptions.
    private func showMore() async {
        isLoadingMore = true
        defer { isLoadingMore = false }
        let id = selectedId
        if let updated = await EpisodeService.shared.loadMore(mediaId: id), id == selectedId {
            page = updated
        }
        withAnimation(.snappy) { shownCount += 20 }
    }
}

struct EpisodeRow: View {
    let episode: EpisodeInfo
    let expanded: Bool
    var showThumbnail = true

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if showThumbnail { thumbnail }
            VStack(alignment: .leading, spacing: 3) {
                Text("Episode \(episode.number)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let title = episode.title {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                }
                if let description = episode.description {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(expanded ? nil : 3)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var thumbnail: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(.fill.tertiary)
            .frame(width: 128, height: 72)
            .overlay {
                if let url = episode.thumbnail.flatMap(URL.init(string:)) {
                    AsyncImage(url: url) { phase in
                        if case .success(let image) = phase {
                            image.resizable().scaledToFill()
                        }
                    }
                } else {
                    Text("EP \(episode.number)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
