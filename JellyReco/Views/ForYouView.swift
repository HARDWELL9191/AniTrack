import SwiftUI

/// One personal pick at a time from your own library (AniReco's For You, for Jellyfin).
/// First dropdown: which library (default Anime; or All). Second: a genre within it.
struct ForYouView: View {
    @Environment(AppModel.self) private var model
    @Namespace private var zoom
    @State private var path = NavigationPath()
    @State private var genre: String?
    @State private var index = 0
    @State private var handled = 0

    private var reco: RecoEngine { model.reco }
    private var sourceId: String { reco.currentSourceId }
    private var list: [Pick] { reco.picks(for: sourceId, genre: genre) }

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
            .refreshable {
                index = 0
                handled = 0
                await reco.build(force: true)
            }
            .task { await reco.ensureBuilt() }
            .onChange(of: sourceId) { _, _ in index = 0; handled = 0; genre = nil }
            .onChange(of: genre) { _, _ in index = 0; handled = 0 }
            .appDestinations(zoom: zoom)
            .environment(\.zoomNamespace, zoom)
        }
    }

    // MARK: Dropdowns

    private var filterBar: some View {
        @Bindable var settings = model.settings
        let genres = reco.genres[sourceId] ?? []
        return GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                Menu {
                    Picker("Library", selection: Binding(get: { sourceId }, set: { settings.recoSource = $0 })) {
                        ForEach(reco.sources) { source in
                            Label(source.name, systemImage: symbol(for: source)).tag(source.id)
                        }
                    }
                } label: {
                    dropdownLabel(reco.sourceName(sourceId),
                                  symbol: symbol(for: reco.sources.first { $0.id == sourceId }))
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
        guard let source else { return "square.grid.2x2" }
        if source.id == RecoSource.all { return "square.grid.2x2" }
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
        if picks.isEmpty && reco.isBuilding {
            VStack(spacing: 14) {
                ProgressView()
                Text("Reading \(reco.sourceName(sourceId))…").font(.headline)
                Text(model.settings.useOnDeviceAI
                     ? "Comparing what you've finished with everything you haven't watched yet, with on-device AI."
                     : "Comparing what you've finished with everything you haven't watched yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(40)
        } else if picks.isEmpty, let error = reco.lastError {
            ContentUnavailableView("Couldn't build picks", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if picks.isEmpty {
            ContentUnavailableView("No picks yet", systemImage: "wand.and.stars",
                                   description: Text(genre == nil
                                                     ? "Finish or favourite a few titles in \(reco.sourceName(sourceId)), then pull to refresh."
                                                     : "Nothing unwatched in \(genre!) right now. Try another category."))
        } else {
            let safe = min(index, picks.count - 1)
            let pick = picks[safe]
            PickCard(pick: pick,
                     position: safe + 1 + handled,
                     total: picks.count + handled,
                     noun: reco.noun(for: sourceId),
                     onNext: { withAnimation(.snappy) { index = safe + 1 >= picks.count ? 0 : safe + 1 } },
                     onHandled: { handled += 1 })
                .id(pick.id)
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                        removal: .move(edge: .leading).combined(with: .opacity)))
                .padding(.horizontal)

            if picks.count > 1 {
                VStack(alignment: .leading, spacing: 10) {
                    Text("More picks").font(.title3.bold()).padding(.horizontal)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 12) {
                            ForEach(Array(picks.prefix(60).enumerated()), id: \.element.id) { offset, p in
                                Button { withAnimation(.snappy) { index = offset } } label: {
                                    PosterCard(item: p.item, width: 96)
                                        .overlay {
                                            if offset == safe {
                                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                    .strokeBorder(Theme.pink, lineWidth: 2)
                                                    .frame(width: 96, height: 144)
                                                    .frame(maxHeight: .infinity, alignment: .top)
                                            }
                                        }
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

    private var footer: String {
        let when = reco.builtAt.map { $0.formatted(.relative(presentation: .named)) } ?? "just now"
        let how = reco.usedAI ? "your history, similar titles and on-device AI" : "your history and similar titles"
        return "Built \(when) from \(how). Only titles on your server, never ones you've finished."
    }
}

struct PickCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.zoomNamespace) private var zoom
    let pick: Pick
    let position: Int
    let total: Int
    let noun: String
    let onNext: () -> Void
    let onHandled: () -> Void

    @State private var explanation: String?
    @State private var isExplaining = false
    @State private var explainError: String?
    @State private var showMoreLike = false

    var body: some View {
        let item = pick.item
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                RemoteImage(url: model.client?.posterURL(item, width: 400))
                    .frame(width: 120, height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        if let r = item.officialRating { GlassLabel(text: r).padding(6) }
                    }
                    .zoomSource(id: item.id, in: zoom)
                    .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Pick \(position) of \(total)").font(.caption).foregroundStyle(.secondary)
                    Text(item.displayName).font(.title3.bold()).lineLimit(3)
                    if let m = model.reco.match(for: item) {
                        Text("\(m)% match").font(.headline).foregroundStyle(Theme.pink)
                    }
                    Text(item.subtitleLine).font(.caption).foregroundStyle(.secondary)
                    RatingLabel(item: item)
                }
            }

            if !pick.because.isEmpty {
                Label {
                    Text("Because you liked \(Text(pick.because.joined(separator: ", ")).bold())").font(.subheadline)
                } icon: {
                    Image(systemName: "heart.fill").foregroundStyle(Theme.pink)
                }
            }
            if !pick.highlights.isEmpty {
                FlowLayout { ForEach(pick.highlights, id: \.self) { Chip(text: $0) } }
            }
            Text(item.plainOverview).font(.subheadline).lineLimit(6).foregroundStyle(.secondary)

            aiExplanation

            GlassEffectContainer(spacing: 10) {
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        Button { model.play(item) } label: {
                            Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        Button {
                            Task {
                                await model.toggleWatchlist(item)
                                if model.isOnWatchlist(item) { onHandled() }   // planned = handled: next pick
                            }
                        } label: {
                            Label("My List", systemImage: model.isOnWatchlist(item) ? "bookmark.fill" : "bookmark")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                        NavigationLink(value: ItemLink(item: item)) {
                            Label("Details", systemImage: "info.circle").labelStyle(.iconOnly).frame(width: 44)
                        }
                        .buttonStyle(.glass)
                    }
                    HStack(spacing: 10) {
                        Button(role: .destructive) {
                            onHandled()
                            withAnimation(.snappy) { model.reco.dismiss(item) }
                        } label: {
                            Label("Not for me", systemImage: "hand.thumbsdown").foregroundStyle(.red).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                        Button {
                            Task {
                                await model.togglePlayed(item)
                                onHandled()
                            }
                        } label: {
                            Label("Already watched", systemImage: "eye.fill").lineLimit(1).minimumScaleFactor(0.8)
                                .frame(maxWidth: .infinity)
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
        .onAppear { explanation = PickExplainer.shared.cached(item.id) }
        .sheet(isPresented: $showMoreLike) {
            MoreLikeThisSheet(item: item).presentationDetents([.medium, .large])
        }
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
                    if isExplaining {
                        HStack { ProgressView(); Text("Thinking on-device…") }
                    } else {
                        Label("Why would I like this?", systemImage: "apple.intelligence")
                    }
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
                pick.item, because: pick.because,
                liked: model.reco.topLiked(in: model.reco.currentSourceId),
                highlights: pick.highlights, noun: noun)
        } catch {
            explainError = "Apple Intelligence couldn't write this one (\(error.localizedDescription))."
        }
    }
}
