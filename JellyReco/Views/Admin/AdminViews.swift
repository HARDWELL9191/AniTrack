import SwiftUI

/// Server administration (admins only): everything Swiftfin's dashboard has, grouped by task.
struct AdminDashboardView: View {
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
            Section {
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
                        Label("Server update available", systemImage: "arrow.down.circle").foregroundStyle(Theme.accent)
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
                NavigationLink { ActivityLogView() } label: { Label("Activity log", systemImage: "list.bullet.rectangle") }
            }

            Section("Maintenance") {
                NavigationLink { ScheduledTasksView() } label: { Label("Scheduled tasks", systemImage: "clock.arrow.2.circlepath") }
                NavigationLink { AdminLibrariesView() } label: { Label("Libraries", systemImage: "books.vertical.fill") }
                NavigationLink { ServerLogsView() } label: { Label("Server logs", systemImage: "doc.text.magnifyingglass") }
                NavigationLink { PlaybackTestView() } label: { Label("Playback test", systemImage: "checkmark.seal.fill") }
            }

            Section("Access") {
                NavigationLink { UsersAdminView() } label: { Label("Users", systemImage: "person.3.fill") }
                NavigationLink { DevicesView() } label: { Label("Devices", systemImage: "iphone.gen3") }
                NavigationLink { APIKeysView() } label: { Label("API keys", systemImage: "key.horizontal.fill") }
                NavigationLink { PluginsView() } label: { Label("Plugins", systemImage: "puzzlepiece.extension.fill") }
            }

