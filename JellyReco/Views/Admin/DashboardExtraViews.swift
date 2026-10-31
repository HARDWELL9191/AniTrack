import SwiftUI

// Dashboard pages the JellyReco desktop client has: Live TV tuners and guides, backups, and
// plugin settings (jellyfin-web shows each plugin's own page; this edits its configuration).

private func jsonGet(_ d: [String: Any], _ key: String) -> Any? {
    d[key] ?? d.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
}
private func jsonString(_ d: [String: Any], _ key: String) -> String? { jsonGet(d, key) as? String }

// MARK: - Live TV

struct LiveTVSetupView: View {
    @Environment(AppModel.self) private var model
    @State private var tuners: [[String: Any]] = []
    @State private var guides: [[String: Any]] = []
    @State private var types: [String] = []
    @State private var addingTuner = false
    @State private var addingGuide = false
    @State private var address = ""
    @State private var guidePath = ""
    @State private var message: String?
    @State private var busy = false

    var body: some View {
        List {
            if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            Section {
                ForEach(tuners.indices, id: \.self) { i in
                    let t = tuners[i]
                    VStack(alignment: .leading, spacing: 2) {
                        Text(jsonString(t, "FriendlyName").flatMap { $0.isEmpty ? nil : $0 } ?? jsonString(t, "Url") ?? "Tuner")
                        Text("\(jsonString(t, "Type") ?? "") · \(jsonString(t, "Url") ?? "")").font(.caption).foregroundStyle(.secondary)
                    }
                    .swipeActions {
                        Button(role: .destructive) { Task { await remove("/LiveTv/TunerHosts", jsonString(t, "Id")) } } label: { Label("Remove", systemImage: "trash") }
                    }
                }
                Button { address = ""; addingTuner = true } label: { Label("Add tuner", systemImage: "plus") }
            } header: { Text("Tuners") } footer: {
                if !types.isEmpty { Text("Supported: \(types.joined(separator: ", ")). Swipe a tuner to remove it.") }
            }
            Section {
                ForEach(guides.indices, id: \.self) { i in
                    let g = guides[i]
                    VStack(alignment: .leading, spacing: 2) {
                        Text(jsonString(g, "Type") ?? "Guide")
                        Text(jsonString(g, "Path") ?? jsonString(g, "ListingsId") ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                    .swipeActions {
                        Button(role: .destructive) { Task { await remove("/LiveTv/ListingProviders", jsonString(g, "Id")) } } label: { Label("Remove", systemImage: "trash") }
                    }
                }
                Button { guidePath = ""; addingGuide = true } label: { Label("Add XMLTV", systemImage: "plus") }
                Button { Task { await refreshGuide() } } label: { Label("Refresh guide data", systemImage: "arrow.clockwise") }
                    .disabled(busy)
            } header: { Text("TV guide") }
            Section {
                NavigationLink { ConfigPageView(page: ServerSettingsCatalog.dvr) } label: { Label("DVR (recording options)", systemImage: "record.circle") }
            }
        }
        .navigationTitle("Live TV")
        .task { await load() }
        .refreshable { await load() }
        .alert("Add a tuner", isPresented: $addingTuner) {
            TextField("M3U URL or HDHomeRun address", text: $address)
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
            Button("Add") { Task { await addTuner() } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Add an XMLTV guide", isPresented: $addingGuide) {
            TextField("XMLTV file path or URL", text: $guidePath)
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
            Button("Add") { Task { await addGuide() } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func load() async {
        guard let client = model.client else { return }
        if let d = try? await client.send("GET", "/System/Configuration/livetv"),
           let cfg = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            tuners = (jsonGet(cfg, "TunerHosts") as? [[String: Any]]) ?? []
            guides = (jsonGet(cfg, "ListingProviders") as? [[String: Any]]) ?? []
        }
        if let d = try? await client.send("GET", "/LiveTv/TunerHosts/Types"),
           let list = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] {
            types = list.compactMap { jsonString($0, "Name") }
        }
    }

    private func addTuner() async {
        let url = address.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty else { return }
        // Same rule as the desktop client: an IP / "hdhomerun" address without .m3u is an HDHomeRun.
        let isHDHR = (url.first?.isNumber ?? false || url.lowercased().contains("hdhomerun")) && !url.lowercased().contains(".m3u")
        await post("/LiveTv/TunerHosts", [:], ["Type": isHDHR ? "hdhomerun" : "m3u", "Url": url, "ImportFavoritesOnly": false,
                                                "AllowHWTranscoding": true, "EnableStreamLooping": false], done: "Tuner added.")
    }

    private func addGuide() async {
        let path = guidePath.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return }
        await post("/LiveTv/ListingProviders", ["validateListings": false, "validateLogin": false],
                   ["Type": "xmltv", "Path": path, "EnableAllTuners": true], done: "Guide added.")
    }

    private func post(_ path: String, _ query: [String: Any?], _ body: [String: Any], done: String) async {
        do {
            try await model.client?.send("POST", path, query: query, body: try JSONSerialization.data(withJSONObject: body))
            message = done
            await load()
        } catch { message = error.localizedDescription }
    }

    private func remove(_ path: String, _ id: String?) async {
        guard let id else { return }
        do {
            try await model.client?.send("DELETE", path, query: ["id": id])
            message = "Removed."
            await load()
        } catch { message = error.localizedDescription }
    }

    private func refreshGuide() async {
        guard let client = model.client else { return }
        busy = true
        defer { busy = false }
        do {
            let d = try await client.send("GET", "/ScheduledTasks")
            let tasks = (try JSONSerialization.jsonObject(with: d) as? [[String: Any]]) ?? []
            if let id = tasks.first(where: { jsonString($0, "Key") == "RefreshGuide" }).flatMap({ jsonString($0, "Id") }) {
                try await client.send("POST", "/ScheduledTasks/Running/\(id)")
                message = "Refreshing the guide."
            } else {
                message = "The server has no guide refresh task."
            }
        } catch { message = error.localizedDescription }
    }
}

// MARK: - Backups (Jellyfin 10.11+)

struct BackupsView: View {
    @Environment(AppModel.self) private var model
    @State private var backups: [[String: Any]] = []
    @State private var loaded = false
    @State private var database = true
    @State private var metadata = true
    @State private var subtitles = true
    @State private var trickplay = false
    @State private var busy = false
    @State private var message: String?
    @State private var restoring: String?

    var body: some View {
        List {
            if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            Section {
                Toggle("Database (users, watch history, settings)", isOn: $database)
                Toggle("Metadata and images", isOn: $metadata)
                Toggle("Subtitles", isOn: $subtitles)
                Toggle(isOn: $trickplay) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Trickplay images")
                        Text("Large").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button { Task { await create() } } label: {
                    HStack {
                        Label("Create backup", systemImage: "archivebox")
                        if busy { Spacer(); ProgressView() }
                    }
                }
                .disabled(busy)
            } header: { Text("Create a backup") }
            Section("Backups on the server") {
                if !loaded {
                    ProgressView()
                } else if backups.isEmpty {
                    Text("No backups yet.").foregroundStyle(.secondary)
                }
                ForEach(sorted.indices, id: \.self) { i in
                    let b = sorted[i]
                    let path = jsonString(b, "Path") ?? ""
                    VStack(alignment: .leading, spacing: 2) {
                        Text(date(b))
                        Text(detail(b)).font(.caption).foregroundStyle(.secondary)
                    }
                    .swipeActions {
                        Button(role: .destructive) { restoring = path } label: { Label("Restore", systemImage: "arrow.uturn.backward") }
                    }
                }
            }
        }
        .navigationTitle("Backups")
        .task { await load() }
        .refreshable { await load() }
        .confirmationDialog("Restore this backup?", isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } }),
                            titleVisibility: .visible) {
            Button("Restore", role: .destructive) { if let p = restoring { Task { await restore(p) } } }
        } message: { Text("The server restarts and replaces its current data with this backup.") }
    }

