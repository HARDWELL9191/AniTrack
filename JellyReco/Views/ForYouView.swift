import SwiftUI

/// For You: new titles to get, from TMDB, picked from what you watched on your server.
/// First dropdown: which library teaches it (default Anime; or All). Second: a genre.
/// The libraries named Anime and Anime Movies run on your AniList account instead, as in
/// AniReco (picks from your AniList list, My List = AniList Planning, Not for me on AniList).
/// Never shows anything already on your server.
struct ForYouView: View {
    @Environment(AppModel.self) private var model
    @Namespace private var zoom
    @State private var path = NavigationPath()
    @State private var genre: String?
    @State private var index = 0
    @State private var handled = 0
    @State private var detail: ExternalTitle?
    /// AniList category (Anime / Anime Movies libraries).
    @State private var aniCategory: AnimeCategory?
    @State private var showAllCategories = false

    private var discovery: DiscoveryEngine { model.discovery }
    private var anilist: AniListService { model.anilist }
    private var sourceId: String { model.reco.currentSourceId }
    /// Set when the chosen library is Anime or Anime Movies: For You runs on AniList.
    private var aniLibrary: AniListLibrary? { AniListLibrary(libraryName: model.reco.source(sourceId)?.name) }

    /// The bookmark opens the list for this library: Anime lists, Movie list or TV Show list
    /// (a mixed library or All asks which).
    @ViewBuilder
    private var listsButton: some View {
        let filled = !(model.myList.isEmpty && model.anilist.planning.isEmpty)
        let image = Image(systemName: filled ? "bookmark.fill" : "bookmark")
        if aniLibrary != nil {
            NavigationLink(value: ScreenLink.animeLists) { image }.accessibilityLabel("Anime lists")
        } else if model.reco.source(sourceId)?.collectionType == "movies" {
            NavigationLink(value: ScreenLink.movieList) { image }.accessibilityLabel("Movie list")
        } else if model.reco.source(sourceId)?.collectionType == "tvshows" {
            NavigationLink(value: ScreenLink.showList) { image }.accessibilityLabel("TV Show list")
        } else {
            Menu {
                Button("Anime lists", systemImage: "list.bullet.rectangle") { path.append(ScreenLink.animeLists) }
                Button("Movie list", systemImage: "film.stack") { path.append(ScreenLink.movieList) }
                Button("TV Show list", systemImage: "tv") { path.append(ScreenLink.showList) }
            } label: { image }
            .accessibilityLabel("My lists")
        }
    }
    private var list: [ExternalPick] {
        if let aniLibrary { return anilist.externalPicks(aniLibrary, aniCategory) }
        return discovery.visiblePicks(for: sourceId, genre: genre)
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 14) {
                    filterBar
                    content
                }
                .padding(.top, 4)
                .padding(.bottom)
            }
            .navigationTitle("For You")
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { listsButton }
            }
            .refreshable {
                index = 0
                handled = 0
                if let aniLibrary {
                    if model.libraries.isEmpty { await model.refreshSession() }
                    await anilist.refreshList()
                    await anilist.generate(aniLibrary, aniCategory, force: true)
                    return
                }
                // No libraries yet (the server wasn't reachable when the app opened, e.g. VPN off):
                // fetch them now, so the library menu fills in without restarting the app.
                if model.libraries.isEmpty { await model.refreshSession() }
                await discovery.build(sourceId, genre: nil)
            }
            // Per account too: after switching accounts the library id (or "All") can stay the same.
            .task(id: "\(model.store.currentServerId ?? "")|\(model.client?.userId ?? "")|\(sourceId)|\(aniCategory?.id ?? "")|\(anilist.viewer?.id ?? 0)") {
                if let aniLibrary {
                    anilist.syncAccount()
                    guard anilist.isLoggedIn else { return }
                    async let categories: Void = anilist.loadCategories()
                    await anilist.generate(aniLibrary, aniCategory)
                    await categories
                    return
                }
                await discovery.ensureBuilt(sourceId)
            }
            .onChange(of: sourceId) { _, _ in index = 0; handled = 0; genre = nil; aniCategory = nil }
            .onChange(of: aniCategory) { _, _ in index = 0; handled = 0 }
            .onChange(of: index) { _, new in preloadAniList(at: new) }
            .onChange(of: genre) { _, new in
                index = 0
                handled = 0
                // Few picks in this category yet: dig deeper into it.
                if let new, discovery.visiblePicks(for: sourceId, genre: new).count < 12 {
                    Task { await discovery.build(sourceId, genre: new) }
                }
            }
            .sheet(item: $detail) { ExternalDetailSheet(title: $0) }
            .appDestinations(zoom: zoom, path: $path)
            .environment(\.zoomNamespace, zoom)
        }
    }

    // MARK: Dropdowns

    /// AniReco's dropdown bar: glass dropdown buttons on the right, same height as every other
    /// dropdown. First the library For You learns from (default Anime, or All), then a category.
    private var filterBar: some View {
        @Bindable var settings = model.settings
        let genres = discovery.genres(for: sourceId)
        return HStack(spacing: 10) {
            Spacer(minLength: 0)
            Menu {
                ForEach(model.reco.sources) { source in
                    Button { settings.recoSource = source.id } label: {
                        if source.id == sourceId {
                            Label(source.name, systemImage: "checkmark")
                        } else {
                            Label(source.name, systemImage: symbol(for: source))
                        }
                    }
                }
            } label: {
                DropdownLabel(text: model.reco.sourceName(sourceId), symbol: symbol(for: model.reco.source(sourceId)))
            }
            .menuStyle(.button)
            .buttonStyle(.glass)

            if aniLibrary != nil {
                aniCategoryMenu
            } else {
                genreMenu(genres)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    /// AniReco's category dropdown: popular genres and tags, then "All categories…".
    private var aniCategoryMenu: some View {
        Menu {
            AniCategoryMenuItems(selected: $aniCategory, showAll: $showAllCategories)
        } label: {
            DropdownLabel(text: aniCategory?.name ?? "Any category", symbol: "line.3.horizontal.decrease")
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .sheet(isPresented: $showAllCategories) {
            AniAllCategoriesSheet { picked in
                aniCategory = picked
                showAllCategories = false
            }
            .presentationDetents([.medium, .large])
        }
    }

    private func genreMenu(_ genres: [String]) -> some View {
        Menu {
            Button { genre = nil } label: {
                if genre == nil { Label("Any category", systemImage: "checkmark") } else { Text("Any category") }
            }
            if !genres.isEmpty {
                Divider()
                Section("Genres") {
                    ForEach(genres, id: \.self) { g in
                        Button { genre = g } label: {
                            if genre == g { Label(g, systemImage: "checkmark") } else { Text(g) }
                        }
                    }
                }
            }
        } label: {
            DropdownLabel(text: genre ?? "Any category", symbol: "line.3.horizontal.decrease")
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .disabled(genres.isEmpty && genre == nil)
    }

    private var tryAgainButton: some View {
        Button("Try again", systemImage: "arrow.clockwise") {
            Task { await discovery.build(sourceId, genre: nil) }
        }
        .buttonStyle(.glass)
    }

    private func symbol(for source: RecoEngine.Source?) -> String {
        guard let source, source.id != RecoSource.all else { return "square.grid.2x2" }
        let name = source.name.lowercased()
        if name.contains("anime") { return name.contains("movie") ? "sparkles.rectangle.stack" : "sparkles.tv" }
        switch source.collectionType {
        case "movies": return "film"
        case "tvshows": return "tv"
        default: return "rectangle.stack"
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let aniLibrary {
            aniContent(aniLibrary)
        } else {
            tmdbContent
        }
    }

    /// Near the end of the AniList feed: dig one round deeper (AniReco's endless feed).
    private func preloadAniList(at position: Int) {
        guard let aniLibrary, let feed = anilist.feed(aniLibrary, aniCategory), !feed.exhausted,
              position >= list.count - 5 else { return }
        Task { await anilist.loadMore(aniLibrary, aniCategory) }
    }

    @ViewBuilder
    private func aniContent(_ library: AniListLibrary) -> some View {
        let picks = list
        if !anilist.isLoggedIn {
            AniListConnectCard(library: library)
                .padding(.horizontal)
        } else if picks.isEmpty && (anilist.isLoggingIn || !anilist.listLoadedOnce) {
            VStack(spacing: 14) {
                ProgressView()
                Text("Loading your list…").font(.headline)
            }
            .padding(40)
        } else if picks.isEmpty && anilist.isBuilding(library, aniCategory) {
            VStack(spacing: 14) {
                ProgressView()
                Text(aniCategory.map { "Finding \($0.name) picks for you…" } ?? "Hoshi is reading your list…").font(.headline)
                Text(model.settings.useOnDeviceAI
                     ? "Comparing your favorites with on-device AI. This only runs when your list changes."
                     : "Comparing your favorites with what fans recommend.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(40)
        } else if picks.isEmpty, let error = anilist.error(library, aniCategory) {
            ContentUnavailableView {
                Label("Couldn't build picks", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                aniTryAgain(library)
            }
        } else if picks.isEmpty {
            ContentUnavailableView {
                Label("No picks yet", systemImage: "wand.and.stars")
            } description: {
                Text(aniCategory == nil ? "Rate a few shows on your list, then refresh."
                                        : "Nothing new in \(aniCategory!.name) right now. Try another category.")
            } actions: {
                aniTryAgain(library)
            }
        } else {
            aniPickList(library)
            Text(aniFooter(library))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
    }

    private func aniTryAgain(_ library: AniListLibrary) -> some View {
        Button("Try again", systemImage: "arrow.clockwise") {
            Task {
                if !anilist.listLoadedOnce || anilist.entries.isEmpty { await anilist.reloadAll() }
                await anilist.generate(library, aniCategory, force: true)
            }
        }
        .buttonStyle(.glass)
    }

    /// AniReco's footer.
    private func aniFooter(_ library: AniListLibrary) -> String {
        guard let feed = anilist.feed(library, aniCategory) else { return "" }
        let when = feed.generatedAt.formatted(.relative(presentation: .named))
        let engine = feed.usedOnDeviceAI ? "fan recommendations, your tags and on-device AI" : "fan recommendations and your tags"
        var text = "Built \(when) from \(engine)."
        text += feed.exhausted ? " You've seen everything for now. Rate more shows for new picks."
                               : " More picks load automatically as you go."
        return text
    }

    /// AniReco's pick card and "More picks" row, on the AniList feed.
    @ViewBuilder
    private func aniPickList(_ library: AniListLibrary) -> some View {
        let picks = anilist.picks(library, aniCategory)
        let feed = anilist.feed(library, aniCategory)
        let safe = min(index, picks.count - 1)
        let shown = picks[safe]
        AniListPickCard(rec: shown,
                        position: safe + 1 + handled,
                        total: picks.count + handled,
                        moreComing: !(feed?.exhausted ?? true),
                        noun: library.noun,
                        onNext: { aniNext(from: safe, library) },
                        onDismiss: {
                            handled += 1
                            withAnimation(.snappy) { anilist.dismiss(shown.media) }
                            preloadAniList(at: safe)
                        },
                        onWatched: {
                            handled += 1
                            preloadAniList(at: safe)
                        },
                        onDetails: { detail = anilist.title(for: shown.media) })
            .id(shown.id)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)))
            .padding(.horizontal)

        if picks.count > 1 {
            VStack(alignment: .leading, spacing: 10) {
                Text("More picks").font(.title3.bold()).padding(.horizontal)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(Array(picks.enumerated()), id: \.element.id) { offset, rec in
                            Button { withAnimation(.snappy) { index = offset } } label: {
                                AniListMediaCard(media: rec.media, width: 96)
                            }
                            .buttonStyle(PressStyle())
                            .onAppear { if offset >= picks.count - 3 { preloadAniList(at: offset) } }
                        }
                        if anilist.isLoadingMore(library, aniCategory) { ProgressView().frame(width: 96, height: 140) }
                    }
                    .padding(.horizontal)
                }
                .scrollClipDisabled()
            }
        }
    }

    /// AniReco's "Another pick": waits for a round that's about to arrive, wraps only at the true end.
    private func aniNext(from current: Int, _ library: AniListLibrary) {
        let count = anilist.picks(library, aniCategory).count
        let isLast = current >= count - 1
        if isLast && anilist.isLoadingMore(library, aniCategory) { return }
        withAnimation(.snappy) {
            if isLast && (anilist.feed(library, aniCategory)?.exhausted ?? true) {
                index = 0
                handled = 0
            } else {
                index = min(current + 1, count - 1)
            }
        }
        preloadAniList(at: index)
    }

    /// The pick card and the "More picks" row (TMDB and AniList picks alike).
    @ViewBuilder
    private func pickList(_ picks: [ExternalPick], loadingMore: Bool) -> some View {
        let safe = min(index, picks.count - 1)
        let pick = picks[safe]
        ExternalPickCard(pick: pick,
                         position: safe + 1 + handled,
                         total: picks.count + handled,
                         noun: noun,
                         onNext: { withAnimation(.snappy) { index = safe + 1 >= picks.count ? 0 : safe + 1 } },
                         onHandled: { handled += 1; preloadAniList(at: safe) },
                         onDetails: { detail = pick.title })
            .id(pick.id)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)))
            .padding(.horizontal)

        if picks.count > 1 {
            VStack(alignment: .leading, spacing: 10) {
                Text("More picks").font(.title3.bold()).padding(.horizontal)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(Array(picks.enumerated()), id: \.element.id) { offset, p in
                            Button { withAnimation(.snappy) { index = offset } } label: {
                                ExternalPosterCard(title: p.title, match: p.match, width: 96, highlighted: offset == safe)
                            }
                            .buttonStyle(PressStyle())
                            .onAppear { if offset >= picks.count - 3 { preloadAniList(at: offset) } }
                        }
                        if loadingMore { ProgressView().frame(width: 96, height: 144) }
                    }
                    .padding(.horizontal)
                }
                .scrollClipDisabled()
            }
        }
    }

    @ViewBuilder
    private var tmdbContent: some View {
        let picks = list
        if !discovery.hasKey {
            TMDBKeyCard()
                .padding(.horizontal)
        } else if picks.isEmpty && discovery.isBuildingPicks(sourceId, genre: genre) {
            VStack(spacing: 14) {
                ProgressView()
                Text("Learning from \(model.reco.sourceName(sourceId))…").font(.headline)
                Text(discovery.buildStatus(sourceId, genre: genre) ?? "Comparing what you finished on your server with what's out there\(model.settings.useOnDeviceAI ? ", with on-device AI" : "").")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .contentTransition(.opacity)
                    .animation(.easeInOut, value: discovery.buildStatus(sourceId, genre: genre))
            }
            .padding(40)
        } else if picks.isEmpty, let error = discovery.buildError(sourceId, genre: genre) {
            ContentUnavailableView {
                Label("Couldn't build picks", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                tryAgainButton
            }
        } else if picks.isEmpty {
            ContentUnavailableView {
                Label("No picks yet", systemImage: "wand.and.stars")
            } description: {
                Text(genre == nil ? "Tap Try again to look for picks." : "Nothing new in \(genre!) right now.")
            } actions: {
                tryAgainButton
            }
        } else {
            pickList(picks, loadingMore: false)
            Text(footer)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
    }

    private var noun: String {
        if let aniLibrary { return aniLibrary.noun }
        switch discovery.kind(of: sourceId) {
        case .animeShows: return "anime"
        case .animeMovies: return "anime movie"
        case .movies: return "movie"
        case .shows: return "TV show"
        default: return "title"
        }
    }

    private var footer: String {
        let when = discovery.builtAt[sourceId].map { $0.formatted(.relative(presentation: .named)) } ?? "just now"
        return "Built \(when) from what you watched in \(model.reco.sourceName(sourceId)), TMDB's also-liked lists\(discovery.usedAI ? " and on-device AI" : ""). Nothing here is on your server yet."
    }
}

// MARK: - Cards

/// The age bubble on a TMDB cover (top left, like AniReco). Titles that came without full
/// details (rows, "More like this", saved picks) look theirs up once when they appear.
struct ExternalAgeBubble: View {
    @Environment(AppModel.self) private var model
    let title: ExternalTitle
    @State private var looked: (id: String, rating: String)?

    var body: some View {
        if title.isAniList {
            AniListAgeBubble(id: title.sourceId)
        } else {
            tmdbBubble
        }
    }

    @ViewBuilder
    private var tmdbBubble: some View {
        let rating = title.ageRating ?? (looked?.id == title.id ? looked?.rating : nil)
        let label = rating.flatMap(TMDBCertification.bucket)
        ZStack {
            if let label { GlassLabel(text: label).transition(.opacity) }
        }
        .animation(.easeOut(duration: 0.2), value: label)
        .task(id: title.id) {
            guard title.ageRating == nil, looked?.id != title.id else { return }
            if let r = await model.discovery.ageRating(title) { looked = (title.id, r) }
        }
    }
}

/// Kitsu's age rating on an AniList cover (as in AniReco), looked up in batches as covers appear.
struct AniListAgeBubble: View {
    @Environment(AppModel.self) private var model
    let id: Int

    var body: some View {
        let label = model.anilist.ages.rating(for: id)?.label
        ZStack {
            if let label { GlassLabel(text: label).transition(.opacity) }
        }
        .animation(.easeOut(duration: 0.2), value: label)
        .onAppear { model.anilist.ages.request(id: id, mal: nil) }
    }
}

struct ExternalPosterCard: View {
    let title: ExternalTitle
    var match: Int?
    var width: CGFloat = 110
    var highlighted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RemoteImage(url: title.posterURL, placeholderSymbol: title.isMovie ? "film" : "tv")
                .frame(width: width, height: width * 1.5)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .bottomLeading) {
                    if let match { MatchBubble(value: match).padding(5) }
                }
                .overlay(alignment: .topLeading) { ExternalAgeBubble(title: title).padding(5) }
                .overlay {
                    if highlighted {
                        RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.pink, lineWidth: 2)
                    }
                }
            Text(title.title).font(.caption.weight(.semibold)).lineLimit(2).frame(width: width, alignment: .leading)
            Text(title.year.map(String.init) ?? " ").font(.caption2).foregroundStyle(.secondary)
        }
        .foregroundStyle(.primary)
    }
}

