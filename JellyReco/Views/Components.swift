import SwiftUI
import UIKit

enum Theme {
    /// The accent: the app icon's purple (#8E3EA8) in light mode; in dark mode Jellyfin's own logo
    /// purple (#AA5CC3), the same hue a little lighter so text and icons stay readable on black.
    static let accent = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0xAA / 255, green: 0x5C / 255, blue: 0xC3 / 255, alpha: 1)
        : UIColor(red: 0x8E / 255, green: 0x3E / 255, blue: 0xA8 / 255, alpha: 1) })
    static let pink = Color(red: 0.98, green: 0.45, blue: 0.62)
    /// Match % glass tint (AniReco's darker pink).
    static let pinkGlass = Color(red: 0.86, green: 0.33, blue: 0.50)
    /// The app icon's gradient: purple #8E3EA8 → blue #0083B0.
    static let brandPurple = Color(red: 0x8E / 255, green: 0x3E / 255, blue: 0xA8 / 255)
    static let brandBlue = Color(red: 0x00 / 255, green: 0x83 / 255, blue: 0xB0 / 255)
}

// MARK: - Navigation

/// Where a tap on an item goes.
struct ItemLink: Hashable {
    let item: BaseItem
}

struct LibraryLink: Hashable {
    let library: BaseItem
    var sort: LibrarySort = .name
}

/// Screens reached from the Library tab (all navigation uses values: mixing push styles in one
/// stack makes iOS pop new pages straight back).
enum ScreenLink: Hashable {
    case favorites, collections, myList, notForMe, liveTV
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
    /// Opens an item's page on the current tab's stack (nil where there's no such stack).
    @Entry var openDetails: ((BaseItem) -> Void)? = nil
}

extension View {
    @ViewBuilder
    func zoomSource(id: String, in namespace: Namespace.ID?) -> some View {
        if let namespace { matchedTransitionSource(id: id, in: namespace) } else { self }
    }

