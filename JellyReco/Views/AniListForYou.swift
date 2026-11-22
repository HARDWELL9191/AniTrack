import SwiftUI

// AniReco's For You, for the libraries that run on AniList (Anime / Anime Movies): the same
// pick card, buttons, "More picks" row, category dropdown and endless feed as in AniReco.

extension Color {
    /// AniList's cover colours ("#e4a15d").
    init?(aniHex hex: String?) {
        guard var s = hex?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt64(s, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}

extension AniListService {
    /// AniReco's quick picks: the featured categories AniList confirmed exist.
    var featuredCategories: [AnimeCategory] {
        guard !categories.isEmpty else { return AnimeCategory.featured }
        let known = Set(categories.map(\.id))
        return AnimeCategory.featured.filter { known.contains($0.id) }
    }
}

/// AniReco's category dropdown items: Any category, the popular genres, the popular tags, and
/// "All categories…" (every AniList genre and tag, searchable).
struct AniCategoryMenuItems: View {
    @Environment(AppModel.self) private var model
    @Binding var selected: AnimeCategory?
    @Binding var showAll: Bool

    var body: some View {
        let featured = model.anilist.featuredCategories
        Button { selected = nil } label: {
            if selected == nil { Label("Any category", systemImage: "checkmark") } else { Text("Any category") }
        }
        Divider()
        Section("Genres") { ForEach(featured.filter { $0.kind == .genre }) { item($0) } }
        Section("Tags") { ForEach(featured.filter { $0.kind == .tag }) { item($0) } }
        Divider()
        Button { showAll = true } label: { Label("All categories…", systemImage: "magnifyingglass") }
    }

    @ViewBuilder
    private func item(_ c: AnimeCategory) -> some View {
        Button { selected = c } label: {
            if selected == c { Label(c.name, systemImage: "checkmark") } else { Text(c.name) }
        }
    }
}

/// Every AniList genre and tag, searchable (AniReco's "All categories…").
struct AniAllCategoriesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let onSelect: (AnimeCategory) -> Void
    @State private var search = ""

    private func filtered(_ kind: AnimeCategory.Kind) -> [AnimeCategory] {
        let source = model.anilist.categories.isEmpty ? AnimeCategory.featured : model.anilist.categories
        return source
            .filter { $0.kind == kind }
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List {
                let genres = filtered(.genre)
                let tags = filtered(.tag)
                if !genres.isEmpty {
                    Section("Genres") {
                        ForEach(genres) { c in Button(c.name) { onSelect(c) }.foregroundStyle(.primary) }
                    }
                }
                if !tags.isEmpty {
                    Section("Tags") {
                        ForEach(tags) { c in Button(c.name) { onSelect(c) }.foregroundStyle(.primary) }
                    }
                }
            }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Isekai, Romance, Ecchi…")
            .navigationTitle("Categories")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .task { await model.anilist.loadCategories() }
        }
    }
}

/// AniReco's cover card (the "More picks" row): match bubble, age, your list status, score.
struct AniListMediaCard: View {
    @Environment(AppModel.self) private var model
    let media: Media
    var width: CGFloat = 96

    var body: some View {
        let anilist = model.anilist
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                RemoteImage(url: media.coverURL.flatMap(URL.init(string:)), placeholderSymbol: "tv")
                    .frame(width: width, height: width * 1.45)
                    .background((Color(aniHex: media.coverImage?.color) ?? .gray).opacity(0.25))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(alignment: .bottomLeading) {
                        if let value = anilist.matcher.match(for: media) { MatchBubble(value: value).padding(5) }
                    }
                    .overlay(alignment: .topLeading) { AniListAgeBubble(id: media.id).padding(5) }
                if let entry = anilist.entry(for: media.id) {
                    Image(systemName: entry.status.symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .glassEffect(.regular, in: .circle)
                        .padding(5)
                }
            }
            Text(media.displayTitle(anilist.language))
                .font(.caption.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(width: width, alignment: .leading)
            ListScoreBadge(score: media.averageScore)
        }
        .foregroundStyle(.primary)
        .contentShape(Rectangle())
    }
}

/// AniReco's pick card, word for word: cover, "Pick N", match %, facts, score, why, chips,
/// synopsis, "Why would I like this?", then Plan to watch / Details, Not for me / Already
/// watched, More like this / Another pick.
struct AniListPickCard: View {
    @Environment(AppModel.self) private var model
    let rec: Recommendation
    let position: Int
    let total: Int
    let moreComing: Bool
    let noun: String
    let onNext: () -> Void
    let onDismiss: () -> Void
    let onWatched: () -> Void
    let onDetails: () -> Void

    @State private var isAdding = false
    @State private var added = false
    @State private var explanation: String?
    @State private var isExplaining = false
    @State private var explainError: String?
    @State private var showMoreLikeThis = false