struct ExternalPickCard: View {
    @Environment(AppModel.self) private var model
    let pick: ExternalPick
    let position: Int
    let total: Int
    let noun: String
    let onNext: () -> Void
    let onHandled: () -> Void
    let onDetails: () -> Void

    @State private var explanation: String?
    @State private var isExplaining = false
    @State private var explainError: String?
    @State private var showMoreLike = false

    var body: some View {
        let t = pick.title
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Button(action: onDetails) {
                    RemoteImage(url: t.posterURL)
                        .frame(width: 120, height: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(alignment: .topLeading) { ExternalAgeBubble(title: t).padding(6) }
                        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                }
                .buttonStyle(PressStyle())
                VStack(alignment: .leading, spacing: 8) {
                    Text("Pick \(position) of \(total)").font(.caption).foregroundStyle(.secondary)
                    SelectableText(text: t.title, style: .title3, weight: .bold, lineLimit: 3)
                    Text("\(pick.match)% match").font(.headline).foregroundStyle(Theme.pink)
                    Text(t.metaLine).font(.caption).foregroundStyle(.secondary)
                    if let score = t.score, score > 0 {
                        Label(String(format: "%.1f %@", score, t.siteName), systemImage: "star.fill")
                            .font(.caption.weight(.semibold)).foregroundStyle(.yellow)
                    }
                }
            }
            if !pick.because.isEmpty {
                Label {
                    Text("Because you watched \(Text(pick.because.joined(separator: ", ")).bold())").font(.subheadline)
                } icon: {
                    Image(systemName: "heart.fill").foregroundStyle(Theme.pink)
                }
            }
            if !pick.highlights.isEmpty {
                FlowLayout { ForEach(pick.highlights, id: \.self) { Chip(text: $0) } }
            }
            SelectableText(text: t.overview, style: .subheadline, color: .secondaryLabel, lineLimit: 6)

            aiExplanation

            GlassEffectContainer(spacing: 10) {
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        Button {
                            Task {
                                let adding = !model.isOnMyList(t)
                                await model.toggleMyList(t)
                                if adding { onHandled() }   // planned = handled: next pick slides in
                            }
                        } label: {
                            Label(model.isOnMyList(t) ? "On My List" : "Add to My List",
                                  systemImage: model.isOnMyList(t) ? "bookmark.fill" : "bookmark")
                                .lineLimit(1).minimumScaleFactor(0.8)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.tintedGlass)
                        Button(action: onDetails) {
                            Label("Details", systemImage: "info.circle").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                    }
                    HStack(spacing: 10) {
                        Button(role: .destructive) {
                            onHandled()
                            Task { await model.markExternalNotForMe(t) }
                        } label: {
                            Label("Not for me", systemImage: "hand.thumbsdown").foregroundStyle(.red).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                        Button {
                            onHandled()
                            Task { await model.markSeenElsewhere(t) }
                        } label: {
                            Label("Already seen", systemImage: "eye.fill").lineLimit(1).minimumScaleFactor(0.8).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                    }
                    HStack(spacing: 10) {
                        Button { showMoreLike = true } label: {
                            Label("More like this", systemImage: "square.stack.3d.up").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                        Button(action: onNext) {
                            Label("Another pick", systemImage: "shuffle").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                    }
                }
                .controlSize(.large)
            }
        }
        .padding()
        .background {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.background.secondary)
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(LinearGradient(colors: [Theme.accent.opacity(0.18), Theme.pink.opacity(0.06), .clear],
                                             startPoint: .top, endPoint: .bottom))
                }
        }
        .onAppear { explanation = PickExplainer.shared.cached(t.id) }
        .sheet(isPresented: $showMoreLike) { ExternalMoreLikeSheet(title: t).presentationDetents([.medium, .large]) }
    }

