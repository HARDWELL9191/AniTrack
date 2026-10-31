import SwiftUI
import UIKit

// MARK: - All libraries

struct LibrariesView: View {
    @Environment(AppModel.self) private var model
    @Namespace private var zoom

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                    ForEach(model.libraries) { lib in
                        NavigationLink(value: LibraryLink(library: lib)) {
                            LibraryTile(library: lib)
                        }
                        .buttonStyle(PressStyle())
                    }
                    NavigationLink(value: ScreenLink.myList) {
                        SymbolTile(title: "My List", symbol: "bookmark.fill", tint: Theme.accent)
                    }
                    .buttonStyle(PressStyle())
                    NavigationLink(value: ScreenLink.notForMe) {
                        SymbolTile(title: "Not for me", symbol: "hand.thumbsdown.fill", tint: .gray)
                    }
                    .buttonStyle(PressStyle())
                    NavigationLink(value: ScreenLink.favorites) {
                        SymbolTile(title: "Favourites", symbol: "heart.fill", tint: Theme.pink)
                    }
                    .buttonStyle(PressStyle())
                    NavigationLink(value: ScreenLink.collections) {
                        SymbolTile(title: "Collections", symbol: "square.stack.fill", tint: .purple)
                    }
                    .buttonStyle(PressStyle())
                }
                .padding()
            }
            .navigationTitle("Library")
            .toolbarTitleDisplayMode(.inlineLarge)
            .refreshable { await model.refreshSession() }
            .appDestinations(zoom: zoom)
            .environment(\.zoomNamespace, zoom)
        }
    }
}

struct LibraryTile: View {
    @Environment(AppModel.self) private var model
    let library: BaseItem
    var body: some View {
        RemoteImage(url: model.client?.imageURL(itemId: library.id, tag: library.primaryTag, maxWidth: 600),
                    placeholderSymbol: "rectangle.stack")
            .frame(height: 100)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(alignment: .bottomLeading) {
                Text(library.displayName)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .glassEffect(.regular.tint(.black.opacity(0.35)), in: .capsule)
                    .padding(8)
            }
    }
}

