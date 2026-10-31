import SwiftUI

/// Settings, organised like the JellyReco desktop client's: Account, Display, Home, Playback,
/// Player, Subtitles, For You, Devices & servers, About — and, for administrators, the server
/// Dashboard (its own tab on the desktop; inside Settings here, where a phone has less room).
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { AccountSettingsView() } label: {
                        HStack(spacing: 14) {
                            UserAvatar(serverURL: model.client?.baseURL, userId: model.user?.id ?? "",
                                       tag: model.user?.primaryImageTag, size: 54)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.user?.name ?? "…").font(.headline)
                                Text(model.serverName).font(.subheadline).foregroundStyle(.secondary)
                                if model.isAdmin { Text("Administrator").font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
                Section {
                    link("Display", "paintpalette.fill") { DisplaySettingsView() }
                    link("Home", "house.fill") { HomeSettingsView() }
                    link("Playback", "play.fill") { PlaybackSettingsView() }
                    link("Player", "play.rectangle.fill") { PlayerSettingsView() }
                    link("Subtitles", "captions.bubble.fill") { SubtitleSettingsView() }
                    link("For You", "wand.and.stars") { ForYouSettingsView() }
                }
                if model.isAdmin {
                    Section {
                        link("Dashboard", "server.rack") { AdminDashboardView() }
                    } header: { Text("Administration") } footer: {
                        Text("Your server's settings, users, libraries, plugins and more, organised like Jellyfin's dashboard.")
                    }
                }
                Section {
                    link("Devices & servers", "macbook.and.iphone") { AccountsView() }
                    link("About", "info.circle.fill") { AboutSettingsView() }
                }
            }
            .navigationTitle("Settings")
            .toolbarTitleDisplayMode(.inlineLarge)
        }
    }

    private func link<D: View>(_ title: String, _ symbol: String, @ViewBuilder _ destination: @escaping () -> D) -> some View {
        NavigationLink { destination() } label: { Label(title, systemImage: symbol) }
    }
}

// MARK: - Account

struct AccountSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmSignOut = false
    @State private var showQuickConnectApprove = false
    @State private var showPassword = false

    var body: some View {
        Form {
            Section("Profile") {
                HStack(spacing: 14) {
                    UserAvatar(serverURL: model.client?.baseURL, userId: model.user?.id ?? "", tag: model.user?.primaryImageTag, size: 64)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.user?.name ?? "…").font(.title3.weight(.semibold))
                        Text(model.serverName).font(.subheadline).foregroundStyle(.secondary)
                        if model.isAdmin { Text("Administrator").font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                    }
                }
            }
            Section("Password") {
                Button { showPassword = true } label: { Label("Change password", systemImage: "key.fill") }
            }
            Section {
                Button { showQuickConnectApprove = true } label: { Label("Approve a Quick Connect code", systemImage: "qrcode") }
            } header: { Text("Sign in other devices") } footer: {
                Text("Enter the code another device shows to sign it in as you.")
            }
            Section {
                Button(role: .destructive) { confirmSignOut = true } label: {
                    Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right").foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Account")
        .confirmationDialog("Sign out of \(model.serverName)?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { model.signOutCurrentUser() }
        }
        .sheet(isPresented: $showQuickConnectApprove) { ApproveQuickConnectSheet().presentationDetents([.height(280)]) }
        .sheet(isPresented: $showPassword) { ChangePasswordSheet(userId: model.user?.id ?? "", isOwn: true) }
    }
}

// MARK: - About

struct AboutSettingsView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Form {
            Section("About JellyReco") {
                LabeledContent("Version", value: JellyfinClient.appVersion)
                if let v = model.serverInfo?.version ?? model.store.currentServer?.version {
                    LabeledContent("Server", value: "Jellyfin \(v)")
                }
                LabeledContent("Playback", value: "Direct play first")
            }
        }
        .navigationTitle("About")
    }
}

// MARK: - Accounts

struct AccountsView: View {
    @Environment(AppModel.self) private var model
    @State private var editingServer: SavedServer?
    @State private var cacheCleared = false

    private var faceID: Binding<Bool> {
        Binding(get: { model.settings.requireFaceID }, set: { model.settings.requireFaceID = $0 })
    }