    private var sorted: [[String: Any]] {
        backups.sorted { (jsonString($0, "DateCreated") ?? "") > (jsonString($1, "DateCreated") ?? "") }
    }

    private func date(_ b: [String: Any]) -> String {
        guard let raw = jsonString(b, "DateCreated") else { return "Backup" }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let d = f.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
        return d.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? raw
    }

    private func detail(_ b: [String: Any]) -> String {
        let opts = (jsonGet(b, "Options") as? [String: Any]) ?? [:]
        let on = opts.filter { ($0.value as? Bool) == true }.keys.sorted().joined(separator: ", ")
        return ["Jellyfin \(jsonString(b, "ServerVersion") ?? "?")", on, jsonString(b, "Path") ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func load() async {
        guard let client = model.client else { return }
        do {
            let d = try await client.send("GET", "/Backup")
            backups = (try JSONSerialization.jsonObject(with: d) as? [[String: Any]]) ?? []
        } catch {
            if !AppModel.isCancellation(error) { message = "Backups need Jellyfin 10.11 or newer. (\(error.localizedDescription))" }
        }
        loaded = true
    }

    private func create() async {
        busy = true
        defer { busy = false }
        do {
            let body = try JSONSerialization.data(withJSONObject: ["Metadata": metadata, "Trickplay": trickplay, "Subtitles": subtitles, "Database": database])
            try await model.client?.send("POST", "/Backup/Create", body: body, timeout: 3600)
            message = "Backup created."
            await load()
        } catch { message = error.localizedDescription }
    }

    private func restore(_ path: String) async {
        do {
            let body = try JSONSerialization.data(withJSONObject: ["ArchiveFileName": path])
            try await model.client?.send("POST", "/Backup/Restore", body: body)
            message = "Restoring. The server restarts."
        } catch { message = error.localizedDescription }
    }
}

// MARK: - Plugin settings

struct PluginSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let plugin: PluginInfo
    @State private var draft: [String: Any] = [:]
    @State private var original: Data?
    @State private var pages: [(name: String, display: String)] = []
    @State private var loaded = false
    @State private var saving = false
    @State private var message: String?

    var body: some View {
        Form {
            if let message { Section { Text(message).font(.footnote).foregroundStyle(.secondary) } }
            Section {
                LabeledContent("Version", value: plugin.version ?? "?")
                LabeledContent("Status", value: plugin.status ?? "?")
                if let d = plugin.description, !d.isEmpty { Text(d).font(.footnote).foregroundStyle(.secondary) }
            }
            if !loaded {
                Section { HStack { Spacer(); ProgressView(); Spacer() } }
            } else if draft.isEmpty {
                Section { Text("This plugin has no settings.").foregroundStyle(.secondary) }
            } else {
                Section("Settings") { JSONObjectRows(object: $draft) }
            }
            if !pages.isEmpty, let base = model.client?.baseURL.absoluteString {
                Section {
                    ForEach(pages.indices, id: \.self) { i in
                        Button {
                            let name = pages[i].name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? pages[i].name
                            if let url = URL(string: "\(base)/web/#/configurationpage?name=\(name)") { openURL(url) }
                        } label: { Label("Open \(pages[i].display) in Safari", systemImage: "safari") }
                    }
                } header: { Text("Plugin pages") } footer: { Text("This plugin also has its own settings page made for the web dashboard.") }
            }
        }
        .navigationTitle(plugin.name ?? "Plugin")
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
    }

    private var dirty: Bool { loaded && Self.json(draft) != original }
    private static func json(_ o: [String: Any]) -> Data? { try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) }

