import SwiftUI

/// The server Dashboard (admins only), organised like jellyfin-web's and the desktop client's:
/// Server, Libraries, Playback, Devices, Live TV, Plugins, Advanced — same names, same pages.
struct AdminDashboardView: View {
    var body: some View {
        List {
            Section("Server") {
                NavigationLink { DashboardOverviewView() } label: { Label("Dashboard", systemImage: "gauge.with.dots.needle.67percent") }
                page(ServerSettingsCatalog.general)
                page(ServerSettingsCatalog.branding)
                NavigationLink { UsersAdminView() } label: { Label("Users", systemImage: "person.3.fill") }
            }
            Section("Libraries") {
                NavigationLink { AdminLibrariesView() } label: { Label("Libraries", systemImage: "books.vertical.fill") }
                page(ServerSettingsCatalog.display)
                page(ServerSettingsCatalog.metadata)
                page(ServerSettingsCatalog.nfo)
            }
            Section("Playback") {
                page(ServerSettingsCatalog.transcoding)
                page(ServerSettingsCatalog.resume)
                page(ServerSettingsCatalog.streaming)
                page(ServerSettingsCatalog.trickplay)
            }
            Section("Devices") {
                NavigationLink { DevicesView() } label: { Label("Devices", systemImage: "iphone.gen3") }
                NavigationLink { ActivityLogView() } label: { Label("Activity", systemImage: "list.bullet.rectangle") }
            }
            Section("Live TV") {
                NavigationLink { LiveTVSetupView() } label: { Label("Live TV", systemImage: "antenna.radiowaves.left.and.right") }
                page(ServerSettingsCatalog.dvr)
            }
            Section("Plugins") {
                NavigationLink { PluginsView() } label: { Label("My plugins", systemImage: "puzzlepiece.extension.fill") }
                NavigationLink { PluginCatalogView() } label: { Label("Catalog", systemImage: "square.and.arrow.down.fill") }
                NavigationLink { PluginRepositoriesView() } label: { Label("Repositories", systemImage: "link") }
            }
            Section("Advanced") {
                page(ServerSettingsCatalog.networking)
                NavigationLink { APIKeysView() } label: { Label("API keys", systemImage: "key.horizontal.fill") }
                NavigationLink { BackupsView() } label: { Label("Backups", systemImage: "archivebox.fill") }
                NavigationLink { ServerLogsView() } label: { Label("Logs", systemImage: "terminal.fill") }
                NavigationLink { ScheduledTasksView() } label: { Label("Scheduled tasks", systemImage: "clock.arrow.2.circlepath") }
            }
        }
        .navigationTitle("Dashboard")
    }

    private func page(_ p: ConfigPage) -> some View {
        NavigationLink { ConfigPageView(page: p) } label: { Label(p.title, systemImage: p.symbol) }
    }
}

/// jellyfin-web's Dashboard overview: the server, what's playing, and restart / shut down / scan.
struct DashboardOverviewView: View {
    @Environment(AppModel.self) private var model
    @State private var info: SystemInfo?
    @State private var sessions: [SessionInfo] = []
    @State private var confirm: ServerAction?

    enum ServerAction: String, Identifiable {
        case restart, shutdown, scan
        var id: String { rawValue }
    }

