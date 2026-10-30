import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmSignOut = false
    @State private var showQuickConnectApprove = false
    @State private var showPassword = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        UserAvatar(serverURL: model.client?.baseURL, userId: model.user?.id ?? "",
                                   tag: model.user?.primaryImageTag, size: 54)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.user?.name ?? "…").font(.headline)
                            Text(model.serverName).font(.subheadline).foregroundStyle(.secondary)
                            if model.isAdmin { Text("Administrator").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent) }
                        }
                    }
                    NavigationLink { AccountsView() } label: { Label("Servers & users", systemImage: "person.2.fill") }
                    Button { showQuickConnectApprove = true } label: { Label("Approve a Quick Connect code", systemImage: "qrcode") }
                    Button { showPassword = true } label: { Label("Change password", systemImage: "key.fill") }
                    Button(role: .destructive) { confirmSignOut = true } label: {
                        Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right").foregroundStyle(.red)
                    }
                }

                if model.isAdmin {
                    Section {
                        NavigationLink { AdminDashboardView() } label: {
                            Label("Server dashboard", systemImage: "server.rack")
                        }
                    } footer: {
                        Text("Active sessions, scheduled tasks, users, devices, API keys, logs, activity and libraries.")
                    }
                }

                Section("Playback") {
                    NavigationLink { PlayerSettingsView() } label: { Label("Video player", systemImage: "play.rectangle.fill") }
                    NavigationLink { SubtitleAudioSettingsView() } label: { Label("Subtitles & audio", systemImage: "captions.bubble.fill") }
                    NavigationLink { QualitySettingsView() } label: { Label("Streaming quality", systemImage: "antenna.radiowaves.left.and.right") }
                    NavigationLink { GestureSettingsView() } label: { Label("Gestures", systemImage: "hand.draw.fill") }
                }

                Section("Browsing") {
                    NavigationLink { HomeSettingsView() } label: { Label("Home", systemImage: "house.fill") }
                    NavigationLink { LibrarySettingsView() } label: { Label("Library & item pages", systemImage: "square.grid.2x2.fill") }
                    NavigationLink { AppearanceSettingsView() } label: { Label("Appearance & indicators", systemImage: "paintbrush.fill") }
                }

                Section("For You") {
                    NavigationLink { ForYouSettingsView() } label: { Label("Recommendations", systemImage: "wand.and.stars") }
                }

                Section("Privacy & storage") {
                    @Bindable var s = model.settings
                    Toggle(isOn: $s.requireFaceID) { Label("Lock with Face ID", systemImage: "faceid") }
                    Button {
                        URLCache.shared.removeAllCachedResponses()
                    } label: { Label("Clear image cache", systemImage: "photo.on.rectangle.angled") }
                }

                Section("About") {
                    LabeledContent("JellyReco", value: JellyfinClient.appVersion)
                    if let v = model.serverInfo?.version ?? model.store.currentServer?.version { LabeledContent("Server", value: "Jellyfin \(v)") }
                    LabeledContent("Player", value: "mpv (FFmpeg + libass) & AVPlayer")
                }
            }
            .navigationTitle("Settings")
            .toolbarTitleDisplayMode(.inlineLarge)
            .confirmationDialog("Sign out of \(model.serverName)?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) { model.signOutCurrentUser() }
            }
            .sheet(isPresented: $showQuickConnectApprove) { ApproveQuickConnectSheet().presentationDetents([.height(280)]) }
            .sheet(isPresented: $showPassword) { ChangePasswordSheet(userId: model.user?.id ?? "", isOwn: true) }
        }
    }
}

// MARK: - Accounts

struct AccountsView: View {
    @Environment(AppModel.self) private var model
    @State private var editingServer: SavedServer?

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
        }
        .navigationTitle("Servers & users")
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
            .buttonStyle(.glassProminent)
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

// MARK: - Player settings

