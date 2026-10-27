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
            // A regular tab (not the .search role, which iOS always pins to the far right).
            Tab("Discover", systemImage: "magnifyingglass", value: AppTab.discover) { DiscoverView() }
            Tab("Lists", systemImage: "list.bullet.rectangle.portrait.fill", value: AppTab.lists) { LibraryView() }
            Tab("Profile", systemImage: "person.crop.circle.fill", value: AppTab.profile) { SettingsView() }
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

    private enum Field { case clientId, username }
    @FocusState private var focused: Field?

    var body: some View {
        // NavigationStack (bar hidden) so the keyboard's Done bar has a toolbar to live in.
        NavigationStack {
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
                        .focused($focused, equals: .clientId)
                        .padding(14)
                        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    Text("Create one once at anilist.co/settings/developer with the redirect URL **\(AniListAuth.redirectURL)**. See the README for steps.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                GlassEffectContainer(spacing: 16) {
                    VStack(spacing: 12) {
                        Button {
                            focused = nil
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
                            .focused($focused, equals: .username)
                            .submitLabel(.done)
                            .onSubmit { focused = nil }
                            .padding(14)
                            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        Button {
                            focused = nil
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
            .frame(maxWidth: .infinity)
            // Tap on any empty spot of the page closes the keyboard (buttons and fields still win).
            .contentShape(Rectangle())
            .onTapGesture { focused = nil }
        }
        .scrollDismissesKeyboard(.interactively)
        .background {
            // Soft colorful backdrop so the glass has something to refract.
            // Tapping empty space anywhere closes the keyboard.
            LinearGradient(colors: [Theme.accent.opacity(0.35), Theme.pink.opacity(0.25), Color(.systemBackground)],
                           startPoint: .topLeading, endPoint: .bottom)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { focused = nil }
        }
        .toolbar(.hidden, for: .navigationBar)
        .toolbar {
            // The number pad has no Return key: give it a Done button.
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focused = nil }
                    .fontWeight(.semibold)
            }
        }
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
