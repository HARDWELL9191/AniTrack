import AuthenticationServices
import SwiftUI

/// Client ID + "Log in with AniList" (AniList's own login page, in a sheet), or a pasted token.
struct AniListLoginControls: View {
    @Environment(AppModel.self) private var model
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var clientId = ""
    @State private var pastedToken = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("AniList client ID", text: $clientId)
                .keyboardType(.numberPad)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardDoneBar()
                .padding(12)
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .onChange(of: clientId) { _, new in
                    let digits = new.filter(\.isNumber)
                    if digits != new { clientId = digits }
                }
                .accessibilityIdentifier("anilist-client-id")
            Button {
                Keyboard.dismiss()
                Task { await logIn() }
            } label: {
                HStack {
                    if working || model.anilist.isLoggingIn { ProgressView() }
                    Text("Log in with AniList").fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.tintedGlass)
            .controlSize(.large)
            .disabled(clientId.isEmpty || working || model.anilist.isLoggingIn)
            SecureField("Or paste an AniList access token", text: $pastedToken)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardDoneBar()
                .padding(12)
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            if !pastedToken.isEmpty {
                Button("Use token") {
                    Keyboard.dismiss()
                    let token = pastedToken
                    pastedToken = ""
                    Task { await model.anilist.logIn(token: token) }
                }
                .buttonStyle(.glass)
            }
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
        }
        .onAppear { if clientId.isEmpty { clientId = model.settings.anilistClientId } }
    }

    private func logIn() async {
        model.settings.anilistClientId = clientId
        guard let url = AniListAuth.authorizeURL(clientId: clientId) else {
            error = "That isn't an AniList client ID (it's a number)."
            return
        }
        error = nil
        working = true
        defer { working = false }
        do {
            let callback = try await webAuthenticationSession.authenticate(using: url, callbackURLScheme: AniListAuth.callbackScheme)
            await model.anilist.handleAuthCallback(callback)
        } catch let e as ASWebAuthenticationSessionError where e.code == .canceledLogin {
            // Closed the login sheet: nothing to do.
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Shown on For You (Anime / Anime Movies) until an AniList account is connected.
struct AniListConnectCard: View {
    @Environment(\.openURL) private var openURL
    let library: AniListLibrary

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Connect AniList", systemImage: "sparkles.tv").font(.title3.bold())
            Text("\(library == .movies ? "Anime Movies" : "Anime") picks come from your AniList list, the same way as in AniReco, and never include anything already on your server. Add to My List puts a show on your AniList Planning list, Not for me goes to a private \"Not for me\" list on AniList, Already seen marks it Completed.")
                .font(.subheadline).foregroundStyle(.secondary)
            Text("1. On AniList: Settings → Developer → Create New Client\n2. Redirect URL: \(AniListAuth.redirectURL)\n3. Paste the client ID here and log in")
                .font(.footnote)
            Button("Open AniList developer settings", systemImage: "safari") {
                if let url = URL(string: "https://anilist.co/settings/developer") { openURL(url) }
            }
            .buttonStyle(.glass)
            AniListLoginControls()
            Text("The login is kept in this iPhone's Keychain, for this Jellyfin account only. The client ID is saved with your settings, so your other devices have it too.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(.background.secondary))
    }
}

/// Settings → For You: the AniList account and its pick settings.
struct AniListSettingsSection: View {
    @Environment(AppModel.self) private var model
    @State private var confirmLogOut = false

    var body: some View {
        @Bindable var s = model.settings
        let anilist = model.anilist
        Section {
            if anilist.isLoggedIn {
                LabeledContent("Logged in as", value: anilist.viewer?.name ?? "…")
                Button("Rebuild anime picks now") {
                    anilist.invalidatePicks()
                    Task { await anilist.refreshList() }
                }
                Button("Log out of AniList", role: .destructive) { confirmLogOut = true }
            } else {
                AniListLoginControls()
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            }
            Toggle("Hide Chinese animation", isOn: $s.anilistHideChinese)
                .onChange(of: s.anilistHideChinese) { _, _ in anilist.invalidatePicks() }
            Toggle("Include unreleased anime", isOn: $s.anilistIncludeUnreleased)
                .onChange(of: s.anilistIncludeUnreleased) { _, _ in anilist.invalidatePicks() }
            Picker("Titles in", selection: $s.anilistTitleLanguage) {
                Text("AniList setting").tag("")
                ForEach(TitleLanguage.allCases) { Text($0.label).tag($0.rawValue) }
            }
        } header: {
            Text("AniList (Anime libraries)")
        } footer: {
            Text("For You on the libraries named Anime and Anime Movies runs on your AniList account, the same way as AniReco: picks are learned from your AniList list and what fans recommend, My List for anime is your AniList Planning list, Not for me is a private, hidden \"Not for me\" list on AniList (the same one AniReco uses), and Already seen marks a show Completed. Anything already on your server is never picked. Your AniList client's redirect URL must be \(AniListAuth.redirectURL).")
        }
        .confirmationDialog("Log out of AniList?", isPresented: $confirmLogOut, titleVisibility: .visible) {
            Button("Log out", role: .destructive) { anilist.logOut() }
        } message: {
            Text("Anime picks stop until you log in again. Nothing on your AniList changes.")
        }
    }
}

/// "How did you like it?" after "Already seen" on an AniList pick (AniReco's rating prompt).
struct AniListRatePrompt: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let media: Media
    @State private var isSaving = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 5)

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                RemoteImage(url: media.thumbURL.flatMap(URL.init(string:)), placeholderSymbol: "tv")
                    .frame(width: 46, height: 66)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text("How did you like it?").font(.headline)
                    Text(media.displayTitle(model.anilist.language))
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            GlassEffectContainer(spacing: 8) {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(1...10, id: \.self) { value in
                        Button {
                            Task {
                                isSaving = true
                                if await model.anilist.rate(media, value) { dismiss() }
                                isSaving = false
                            }
                        } label: {
                            Text("\(value)").font(.title3.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.glass)
                        .tint(value >= 8 ? .green : (value >= 5 ? .orange : .red))
                        .disabled(isSaving)
                    }
                }
            }
            Button("Skip") { dismiss() }.foregroundStyle(.secondary)
        }
        .padding(20)
    }
}

