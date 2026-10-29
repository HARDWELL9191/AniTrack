import SwiftUI

// MARK: - Zoom transition (cover → detail page)

extension EnvironmentValues {
    /// Namespace of the current tab's NavigationStack, used for the cover-to-detail zoom.
    @Entry var zoomNamespace: Namespace.ID? = nil
}

extension View {
    /// Marks a cover as the place the detail page zooms out of.
    @ViewBuilder
    func zoomSource(id: Int, in namespace: Namespace.ID?) -> some View {
        if let namespace {
            matchedTransitionSource(id: id, in: namespace)
        } else {
            self
        }
    }

    /// Standard detail destination with the native zoom transition.
    func mediaDestination(zoom namespace: Namespace.ID) -> some View {
        navigationDestination(for: MediaLink.self) { link in
            MediaDetailView(mediaId: link.id)
                .navigationTransition(.zoom(sourceID: link.id, in: namespace))
        }
    }

    /// Detail destination inside a sheet: the normal slide-in. (The zoom inside a sheet
    /// makes the page jump to full screen and the sheet vanish and come back on the way out.)
    func plainMediaDestination() -> some View {
        navigationDestination(for: MediaLink.self) { link in
            MediaDetailView(mediaId: link.id)
        }
    }
}

extension Color {
    init?(hex: String?) {
        guard var s = hex?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt64(s, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}

struct CoverImageView: View {
    let url: String?
    var color: String? = nil
    var width: CGFloat
    var height: CGFloat
    var cornerRadius: CGFloat = 8

    var body: some View {
        AsyncImage(url: url.flatMap(URL.init(string:))) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            case .failure:
                ZStack {
                    placeholder
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            default:
                placeholder
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private var placeholder: some View {
        Rectangle().fill((Color(hex: color) ?? .gray).opacity(0.25))
    }
}

struct BannerImageView: View {
    let url: String?
    var fallbackColor: String?
    var height: CGFloat = 200

    var body: some View {
        // The container decides the width; the image only fills and is clipped to it.
        // (A scaled-to-fill image as the layout root made the whole page wider than the screen.)
        Rectangle()
            .fill(LinearGradient(colors: [(Color(hex: fallbackColor) ?? Theme.accent).opacity(0.7),
                                          Color(.systemBackground)],
                                 startPoint: .top, endPoint: .bottom))
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .overlay {
                AsyncImage(url: url.flatMap(URL.init(string:))) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    }
                }
            }
            .clipped()
    }
}

/// Swipe left on a row to remove the show from your AniList list (asks first);
/// swipe right to mark it as fully watched and move it to Completed.
struct RemoveFromListSwipe: ViewModifier {
    @Environment(AppModel.self) private var model
    let entry: ListEntry

    @ViewBuilder
    func body(content: Content) -> some View {
        if model.canEdit {
            content
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    // Swipe = removed, no question asked (the whole show, every season).
                    Button(role: .destructive) {
                        Task {
                            do {
                                try await model.removeShow(entry.media, entryId: entry.id)
                            } catch {
                                model.errorMessage = error.localizedDescription
                            }
                        }
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                }
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    if entry.status != .COMPLETED {
                        Button {
                            Task { await model.markCompleted(entry.media) }
                        } label: {
                            Label("Completed", systemImage: "checkmark.circle.fill")
                        }
                        .tint(.green)
                    }
                }
        } else {
            content
        }
    }
}

extension View {
    func removeFromListSwipe(_ entry: ListEntry) -> some View {
        modifier(RemoveFromListSwipe(entry: entry))
    }
}

/// Community score shown out of 10 (AniList stores it as 0–100), with a mood smiley.
struct ScoreBadge: View {
    let score: Int?
    var body: some View {
        if let score, score > 0 {
            Label(Fmt.outOfTen(score), systemImage: Fmt.smiley(score))
                .font(.caption.weight(.semibold))
                .foregroundStyle(score >= 75 ? .green : (score >= 60 ? .orange : .red))
        }
    }
}

/// Personal match %, shown next to the community score.
struct MatchBadge: View {
    @Environment(AppModel.self) private var model
    let media: Media
    var showWord = false

    var body: some View {
        if let value = model.matcher.match(for: media) {
            Label(showWord ? "\(value)% match" : "\(value)%", systemImage: "wand.and.stars")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.pink)
        }
    }
}

struct Chip: View {
    let text: String
    var tint: Color = Theme.accent
    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }
}

/// Simple wrapping layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(widest, maxWidth), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