    private func discard() {
        if let original, let o = try? JSONSerialization.jsonObject(with: original) as? [String: Any] { draft = o }
    }

    private func load() async {
        guard let client = model.client else { return }
        if let d = try? await client.send("GET", "/Plugins/\(plugin.id)/Configuration"),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            draft = o
            original = Self.json(o)
        }
        if let d = try? await client.send("GET", "/web/ConfigurationPages"),
           let list = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] {
            let mine = plugin.id.replacingOccurrences(of: "-", with: "").lowercased()
            pages = list.filter { (jsonString($0, "PluginId") ?? "").replacingOccurrences(of: "-", with: "").lowercased() == mine }
                .compactMap { p -> (name: String, display: String)? in jsonString(p, "Name").map { (name: $0, display: jsonString(p, "DisplayName") ?? $0) } }
        }
        loaded = true
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            try await model.client?.send("POST", "/Plugins/\(plugin.id)/Configuration", body: try JSONSerialization.data(withJSONObject: draft))
            original = Self.json(draft)
            message = "Saved to the server."
        } catch { message = error.localizedDescription }
    }
}

/// Every value of a JSON object as a row: switches, numbers, text, lists as chips; nested objects open in place.
struct JSONObjectRows: View {
    @Binding var object: [String: Any]

    var body: some View {
        ForEach(object.keys.sorted(), id: \.self) { key in
            JSONValueRow(name: key, value: Binding(get: { object[key] ?? NSNull() }, set: { object[key] = $0 }),
                         onRemove: nil)
        }
    }
}

