import SwiftUI

struct ItemDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let item: BaseItem

    @State private var detail: BaseItem?
    @State private var seasons: [BaseItem] = []
    @State private var selectedSeason: String?
    @State private var episodes: [BaseItem] = []
    @State private var nextUp: BaseItem?
    @State private var similar: [BaseItem] = []
    @State private var extras: [BaseItem] = []
    @State private var children: [BaseItem] = []
    @State private var sourceIndex = 0
    @State private var audioIndex: Int?
    @State private var subtitleIndex: Int?
    @State private var expanded = false
    @State private var showMediaInfo = false
    @State private var loadError: String?

    private var current: BaseItem { detail ?? item }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                header
                actions.padding(.horizontal)
                overview.padding(.horizontal)
                if current.kind == .series || current.kind == .season { episodesSection }
                if current.kind == .boxSet || current.kind == .folder || current.kind == .playlist {
                    childrenSection
                }
                if !(current.chapters ?? []).isEmpty && current.kind.isPlayableVideo { chaptersSection }
                castSection
                if !extras.isEmpty { Shelf(title: "Extras", items: extras, landscape: true, playOnTap: true) }
                if !similar.isEmpty { Shelf(title: "More like this", items: similar) }
                infoSection.padding(.horizontal)
            }
            .padding(.bottom, 30)
        }
        .ignoresSafeArea(edges: .top)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if [.movie, .series, .episode, .season].contains(current.kind) {
                    Button {
                        Task { await model.toggleWatchlist(current) }
                    } label: {
                        Image(systemName: model.isOnWatchlist(current) ? "bookmark.fill" : "bookmark")
                    }
                    .accessibilityLabel("My List")
                }
                Button {
                    Task { await model.toggleFavorite(current) }
                } label: {
                    Image(systemName: model.isFavorite(current) ? "heart.fill" : "heart")
                        .foregroundStyle(model.isFavorite(current) ? Theme.pink : .primary)
                }
                Menu {
                    Button(model.isPlayed(current) ? "Mark as unwatched" : "Mark as watched",
                           systemImage: model.isPlayed(current) ? "eye.slash" : "checkmark.circle") {
                        Task { await model.togglePlayed(current) }
                    }
                    if current.kind.isPlayableVideo { Button("Media info", systemImage: "info.circle") { showMediaInfo = true } }
                    ForEach(externalLinks) { link in
                        Button(link.name, systemImage: "safari") { openURL(link.url) }
                    }
                    if current.kind == .movie || current.kind == .series {
                        Button(model.isNotForMe(current) ? "Undo Not for me" : "Not for me",
                               systemImage: model.isNotForMe(current) ? "hand.thumbsup" : "hand.thumbsdown") {
                            Task { await model.setNotForMe(current, !model.isNotForMe(current)) }
                        }
                    }
                    if model.isAdmin {
                        Button("Refresh metadata", systemImage: "arrow.clockwise") { Task { await refreshMetadata() } }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task(id: item.id) { await load() }
        .sheet(isPresented: $showMediaInfo) {
            MediaInfoSheet(item: current, sourceIndex: sourceIndex).presentationDetents([.medium, .large])
        }
    }

    // MARK: Header

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            RemoteImage(url: model.client?.backdropURL(current) ?? model.client?.landscapeURL(current, width: 1280))
                .frame(height: 300)
                .frame(maxWidth: .infinity)
                .clipped()
                .overlay(LinearGradient(colors: [.clear, .clear, Color(.systemBackground)], startPoint: .top, endPoint: .bottom))
            HStack(alignment: .bottom, spacing: 14) {
                if current.kind != .episode {
                    RemoteImage(url: model.client?.posterURL(current, width: 360))
                        .frame(width: 104, height: 156)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .shadow(color: .black.opacity(0.3), radius: 10, y: 5)
                }
                VStack(alignment: .leading, spacing: 6) {
                    if let logo = model.client?.logoURL(current), current.kind != .episode {
                        RemoteImage(url: logo, contentMode: .fit)
                            .frame(maxWidth: 220, maxHeight: 70, alignment: .leading)
                    } else {
                        if current.kind == .episode, let s = current.seriesName {
                            Text(s).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        }
                        Text(current.displayName).font(.title2.bold()).lineLimit(3)
                    }
                    Text(current.subtitleLine).font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        RatingLabel(item: current)
                        if let m = model.reco.match(for: current) {
                            Label("\(m)% match", systemImage: "wand.and.stars")
                                .font(.caption.weight(.semibold)).foregroundStyle(Theme.pink)
                        }
                    }
                }
            }
            .padding(.horizontal)
        }
    }

    // MARK: Actions

    @ViewBuilder
    private var actions: some View {
        let playTarget = current.kind == .series || current.kind == .season ? nextUp : current
        let canPlay = current.kind.isPlayableVideo || playTarget != nil
        VStack(alignment: .leading, spacing: 10) {
            if canPlay {
                let resume = playTarget.flatMap { model.userData(for: $0)?.playbackPositionTicks } ?? 0
                GlassEffectContainer(spacing: 10) {
                    HStack(spacing: 10) {
                        Button {
                            playCurrent(from: nil)
                        } label: {
                            VStack(spacing: 2) {
                                Label(resume > 0 ? "Resume" : "Play", systemImage: "play.fill").font(.headline)
                                if let t = playTarget, current.kind != t.kind, let label = t.episodeLabel {
                                    Text(label + (t.name.map { " · \($0)" } ?? "")).font(.caption2).lineLimit(1)
                                } else if resume > 0 {
                                    Text("from \(Fmt.clock(Fmt.seconds(resume)))").font(.caption2)
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        if resume > 0 {
                            Button { playCurrent(from: 0) } label: {
                                Image(systemName: "arrow.counterclockwise").font(.headline).frame(width: 44)
                            }
                            .buttonStyle(.glass)
                            .accessibilityLabel("Play from beginning")
                        }
                        if trailerAvailable {
                            Button { Task { await playTrailer() } } label: {
                                Image(systemName: "film.stack").font(.headline).frame(width: 44)
                            }
                            .buttonStyle(.glass)
                            .accessibilityLabel("Trailer")
                        }
                        Button { Task { await model.togglePlayed(current) } } label: {
                            Image(systemName: model.isPlayed(current) ? "checkmark.circle.fill" : "checkmark.circle")
                                .font(.headline).frame(width: 44)
                        }
                        .buttonStyle(.glass)
                        .accessibilityLabel("Watched")
                    }
                    .controlSize(.large)
                }
            }
            if current.kind.isPlayableVideo { trackPickers }
        }
    }

    /// Version / audio / subtitle picked before pressing play (Swiftfin's item page options).
    @ViewBuilder
    private var trackPickers: some View {
        let sources = current.mediaSources ?? []
        let source = sources.indices.contains(sourceIndex) ? sources[sourceIndex] : sources.first
        let streams = source?.mediaStreams ?? current.mediaStreams ?? []
        let audio = streams.filter(\.isAudio)
        let subs = streams.filter(\.isSubtitle)
        if sources.count > 1 || audio.count > 1 || !subs.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if sources.count > 1 {
                        Menu {
                            Picker("Version", selection: $sourceIndex) {
                                ForEach(sources.indices, id: \.self) { i in Text(sources[i].name ?? "Version \(i + 1)").tag(i) }
                            }
                        } label: { pill(source?.name ?? "Version", symbol: "square.stack") }
                    }
                    if audio.count > 1 {
                        Menu {
                            Picker("Audio", selection: $audioIndex) {
                                Text("Default").tag(Int?.none)
                                ForEach(audio, id: \.index) { Text($0.label).tag(Int?.some($0.index)) }
                            }
                        } label: { pill(audio.first { $0.index == audioIndex }?.label ?? "Audio: default", symbol: "waveform") }
                    }
                    if !subs.isEmpty {
                        Menu {
                            Picker("Subtitles", selection: $subtitleIndex) {
                                Text("Default").tag(Int?.none)
                                Text("Off").tag(Int?.some(-1))
                                ForEach(subs, id: \.index) { Text($0.label).tag(Int?.some($0.index)) }
                            }
                        } label: {
                            pill(subtitleIndex == -1 ? "Subtitles off" : (subs.first { $0.index == subtitleIndex }?.label ?? "Subtitles: default"),
                                 symbol: "captions.bubble")
                        }
                    }
                }
            }
            .scrollClipDisabled()
        }
    }

    private func pill(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .glassEffect(.regular, in: .capsule)
    }

    private func playCurrent(from start: Double?) {
        let target = current.kind == .series || current.kind == .season ? (nextUp ?? current) : current
        let sources = current.mediaSources ?? []
        let sourceId = sources.indices.contains(sourceIndex) && sources.count > 1 ? sources[sourceIndex].id : nil
        model.play(target, from: start, audio: audioIndex, subtitle: subtitleIndex, mediaSourceId: sourceId)
    }

    private var trailerAvailable: Bool {
        (current.localTrailerCount ?? 0) > 0 || !(current.remoteTrailers ?? []).isEmpty
    }

    private func playTrailer() async {
        if (current.localTrailerCount ?? 0) > 0, let client = model.client,
           let trailer = try? await client.localTrailers(current.id).first {
            model.play(trailer, from: 0)
        } else if let url = current.remoteTrailers?.first?.url.flatMap(URL.init(string:)) {
            openURL(url)
        }
    }

    // MARK: Overview

    @ViewBuilder
    private var overview: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let tagline = current.taglines?.first, !tagline.isEmpty {
                Text(tagline).font(.headline).italic()
            }
            let text = current.plainOverview
            if !text.isEmpty {
                let hidden = model.settings.hideSpoilers && current.kind == .episode && !model.isPlayed(current) && !expanded
                Text(hidden ? "Overview hidden until you've watched this episode. Tap to show." : text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(expanded ? nil : 5)
                    .onTapGesture { withAnimation(.snappy) { expanded.toggle() } }
            }
            if let genres = current.genres, !genres.isEmpty {
                FlowLayout {
                    ForEach(genres, id: \.self) { g in
                        NavigationLink(value: GenreLink(name: g, parentId: nil)) { Chip(text: g) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: Seasons & episodes

    @ViewBuilder
    private var episodesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if current.kind == .series && !seasons.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(seasons) { season in
                            Button {
                                selectedSeason = season.id
                            } label: {
                                Text(season.displayName)
                                    .font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 14).padding(.vertical, 8)
                                    .foregroundStyle(selectedSeason == season.id ? .white : .primary)
                                    .background {
                                        if selectedSeason == season.id { Capsule().fill(Theme.accent) }
                                    }
                                    .glassEffect(.regular, in: .capsule)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(model.isPlayed(season) ? "Mark season unwatched" : "Mark season watched",
                                       systemImage: "checkmark.circle") {
                                    Task { await model.togglePlayed(season); await loadEpisodes() }
                                }
                            }
                        }
                    }
                    .padding(.horizontal)
                }
                .scrollClipDisabled()
            }
            LazyVStack(spacing: 14) {
                ForEach(episodes) { ep in
                    EpisodeRow(episode: ep)
                }
            }
            .padding(.horizontal)
            if episodes.isEmpty && !seasons.isEmpty { ProgressView().frame(maxWidth: .infinity) }
        }
        .onChange(of: selectedSeason) { _, _ in Task { await loadEpisodes() } }
    }

    @ViewBuilder
    private var childrenSection: some View {
        if !children.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(children.count) items").font(.title3.bold()).padding(.horizontal)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12)], spacing: 16) {
                    ForEach(children) { c in
                        NavigationLink(value: ItemLink(item: c)) { PosterCard(item: c, width: 104) }
                            .buttonStyle(PressStyle())
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private var chaptersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Chapters").font(.title3.bold()).padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(Array((current.chapters ?? []).enumerated()), id: \.offset) { i, ch in
                        Button {
                            model.play(current, from: Fmt.seconds(ch.startPositionTicks))
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                RemoteImage(url: model.client?.chapterImageURL(itemId: current.id, index: i, tag: ch.imageTag))
                                    .frame(width: 180, height: 101)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                Text(ch.name ?? "Chapter \(i + 1)").font(.caption.weight(.semibold)).lineLimit(1)
                                Text(Fmt.clock(Fmt.seconds(ch.startPositionTicks))).font(.caption2).foregroundStyle(.secondary)
                            }
                            .frame(width: 180, alignment: .leading)
                        }
                        .buttonStyle(PressStyle())
                    }
                }
                .padding(.horizontal)
            }
            .scrollClipDisabled()
        }
    }

    @ViewBuilder
    private var castSection: some View {
        let people = current.people ?? []
        if !people.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Cast & crew").font(.title3.bold()).padding(.horizontal)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(people.prefix(40)) { p in
                            NavigationLink(value: PersonLink(id: p.id, name: p.name ?? "")) {
                                VStack(spacing: 4) {
                                    RemoteImage(url: model.client?.personImageURL(p), placeholderSymbol: "person.fill")
                                        .frame(width: 76, height: 76)
                                        .clipShape(Circle())
                                    Text(p.name ?? "").font(.caption.weight(.semibold)).lineLimit(2)
                                        .multilineTextAlignment(.center)
                                    Text(p.role?.isEmpty == false ? p.role! : (p.type ?? ""))
                                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                                .frame(width: 86)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
    }

    @ViewBuilder
    private var infoSection: some View {
        let c = current
        VStack(alignment: .leading, spacing: 8) {
            Text("Information").font(.title3.bold())
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                if let d = c.premiereDate { infoRow("Released", d.formatted(date: .long, time: .omitted)) }
                if let r = c.officialRating { infoRow("Rated", r) }
                if let rt = c.runtimeSeconds, rt > 0 { infoRow("Runtime", Fmt.runtime(rt)) }
                if let st = c.studios?.compactMap(\.name), !st.isEmpty { infoRow("Studio", st.joined(separator: ", ")) }
                let directors = (c.people ?? []).filter { $0.type == "Director" }.compactMap(\.name)
                if !directors.isEmpty { infoRow("Director", directors.joined(separator: ", ")) }
                let writers = (c.people ?? []).filter { $0.type == "Writer" }.compactMap(\.name)
                if !writers.isEmpty { infoRow("Writers", writers.prefix(3).joined(separator: ", ")) }
                if let status = c.status, c.kind == .series { infoRow("Status", status) }
                if let air = c.airDays, !air.isEmpty { infoRow("Airs", air.joined(separator: ", ") + (c.airTime.map { " · \($0)" } ?? "")) }
                if let src = c.mediaSources?.first {
                    if let size = src.size { infoRow("File", "\(src.container?.uppercased() ?? "") · \(Fmt.bytes(size))") }
                    let v = (src.mediaStreams ?? []).first(where: \.isVideo)
                    if let v { infoRow("Video", [v.codec?.uppercased(), v.width.flatMap { w in v.height.map { "\(w)×\($0)" } }, v.videoRangeType].compactMap { $0 }.joined(separator: " · ")) }
                    if let a = (src.mediaStreams ?? []).first(where: \.isAudio) { infoRow("Audio", a.label) }
                }
            }
            .font(.subheadline)
        }
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    struct LinkItem: Identifiable {
        var id: String { name }
        let name: String
        let url: URL
    }

    private var externalLinks: [LinkItem] {
        var out: [LinkItem] = []
        for link in current.externalUrls ?? [] {
            if let name = link.name, let s = link.url, let url = URL(string: s), !out.contains(where: { $0.name == name }) {
                out.append(LinkItem(name: name, url: url))
            }
        }
        return out
    }

    // MARK: Loading

    private func load() async {
        guard let client = model.client else { return }
        do {
            let full = try await client.item(item.id)
            detail = full
            switch full.kind {
            case .series:
                async let s = client.seasons(seriesId: full.id)
                async let n = client.nextUp(seriesId: full.id, limit: 1, enableRewatching: true)
                seasons = ((try? await s) ?? []).filter { model.settings.showMissingEpisodes || $0.locationType != "Virtual" }
                nextUp = (try? await n)?.first
                if selectedSeason == nil {
                    selectedSeason = nextUp?.seasonId ?? seasons.first(where: { !model.isPlayed($0) })?.id ?? seasons.first?.id
                }
                if nextUp == nil { nextUp = try? await client.episodes(seriesId: full.id).first }
                await loadEpisodes()
            case .season:
                selectedSeason = full.id
                await loadEpisodes()
                nextUp = episodes.first { !model.isPlayed($0) } ?? episodes.first
            case .boxSet, .folder, .playlist:
                var q = JellyfinClient.ItemQuery()
                q.parentId = full.id
                q.recursive = false
                q.sortBy = full.kind == .playlist ? [] : ["ProductionYear", "PremiereDate", "SortName"]
                q.limit = 500
                children = (try? await client.items(q).items) ?? []
            default:
                break
            }
            if [.movie, .series, .episode].contains(full.kind) {
                async let sim = client.similar(full.kind == .episode ? (full.seriesId ?? full.id) : full.id, limit: 16)
                async let ex = client.specialFeatures(full.id)
                similar = (try? await sim) ?? []
                extras = (try? await ex) ?? []
            }
        } catch {
            if !AppModel.isCancellation(error) { loadError = error.localizedDescription; model.report(error) }
        }
    }

    private func loadEpisodes() async {
        guard let client = model.client else { return }
        let seriesId = current.kind == .series ? current.id : (current.seriesId ?? current.parentId ?? current.id)
        let eps = (try? await client.episodes(seriesId: seriesId, seasonId: selectedSeason)) ?? []
        episodes = eps.filter { model.settings.showMissingEpisodes || $0.locationType != "Virtual" }
    }

    private func refreshMetadata() async {
        guard let client = model.client else { return }
        do {
            try await client.send("POST", "/Items/\(current.id)/Refresh", query: [
                "metadataRefreshMode": "FullRefresh", "imageRefreshMode": "FullRefresh",
                "replaceAllMetadata": false, "replaceAllImages": false,
            ])
        } catch { model.report(error) }
    }
}

struct EpisodeRow: View {
    @Environment(AppModel.self) private var model
    let episode: BaseItem
    @State private var expanded = false

    var body: some View {
        let data = model.userData(for: episode)
        let hideSpoiler = model.settings.hideSpoilers && !(data?.played ?? false)
        HStack(alignment: .top, spacing: 12) {
            Button { model.play(episode) } label: {
                RemoteImage(url: model.client?.landscapeURL(episode, width: 480))
                    .blur(radius: hideSpoiler ? 14 : 0)
                    .frame(width: 150, height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay { GlassIcon(symbol: "play.fill", tint: .black.opacity(0.3)) }
                    .overlay(alignment: .bottom) {
                        if let p = data?.playedPercentage, p > 0, p < 100 { ProgressBar(value: p / 100).padding(6) }
                    }
                    .overlay(alignment: .topTrailing) {
                        if data?.played ?? false { GlassIcon(symbol: "checkmark", tint: Theme.accent.opacity(0.55)).padding(4) }
                    }
            }
            .buttonStyle(PressStyle())
            VStack(alignment: .leading, spacing: 3) {
                Text("\(episode.indexNumber.map { "\($0). " } ?? "")\(episode.displayName)")
                    .font(.subheadline.weight(.semibold)).lineLimit(2)
                HStack(spacing: 6) {
                    if let rt = episode.runtimeSeconds { Text(Fmt.runtime(rt)) }
                    if let d = episode.premiereDate { Text(d.formatted(date: .abbreviated, time: .omitted)) }
                }
                .font(.caption2).foregroundStyle(.secondary)
                if !hideSpoiler || expanded {
                    Text(episode.plainOverview).font(.caption).foregroundStyle(.secondary).lineLimit(expanded ? nil : 3)
                }
            }
            .onTapGesture { withAnimation(.snappy) { expanded.toggle() } }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .itemActions(episode)
    }
}

// MARK: - Media info

struct MediaInfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    let item: BaseItem
    let sourceIndex: Int

    var body: some View {
        NavigationStack {
            List {
                let sources = item.mediaSources ?? []
                ForEach(Array(sources.enumerated()), id: \.offset) { i, src in
                    Section(src.name ?? "Version \(i + 1)") {
                        if let c = src.container { LabeledContent("Container", value: c.uppercased()) }
                        if let s = src.size { LabeledContent("Size", value: Fmt.bytes(s)) }
                        if let b = src.bitrate { LabeledContent("Bitrate", value: Fmt.bitrate(b)) }
                        if let p = src.path { LabeledContent("Path") { Text(p).font(.caption).textSelection(.enabled) } }
                    }
                    ForEach(src.mediaStreams ?? [], id: \.index) { stream in
                        Section("\(stream.type ?? "Stream") #\(stream.index)") {
                            LabeledContent("Title", value: stream.label)
                            if let c = stream.codec { LabeledContent("Codec", value: c.uppercased() + (stream.profile.map { " (\($0))" } ?? "")) }
                            if let l = stream.languageName { LabeledContent("Language", value: l) }
                            if let w = stream.width, let h = stream.height { LabeledContent("Resolution", value: "\(w)×\(h)") }
                            if let r = stream.videoRangeType { LabeledContent("Range", value: r) }
                            if let d = stream.bitDepth { LabeledContent("Bit depth", value: "\(d)-bit") }
                            if let f = stream.realFrameRate ?? stream.averageFrameRate { LabeledContent("Frame rate", value: String(format: "%.3f fps", f)) }
                            if let ch = stream.channelLayout ?? stream.channels.map({ "\($0) ch" }) { LabeledContent("Channels", value: ch) }
                            if let sr = stream.sampleRate { LabeledContent("Sample rate", value: "\(sr) Hz") }
                            if let b = stream.bitRate { LabeledContent("Bitrate", value: Fmt.bitrate(b)) }
                            if stream.isDefault == true { LabeledContent("Default", value: "Yes") }
                            if stream.isForced == true { LabeledContent("Forced", value: "Yes") }
                            if stream.isExternal == true { LabeledContent("External", value: "Yes") }
                        }
                    }
                }
            }
            .navigationTitle("Media info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

// MARK: - Person

struct PersonView: View {
    @Environment(AppModel.self) private var model
    let personId: String
    let name: String
    @State private var person: BaseItem?
    @State private var movies: [BaseItem] = []
    @State private var shows: [BaseItem] = []
    @State private var expanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 16) {
                    RemoteImage(url: model.client?.imageURL(itemId: personId, tag: person?.primaryTag, maxWidth: 400),
                                placeholderSymbol: "person.fill")
                        .frame(width: 110, height: 150)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(name).font(.title2.bold())
                        if let b = person?.premiereDate { Text("Born \(b.formatted(date: .long, time: .omitted))").font(.caption).foregroundStyle(.secondary) }
                        if let place = person?.productionLocations?.first { Text(place).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                .padding(.horizontal)
                if let bio = person?.plainOverview, !bio.isEmpty {
                    Text(bio).font(.subheadline).foregroundStyle(.secondary).lineLimit(expanded ? nil : 6)
                        .onTapGesture { withAnimation { expanded.toggle() } }
                        .padding(.horizontal)
                }
                Shelf(title: "Movies", items: movies)
                Shelf(title: "Shows", items: shows)
            }
            .padding(.vertical)
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard let client = model.client else { return }
            person = try? await client.item(personId)
            var q = JellyfinClient.ItemQuery()
            q.personIds = [personId]
            q.sortBy = ["PremiereDate", "ProductionYear", "SortName"]
            q.sortOrder = "Descending"
            q.limit = 200
            q.includeItemTypes = [.movie]
            movies = (try? await client.items(q).items) ?? []
            q.includeItemTypes = [.series]
            shows = (try? await client.items(q).items) ?? []
        }
    }
}