    @ViewBuilder
    private var aiExplanation: some View {
        if let explanation {
            Label {
                Text(explanation).font(.subheadline)
            } icon: {
                Image(systemName: "apple.intelligence").foregroundStyle(Theme.accent)
            }
            .padding(12)
            .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            switch PickExplainer.shared.availability {
            case .available:
                Button {
                    Task { await explain() }
                } label: {
                    if isExplaining { HStack { ProgressView(); Text("Thinking on-device…") } }
                    else { Label("Why would I like this?", systemImage: "apple.intelligence") }
                }
                .buttonStyle(.glass)
                .disabled(isExplaining)
                if let explainError { Text(explainError).font(.caption).foregroundStyle(.secondary) }
            case .unavailable(let reason):
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func explain() async {
        isExplaining = true
        explainError = nil
        defer { isExplaining = false }
        do {
            explanation = try await PickExplainer.shared.explain(
                DiscoveryEngine.pseudoItem(pick.title).withOverview(pick.title.overview),
                because: pick.because,
                liked: pick.title.isAniList ? model.anilist.topLiked() : model.reco.topLiked(in: model.reco.currentSourceId),
                highlights: pick.highlights, noun: noun)
        } catch {
            explainError = "Apple Intelligence couldn't write this one (\(error.localizedDescription))."
        }
    }
}

extension BaseItem {
    func withOverview(_ text: String) -> BaseItem {
        var copy = self
        copy.overview = text
        return copy
    }
}

/// A TMDB title (not on your server): poster, overview, links, actions.
struct ExternalDetailSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State var title: ExternalTitle
    @State private var showMoreLike = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ZStack(alignment: .bottomLeading) {
                        // The image fills a screen-wide, 210 pt box drawn over it: sized by its own
                        // aspect, an AniList banner (about 5:1) made the box, and so the whole
                        // sheet, ~1000 pt wide (cut off on both sides).
                        Color.clear.frame(height: 210).frame(maxWidth: .infinity)
                            .overlay { RemoteImage(url: title.backdropURL ?? title.posterURL) }
                            .clipped()
                            .overlay(LinearGradient(colors: [.clear, Color(.systemBackground)], startPoint: .center, endPoint: .bottom))
                        HStack(alignment: .bottom, spacing: 14) {
                            RemoteImage(url: title.posterURL)
                                .frame(width: 96, height: 144)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(alignment: .topLeading) { ExternalAgeBubble(title: title).padding(5) }
                                .shadow(radius: 8)
                            VStack(alignment: .leading, spacing: 4) {
                                SelectableText(text: title.title, style: .title3, weight: .bold, lineLimit: 3)
                                if let o = title.originalTitle, o != title.title { SelectableText(text: o, style: .caption1, color: .secondaryLabel) }
                                Text(title.metaLine).font(.caption).foregroundStyle(.secondary)
                                if let s = title.score, s > 0 {
                                    Label(title.isAniList ? String(format: "%.1f AniList", s)
                                                          : String(format: "%.1f · %d votes", s, title.voteCount ?? 0),
                                          systemImage: "star.fill")
                                        .font(.caption.weight(.semibold)).foregroundStyle(.yellow)
                                }
                                // "PG-13 · United States" (TMDB certification), like AniReco's details;
                                // AniList titles: Kitsu's rating, as in AniReco.
                                if let age = title.isAniList ? model.anilist.ages.rating(for: title.sourceId)?.explanation : title.ageExplanation {
                                    Label(age, systemImage: "checkmark.shield")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.horizontal)
                        .offset(y: 40)
                    }
                    .padding(.bottom, 40)

                    Label(title.isAniList ? "Not on your server or your AniList list" : "Not on your server",
                          systemImage: "icloud.and.arrow.down")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal)

                    GlassEffectContainer(spacing: 10) {
                        HStack(spacing: 10) {
                            Button { Task { await model.toggleMyList(title) } } label: {
                                Label(model.isOnMyList(title) ? "On My List" : "Add to My List",
                                      systemImage: model.isOnMyList(title) ? "bookmark.fill" : "bookmark").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.tintedGlass)
                            Button { showMoreLike = true } label: {
                                Label("More like this", systemImage: "square.stack.3d.up").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.glass)
                        }
                        .controlSize(.large)
                    }
                    .padding(.horizontal)

                    SelectableText(text: title.overview, style: .subheadline, color: .secondaryLabel).padding(.horizontal)
                    if !title.genres.isEmpty {
                        FlowLayout { ForEach(title.genres, id: \.self) { Chip(text: $0) } }.padding(.horizontal)
                    }
                    if !title.tags.isEmpty {
                        FlowLayout { ForEach(title.tags.prefix(12), id: \.self) { Chip(text: $0, tint: .gray) } }.padding(.horizontal)
                    }
                    HStack(spacing: 10) {
                        if let url = title.webURL { Button(title.siteName, systemImage: "safari") { openURL(url) }.buttonStyle(.glass) }
                        if let url = title.imdbURL { Button("IMDb", systemImage: "safari") { openURL(url) }.buttonStyle(.glass) }
                    }
                    .padding(.horizontal)
                    HStack(spacing: 10) {
                        Button("Already seen") { Task { await model.markSeenElsewhere(title); dismiss() } }.buttonStyle(.glass)
                        Button("Not for me", role: .destructive) { Task { await model.markExternalNotForMe(title); dismiss() } }.buttonStyle(.glass)
                    }
                    .padding(.horizontal)
                }
                .padding(.bottom, 24)
            }
            .ignoresSafeArea(edges: .top)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { title = await model.discovery.details(title) }
            .sheet(isPresented: $showMoreLike) { ExternalMoreLikeSheet(title: title).presentationDetents([.medium, .large]) }
        }
    }
}

