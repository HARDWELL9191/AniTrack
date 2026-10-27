import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var pastedToken = ""
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
                }

                Section {
                    Toggle("On-device AI ranking", isOn: $settings.useOnDeviceAI)
                    Toggle("Include unreleased shows", isOn: $settings.includeUnreleased)
                    Button("Rebuild picks now") {
                        Task { await model.generateRecommendations(force: true) }
                    }
                    .disabled(model.isLoadingFeed(nil))
                    Button("Reset \"Not for me\" (\(settings.dismissedPicks.count))") {
                        model.resetDismissedPicks()
                    }
                    .disabled(settings.dismissedPicks.isEmpty)
                    LabeledContent("AI explanations", value: explainerStatus)
                } header: {
                    Text("For You picks")
                } footer: {
                    Text("Picks combine fan recommendations from the shows you rated highly, your favorite genres and tags, and (when on-device AI is on) the meaning of each synopsis compared on your iPhone with Apple's Natural Language models. Nothing leaves your device except normal AniList requests. Picks are saved and only rebuilt when your list changes, each synopsis is analyzed once and cached, and the AI step pauses in Low Power Mode or when your iPhone is hot, so this costs almost no battery day to day.")
                }

                Section {
                    TextField("AniList client ID", text: $settings.clientId)
                        .keyboardType(.numberPad)
                    SecureField("Paste an access token (optional)", text: $pastedToken)
                    Button("Use token") {
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