    var body: some View {
        List {
            Section("Server") {
                if let info {
                    LabeledContent("Server", value: info.serverName ?? "")
                    LabeledContent("Version", value: info.version ?? "")
                    if let os = info.operatingSystemDisplayName ?? info.operatingSystem {
                        LabeledContent("System", value: os + (info.systemArchitecture.map { " · \($0)" } ?? ""))
                    }
                    if info.hasPendingRestart == true {
                        Label("Restart needed to apply changes", systemImage: "exclamationmark.arrow.circlepath").foregroundStyle(.orange)
                    }
                    if info.hasUpdateAvailable == true {
                        Label("Server update available", systemImage: "arrow.down.circle")
                    }
                } else {
                    ProgressView()
                }
            }
            Section("Activity") {
                NavigationLink { SessionsView() } label: {
                    LabeledContent { Text("\(sessions.filter { $0.nowPlayingItem != nil }.count) playing") } label: {
                        Label("Active sessions", systemImage: "play.tv.fill")
                    }
                }
            }
            Section {
                Button { confirm = .scan } label: { Label("Scan all libraries", systemImage: "arrow.triangle.2.circlepath") }
                Button { confirm = .restart } label: { Label("Restart server", systemImage: "restart") }
                Button(role: .destructive) { confirm = .shutdown } label: {
                    Label("Shut down server", systemImage: "power").foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Dashboard")
        .refreshable { await load() }
        .task { await load() }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            titleVisibility: .visible) {
            Button(confirmTitle, role: confirm == .shutdown ? .destructive : nil) {
                if let action = confirm { Task { await run(action) } }
            }
        }
    }

    private var confirmTitle: String {
        switch confirm {
        case .restart: return "Restart server"
        case .shutdown: return "Shut down server"
        case .scan: return "Scan all libraries"
        case nil: return ""
        }
    }

    private func load() async {
        guard let client = model.client else { return }
        info = try? await client.get("/System/Info", as: SystemInfo.self)
        sessions = (try? await client.get("/Sessions", ["activeWithinSeconds": 960], as: [SessionInfo].self)) ?? []
    }

    private func run(_ action: ServerAction) async {
        guard let client = model.client else { return }
        do {
            switch action {
            case .restart: try await client.send("POST", "/System/Restart")
            case .shutdown: try await client.send("POST", "/System/Shutdown")
            case .scan: try await client.send("POST", "/Library/Refresh")
            }
        } catch { model.report(error) }
    }
}

// MARK: - Sessions

struct SessionsView: View {
    @Environment(AppModel.self) private var model
    @State private var sessions: [SessionInfo] = []
    @State private var messageTarget: SessionInfo?
    @State private var showIdle = false

    var body: some View {
        List {
            Toggle("Show idle devices", isOn: $showIdle)
            ForEach(shown) { s in
                SessionRow(session: s)
                    .swipeActions {
                        if s.nowPlayingItem != nil {
                            Button(role: .destructive) { Task { await command(s, "Stop") } } label: { Label("Stop", systemImage: "stop.fill") }
                            Button { Task { await command(s, s.playState?.isPaused == true ? "Unpause" : "Pause") } } label: {
                                Label("Pause", systemImage: "playpause.fill")
                            }
                            .tint(.orange)
                        }
                        Button { messageTarget = s } label: { Label("Message", systemImage: "text.bubble.fill") }
                            .tint(Theme.accent)
                    }
            }
            if shown.isEmpty { Text("Nobody's watching right now.").foregroundStyle(.secondary) }
        }
        .navigationTitle("Sessions")
        .task {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        .sheet(item: $messageTarget) { MessageSheet(session: $0).presentationDetents([.medium]) }
    }

    private var shown: [SessionInfo] {
        let list = showIdle ? sessions : sessions.filter { $0.nowPlayingItem != nil }
        return list.sorted { ($0.nowPlayingItem != nil ? 0 : 1, $0.userName ?? "") < ($1.nowPlayingItem != nil ? 0 : 1, $1.userName ?? "") }
    }

    private func load() async {
        sessions = (try? await model.client?.get("/Sessions", ["activeWithinSeconds": 960], as: [SessionInfo].self)) ?? sessions
    }

    private func command(_ s: SessionInfo, _ cmd: String) async {
        do { try await model.client?.send("POST", "/Sessions/\(s.id)/Playing/\(cmd)") } catch { model.report(error) }
        await load()
    }
}

struct SessionRow: View {
    @Environment(AppModel.self) private var model
    let session: SessionInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                UserAvatar(serverURL: model.client?.baseURL, userId: session.userId ?? "", tag: nil, size: 30)
                VStack(alignment: .leading) {
                    Text(session.userName ?? "Unknown").font(.headline)
                    Text([session.client, session.deviceName, session.remoteEndPoint].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if let item = session.nowPlayingItem {
                HStack(alignment: .top, spacing: 10) {
                    RemoteImage(url: model.client?.landscapeURL(item, width: 300))
                        .frame(width: 96, height: 54).clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.seriesName.map { "\($0) · \(item.episodeLabel ?? "")" } ?? item.displayName).font(.subheadline.weight(.semibold)).lineLimit(1)
                        if item.kind == .episode { Text(item.displayName).font(.caption).lineLimit(1) }
                        if let pos = session.playState?.positionTicks, let total = item.runTimeTicks, total > 0 {
                            ProgressView(value: Double(pos) / Double(total)).tint(Theme.accent)
                            Text("\(Fmt.clock(Fmt.seconds(pos))) / \(Fmt.clock(Fmt.seconds(total)))\(session.playState?.isPaused == true ? " · Paused" : "")")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                playMethod
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var playMethod: some View {
        let method = session.playState?.playMethod ?? "DirectPlay"
        let t = session.transcodingInfo
        VStack(alignment: .leading, spacing: 3) {
            Label(method == "Transcode" ? "Transcoding" : (method == "DirectStream" ? "Direct stream" : "Direct play"),
                  systemImage: method == "Transcode" ? "flame.fill" : "checkmark.seal.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(method == "Transcode" ? .orange : .green)
            if let t {
                Text([t.videoCodec.map { "Video \($0.uppercased())\(t.isVideoDirect == true ? " (copy)" : "")" },
                      t.audioCodec.map { "Audio \($0.uppercased())\(t.isAudioDirect == true ? " (copy)" : "")" },
                      t.bitrate.map { Fmt.bitrate($0) }, t.framerate.map { String(format: "%.0f fps", $0) },
                      t.hardwareAccelerationType.map { "HW: \($0)" },
                      t.completionPercentage.map { String(format: "%.0f%% done", $0) }]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.secondary)
                if let reasons = t.transcodeReasons, !reasons.isEmpty {
                    Text("Why: " + reasons.joined(separator: ", ")).font(.caption2).foregroundStyle(.orange)
                }
            }
        }
    }
}

struct MessageSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let session: SessionInfo
    @State private var header = "Message from the server"
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $header)
                    .keyboardDoneBar()
                TextField("Message", text: $text, axis: .vertical).lineLimit(3...6)
            }
            .navigationTitle("Message \(session.userName ?? "")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        struct Body: Encodable { var header: String; var text: String; var timeoutMs: Int }
                        Task {
                            do {
                                try await model.client?.postVoid("/Sessions/\(session.id)/Message",
                                                                 json: Body(header: header, text: text, timeoutMs: 8000))
                                dismiss()
                            } catch { model.report(error) }
                        }
                    }
                    .disabled(text.isEmpty)
                }
            }
        }
    }
}

// MARK: - Scheduled tasks

struct ScheduledTasksView: View {
    @Environment(AppModel.self) private var model
    @State private var tasks: [TaskInfo] = []

    var body: some View {
        List {
            ForEach(groups, id: \.0) { category, items in
                Section(category) {
                    ForEach(items) { task in
                        NavigationLink { TaskDetailView(task: task, reload: load) } label: { TaskRow(task: task) }
                            .swipeActions {
                                if task.state == "Running" {
                                    Button(role: .destructive) { Task { await stop(task) } } label: { Label("Stop", systemImage: "stop.fill") }
                                } else {
                                    Button { Task { await start(task) } } label: { Label("Run", systemImage: "play.fill") }.tint(.green)
                                }
                            }
                    }
                }
            }
        }
        .navigationTitle("Scheduled tasks")
        .task {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(nanoseconds: tasks.contains { $0.state == "Running" } ? 2_000_000_000 : 8_000_000_000)
            }
        }
    }

    private var groups: [(String, [TaskInfo])] {
        Dictionary(grouping: tasks.filter { $0.isHidden != true }, by: { $0.category ?? "Other" })
            .map { ($0.key, $0.value.sorted { ($0.name ?? "") < ($1.name ?? "") }) }
            .sorted { $0.0 < $1.0 }
    }

    func load() async {
        tasks = (try? await model.client?.get("/ScheduledTasks", ["isHidden": false], as: [TaskInfo].self)) ?? tasks
    }

    private func start(_ t: TaskInfo) async {
        do { try await model.client?.send("POST", "/ScheduledTasks/Running/\(t.id)") } catch { model.report(error) }
        await load()
    }

    private func stop(_ t: TaskInfo) async {
        do { try await model.client?.send("DELETE", "/ScheduledTasks/Running/\(t.id)") } catch { model.report(error) }
        await load()
    }
}

