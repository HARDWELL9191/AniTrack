import SwiftUI

/// Identify, as Jellyfin's web app does it: search the metadata providers by name, year or a
/// provider id, pick the right match, and the server re-identifies the title (new provider ids,
/// a full metadata refresh, optionally new images). Admins only, like on the web.
struct IdentifySheet: View {
    let item: BaseItem
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// One provider id field (Jellyfin's ExternalIdInfos: "TheMovieDb", "TheTVDB Series"…).
    struct IdField: Identifiable { let key: String; let label: String; var id: String { label } }
    /// A search result, kept exactly as the server sent it (Apply wants it back unchanged).
    struct Match: Identifiable, Hashable {
        let id: Int
        let raw: Data
        let name: String
        let year: Int?
        let provider: String?
        let overview: String?
        let imageURL: URL?
        let ids: String
    }

    @State private var name: String
    @State private var year: String
    @State private var idFields: [IdField] = []
    @State private var idValues: [String: String] = [:]
    @State private var matches: [Match]?
    @State private var searching = false
    @State private var path = NavigationPath()

    init(item: BaseItem) {
        self.item = item
        _name = State(initialValue: item.name ?? "")
        _year = State(initialValue: "")
    }

    #if DEBUG
    /// UI tests: the sheet with id fields and results already there (no server).
    init(testing item: BaseItem, fields: [IdField], matches: [Match]) {
        self.init(item: item)
        _idFields = State(initialValue: fields)
        _matches = State(initialValue: matches)
    }
    #endif

    /// Types Jellyfin can identify (jellyfin-web's itemHelper.canIdentify).
    static func canIdentify(_ item: BaseItem) -> Bool {
        [.movie, .trailer, .series, .boxSet, .person, .musicAlbum, .musicArtist, .musicVideo].contains(item.kind)
    }

    private var showsYear: Bool { item.kind != .person && item.kind != .boxSet }
    private var canSearch: Bool {
        !searching && (!name.trimmingCharacters(in: .whitespaces).isEmpty || idValues.values.contains { !$0.isEmpty })
    }

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .onSubmit { Task { await search() } }
                    if showsYear {
                        TextField("Year", text: $year).keyboardType(.numberPad)
                    }
                } footer: {
                    if let folder = item.path, !folder.isEmpty {
                        Text("On the server: \(folder)").textSelection(.enabled)
                    }
                }
                if !idFields.isEmpty {
                    Section {
                        ForEach(idFields) { field in
                            TextField(field.label, text: Binding(
                                get: { idValues[field.key] ?? "" },
                                set: { idValues[field.key] = $0 }))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.asciiCapable)
                        }
                    } header: {
                        Text("Provider IDs")
                    } footer: {
                        Text("An id finds the exact title (e.g. the number in its TMDB or TVDB link). Leave them empty to search by name.")
                    }
                }
                Section {
                    Button {
                        Task { await search() }
                    } label: {
                        HStack {
                            Text("Search")
                            if searching { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(!canSearch)
                }
                if let matches {
                    Section("Results") {
                        if matches.isEmpty {
                            Text("No matches. Try another name, the year, or a provider id.").foregroundStyle(.secondary)
                        }
                        ForEach(matches) { match in
                            NavigationLink(value: match) { MatchRow(match: match) }
                        }
                    }
                }
            }
            .navigationTitle("Identify")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .navigationDestination(for: Match.self) { match in
                IdentifyConfirmView(item: item, match: match) { dismiss() }
            }
            .task { await loadIdFields() }
        }
    }

    private func loadIdFields() async {
        guard idFields.isEmpty, let client = model.client else { return }
        guard let data = try? await client.send("GET", "/Items/\(item.id)/ExternalIdInfos"),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        idFields = list.compactMap { info in
            guard let key = info["Key"] as? String, let label = info["Name"] as? String else { return nil }
            let type = (info["Type"] as? String).map { " " + $0 } ?? ""
            return IdField(key: key, label: "\(label)\(type) Id")
        }
    }

    private func search() async {
        guard canSearch, let client = model.client else { return }
        searching = true
        defer { searching = false }
        var info: [String: Any] = ["ProviderIds": idValues.filter { !$0.value.isEmpty }]
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { info["Name"] = trimmed }
        if showsYear, let y = Int(year.trimmingCharacters(in: .whitespaces)) { info["Year"] = y }
        let query: [String: Any] = ["SearchInfo": info, "ItemId": item.id]
        do {
            let body = try JSONSerialization.data(withJSONObject: query)
            let data = try await client.send("POST", "/Items/RemoteSearch/\(item.kind.rawValue)", body: body, timeout: 120)
            let list = (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
            matches = list.enumerated().compactMap { index, r in
                guard let raw = try? JSONSerialization.data(withJSONObject: r) else { return nil }
                let ids = (r["ProviderIds"] as? [String: Any] ?? [:])
                    .sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: " · ")
                return Match(id: index, raw: raw, name: r["Name"] as? String ?? "Untitled",
                             year: r["ProductionYear"] as? Int, provider: r["SearchProviderName"] as? String,
                             overview: r["Overview"] as? String, imageURL: (r["ImageUrl"] as? String).flatMap(URL.init(string:)),
                             ids: ids)
            }
        } catch {
            model.report(error)
        }
    }
}

private struct MatchRow: View {
    let match: IdentifySheet.Match

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RemoteImage(url: match.imageURL)
                .frame(width: 54, height: 80)
                .clipShape(.rect(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 3) {
                Text(match.year.map { "\(match.name) (\(String($0)))" } ?? match.name).font(.headline)
                if let provider = match.provider { Text(provider).font(.caption).foregroundStyle(.secondary) }
                if !match.ids.isEmpty { Text(match.ids).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
                if let overview = match.overview, !overview.isEmpty {
                    Text(overview).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// The pick: "Replace existing images" (on, as on the web), then Identify.
private struct IdentifyConfirmView: View {
    let item: BaseItem
    let match: IdentifySheet.Match
    let onDone: () -> Void
    @Environment(AppModel.self) private var model
    @State private var replaceImages = true
    @State private var applying = false

    var body: some View {
        Form {
            Section { MatchRow(match: match) }
            Section {
                Toggle("Replace existing images", isOn: $replaceImages)
            } footer: {
                Text("\(item.name ?? "This title") becomes \(match.name): the server sets its provider ids and refreshes all of its metadata. For a show with many episodes this takes a moment.")
            }
            Section {
                Button {
                    Task { await apply() }
                } label: {
                    HStack {
                        Text(applying ? "Identifying…" : "Identify")
                        if applying { Spacer(); ProgressView() }
                    }
                }
                .disabled(applying)
            }
        }
        .navigationTitle(match.name)
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(applying)
    }

    private func apply() async {
        guard let client = model.client else { return }
        applying = true
        defer { applying = false }
        do {
            // The server answers once the refresh is done (it can take a while for a whole show).
            try await client.send("POST", "/Items/RemoteSearch/Apply/\(item.id)",
                                  query: ["replaceAllImages": replaceImages], body: match.raw, timeout: 600)
            model.bumpContent()
            onDone()
        } catch {
            model.report(error)
        }
    }
}