/// UI test only ("anilist-reco"): runs the ported AniReco recommender against real AniList with
/// a small made-up list (no account needed) and checks what For You relies on: shows-only picks
/// for Anime, movies-only for Anime Movies, nothing from your list, nothing already on the
/// server, library names, and the AniList title shape.
struct AniListRecoTestHost: View {
    @State private var result = "ANILIST running…"

    var body: some View {
        ScrollView {
            Text(result)
                .font(.caption2.monospaced())
                .accessibilityIdentifier("anilist-result")
                .padding()
        }
        .task { result = await Self.run() }
    }

    static func run() async -> String {
        var log: [String] = []
        var failures: [String] = []
        func check(_ ok: Bool, _ what: String) { if ok { log.append("ok: \(what)") } else { failures.append(what) } }

        // Library names.
        check(AniListLibrary(libraryName: "Anime") == .shows, "Anime = shows")
        check(AniListLibrary(libraryName: "anime") == .shows, "anime = shows")
        check(AniListLibrary(libraryName: "Anime Movies") == .movies, "Anime Movies = movies")
        check(AniListLibrary(libraryName: "anime movies ") == .movies, "anime movies = movies")
        check(AniListLibrary(libraryName: "Anime movies") == .movies, "Anime movies = movies")
        check(AniListLibrary(libraryName: "TV Shows") == nil, "TV Shows = TMDB")
        check(AniListLibrary(libraryName: "Anime Shows") == nil, "Anime Shows = TMDB")

        let client = AniListClient()
        // Mushoku Tensei, Frieren, Solo Leveling, Re:Zero (shows), Your Name, A Silent Voice (movies).
        let ids = [108465, 154587, 151807, 21355, 21519, 20954]
        guard let page = try? await client.run(Queries.mediaByIds, variables: ["ids": ids, "perPage": ids.count], as: PageData.self),
              page.page.media.count >= 4 else {
            return "ANILIST FAIL: couldn't load the seed shows from AniList"
        }
        let entries = page.page.media.enumerated().map { i, m in
            ListEntry(id: -(i + 1), mediaId: m.id, status: .COMPLETED, score: 90, progress: nil,
                      updatedAt: nil, media: m)
        }
        log.append("seeds: \(entries.map { $0.media.displayTitle(.english) })")
        let onList = Set(entries.map(\.mediaId))
        func options(movies: Bool, owned: AniListOwnedIndex = AniListOwnedIndex()) -> Recommender.Options {
            Recommender.Options(hideChinese: true, includeUnreleased: false, dismissed: [], titleLanguage: .english,
                                useOnDeviceAI: false, category: nil, movies: movies, owned: owned)
        }

        // Anime: shows only, nothing from the list.
        var topShow: Media?
        do {
            let shows = try await Recommender.run(entries: entries, client: client, options: options(movies: false)).picks
            log.append("shows: \(shows.count) — \(shows.prefix(5).map { $0.media.displayTitle(.english) })")
            check(!shows.isEmpty, "Anime picks found")
            check(shows.allSatisfy { !$0.media.isMovie }, "Anime picks are all shows")
            check(shows.allSatisfy { !onList.contains($0.id) }, "Anime picks skip the list")
            check(shows.allSatisfy { $0.match >= 50 && $0.match <= 99 }, "match % in range")
            topShow = shows.first?.media
        } catch {
            failures.append("Anime picks error: \(error.localizedDescription)")
        }

        // Anime Movies: movies only.
        do {
            let movies = try await Recommender.run(entries: entries, client: client, options: options(movies: true)).picks
            log.append("movies: \(movies.count) — \(movies.prefix(5).map { $0.media.displayTitle(.english) })")
            check(!movies.isEmpty, "Anime Movies picks found")
            check(movies.allSatisfy { $0.media.isMovie }, "Anime Movies picks are all movies")
            check(movies.allSatisfy { !onList.contains($0.id) }, "Anime Movies picks skip the list")
        } catch {
            failures.append("Anime Movies picks error: \(error.localizedDescription)")
        }

        // Already on the server (a series with the same name): never picked.
        if let top = topShow {
            let name = top.title.english ?? top.title.romaji ?? ""
            let json = #"{"Id":"owned1","Name":"\#(name.replacingOccurrences(of: "\"", with: "\\\""))","Type":"Series"}"#
            if let item = try? JSONCoding.decoder.decode(BaseItem.self, from: Data(json.utf8)) {
                let owned = AniListOwnedIndex(items: [item])
                check(owned.contains(top), "server copy of \(name) is recognized")
                check(owned.contains(ExternalTitle(anilist: top, language: .english)), "server copy recognized as a title")
                let byId = #"{"Id":"owned2","Name":"Something else","Type":"Series","ProviderIds":{"AniList":"\#(top.id)"}}"#
                if let idItem = try? JSONCoding.decoder.decode(BaseItem.self, from: Data(byId.utf8)) {
                    check(AniListOwnedIndex(items: [idItem]).contains(top), "server copy recognized by AniList id")
                }
                if let again = try? await Recommender.run(entries: entries, client: client,
                                                          options: options(movies: false, owned: owned)).picks {
                    check(!again.contains { $0.id == top.id }, "owned show left out of picks")
                }
            } else {
                failures.append("couldn't make the server item")
            }
        }

        // The AniList title shape (what cards, My List and the sheets use).
        if let m = entries.first?.media {
            let t = ExternalTitle(anilist: m, language: .english)
            check(t.isAniList && t.anilistId == m.id && t.isAnime, "title is an AniList anime")
            check(t.isMovie == m.isMovie, "title movie flag")
            check(t.webURL?.absoluteString == "https://anilist.co/anime/\(m.id)", "title links to AniList")
            if let data = try? JSONEncoder().encode(t), let back = try? JSONDecoder().decode(ExternalTitle.self, from: data) {
                check(back == t, "title survives saving")
            } else {
                failures.append("title couldn't be saved and read back")
            }
        }

        // Kitsu age rating (as in AniReco); informational, Kitsu can be slow.
        let (ages, kitsuFailed) = await KitsuClient.shared.ratings(for: entries.prefix(3).map { KitsuClient.Lookup(id: $0.mediaId, mal: $0.media.idMal) })
        log.append("kitsu: \(kitsuFailed ? "unreachable" : ages.mapValues { $0.label ?? "?" }.description)")

        return (failures.isEmpty ? "ANILIST PASS" : "ANILIST FAIL: \(failures.joined(separator: "; "))") + "\n" + log.joined(separator: "\n")
    }
}