    var body: some View {
        List {
            ForEach(model.store.servers) { server in
                Section {
                    ForEach(server.users) { user in
                        Button {
                            model.switchTo(server: server, user: user)
                        } label: {
                            HStack(spacing: 12) {
                                UserAvatar(serverURL: server.url, userId: user.id, tag: user.imageTag, size: 36)
                                VStack(alignment: .leading) {
                                    Text(user.name)
                                    if user.isAdmin { Text("Administrator").font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                if user.id == model.store.currentUserId && server.id == model.store.currentServerId {
                                    Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                        .swipeActions {
                            Button(role: .destructive) { model.store.removeUser(user.id, from: server.id) } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }
                    Button("Addresses…", systemImage: "network") { editingServer = server }
                    Button("Remove server", systemImage: "trash", role: .destructive) {
                        let wasCurrent = server.id == model.store.currentServerId
                        model.store.removeServer(server.id)
                        if wasCurrent { model.signOutCurrentUser(revoke: false) }
                    }
                } header: {
                    Text("\(server.name)\(server.version.map { " · \($0)" } ?? "")")
                }
            }
            Section {
                Button("Add server or user", systemImage: "plus") { model.addAnotherAccount() }
            }
            Section("This iPhone") {
                Toggle(isOn: faceID) { Label("Lock with Face ID", systemImage: "faceid") }
                Button {
                    URLCache.shared.removeAllCachedResponses()
                    cacheCleared = true
                } label: { Label(cacheCleared ? "Image cache cleared" : "Clear image cache", systemImage: "photo.on.rectangle.angled") }
                .disabled(cacheCleared)
            }
        }
        .navigationTitle("Devices & servers")
        .sheet(item: $editingServer) { ServerAddressesSheet(server: $0) }
    }
}

struct ServerAddressesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let server: SavedServer
    @State private var urls: [String] = []
    @State private var newURL = ""
    @State private var status: [String: Bool] = [:]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(urls, id: \.self) { u in
                        HStack {
                            Text(u).font(.callout)
                            Spacer()
                            if let ok = status[u] {
                                Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(ok ? .green : .red)
                            }
                        }
                    }
                    .onDelete { urls.remove(atOffsets: $0) }
                    .onMove { urls.move(fromOffsets: $0, toOffset: $1) }
                } footer: {
                    Text("The first address is used; when it can't be reached JellyReco tries the others (e.g. home network and remote).")
                }
                Section("Add address") {
                    TextField("https://jellyfin.example.com", text: $newURL)
                    .keyboardDoneBar()
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Add") {
                        if let u = JellyfinClient.normalize(newURL)?.absoluteString, !urls.contains(u) { urls.append(u) }
                        newURL = ""
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle(server.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { model.store.setURLs(urls, for: server.id); dismiss() }.disabled(urls.isEmpty)
                }
            }
            .task {
                urls = server.urls
                for u in urls {
                    guard let url = URL(string: u) else { continue }
                    status[u] = (try? await JellyfinClient(baseURL: url).publicInfo()) != nil
                }
            }
        }
    }
}

struct ApproveQuickConnectSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var result: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("Approve Quick Connect").font(.title3.bold())
            TextField("6-digit code", text: $code)
                    .keyboardDoneBar()
                .keyboardType(.numberPad)
                .font(.title2.monospacedDigit())
                .multilineTextAlignment(.center)
                .padding(12)
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12))
            Button("Approve") {
                Task {
                    do {
                        try await model.client?.authorizeQuickConnect(code: code.trimmingCharacters(in: .whitespaces))
                        result = "Approved. The other device is signing in."
                    } catch { result = error.localizedDescription }
                }
            }
            .buttonStyle(.tintedGlass)
            .disabled(code.count < 4)
            if let result { Text(result).font(.footnote).foregroundStyle(.secondary) }
        }
        .padding(24)
    }
}

