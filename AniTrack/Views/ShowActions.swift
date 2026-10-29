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
        // A custom preview, so only the pressed show lifts out (inside a List the system would
        // otherwise lift the whole row of covers).
        // The highlight while you hold sits a little outside the show (padding added, then taken
        // back so the layout doesn't move): the cover never touches the highlight's edge.
        content
            .padding(Self.highlightPadding)
            .contentShape(.contextMenuPreview,
                          RoundedRectangle(cornerRadius: 10 + Self.highlightPadding, style: .continuous))
            .contextMenu { menuItems } preview: {
                // iOS renders the preview outside the app's view tree, so it gets plain values
                // only (reading the app model inside it would crash).
                ShowMenuPreview(coverURL: media.coverURL,
                                coverColor: media.coverImage?.color,
                                title: media.displayTitle(model.settings.titleLanguage),
                                score: media.averageScore,
                                match: model.matcher.match(for: media),
                                age: model.ages.rating(for: media.id)?.label)
            }
            .padding(-Self.highlightPadding)
    }

    private static let highlightPadding: CGFloat = 8

    @ViewBuilder
    private var menuItems: some View {
            let entry = model.entry(for: media.id)
            // Only for shows not on your lists: it must never move a watched show back to Planning.
            if model.canEdit && entry == nil {
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
                    // Inside a sheet the sheet itself shows the rating prompt.
                    Task { await model.markCompleted(media, inSheet: !sheetsAllowed) }
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

/// What lifts out when you long-press a show: just that show's cover, title and bubbles.
struct ShowMenuPreview: View {
    let coverURL: String?
    let coverColor: String?
    let title: String
    let score: Int?
    let match: Int?
    let age: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CoverImageView(url: coverURL, color: coverColor, width: 200, height: 290, cornerRadius: 12)
                .overlay(alignment: .topLeading) {
                    if let age { AgeBubble(label: age).padding(6) }
                }
                .overlay(alignment: .bottomLeading) {
                    if let match { MatchBubble(value: match).padding(6) }
                }
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .frame(width: 200, alignment: .leading)
            ScoreBadge(score: score)
        }
        .padding(12)
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

/// Match % bubble: pink-tinted Liquid Glass, white text (covers and list rows).
struct MatchBubble: View {
    /// Both bubbles are exactly this tall; their width follows the text.
    static let height: CGFloat = 22
    let value: Int
    var body: some View {
        Text("\(value)%")
            .font(.caption2.weight(.bold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .frame(height: Self.height)
            .glassEffect(.regular.tint(Theme.pinkGlass.opacity(0.55)), in: .capsule)
            // Same faint white edge as the age bubble.
            .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 0.5))
    }
}

/// Age rating bubble: black-tinted Liquid Glass, white text (top-left of covers).
struct AgeBubble: View {
    let label: String
    var body: some View {
        Text(label)
            .font(.caption2.weight(.bold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .frame(height: MatchBubble.height)
            .glassEffect(.regular.tint(.black.opacity(0.55)), in: .capsule)
            // A faint edge keeps it visible on very dark covers.
            .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 0.5))
    }
}

/// The age bubble for a show, if its rating is known (asks for it when it appears).
struct AgeBadge: View {
    @Environment(AppModel.self) private var model
    let media: Media
    private var mediaId: Int { media.id }

    var body: some View {
        ZStack {
            if let label = model.ages.rating(for: mediaId)?.label {
                AgeBubble(label: label)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.ages.rating(for: mediaId)?.label)
        .onAppear { model.ages.request(media) }
    }
}
