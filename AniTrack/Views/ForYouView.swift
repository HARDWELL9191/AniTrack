import SwiftUI

/// "Ask Hoshi": one personal pick at a time, like a friend recommending a show.
/// The feed never stops: near the end it quietly digs one round deeper and appends more.
struct ForYouView: View {
    @State private var path = NavigationPath()
    @Environment(AppModel.self) private var model
    @Namespace private var zoom

    @State private var category: AnimeCategory?
    @State private var index = 0
    /// Picks you've dealt with (planned, watched, "Not for me"): they leave the list, so the
    /// next one takes their place, but the "Pick N" counter should still move on.
    @State private var handled = 0

    private var feed: RecommendationResult? { model.feed(for: category) }
    private var picks: [Recommendation] { model.picks(for: category) }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 12) {
                    CategoryChipsBar(selected: $category)
                    content
                }
                .padding(.top, 4)
                .padding(.bottom)
            }
            .navigationTitle("For You")
            // Large title on the same row as the toolbar buttons (no empty row above it).
            .toolbarTitleDisplayMode(.inlineLarge)
            .mediaDestination(zoom: zoom)
            .environment(\.zoomNamespace, zoom)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        index = 0
                        handled = 0
                        Task { await model.generateRecommendations(category: category, force: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(model.isLoadingFeed(category))
                }
            }
            .task(id: category?.id ?? "any") {
                if model.entries.isEmpty { await model.refreshList() }
                await model.generateRecommendations(category: category)
            }
            .onChange(of: category) { _, _ in index = 0; handled = 0 }
            .onChange(of: index) { _, newValue in preloadIfNeeded(at: newValue) }
        }
        .pushDetailAction($path)
    }

    /// Start loading the next round a few picks before the end, so "Another pick" never stalls.
    private func preloadIfNeeded(at position: Int) {
        guard let feed, !feed.exhausted, position >= picks.count - 5 else { return }
        Task { await model.loadMorePicks(category: category) }
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoadingFeed(category) && picks.isEmpty {
            VStack(spacing: 14) {
                ProgressView()
                Text(category == nil ? "Hoshi is reading your list…" : "Finding \(category!.name) picks for you…")
                    .font(.headline)
                Text(model.settings.useOnDeviceAI
                     ? "Comparing your favorites with on-device AI. This only runs when your list changes."
                     : "Comparing your favorites with what fans recommend.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(40)
        } else if let error = model.recommendationError(for: category), picks.isEmpty {
            ContentUnavailableView("Couldn't build picks", systemImage: "exclamationmark.triangle",
                                   description: Text(error))
        } else if picks.isEmpty {
            ContentUnavailableView("No picks yet",
                                   systemImage: "wand.and.stars",
                                   description: Text(category == nil
                                                     ? "Rate a few shows on your list, then refresh."
                                                     : "Nothing new in \(category!.name) right now. Try another category."))
        } else {
            let safeIndex = min(index, picks.count - 1)
            // Each button is tied to the card it belongs to (never re-looked-up at tap time).
            let shownPick = picks[safeIndex]
            PickCard(rec: shownPick,
                     position: safeIndex + 1 + handled,
                     total: picks.count + handled,
                     moreComing: !(feed?.exhausted ?? true),
                     onNext: { next(from: safeIndex) },
                     onDismiss: {
                         handled += 1
                         withAnimation(.snappy) { model.dismissPick(shownPick.id, media: shownPick.media) }
                         preloadIfNeeded(at: safeIndex)
                     },
                     onWatched: {
                         handled += 1
                         // markCompleted already took it out of the feed; the next pick slides in.
                         preloadIfNeeded(at: safeIndex)
                     })
                .id(shownPick.id)
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                        removal: .move(edge: .leading).combined(with: .opacity)))
                .padding(.horizontal)

            if picks.count > 1 {
                VStack(alignment: .leading, spacing: 10) {
                    Text("More picks").font(.title3.bold()).padding(.horizontal)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 12) {
                            ForEach(Array(picks.enumerated()), id: \.element.id) { offset, rec in
                                Button {
                                    withAnimation(.snappy) { index = offset }
                                } label: {
                                    MediaCard(media: rec.media, width: 96)
                                }
                                .buttonStyle(.plain)
                                .onAppear { if offset >= picks.count - 3 { preloadIfNeeded(at: offset) } }
                            }
                            if model.isLoadingMore(category) {
                                ProgressView().frame(width: 96, height: 140)
                            }
                        }
                        .padding(.horizontal)
                    }
                }
            }

            if let feed {
                Text(footer(feed))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
        }
    }

    private func next(from current: Int) {
        let isLast = current >= picks.count - 1
        if isLast && model.isLoadingMore(category) { return }   // the next round is about to arrive
        withAnimation(.snappy) {
            if isLast && (feed?.exhausted ?? true) {
                index = 0   // truly the end: wrap around
                handled = 0
            } else {
                index = min(current + 1, picks.count - 1)
            }
        }
        preloadIfNeeded(at: index)
    }

    private func footer(_ feed: RecommendationResult) -> String {
        let when = feed.generatedAt.formatted(.relative(presentation: .named))
        let engine = feed.usedOnDeviceAI ? "fan recommendations, your tags and on-device AI"
                                         : "fan recommendations and your tags"
        var text = "Built \(when) from \(engine)."
        text += feed.exhausted ? " You've seen everything for now. Rate more shows for new picks."
                               : " More picks load automatically as you go."
        return text
    }
}

