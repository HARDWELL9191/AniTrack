import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Namespace private var zoom

    var body: some View {
        NavigationStack {
            List {
                if let viewer = model.viewer {
                    Section { ProfileHeader(viewer: viewer) }
                }

                let watching = model.entries(in: [.CURRENT, .REPEATING])
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
                        Text("Nothing in progress. Find something in Discover or For You.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(watching) { WatchingRow(entry: $0) }
                }
            }
            .navigationTitle("Home")
            .mediaDestination(zoom: zoom)
            .environment(\.zoomNamespace, zoom)
            .refreshable { await model.reloadAll() }
            .overlay {
                if model.isLoadingList && model.entries.isEmpty { ProgressView("Loading your list…") }
            }
        }
    }
}

struct ProfileHeader: View {
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
                if let stats = viewer.statistics?.anime {
                    let days = Double(stats.minutesWatched ?? 0) / 1440
                    Text("\(stats.count ?? 0) anime · \(stats.episodesWatched ?? 0) eps · \(String(format: "%.1f", days)) days")
                        .font(.caption).foregroundStyle(.secondary)
                    if let mean = stats.meanScore, mean > 0 {
                        Text("Mean score \(String(format: "%.1f", mean))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
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
                CoverImageView(url: entry.media.coverURL, color: entry.media.coverImage?.color,
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