struct ChangePasswordSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let userId: String
    let isOwn: Bool
    @State private var current = ""
    @State private var new1 = ""
    @State private var new2 = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                if isOwn { SecureField("Current password", text: $current) }
                SecureField("New password", text: $new1)
                    .keyboardDoneBar()
                SecureField("Repeat new password", text: $new2)
                if let error { Text(error).foregroundStyle(.red).font(.footnote) }
            }
            .navigationTitle("Change password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }.disabled(new1 != new2)
                }
            }
        }
    }

    private func save() async {
        struct Body: Encodable { var currentPw: String?; var newPw: String; var resetPassword: Bool }
        do {
            try await model.client?.postVoid("/Users/Password", query: ["userId": userId],
                                             json: Body(currentPw: isOwn ? current : nil, newPw: new1, resetPassword: false))
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

// MARK: - Display

struct DisplaySettingsView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var s = model.settings
        Form {
            Section("Display") {
                Picker("Theme", selection: $s.appearance) { ForEach(AppearanceMode.allCases) { Text($0.label).tag($0) } }
                    .pickerStyle(.menu)
                Toggle("Titles under posters", isOn: $s.showPosterLabels)
                Toggle("Match % on posters", isOn: $s.showRatingBadges)
                Toggle(isOn: $s.hideSpoilers) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Blur unwatched episode thumbnails")
                        Text("No spoilers in episode stills").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Indicators") {
                Toggle("Watch progress", isOn: $s.showProgressIndicator)
                Toggle("Unwatched episode count", isOn: $s.showUnplayedIndicator)
                Toggle("Watched tick", isOn: $s.showPlayedIndicator)
                Toggle("Favourite heart", isOn: $s.showFavoriteIndicator)
            }
            Section("Libraries") {
                Picker("Layout", selection: $s.libraryLayout) {
                    Text("Grid").tag(LibraryLayout.grid)
                    Text("List").tag(LibraryLayout.list)
                }
                .pickerStyle(.menu)
                Picker("Posters", selection: $s.libraryPosterStyle) { ForEach(PosterStyle.allCases) { Text($0.label).tag($0) } }
                    .pickerStyle(.menu)
                Stepper("Columns: \(s.gridColumns)", value: $s.gridColumns, in: 2...6)
                Toggle("Remember layout per library", isOn: $s.rememberLayoutPerLibrary)
                Toggle("A–Z scrubber", isOn: $s.showLetterPicker)
                Toggle("Random button", isOn: $s.showRandomButton)
            }
        }
        .navigationTitle("Display")
    }
}

// MARK: - Home