struct PickCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.zoomNamespace) private var zoom
    let rec: Recommendation
    let position: Int
    let total: Int
    let moreComing: Bool
    let onNext: () -> Void
    let onDismiss: () -> Void
    let onWatched: () -> Void

    @State private var isAdding = false
    @State private var added = false
    @State private var explanation: String?
    @State private var isExplaining = false
    @State private var explainError: String?
    @State private var showMoreLikeThis = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                CoverImageView(url: rec.media.coverURL, color: rec.media.coverImage?.color,
                               width: 120, height: 174, cornerRadius: 12)
                    .overlay(alignment: .topLeading) { AgeBadge(media: rec.media).padding(6) }
                    .zoomSource(id: rec.media.id, in: zoom)
                    .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                VStack(alignment: .leading, spacing: 8) {
                    Text(moreComing ? "Pick \(position)" : "Pick \(position) of \(total)")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(rec.media.displayTitle(model.settings.titleLanguage))
                        .font(.title3.bold())
                        .lineLimit(3)
                    // The same match % as everywhere else in the app (the pick's rank within
                    // today's list is only a fallback while your taste profile is loading).
                    Text("\(model.matcher.match(for: rec.media) ?? rec.match)% match")
                        .font(.headline)
                        .foregroundStyle(Theme.pink)
                    Text(meta).font(.caption).foregroundStyle(.secondary)
                    ScoreBadge(score: rec.media.averageScore)
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
                FlowLayout {
                    ForEach(rec.sharedHighlights, id: \.self) { Chip(text: $0) }
                }
            }

            Text(rec.media.plainDescription)
                .font(.subheadline)
                .lineLimit(6)
                .foregroundStyle(.secondary)

            aiExplanation

            GlassEffectContainer(spacing: 10) {
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        if model.canEdit && model.entry(for: rec.id) == nil {
                            Button {
                                Task { await addToPlanning() }
                            } label: {
                                Label(added ? "Added" : "Plan to watch",
                                      systemImage: added ? "checkmark" : "bookmark.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.glassProminent)
                            .disabled(isAdding || added)
                        }
                        NavigationLink(value: MediaLink(id: rec.media.id)) {
                            Label("Details", systemImage: "info.circle").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                    }

                    HStack(spacing: 10) {
                        Button(role: .destructive, action: onDismiss) {
                            Label("Not for me", systemImage: "hand.thumbsdown").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                        if model.canEdit {
                            Button {
                                Task {
                                    // Only counts as handled if AniList saved it (else it stays put).
                                    if await model.markCompleted(rec.media) { onWatched() }
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
            // Content card (not glass, per Apple's guidance): tinted by the show's own cover color.
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.background.secondary)
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(LinearGradient(colors: [(Color(hex: rec.media.coverImage?.color) ?? Theme.accent).opacity(0.22), .clear],
                                             startPoint: .top, endPoint: .bottom))
                }
        }
        .onAppear { explanation = PickExplainer.shared.cached(rec.id) }
        .sheet(isPresented: $showMoreLikeThis) {
            MoreLikeThisSheet(media: rec.media)
                .presentationDetents([.medium, .large])
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
                if let explainError {
                    Text(explainError).font(.caption).foregroundStyle(.secondary)
                }
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
        let liked = model.entries
            .filter { $0.scoreValue >= 75 || ($0.status == .COMPLETED && $0.scoreValue == 0) }
            .sorted { $0.scoreValue > $1.scoreValue }
            .prefix(8)
            .map { $0.media.displayTitle(model.settings.titleLanguage) }
        do {
            explanation = try await PickExplainer.shared.explain(rec, likedTitles: Array(liked),
                                                                 language: model.settings.titleLanguage)
        } catch {
            explainError = "Apple Intelligence couldn't write this one (\(error.localizedDescription))."
        }
    }

    private func addToPlanning() async {
        isAdding = true
        defer { isAdding = false }
        // The whole show goes to Planning (its other seasons follow in the background).
        let planned = await model.planToWatch(rec.media)
        guard planned else { return }   // the error is shown already
        added = true
        // Planned = handled: move on to the next pick (the feed drops it, the next card slides in).
        withAnimation(.snappy) { model.removeFromFeeds(rec.id) }
        onWatched()
    }
}