struct ExternalMoreLikeSheet: View {
    @Environment(AppModel.self) private var model
    let title: ExternalTitle
    @State private var items: [ExternalTitle]?
    @State private var detail: ExternalTitle?

    var body: some View {
        NavigationStack {
            Group {
                if let items, items.isEmpty {
                    ContentUnavailableView("Nothing new", systemImage: "square.stack.3d.up.slash",
                                           description: Text("Everything like \(title.title) is already on your server\(title.isAniList ? ", on your AniList list" : "") or hidden."))
                } else if let items {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12)], spacing: 16) {
                            ForEach(items) { t in
                                Button { detail = t } label: { ExternalPosterCard(title: t, width: 104) }.buttonStyle(PressStyle())
                            }
                        }
                        .padding()
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Like \(title.title)")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $detail) { ExternalDetailSheet(title: $0) }
        }
        .task { items = await model.discovery.moreLike(title) }
    }
}

/// Shown until a TMDB key is added (one-time, ~2 minutes).
struct TMDBKeyCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var key = ""
    @State private var checking = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Connect TMDB", systemImage: "sparkle.magnifyingglass").font(.title3.bold())
            Text("For You finds new movies, shows and anime on TMDB, based on what you watched on your server, and never suggests anything you already have. It needs a free TMDB API key (once).")
                .font(.subheadline).foregroundStyle(.secondary)
            Text("1. Sign up at themoviedb.org\n2. Settings → API → create a key (Developer, personal use)\n3. Copy the \"API Read Access Token\" (or the API key) and paste it here")
                .font(.footnote)
            Button("Open TMDB API settings", systemImage: "safari") {
                if let url = URL(string: "https://www.themoviedb.org/settings/api") { openURL(url) }
            }
            .buttonStyle(.glass)
            SecureField("TMDB API key or read access token", text: $key)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .keyboardDoneBar()
                .padding(12)
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            if let error { Text(error).font(.footnote).foregroundStyle(.red).accessibilityIdentifier("tmdb-error") }
            Button {
                checking = true          // spinner right away, before anything else
                Keyboard.dismiss()
                Task { await save() }
            } label: {
                HStack { if checking { ProgressView().accessibilityIdentifier("tmdb-checking") }; Text("Save and find picks").fontWeight(.semibold) }.frame(maxWidth: .infinity)
            }
            .buttonStyle(.tintedGlass)
            .controlSize(.large)
            .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || checking)
            Text("Saved in your account's private JellyReco storage on your server, so your other devices have it too.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(.background.secondary))
    }

    private func save() async {
        checking = true
        error = nil
        defer { checking = false }
        let cleaned = key.components(separatedBy: .whitespacesAndNewlines).joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        do {
            try await TMDBClient(key: cleaned).validate()
            model.settings.tmdbKey = cleaned   // starts building picks (discovery.keyChanged)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