struct JSONValueRow: View {
    let name: String
    @Binding var value: Any
    let onRemove: (() -> Void)?

    var body: some View {
        content
            .swipeActions { if let onRemove { Button(role: .destructive, action: onRemove) { Label("Remove", systemImage: "trash") } } }
    }

    private var label: String { AllServerSettingsView.humanize(name.prefix(1).uppercased() + name.dropFirst()) }

    @ViewBuilder private var content: some View {
        if let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() {
            Toggle(label, isOn: Binding(get: { n.boolValue }, set: { value = $0 }))
        } else if let n = value as? NSNumber {
            let isFloat = CFNumberIsFloatType(n as CFNumber)
            LabeledContent(label) {
                TextField("0", text: Binding(get: { isFloat ? String(format: "%g", n.doubleValue) : n.stringValue }, set: { t in
                    let t = t.replacingOccurrences(of: ",", with: ".")
                    if isFloat { if let d = Double(t) { value = d } } else if let i = Int(t) { value = i } else if t.isEmpty { value = 0 }
                }))
                .keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing).frame(maxWidth: 120)
            }
        } else if value is String || value is NSNull {
            let text = Binding<String>(get: { value as? String ?? "" }, set: { value = $0 })
            let secret = name.range(of: "password|secret|token|apikey", options: [.regularExpression, .caseInsensitive]) != nil
            let long = name.range(of: "css|script|template|description", options: [.regularExpression, .caseInsensitive]) != nil
                || text.wrappedValue.count > 120 || text.wrappedValue.contains("\n")
            VStack(alignment: .leading, spacing: 4) {
                Text(label).font(.subheadline)
                if secret {
                    SecureField(label, text: text)
                } else if long {
                    TextField(label, text: text, axis: .vertical).lineLimit(3...10).font(.callout.monospaced())
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } else {
                    TextField(label, text: text).textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.done)
                }
            }
        } else if let array = value as? [Any], array.allSatisfy({ $0 is String || $0 is NSNumber }) {
            let numeric = array.first is NSNumber
            TagsEditor(label: label, placeholder: "Add", numeric: numeric, values: Binding(get: { array.map { "\($0)" } }, set: { items in
                value = numeric ? items.compactMap { Int($0) } as [Any] : items as [Any]
            }))
        } else if value is [Any] {
            NavigationLink {
                AnyView(JSONArrayPage(title: label, array: Binding(get: { value as? [Any] ?? [] }, set: { value = $0 })))
            } label: {
                LabeledContent(label, value: "\((value as? [Any])?.count ?? 0)")
            }
        } else if value is [String: Any] {
            NavigationLink {
                AnyView(JSONObjectPage(title: label, object: Binding(get: { value as? [String: Any] ?? [:] }, set: { value = $0 })))
            } label: { Text(label) }
        }
    }
}

struct JSONObjectPage: View {
    let title: String
    @Binding var object: [String: Any]
    var body: some View {
        Form { JSONObjectRows(object: $object) }
            .navigationTitle(title)
            .keyboardDoneBar()
    }
}

struct JSONArrayPage: View {
    let title: String
    @Binding var array: [Any]
    var body: some View {
        Form {
            ForEach(array.indices, id: \.self) { i in
                JSONValueRow(name: "\(title) \(i + 1)",
                             value: Binding(get: { array.indices.contains(i) ? array[i] : NSNull() }, set: { if array.indices.contains(i) { array[i] = $0 } }),
                             onRemove: { if array.indices.contains(i) { array.remove(at: i) } })
            }
            if array.isEmpty { Text("Empty").foregroundStyle(.secondary) }
        }
        .navigationTitle(title)
        .keyboardDoneBar()
    }
}
