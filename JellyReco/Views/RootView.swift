import LocalAuthentication
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            switch model.phase {
            case .launching:
                ProgressView()
            case .signedOut:
                SignInFlow()
            case .ready:
                MainTabView()
            }
        }
        .overlay {
            if model.isLocked { LockView() }
        }
        .fullScreenCover(item: $model.playback) { request in
            PlayerScreen(request: request)
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

struct MainTabView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.selectedTab) {
            Tab("Home", systemImage: "house.fill", value: AppTab.home) { HomeView() }
            Tab("For You", systemImage: "wand.and.stars", value: AppTab.forYou) { ForYouView() }
            Tab("Library", systemImage: "square.grid.2x2.fill", value: AppTab.library) { LibrariesView() }
            Tab("Search", systemImage: "magnifyingglass", value: AppTab.search) { SearchView() }
            Tab("Settings", systemImage: "gearshape.fill", value: AppTab.settings) { SettingsView() }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
    }
}

// MARK: - Face ID lock

struct LockView: View {
    @Environment(AppModel.self) private var model
    @State private var failed = false

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
            VStack(spacing: 18) {
                Image("Logo").resizable().scaledToFit().frame(width: 84, height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                Text("JellyReco is locked").font(.title3.bold())
                Button {
                    Task { await unlock() }
                } label: {
                    Label("Unlock", systemImage: "faceid").frame(maxWidth: 220)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                if failed { Text("Couldn't verify. Try again.").font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .task { await unlock() }
    }

    private func unlock() async {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            model.isLocked = false   // no passcode set: nothing to lock with
            return
        }
        do {
            if try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock JellyReco") {
                withAnimation { model.isLocked = false }
            }
        } catch {
            failed = true
        }
    }
}

// MARK: - Sign-in

struct SignInFlow: View {
    @Environment(AppModel.self) private var model
    @State private var address = ""
    @State private var isConnecting = false
    @State private var connectError: String?
    @State private var connected: ConnectedServer?
    @FocusState private var focused: Bool

