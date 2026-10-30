import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Namespace private var zoom
    @State private var path = NavigationPath()

    @State private var resume: [BaseItem] = []
    @State private var nextUp: [BaseItem] = []
    @State private var latest: [LatestShelf] = []
    @State private var loaded = false
    @State private var loadError: String?
    @State private var hero: BaseItem?

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    if let hero { HeroCard(item: hero).padding(.horizontal) }

                    let s = model.settings
                    if s.homeShowContinue && s.homeMergeNextUp {
                        Shelf(title: "Continue Watching", items: merged, landscape: true, playOnTap: true)
                    } else {
                        if s.homeShowContinue { Shelf(title: "Continue Watching", items: resume, landscape: true, playOnTap: true) }
                        if s.homeShowNextUp { Shelf(title: "Next Up", items: nextUp, landscape: true, playOnTap: true) }
                    }

                    if s.homeShowPicks { PicksShelf() }
                    WatchlistShelf()

                    if s.homeShowLatest {
                        ForEach(latest) { entry in
                            Shelf(title: "Recently added in \(entry.library.displayName)", items: entry.items) {
                                LibraryView(library: entry.library, initialSort: .dateAdded)
                            }
                        }
                    }

                    if loaded && resume.isEmpty && nextUp.isEmpty && latest.isEmpty {
                        ContentUnavailableView(loadError == nil ? "Nothing here yet" : "Couldn't load",
                                               systemImage: loadError == nil ? "film.stack" : "wifi.exclamationmark",
                                               description: Text(loadError ?? "Add media to your Jellyfin libraries and it shows up here."))
                    } else if !loaded {
                        ProgressView().frame(maxWidth: .infinity).padding(40)
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle(model.serverName)
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ForEach(model.store.servers) { server in
                            Section(server.name) {
                                ForEach(server.users) { user in
                                    Button {
                                        model.switchTo(server: server, user: user)
                                    } label: {
                                        if user.id == model.store.currentUserId && server.id == model.store.currentServerId {
                                            Label(user.name, systemImage: "checkmark")
                                        } else {
                                            Text(user.name)
                                        }
                                    }
                                }
                            }
                        }
                        Button("Add server or user", systemImage: "plus") { model.addAnotherAccount() }
                    } label: {
                        UserAvatar(serverURL: model.client?.baseURL, userId: model.user?.id ?? "",
                                   tag: model.user?.primaryImageTag, size: 30)
                    }
                }
            }
            .refreshable { await load() }
            .task(id: model.contentVersion) { await load() }
            .appDestinations(zoom: zoom)
            .environment(\.zoomNamespace, zoom)
        }
    }

    /// Continue Watching + Next Up as one row, most recently watched first.
    private var merged: [BaseItem] {
        var seen = Set<String>()
        var series = Set<String>()
        var out: [BaseItem] = []
        for item in resume where seen.insert(item.id).inserted {
            if let sid = item.seriesId { series.insert(sid) }
            out.append(item)
        }
        for item in nextUp where seen.insert(item.id).inserted && !series.contains(item.seriesId ?? "-") {
            out.append(item)
        }
        return out
    }

    private func load() async {
        guard let client = model.client else { return }
        let s = model.settings
        async let r = client.resume()
        async let n = client.nextUp(limit: 24, enableRewatching: s.nextUpRewatching,
                                    maxDaysOld: s.nextUpMaxDays > 0 ? s.nextUpMaxDays : nil)
        var lat: [(BaseItem, [BaseItem])] = []
        var anyError: Error?
        if model.libraries.isEmpty { await model.refreshSession() }
        let shelves = model.libraries.filter {
            !["music", "books", "photos", "playlists", "livetv", "boxsets"].contains($0.collectionType ?? "")
                && !s.hiddenLatestLibraries.contains($0.id)
        }
        await withTaskGroup(of: (Int, BaseItem, [BaseItem]).self) { group in
            for (i, lib) in shelves.enumerated() {
                group.addTask { (i, lib, (try? await client.latest(parentId: lib.id, limit: 20)) ?? []) }
            }
            var tmp: [(Int, BaseItem, [BaseItem])] = []
            for await x in group { tmp.append(x) }
            lat = tmp.sorted { $0.0 < $1.0 }.filter { !$0.2.isEmpty }.map { ($0.1, $0.2) }
        }
        do { resume = try await r } catch { anyError = error }
        do { nextUp = try await n } catch { anyError = anyError ?? error }
        latest = lat.map { LatestShelf(library: $0.0, items: $0.1) }
        hero = resume.first ?? nextUp.first
        loadError = anyError.flatMap { AppModel.isCancellation($0) ? nil : $0.localizedDescription }
        loaded = true
        Task { await model.reco.ensureBuilt() }
    }
}

struct LatestShelf: Identifiable {
    var id: String { library.id }
    let library: BaseItem
    let items: [BaseItem]
}

/// Big glass "pick up where you left off" card at the top of Home.
struct HeroCard: View {
    @Environment(AppModel.self) private var model
    let item: BaseItem

    var body: some View {
        let data = model.userData(for: item)
        ZStack(alignment: .bottomLeading) {
            RemoteImage(url: model.client?.backdropURL(item) ?? model.client?.landscapeURL(item, width: 1280))
                .frame(height: 220)
                .frame(maxWidth: .infinity)
                .clipped()
                .overlay(LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom))
            VStack(alignment: .leading, spacing: 8) {
                if let logo = model.client?.logoURL(item) {
                    RemoteImage(url: logo, contentMode: .fit)
                        .frame(maxWidth: 200, maxHeight: 60, alignment: .leading)
                } else {
                    Text(item.seriesName ?? item.displayName).font(.title2.bold()).foregroundStyle(.white)
                }
                Text([item.episodeLabel, item.kind == .episode ? item.name : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                HStack(spacing: 10) {
                    Button { model.play(item) } label: {
                        Label((data?.playbackPositionTicks ?? 0) > 0 ? "Resume" : "Play", systemImage: "play.fill")
                            .font(.headline)
                    }
                    .buttonStyle(.glassProminent)
                    if let p = data?.playedPercentage, p > 0 { ProgressBar(value: p / 100).frame(width: 90) }
                }
            }
            .padding(16)
        }
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
        .itemActions(item)
    }
}

/// My List on Home (stored on the server).
struct WatchlistShelf: View {
    @Environment(AppModel.self) private var model
    @State private var items: [BaseItem] = []
    var body: some View {
        Shelf(title: "My List", items: items) { WatchlistView() }
            .task(id: model.watchlist) { items = await WatchlistView.fetch(model) }
    }
}

/// A short shelf of For You picks on Home.
struct PicksShelf: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let source = model.reco.currentSourceId
        let items = model.reco.picks(for: source, genre: nil).prefix(15).map(\.item)
        if !items.isEmpty {
            Shelf(title: "Picked for you · \(model.reco.sourceName(source))", items: Array(items))
        }
    }
}
