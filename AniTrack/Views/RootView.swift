import SwiftUI
import AuthenticationServices

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if !model.didBootstrap {
                ProgressView()
            } else if model.mode == .none {
                WelcomeView()
            } else {
                MainTabView()
            }
        }
        .onOpenURL { url in
            if url.scheme == AniListAuth.callbackScheme { model.handleAuthCallback(url) }
        }
        .alert("Something went wrong",
               isPresented: Binding(get: { model.errorMessage != nil },
                                    set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

enum AppTab: Hashable {
    case home, forYou, lists, profile, discover
}

struct MainTabView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.selectedTab) {
            Tab("Home", systemImage: "house.fill", value: AppTab.home) { HomeView() }
            Tab("For You", systemImage: "wand.and.stars", value: AppTab.forYou) { ForYouView() }
            Tab("Lists", systemImage: "list.bullet.rectangle.portrait.fill", value: AppTab.lists) { LibraryView() }
            Tab("Profile", systemImage: "person.crop.circle.fill", value: AppTab.profile) { SettingsView() }
            // Search role: iOS shows this as the separate floating glass search button.
            Tab("Discover", systemImage: "magnifyingglass", value: AppTab.discover, role: .search) { DiscoverView() }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .task { await model.loadCategories() }
        .sheet(item: $model.ratePrompt) { media in
            RatePromptView(media: media)
                .presentationDetents([.height(360)])
        }
    }
}

struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    @State private var clientId = ""
    @State private var username = ""
    @State private var isWorking = false
    @State private var showUsernameField = false

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 12) {
                    Image("Logo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 104, height: 104)
                        .padding(14)
                        .glassEffect(.regular.tint(Theme.accent.opacity(0.25)), in: .circle)
                    Text("AniTrack").font(.largeTitle.bold())
                    Text("Track, discover and get personal picks from your AniList.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 56)

                VStack(alignment: .leading, spacing: 10) {
                    Text("AniList Client ID").font(.headline)
                    TextField("e.g. 12345", text: $clientId)
                        .keyboardType(.numberPad)
                        .padding(14)
                        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    Text("Create one once at anilist.co/settings/developer with the redirect URL **\(AniListAuth.redirectURL)**. See the README for steps.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                GlassEffectContainer(spacing: 16) {
                    VStack(spacing: 12) {
                        Button {
                            Task { await logIn() }
                        } label: {
                            Label("Log in with AniList", systemImage: "person.badge.key.fill")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                        .disabled(isWorking || AniListAuth.authorizeURL(clientId: clientId) == nil)

                        Button {
                            withAnimation(.bouncy) { showUsernameField.toggle() }
                        } label: {
                            Label("Just browse with my username", systemImage: "eye")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                        .controlSize(.large)
                    }
                }

                if showUsernameField {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("AniList username", text: $username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(14)
                            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        Button {
                            Task {
                                isWorking = true
                                await model.useUsername(username)
                                isWorking = false
                            }
                        } label: {
                            Text("Continue read-only").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                        .controlSize(.large)
                        .disabled(isWorking || username.trimmingCharacters(in: .whitespaces).isEmpty)
                        Text("Your profile must be public. You can't edit your list in this mode.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                if isWorking { ProgressView() }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.interactively)
        .background {
            // Soft colorful backdrop so the glass has something to refract.
            LinearGradient(colors: [Theme.accent.opacity(0.35), Theme.pink.opacity(0.25), Color(.systemBackground)],
                           startPoint: .topLeading, endPoint: .bottom)
                .ignoresSafeArea()
        }
        .onAppear { clientId = model.settings.clientId }
    }

    private func logIn() async {
        model.settings.clientId = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = AniListAuth.authorizeURL(clientId: model.settings.clientId) else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let callback = try await webAuthenticationSession.authenticate(
                using: url,
                callbackURLScheme: AniListAuth.callbackScheme
            )
            model.handleAuthCallback(callback)
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            // User closed the sheet; nothing to do.
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }
}