    private var anilist: AniListService { model.anilist }
    private var title: ExternalTitle { anilist.title(for: rec.media) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Button(action: onDetails) {
                    RemoteImage(url: rec.media.coverURL.flatMap(URL.init(string:)), placeholderSymbol: "tv")
                        .frame(width: 120, height: 174)
                        .background((Color(aniHex: rec.media.coverImage?.color) ?? .gray).opacity(0.25))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(alignment: .topLeading) { AniListAgeBubble(id: rec.media.id).padding(6) }
                        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                }
                .buttonStyle(PressStyle())
                VStack(alignment: .leading, spacing: 8) {
                    Text(moreComing ? "Pick \(position)" : "Pick \(position) of \(total)")
                        .font(.caption).foregroundStyle(.secondary)
                    SelectableText(text: rec.media.displayTitle(anilist.language), style: .title3, weight: .bold, lineLimit: 3)
                    // The same match % as everywhere else (the pick's own rank only while the
                    // taste profile is loading).
                    Text("\(anilist.matcher.match(for: rec.media) ?? rec.match)% match")
                        .font(.headline)
                        .foregroundStyle(Theme.pink)
                    Text(meta).font(.caption).foregroundStyle(.secondary)
                    ListScoreBadge(score: rec.media.averageScore)
                }
            }

            if !rec.because.isEmpty {
                Label {
                    Text("Because you liked \(Text(rec.because.joined(separator: ", ")).bold())")
                        .font(.subheadline)
                } icon: {
                    Image(systemName: "heart.fill").foregroundStyle(Theme.pink)
                }
            }

            if !rec.sharedHighlights.isEmpty {
                FlowLayout { ForEach(rec.sharedHighlights, id: \.self) { Chip(text: $0) } }
            }

            SelectableText(text: rec.media.plainDescription, style: .subheadline, color: .secondaryLabel, lineLimit: 6)

            aiExplanation

            GlassEffectContainer(spacing: 10) {
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        if anilist.isLoggedIn && anilist.entry(for: rec.id) == nil {
                            Button {
                                Task { await addToPlanning() }
                            } label: {
                                Label(added ? "Added" : "Plan to watch", systemImage: added ? "checkmark" : "bookmark.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.glassProminent)
                            .disabled(isAdding || added)
                        }
                        Button(action: onDetails) {
                            Label("Details", systemImage: "info.circle").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                    }
                    HStack(spacing: 10) {
                        Button(role: .destructive, action: onDismiss) {
                            Label("Not for me", systemImage: "hand.thumbsdown")
                                .foregroundStyle(.red)   // glass buttons don't tint destructive ones
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                        if anilist.isLoggedIn {
                            Button {
                                Task {
                                    // Only counts as handled if AniList saved it (else it stays put).
                                    if await anilist.markCompleted(rec.media) { onWatched() }
                                }
                            } label: {
                                Label("Already watched", systemImage: "eye.fill")
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.glass)
                        }
                    }
                    HStack(spacing: 10) {
                        Button { showMoreLikeThis = true } label: {
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
            // Tinted by the show's own cover colour (AniReco).
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.background.secondary)
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(LinearGradient(colors: [(Color(aniHex: rec.media.coverImage?.color) ?? Theme.accent).opacity(0.22), .clear],
                                             startPoint: .top, endPoint: .bottom))
                }
        }
        .onAppear { explanation = PickExplainer.shared.cached(title.id) }
        .sheet(isPresented: $showMoreLikeThis) {
            ExternalMoreLikeSheet(title: title).presentationDetents([.medium, .large])
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

    private var meta: String {
        var parts = [rec.media.formatLabel]
        if let eps = rec.media.episodes { parts.append("\(eps) eps") }
        if let season = rec.media.seasonLabel { parts.append(season) }
        return parts.joined(separator: " · ")
    }

    private func explain() async {
        isExplaining = true
        explainError = nil
        defer { isExplaining = false }
        let t = title
        do {
            explanation = try await PickExplainer.shared.explain(
                DiscoveryEngine.pseudoItem(t).withOverview(t.overview),
                because: rec.because, liked: anilist.topLiked(), highlights: rec.sharedHighlights, noun: noun)
        } catch {
            explainError = "Apple Intelligence couldn't write this one (\(error.localizedDescription))."
        }
    }

    private func addToPlanning() async {
        isAdding = true
        defer { isAdding = false }
        // The whole show goes to Planning (its other seasons follow in the background).
        guard await anilist.planToWatch(rec.media) else { return }
        added = true
        // Planned = handled: the next pick slides in.
        withAnimation(.snappy) { anilist.removeFromFeeds(rec.id) }
        onWatched()
    }
}