/// Jellyfin's home settings (shared with Jellyfin web): section order, library order, and which
/// libraries show in My Media and Recently Added. Next Up's limits are per device, as in Jellyfin web.
struct HomeSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var sections: [HomeSection] = HomeSection.defaults
    @State private var loaded = false
    @State private var saving = false
    @State private var allViews: [BaseItem] = []

    private let choices: [HomeSection] = [.libraryTiles, .libraryButtons, .resume, .nextUp, .latestMedia, .liveTV,
                                          .activeRecordings, .resumeAudio, .resumeBook, .none]
    private var config: UserConfiguration? { model.user?.configuration }

    var body: some View {
        @Bindable var s = model.settings
        Form {
            Section {
                ForEach(0..<10, id: \.self) { i in
                    Picker("Section \(i + 1)", selection: Binding(get: { sections[i] }, set: { v in
                        sections[i] = v
                        saveWeb(["homesection\(i)": v.rawValue])
                    })) {
                        ForEach(choices) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.menu)
                }
            } header: { Text("Home sections") } footer: {
                Text("Saved on your server, the same as Jellyfin web → Settings → Home.")
            }
            Section {
                ForEach(allViews) { lib in
                    Label(lib.displayName, systemImage: "line.3.horizontal")
                }
                .onMove { from, to in
                    allViews.move(fromOffsets: from, toOffset: to)
                    saveConfig("OrderedViews", allViews.map(\.id))
                }
            } header: { Text("Library order") } footer: {
                Text("Tap Edit, then drag to reorder your libraries.")
            }
            Section {
                ForEach(allViews) { lib in
                    Toggle(lib.displayName, isOn: excludeBinding("MyMediaExcludes", list: config?.myMediaExcludes, id: lib.id))
                }
            } header: { Text("Show in My Media") }
            Section {
                ForEach(allViews) { lib in
                    Toggle(lib.displayName, isOn: excludeBinding("LatestItemsExcludes", list: config?.latestItemsExcludes, id: lib.id))
                }
                Toggle("Hide watched content from Recently Added", isOn: configBool(\.hidePlayedInLatest, key: "HidePlayedInLatest"))
            } header: { Text("Show in Recently Added") }
            Section {
                Toggle("Display a Collections view", isOn: configBool(\.displayCollectionsView, key: "DisplayCollectionsView"))
                Toggle(isOn: configBool(\.displayMissingEpisodes, key: "DisplayMissingEpisodes")) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Display missing episodes within seasons")
                        Text("Episodes you don't have, inside seasons").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: { Text("Libraries (saved in your Jellyfin account)") }
            Section {
                Picker("Max days in Next Up", selection: $s.nextUpMaxDays) {
                    ForEach([7, 14, 30, 60, 90, 180, 365], id: \.self) { Text("\($0) days").tag($0) }
                    Text("No limit").tag(0)
                }
                .pickerStyle(.menu)
                Toggle("Rewatching in Next Up", isOn: $s.nextUpRewatching)
            } header: { Text("Next Up (this device)") } footer: {
                Text("Like Jellyfin web, these are per device. Jellyfin's default is 365 days.")
            }
        }
        .navigationTitle("Home")
        .toolbar { EditButton() }
        .overlay(alignment: .top) { if saving { ProgressView().padding() } }
        .task {
            guard !loaded, let client = model.client else { return }
            sections = HomeSection.sections(from: await client.loadWebUserSettings())
            let r: QueryResult<BaseItem>? = try? await client.get("/UserViews", ["userId": client.userId, "includeHidden": true])
            allViews = r?.items ?? model.libraries
            loaded = true
        }
        .onDisappear { model.bumpContent() }
    }

    private func norm(_ id: String) -> String { id.lowercased().replacingOccurrences(of: "-", with: "") }

    private func excludeBinding(_ key: String, list: [String]?, id: String) -> Binding<Bool> {
        Binding(get: { !(list ?? []).contains { norm($0) == norm(id) } }, set: { show in
            var new = (list ?? []).filter { norm($0) != norm(id) }
            if !show { new.append(id) }
            saveConfig(key, new)
        })
    }

    private func configBool(_ path: KeyPath<UserConfiguration, Bool?>, key: String) -> Binding<Bool> {
        Binding(get: { config?[keyPath: path] ?? false }, set: { saveConfig(key, $0) })
    }

    private func saveConfig(_ key: String, _ value: Any) {
        Task {
            saving = true
            defer { saving = false }
            do {
                try await model.client?.updateUserConfiguration([key: value])
                await model.refreshSession()
            } catch { model.report(error) }
        }
    }

    private func saveWeb(_ changes: [String: String]) {
        Task {
            do { try await model.client?.saveWebUserSettings(changes) } catch { model.report(error) }
        }
    }
}

// MARK: - Playback (your Jellyfin account's playback settings, plus this app's)

struct PlaybackSettingsView: View {
    @Environment(AppModel.self) private var model
    struct Lang: Hashable { let code: String; let name: String }
    @State private var languages: [Lang] = []
    @State private var saving = false
    private let subtitleModes = [("Default", "Default"), ("Smart", "Smart"), ("OnlyForced", "Only forced"),
                                 ("Always", "Always"), ("None", "None")]
    private var config: UserConfiguration? { model.user?.configuration }

