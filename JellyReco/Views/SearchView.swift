import SwiftUI

struct SearchView: View {
    @Environment(AppModel.self) private var model
    @Namespace private var zoom
    @State private var query = ""
    @State private var movies: [BaseItem] = []
    @State private var shows: [BaseItem] = []
    @State private var episodes: [BaseItem] = []
    @State private var people: [BaseItem] = []
    @State private var collections: [BaseItem] = []
    @State private var genres: [BaseItem] = []
    @State private var isSearching = false
    @State private var searchGenre: String?
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    if query.trimmingCharacters(in: .whitespaces).isEmpty {
                        suggestions
                    } else {
                        // AniReco: category filter dropdown on the right.
                        categoryFilter
                        let matching = genres.filter { $0.displayName.localizedCaseInsensitiveContains(query.trimmingCharacters(in: .whitespaces)) }
                        if !matching.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Categories").font(.title3.bold())
                                ForEach(matching.prefix(5)) { g in
                                    NavigationLink(value: GenreLink(name: g.displayName, parentId: nil)) {
                                        Label("Browse \(g.displayName)", systemImage: "square.stack.fill")
                                            .font(.subheadline.weight(.semibold))
                                    }
                                }
                            }
                            .padding(.horizontal)
                        }
                        Shelf(title: "Movies", items: movies)
                        Shelf(title: "Shows", items: shows)
                        Shelf(title: "Episodes", items: episodes, landscape: true)
                        Shelf(title: "Collections", items: collections)
                        if !people.isEmpty { peopleRow }
                        if !isSearching && movies.isEmpty && shows.isEmpty && episodes.isEmpty && people.isEmpty && collections.isEmpty {
                            ContentUnavailableView.search(text: query)
                        }
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("Search")
            .toolbarTitleDisplayMode(.inlineLarge)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Movies, shows, episodes, people")
            .task(id: "\(query)|\(searchGenre ?? "")") {
                let term = query.trimmingCharacters(in: .whitespaces)
                guard !term.isEmpty else { return }
                try? await Task.sleep(nanoseconds: 300_000_000)   // debounce typing
                guard !Task.isCancelled else { return }
                await search(term)
            }
            .task { await loadGenres() }
            .appDestinations(zoom: zoom)
            .environment(\.zoomNamespace, zoom)
        }
    }

    /// AniReco's "Categories" dropdown on the right: picking one opens that genre.
    private var suggestions: some View {
        VStack(spacing: 24) {
            HStack {
                Spacer()
                Menu {
                    ForEach(genres) { g in
                        Button(g.displayName) { path.append(GenreLink(name: g.displayName, parentId: nil)) }
                    }
                } label: {
                    DropdownLabel(text: "Categories", symbol: "line.3.horizontal.decrease")
                }
                .menuStyle(.button)
                .buttonStyle(.glass)
                .disabled(genres.isEmpty)
            }
            .padding(.horizontal, 16)
            ContentUnavailableView("Search your server", systemImage: "magnifyingglass",
                                   description: Text("Movies, shows, episodes, collections and people. Pick a category to browse it."))
        }
    }

    /// Search results filtered to one category ("Any category" = everything).
    private var categoryFilter: some View {
        HStack {
            Spacer()
            Menu {
                Button { searchGenre = nil } label: {
                    if searchGenre == nil { Label("Any category", systemImage: "checkmark") } else { Text("Any category") }
                }
                Divider()
                ForEach(genres) { g in
                    Button { searchGenre = g.displayName } label: {
                        if searchGenre == g.displayName { Label(g.displayName, systemImage: "checkmark") } else { Text(g.displayName) }
                    }
                }
            } label: {
                DropdownLabel(text: searchGenre ?? "Any category", symbol: "line.3.horizontal.decrease")
            }
            .menuStyle(.button)
            .buttonStyle(.glass)
        }
        .padding(.horizontal, 16)
    }

    private var peopleRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("People").font(.title3.bold()).padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(people) { p in
                        NavigationLink(value: PersonLink(id: p.id, name: p.displayName)) {
                            VStack(spacing: 4) {
                                RemoteImage(url: model.client?.imageURL(itemId: p.id, tag: p.primaryTag, maxWidth: 240),
                                            placeholderSymbol: "person.fill")
                                    .frame(width: 76, height: 76).clipShape(Circle())
                                Text(p.displayName).font(.caption.weight(.semibold)).lineLimit(2).multilineTextAlignment(.center)
                            }
                            .frame(width: 86)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private func search(_ term: String) async {
        guard let client = model.client else { return }
        isSearching = true
        defer { isSearching = false }
        let g = searchGenre
        async let m = client.search(term, types: [.movie], genre: g)
        async let s = client.search(term, types: [.series], genre: g)
        async let e = client.search(term, types: [.episode], limit: 30, genre: g)
        async let c = client.search(term, types: [.boxSet], limit: 20, genre: g)
        async let p = client.searchPeople(term)
        movies = (try? await m) ?? []
        shows = (try? await s) ?? []
        episodes = (try? await e) ?? []
        collections = (try? await c) ?? []
        people = (try? await p) ?? []
    }

    private func loadGenres() async {
        guard genres.isEmpty, let client = model.client else { return }
        genres = (try? await client.genres(parentId: nil, types: [.movie, .series])) ?? []
    }
}

// MARK: - Live TV

struct LiveTVView: View {
    @Environment(AppModel.self) private var model
    @State private var channels: [BaseItem] = []
    @State private var programs: [String: [BaseItem]] = [:]
    @State private var loaded = false

    var body: some View {
        List {
            ForEach(channels) { ch in
                Button { model.play(ch, from: 0) } label: {
                    HStack(spacing: 12) {
                        RemoteImage(url: model.client?.imageURL(itemId: ch.id, tag: ch.primaryTag, maxWidth: 200),
                                    contentMode: .fit, placeholderSymbol: "tv")
                            .frame(width: 64, height: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(ch.channelNumber.map { "\($0) · " } ?? "")\(ch.displayName)").font(.subheadline.weight(.semibold))
                            if let now = ch.currentProgram?.name { Text("Now: \(now)").font(.caption).foregroundStyle(.secondary) }
                            if let next = programs[ch.id]?.dropFirst().first {
                                Text("Next: \(next.displayName) · \(next.startDate?.formatted(date: .omitted, time: .shortened) ?? "")")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                        if model.isFavorite(ch) { Image(systemName: "heart.fill").foregroundStyle(Theme.pink) }
                    }
                }
                .foregroundStyle(.primary)
                .swipeActions {
                    Button { Task { await model.toggleFavorite(ch) } } label: { Label("Favourite", systemImage: "heart") }
                        .tint(Theme.pink)
                }
            }
        }
        .overlay {
            if loaded && channels.isEmpty { ContentUnavailableView("No channels", systemImage: "tv") }
            else if !loaded { ProgressView() }
        }
        .navigationTitle("Live TV")
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        guard let client = model.client else { return }
        channels = (try? await client.liveChannels()) ?? []
        let list = (try? await client.programs(channelIds: channels.prefix(80).map(\.id), hours: 6)) ?? []
        programs = Dictionary(grouping: list, by: { $0.channelId ?? "" })
        loaded = true
    }
}