struct SymbolTile: View {
    let title: String
    let symbol: String
    let tint: Color
    var body: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(LinearGradient(colors: [tint.opacity(0.55), tint.opacity(0.2)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(height: 100)
            .overlay {
                Image(systemName: symbol).font(.system(size: 34, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
            }
            .overlay(alignment: .bottomLeading) {
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .glassEffect(.regular.tint(.black.opacity(0.35)), in: .capsule)
                    .padding(8)
            }
    }
}

// MARK: - One library (grid / list, sort, filters, A–Z, random)

enum LibrarySort: String, CaseIterable, Identifiable {
    case name, dateAdded, premiere, rating, criticRating, runtime, datePlayed, playCount, random
    var id: String { rawValue }
    var label: String {
        switch self {
        case .name: return "Name"
        case .dateAdded: return "Date added"
        case .premiere: return "Release date"
        case .rating: return "Community rating"
        case .criticRating: return "Critic rating"
        case .runtime: return "Runtime"
        case .datePlayed: return "Date played"
        case .playCount: return "Play count"
        case .random: return "Random"
        }
    }
    var fields: [String] {
        switch self {
        case .name: return ["SortName"]
        case .dateAdded: return ["DateCreated", "SortName"]
        case .premiere: return ["PremiereDate", "ProductionYear", "SortName"]
        case .rating: return ["CommunityRating", "SortName"]
        case .criticRating: return ["CriticRating", "SortName"]
        case .runtime: return ["Runtime", "SortName"]
        case .datePlayed: return ["DatePlayed", "SortName"]
        case .playCount: return ["PlayCount", "SortName"]
        case .random: return ["Random"]
        }
    }
    var defaultDescending: Bool { self != .name }
}

struct LibraryFilters: Equatable {
    var watched: Watched = .all
    var favoritesOnly = false
    var genres: Set<String> = []
    var years: Set<Int> = []
    var ratings: Set<String> = []
    var tags: Set<String> = []

    enum Watched: String, CaseIterable, Identifiable {
        case all, unwatched, watched, inProgress
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return "All"
            case .unwatched: return "Unwatched"
            case .watched: return "Watched"
            case .inProgress: return "In progress"
            }
        }
    }

    var isActive: Bool { self != LibraryFilters() }
}

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    let library: BaseItem
    var initialSort: LibrarySort = .name
    /// Restricts to certain types (e.g. boxsets of a library).
    var itemTypes: [ItemKind]? = nil

    @State private var items: [BaseItem] = []
    @State private var total = 0
    @State private var isLoading = false
    @State private var sort: LibrarySort = .name
    @State private var descending = false
    @State private var filters = LibraryFilters()
    @State private var available = QueryFiltersLegacy()
    @State private var showFilters = false
    @State private var jumpTask: Task<Void, Never>?
    @State private var didInit = false
    @State private var generation = 0

    private var layout: LibraryLayout { model.settings.layout(for: library.id) }

    private var types: [ItemKind] {
        if let itemTypes { return itemTypes }
        switch library.collectionType {
        case "movies": return [.movie]
        case "tvshows": return [.series]
        case "boxsets": return [.boxSet]
        case "musicvideos": return [.musicVideo]
        case "homevideos": return [.video, .photo]
        case "music": return [.musicAlbum]
        default: return [.movie, .series, .video, .boxSet]
        }
    }

    private var showsScrubber: Bool { model.settings.showLetterPicker && sort == .name && !items.isEmpty }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            Group {
                if layout == .grid { grid } else { listLayout }
            }
            .frame(maxWidth: .infinity)
            .padding(.trailing, showsScrubber ? 22 : 0)
            if isLoading && items.isEmpty {
                ProgressView().padding(40)
            } else if !isLoading && items.isEmpty {
                ContentUnavailableView(filters.isActive ? "No matches" : "Empty library",
                                       systemImage: "rectangle.stack",
                                       description: Text(filters.isActive ? "Try removing some filters." : ""))
            }
        }
        // Pinned to the screen (never scrolls away), like the index in Contacts.
        .overlay(alignment: .trailing) {
            if showsScrubber {
                AlphabetScrubber { letter in jump(to: letter, proxy: proxy) }
                    .padding(.trailing, 2)
            }
        }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
        .navigationTitle(library.displayName)
        .toolbar { toolbar }
        .refreshable { await reload() }
        .task {
            guard !didInit else { return }
            didInit = true
            sort = initialSort
            descending = initialSort.defaultDescending
            await reload()
            if let client = model.client {
                available = (try? await client.filters(parentId: library.id, types: types)) ?? QueryFiltersLegacy()
            }
        }
        .onChange(of: sort) { _, new in descending = new.defaultDescending; Task { await reload() } }
        .onChange(of: descending) { _, _ in Task { await reload() } }
        .onChange(of: filters) { _, _ in Task { await reload() } }
        .sheet(isPresented: $showFilters) {
            FilterSheet(filters: $filters, available: available).presentationDetents([.medium, .large])
        }
    }

    private var columns: [GridItem] {
        let n = max(2, min(6, model.settings.gridColumns))
        return Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: model.settings.libraryPosterStyle == .landscape ? max(1, n - 1) : n)
    }

    @State private var gridWidth: CGFloat = 360

    /// Card width from the screen width (fixed sizes inside the links; no layout readers in them).
    private var cardWidth: CGFloat {
        let n = CGFloat(columns.count)
        let letters: CGFloat = model.settings.showLetterPicker && sort == .name ? 24 : 0
        return max(80, (gridWidth - 32 - letters - 12 * (n - 1)) / n)
    }

    private var grid: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
            ForEach(items) { item in
                NavigationLink(value: ItemLink(item: item)) {
                    if model.settings.libraryPosterStyle == .landscape {
                        LandscapeCard(item: item, width: cardWidth)
                    } else {
                        PosterCard(item: item, width: cardWidth)
                    }
                }
                .buttonStyle(PressStyle())
                .onAppear { loadMoreIfNeeded(item) }
            }
        }
        .padding(.horizontal)
    }

    private var listLayout: some View {
        LazyVStack(spacing: 10) {
            ForEach(items) { item in
                NavigationLink(value: ItemLink(item: item)) { ItemRow(item: item) }
                    .buttonStyle(PressStyle())
                    .onAppear { loadMoreIfNeeded(item) }
            }
        }
        .padding(.horizontal)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if model.settings.showRandomButton {
                Button("Random", systemImage: "dice") { Task { await playRandom() } }
            }
            Button("Filters", systemImage: filters.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle") {
                showFilters = true
            }
            Menu {
                Picker("Sort by", selection: $sort) {
                    ForEach(LibrarySort.allCases) { Text($0.label).tag($0) }
                }
                Picker("Order", selection: $descending) {
                    Label("Ascending", systemImage: "arrow.up").tag(false)
                    Label("Descending", systemImage: "arrow.down").tag(true)
                }
                Divider()
                Picker("Layout", selection: Binding(get: { layout }, set: { model.settings.setLayout($0, for: library.id) })) {
                    Label("Grid", systemImage: "square.grid.3x3").tag(LibraryLayout.grid)
                    Label("List", systemImage: "list.bullet").tag(LibraryLayout.list)
                }
                @Bindable var s = model.settings
                Picker("Posters", selection: $s.libraryPosterStyle) {
                    ForEach(PosterStyle.allCases) { Text($0.label).tag($0) }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down.circle")
            }
        }
    }

    private func query(start: Int) -> JellyfinClient.ItemQuery {
        var q = JellyfinClient.ItemQuery()
        q.parentId = library.id
        q.includeItemTypes = types
        q.recursive = true
        q.sortBy = sort.fields
        q.sortOrder = descending ? "Descending" : "Ascending"
        q.startIndex = start
        q.limit = 100
        switch filters.watched {
        case .all: break
        case .unwatched: q.filters.append("IsUnplayed")
        case .watched: q.filters.append("IsPlayed")
        case .inProgress: q.filters.append("IsResumable")
        }
        if filters.favoritesOnly { q.filters.append("IsFavorite") }
        q.genres = Array(filters.genres)
        q.years = Array(filters.years)
        q.officialRatings = Array(filters.ratings)
        q.tags = Array(filters.tags)
        return q
    }

    private func reload() async {
        guard let client = model.client else { return }
        generation &+= 1
        let gen = generation
        isLoading = true
        defer { if gen == generation { isLoading = false } }
        do {
            let page = try await client.items(query(start: 0))
            guard gen == generation else { return }
            items = page.items ?? []
            total = page.totalRecordCount ?? items.count
        } catch {
            model.report(error)
        }
    }

    /// Scrolls to the first title starting with `letter`. Jellyfin counts the titles sorted
    /// before it (NameLessThan), so this works in libraries of any size; pages up to that
    /// point are loaded first.
    private func jump(to letter: String, proxy: ScrollViewProxy) {
        jumpTask?.cancel()
        jumpTask = Task {
            guard let client = model.client else { return }
            var index = 0
            if letter != "#" {
                var q = query(start: 0)
                q.limit = 1
                if descending {
                    let next = letter == "Z" ? "{" : String(UnicodeScalar(letter.unicodeScalars.first!.value + 1)!)
                    q.nameLessThan = next
                    let before = (try? await client.items(q).totalRecordCount) ?? 0
                    index = max(0, total - before)
                } else {
                    q.nameLessThan = letter
                    index = (try? await client.items(q).totalRecordCount) ?? 0
                }
            } else if descending {
                var q = query(start: 0)
                q.limit = 1
                q.nameLessThan = "A"
                index = max(0, total - ((try? await client.items(q).totalRecordCount) ?? 0))
            }
            guard !Task.isCancelled else { return }
            let gen = generation
            while items.count <= index, items.count < total, !Task.isCancelled, gen == generation {
                guard let page = try? await client.items(query(start: items.count)), gen == generation else { break }
                let known = Set(items.map(\.id))
                let fresh = (page.items ?? []).filter { !known.contains($0.id) }
                if fresh.isEmpty { break }
                items += fresh
            }
            guard !Task.isCancelled, !items.isEmpty else { return }
            let target = items[min(index, items.count - 1)].id
            withAnimation(.snappy(duration: 0.2)) { proxy.scrollTo(target, anchor: .top) }
        }
    }

    private func loadMoreIfNeeded(_ item: BaseItem) {
        guard !isLoading, items.count < total, let idx = items.firstIndex(where: { $0.id == item.id }),
              idx >= items.count - 20, let client = model.client else { return }
        isLoading = true
        let gen = generation
        Task {
            defer { isLoading = false }
            if let page = try? await client.items(query(start: items.count)), gen == generation {
                let known = Set(items.map(\.id))
                items += (page.items ?? []).filter { !known.contains($0.id) }
            }
        }
    }

    private func playRandom() async {
        guard let client = model.client else { return }
        var q = query(start: 0)
        q.sortBy = ["Random"]
        q.limit = 1
        if let item = try? await client.items(q).items?.first { model.play(item) }
    }
}

