import SwiftUI

// MARK: - Libraries (add, remove, rename, folders, options) — the dashboard's Libraries page

struct LibraryAdminDetail: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let folder: VirtualFolderInfo
    let reload: () async -> Void

    @State private var options = LibraryOptionsModel()
    @State private var locations: [String] = []
    @State private var newPath = ""
    @State private var browsing = false
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmDelete = false
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                ForEach(locations, id: \.self) { path in
                    Label(path, systemImage: "folder.fill").font(.callout.monospaced())
                        .swipeActions {
                            Button(role: .destructive) { Task { await removePath(path) } } label: { Label("Remove", systemImage: "trash") }
                        }
                }
                HStack {
                    TextField("/path/on/server", text: $newPath)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().font(.callout.monospaced())
                        .submitLabel(.done)
                    Button { browsing = true } label: { Image(systemName: "folder.badge.plus") }
                        .buttonStyle(.borderless).foregroundStyle(.primary)
                        .accessibilityLabel("Browse the server")
                    Button("Add") { Task { await addPath(newPath) } }
                        .buttonStyle(.borderless)
                        .disabled(newPath.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: { Text("Folders") } footer: { Text("Swipe a folder to remove it. Paths are on the server.") }

            Section {
                Button { Task { await scan() } } label: { Label("Scan library files", systemImage: "arrow.triangle.2.circlepath") }
                Button { newName = folder.name ?? ""; renaming = true } label: { Label("Rename", systemImage: "pencil") }
                Button(role: .destructive) { confirmDelete = true } label: {
                    Label("Remove library", systemImage: "trash").foregroundStyle(.red)
                }
            } header: { Text("Manage") }
            if let message { Section { Text(message).font(.footnote).foregroundStyle(.secondary) } }

            LibraryOptionsSections(model: options, contentType: folder.collectionType)

            if let note = options.savedNote {
                Section { Label(note, systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            }
        }
        .navigationTitle(folder.name ?? "Library")
        .keyboardDoneBar()
        .toolbar {
            if options.dirty {
                ToolbarItem(placement: .cancellationAction) { Button("Discard") { options.discard() } }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Keyboard.dismiss()
                    Task { await options.save(client: model.client, libraryId: folder.itemId ?? ""); await reload() }
                }
                .disabled(!options.dirty || options.saving)
            }
        }
        .sheet(isPresented: $browsing) {
            ServerPathPicker(files: false) { picked in Task { await addPath(picked) } }
        }
        .alert("Rename library", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Rename") { Task { await rename() } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Remove \(folder.name ?? "this library")?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Remove library", role: .destructive) { Task { await remove() } }
        } message: {
            Text("Removes the library from Jellyfin. Your files on disk aren't deleted.")
        }
        .task { await load() }
    }

    private func load() async {
        locations = folder.locations ?? []
        guard let client = model.client,
              let data = try? await client.send("GET", "/Library/VirtualFolders"),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let mine = list.first(where: { Self.string($0, "ItemId") == folder.itemId }) else {
            await options.load(client: model.client, contentType: folder.collectionType, isNew: false, initial: [:])
            return
        }
        if let locs = Self.value(mine, "Locations") as? [String] { locations = locs }
        await options.load(client: client, contentType: folder.collectionType, isNew: false,
                           initial: Self.value(mine, "LibraryOptions") as? [String: Any] ?? [:])
    }

    private func addPath(_ raw: String) async {
        let path = raw.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty, !locations.contains(path) else { return }
        do {
            let body = try JSONSerialization.data(withJSONObject: ["Name": folder.name ?? "", "PathInfo": ["Path": path]])
            try await model.client?.send("POST", "/Library/VirtualFolders/Paths", query: ["refreshLibrary": true], body: body)
            locations.append(path)
            newPath = ""
            message = "Folder added."
            await reload()
        } catch { message = error.localizedDescription }
    }

    private func removePath(_ path: String) async {
        do {
            try await model.client?.send("DELETE", "/Library/VirtualFolders/Paths",
                                         query: ["name": folder.name ?? "", "path": path, "refreshLibrary": true])
            locations.removeAll { $0 == path }
            await reload()
        } catch { message = error.localizedDescription }
    }

    private func rename() async {
        do {
            try await model.client?.send("POST", "/Library/VirtualFolders/Name",
                                         query: ["name": folder.name ?? "", "newName": newName, "refreshLibrary": true])
            await reload()
            dismiss()
        } catch { message = error.localizedDescription }
    }

    private func remove() async {
        do {
            try await model.client?.send("DELETE", "/Library/VirtualFolders", query: ["name": folder.name ?? "", "refreshLibrary": true])
            await reload()
            dismiss()
        } catch { message = error.localizedDescription }
    }

    private func scan() async {
        guard let id = folder.itemId else { return }
        do {
            try await model.client?.send("POST", "/Items/\(id)/Refresh", query: [
                "recursive": true, "metadataRefreshMode": "Default", "imageRefreshMode": "Default",
                "replaceAllMetadata": false, "replaceAllImages": false,
            ])
            message = "Scan started."
        } catch { message = error.localizedDescription }
    }

    static func value(_ dict: [String: Any], _ key: String) -> Any? {
        dict.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
    }
    static func string(_ dict: [String: Any], _ key: String) -> String? { value(dict, key) as? String }
}

