import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var pastedToken = ""
    private enum Field { case clientId, token }
    @FocusState private var focused: Field?
    @State private var confirmLogout = false

    var body: some View {
        @Bindable var settings = model.settings
        NavigationStack {
            Form {
                Section("Account") {
                    if let viewer = model.viewer {
                        ProfileHeader(viewer: viewer)
                    }
                    switch model.mode {
                    case .loggedIn:
                        Label("Logged in with AniList", systemImage: "checkmark.seal.fill")
                    case .username(let name):
                        Label("Read-only as \(name)", systemImage: "eye")
                    case .none:
                        EmptyView()
                    }
                    Button("Log out", role: .destructive) { confirmLogout = true }
                }

                Section("Display") {
                    Picker("Titles", selection: $settings.titleLanguage) {
                        ForEach(TitleLanguage.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("Hide Chinese animation", isOn: $settings.hideChinese)
                        .onChange(of: settings.hideChinese) { _, _ in model.invalidatePicks() }
                }

                Section {
                    Toggle("On-device AI ranking", isOn: $settings.useOnDeviceAI)
                        .onChange(of: settings.useOnDeviceAI) { _, _ in model.invalidatePicks() }
                    Toggle("Include unreleased shows", isOn: $settings.includeUnreleased)
                        .onChange(of: settings.includeUnreleased) { _, _ in model.invalidatePicks() }
                    Button("Rebuild picks now") {
                        Task { await model.generateRecommendations(force: true) }
                    }
                    .disabled(model.isLoadingFeed(nil))
                    Button("Reset \"Not for me\" (\(settings.dismissedPicks.count))") {
                        model.resetDismissedPicks()
                    }
                    .disabled(settings.dismissedPicks.isEmpty || model.isResettingNotForMe)
                    LabeledContent("AI explanations", value: explainerStatus)
                } header: {
                    Text("For You picks")
                } footer: {
                    Text("Picks combine fan recommendations from the shows you rated highly, your favorite genres and tags, and (when on-device AI is on) the meaning of each synopsis compared on your iPhone with Apple's Natural Language models. Nothing leaves your device except normal AniList requests. \"Not for me\" is saved to your AniList as a private, hidden custom list, so it survives reinstalls and other devices (in read-only mode it stays on this iPhone). Picks are saved and only rebuilt when your list changes, each synopsis is analyzed once and cached, and the AI step pauses in Low Power Mode or when your iPhone is hot, so this costs almost no battery day to day.")
                }

                Section {
                    // Numbers keyboard *with* a Done key (the number pad has none, and iOS doesn't
                    // always show the toolbar Done bar), so the keyboard can always be closed.
                    TextField("AniList client ID", text: $settings.clientId)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit { focused = nil }
                        .onChange(of: settings.clientId) { _, new in
                            let digits = new.filter(\.isNumber)
                            if digits != new { settings.clientId = digits }
                        }
                        .focused($focused, equals: .clientId)
                    SecureField("Paste an access token (optional)", text: $pastedToken)
                        .focused($focused, equals: .token)
                        .submitLabel(.done)
                        .onSubmit { focused = nil }
                    Button("Use token") {
                        focused = nil
                        Task {
                            await model.useToken(pastedToken)
                            pastedToken = ""
                        }
                    }
                    .disabled(pastedToken.trimmingCharacters(in: .whitespaces).isEmpty)
                } header: {
                    Text("AniList API")
                } footer: {
                    Text("Redirect URL for your AniList client: \(AniListAuth.redirectURL). Tokens are stored in the iOS Keychain and last one year.")
                }

                Section("About") {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                    Text("AniTrack is an unofficial client and isn't affiliated with AniList.co.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Profile")
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focused = nil }
                        .fontWeight(.semibold)
                }
            }
            .confirmationDialog("Log out of AniTrack?", isPresented: $confirmLogout, titleVisibility: .visible) {
                Button("Log out", role: .destructive) { model.logOut() }
            }
        }
    }

    private var explainerStatus: String {
        switch PickExplainer.shared.availability {
        case .available: return "Apple Intelligence ready"
        case .unavailable: return "Unavailable"
        }
    }
}