struct ItemRow: View {
    @Environment(AppModel.self) private var model
    let item: BaseItem
    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(url: model.client?.posterURL(item, width: 200))
                .frame(width: 58, height: 87)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayName).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text(item.subtitleLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 10) {
                    RatingLabel(item: item)
                    if let m = model.reco.match(for: item) {
                        HStack(spacing: 5) {
                            Image(systemName: "wand.and.stars").font(.caption.weight(.semibold)).foregroundStyle(Theme.pink)
                            MatchBubble(value: m)
                        }
                    }
                    if model.isPlayed(item) { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent) }
                    if model.isFavorite(item) { Image(systemName: "heart.fill").foregroundStyle(Theme.pink) }
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .foregroundStyle(.primary)
        .contentShape(Rectangle())
        .itemActions(item)
    }
}

/// The A–Z index on the right edge: drag through it (or tap) to jump; a haptic tick and a
/// big letter show where you are.
struct AlphabetScrubber: View {
    let onSelect: (String) -> Void
    private let letters = ["#"] + (65...90).map { String(UnicodeScalar($0)!) }
    @State private var active: String?
    @State private var feedback = UISelectionFeedbackGenerator()

    var body: some View {
        GeometryReader { geo in
            let rowHeight = min(17, max(9, (geo.size.height - 24) / CGFloat(letters.count)))
            VStack(spacing: 0) {
                ForEach(letters, id: \.self) { l in
                    Text(l)
                        .font(.system(size: min(11, rowHeight - 2), weight: active == l ? .heavy : .semibold))
                        .foregroundStyle(active == l ? Color.white : Theme.accent)
                        .frame(width: 20, height: rowHeight)
                        .background { if active == l { Circle().fill(Theme.accent) } }
                }
            }
            .padding(.vertical, 6)
            .glassEffect(.regular, in: .capsule)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let i = Int(((g.location.y - 6) / rowHeight).rounded(.down))
                        let l = letters[min(max(i, 0), letters.count - 1)]
                        if l != active {
                            active = l
                            feedback.selectionChanged()
                            onSelect(l)
                        }
                    }
                    .onEnded { _ in withAnimation(.easeOut(duration: 0.3)) { active = nil } }
            )
            .overlay(alignment: .leading) {
                if let active {
                    Text(active)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(width: 64, height: 64)
                        .glassEffect(.regular.tint(Theme.accent.opacity(0.6)), in: .circle)
                        .offset(x: -76)
                        .transition(.scale.combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(width: 22)
        .padding(.vertical, 12)
    }
}

struct FilterSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var filters: LibraryFilters
    let available: QueryFiltersLegacy

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Show", selection: $filters.watched) {
                        ForEach(LibraryFilters.Watched.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Favourites only", isOn: $filters.favoritesOnly)
                }
                multiSection("Genres", values: available.genres ?? [], selection: $filters.genres)
                if let years = available.years, !years.isEmpty {
                    Section("Years") {
                        FlowLayout {
                            ForEach(years.sorted(by: >), id: \.self) { y in
                                toggleChip("\(y)", on: filters.years.contains(y)) {
                                    if filters.years.contains(y) { filters.years.remove(y) } else { filters.years.insert(y) }
                                }
                            }
                        }
                    }
                }
                multiSection("Age ratings", values: available.officialRatings ?? [], selection: $filters.ratings)
                multiSection("Tags", values: Array((available.tags ?? []).prefix(80)), selection: $filters.tags)
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset") { filters = LibraryFilters() }.disabled(!filters.isActive)
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    @ViewBuilder
    private func multiSection(_ title: String, values: [String], selection: Binding<Set<String>>) -> some View {
        if !values.isEmpty {
            Section(title) {
                FlowLayout {
                    ForEach(values, id: \.self) { v in
                        toggleChip(v, on: selection.wrappedValue.contains(v)) {
                            if selection.wrappedValue.contains(v) { selection.wrappedValue.remove(v) } else { selection.wrappedValue.insert(v) }
                        }
                    }
                }
            }
        }
    }

    private func toggleChip(_ text: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(on ? Theme.accent : Color.secondary.opacity(0.15), in: Capsule())
                .foregroundStyle(on ? .white : .primary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Genre, favourites, collections

struct GenreItemsView: View {
    @Environment(AppModel.self) private var model
    let genre: String
    let parentId: String?
    @State private var items: [BaseItem] = []

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12)], spacing: 16) {
                ForEach(items) { item in
                    NavigationLink(value: ItemLink(item: item)) { PosterCard(item: item, width: 104) }
                        .buttonStyle(PressStyle())
                }
            }
            .padding()
        }
        .navigationTitle(genre)
        .task {
            guard let client = model.client else { return }
            var q = JellyfinClient.ItemQuery()
            q.parentId = parentId
            q.genres = [genre]
            q.includeItemTypes = [.movie, .series]
            q.sortBy = ["CommunityRating", "SortName"]
            q.sortOrder = "Descending"
            q.limit = 300
            items = (try? await client.items(q).items) ?? []
        }
    }
}

