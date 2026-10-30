import SwiftUI

/// Home, the way Jellyfin builds it: the sections and their order come from your Jellyfin home
/// settings (Settings → Home on the server, shared with Jellyfin web), with the same queries
/// Jellyfin web uses. Only the look is JellyReco's.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Namespace private var zoom
    @State private var path = NavigationPath()

    @State private var sections: [HomeSection] = []
    @State private var resume: [BaseItem] = []
    @State private var nextUp: [BaseItem] = []
    @State private var onNow: [BaseItem] = []
    @State private var latest: [LatestShelf] = []
    @State private var loaded = false
    @State private var loadError: String?

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                        sectionView(section)
                    }
                    if loaded && model.libraries.isEmpty {
                        ContentUnavailableView(loadError == nil ? "Nothing here yet" : "Couldn't load",
                                               systemImage: loadError == nil ? "film.stack" : "wifi.exclamationmark",
                                               description: Text(loadError ?? (model.isAdmin ? "Add a library in the server dashboard." : "Ask your server admin to add a library.")))
                    } else if !loaded {
                        ProgressView().frame(maxWidth: .infinity).padding(40)
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("Home")
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

    @ViewBuilder
    private func sectionView(_ section: HomeSection) -> some View {
        switch section {
        case .libraryTiles, .libraryButtons:
            MyMediaRow(libraries: model.libraries)
        case .resume:
            Shelf(title: "Continue Watching", items: resume, landscape: true, playOnTap: true)
        case .nextUp:
            Shelf(title: "Next Up", items: nextUp, landscape: true, playOnTap: true)
        case .liveTV:
            Shelf(title: "On Now", items: onNow, landscape: true, playOnTap: true)
        case .latestMedia:
            ForEach(latest) { entry in
                Shelf(title: "Recently Added in \(entry.library.displayName)", items: entry.items,
                      seeAll: LibraryLink(library: entry.library, sort: .dateAdded))
            }
        case .none, .resumeAudio, .resumeBook, .activeRecordings:
            EmptyView()
        }
    }

    private func load() async {
        guard let client = model.client else { return }
        if model.libraries.isEmpty { await model.refreshSession() }
        let web = await client.loadWebUserSettings()
        let order = HomeSection.sections(from: web)
        let settings = model.settings

        async let r = client.resume(limit: 12)
        let cutoff = settings.nextUpMaxDays   // Jellyfin web's default is 365 days
        async let n = client.nextUp(limit: 24, enableRewatching: settings.nextUpRewatching,
                                    maxDaysOld: cutoff > 0 ? cutoff : nil)

        // Recently added: same rules as Jellyfin web (skip these library types and your exclusions).
        let excludedTypes: Set<String> = ["playlists", "livetv", "boxsets", "channels", "folders"]
        let excludedIds = Set((model.user?.configuration?.latestItemsExcludes ?? []).map(Self.normalize))
        let shelves = model.libraries.filter {
            !excludedTypes.contains($0.collectionType ?? "") && !excludedIds.contains(Self.normalize($0.id))
        }
        var lat: [LatestShelf] = []
        if order.contains(.latestMedia) {
            await withTaskGroup(of: (Int, BaseItem, [BaseItem]).self) { group in
                for (i, lib) in shelves.enumerated() {
                    group.addTask { (i, lib, (try? await client.latest(parentId: lib.id, limit: 16)) ?? []) }
                }
                var tmp: [(Int, BaseItem, [BaseItem])] = []
                for await x in group { tmp.append(x) }
                lat = tmp.sorted { $0.0 < $1.0 }.filter { !$0.2.isEmpty }.map { LatestShelf(library: $0.1, items: $0.2) }
            }
        }
        var anyError: Error?
        do { resume = try await r } catch { anyError = error }
        do { nextUp = try await n } catch { anyError = anyError ?? error }
        if order.contains(.liveTV) && model.hasLiveTV {
            onNow = (try? await client.recommendedPrograms()) ?? []
        } else {
            onNow = []
        }
        latest = lat
        sections = order
        loadError = anyError.flatMap { AppModel.isCancellation($0) ? nil : $0.localizedDescription }
        loaded = true
    }

    static func normalize(_ id: String) -> String { id.lowercased().replacingOccurrences(of: "-", with: "") }
}

/// Jellyfin's home section types (jellyfin-web `HomeSectionType`, same defaults and order).
enum HomeSection: String, CaseIterable, Identifiable {
    case libraryTiles = "smalllibrarytiles"
    case libraryButtons = "librarybuttons"
    case activeRecordings = "activerecordings"
    case resume = "resume"
    case resumeAudio = "resumeaudio"
    case latestMedia = "latestmedia"
    case nextUp = "nextup"
    case liveTV = "livetv"
    case resumeBook = "resumebook"
    case none = "none"

    var id: String { rawValue }

    static let defaults: [HomeSection] = [.libraryTiles, .resume, .resumeAudio, .resumeBook, .liveTV, .nextUp,
                                          .latestMedia, .none, .none, .none]

    /// Sections 0–9 from the server, falling back to Jellyfin's defaults (as jellyfin-web does).
    static func sections(from prefs: [String: String]) -> [HomeSection] {
        (0..<10).map { i in
            var raw = prefs["homesection\(i)"] ?? ""
            if raw.isEmpty { raw = defaults[i].rawValue }
            if raw == "folders" { raw = defaults[0].rawValue }
            return HomeSection(rawValue: raw.lowercased()) ?? .none
        }
    }

    var label: String {
        switch self {
        case .libraryTiles: return "My Media"
        case .libraryButtons: return "My Media (small)"
        case .activeRecordings: return "Active Recordings"
        case .resume: return "Continue Watching"
        case .resumeAudio: return "Continue Listening"
        case .latestMedia: return "Recently Added Media"
        case .nextUp: return "Next Up"
        case .liveTV: return "Live TV"
        case .resumeBook: return "Continue Reading"
        case .none: return "None"
        }
    }
}

struct LatestShelf: Identifiable {
    var id: String { library.id }
    let library: BaseItem
    let items: [BaseItem]
}

/// "My Media": your libraries (in your Jellyfin order) as glass tiles.
struct MyMediaRow: View {
    let libraries: [BaseItem]
    var body: some View {
        if !libraries.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("My Media").font(.title3.weight(.bold)).padding(.horizontal)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(libraries) { lib in
                            NavigationLink(value: LibraryLink(library: lib)) {
                                LibraryTile(library: lib).frame(width: 220)
                            }
                            .buttonStyle(PressStyle())
                        }
                    }
                    .padding(.horizontal)
                }
                .scrollClipDisabled()
            }
        }
    }
}
