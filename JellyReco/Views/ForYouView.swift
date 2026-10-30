import SwiftUI

/// For You: new titles to get, from TMDB, picked from what you watched on your server.
/// First dropdown: which library teaches it (default Anime; or All). Second: a genre.
/// Never shows anything already on your server.
struct ForYouView: View {
    @Environment(AppModel.self) private var model
    @State private var genre: String?
    @State private var index = 0
    @State private var handled = 0
    @State private var detail: ExternalTitle?
    @State private var showWishlist = false

    private var discovery: DiscoveryEngine { model.discovery }
    private var sourceId: String { model.reco.currentSourceId }
    private var list: [ExternalPick] { discovery.visiblePicks(for: sourceId, genre: genre) }

    var body: some View {
        NavigationStack {
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
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showWishlist = true } label: {
                        Image(systemName: model.wishlist.isEmpty ? "star" : "star.fill")
                    }
                    .accessibilityLabel("Wishlist")
                }
            }
            .refreshable {
                index = 0
                handled = 0
                await discovery.build(sourceId, genre: nil)
            }
            .task(id: sourceId) { await discovery.ensureBuilt(sourceId) }
            .onChange(of: sourceId) { _, _ in index = 0; handled = 0; genre = nil }
            .onChange(of: genre) { _, new in
                index = 0
                handled = 0
                // Few picks in this category yet: dig deeper into it.
                if let new, discovery.visiblePicks(for: sourceId, genre: new).count < 12 {
                    Task { await discovery.build(sourceId, genre: new) }
                }
            }
            .sheet(item: $detail) { ExternalDetailSheet(title: $0) }
            .sheet(isPresented: $showWishlist) { WishlistSheet() }
        }
    }

    // MARK: Dropdowns

    private var filterBar: some View {
        @Bindable var settings = model.settings
        let genres = discovery.genres(for: sourceId)
        return GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                Menu {
                    Picker("Library", selection: Binding(get: { sourceId }, set: { settings.recoSource = $0 })) {
                        ForEach(model.reco.sources) { source in
                            Label(source.name, systemImage: symbol(for: source)).tag(source.id)
                        }
                    }
                } label: {
                    dropdownLabel(model.reco.sourceName(sourceId), symbol: symbol(for: model.reco.source(sourceId)))
                }
                .buttonStyle(.glass)

                Menu {
                    Picker("Category", selection: $genre) {
                        Text("All categories").tag(String?.none)
                        ForEach(genres, id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                } label: {
                    dropdownLabel(genre ?? "All categories", symbol: "line.3.horizontal.decrease")
                }
                .buttonStyle(.glass)
                .disabled(genres.isEmpty)
            }
            .padding(.horizontal)
        }
    }

    private func dropdownLabel(_ text: String, symbol: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
            Text(text).lineLimit(1)
            Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
        }
        .font(.subheadline.weight(.semibold))
        .frame(maxWidth: .infinity)
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
        let picks = list
        if !discovery.hasKey {
            TMDBKeyCard()
                .padding(.horizontal)
        } else if picks.isEmpty && discovery.isBuilding.contains(sourceId) {
            VStack(spacing: 14) {
                ProgressView()
                Text("Learning from \(model.reco.sourceName(sourceId))…").font(.headline)
                Text("Comparing what you finished on your server with what's out there\(model.settings.useOnDeviceAI ? ", with on-device AI" : "").")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(40)
        } else if picks.isEmpty, let error = discovery.errors[sourceId] {
            ContentUnavailableView("Couldn't build picks", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if picks.isEmpty {
            ContentUnavailableView("No picks yet", systemImage: "wand.and.stars",
                                   description: Text(genre == nil ? "Pull down to look again." : "Nothing new in \(genre!) right now."))
        } else {
            let safe = min(index, picks.count - 1)
            let pick = picks[safe]
            ExternalPickCard(pick: pick,
                             position: safe + 1 + handled,
                             total: picks.count + handled,
                             noun: noun,
                             onNext: { withAnimation(.snappy) { index = safe + 1 >= picks.count ? 0 : safe + 1 } },
                             onHandled: { handled += 1 },
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
                            }
                        }
                        .padding(.horizontal)
                    }
                    .scrollClipDisabled()
                }
            }
            Text(footer)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
    }

    private var noun: String {
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
                        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                }
                .buttonStyle(PressStyle())
                VStack(alignment: .leading, spacing: 8) {
                    Text("Pick \(position) of \(total)").font(.caption).foregroundStyle(.secondary)
                    Text(t.title).font(.title3.bold()).lineLimit(3)
                    Text("\(pick.match)% match").font(.headline).foregroundStyle(Theme.pink)
                    Text(t.metaLine).font(.caption).foregroundStyle(.secondary)
                    if let score = t.score, score > 0 {
                        Label(String(format: "%.1f TMDB", score), systemImage: "star.fill")
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
            Text(t.overview).font(.subheadline).lineLimit(6).foregroundStyle(.secondary)

            aiExplanation

            GlassEffectContainer(spacing: 10) {
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        Button {
                            Task {
                                let adding = !model.isOnWishlist(t)
                                await model.toggleWishlist(t)
                                if adding { onHandled() }
                            }
                        } label: {
                            Label(model.isOnWishlist(t) ? "On Wishlist" : "Want it", systemImage: model.isOnWishlist(t) ? "star.fill" : "star")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
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
                because: pick.because, liked: model.reco.topLiked(in: model.reco.currentSourceId),
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
                        RemoteImage(url: title.backdropURL ?? title.posterURL)
                            .frame(height: 210).frame(maxWidth: .infinity).clipped()
                            .overlay(LinearGradient(colors: [.clear, Color(.systemBackground)], startPoint: .center, endPoint: .bottom))
                        HStack(alignment: .bottom, spacing: 14) {
                            RemoteImage(url: title.posterURL)
                                .frame(width: 96, height: 144)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .shadow(radius: 8)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(title.title).font(.title3.bold()).lineLimit(3)
                                if let o = title.originalTitle, o != title.title { Text(o).font(.caption).foregroundStyle(.secondary) }
                                Text(title.metaLine).font(.caption).foregroundStyle(.secondary)
                                if let s = title.score, s > 0 {
                                    Label(String(format: "%.1f · %d votes", s, title.voteCount ?? 0), systemImage: "star.fill")
                                        .font(.caption.weight(.semibold)).foregroundStyle(.yellow)
                                }
                            }
                        }
                        .padding(.horizontal)
                        .offset(y: 40)
                    }
                    .padding(.bottom, 40)

                    Label("Not on your server", systemImage: "icloud.and.arrow.down")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal)

                    GlassEffectContainer(spacing: 10) {
                        HStack(spacing: 10) {
                            Button { Task { await model.toggleWishlist(title) } } label: {
                                Label(model.isOnWishlist(title) ? "On Wishlist" : "Want it",
                                      systemImage: model.isOnWishlist(title) ? "star.fill" : "star").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.glassProminent)
                            Button { showMoreLike = true } label: {
                                Label("More like this", systemImage: "square.stack.3d.up").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.glass)
                        }
                        .controlSize(.large)
                    }
                    .padding(.horizontal)

                    Text(title.overview).font(.subheadline).foregroundStyle(.secondary).padding(.horizontal)
                    if !title.genres.isEmpty {
                        FlowLayout { ForEach(title.genres, id: \.self) { Chip(text: $0) } }.padding(.horizontal)
                    }
                    if !title.tags.isEmpty {
                        FlowLayout { ForEach(title.tags.prefix(12), id: \.self) { Chip(text: $0, tint: .gray) } }.padding(.horizontal)
                    }
                    HStack(spacing: 10) {
                        if let url = title.webURL { Button("TMDB", systemImage: "safari") { openURL(url) }.buttonStyle(.glass) }
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
                                           description: Text("Everything like \(title.title) is already on your server or hidden."))
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

/// Things you want to get (saved on your server). Ticks off by itself once a title appears there.
struct WishlistSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var detail: ExternalTitle?
    @State private var tab = 0

    var body: some View {
        NavigationStack {
            List {
                Picker("", selection: $tab) {
                    Text("Wishlist").tag(0)
                    Text("Seen").tag(1)
                    Text("Not for me").tag(2)
                }
                .pickerStyle(.segmented)
                let list = tab == 0 ? model.wishlist : (tab == 1 ? model.externalSeen : model.externalNotForMe)
                let owned = OwnedIndex(items: model.reco.libraryItems, idMap: [:])
                ForEach(list) { t in
                    Button { detail = t } label: {
                        HStack(spacing: 12) {
                            RemoteImage(url: t.posterURL).frame(width: 50, height: 75).clipShape(RoundedRectangle(cornerRadius: 6))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(t.title).font(.subheadline.weight(.semibold))
                                Text(t.metaLine).font(.caption).foregroundStyle(.secondary)
                                if tab == 0 && owned.contains(t) {
                                    Label("Now on your server", systemImage: "checkmark.circle.fill").font(.caption.weight(.semibold)).foregroundStyle(.green)
                                }
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                    .swipeActions {
                        Button(role: .destructive) {
                            Task {
                                switch tab {
                                case 0: await model.toggleWishlist(t)
                                case 2: await model.markExternalNotForMe(t, false)
                                default: break
                                }
                            }
                        } label: { Label("Remove", systemImage: "trash") }
                    }
                }
                if list.isEmpty {
                    Text(tab == 0 ? "Tap \"Want it\" on a pick to keep it here. Saved on your Jellyfin server." : "Nothing here.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Wishlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                if tab > 0 {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Clear") { Task { await model.clearExternal(tab == 1 ? .seenelsewhere : .notforme) } }
                    }
                }
            }
            .sheet(item: $detail) { ExternalDetailSheet(title: $0) }
        }
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
                .padding(12)
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            Button {
                Task { await save() }
            } label: {
                HStack { if checking { ProgressView() }; Text("Save and find picks").fontWeight(.semibold) }.frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
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
        do {
            try await TMDBClient(key: key).validate()
            model.settings.tmdbKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
            await model.discovery.build(model.reco.currentSourceId, genre: nil)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