struct FavoritesView: View {
    @Environment(AppModel.self) private var model
    @State private var groups: [LatestShelf] = []

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                ForEach(groups) { group in
                    Shelf(title: group.library.displayName, items: group.items,
                          landscape: group.library.id == "fav-Episodes")
                }
                if groups.isEmpty {
                    ContentUnavailableView("No favourites", systemImage: "heart",
                                           description: Text("Long-press anything and choose Add to favourites."))
                }
            }
            .padding(.vertical)
        }
        .navigationTitle("Favourites")
        .task(id: model.contentVersion) {
            guard let client = model.client else { return }
            var out: [LatestShelf] = []
            for (title, kind) in [("Movies", ItemKind.movie), ("Shows", .series), ("Episodes", .episode),
                                  ("Collections", .boxSet), ("People", .person)] {
                var q = JellyfinClient.ItemQuery()
                q.filters = ["IsFavorite"]
                q.includeItemTypes = [kind]
                q.limit = 100
                let items = (try? await client.items(q).items) ?? []
                if !items.isEmpty {
                    out.append(LatestShelf(library: BaseItem(id: "fav-\(title)", name: title), items: items))
                }
            }
            groups = out
        }
    }
}

struct CollectionsBrowser: View {
    @Environment(AppModel.self) private var model
    @State private var items: [BaseItem] = []

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12)], spacing: 16) {
                ForEach(items) { item in
                    NavigationLink(value: ItemLink(item: item)) { PosterCard(item: item, width: 104) }
                        .buttonStyle(PressStyle())
                }
            }
            .padding()
        }
        .overlay { if items.isEmpty { ContentUnavailableView("No collections", systemImage: "square.stack") } }
        .navigationTitle("Collections")
        .task {
            guard let client = model.client else { return }
            var q = JellyfinClient.ItemQuery()
            q.includeItemTypes = [.boxSet]
            q.limit = 500
            items = (try? await client.items(q).items) ?? []
        }
    }
}

