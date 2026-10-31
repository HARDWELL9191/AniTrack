import SwiftUI

/// My List: everything you want to watch, saved on your Jellyfin server (your account's
/// JellyReco storage). Titles on your server play from here; For You picks that aren't on the
/// server yet open their TMDB page, and switch to "On your server" once they're added.
struct MyListView: View {
    @Environment(AppModel.self) private var model
    @State private var serverItems: [String: BaseItem] = [:]
    @State private var detail: ExternalTitle?
    @State private var filter = 0

    private var entries: [MyListEntry] {
        switch filter {
        case 1: return model.myList.filter { $0.serverId != nil || isNowOnServer($0) }
        case 2: return model.myList.filter { $0.external != nil && !isNowOnServer($0) }
        default: return model.myList
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                filterBar

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12, alignment: .top)], spacing: 16) {
                    ForEach(entries) { entry in
                        cell(entry)
                    }
                }
                .padding(.horizontal)
            }
            .padding(.vertical)
        }
        .overlay {
            if model.myList.isEmpty {
                ContentUnavailableView("My List is empty", systemImage: "bookmark",
                                       description: Text("Add titles with \"Add to My List\" on For You picks, on item pages, or by long-pressing any poster. It's saved on your Jellyfin server."))
            }
        }
        .navigationTitle("My List")
        .refreshable { await model.loadAccountStorage(); await loadServerItems() }
        .task(id: model.myList.map(\.id)) {
            if model.reco.libraryItems.isEmpty { await model.reco.ensureBuilt() }
            indexLibrary()
            await loadServerItems()
        }
        .sheet(item: $detail) { ExternalDetailSheet(title: $0) }
    }

    /// AniReco's list dropdown: one glass button on the right showing the current list and its count.
    private var filterBar: some View {
        let options: [(Int, String, String)] = [
            (0, "All", "bookmark"),
            (1, "On your server", "server.rack"),
            (2, "Not on server yet", "icloud.and.arrow.down"),
        ]
        func count(_ f: Int) -> Int {
            switch f {
            case 1: return model.myList.filter { $0.serverId != nil || isNowOnServer($0) }.count
            case 2: return model.myList.filter { $0.external != nil && !isNowOnServer($0) }.count
            default: return model.myList.count
            }
        }
        let current = options.first { $0.0 == filter } ?? options[0]
        return HStack {
            Spacer()
            Menu {
                ForEach(options.indices, id: \.self) { i in
                    Button { filter = options[i].0 } label: {
                        Label("\(options[i].1) (\(count(options[i].0)))", systemImage: options[i].0 == filter ? "checkmark" : options[i].2)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: current.2).frame(height: 0)
                    Text("\(current.1) (\(count(current.0)))")
                    Image(systemName: "chevron.down").font(.caption.weight(.semibold)).frame(height: 0)
                }
                .menuButtonHeight()
                .font(.subheadline.weight(.semibold))
            }
            .menuStyle(.button)
            .buttonStyle(.glass)
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private func cell(_ entry: MyListEntry) -> some View {
        if let id = entry.serverId, let item = serverItems[id] {
            NavigationLink(value: ItemLink(item: item)) { PosterCard(item: item, width: 104) }
                .buttonStyle(PressStyle())
        } else if let ext = entry.external {
            if let owned = ownedItem(for: ext) {
                NavigationLink(value: ItemLink(item: owned)) {
                    PosterCard(item: owned, width: 104)
                        .overlay(alignment: .topLeading) { GlassLabel(text: "New on server").padding(5) }
                }
                .buttonStyle(PressStyle())
            } else {
                Button { detail = ext } label: {
                    ExternalPosterCard(title: ext, width: 104)
                        .overlay(alignment: .topLeading) { GlassIcon(symbol: "icloud.and.arrow.down").padding(5) }
                }
                .buttonStyle(PressStyle())
                .cardContextMenu {
                    Button("Remove from My List", systemImage: "bookmark.slash", role: .destructive) {
                        Task { await model.removeFromMyList(entry) }
                    }
                    Button("Already seen", systemImage: "eye") { Task { await model.markSeenElsewhere(ext) } }
                    Button("Not for me", systemImage: "hand.thumbsdown") { Task { await model.markExternalNotForMe(ext) } }
                }
            }
        } else {
            // A server title that's no longer on the server.
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 10).fill(.fill.tertiary).frame(width: 104, height: 156)
                    .overlay(Image(systemName: "questionmark").foregroundStyle(.secondary))
                Text(entry.name ?? "Removed from server").font(.caption.weight(.semibold)).lineLimit(2)
            }
            .cardContextMenu {
                Button("Remove from My List", systemImage: "bookmark.slash", role: .destructive) {
                    Task { await model.removeFromMyList(entry) }
                }
            }
        }
    }

    @State private var byTMDB: [String: BaseItem] = [:]
    @State private var byIMDb: [String: BaseItem] = [:]
    @State private var byTitle: [String: BaseItem] = [:]

    /// The server copy of a For You pick, if it has been added since (TMDB/IMDb id, then title).
    private func ownedItem(for ext: ExternalTitle) -> BaseItem? {
        if let hit = byTMDB["\(ext.isMovie ? "m" : "s"):\(ext.sourceId)"] { return hit }
        if let imdb = ext.imdbId, let hit = byIMDb[imdb] { return hit }
        return byTitle["\(ext.isMovie ? "m" : "s"):\(TitleKey.make(ext.title))"]
    }

    private func indexLibrary() {
        var t: [String: BaseItem] = [:], i: [String: BaseItem] = [:], n: [String: BaseItem] = [:]
        for item in model.reco.libraryItems {
            let kind = item.kind == .series ? "s" : "m"
            for (key, value) in item.providerIds ?? [:] {
                if key.caseInsensitiveCompare("Tmdb") == .orderedSame { t["\(kind):\(value)"] = item }
                if key.caseInsensitiveCompare("Imdb") == .orderedSame { i[value] = item }
            }
            n["\(kind):\(TitleKey.make(item.displayName))"] = item
        }
        byTMDB = t; byIMDb = i; byTitle = n
    }

    private func isNowOnServer(_ e: MyListEntry) -> Bool {
        guard let ext = e.external else { return false }
        return ownedItem(for: ext) != nil
    }

    private func loadServerItems() async {
        guard let client = model.client else { return }
        let ids = model.myList.compactMap(\.serverId).filter { serverItems[$0] == nil }
        guard !ids.isEmpty else { return }
        var q = JellyfinClient.ItemQuery()
        q.ids = ids
        q.limit = ids.count
        q.isMissing = nil
        for item in (try? await client.items(q).items) ?? [] { serverItems[item.id] = item }
    }
}

