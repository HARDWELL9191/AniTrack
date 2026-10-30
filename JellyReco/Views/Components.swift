import SwiftUI

enum Theme {
    static let accent = Color(red: 0.24, green: 0.60, blue: 1.0)
    static let pink = Color(red: 0.98, green: 0.45, blue: 0.62)
    /// Match % glass tint (AniReco's darker pink).
    static let pinkGlass = Color(red: 0.86, green: 0.33, blue: 0.50)
}

// MARK: - Navigation

/// Where a tap on an item goes.
struct ItemLink: Hashable {
    let item: BaseItem
}

struct LibraryLink: Hashable {
    let library: BaseItem
}

struct PersonLink: Hashable {
    let id: String
    let name: String
}

struct GenreLink: Hashable {
    let name: String
    let parentId: String?
}

extension EnvironmentValues {
    @Entry var zoomNamespace: Namespace.ID? = nil
}

extension View {
    @ViewBuilder
    func zoomSource(id: String, in namespace: Namespace.ID?) -> some View {
        if let namespace { matchedTransitionSource(id: id, in: namespace) } else { self }
    }

    /// Every tab's NavigationStack gets the same destinations (with the cover → page zoom).
    func appDestinations(zoom: Namespace.ID) -> some View {
        self
            .navigationDestination(for: ItemLink.self) { link in
                ItemDetailView(item: link.item)
                    .navigationTransition(.zoom(sourceID: link.item.id, in: zoom))
            }
            .navigationDestination(for: LibraryLink.self) { LibraryView(library: $0.library) }
            .navigationDestination(for: PersonLink.self) { PersonView(personId: $0.id, name: $0.name) }
            .navigationDestination(for: GenreLink.self) { GenreItemsView(genre: $0.name, parentId: $0.parentId) }
    }
}

// MARK: - Images

struct RemoteImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    var placeholderSymbol: String = "film"

    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: contentMode)
            case .failure:
                placeholder.overlay(Image(systemName: placeholderSymbol).foregroundStyle(.secondary))
            default:
                placeholder
            }
        }
    }

    private var placeholder: some View {
        Rectangle().fill(.fill.tertiary)
    }
}

// MARK: - Glass bubbles (same look as AniReco)

struct MatchBubble: View {
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
            .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 0.5))
    }
}

/// Black-tinted glass label (age rating, episode count, resolution…).
struct GlassLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .frame(height: MatchBubble.height)
            .glassEffect(.regular.tint(.black.opacity(0.45)), in: .capsule)
            .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 0.5))
    }
}

struct GlassIcon: View {
    let symbol: String
    var tint: Color = .black.opacity(0.4)
    var body: some View {
        Image(systemName: symbol)
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .glassEffect(.regular.tint(tint), in: .circle)
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

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
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
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

struct RatingLabel: View {
    let item: BaseItem
    var body: some View {
        HStack(spacing: 8) {
            if let r = Fmt.rating(item.communityRating) {
                Label(r, systemImage: "star.fill")
                    .foregroundStyle(.yellow)
            }
            if let critic = item.criticRating, critic > 0 {
                Label("\(Int(critic))%", systemImage: critic >= 60 ? "leaf.fill" : "leaf")
                    .foregroundStyle(critic >= 60 ? .green : .orange)
            }
        }
        .font(.caption.weight(.semibold))
    }
}

/// Pressed covers: the same rounded grey highlight AniReco uses (no dimming blink).
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
            .background {
                if configuration.isPressed {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(.systemGray5))
                        .padding(-8)
                }
            }
    }
}

// MARK: - Cards