struct PlayerSettingsView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var s = model.settings
        Form {
            Section {
                Picker("Player", selection: $s.playerEngine) {
                    ForEach(PlayerEngine.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Hardware decoding", isOn: $s.hardwareDecoding)
            } footer: {
                Text(s.playerEngine.footnote)
            }
            Section("Resume & jumping") {
                Stepper("Rewind on resume: \(s.resumeOffset) s", value: $s.resumeOffset, in: 0...30)
                Picker("Jump back", selection: $s.jumpBackward) {
                    ForEach([5, 10, 15, 30, 45, 60], id: \.self) { Text("\($0) s").tag($0) }
                }
                Picker("Jump forward", selection: $s.jumpForward) {
                    ForEach([5, 10, 15, 30, 45, 60, 90], id: \.self) { Text("\($0) s").tag($0) }
                }
                Picker("Default speed", selection: $s.defaultSpeed) {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0], id: \.self) { Text(String(format: "%g×", $0)).tag($0) }
                }
            }
            Section {
                Toggle("Play next episode automatically", isOn: $s.autoPlayNext)
                if s.autoPlayNext {
                    Stepper("Countdown: \(s.nextUpCountdown) s", value: $s.nextUpCountdown, in: 3...30)
                    Picker("Ask \"Still watching?\"", selection: $s.stillWatchingAfter) {
                        Text("Never").tag(0)
                        ForEach([2, 3, 4, 5, 6, 8], id: \.self) { Text("After \($0) episodes").tag($0) }
                    }
                }
            } header: { Text("Next episode") }
            Section {
                Toggle("Show skip buttons", isOn: $s.showSkipButtons)
                Toggle("Skip intros automatically", isOn: $s.autoSkipIntro)
                Toggle("Skip recaps automatically", isOn: $s.autoSkipRecap)
                Toggle("Skip credits automatically", isOn: $s.autoSkipOutro)
            } header: { Text("Intros & credits") } footer: {
                Text("Uses your server's media segments (Jellyfin 10.10+, with an intro-detection plugin).")
            }
            Section("Controls") {
                Picker("Time on the right", selection: $s.timestampStyle) {
                    ForEach(TimestampStyle.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Chapter marks on the timeline", isOn: $s.showChaptersOnSlider)
                Toggle("Thumbnail previews while scrubbing", isOn: $s.trickplayPreviews)
                Toggle("Start in landscape", isOn: $s.startInLandscape)
            }
            Section("Background") {
                Toggle("Picture in Picture when leaving the app", isOn: $s.pipAutomatically)
                Toggle("Keep playing audio in the background", isOn: $s.backgroundAudio)
            }
            Section {
                Button("Reset player settings", role: .destructive) { s.resetPlayer() }
            }
        }
        .navigationTitle("Video player")
    }
}

struct GestureSettingsView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var s = model.settings
        let vertical: [GestureAction] = [.none, .brightness, .volume, .speed, .audioOffset, .subtitleOffset]
        Form {
            Section("Swipe up/down") {
                Picker("Left side", selection: $s.gestureLeftVertical) { ForEach(vertical) { Text($0.label).tag($0) } }
                Picker("Right side", selection: $s.gestureRightVertical) { ForEach(vertical) { Text($0.label).tag($0) } }
            }
            Section("Swipe left/right") {
                Picker("Anywhere", selection: $s.gestureHorizontal) {
                    ForEach([GestureAction.none, .scrub]) { Text($0.label).tag($0) }
                }
            }
            Section("Taps") {
                Picker("Double tap", selection: $s.doubleTap) { ForEach(DoubleTapAction.allCases) { Text($0.label).tag($0) } }
                Picker("Long press", selection: $s.longPress) { ForEach(LongPressAction.allCases) { Text($0.label).tag($0) } }
                Toggle("Pinch to fill the screen", isOn: $s.pinchToFill)
            }
        }
        .navigationTitle("Gestures")
    }
}