struct AddLibrarySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let reload: () async -> Void
    @State private var name = ""
    @State private var type = "movies"
    @State private var paths: [String] = []
    @State private var typedPath = ""
    @State private var browsing = false
    @State private var options = LibraryOptionsModel()
    @State private var error: String?
    @State private var working = false

    /// jellyfin-web's content types, in its order.
    static let types: [(String, String)] = [
        ("movies", "Movies"), ("tvshows", "Shows"), ("music", "Music"), ("musicvideos", "Music videos"),
        ("homevideos", "Home videos and photos"), ("boxsets", "Collections"), ("books", "Books"), ("mixed", "Mixed movies and shows"),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Content type", selection: $type) {
                        ForEach(Self.types.indices, id: \.self) { i in Text(Self.types[i].1).tag(Self.types[i].0) }
                    }
                    .pickerStyle(.menu)
                    TextField("Display name", text: $name).submitLabel(.done)
                }
                Section {
                    ForEach(paths, id: \.self) { p in
                        Label(p, systemImage: "folder.fill").font(.callout.monospaced())
                            .swipeActions {
                                Button(role: .destructive) { paths.removeAll { $0 == p } } label: { Label("Remove", systemImage: "trash") }
                            }
                    }
                    HStack {
                        TextField("/path/on/server", text: $typedPath)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().font(.callout.monospaced())
                            .submitLabel(.done).onSubmit(addTyped)
                        Button { browsing = true } label: { Image(systemName: "folder.badge.plus") }
                            .buttonStyle(.borderless).foregroundStyle(.primary)
                            .accessibilityLabel("Browse the server")
                        Button("Add", action: addTyped).buttonStyle(.borderless).disabled(typedPath.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: { Text("Folders") } footer: { Text("Folders on the server. Swipe one to remove it.") }

                LibraryOptionsSections(model: options, contentType: type)

                if let error { Section { Text(error).foregroundStyle(.red).font(.footnote) } }
            }
            .navigationTitle("Add library")
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDoneBar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { await add() } }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || paths.isEmpty || working || !options.ready)
                }
            }
            .sheet(isPresented: $browsing) {
                ServerPathPicker(files: false) { picked in if !paths.contains(picked) { paths.append(picked) } }
            }
            // A new library starts with jellyfin-web's defaults; the editor fills in the providers for the type.
            .task(id: type) {
                await options.load(client: model.client, contentType: type, isNew: true, initial: LibraryOptionsModel.newLibraryDefaults)
            }
        }
    }

    private func addTyped() {
        let p = typedPath.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else { return }
        if !paths.contains(p) { paths.append(p) }
        typedPath = ""
    }

    private func add() async {
        working = true
        defer { working = false }
        var query: [String: Any?] = ["name": name.trimmingCharacters(in: .whitespaces), "refreshLibrary": true]
        if type != "mixed" { query["collectionType"] = type }
        var libraryOptions = options.options
        libraryOptions["PathInfos"] = paths.map { ["Path": $0] }
        do {
            let body = try JSONSerialization.data(withJSONObject: ["LibraryOptions": libraryOptions])
            try await model.client?.send("POST", "/Library/VirtualFolders", query: query, body: body)
            await reload()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

// MARK: - Plugin catalog and repositories

struct PluginCatalogView: View {
    @Environment(AppModel.self) private var model
    @State private var packages: [[String: Any]] = []
    @State private var installed: Set<String> = []
    @State private var search = ""
    @State private var message: String?
    @State private var loading = true

    var body: some View {
        List {
            if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            let groups = Dictionary(grouping: filtered, by: { (LibraryAdminDetail.string($0, "Category") ?? "Other") })
            ForEach(groups.keys.sorted(), id: \.self) { category in
                Section(category) {
                    ForEach(groups[category] ?? [], id: \.pkgId) { pkg in
                        let name = LibraryAdminDetail.string(pkg, "Name") ?? ""
                        let versions = LibraryAdminDetail.value(pkg, "Versions") as? [[String: Any]] ?? []
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(name).font(.headline)
                                if let o = LibraryAdminDetail.string(pkg, "Overview") ?? LibraryAdminDetail.string(pkg, "Description") {
                                    Text(o).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                                }
                                if let v = versions.first.flatMap({ LibraryAdminDetail.string($0, "Version") }) {
                                    Text("Latest \(v)").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if installed.contains(name.lowercased()) {
                                Text("Installed").font(.caption.weight(.semibold)).foregroundStyle(.green)
                            } else if let latest = versions.first {
                                Button("Install") { Task { await install(pkg, version: latest) } }
                                    .buttonStyle(.glass).controlSize(.small)
                            }
                        }
                    }
                }
            }
        }
        .overlay { if loading && packages.isEmpty { ProgressView() } }
        .searchable(text: $search, prompt: "Search plugins")
        .navigationTitle("Catalog")
        .task { await load() }
        .refreshable { await load() }
    }

    private var filtered: [[String: Any]] {
        packages.filter { search.isEmpty || (LibraryAdminDetail.string($0, "Name") ?? "").localizedCaseInsensitiveContains(search) }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        guard let client = model.client else { return }
        if let data = try? await client.send("GET", "/Packages"),
           let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            packages = list.sorted { (LibraryAdminDetail.string($0, "Name") ?? "") < (LibraryAdminDetail.string($1, "Name") ?? "") }
        }
        if let plugins = try? await client.get("/Plugins", as: [PluginInfo].self) {
            installed = Set(plugins.compactMap { $0.name?.lowercased() })
        }
    }

    private func install(_ pkg: [String: Any], version: [String: Any]) async {
        let name = LibraryAdminDetail.string(pkg, "Name") ?? ""
        var query: [String: Any?] = [:]
        if let guid = LibraryAdminDetail.string(pkg, "Guid") { query["assemblyGuid"] = guid }
        if let v = LibraryAdminDetail.string(version, "Version") { query["version"] = v }
        if let url = LibraryAdminDetail.string(version, "RepositoryUrl") { query["repositoryUrl"] = url }
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        do {
            try await model.client?.send("POST", "/Packages/Installed/\(encoded)", query: query)
            message = "Installing \(name). Restart the server to finish."
            installed.insert(name.lowercased())
        } catch { message = error.localizedDescription }
    }
}

private extension Dictionary where Key == String, Value == Any {
    var pkgId: String { (LibraryAdminDetail.string(self, "Guid") ?? "") + (LibraryAdminDetail.string(self, "Name") ?? "") }
}

struct PluginRepositoriesView: View {
    @Environment(AppModel.self) private var model
    @State private var repos: [[String: Any]] = []
    @State private var adding = false
    @State private var newName = ""
    @State private var newURL = ""
    @State private var message: String?

    var body: some View {
        List {
            if let message { Text(message).font(.footnote).foregroundStyle(.red) }
            ForEach(repos.indices, id: \.self) { i in
                let repo = repos[i]
                VStack(alignment: .leading, spacing: 3) {
                    Toggle(LibraryAdminDetail.string(repo, "Name") ?? "Repository", isOn: Binding(
                        get: { (LibraryAdminDetail.value(repo, "Enabled") as? Bool) ?? true },
                        set: { on in repos[i]["Enabled"] = on; Task { await save() } }))
                    Text(LibraryAdminDetail.string(repo, "Url") ?? "").font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                .swipeActions {
                    Button(role: .destructive) { repos.remove(at: i); Task { await save() } } label: { Label("Delete", systemImage: "trash") }
                }
            }
        }
        .navigationTitle("Repositories")
        .toolbar { Button("Add", systemImage: "plus") { adding = true } }
        .alert("Add repository", isPresented: $adding) {
            TextField("Name", text: $newName)
            TextField("Repository URL", text: $newURL).textInputAutocapitalization(.never)
            Button("Add") {
                repos.append(["Name": newName, "Url": newURL, "Enabled": true])
                newName = ""; newURL = ""
                Task { await save() }
            }
            Button("Cancel", role: .cancel) {}
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        guard let data = try? await model.client?.send("GET", "/Repositories"),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        repos = list.map { r in
            ["Name": LibraryAdminDetail.string(r, "Name") ?? "", "Url": LibraryAdminDetail.string(r, "Url") ?? "",
             "Enabled": (LibraryAdminDetail.value(r, "Enabled") as? Bool) ?? true]
        }
    }

    private func save() async {
        do {
            let body = try JSONSerialization.data(withJSONObject: repos)
            try await model.client?.send("POST", "/Repositories", body: body)
            message = nil
        } catch { message = error.localizedDescription }
    }
}