struct MediaCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.zoomNamespace) private var zoom
    let media: Media
    var width: CGFloat = 112

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                CoverImageView(url: media.coverURL, color: media.coverImage?.color,
                               width: width, height: width * 1.45)
                    .zoomSource(id: media.id, in: zoom)
                    .overlay(alignment: .bottomLeading) {
                        if let value = model.matcher.match(for: media) {
                            MatchBubble(value: value).padding(5)
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        AgeBadge(media: media).padding(5)
                    }
                if let entry = model.entry(for: media.id) {
                    Image(systemName: entry.status.symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .glassEffect(.regular, in: .circle)
                        .padding(5)
                }
            }
            Text(media.displayTitle(model.settings.titleLanguage))
                .font(.caption.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(width: width, alignment: .leading)
            ScoreBadge(score: media.averageScore)
        }
        .foregroundStyle(.primary)
        .contentShape(Rectangle())
        .showActions(media)
    }
}

struct MediaRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.zoomNamespace) private var zoom
    let media: Media
    var subtitle: String? = nil
    /// The ">" a list row shows (drawn here since rows are plain buttons, see MediaRowLink).
    var chevron = false

    var body: some View {
        HStack(spacing: 12) {
            CoverImageView(url: media.thumbURL, color: media.coverImage?.color, width: 54, height: 78, cornerRadius: 6)
                .zoomSource(id: media.id, in: zoom)
            VStack(alignment: .leading, spacing: 4) {
                Text(media.displayTitle(model.settings.titleLanguage))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text(subtitle ?? defaultSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 10) {
                    ScoreBadge(score: media.averageScore)
                    // Wand outside, % in the same pink glass bubble as on covers.
                    if let value = model.matcher.match(for: media) {
                        HStack(spacing: 5) {
                            Image(systemName: "wand.and.stars")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.pink)
                            MatchBubble(value: value)
                        }
                    }
                    AgeBadge(media: media)
                }
            }
            Spacer(minLength: 0)
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .showActions(media)
    }

    private var defaultSubtitle: String {
        var parts = [media.formatLabel]
        if let eps = media.episodes { parts.append("\(eps) eps") }
        if let season = media.seasonLabel { parts.append(season) }
        return parts.joined(separator: " · ")
    }
}

/// A list row that opens the show's details. A plain button, not a NavigationLink: inside a
/// List a NavigationLink row first flashes the list's own sharp-cornered grey highlight and
/// then swaps to the long-press menu's rounded one. Here the pressed look is that same rounded
/// highlight, so touch → hold → menu is one continuous shape.
struct MediaRowLink: View {
    @Environment(\.pushDetail) private var pushDetail
    let media: Media
    var subtitle: String? = nil

    var body: some View {
        if let pushDetail {
            Button { pushDetail(media.id) } label: {
                MediaRow(media: media, subtitle: subtitle, chevron: true)
            }
            .buttonStyle(RowPressStyle())
        } else {
            NavigationLink(value: MediaLink(id: media.id)) { MediaRow(media: media, subtitle: subtitle) }
        }
    }
}

/// Pressed rows: the same rounded grey highlight the long-press menu shows (8 pt around the
/// row, matching corners), never the list's own full-width one.
struct RowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                if configuration.isPressed {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(.systemGray5))
                        .padding(-8)
                }
            }
    }
}

struct HorizontalMediaSection: View {
    @Environment(AppModel.self) private var model
    let title: String
    let items: [Media]

    var body: some View {
        // A show marked "Not for me" (e.g. from its long-press menu) leaves the row right away.
        // "Hide Chinese animation" applies the moment it's switched on (saved shelves too).
        let hideCN = model.settings.hideChinese
        let shown = items.filter {
            !model.settings.dismissedPicks.contains($0.id) && !(hideCN && $0.countryOfOrigin == "CN")
        }
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3.weight(.bold)).padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(shown) { media in
                        NavigationLink(value: MediaLink(id: media.id)) {
                            MediaCard(media: media)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
            .scrollClipDisabled()   // a pressed cover grows a little: never cut its top off
        }
    }
}

enum Fmt {
    static func countdown(_ seconds: Int) -> String {
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(max(minutes, 1))m"
    }

    static func airing(_ next: AiringEpisode?) -> String? {
        guard let next else { return nil }
        let remaining = max(0, next.airingAt - Int(Date().timeIntervalSince1970))
        return "Ep \(next.episode) in \(countdown(remaining))"
    }

    /// 82 → "8.2/10"
    static func outOfTen(_ score: Int) -> String {
        String(format: "%.1f/10", Double(score) / 10)
    }

    static func smiley(_ score: Int) -> String {
        if score >= 75 { return "face.smiling.inverse" }
        if score >= 60 { return "face.smiling" }
        return "face.dashed"
    }

    static func score(_ raw: Double?) -> String {
        guard let raw, raw > 0 else { return "–" }
        let ten = raw / 10
        return ten == ten.rounded() ? String(Int(ten)) : String(format: "%.1f", ten)
    }
}