/// Folder-style libraries (Jellyfin "folders", mixed content, home videos): browsed as folders,
/// the way Jellyfin shows them, with files playable straight from the list.
struct FolderBrowserView: View {
    @Environment(AppModel.self) private var model
    let folder: BaseItem
    @State private var children: [BaseItem] = []
    @State private var loaded = false
    @State private var search = ""

    static func isFolderLibrary(_ lib: BaseItem) -> Bool {
        let type = lib.collectionType ?? ""
        return type.isEmpty || ["folders", "mixed", "homevideos"].contains(type)
    }

    private var shown: [BaseItem] {
        guard !search.isEmpty else { return children }
        return children.filter { $0.displayName.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        List {
            ForEach(shown) { item in
                if item.isFolder == true && !(item.kind == .series || item.kind == .season || item.kind == .boxSet) {
                    NavigationLink(value: LibraryLink(library: item)) { FolderRow(item: item) }
                } else if item.kind.isPlayableVideo {
                    FileRow(item: item)
                } else {
                    NavigationLink(value: ItemLink(item: item)) { FileRow(item: item, showsPlay: false) }
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if !loaded { ProgressView() }
            else if children.isEmpty { ContentUnavailableView("Empty folder", systemImage: "folder") }
        }
        .navigationTitle(folder.displayName)
        .searchable(text: $search, prompt: "Filter this folder")
        .refreshable { await load() }
        .task { if !loaded { await load() } }
    }

    private func load() async {
        guard let client = model.client else { return }
        var q = JellyfinClient.ItemQuery()
        q.parentId = folder.id
        q.recursive = false
        q.sortBy = ["SortName"]
        q.limit = 2000
        q.isMissing = nil
        q.fields = JellyfinClient.listFields + ["Path", "MediaSources"]
        let items = (try? await client.items(q).items) ?? []
        // Folders first, then files, each by name (like a file browser).
        children = items.sorted { a, b in
            let fa = a.isFolder == true, fb = b.isFolder == true
            if fa != fb { return fa }
            return a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
        }
        loaded = true
    }
}

private struct FolderRow: View {
    @Environment(AppModel.self) private var model
    let item: BaseItem
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .font(.title3)
                .foregroundStyle(Theme.accent)
                .frame(width: 44, height: 44)
                .glassEffect(.regular.tint(Theme.accent.opacity(0.15)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName).font(.subheadline.weight(.semibold)).lineLimit(2)
                if let n = item.childCount ?? item.recursiveItemCount {
                    Text(n == 1 ? "1 item" : "\(n) items").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// A video file in a folder: tap to play (long-press for watched, favourite, details…).
private struct FileRow: View {
    @Environment(AppModel.self) private var model
    let item: BaseItem
    var showsPlay = true

    var body: some View {
        let data = model.userData(for: item)
        Button {
            if showsPlay { model.play(item) }
        } label: {
            HStack(spacing: 12) {
                RemoteImage(url: model.client?.landscapeURL(item, width: 300), placeholderSymbol: "film")
                    .frame(width: 96, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(alignment: .bottom) {
                        if let p = data?.playedPercentage, p > 0, p < 100 { ProgressBar(value: p / 100).padding(4) }
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayName).font(.subheadline.weight(.semibold)).lineLimit(2)
                    Text([item.runtimeSeconds.map(Fmt.runtime), item.container?.uppercased()].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if data?.played ?? false { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent) }
                if showsPlay { Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(Theme.accent) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .itemActions(item)
    }
}