    var body: some View {
        @Bindable var s = model.settings
        Form {
            Section {
                Picker("Preferred audio language", selection: configString(\.audioLanguagePreference, key: "AudioLanguagePreference")) {
                    Text("Any (the file's default)").tag("")
                    ForEach(languages, id: \.self) { Text($0.name).tag($0.code) }
                }
                .pickerStyle(.menu)
                Toggle("Play the default audio track whatever its language", isOn: configBool(\.playDefaultAudioTrack, key: "PlayDefaultAudioTrack", fallback: true))
                Picker("Preferred subtitle language", selection: configString(\.subtitleLanguagePreference, key: "SubtitleLanguagePreference")) {
                    Text("Any").tag("")
                    ForEach(languages, id: \.self) { Text($0.name).tag($0.code) }
                }
                .pickerStyle(.menu)
                Picker("Subtitles", selection: Binding(get: { config?.subtitleMode ?? "Default" }, set: { saveConfig("SubtitleMode", $0) })) {
                    ForEach(subtitleModes, id: \.0) { Text($0.1).tag($0.0) }
                }
                .pickerStyle(.menu)
                Toggle("Remember my audio choices per show", isOn: configBool(\.rememberAudioSelections, key: "RememberAudioSelections", fallback: true))
                Toggle("Remember my subtitle choices per show", isOn: configBool(\.rememberSubtitleSelections, key: "RememberSubtitleSelections", fallback: true))
                Toggle("Play the next episode automatically", isOn: Binding(
                    get: { config?.enableNextEpisodeAutoPlay ?? s.autoPlayNext },
                    set: { v in s.autoPlayNext = v; saveConfig("EnableNextEpisodeAutoPlay", v) }))
            } header: { Text("Languages (your Jellyfin account)") } footer: {
                Text("Smart: subtitles on when the audio isn't in your language. These are your account's settings on the server, the same as in Jellyfin web.")
            }
            Section {
                if s.autoPlayNext {
                    Stepper("Countdown: \(s.nextUpCountdown) s", value: $s.nextUpCountdown, in: 3...30)
                    Picker("Ask \"Still watching?\"", selection: $s.stillWatchingAfter) {
                        Text("Never").tag(0)
                        ForEach([2, 3, 4, 5, 6, 8], id: \.self) { Text("After \($0) episodes").tag($0) }
                    }
                    .pickerStyle(.menu)
                }
                ForEach(AppSettings.segmentTypes, id: \.type) { seg in
                    Picker(seg.label, selection: Binding(get: { s.segmentAction(seg.type) }, set: { v in
                        var actions = s.segmentActions
                        actions[seg.type] = v
                        s.segmentActions = actions
                    })) {
                        Text("Show a skip button").tag("ask")
                        Text("Skip automatically").tag("skip")
                        Text("Skip the first time").tag("skipOnce")
                        Text("Never").tag("none")
                    }
                    .pickerStyle(.menu)
                }
            } header: { Text("Next episode & skipping") } footer: {
                Text("Intro and credits times come from your server's media segments (e.g. the Intro Skipper plugin or chapter names).")
            }
            Section("Starting") {
                Stepper("Rewind on resume: \(s.resumeOffset) s", value: $s.resumeOffset, in: 0...30)
                Picker("Jump back", selection: $s.jumpBackward) {
                    ForEach([5, 10, 15, 30, 45, 60], id: \.self) { Text("\($0) s").tag($0) }
                }
                .pickerStyle(.menu)
                Picker("Jump forward", selection: $s.jumpForward) {
                    ForEach([5, 10, 15, 30, 45, 60, 90], id: \.self) { Text("\($0) s").tag($0) }
                }
                .pickerStyle(.menu)
            }
            Section {
                Toggle("Server conversion as a fallback", isOn: $s.transcodeFallback)
            } header: { Text("Quality") } footer: {
                Text("Every file plays directly on your iPhone, as stored. If a file still can't play, \(s.transcodeFallback ? "your server converts it as a last resort" : "you'll see why instead (the server never converts)").")
            }
        }
        .navigationTitle("Playback")
        .overlay(alignment: .top) { if saving { ProgressView().padding() } }
        .task { await loadLanguages() }
    }

    private func configString(_ path: KeyPath<UserConfiguration, String?>, key: String) -> Binding<String> {
        // "" = any, as jellyfin-web saves it.
        Binding(get: { config?[keyPath: path] ?? "" }, set: { saveConfig(key, $0) })
    }

    private func configBool(_ path: KeyPath<UserConfiguration, Bool?>, key: String, fallback: Bool) -> Binding<Bool> {
        Binding(get: { config?[keyPath: path] ?? fallback }, set: { saveConfig(key, $0) })
    }

    private func saveConfig(_ key: String, _ value: Any) {
        Task {
            saving = true
            defer { saving = false }
            do {
                try await model.client?.updateUserConfiguration([key: value])
                await model.refreshSession()
            } catch { model.report(error) }
        }
    }

    /// The server's language list (three-letter codes, as Jellyfin stores them), like jellyfin-web.
    private func loadLanguages() async {
        guard languages.isEmpty, let client = model.client,
              let data = try? await client.send("GET", "/Localization/Cultures"),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        var seen = Set<String>()
        languages = list.compactMap { c -> Lang? in
            guard let code = c["ThreeLetterISOLanguageName"] as? String, !code.isEmpty, seen.insert(code).inserted else { return nil }
            return Lang(code: code, name: c["DisplayName"] as? String ?? code)
        }
        // A saved language the list doesn't have still shows.
        for code in [config?.audioLanguagePreference, config?.subtitleLanguagePreference].compactMap({ $0 }) where !code.isEmpty && !seen.contains(code) {
            languages.append(Lang(code: code, name: code))
            seen.insert(code)
        }
    }
}

// MARK: - Player

struct PlayerSettingsView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var s = model.settings
        Form {
            Section("Picture") {
                Toggle("Hardware decoding", isOn: $s.hardwareDecoding)
                Picker("Default picture", selection: $s.defaultAspect) {
                    Text("Fit").tag("fit")
                    Text("Fill").tag("fill")
                    Text("Stretch").tag("stretch")
                }
                .pickerStyle(.menu)
                Toggle("Thumbnail previews on the timeline", isOn: $s.trickplayPreviews)
                Toggle("Chapter marks on the timeline", isOn: $s.showChaptersOnSlider)
            }
            Section("Sound") {
                Toggle("Downmix to stereo", isOn: $s.stereoDownmix)
                Picker("Default speed", selection: $s.defaultSpeed) {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0], id: \.self) { Text(String(format: "%g×", $0)).tag($0) }
                }
                .pickerStyle(.menu)
            }
            Section("Controls") {
                Picker("Time on the right", selection: $s.timestampStyle) {
                    ForEach(TimestampStyle.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
                Toggle("Start in landscape", isOn: $s.startInLandscape)
                Toggle("Picture in Picture when leaving the app", isOn: $s.pipAutomatically)
                Toggle("Keep playing audio in the background", isOn: $s.backgroundAudio)
            }
            Section {
                NavigationLink { PlaybackTestView() } label: { Label("Playback test", systemImage: "checkmark.seal") }
            } footer: {
                Text("Plays your files on this iPhone and lists anything that fails to decode.")
            }
            Section {
                Button("Reset player settings", role: .destructive) { s.resetPlayer() }
            }
        }
        .navigationTitle("Player")
    }
}

