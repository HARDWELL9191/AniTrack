import SwiftUI

struct MediaDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let mediaId: Int

    @State private var detail: MediaDetail?
    @State private var loadError: String?
    @State private var showEditor = false
    @State private var expanded = false
    @State private var showSpoilers = false
    /// Fan recommendations with later seasons swapped for their first season.
    @State private var recommendations: [Media] = []

    var body: some View {
        Group {
            if let detail {
                content(detail)
            } else if let loadError {
                ContentUnavailableView("Couldn't load", systemImage: "wifi.exclamationmark",
                                       description: Text(loadError))
            } else {
                ProgressView()
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task(id: mediaId) { if detail == nil { await load() } }
        .sheet(isPresented: $showEditor) {
            if let media = detail?.media {
                EntryEditorView(media: media, existing: model.entry(for: mediaId),
                                lite: model.isNotForMeEntry(detail?.mediaListEntry) ? nil : detail?.mediaListEntry)
                    .presentationDetents([.medium, .large])
            }
        }
    }

    private func load() async {
        do {
            let loaded = try await model.detail(id: mediaId)
            detail = loaded
            loadError = nil
            let raw = (loaded.recommendations?.nodes ?? []).compactMap(\.mediaRecommendation)
            recommendations = raw   // shown right away; first seasons swapped in below
            recommendations = await SeasonRoots.collapse(raw, client: model.client)
        } catch {
            // Cancelled (page left mid-load): keep loading, it retries when it reappears.
            if AppModel.isCancellation(error) { return }
            loadError = error.localizedDescription
        }
    }

    @ViewBuilder
    private func content(_ d: MediaDetail) -> some View {
        let media = d.media
        let entry = model.entry(for: media.id)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ZStack(alignment: .bottomLeading) {
                    BannerImageView(url: media.bannerImage, fallbackColor: media.coverImage?.color, height: 180)
                    LinearGradient(colors: [.clear, Color(.systemBackground)], startPoint: .center, endPoint: .bottom)
                        .frame(height: 180)
                }

                HStack(alignment: .bottom, spacing: 14) {
                    CoverImageView(url: media.coverURL, color: media.coverImage?.color,
                                   width: 110, height: 160, cornerRadius: 10)
                        .overlay(alignment: .topLeading) { AgeBadge(media: media).padding(5) }
                        .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(media.displayTitle(model.settings.titleLanguage))
                            .font(.title3.bold())
                            .lineLimit(4)
                        if let native = media.title.native, model.settings.titleLanguage != .native {
                            Text(native).font(.caption).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 12) {
                            ScoreBadge(score: media.averageScore)
                            MatchBadge(media: media, showWord: true)
                        }
                        // "13+ · Teens 13 or older" (from Kitsu, when it knows the show).
                        if let age = model.ages.rating(for: media.id)?.explanation {
                            Label(age, systemImage: "checkmark.shield")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.top, -80)

                // A "Not for me" marker isn't a real list entry: show the show as not on your list.
                listControls(media: media, entry: entry,
                             lite: model.isNotForMeEntry(d.mediaListEntry) ? nil : d.mediaListEntry)
                    .padding(.horizontal)

                infoGrid(media: media, studios: d.studios?.nodes?.map(\.name) ?? [])
                    .padding(.horizontal)

                if let genres = media.genres, !genres.isEmpty {
                    FlowLayout { ForEach(genres, id: \.self) { Chip(text: $0) } }
                        .padding(.horizontal)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Synopsis").font(.headline)
                    Text(media.plainDescription)
                        .font(.subheadline)
                        .lineLimit(expanded ? nil : 6)
                    Button(expanded ? "Show less" : "Read more") { withAnimation { expanded.toggle() } }
                        .font(.subheadline)
                }
                .padding(.horizontal)

                EpisodesSection(media: media)

                tags(media)

                // Other seasons of this show (its TV/ONA prequels and sequels) are in the Episodes
                // season dropdown, not here; movies, OVAs, spin-offs and side stories stay.
                if let edges = d.relations?.edges?.filter({ edge in
                    guard let node = edge.node, node.type == "ANIME" else { return false }
                    let isSeason = (edge.relationType == "PREQUEL" || edge.relationType == "SEQUEL")
                        && Seasons.isSeries(node.format) && Seasons.sameShow(media.title, node.title)
                    return !isSeason
                }), !edges.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Related").font(.headline).padding(.horizontal)
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 12) {
                                ForEach(edges, id: \.node?.id) { edge in
                                    if let node = edge.node {
                                        NavigationLink(value: MediaLink(id: node.id)) {
                                            VStack(alignment: .leading, spacing: 4) {
                                                CoverImageView(url: node.coverImage?.large, color: node.coverImage?.color,
                                                               width: 96, height: 138)
                                                Text(edge.relationLabel).font(.caption2.weight(.bold)).foregroundStyle(Theme.accent)
                                                Text(node.title.english ?? node.title.romaji ?? node.title.userPreferred ?? "")
                                                    .font(.caption).lineLimit(2).frame(width: 96, alignment: .leading)
                                            }
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                }

                // Season 2+ of other shows is left out (their Season 1 shows up instead, elsewhere).
                let recs = recommendations
                    .filter { $0.id != media.id }
                    .filter { $0.isAdult != true && !$0.isMovie && !(model.settings.hideChinese && $0.countryOfOrigin == "CN") && !$0.isLaterSeason }
                    .filter { model.entry(for: $0.id) == nil && !model.franchises.contains($0) }   // planned/watched stay out
                    .filter { !model.settings.dismissedPicks.contains($0.id) }
                    .sorted { (model.matcher.match(for: $0) ?? 0) > (model.matcher.match(for: $1) ?? 0) }
                if !recs.isEmpty {
                    HorizontalMediaSection(title: "More like this · best match first", items: recs)
                }

                if let site = media.siteUrl, let url = URL(string: site) {
                    Button { openURL(url) } label: {
                        Label("Open on AniList", systemImage: "safari")
                    }
                    .buttonStyle(.glass)
                    .padding(.horizontal)
                }
            }
            .padding(.bottom, 30)
        }
        .ignoresSafeArea(edges: .top)
    }

    @ViewBuilder
    private func listControls(media: Media, entry: ListEntry?, lite: EntryLite?) -> some View {
        let status = entry?.status ?? lite?.status
        VStack(spacing: 10) {
            if model.canEdit {
                Button { showEditor = true } label: {
                    Label(status?.label ?? "Add to list", systemImage: status?.symbol ?? "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            } else if let status {
                Label(status.label, systemImage: status.symbol)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            let score = entry?.score ?? lite?.score
            if let score, score > 0 {
                Text("Your score ★ \(Fmt.score(score))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let airing = Fmt.airing(media.nextAiringEpisode) {
                Label(airing, systemImage: "clock")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func infoGrid(media: Media, studios: [String]) -> some View {
        let rows: [(String, String)] = [
            ("Format", media.formatLabel),
            ("Episodes", media.episodes.map(String.init) ?? "?"),
            ("Length", media.duration.map { "\($0) min" } ?? "?"),
            ("Status", media.statusLabel),
            ("Season", media.seasonLabel ?? "?"),
            ("Studio", studios.first ?? "?"),
            ("Popularity", media.popularity.map { $0.formatted() } ?? "?"),
            ("Mean score", media.meanScore.map { Fmt.outOfTen($0) } ?? "?")
        ]
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 10) {
            ForEach(rows, id: \.0) { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.0).font(.caption).foregroundStyle(.secondary)
                    Text(row.1).font(.subheadline.weight(.medium)).lineLimit(1)
                }
            }
        }
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private func tags(_ media: Media) -> some View {
        let all = (media.tags ?? []).sorted { ($0.rank ?? 0) > ($1.rank ?? 0) }
        let visible = all.filter { showSpoilers || $0.isMediaSpoiler != true }.prefix(14)
        if !all.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Tags").font(.headline)
                    Spacer()
                    if all.contains(where: { $0.isMediaSpoiler == true }) {
                        Button(showSpoilers ? "Hide spoilers" : "Show spoilers") { showSpoilers.toggle() }
                            .font(.caption)
                    }
                }
                FlowLayout {
                    ForEach(Array(visible), id: \.name) { tag in
                        Chip(text: "\(tag.name) \(tag.rank ?? 0)%",
                             tint: tag.isMediaSpoiler == true ? .red : .secondary)
                    }
                }
            }
            .padding(.horizontal)
        }
    }
}

struct EntryEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let media: Media
    let existing: ListEntry?
    let lite: EntryLite?

    @State private var status: ListStatus = .PLANNING
    @State private var progress = 0
    @State private var score: Double = 0
    @State private var isSaving = false
    @State private var confirmDelete = false
    @State private var didLoad = false
    /// Set when you pick a status yourself (not when the episode stepper changes it), so
    /// "Completed"/"Planning" picked here applies to the whole show.
    @State private var pickedStatus = false

    private var entryId: Int? { existing?.id ?? lite?.id }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Status", selection: Binding(get: { status },
                                                    set: { status = $0; pickedStatus = true })) {
                    ForEach(ListStatus.allCases) { s in
                        Label(s.label, systemImage: s.symbol).tag(s)
                    }
                }
                Stepper(value: $progress, in: 0...(media.episodes ?? 9999)) {
                    Text("Episodes \(progress)/\(media.episodes.map(String.init) ?? "?")")
                }
                VStack(alignment: .leading) {
                    Text(score > 0 ? "Score ★ \(Fmt.score(score * 10))" : "Score: not rated")
                    Slider(value: $score, in: 0...10, step: 0.5)
                }
                if entryId != nil {
                    Button("Remove from list", role: .destructive) { confirmDelete = true }
                }
            }
            .navigationTitle(media.displayTitle(model.settings.titleLanguage))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }.disabled(isSaving)
                }
            }
            .confirmationDialog("Remove from your list?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Remove", role: .destructive) { Task { await remove() } }
            } message: {
                Text("Its other seasons are removed too.")
            }
            .onChange(of: progress) { _, newValue in
                guard didLoad else { return }   // ignore the initial fill from your existing entry
                if let total = media.episodes, newValue >= total, total > 0, status != .REPEATING { status = .COMPLETED }
                else if newValue > 0 && status == .PLANNING { status = .CURRENT }
            }
        }
        .onAppear {
            status = existing?.status ?? lite?.status ?? .PLANNING
            progress = existing?.progressValue ?? lite?.progress ?? 0
            score = (existing?.score ?? lite?.score ?? 0) / 10
            DispatchQueue.main.async { didLoad = true }
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let isNew = entryId == nil
        let oldScore = Int((existing?.score ?? lite?.score ?? 0).rounded())
        let newScore = Int((score * 10).rounded())
        do {
            try await model.save(media: media, status: status, progress: progress, scoreRaw: newScore)
            // Show-level changes go to the other seasons too (progress stays per season).
            if pickedStatus && status == .COMPLETED {
                model.updateOtherSeasons(of: media, .watched)
            } else if isNew || (pickedStatus && status == .PLANNING) {
                model.updateOtherSeasons(of: media, .planned)
            }
            if newScore > 0 && newScore != oldScore {
                model.updateOtherSeasons(of: media, .scored(newScore))
            }
            dismiss()
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    private func remove() async {
        guard let entryId else { return }
        do {
            try await model.removeShow(media, entryId: entryId)
            dismiss()
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }
}