/// Portrait poster with match %, watched / unplayed / progress indicators and a title.
struct PosterCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.zoomNamespace) private var zoom
    let item: BaseItem
    var width: CGFloat = 112
    var showTitle = true

    var body: some View {
        let settings = model.settings
        let data = model.userData(for: item)
        VStack(alignment: .leading, spacing: 6) {
            RemoteImage(url: model.client?.posterURL(item, width: Int(width * 3)),
                        placeholderSymbol: item.kind == .series ? "tv" : "film")
                .frame(width: width, height: width * 1.5)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .bottomLeading) {
                    if settings.showRatingBadges, let match = model.reco.match(for: item) {
                        MatchBubble(value: match).padding(5)
                    }
                }
                .overlay(alignment: .topTrailing) { indicator(data).padding(5) }
                .overlay(alignment: .topLeading) {
                    if settings.showFavoriteIndicator && (data?.isFavorite ?? false) {
                        GlassIcon(symbol: "heart.fill", tint: Theme.pinkGlass.opacity(0.6)).padding(5)
                    }
                }
                .overlay(alignment: .bottom) { progressBar(data) }
                .zoomSource(id: item.id, in: zoom)
            if showTitle && settings.showPosterLabels {
                Text(item.kind == .episode ? (item.seriesName ?? item.displayName) : item.displayName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(width: width, alignment: .leading)
                Text(item.kind == .episode ? (item.episodeLabel ?? "") : item.productionYear.map(String.init) ?? " ")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(.primary)
        .contentShape(Rectangle())
        .itemActions(item)
    }

    @ViewBuilder
    private func indicator(_ data: UserItemData?) -> some View {
        let s = model.settings
        if s.showPlayedIndicator && (data?.played ?? false) {
            GlassIcon(symbol: "checkmark", tint: Theme.accent.opacity(0.55))
        } else if s.showUnplayedIndicator, item.kind == .series || item.kind == .season,
                  let n = data?.unplayedItemCount, n > 0 {
            GlassLabel(text: "\(n)")
        }
    }

    @ViewBuilder
    private func progressBar(_ data: UserItemData?) -> some View {
        if model.settings.showProgressIndicator, let p = data?.playedPercentage, p > 0, p < 100, !(data?.played ?? false) {
            ProgressBar(value: p / 100).padding(.horizontal, 8).padding(.bottom, 7)
        }
    }
}

struct ProgressBar: View {
    let value: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.3))
                Capsule().fill(Theme.accent).frame(width: max(4, geo.size.width * value))
            }
        }
        .frame(height: 4)
        .shadow(color: .black.opacity(0.4), radius: 2)
    }
}

/// Landscape still (Continue Watching, Next Up, episodes).
struct LandscapeCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.zoomNamespace) private var zoom
    let item: BaseItem
    var width: CGFloat = 240

    var body: some View {
        let data = model.userData(for: item)
        VStack(alignment: .leading, spacing: 6) {
            RemoteImage(url: model.client?.landscapeURL(item, width: Int(width * 3)))
                .frame(width: width, height: width * 9 / 16)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 5) {
                        if let remaining = remainingText(data) {
                            Text(remaining).font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.9))
                        }
                        if let p = data?.playedPercentage, p > 0, p < 100 { ProgressBar(value: p / 100) }
                    }
                    .padding(10)
                }
                .overlay(alignment: .topTrailing) {
                    if data?.played ?? false { GlassIcon(symbol: "checkmark", tint: Theme.accent.opacity(0.55)).padding(6) }
                }
                .overlay(alignment: .topLeading) {
                    if model.settings.showRatingBadges, let m = model.reco.match(for: item) { MatchBubble(value: m).padding(6) }
                }
                .zoomSource(id: item.id, in: zoom)
            Text(item.kind == .episode ? (item.seriesName ?? item.displayName) : item.displayName)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text(secondLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: width, alignment: .leading)
        .foregroundStyle(.primary)
        .contentShape(Rectangle())
        .itemActions(item)
    }

    private var secondLine: String {
        if item.kind == .episode {
            return [item.episodeLabel, item.name].compactMap { $0 }.joined(separator: " · ")
        }
        return item.subtitleLine
    }

    private func remainingText(_ data: UserItemData?) -> String? {
        guard let total = item.runTimeTicks, let pos = data?.playbackPositionTicks, pos > 0 else { return nil }
        let left = Fmt.seconds(max(0, total - pos))
        return "\(Fmt.runtime(left)) left"
    }
}

// MARK: - Shelves

struct Shelf<Destination: View>: View {
    let title: String
    let items: [BaseItem]
    var landscape = false
    var playOnTap = false
    var seeAll: (() -> Destination)? = nil

