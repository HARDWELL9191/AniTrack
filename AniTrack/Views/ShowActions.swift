import SwiftUI

// MARK: - Navigation from menus

extension EnvironmentValues {
    /// Opens a show's details in the current tab (or sheet). Set by each NavigationStack.
    @Entry var pushDetail: ((Int) -> Void)? = nil
    /// False inside sheets, so a menu there can't try to open a second sheet on top.
    @Entry var cardSheetsAllowed: Bool = true
}

/// Sheets that can be opened from any show card's long-press menu.
enum CardSheet: Identifiable {
    case moreLikeThis(Media)
    case why(Media)
    var id: String {
        switch self {
        case .moreLikeThis(let m): return "more-\(m.id)"
        case .why(let m): return "why-\(m.id)"
        }
    }
}

// MARK: - Long-press menu

/// Long-press any show card: Plan to watch, Details, Not for me, Already watched,
/// More like this, Why would I like this?. A normal tap still opens the details page.
struct ShowActionsMenu: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.pushDetail) private var pushDetail
    @Environment(\.cardSheetsAllowed) private var sheetsAllowed
    let media: Media

    func body(content: Content) -> some View {
        content.contextMenu {
            let entry = model.entry(for: media.id)
            if model.canEdit && entry?.status != .PLANNING {
                Button("Plan to watch", systemImage: "bookmark.fill") {
                    Task { await model.planToWatch(media) }
                }
            }
            if let pushDetail {
                Button("Details", systemImage: "info.circle") { pushDetail(media.id) }
            }
            if entry == nil && !model.settings.dismissedPicks.contains(media.id) {
                Button("Not for me", systemImage: "hand.thumbsdown", role: .destructive) {
                    withAnimation(.snappy) { model.dismissPick(media.id, media: media) }
                }
            }
            if model.canEdit && entry?.status != .COMPLETED {
                Button("Already watched", systemImage: "eye.fill") {
                    // Inside a sheet the rating prompt can't open on top, so it's skipped there.
                    Task { await model.markCompleted(media, askRating: sheetsAllowed) }
                }
            }
            if sheetsAllowed {
                Button("More like this", systemImage: "square.stack.3d.up") {
                    model.cardSheet = .moreLikeThis(media)
                }
            }
            if sheetsAllowed, case .available = PickExplainer.shared.availability {
                Button("Why would I like this?", systemImage: "apple.intelligence") {
                    model.cardSheet = .why(media)
                }
            }
        }
    }
}

extension View {
    func showActions(_ media: Media) -> some View {
        modifier(ShowActionsMenu(media: media))
    }

    /// Gives a NavigationStack's content the "open details" action used by long-press menus.
    func pushDetailAction(_ path: Binding<NavigationPath>) -> some View {
        environment(\.pushDetail) { id in path.wrappedValue.append(MediaLink(id: id)) }
    }
}

// MARK: - "Why would I like this?" sheet

struct WhyThisSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let media: Media

    @State private var text: String?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 14) {
                    CoverImageView(url: media.coverURL, color: media.coverImage?.color,
                                   width: 70, height: 100, cornerRadius: 8)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(media.displayTitle(model.settings.titleLanguage))
                            .font(.headline).lineLimit(3)
                        MatchBadge(media: media, showWord: true)
                    }
                }
                if let text {
                    Label {
                        Text(text).font(.subheadline)
                    } icon: {
                        Image(systemName: "apple.intelligence").foregroundStyle(Theme.accent)
                    }
                    .padding(12)
                    .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else if let error {
                    Text(error).font(.subheadline).foregroundStyle(.secondary)
                } else {
                    HStack { ProgressView(); Text("Thinking on-device…").foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
            }
            .padding()
            .navigationTitle("Why you might like it")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .task { await explain() }
        }
    }

    private func explain() async {
        let liked = model.entries
            .filter { $0.scoreValue >= 75 || ($0.status == .COMPLETED && $0.scoreValue == 0) }
            .sorted { $0.scoreValue > $1.scoreValue }
            .prefix(8)
            .map { $0.media.displayTitle(model.settings.titleLanguage) }
        let rec = Recommendation(media: media, score: 0,
                                 match: model.matcher.match(for: media) ?? 0,
                                 because: [], sharedHighlights: [])
        do {
            text = try await PickExplainer.shared.explain(rec, likedTitles: Array(liked),
                                                          language: model.settings.titleLanguage)
        } catch {
            self.error = "Apple Intelligence couldn't write this one (\(error.localizedDescription))."
        }
    }
}

// MARK: - Bubbles

/// Age rating bubble: black-tinted Liquid Glass, white text (top-left of covers).
struct AgeBubble: View {
    let label: String
    var body: some View {
        Text(label)
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .glassEffect(.regular.tint(.black.opacity(0.55)), in: .capsule)
            // A faint edge keeps it visible on very dark covers.
            .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 0.5))
    }
}

/// The age bubble for a show, if its rating is known (asks for it when it appears).
struct AgeBadge: View {
    @Environment(AppModel.self) private var model
    let mediaId: Int

    var body: some View {
        ZStack {
            if let label = model.ages.rating(for: mediaId)?.label {
                AgeBubble(label: label)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.ages.rating(for: mediaId)?.label)
        .onAppear { model.ages.request(mediaId) }
    }
}