    /// Every tab's NavigationStack gets the same destinations (with the cover → page zoom), and
    /// the long-press menu's "Details" / "Go to show" push onto that tab's stack.
    func appDestinations(zoom: Namespace.ID, path: Binding<NavigationPath>) -> some View {
        let open: (BaseItem) -> Void = { path.wrappedValue.append(ItemLink(item: $0)) }
        return self
            .environment(\.openDetails, open)
            .navigationDestination(for: ItemLink.self) { link in
                ItemDetailView(item: link.item)
                    .navigationTransition(.zoom(sourceID: link.item.id, in: zoom))
                    .environment(\.openDetails, open)
            }
            .navigationDestination(for: LibraryLink.self) { link in
                Group {
                    if link.library.collectionType == "livetv" {
                        LiveTVView()
                    } else if FolderBrowserView.isFolderLibrary(link.library) {
                        FolderBrowserView(folder: link.library)
                    } else {
                        LibraryView(library: link.library, initialSort: link.sort)
                    }
                }
                .environment(\.openDetails, open)
            }
            .navigationDestination(for: ScreenLink.self) { screen in
                Group {
                    switch screen {
                    case .favorites: FavoritesView()
                    case .collections: CollectionsBrowser()
                    case .myList: MyListView()
                    case .notForMe: NotForMeView()
                    case .liveTV: LiveTVView()
                    }
                }
                .environment(\.openDetails, open)
            }
            .navigationDestination(for: PersonLink.self) { PersonView(personId: $0.id, name: $0.name).environment(\.openDetails, open) }
            .navigationDestination(for: GenreLink.self) { GenreItemsView(genre: $0.name, parentId: $0.parentId).environment(\.openDetails, open) }
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
            widest = max(widest, x + size.width)   // without the spacing after the last chip
            x += size.width + spacing
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
                    HStack(spacing: 4) {
                        // The age bubble (AniReco's PG / 13+ / 17+ / 18+) from Jellyfin's rating.
                        if let age = item.officialRating.flatMap(TMDBCertification.bucket) { GlassLabel(text: age) }
                        if settings.showFavoriteIndicator && (data?.isFavorite ?? false) {
                            GlassIcon(symbol: "heart.fill", tint: Theme.pinkGlass.opacity(0.6))
                        }
                    }
                    .padding(5)
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
                Capsule().fill(Theme.accent)
                    .frame(width: max(4, geo.size.width * value))
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

struct Shelf: View {
    let title: String
    let items: [BaseItem]
    var landscape = false
    var playOnTap = false
    var seeAll: LibraryLink? = nil

    @Environment(AppModel.self) private var model

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(title).font(.title3.weight(.bold))
                    Spacer()
                    if let seeAll {
                        NavigationLink(value: seeAll) {
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

// MARK: - Long-press menu (every card in the app)

struct ItemActionsMenu: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.openDetails) private var openDetails
    let item: BaseItem

    func body(content: Content) -> some View {
        content
            .cardContextMenu {
                if item.kind.isPlayableVideo || item.kind == .series || item.kind == .season {
                    Button("Play", systemImage: "play.fill") { model.play(item) }
                    if (model.userData(for: item)?.playbackPositionTicks ?? 0) > 0 {
                        Button("Play from beginning", systemImage: "arrow.counterclockwise") { model.play(item, from: 0) }
                    }
                }
                if let openDetails {
                    // An episode or season card: straight to its show's page.
                    if [.episode, .season].contains(item.kind), let seriesId = item.seriesId {
                        Button("Go to show", systemImage: "tv") {
                            Task {
                                if let show = try? await model.client?.item(seriesId) { openDetails(show) }
                            }
                        }
                    }
                    Button("Details", systemImage: "info.circle") { openDetails(item) }
                }
                Button(model.isPlayed(item) ? "Mark as unwatched" : "Mark as watched",
                       systemImage: model.isPlayed(item) ? "eye.slash" : "checkmark.circle") {
                    Task { await model.togglePlayed(item) }
                }
                Button(model.isFavorite(item) ? "Remove from favourites" : "Add to favourites",
                       systemImage: model.isFavorite(item) ? "heart.slash" : "heart") {
                    Task { await model.toggleFavorite(item) }
                }
                if [.movie, .series, .season, .episode, .video].contains(item.kind) {
                    Button(model.isOnMyList(item) ? "Remove from My List" : "Add to My List",
                           systemImage: model.isOnMyList(item) ? "bookmark.slash" : "bookmark") {
                        Task { await model.toggleMyList(item) }
                    }
                }
                if item.kind == .movie || item.kind == .series {
                    Button("More like this", systemImage: "square.stack.3d.up") { model.moreLikeItem = item }
                }
            }
    }
}

extension View {
    func itemActions(_ item: BaseItem) -> some View { modifier(ItemActionsMenu(item: item)) }

    /// A long-press menu for a card. When iOS lifts the card it cuts it to rounded corners at
    /// its exact edge, which shaved off text sitting in a corner (the "S" of "S1E4"). The lifted
    /// preview gets a margin around the card instead; the card's layout doesn't change.
    func cardContextMenu<Menu: View>(margin: CGFloat = 10, @ViewBuilder _ menu: @escaping () -> Menu) -> some View {
        self
            .padding(margin)
            .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 20, style: .continuous))
            .contextMenu { menu() }
            .padding(-margin)
    }
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

// MARK: - Selectable text

/// Text that can be selected like in Notes or Safari: double-tap selects a word, press and hold
/// selects too, the handles drag the selection, and the menu offers Copy, Look Up, Translate and
/// Share (SwiftUI's own Text only copies the whole text). Sizes itself like a Text with a line limit.
/// An optional single tap action (expand / collapse) runs only when the tap isn't part of a
/// double tap.
struct SelectableText: UIViewRepresentable {
    let text: String
    var style: UIFont.TextStyle = .body
    var weight: UIFont.Weight = .regular
    var italic = false
    var color: UIColor = .label
    var lineLimit: Int? = nil
    var onTap: (() -> Void)? = nil

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = true
        view.dataDetectorTypes = []
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultHigh, for: .vertical)

        let coordinator = context.coordinator
        view.delegate = coordinator
        coordinator.textView = view
        // A double tap selects a word (the text view's own); a single tap waits for it to fail.
        let double = UITapGestureRecognizer(target: nil, action: nil)
        double.numberOfTapsRequired = 2
        double.cancelsTouchesInView = false
        double.delegate = coordinator
        let single = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.tapped))
        single.require(toFail: double)
        single.cancelsTouchesInView = false
        single.delegate = coordinator
        view.addGestureRecognizer(double)
        view.addGestureRecognizer(single)
        coordinator.single = single
        // A tap on the text while something is selected only clears the selection, at once and
        // without the text view's own tap handling (which flashed the menu somewhere else first).
        let clear = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.clearSelection))
        clear.delegate = coordinator
        view.addGestureRecognizer(clear)
        coordinator.clearTap = clear
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onTap = onTap
        coordinator.single?.isEnabled = onTap != nil
        let font = coordinator.font(style: style, weight: weight, italic: italic,
                                    category: view.traitCollection.preferredContentSizeCategory)
        var changed = false
        if view.font != font { view.font = font; changed = true }
        if view.textColor != color { view.textColor = color }
        if view.text != text { view.text = text; changed = true }
        let lines = lineLimit ?? 0
        if view.textContainer.maximumNumberOfLines != lines {
            view.textContainer.maximumNumberOfLines = lines
            view.textContainer.lineBreakMode = lines == 0 ? .byWordWrapping : .byTruncatingTail
            changed = true
        }
        if changed { view.invalidateIntrinsicContentSize() }
    }

    /// `weight: .regular` keeps the text style's own weight (a headline stays semibold), like
    /// SwiftUI's `.font(.headline)`; another weight is applied at the default text size and then
    /// scaled once for the reader's Dynamic Type size (scaling the already scaled preferred font
    /// made larger sizes grow twice).
    static func makeFont(style: UIFont.TextStyle, weight: UIFont.Weight, italic: Bool) -> UIFont {
        if weight == .regular {
            let font = UIFont.preferredFont(forTextStyle: style)
            guard italic, let slanted = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.traitItalic))
            else { return font }
            return UIFont(descriptor: slanted, size: 0)
        }
        let base = UIFont.preferredFont(forTextStyle: style,
                                        compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)).pointSize
        var font = UIFont.systemFont(ofSize: base, weight: weight)
        if italic, let slanted = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.traitItalic)) {
            font = UIFont(descriptor: slanted, size: base)
        }
        return UIFontMetrics(forTextStyle: style).scaledFont(for: font)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? uiView.window?.windowScene?.screen.bounds.width ?? 390
        guard width.isFinite, width > 0 else { return nil }
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(fitted.height))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleUIView(_ view: UITextView, coordinator: Coordinator) {
        coordinator.removeOutsideTap()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate, UITextViewDelegate {
        var onTap: (() -> Void)?
        weak var single: UITapGestureRecognizer?
        weak var clearTap: UITapGestureRecognizer?
        weak var textView: UITextView?
        /// The tap began while text was selected: it only clears the selection (as in other apps),
        /// it doesn't also expand or collapse the text.
        private var tapClearsSelection = false
        /// While text is selected: a tap anywhere else on the screen clears the selection.
        private var outsideTap: UITapGestureRecognizer?

        /// The font is only rebuilt when its inputs change, not on every update.
        private var fontKey: (style: UIFont.TextStyle, weight: UIFont.Weight, italic: Bool, category: UIContentSizeCategory)?
        private var cachedFont: UIFont?

        func font(style: UIFont.TextStyle, weight: UIFont.Weight, italic: Bool, category: UIContentSizeCategory) -> UIFont {
            if let key = fontKey, let cachedFont, key.style == style, key.weight == weight, key.italic == italic,
               key.category == category {
                return cachedFont
            }
            let font = SelectableText.makeFont(style: style, weight: weight, italic: italic)
            fontKey = (style, weight, italic, category)
            cachedFont = font
            return font
        }

        @objc func tapped() {
            if tapClearsSelection { tapClearsSelection = false; return }
            onTap?()
        }

        // Selection made or cleared: watch for a tap outside the text only while something is selected.
        func textViewDidChangeSelection(_ textView: UITextView) {
            if textView.selectedRange.length > 0 { installOutsideTap(in: textView) } else { removeOutsideTap() }
        }

        private func installOutsideTap(in textView: UITextView) {
            guard outsideTap == nil, let window = textView.window else { return }
            let tap = UITapGestureRecognizer(target: self, action: #selector(tappedOutside))
            tap.cancelsTouchesInView = false
            tap.delegate = self
            window.addGestureRecognizer(tap)
            outsideTap = tap
        }

        func removeOutsideTap() {
            guard let outsideTap else { return }
            outsideTap.view?.removeGestureRecognizer(outsideTap)
            self.outsideTap = nil
        }

        /// Same as a tap on empty space: the Copy menu fades away with its own animation, then the
        /// selection goes.
        @objc func clearSelection() {
            guard let textView else { return }
            for case let menu as UIEditMenuInteraction in textView.interactions { menu.dismissMenu() }
            DispatchQueue.main.async { [weak textView] in
                guard let textView, textView.selectedRange.length > 0 else { return }
                UIView.performWithoutAnimation { textView.selectedTextRange = nil }
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer === clearTap { return (textView?.selectedRange.length ?? 0) > 0 }
            return true
        }

        // The text view's own taps wait for `clearTap` to fail (it only succeeds while text is
        // selected), so a tap that clears the selection never reaches them.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer === clearTap, let textView, other.view === textView,
                  other is UITapGestureRecognizer, other !== single, other !== clearTap else { return false }
            return true
        }

        @objc private func tappedOutside() {
            // After the tap's own action (a button, another text) has run.
            DispatchQueue.main.async { [weak self] in
                guard let textView = self?.textView, textView.selectedRange.length > 0 else { return }
                UIView.performWithoutAnimation { textView.selectedTextRange = nil }
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            if gestureRecognizer === single {
                tapClearsSelection = (textView?.selectedRange.length ?? 0) > 0
                return true
            }
            if gestureRecognizer === outsideTap {
                guard let textView, let touched = touch.view else { return true }
                // Taps in this text (handled by the text view itself) or on the Copy / Look Up menu
                // don't count as "outside".
                var view: UIView? = touched
                while let current = view {
                    if current === textView || NSStringFromClass(type(of: current)).contains("Menu") { return false }
                    view = current.superview
                }
                return true
            }
            return true
        }

        // Alongside the text view's own selection gestures (and anything else), never instead of them.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            if gestureRecognizer === clearTap, other.view === textView { return false }
            return true
        }
    }
}