// MARK: - Subtitles

struct SubtitleSettingsView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var s = model.settings
        Form {
            Section {
                preview(s)
            }
            Section {
                VStack(alignment: .leading) {
                    Text("Size: \(Int(s.subtitleSize * 100))%")
                    Slider(value: $s.subtitleSize, in: 0.6...2.0, step: 0.05)
                }
                Toggle("Bold", isOn: $s.subtitleBold)
                Picker("Text color", selection: $s.subtitleColor) { ForEach(SubtitleColor.allCases) { Text($0.label).tag($0) } }
                    .pickerStyle(.menu)
                Picker("Background", selection: $s.subtitleBackground) { ForEach(SubtitleBackground.allCases) { Text($0.label).tag($0) } }
                    .pickerStyle(.menu)
                if s.subtitleBackground == .outline {
                    VStack(alignment: .leading) {
                        Text("Outline: \(String(format: "%g", s.subtitleOutlineSize))")
                        Slider(value: $s.subtitleOutlineSize, in: 0...6, step: 0.5)
                    }
                }
                VStack(alignment: .leading) {
                    Text("Vertical position: \(s.subtitlePosition)%")
                    Slider(value: Binding(get: { Double(s.subtitlePosition) }, set: { s.subtitlePosition = Int($0) }), in: 50...100, step: 1)
                }
            } header: { Text("Subtitle style") }
            Section {
                Picker("Styled subtitles (ASS, anime typesetting)", selection: $s.subtitleASSMode) {
                    Text("Keep their own styling").tag("no")
                    Text("Keep styling, use my size").tag("scale")
                    Text("Force my style").tag("force")
                    Text("Plain text").tag("strip")
                }
                .pickerStyle(.menu)
            } footer: {
                Text("Styled ASS/SSA subtitles (typical for anime) keep their own fonts, colours and positions unless you choose Force my style or Plain text.")
            }
        }
        .navigationTitle("Subtitles")
    }

    private func preview(_ s: AppSettings) -> some View {
        ZStack(alignment: .bottom) {
            LinearGradient(colors: [.indigo, .black], startPoint: .top, endPoint: .bottom)
            Text("The quick brown fox jumps.")
                .font(.system(size: 17 * s.subtitleSize, weight: s.subtitleBold ? .bold : .regular))
                .foregroundStyle(s.subtitleColor.color)
                .shadow(color: .black, radius: s.subtitleBackground == .shadow ? 3 : 1)
                .padding(.horizontal, 6)
                .background { if s.subtitleBackground == .box { Color.black.opacity(0.6) } }
                .padding(.bottom, 12)
        }
        .frame(height: 110)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .listRowInsets(EdgeInsets())
    }
}