struct TaskRow: View {
    let task: TaskInfo
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(task.name ?? "Task").font(.subheadline.weight(.semibold))
                Spacer()
                if task.state == "Running" { ProgressView().controlSize(.small) }
            }
            if task.state == "Running", let p = task.currentProgressPercentage {
                ProgressView(value: p / 100).tint(Theme.accent)
            } else if let r = task.lastExecutionResult {
                Text("\(r.status ?? "") · \(r.endTimeUtc?.formatted(.relative(presentation: .named)) ?? "")")
                    .font(.caption)
                    .foregroundStyle(r.status == "Completed" ? Color.secondary : Color.orange)
            } else {
                Text("Never run").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct TaskDetailView: View {
    @Environment(AppModel.self) private var model
    @State var task: TaskInfo
    let reload: () async -> Void
    @State private var addingTrigger = false

    var body: some View {
        List {
            Section {
                if let d = task.description { Text(d).font(.subheadline) }
                Button(task.state == "Running" ? "Stop" : "Run now", systemImage: task.state == "Running" ? "stop.fill" : "play.fill") {
                    Task {
                        do {
                            try await model.client?.send(task.state == "Running" ? "DELETE" : "POST", "/ScheduledTasks/Running/\(task.id)")
                            await refresh()
                        } catch { model.report(error) }
                    }
                }
            }
            if let r = task.lastExecutionResult {
                Section("Last run") {
                    LabeledContent("Result", value: r.status ?? "")
                    if let s = r.startTimeUtc { LabeledContent("Started", value: s.formatted()) }
                    if let e = r.endTimeUtc, let s = r.startTimeUtc { LabeledContent("Took", value: Fmt.runtime(e.timeIntervalSince(s))) }
                    if let err = r.errorMessage { Text(err).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                }
            }
            Section("Triggers") {
                ForEach(Array((task.triggers ?? []).enumerated()), id: \.offset) { i, t in
                    Text(describe(t))
                        .swipeActions { Button(role: .destructive) { Task { await removeTrigger(i) } } label: { Label("Delete", systemImage: "trash") } }
                }
                Button("Add trigger", systemImage: "plus") { addingTrigger = true }
            }
        }
        .navigationTitle(task.name ?? "Task")
        .sheet(isPresented: $addingTrigger) {
            AddTriggerSheet { trigger in Task { await saveTriggers((task.triggers ?? []) + [trigger]) } }
        }
    }

    private func describe(_ t: TaskTrigger) -> String {
        switch t.type {
        case "DailyTrigger": return "Daily at \(Fmt.clock(Fmt.seconds(t.timeOfDayTicks ?? 0)))"
        case "WeeklyTrigger": return "Every \(t.dayOfWeek ?? "week") at \(Fmt.clock(Fmt.seconds(t.timeOfDayTicks ?? 0)))"
        case "IntervalTrigger": return "Every \(Fmt.runtime(Fmt.seconds(t.intervalTicks ?? 0)))"
        case "StartupTrigger": return "When the server starts"
        default: return t.type
        }
    }

    private func refresh() async {
        if let t = try? await model.client?.get("/ScheduledTasks/\(task.id)", as: TaskInfo.self) { task = t }
        await reload()
    }

    private func removeTrigger(_ index: Int) async {
        var list = task.triggers ?? []
        guard list.indices.contains(index) else { return }
        list.remove(at: index)
        await saveTriggers(list)
    }

    private func saveTriggers(_ list: [TaskTrigger]) async {
        do {
            try await model.client?.postVoid("/ScheduledTasks/\(task.id)/Triggers", json: list)
            await refresh()
        } catch { model.report(error) }
    }
}

struct AddTriggerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let add: (TaskTrigger) -> Void
    @State private var type = "DailyTrigger"
    @State private var time = Calendar.current.date(bySettingHour: 3, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var day = "Sunday"
    @State private var hours = 24

    var body: some View {
        NavigationStack {
            Form {
                Picker("Type", selection: $type) {
                    Text("Daily").tag("DailyTrigger")
                    Text("Weekly").tag("WeeklyTrigger")
                    Text("Interval").tag("IntervalTrigger")
                    Text("On server start").tag("StartupTrigger")
                }
                if type == "DailyTrigger" || type == "WeeklyTrigger" {
                    DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                }
                if type == "WeeklyTrigger" {
                    Picker("Day", selection: $day) {
                        ForEach(["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"], id: \.self) { Text($0) }
                    }
                }
                if type == "IntervalTrigger" {
                    Picker("Every", selection: $hours) {
                        ForEach([1, 2, 3, 4, 6, 8, 12, 24, 48, 72, 168], id: \.self) { Text("\($0) h").tag($0) }
                    }
                }
            }
            .navigationTitle("Add trigger")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let c = Calendar.current.dateComponents([.hour, .minute], from: time)
                        let tod = Int64(((c.hour ?? 0) * 3600 + (c.minute ?? 0) * 60)) * 10_000_000
                        var t = TaskTrigger(type: type)
                        switch type {
                        case "DailyTrigger": t.timeOfDayTicks = tod
                        case "WeeklyTrigger": t.timeOfDayTicks = tod; t.dayOfWeek = day
                        case "IntervalTrigger": t.intervalTicks = Int64(hours) * 3600 * 10_000_000
                        default: break
                        }
                        add(t)
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Users

struct UsersAdminView: View {
    @Environment(AppModel.self) private var model
    @State private var users: [UserDto] = []
    @State private var creating = false

    var body: some View {
        List {
            ForEach(users) { u in
                NavigationLink { UserAdminDetail(user: u, reload: load) } label: {
                    HStack(spacing: 12) {
                        UserAvatar(serverURL: model.client?.baseURL, userId: u.id, tag: u.primaryImageTag, size: 38)
                        VStack(alignment: .leading) {
                            Text(u.name ?? "").font(.headline)
                            Text([u.policy?.isAdministrator == true ? "Administrator" : nil,
                                  u.policy?.isDisabled == true ? "Disabled" : nil,
                                  u.lastActivityDate.map { "Active \($0.formatted(.relative(presentation: .named)))" }]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Users")
        .toolbar { Button("New user", systemImage: "person.badge.plus") { creating = true } }
        .task { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $creating) { NewUserSheet(reload: load) }
    }

    func load() async {
        users = (try? await model.client?.get("/Users", as: [UserDto].self)) ?? users
    }
}

struct NewUserSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let reload: () async -> Void
    @State private var name = ""
    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .keyboardDoneBar()
                SecureField("Password (optional)", text: $password)
            }
            .navigationTitle("New user")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        struct Body: Encodable { var name: String; var password: String? }
                        Task {
                            do {
                                let _: UserDto = try await model.client!.post("/Users/New", json: Body(name: name, password: password.isEmpty ? nil : password))
                                await reload()
                                dismiss()
                            } catch { model.report(error) }
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

/// One user, in jellyfin-web's tabs: Profile, Access, Parental control, Password.
/// The policy is edited as the server's own JSON, so every key (including ones this app
/// doesn't show) is sent back unchanged — Jellyfin replaces the whole policy on save.
struct UserAdminDetail: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var user: UserDto
    let reload: () async -> Void

    enum Tab: String, CaseIterable { case profile = "Profile", access = "Access", parental = "Parental control", password = "Password" }
    struct Named: Hashable { let id: String; let name: String }
    struct RatingGroup: Hashable { var label: String; let score: Int; let sub: Int? }

    @State private var tab: Tab = .profile
    @State private var raw: [String: Any] = [:]
    @State private var policy: [String: Any] = [:]
    @State private var originalPolicy: Data?
    @State private var name = ""
    @State private var views: [Named] = []
    @State private var channels: [Named] = []
    @State private var devices: [Named] = []
    @State private var authProviders: [Named] = []
    @State private var resetProviders: [Named] = []
    @State private var ratings: [RatingGroup] = []
    @State private var loaded = false
    @State private var saving = false
    @State private var message: String?
    @State private var confirmDelete = false
    @State private var confirmReset = false
    @State private var pw = ""
    @State private var pw2 = ""

    private static let unrated: [(String, String)] = [
        ("Book", "Books"), ("ChannelContent", "Channels"), ("LiveTvChannel", "Live TV"), ("Movie", "Movies"),
        ("Music", "Music"), ("Trailer", "Trailers"), ("Series", "Shows"),
    ]
    private static let days = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Everyday", "Weekday", "Weekend"]

    var body: some View {
        Form {
            Section {
                Picker("Section", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
            }
            if flag("IsDisabled").wrappedValue {
                Section {
                    Label("This user is currently disabled. Turn off \"Disable this user\" to let them sign in again.", systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(.orange)
                }
            }
            if let message { Section { Text(message).font(.footnote).foregroundStyle(.secondary) } }
            if !loaded {
                Section { HStack { Spacer(); ProgressView(); Spacer() } }
            } else {
                switch tab {
                case .profile: profile
                case .access: access
                case .parental: parental
                case .password: password
                }
            }
        }
        .navigationTitle(user.name ?? "User")
        .keyboardDoneBar()
        .toolbar {
            if dirty {
                ToolbarItem(placement: .cancellationAction) { Button("Discard") { discard() } }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Keyboard.dismiss(); Task { await save() } }.disabled(!dirty || saving)
            }
        }
        .task { await load() }
        .confirmationDialog("Delete \(user.name ?? "this user")?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task {
                    do {
                        try await model.client?.send("DELETE", "/Users/\(user.id)")
                        await reload()
                        dismiss()
                    } catch { model.report(error) }
                }
            }
        } message: { Text("Their watch history and settings are deleted too.") }
        .confirmationDialog("Reset this user's password?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { Task { await setPassword(reset: true) } }
        } message: { Text("They can then sign in without a password until they set one.") }
    }

    // MARK: Tabs

    @ViewBuilder private var profile: some View {
        Section("Profile") {
            LabeledContent("Name") {
                TextField("Name", text: $name).multilineTextAlignment(.trailing).submitLabel(.done)
            }
            if authProviders.count > 1 {
                picker("Authentication provider", "AuthenticationProviderId", authProviders, help: "Checks this user's password.")
            }
            if resetProviders.count > 1 {
                picker("Password reset provider", "PasswordResetProviderId", resetProviders, help: "Used when this user asks to reset their password.")
            }
            toggle("Allow remote connections to this server", "EnableRemoteAccess", "Off blocks this user's connections from outside your network.")
            toggle("Allow this user to manage the server", "IsAdministrator")
            toggle("Allow this user to manage collections", "EnableCollectionManagement")
            toggle("Allow this user to edit subtitles", "EnableSubtitleManagement")
            if has("EnableLyricManagement") { toggle("Allow this user to edit lyrics", "EnableLyricManagement") }
        }
        Section("Feature access") {
            toggle("Allow Live TV access", "EnableLiveTvAccess")
            toggle("Allow Live TV recording management", "EnableLiveTvManagement")
        }
        Section("Playback") {
            toggle("Allow media playback", "EnableMediaPlayback")
            toggle("Allow audio playback that requires transcoding", "EnableAudioPlaybackTranscoding")
            toggle("Allow video playback that requires transcoding", "EnableVideoPlaybackTranscoding")
            toggle("Allow video playback that requires conversion without re-encoding", "EnablePlaybackRemuxing",
                   "Turning transcoding off may make some files fail to play on some apps.")
            toggle("Force transcoding of remote media sources such as Live TV", "ForceRemoteSourceTranscoding")
            number("Internet streaming bitrate limit (Mbps)", "RemoteClientBitrateLimit", min: 0, scale: 1_000_000,
                   help: "Overrides the server's limit (Server settings → Streaming). 0 = no limit.")
            VStack(alignment: .leading, spacing: 4) {
                Picker("SyncPlay access", selection: text("SyncPlayAccess", default: "CreateAndJoinGroups")) {
                    Text("Allow creating and joining groups").tag("CreateAndJoinGroups")
                    Text("Allow joining groups").tag("JoinGroups")
                    Text("No access").tag("None")
                }
                .pickerStyle(.menu)
                Text("Watching together in sync with other devices.").font(.caption).foregroundStyle(.secondary)
            }
        }
        Section("Allow media deletion from") {
            toggle("All libraries", "EnableContentDeletion")
            if !flag("EnableContentDeletion").wrappedValue {
                ForEach(views, id: \.self) { v in Toggle(v.name, isOn: member("EnableContentDeletionFromFolders", v.id)) }
            }
        }
        Section("Remote control") {
            toggle("Allow remote control of other users", "EnableRemoteControlOfOtherUsers")
            toggle("Allow remote control of shared devices", "EnableSharedDeviceControl", "DLNA devices count as shared until a user starts controlling them.")
        }
        Section("Other") {
            toggle("Allow media downloading", "EnableContentDownloading", "Save media on their devices (not the same as sync). Book libraries need this.")
            toggle("Disable this user", "IsDisabled", "The server refuses their connections and ends the open ones.")
            toggle("Hide this user from login screens", "IsHidden", "For private or admin accounts: they sign in by typing their name and password.")
            number("Failed login tries before the user is locked out", "LoginAttemptsBeforeLockout", min: -1,
                   help: "0 = the default (3 tries, 5 for administrators); -1 = never lock out.")
            number("Maximum simultaneous sessions", "MaxActiveSessions", min: 0, help: "0 = no limit.")
        }
        if user.id != model.user?.id {
            Section {
                Button(role: .destructive) { confirmDelete = true } label: { Label("Delete user", systemImage: "trash").foregroundStyle(.red) }
            }
        }
    }

    @ViewBuilder private var access: some View {
        Section {
            toggle("Enable access to all libraries", "EnableAllFolders")
            if !flag("EnableAllFolders").wrappedValue {
                ForEach(views, id: \.self) { v in Toggle(v.name, isOn: member("EnabledFolders", v.id)) }
            }
        } header: { Text("Library access") } footer: {
            Text("The libraries this user can see. Administrators can edit every folder with the metadata manager.")
        }
        if !channels.isEmpty {
            Section("Channel access") {
                toggle("Enable access to all channels", "EnableAllChannels")
                if !flag("EnableAllChannels").wrappedValue {
                    ForEach(channels, id: \.self) { c in Toggle(c.name, isOn: member("EnabledChannels", c.id)) }
                }
            }
        }
        if !flag("IsAdministrator").wrappedValue {
            Section {
                toggle("Enable access from all devices", "EnableAllDevices")
                if !flag("EnableAllDevices").wrappedValue {
                    ForEach(devices, id: \.self) { d in Toggle(d.name, isOn: member("EnabledDevices", d.id)) }
                }
            } header: { Text("Device access") } footer: {
                Text("Only for devices that can be told apart; doesn't block browsers. With a list, new devices need approval here first.")
            }
        }
    }

    @ViewBuilder private var parental: some View {
        Section {
            Picker("Highest allowed rating", selection: ratingSelection) {
                Text("No limit").tag(-1)
                ForEach(ratings.indices, id: \.self) { i in Text(ratings[i].label).tag(i) }
            }
            .pickerStyle(.menu)
        } header: { Text("Maximum allowed parental rating") } footer: { Text("Titles rated higher are hidden from this user.") }
        Section("Block items with no or unrecognized rating") {
            ForEach(Self.unrated, id: \.0) { t in Toggle(t.1, isOn: member("BlockUnratedItems", t.0)) }
        }
        Section {
            TagsEditor(label: "Tags", placeholder: "Add a tag", numeric: false, values: strings("AllowedTags"))
        } header: { Text("Allow items with tags") } footer: { Text("Only show media with at least one of these tags. Empty = no limit.") }
        Section {
            TagsEditor(label: "Tags", placeholder: "Add a tag", numeric: false, values: strings("BlockedTags"))
        } header: { Text("Block items with tags") } footer: { Text("Hide media with at least one of these tags.") }
        if !flag("IsAdministrator").wrappedValue {
            Section {
                Button {
                    setSchedules(schedules + [["DayOfWeek": "Sunday", "StartHour": 0.0, "EndHour": 24.0]])
                } label: { Label("Add", systemImage: "plus") }
            } header: { Text("Access schedule") } footer: {
                Text("Limit sign-ins to certain hours. With no schedule, the user can sign in any time.")
            }
            ForEach(schedules.indices, id: \.self) { i in
                Section("Schedule \(i + 1)") { scheduleRows(i) }
            }
        }
    }

    @ViewBuilder private var password: some View {
        Section("Password") {
            SecureField("New password", text: $pw).textContentType(.newPassword)
            SecureField("Confirm new password", text: $pw2).textContentType(.newPassword)
            if !pw2.isEmpty && pw != pw2 {
                Text("The passwords don't match.").font(.footnote).foregroundStyle(.red)
            }
        }
        Section {
            Button("Save password") { Task { await setPassword(reset: false) } }
                .disabled(pw.isEmpty || pw != pw2 || saving)
            Button("Reset password", role: .destructive) { confirmReset = true }
        }
    }

    // MARK: Rows

    private func toggle(_ label: String, _ key: String, _ detail: String? = nil) -> some View {
        Toggle(isOn: flag(key)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private func number(_ label: String, _ key: String, min: Double, scale: Double = 1, help: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(label) {
                TextField("0", text: Binding(get: {
                    let v = ((policy[realKey(key)] as? NSNumber)?.doubleValue ?? 0) / scale
                    return v == v.rounded() ? String(Int(v)) : String(format: "%g", v)
                }, set: { t in
                    guard let v = Double(t.replacingOccurrences(of: ",", with: ".")) ?? (t.isEmpty ? 0 : nil) else { return }
                    put(key, Int((Swift.max(min, v) * scale).rounded()))
                }))
                .keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing).frame(maxWidth: 90)
            }
            Text(help).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func picker(_ label: String, _ key: String, _ options: [Named], help: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(label, selection: text(key)) {
                ForEach(options, id: \.self) { Text($0.name).tag($0.id) }
            }
            .pickerStyle(.menu)
            Text(help).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// One schedule as separate rows (day, from, to, remove), so each control is its own row.
    @ViewBuilder
    private func scheduleRows(_ i: Int) -> some View {
        let sc = schedules.indices.contains(i) ? schedules[i] : [:]
        let start = (sc["StartHour"] as? NSNumber)?.doubleValue ?? 0
        let end = (sc["EndHour"] as? NSNumber)?.doubleValue ?? 24
        Picker("Day", selection: Binding(get: { sc["DayOfWeek"] as? String ?? "Sunday" }, set: { updateSchedule(i, "DayOfWeek", $0) })) {
            ForEach(Self.days, id: \.self) { Text(Self.dayLabel($0)).tag($0) }
        }
        .pickerStyle(.menu)
        Picker("From", selection: Binding(get: { start }, set: { updateSchedule(i, "StartHour", $0) })) {
            ForEach((0..<48).map { Double($0) / 2 }.filter { $0 < end }, id: \.self) { Text(Self.hourLabel($0)).tag($0) }
        }
        .pickerStyle(.menu)
        Picker("To", selection: Binding(get: { end }, set: { updateSchedule(i, "EndHour", $0) })) {
            ForEach((1...48).map { Double($0) / 2 }.filter { $0 > start }, id: \.self) { Text($0 == 24 ? "24:00" : Self.hourLabel($0)).tag($0) }
        }
        .pickerStyle(.menu)
        Button(role: .destructive) {
            var list = schedules
            guard list.indices.contains(i) else { return }
            list.remove(at: i)
            setSchedules(list)
        } label: { Label("Remove schedule", systemImage: "trash").foregroundStyle(.red) }
    }

    private func updateSchedule(_ i: Int, _ k: String, _ v: Any) {
        var list = schedules
        guard list.indices.contains(i) else { return }
        list[i][k] = v
        setSchedules(list)
    }

    private static func dayLabel(_ d: String) -> String {
        d == "Everyday" ? "Every day" : d == "Weekday" ? "Weekdays" : d == "Weekend" ? "Weekends" : d
    }
    private static func hourLabel(_ h: Double) -> String {
        String(format: "%02d:%@", Int(h) % 24, h.truncatingRemainder(dividingBy: 1) != 0 ? "30" : "00")
    }

    // MARK: Policy values

    private func realKey(_ key: String) -> String {
        policy.keys.first { $0.caseInsensitiveCompare(key) == .orderedSame } ?? key
    }
    private func has(_ key: String) -> Bool { policy[realKey(key)] != nil }
    private func put(_ key: String, _ value: Any) { policy[realKey(key)] = value }

    private func flag(_ key: String) -> Binding<Bool> {
        Binding(get: { (policy[realKey(key)] as? Bool) ?? false }, set: { put(key, $0) })
    }
    private func text(_ key: String, default def: String = "") -> Binding<String> {
        Binding(get: { (policy[realKey(key)] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? def }, set: { put(key, $0) })
    }
    private func list(_ key: String) -> [String] { ((policy[realKey(key)] as? [Any]) ?? []).compactMap { $0 as? String } }
    private func strings(_ key: String) -> Binding<[String]> {
        Binding(get: { list(key) }, set: { put(key, $0) })
    }
    private func member(_ key: String, _ id: String) -> Binding<Bool> {
        Binding(get: { list(key).contains(id) }, set: { on in
            var l = list(key).filter { $0 != id }
            if on { l.append(id) }
            put(key, l)
        })
    }

    private var schedules: [[String: Any]] { (policy[realKey("AccessSchedules")] as? [[String: Any]]) ?? [] }
    private func setSchedules(_ v: [[String: Any]]) { put("AccessSchedules", v) }

    /// jellyfin-web groups ratings with the same score ("PG-13/TV-14") and picks the highest the user may see.
    private var ratingSelection: Binding<Int> {
        Binding(get: {
            guard let max = (policy[realKey("MaxParentalRating")] as? NSNumber)?.intValue else { return -1 }
            let sub = (policy[realKey("MaxParentalSubRating")] as? NSNumber)?.intValue
            if let i = ratings.firstIndex(where: { $0.score == max && $0.sub == sub }) { return i }
            return ratings.lastIndex(where: { $0.score <= max }) ?? -1
        }, set: { i in
            if ratings.indices.contains(i) {
                put("MaxParentalRating", ratings[i].score)
                put("MaxParentalSubRating", ratings[i].sub.map { $0 as Any } ?? NSNull())
            } else {
                put("MaxParentalRating", NSNull())
                put("MaxParentalSubRating", NSNull())
            }
        })
    }

    private var dirty: Bool {
        guard loaded else { return false }
        return Self.json(policy) != originalPolicy || name != (user.name ?? "")
    }
    private static func json(_ o: [String: Any]) -> Data? { try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) }

    // MARK: Server

    private func load() async {
        guard let client = model.client else { return }
        func object(_ path: String, _ query: [String: Any?] = [:]) async -> Any? {
            guard let d = try? await client.send("GET", path, query: query) else { return nil }
            return try? JSONSerialization.jsonObject(with: d)
        }
        func named(_ any: Any?, label: (([String: Any]) -> String)? = nil) -> [Named] {
            let list = (any as? [[String: Any]]) ?? ((any as? [String: Any]).flatMap { LibraryAdminDetail.value($0, "Items") as? [[String: Any]] } ?? [])
            return list.compactMap { e in
                guard let id = LibraryAdminDetail.string(e, "Id") else { return nil }
                return Named(id: id, name: label?(e) ?? LibraryAdminDetail.string(e, "Name") ?? id)
            }
        }
        if let u = await object("/Users/\(user.id)") as? [String: Any] {
            raw = u
            if let fresh = try? await client.get("/Users/\(user.id)", as: UserDto.self) { user = fresh }
            policy = (LibraryAdminDetail.value(u, "Policy") as? [String: Any]) ?? [:]
            originalPolicy = Self.json(policy)
            name = LibraryAdminDetail.string(u, "Name") ?? ""
        }
        views = named(await object("/Library/MediaFolders", ["isHidden": false]))
        channels = named(await object("/Channels"))
        devices = named(await object("/Devices")) { d in
            let n = LibraryAdminDetail.string(d, "CustomName").flatMap { $0.isEmpty ? nil : $0 } ?? LibraryAdminDetail.string(d, "Name") ?? ""
            return "\(n) (\(LibraryAdminDetail.string(d, "AppName") ?? ""))"
        }
        authProviders = named(await object("/Auth/Providers"))
        resetProviders = named(await object("/Auth/PasswordResetProviders"))
        var groups: [RatingGroup] = []
        for r in (await object("/Localization/ParentalRatings") as? [[String: Any]]) ?? [] {
            let scoreObj = LibraryAdminDetail.value(r, "RatingScore") as? [String: Any]
            guard let score = (scoreObj.flatMap { LibraryAdminDetail.value($0, "score") } as? NSNumber)?.intValue
                    ?? (LibraryAdminDetail.value(r, "Value") as? NSNumber)?.intValue else { continue }
            let sub = (scoreObj.flatMap { LibraryAdminDetail.value($0, "subScore") } as? NSNumber)?.intValue
            let label = LibraryAdminDetail.string(r, "Name") ?? "\(score)"
            if let last = groups.last, last.score == score, last.sub == sub {
                groups[groups.count - 1].label += "/\(label)"
            } else {
                groups.append(RatingGroup(label: label, score: score, sub: sub))
            }
        }
        ratings = groups
        loaded = true
    }

    private func discard() {
        if let originalPolicy, let p = try? JSONSerialization.jsonObject(with: originalPolicy) as? [String: Any] { policy = p }
        name = user.name ?? ""
    }

    private func save() async {
        guard let client = model.client else { return }
        saving = true
        defer { saving = false }
        message = nil
        do {
            if name != (user.name ?? ""), !raw.isEmpty {
                var u = raw
                u[raw.keys.first { $0.caseInsensitiveCompare("Name") == .orderedSame } ?? "Name"] = name
                try await client.send("POST", "/Users/\(user.id)", body: try JSONSerialization.data(withJSONObject: u))
            }
            var body = policy
            if (body[realKey("AuthenticationProviderId")] as? String ?? "").isEmpty {
                body[realKey("AuthenticationProviderId")] = "Jellyfin.Server.Implementations.Users.DefaultAuthenticationProvider"
            }
            if (body[realKey("PasswordResetProviderId")] as? String ?? "").isEmpty {
                body[realKey("PasswordResetProviderId")] = "Jellyfin.Server.Implementations.Users.DefaultPasswordResetProvider"
            }
            try await client.send("POST", "/Users/\(user.id)/Policy", body: try JSONSerialization.data(withJSONObject: body))
            await load()
            await reload()
            message = "Saved to the server."
        } catch { message = error.localizedDescription }
    }

    private func setPassword(reset: Bool) async {
        guard let client = model.client else { return }
        saving = true
        defer { saving = false }
        do {
            let body: [String: Any] = reset ? ["ResetPassword": true] : ["NewPw": pw]
            try await client.send("POST", "/Users/Password", query: ["userId": user.id], body: try JSONSerialization.data(withJSONObject: body))
            pw = ""
            pw2 = ""
            message = reset ? "Password reset." : "Password changed."
        } catch { message = error.localizedDescription }
    }
}

// MARK: - Devices & API keys

struct DevicesView: View {
    @Environment(AppModel.self) private var model
    @State private var devices: [DeviceInfoDto] = []
    @State private var renaming: DeviceInfoDto?
    @State private var newName = ""

    var body: some View {
        List {
            ForEach(devices) { d in
                VStack(alignment: .leading, spacing: 3) {
                    Text(d.customName?.isEmpty == false ? d.customName! : (d.name ?? "Device")).font(.headline)
                    Text([d.appName, d.appVersion, d.lastUserName].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                    if let last = d.dateLastActivated { Text("Last used \(last.formatted(.relative(presentation: .named)))").font(.caption2).foregroundStyle(.tertiary) }
                }
                .swipeActions {
                    if d.id != JellyfinClient.deviceId {
                        Button(role: .destructive) { Task { await delete(d) } } label: { Label("Sign out", systemImage: "trash") }
                    }
                    Button { renaming = d; newName = d.customName ?? d.name ?? "" } label: { Label("Rename", systemImage: "pencil") }.tint(Theme.accent)
                }
            }
        }
        .navigationTitle("Devices")
        .task { await load() }
        .refreshable { await load() }
        .alert("Rename device", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Save") {
                guard let d = renaming else { return }
                struct Body: Encodable { var customName: String }
                Task {
                    do { try await model.client?.postVoid("/Devices/Options", query: ["id": d.id], json: Body(customName: newName)) } catch { model.report(error) }
                    await load()
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func load() async {
        struct Page: Codable { var items: [DeviceInfoDto]? }
        devices = ((try? await model.client?.get("/Devices", as: Page.self))?.items ?? devices)
            .sorted { ($0.dateLastActivated ?? .distantPast) > ($1.dateLastActivated ?? .distantPast) }
    }

    private func delete(_ d: DeviceInfoDto) async {
        do { try await model.client?.send("DELETE", "/Devices", query: ["id": d.id]) } catch { model.report(error) }
        await load()
    }
}

struct APIKeysView: View {
    @Environment(AppModel.self) private var model
    @State private var keys: [AuthKey] = []
    @State private var creating = false
    @State private var appName = ""

    var body: some View {
        List {
            ForEach(keys, id: \.accessToken) { k in
                VStack(alignment: .leading, spacing: 4) {
                    Text(k.appName ?? "App").font(.headline)
                    Text(k.accessToken).font(.caption.monospaced()).textSelection(.enabled)
                    if let d = k.dateCreated { Text("Created \(d.formatted(date: .abbreviated, time: .omitted))").font(.caption2).foregroundStyle(.secondary) }
                }
                .swipeActions {
                    Button(role: .destructive) { Task { await revoke(k) } } label: { Label("Revoke", systemImage: "trash") }
                }
                .contextMenu { Button("Copy key", systemImage: "doc.on.doc") { UIPasteboard.general.string = k.accessToken } }
            }
        }
        .navigationTitle("API keys")
        .toolbar { Button("New key", systemImage: "plus") { creating = true } }
        .task { await load() }
        .alert("New API key", isPresented: $creating) {
            TextField("App name", text: $appName)
            Button("Create") {
                Task {
                    do { try await model.client?.send("POST", "/Auth/Keys", query: ["app": appName]) } catch { model.report(error) }
                    appName = ""
                    await load()
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func load() async {
        struct Page: Codable { var items: [AuthKey]? }
        keys = (try? await model.client?.get("/Auth/Keys", as: Page.self))?.items ?? keys
    }

    private func revoke(_ k: AuthKey) async {
        do { try await model.client?.send("DELETE", "/Auth/Keys/\(k.accessToken)") } catch { model.report(error) }
        await load()
    }
}

// MARK: - Logs, activity

struct ServerLogsView: View {
    @Environment(AppModel.self) private var model
    @State private var files: [LogFile] = []

    var body: some View {
        List(files) { f in
            NavigationLink { LogTextView(name: f.name) } label: {
                VStack(alignment: .leading) {
                    Text(f.name).font(.subheadline.monospaced())
                    Text([f.dateModified?.formatted(), f.size.map(Fmt.bytes)].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Logs")
        .task {
            files = ((try? await model.client?.get("/System/Logs", as: [LogFile].self)) ?? [])
                .sorted { ($0.dateModified ?? .distantPast) > ($1.dateModified ?? .distantPast) }
        }
    }
}

struct LogTextView: View {
    @Environment(AppModel.self) private var model
    let name: String
    @State private var text = ""
    @State private var filter = ""
    @State private var errorsOnly = false

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(shown)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $filter, prompt: "Filter lines")
        .toolbar {
            ToolbarItem { Toggle(isOn: $errorsOnly) { Image(systemName: "exclamationmark.triangle") } }
            ToolbarItem { ShareLink(item: text) }
        }
        .overlay { if text.isEmpty { ProgressView() } }
        .task {
            guard let data = try? await model.client?.send("GET", "/System/Logs/Log", query: ["name": name], timeout: 60) else { return }
            text = String(decoding: data, as: UTF8.self)
        }
    }

    private var shown: String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if errorsOnly { lines = lines.filter { $0.contains("[ERR]") || $0.contains("[WRN]") || $0.contains("[FTL]") } }
        if !filter.isEmpty { lines = lines.filter { $0.localizedCaseInsensitiveContains(filter) } }
        return lines.suffix(4000).joined(separator: "\n")
    }
}

struct ActivityLogView: View {
    @Environment(AppModel.self) private var model
    @State private var entries: [ActivityLogEntry] = []
    @State private var total = 0
    @State private var usersOnly = false

    var body: some View {
        List {
            Picker("", selection: $usersOnly) {
                Text("All").tag(false)
                Text("User activity").tag(true)
            }
            .pickerStyle(.segmented)
            ForEach(entries) { e in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: icon(e)).foregroundStyle(color(e)).frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.name ?? "").font(.subheadline)
                        if let o = e.shortOverview ?? e.overview { Text(o).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                        if let d = e.date { Text(d.formatted(.relative(presentation: .named))).font(.caption2).foregroundStyle(.tertiary) }
                    }
                }
                .onAppear { if e.id == entries.last?.id, entries.count < total { Task { await load(more: true) } } }
            }
        }
        .navigationTitle("Activity")
        .task(id: usersOnly) { await load(more: false) }
        .refreshable { await load(more: false) }
    }

    private func icon(_ e: ActivityLogEntry) -> String {
        switch e.type ?? "" {
        case let t where t.contains("Playback"): return "play.circle.fill"
        case let t where t.contains("Authentication"): return "person.badge.key.fill"
        case let t where t.contains("Plugin"): return "puzzlepiece.extension.fill"
        case let t where t.contains("Task"): return "clock.arrow.2.circlepath"
        default: return "info.circle.fill"
        }
    }

    private func color(_ e: ActivityLogEntry) -> Color {
        switch e.severity ?? "" {
        case "Error", "Critical": return .red
        case "Warning": return .orange
        default: return Theme.accent
        }
    }

    private func load(more: Bool) async {
        struct Page: Codable { var items: [ActivityLogEntry]?; var totalRecordCount: Int? }
        var q: [String: Any?] = ["startIndex": more ? entries.count : 0, "limit": 50]
        if usersOnly { q["hasUserId"] = true }
        guard let page = try? await model.client?.get("/System/ActivityLog/Entries", q, as: Page.self) else { return }
        entries = (more ? entries : []) + (page.items ?? [])
        total = page.totalRecordCount ?? entries.count
    }
}

// MARK: - Libraries & plugins

struct AdminLibrariesView: View {
    @Environment(AppModel.self) private var model
    @State private var folders: [VirtualFolderInfo] = []
    @State private var adding = false

    var body: some View {
        List {
            ForEach(folders) { f in
                NavigationLink { LibraryAdminDetail(folder: f, reload: reloadFolders) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(f.name ?? "").font(.headline)
                        Spacer()
                        Text(f.collectionType ?? "mixed").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(f.locations ?? [], id: \.self) { Text($0).font(.caption.monospaced()).foregroundStyle(.secondary) }
                    if let p = f.refreshProgress, f.refreshStatus == "Active" { ProgressView(value: p / 100).tint(Theme.accent) }
                }
                }
                .swipeActions {
                    Button { Task { await scan(f) } } label: { Label("Scan", systemImage: "arrow.triangle.2.circlepath") }.tint(.green)
                }
            }
        }
        .navigationTitle("Libraries")
        .toolbar { Button("Add library", systemImage: "plus") { adding = true } }
        .sheet(isPresented: $adding) { AddLibrarySheet(reload: reloadFolders) }
        .task {
            while !Task.isCancelled {
                folders = (try? await model.client?.get("/Library/VirtualFolders", as: [VirtualFolderInfo].self)) ?? folders
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    private func reloadFolders() async {
        folders = (try? await model.client?.get("/Library/VirtualFolders", as: [VirtualFolderInfo].self)) ?? folders
    }

    private func scan(_ f: VirtualFolderInfo) async {
        guard let id = f.itemId else { return }
        do {
            try await model.client?.send("POST", "/Items/\(id)/Refresh", query: [
                "recursive": true, "metadataRefreshMode": "Default", "imageRefreshMode": "Default",
                "replaceAllMetadata": false, "replaceAllImages": false,
            ])
        } catch { model.report(error) }
    }
}

struct PluginsView: View {
    @Environment(AppModel.self) private var model
    @State private var plugins: [PluginInfo] = []

    var body: some View {
        List {
            ForEach(plugins) { p in
                NavigationLink { PluginSettingsView(plugin: p) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(p.name ?? "").font(.headline)
                        Spacer()
                        Text(p.status ?? "").font(.caption.weight(.semibold))
                            .foregroundStyle(p.status == "Active" ? .green : .orange)
                    }
                    Text("Version \(p.version ?? "?")").font(.caption).foregroundStyle(.secondary)
                    if let d = p.description, !d.isEmpty { Text(d).font(.caption2).foregroundStyle(.secondary).lineLimit(3) }
                }
                }
                .swipeActions {
                    if p.status == "Active" {
                        Button { Task { await toggle(p, enable: false) } } label: { Label("Disable", systemImage: "pause.circle") }.tint(.orange)
                    } else if p.status == "Disabled" {
                        Button { Task { await toggle(p, enable: true) } } label: { Label("Enable", systemImage: "play.circle") }.tint(.green)
                    }
                    if p.canUninstall == true {
                        Button(role: .destructive) { Task { await uninstall(p) } } label: { Label("Uninstall", systemImage: "trash") }
                    }
                }
            }
        }
        .navigationTitle("My plugins")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        plugins = ((try? await model.client?.get("/Plugins", as: [PluginInfo].self)) ?? plugins).sorted { ($0.name ?? "") < ($1.name ?? "") }
    }

    private func toggle(_ p: PluginInfo, enable: Bool) async {
        do { try await model.client?.send("POST", "/Plugins/\(p.id)/\(p.version ?? "")/\(enable ? "Enable" : "Disable")") } catch { model.report(error) }
        await load()
    }

    private func uninstall(_ p: PluginInfo) async {
        do { try await model.client?.send("DELETE", "/Plugins/\(p.id)/\(p.version ?? "")") } catch { model.report(error) }
        await load()
    }
}