struct SubtitleAudioSettingsView: View {
    @Environment(AppModel.self) private var model
    struct Lang: Identifiable { let id: String; let name: String }
    private let languages: [Lang] = [Lang(id: "", name: "Server default")] + [
        "eng", "jpn", "slv", "ger", "fre", "spa", "ita", "por", "rus", "chi", "kor", "hrv", "srp", "pol", "dut", "swe",
    ].map { Lang(id: $0, name: Locale.current.localizedString(forLanguageCode: $0) ?? $0) }

    var body: some View {
        @Bindable var s = model.settings
        Form {
            Section("Languages") {
                Picker("Audio", selection: $s.preferredAudioLanguage) {
                    ForEach(languages) { Text($0.name).tag($0.id) }
                }
                Picker("Subtitles", selection: $s.preferredSubtitleLanguage) {
                    ForEach(languages) { Text($0.name).tag($0.id) }
                }
                Toggle("Subtitles on by default", isOn: $s.subtitlesByDefault)
                Toggle("Prefer \"Signs & Songs\" tracks", isOn: $s.preferSignsAndSongs)
            }
            Section {
                VStack(alignment: .leading) {
                    Text("Size: \(Int(s.subtitleSize * 100))%")
                    Slider(value: $s.subtitleSize, in: 0.6...2.0, step: 0.05)
                }
                Picker("Colour", selection: $s.subtitleColor) { ForEach(SubtitleColor.allCases) { Text($0.label).tag($0) } }
                Picker("Background", selection: $s.subtitleBackground) { ForEach(SubtitleBackground.allCases) { Text($0.label).tag($0) } }
                Toggle("Bold", isOn: $s.subtitleBold)
                VStack(alignment: .leading) {
                    Text("Vertical position: \(s.subtitlePosition)%")
                    Slider(value: Binding(get: { Double(s.subtitlePosition) }, set: { s.subtitlePosition = Int($0) }), in: 50...100, step: 1)
                }
                Toggle("Override styled (ASS) subtitles", isOn: $s.overrideASSStyles)
                subtitlePreview(s)
            } header: { Text("Subtitle style") } footer: {
                Text("Styled ASS/SSA subtitles (typical for anime) keep their own fonts and positions unless you override them.")
            }
            Section("Audio") {
                Toggle("Normalize loudness", isOn: $s.audioNormalization)
                Toggle("Downmix to stereo", isOn: $s.stereoDownmix)
            }
        }
        .navigationTitle("Subtitles & audio")
    }

    private func subtitlePreview(_ s: AppSettings) -> some View {
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

struct QualitySettingsView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var s = model.settings
        Form {
            Section {
                Picker("On Wi-Fi", selection: $s.maxBitrate) { ForEach(MaxBitrate.allCases) { Text($0.label).tag($0) } }
                Picker("On cellular", selection: $s.cellularBitrate) { ForEach(MaxBitrate.allCases) { Text($0.label).tag($0) } }
            } header: { Text("Maximum bitrate") } footer: {
                Text("Files above the limit are converted by your server. \"Maximum\" always plays the original file.")
            }
            Section {
                Picker("Compatibility", selection: $s.compatibility) {
                    ForEach(CompatibilityProfile.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Allow server conversion", isOn: $s.allowTranscoding)
            } footer: {
                Text("With the mpv player almost nothing needs converting. \"Most compatible\" asks the server for H.264/AAC; \"Direct play only\" never converts.")
            }
        }
        .navigationTitle("Streaming quality")
    }
}

struct HomeSettingsView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var s = model.settings
        Form {
            Section("Sections") {
                Toggle("Continue Watching", isOn: $s.homeShowContinue)
                Toggle("Next Up", isOn: $s.homeShowNextUp)
                Toggle("Combine Continue Watching and Next Up", isOn: $s.homeMergeNextUp)
                Toggle("Picked for you", isOn: $s.homeShowPicks)
                Toggle("Recently added", isOn: $s.homeShowLatest)
            }
            Section("Next Up") {
                Toggle("Include rewatching", isOn: $s.nextUpRewatching)
                Picker("Hide shows not watched for", selection: $s.nextUpMaxDays) {
                    Text("Never hide").tag(0)
                    ForEach([7, 14, 30, 60, 90, 180, 365], id: \.self) { Text("\($0) days").tag($0) }
                }
            }
            Section("Recently added rows") {
                ForEach(model.libraries) { lib in
                    Toggle(lib.displayName, isOn: Binding(
                        get: { !s.hiddenLatestLibraries.contains(lib.id) },
                        set: { on in if on { s.hiddenLatestLibraries.remove(lib.id) } else { s.hiddenLatestLibraries.insert(lib.id) } }))
                }
            }
        }
        .navigationTitle("Home")
        .onDisappear { model.bumpContent() }
    }
}