            Section("Server") {
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

struct UserAdminDetail: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var user: UserDto
    let reload: () async -> Void
    @State private var policy = UserPolicy()
    @State private var libraries: [VirtualFolderInfo] = []
    @State private var ratings: [ParentalRating] = []
    @State private var confirmDelete = false
    @State private var resetPassword = false
    @State private var dirty = false

    var body: some View {
        Form {
            Section("Role") {
                Toggle("Administrator", isOn: bind(\.isAdministrator))
                Toggle("Disabled", isOn: bind(\.isDisabled))
                Toggle("Hidden from login screen", isOn: bind(\.isHidden))
            }
            Section("Playback") {
                Toggle("Allow media playback", isOn: bind(\.enableMediaPlayback))
                Toggle("Allow video transcoding", isOn: bind(\.enableVideoPlaybackTranscoding))
                Toggle("Allow audio transcoding", isOn: bind(\.enableAudioPlaybackTranscoding))
                Toggle("Allow remuxing", isOn: bind(\.enablePlaybackRemuxing))
                Toggle("Force transcoding for remote sources", isOn: bind(\.forceRemoteSourceTranscoding))
                Picker("Remote bitrate limit", selection: Binding(get: { policy.remoteClientBitrateLimit ?? 0 },
                                                                 set: { policy.remoteClientBitrateLimit = $0; dirty = true })) {
                    Text("No limit").tag(0)
                    ForEach([1, 2, 4, 8, 10, 15, 20, 40, 60, 80, 120], id: \.self) { Text("\($0) Mbps").tag($0 * 1_000_000) }
                }
                Stepper("Max sessions: \((policy.maxActiveSessions ?? 0) == 0 ? "unlimited" : "\(policy.maxActiveSessions!)")",
                        value: Binding(get: { policy.maxActiveSessions ?? 0 }, set: { policy.maxActiveSessions = $0; dirty = true }), in: 0...20)
            }
            Section("Features") {
                Toggle("Remote access", isOn: bind(\.enableRemoteAccess))
                Toggle("Live TV", isOn: bind(\.enableLiveTvAccess))
                Toggle("Manage Live TV recordings", isOn: bind(\.enableLiveTvManagement))
                Toggle("Download media", isOn: bind(\.enableContentDownloading))
                Toggle("Delete media", isOn: bind(\.enableContentDeletion))
                Toggle("Manage collections", isOn: bind(\.enableCollectionManagement))
                Toggle("Manage subtitles", isOn: bind(\.enableSubtitleManagement))
                Toggle("Manage lyrics", isOn: bind(\.enableLyricManagement))
                Toggle("Remote control other users", isOn: bind(\.enableRemoteControlOfOtherUsers))
                Toggle("Shared device control", isOn: bind(\.enableSharedDeviceControl))
                Toggle("Public sharing", isOn: bind(\.enablePublicSharing))
            }
            Section("Library access") {
                Toggle("All libraries", isOn: bind(\.enableAllFolders))
                if policy.enableAllFolders != true {
                    ForEach(libraries) { lib in
                        Toggle(lib.name ?? "", isOn: Binding(
                            get: { (policy.enabledFolders ?? []).contains(lib.itemId ?? "") },
                            set: { on in
                                var set = Set(policy.enabledFolders ?? [])
                                if on { set.insert(lib.itemId ?? "") } else { set.remove(lib.itemId ?? "") }
                                policy.enabledFolders = Array(set)
                                dirty = true
                            }))
                    }
                }
            }
            Section("Parental control") {
                Picker("Maximum rating", selection: Binding(get: { policy.maxParentalRating ?? -1 },
                                                           set: { policy.maxParentalRating = $0 < 0 ? nil : $0; dirty = true })) {
                    Text("No limit").tag(-1)
                    ForEach(ratings.filter { $0.value != nil }, id: \.name) { r in Text(r.name ?? "").tag(r.value ?? 0) }
                }
                Toggle("Block unrated items", isOn: Binding(
                    get: { !(policy.blockUnratedItems ?? []).isEmpty },
                    set: { policy.blockUnratedItems = $0 ? ["Movie", "Series", "Book", "Trailer", "LiveTvChannel", "LiveTvProgram", "Music", "ChannelContent"] : []; dirty = true }))
            }
            Section("Sign-in") {
                Stepper("Lock after \(policy.loginAttemptsBeforeLockout ?? -1 <= 0 ? "default" : "\(policy.loginAttemptsBeforeLockout!)") failed attempts",
                        value: Binding(get: { policy.loginAttemptsBeforeLockout ?? -1 }, set: { policy.loginAttemptsBeforeLockout = $0; dirty = true }), in: -1...20)
                Button("Set password…", systemImage: "key.fill") { resetPassword = true }
            }
            if user.id != model.user?.id {
                Section {
                    Button("Delete user", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .navigationTitle(user.name ?? "User")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }.disabled(!dirty)
            }
        }
        .task {
            guard let client = model.client else { return }
            if let fresh = try? await client.get("/Users/\(user.id)", as: UserDto.self) { user = fresh }
            policy = user.policy ?? UserPolicy()
            libraries = (try? await client.get("/Library/VirtualFolders", as: [VirtualFolderInfo].self)) ?? []
            ratings = (try? await client.get("/Localization/ParentalRatings", as: [ParentalRating].self)) ?? []
        }
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
        }
        .sheet(isPresented: $resetPassword) { ChangePasswordSheet(userId: user.id, isOwn: user.id == model.user?.id) }
    }

    private func bind(_ path: WritableKeyPath<UserPolicy, Bool?>) -> Binding<Bool> {
        Binding(get: { policy[keyPath: path] ?? false }, set: { policy[keyPath: path] = $0; dirty = true })
    }

    private func save() async {
        guard let client = model.client else { return }
        var body = policy
        body.authenticationProviderId = body.authenticationProviderId ?? "Jellyfin.Server.Implementations.Users.DefaultAuthenticationProvider"
        body.passwordResetProviderId = body.passwordResetProviderId ?? "Jellyfin.Server.Implementations.Users.DefaultPasswordResetProvider"
        do {
            try await client.postVoid("/Users/\(user.id)/Policy", json: body)
            dirty = false
            await reload()
        } catch { model.report(error) }
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
        .navigationTitle("Server logs")
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

    var body: some View {
        List {
            ForEach(folders) { f in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(f.name ?? "").font(.headline)
                        Spacer()
                        Text(f.collectionType ?? "mixed").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(f.locations ?? [], id: \.self) { Text($0).font(.caption.monospaced()).foregroundStyle(.secondary) }
                    if let p = f.refreshProgress, f.refreshStatus == "Active" { ProgressView(value: p / 100).tint(Theme.accent) }
                }
                .swipeActions {
                    Button { Task { await scan(f) } } label: { Label("Scan", systemImage: "arrow.triangle.2.circlepath") }.tint(.green)
                }
            }
        }
        .navigationTitle("Libraries")
        .task {
            while !Task.isCancelled {
                folders = (try? await model.client?.get("/Library/VirtualFolders", as: [VirtualFolderInfo].self)) ?? folders
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
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
        .navigationTitle("Plugins")
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