    struct ConnectedServer: Hashable {
        let url: URL
        let info: PublicSystemInfo
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    VStack(spacing: 12) {
                        Image("Logo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 104, height: 104)
                            .clipShape(Circle())
                            .padding(10)
                            .glassEffect(.regular.tint(Theme.accent.opacity(0.25)), in: .circle)
                        Text("JellyReco").font(.largeTitle.bold())
                        Text("Your Jellyfin library, every format, with picks made for you.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 48)

                    if !model.store.servers.filter({ !$0.users.isEmpty }).isEmpty {
                        savedAccounts
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Server address").font(.headline)
                        TextField("e.g. 192.168.1.20:8096 or jellyfin.example.com", text: $address)
                            .keyboardType(.URL)
                            .textContentType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.go)
                            .onSubmit { Task { await connect() } }
                            .focused($focused)
                            .padding(14)
                            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        if let connectError {
                            Text(connectError).font(.footnote).foregroundStyle(.red)
                        }
                    }

                    Button {
                        Task { await connect() }
                    } label: {
                        Group {
                            if isConnecting { ProgressView() } else { Label("Connect", systemImage: "server.rack") }
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .disabled(isConnecting || JellyfinClient.normalize(address) == nil)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
            .scrollDismissesKeyboard(.interactively)
            .background {
                LinearGradient(colors: [Theme.accent.opacity(0.35), Theme.pink.opacity(0.25), Color(.systemBackground)],
                               startPoint: .topLeading, endPoint: .bottom)
                    .ignoresSafeArea()
                    .onTapGesture { focused = false }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(item: $connected) { server in
                UserPickerView(url: server.url, info: server.info)
            }
        }
    }

    private var savedAccounts: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Signed-in accounts").font(.headline)
            ForEach(model.store.servers) { server in
                ForEach(server.users) { user in
                    Button {
                        model.switchTo(server: server, user: user)
                    } label: {
                        HStack(spacing: 12) {
                            UserAvatar(serverURL: server.url, userId: user.id, tag: user.imageTag, size: 40)
                            VStack(alignment: .leading) {
                                Text(user.name).font(.headline)
                                Text(server.name).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                        .padding(12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
        }
    }

    private func connect() async {
        focused = false
        guard let url = JellyfinClient.normalize(address) else { return }
        isConnecting = true
        connectError = nil
        defer { isConnecting = false }
        // Try what was typed; if no scheme was given and http fails, try https (and vice versa).
        var candidates = [url]
        if !address.lowercased().hasPrefix("http") {
            if var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                comps.scheme = "https"
                if let https = comps.url { candidates.append(https) }
            }
        }
        var lastError: Error?
        for candidate in candidates {
            do {
                let info = try await JellyfinClient(baseURL: candidate).publicInfo()
                guard info.productName?.lowercased().contains("jellyfin") ?? true else {
                    connectError = "That's not a Jellyfin server."
                    return
                }
                connected = ConnectedServer(url: candidate, info: info)
                return
            } catch {
                lastError = error
            }
        }
        connectError = "Couldn't reach the server (\(lastError?.localizedDescription ?? "unknown error")). Check the address and that your iPhone is on the right network."
    }
}

struct UserAvatar: View {
    let serverURL: URL?
    let userId: String
    let tag: String?
    var size: CGFloat = 44

    var body: some View {
        Group {
            if let serverURL, let tag {
                RemoteImage(url: JellyfinClient(baseURL: serverURL).userImageURL(userId: userId, tag: tag),
                            placeholderSymbol: "person.fill")
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.45))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.fill.tertiary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

struct UserPickerView: View {
    @Environment(AppModel.self) private var model
    let url: URL
    let info: PublicSystemInfo

    @State private var users: [UserDto] = []
    @State private var quickConnect = false
    @State private var username = ""
    @State private var password = ""
    @State private var isWorking = false
    @State private var error: String?
    @State private var showQuickConnect = false
    @FocusState private var focus: Field?
    private enum Field { case user, password }

    var body: some View {
        Form {
            Section {
                LabeledContent("Server", value: info.serverName ?? url.host ?? "")
                if let v = info.version { LabeledContent("Version", value: v) }
            }
            if !users.isEmpty {
                Section("Who's watching?") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            ForEach(users) { user in
                                Button {
                                    username = user.name ?? ""
                                    password = ""
                                    if user.hasPassword == false {
                                        Task { await signIn() }
                                    } else {
                                        focus = .password
                                    }
                                } label: {
                                    VStack(spacing: 6) {
                                        UserAvatar(serverURL: url, userId: user.id, tag: user.primaryImageTag, size: 64)
                                        Text(user.name ?? "").font(.caption).lineLimit(1)
                                    }
                                    .frame(width: 76)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
            Section("Sign in") {
                TextField("Username", text: $username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .user)
                    .submitLabel(.next)
                    .onSubmit { focus = .password }
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .focused($focus, equals: .password)
                    .submitLabel(.go)
                    .onSubmit { Task { await signIn() } }
                Button {
                    Task { await signIn() }
                } label: {
                    HStack {
                        Text("Sign in").fontWeight(.semibold)
                        if isWorking { Spacer(); ProgressView() }
                    }
                }
                .disabled(username.isEmpty || isWorking)
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            if quickConnect {
                Section {
                    Button { showQuickConnect = true } label: {
                        Label("Use Quick Connect", systemImage: "qrcode")
                    }
                } footer: {
                    Text("Get a code here, then approve it from the Jellyfin web dashboard or another app where you're signed in.")
                }
            }
        }
        .navigationTitle(info.serverName ?? "Sign in")
        .task {
            let client = JellyfinClient(baseURL: url)
            users = (try? await client.publicUsers()) ?? []
            quickConnect = await client.quickConnectEnabled()
        }
        .sheet(isPresented: $showQuickConnect) {
            QuickConnectSheet(url: url, info: info).presentationDetents([.medium])
        }
    }

    private func signIn() async {
        isWorking = true
        error = nil
        defer { isWorking = false }
        do {
            let result = try await JellyfinClient(baseURL: url).authenticate(username: username, password: password)
            model.signIn(server: info, url: url, result: result)
        } catch JellyfinError.http(401, _) {
            error = "Wrong username or password."
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct QuickConnectSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let url: URL
    let info: PublicSystemInfo
    @State private var code: String?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 20) {
            Text("Quick Connect").font(.title2.bold())
            if let code {
                Text(code)
                    .font(.system(size: 44, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 24).padding(.vertical, 12)
                    .glassEffect(.regular.tint(Theme.accent.opacity(0.2)), in: RoundedRectangle(cornerRadius: 18))
                    .textSelection(.enabled)
                Text("Enter this code in Jellyfin under Profile → Quick Connect on a device where you're signed in.")
                    .multilineTextAlignment(.center).font(.subheadline).foregroundStyle(.secondary)
                ProgressView()
            } else if let error {
                Text(error).foregroundStyle(.red)
            } else {
                ProgressView()
            }
        }
        .padding(28)
        .task { await run() }
    }

    private func run() async {
        let client = JellyfinClient(baseURL: url)
        do {
            let start = try await client.quickConnectInitiate()
            guard let secret = start.secret else { throw JellyfinError.message("Quick Connect didn't start.") }
            code = start.code
            for _ in 0..<120 {   // ~10 minutes
                try await Task.sleep(nanoseconds: 5_000_000_000)
                let state = try await client.quickConnectState(secret: secret)
                if state.authenticated == true {
                    let result = try await client.authenticateQuickConnect(secret: secret)
                    model.signIn(server: info, url: url, result: result)
                    dismiss()
                    return
                }
            }
            error = "The code expired. Try again."
        } catch {
            if !AppModel.isCancellation(error) { self.error = error.localizedDescription }
        }
    }
}