    @Environment(AppModel.self) private var model

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(title).font(.title3.weight(.bold))
                    Spacer()
                    if let seeAll {
                        NavigationLink { seeAll() } label: {
                            Text("See all").font(.subheadline.weight(.semibold))
                        }
                    }
                }
                .padding(.horizontal)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(items) { item in
                            if playOnTap {
                                Button { model.play(item) } label: { card(item) }
                                    .buttonStyle(PressStyle())
                            } else {
                                NavigationLink(value: ItemLink(item: item)) { card(item) }
                                    .buttonStyle(PressStyle())
                            }
                        }
                    }
                    .padding(.horizontal)
                }
                .scrollClipDisabled()
            }
        }
    }

    @ViewBuilder
    private func card(_ item: BaseItem) -> some View {
        if landscape { LandscapeCard(item: item) } else { PosterCard(item: item) }
    }
}

extension Shelf where Destination == EmptyView {
    init(title: String, items: [BaseItem], landscape: Bool = false, playOnTap: Bool = false) {
        self.title = title
        self.items = items
        self.landscape = landscape
        self.playOnTap = playOnTap
        self.seeAll = nil
    }
}

// MARK: - Long-press menu (every card in the app)

struct ItemActionsMenu: ViewModifier {
    @Environment(AppModel.self) private var model
    let item: BaseItem
    @State private var showMoreLike = false

    func body(content: Content) -> some View {
        content
            .contextMenu {
                if item.kind.isPlayableVideo || item.kind == .series || item.kind == .season {
                    Button("Play", systemImage: "play.fill") { model.play(item) }
                    if (model.userData(for: item)?.playbackPositionTicks ?? 0) > 0 {
                        Button("Play from beginning", systemImage: "arrow.counterclockwise") { model.play(item, from: 0) }
                    }
                }
                Button(model.isPlayed(item) ? "Mark as unwatched" : "Mark as watched",
                       systemImage: model.isPlayed(item) ? "eye.slash" : "checkmark.circle") {
                    Task { await model.togglePlayed(item) }
                }
                Button(model.isFavorite(item) ? "Remove from favourites" : "Add to favourites",
                       systemImage: model.isFavorite(item) ? "heart.slash" : "heart") {
                    Task { await model.toggleFavorite(item) }
                }
                if item.kind == .movie || item.kind == .series {
                    Button("More like this", systemImage: "square.stack.3d.up") { showMoreLike = true }
                    if !model.isPlayed(item) && !model.settings.dismissedPicks.contains(item.id) {
                        Button("Not for me", systemImage: "hand.thumbsdown", role: .destructive) {
                            withAnimation(.snappy) { model.reco.dismiss(item) }
                        }
                    }
                }
            }
            .sheet(isPresented: $showMoreLike) {
                MoreLikeThisSheet(item: item).presentationDetents([.medium, .large])
            }
    }
}

extension View {
    func itemActions(_ item: BaseItem) -> some View { modifier(ItemActionsMenu(item: item)) }
}

/// Titles like this one from your own library, unwatched, best match first.
struct MoreLikeThisSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let item: BaseItem
    @State private var items: [BaseItem]?
    @Namespace private var zoom

    var body: some View {
        NavigationStack {
            Group {
                if let items, items.isEmpty {
                    ContentUnavailableView("Nothing similar yet", systemImage: "square.stack.3d.up.slash",
                                           description: Text("Nothing unwatched in your library is close to \(item.displayName)."))
                } else if let items {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12)], spacing: 16) {
                            ForEach(items) { i in
                                NavigationLink(value: ItemLink(item: i)) { PosterCard(item: i, width: 104) }
                                    .buttonStyle(PressStyle())
                            }
                        }
                        .padding()
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Like \(item.displayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .navigationDestination(for: ItemLink.self) { ItemDetailView(item: $0.item) }
            .navigationDestination(for: PersonLink.self) { PersonView(personId: $0.id, name: $0.name) }
            .navigationDestination(for: GenreLink.self) { GenreItemsView(genre: $0.name, parentId: $0.parentId) }
        }
        .task { items = await model.reco.moreLike(item) }
    }
}

/// Small header used at the top of sections in Settings / Admin.
struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title).font(.title3.weight(.bold)).frame(maxWidth: .infinity, alignment: .leading)
    }
}