/// Not for me / Already seen: For You picks you turned down (saved on your server).
/// Undo puts a title back in the running for For You.
struct NotForMeView: View {
    @Environment(AppModel.self) private var model
    @State private var tab = 0
    @State private var detail: ExternalTitle?

    var body: some View {
        let list = tab == 0 ? model.externalNotForMe : model.externalSeen
        List {
            HStack {
                Spacer()
                Menu {
                    Button { tab = 0 } label: {
                        Label("Not for me (\(model.externalNotForMe.count))", systemImage: tab == 0 ? "checkmark" : "hand.thumbsdown")
                    }
                    Button { tab = 1 } label: {
                        Label("Already seen (\(model.externalSeen.count))", systemImage: tab == 1 ? "checkmark" : "eye")
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: tab == 0 ? "hand.thumbsdown" : "eye").frame(height: 0)
                        Text(tab == 0 ? "Not for me (\(model.externalNotForMe.count))" : "Already seen (\(model.externalSeen.count))")
                        Image(systemName: "chevron.down").font(.caption.weight(.semibold)).frame(height: 0)
                    }
                    .menuButtonHeight()
                    .font(.subheadline.weight(.semibold))
                }
                .menuStyle(.button)
                .buttonStyle(.glass)
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            ForEach(list) { t in
                Button { detail = t } label: {
                    HStack(spacing: 12) {
                        RemoteImage(url: t.posterURL).frame(width: 50, height: 75).clipShape(RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(t.title).font(.subheadline.weight(.semibold))
                            Text(t.metaLine).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .foregroundStyle(.primary)
                .swipeActions {
                    Button {
                        Task { tab == 0 ? await model.markExternalNotForMe(t, false) : await model.unmarkSeen(t) }
                    } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                    .tint(Theme.accent)
                    Button {
                        Task { await model.toggleMyList(t) }
                    } label: { Label("My List", systemImage: "bookmark") }
                    .tint(.green)
                }
            }
            if list.isEmpty {
                Text(tab == 0 ? "Titles you mark \"Not for me\" in For You show up here." : "Titles you mark \"Already seen\" in For You show up here.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Not for me")
        .toolbar {
            if !list.isEmpty {
                Button("Clear all") { Task { await model.clearExternal(tab == 0 ? .notforme : .seenelsewhere) } }
            }
        }
        .sheet(item: $detail) { ExternalDetailSheet(title: $0) }
    }
}
