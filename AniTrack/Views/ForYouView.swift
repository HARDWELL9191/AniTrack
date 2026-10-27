import SwiftUI

/// "Ask Hoshi": one personal pick at a time, like a friend recommending a show.
struct ForYouView: View {
    @Environment(AppModel.self) private var model
    @Namespace private var zoom

    enum Source: String, CaseIterable, Identifiable {
        case new = "New for me"
        case planning = "From my Planning"
        var id: String { rawValue }
    }

    @State private var source: Source = .new
    @State private var index = 0

    private var picks: [Recommendation] {
        guard let result = model.recommendations else { return [] }
        return source == .new ? result.discover : result.planning
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Picker("Source", selection: $source) {
                        ForEach(Source.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)

                    content
                }
                .padding(.vertical)
            }
            .navigationTitle("For You")
            .mediaDestination(zoom: zoom)
            .environment(\.zoomNamespace, zoom)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        index = 0
                        Task { await model.generateRecommendations(force: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(model.isLoadingRecommendations)
                }
            }
            .task {
                if model.entries.isEmpty { await model.refreshList() }
                await model.generateRecommendations()
            }
            .onChange(of: source) { _, _ in index = 0 }
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoadingRecommendations && model.recommendations == nil {
            VStack(spacing: 14) {
                ProgressView()
                Text("Hoshi is reading your list…")
                    .font(.headline)
                Text(model.settings.useOnDeviceAI
                     ? "Comparing your favorites with on-device AI. This only runs when your list changes."
                     : "Comparing your favorites with what fans recommend.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(40)
        } else if let error = model.recommendationError, model.recommendations == nil {
            ContentUnavailableView("Couldn't build picks", systemImage: "exclamationmark.triangle",
                                   description: Text(error))
        } else if picks.isEmpty {
            ContentUnavailableView(source == .new ? "No new picks" : "Nothing on Planning",
                                   systemImage: "wand.and.stars",
                                   description: Text(source == .new
                                                     ? "Rate more shows on your list, then refresh."
                                                     : "Add shows to Planning and Hoshi will choose which one to start next."))
        } else {
            let safeIndex = min(index, picks.count - 1)
            PickCard(rec: picks[safeIndex],
                     position: safeIndex + 1,
                     total: picks.count,
                     onNext: { withAnimation(.snappy) { index = (safeIndex + 1) % picks.count } },
                     onDismiss: {
                         withAnimation(.snappy) { model.dismissPick(picks[safeIndex].id) }
                     })
                .id(picks[safeIndex].id)
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                        removal: .move(edge: .leading).combined(with: .opacity)))
                .padding(.horizontal)

            if picks.count > 1 {
                VStack(alignment: .leading, spacing: 10) {
                    Text("More picks").font(.title3.bold()).padding(.horizontal)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 12) {
                            ForEach(Array(picks.prefix(30).enumerated()), id: \.element.id) { offset, rec in
                                Button {
                                    withAnimation(.snappy) { index = offset }
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        MediaCard(media: rec.media, width: 96)
                                        Text("\(rec.match)% match")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(Theme.pink)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                    }
                }
            }

            if let result = model.recommendations {
                Text(footer(result))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
        }
    }

    private func footer(_ result: RecommendationResult) -> String {
        let when = result.generatedAt.formatted(.relative(presentation: .named))
        let engine = result.usedOnDeviceAI ? "fan recommendations, your tags and on-device AI"
                                           : "fan recommendations and your tags"
        return "Built \(when) from \(engine). Picks refresh automatically when your list changes."
    }
}

struct PickCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.zoomNamespace) private var zoom
    let rec: Recommendation
    let position: Int
    let total: Int
    let onNext: () -> Void
    let onDismiss: () -> Void

    @State private var isAdding = false
    @State private var added = false
    @State private var explanation: String?
    @State private var isExplaining = false
    @State private var explainError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                CoverImageView(url: rec.media.coverURL, color: rec.media.coverImage?.color,
                               width: 120, height: 174, cornerRadius: 12)
                    .zoomSource(id: rec.media.id, in: zoom)
                    .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Pick \(position) of \(total)")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(rec.media.displayTitle(model.settings.titleLanguage))
                        .font(.title3.bold())
                        .lineLimit(3)
                    Text("\(rec.match)% match")
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
                        if model.canEdit && !rec.onPlanning {
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
        do {
            try await model.save(media: rec.media, status: .PLANNING, progress: nil, scoreRaw: nil)
            added = true
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }
}