struct ForYouSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var keyStatus: String?
    @State private var draft = ""
    @State private var checking = false
    var body: some View {
        @Bindable var s = model.settings
        Form {
            Section {
                if !s.tmdbKey.isEmpty && draft.isEmpty {
                    LabeledContent("Saved key", value: Self.masked(s.tmdbKey))
                }
                SecureField(s.tmdbKey.isEmpty ? "TMDB API key or read access token" : "Paste a new key to replace it", text: $draft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .keyboardDoneBar()
                Button {
                    Keyboard.dismiss()
                    Task { await check() }
                } label: {
                    HStack { Text(draft.isEmpty ? "Check saved key" : "Check and save"); if checking { Spacer(); ProgressView() } }
                }
                .disabled((draft.isEmpty && s.tmdbKey.isEmpty) || checking)
                if let keyStatus { Text(keyStatus).font(.footnote).foregroundStyle(.secondary) }
            } header: { Text("TMDB") } footer: {
                Text("For You looks for new titles on TMDB (free key from themoviedb.org → Settings → API). Your library itself keeps using Jellyfin's own metadata.")
            }
            Section {
                Toggle("On-device AI ranking", isOn: $s.useOnDeviceAI)
                    .onChange(of: s.useOnDeviceAI) { _, _ in model.reco.listChanged() }
                Toggle("Count shows I'm watching as liked", isOn: $s.includeWatchingAsLiked)
                    .onChange(of: s.includeWatchingAsLiked) { _, _ in model.reco.listChanged() }
                Button("Rebuild picks now") {
                    Task {
                        await model.reco.build(force: true)
                        await model.discovery.build(model.reco.currentSourceId, genre: nil)
                    }
                }
                .disabled(model.reco.isBuilding)
                Button("Reset \"Not for me\" on For You picks") { Task { await model.clearExternal(.notforme) } }
                    .disabled(model.externalNotForMe.isEmpty)
                LabeledContent("AI explanations", value: explainer)
            } footer: {
                Text("For You never suggests anything already on your server: titles are matched by the TMDB, IMDb and TVDB ids Jellyfin stored, then by title and year. Your taste comes from what you finished, favourited or are watching on your server (the chosen library counts most), what you gave up on, and what you marked Not for me. The AI reads your library with read-only requests: it can't change, move or delete anything. My List, Not for me, Already seen and your settings are saved in your account's private JellyReco storage on your server, so they follow you to every device. The on-device AI step pauses in Low Power Mode or when the phone is hot.")
            }
            Section("Libraries offered") {
                ForEach(model.reco.sources.filter { $0.id != RecoSource.all }) { src in
                    LabeledContent(src.name, value: src.id == model.reco.currentSourceId ? "Selected" : "")
                }
            }
        }
        .navigationTitle("For You")
    }

    private var explainer: String {
        switch PickExplainer.shared.availability {
        case .available: return "Apple Intelligence"
        case .unavailable: return "Unavailable"
        }
    }
}

extension ForYouSettingsView {
    static func masked(_ key: String) -> String {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard k.count > 8 else { return String(repeating: "•", count: k.count) }
        return "\(k.prefix(4))…\(k.suffix(4)) (\(k.count > 40 ? "read access token" : "API key"))"
    }

    func check() async {
        checking = true
        defer { checking = false }
        let candidate = draft.isEmpty ? model.settings.tmdbKey : draft
        do {
            try await TMDBClient(key: candidate).validate()
            if !draft.isEmpty {
                model.settings.tmdbKey = candidate.components(separatedBy: .whitespacesAndNewlines).joined()
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                draft = ""
                keyStatus = "Key works and is saved. For You is building your picks."
            } else {
                keyStatus = "Key works."
                model.discovery.keyChanged()
            }
        } catch {
            keyStatus = error.localizedDescription
        }
    }
}