struct LibrarySettingsView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var s = model.settings
        Form {
            Section("Library") {
                Picker("Layout", selection: $s.libraryLayout) {
                    Text("Grid").tag(LibraryLayout.grid)
                    Text("List").tag(LibraryLayout.list)
                }
                Picker("Posters", selection: $s.libraryPosterStyle) { ForEach(PosterStyle.allCases) { Text($0.label).tag($0) } }
                Stepper("Columns: \(s.gridColumns)", value: $s.gridColumns, in: 2...6)
                Toggle("Remember layout per library", isOn: $s.rememberLayoutPerLibrary)
                Toggle("A–Z letter picker", isOn: $s.showLetterPicker)
                Toggle("Random button", isOn: $s.showRandomButton)
            }
            Section("Item pages") {
                Toggle("Show missing episodes", isOn: $s.showMissingEpisodes)
                Toggle("Hide spoilers of unwatched episodes", isOn: $s.hideSpoilers)
            }
        }
        .navigationTitle("Library & item pages")
    }
}

struct AppearanceSettingsView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var s = model.settings
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $s.appearance) { ForEach(AppearanceMode.allCases) { Text($0.label).tag($0) } }
                Toggle("Titles under posters", isOn: $s.showPosterLabels)
                Toggle("Match % on posters", isOn: $s.showRatingBadges)
            }
            Section("Indicators") {
                Toggle("Watch progress", isOn: $s.showProgressIndicator)
                Toggle("Unwatched episode count", isOn: $s.showUnplayedIndicator)
                Toggle("Watched tick", isOn: $s.showPlayedIndicator)
                Toggle("Favourite heart", isOn: $s.showFavoriteIndicator)
            }
        }
        .navigationTitle("Appearance")
    }
}

struct ForYouSettingsView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var s = model.settings
        Form {
            Section {
                Toggle("On-device AI ranking", isOn: $s.useOnDeviceAI)
                    .onChange(of: s.useOnDeviceAI) { _, _ in model.reco.listChanged() }
                Toggle("Count shows I'm watching as liked", isOn: $s.includeWatchingAsLiked)
                    .onChange(of: s.includeWatchingAsLiked) { _, _ in model.reco.listChanged() }
                Button("Rebuild picks now") { Task { await model.reco.build(force: true) } }
                    .disabled(model.reco.isBuilding)
                Button("Reset \"Not for me\" (\(s.dismissedPicks.count))") { model.reco.resetDismissed() }
                    .disabled(s.dismissedPicks.isEmpty)
                LabeledContent("AI explanations", value: explainer)
            } footer: {
                Text("Picks come only from your own libraries. What you finished, favourited or are watching pulls toward similar titles; what you abandoned or marked \"Not for me\" pushes away. Jellyfin's similar-items data and, when on, Apple's on-device language model comparing each overview are blended in. Nothing leaves your iPhone except normal requests to your server. The AI step pauses in Low Power Mode or when the phone is hot.")
            }
            Section("Libraries offered") {
                ForEach(model.reco.sources.filter { $0.id != RecoSource.all }) { src in
                    LabeledContent(src.name, value: src.id == model.reco.currentSourceId ? "Selected" : "")
                }
            }
        }
        .navigationTitle("Recommendations")
    }

    private var explainer: String {
        switch PickExplainer.shared.availability {
        case .available: return "Apple Intelligence"
        case .unavailable: return "Unavailable"
        }
    }
}
