import SwiftUI

// Library options, as in jellyfin-web's libraryoptionseditor (and the JellyReco desktop client):
// real-time monitoring, metadata language and country, automatic refresh, embedded titles and
// episode info, subtitles, chapter and trickplay images, saving metadata/subtitles/lyrics next to
// the media, metadata savers, local metadata readers, and per item type the metadata downloaders,
// image downloaders, similar-item providers and image limits, plus subtitle and lyric downloaders
// and media segment providers, each with on/off and priority order.

@Observable
@MainActor
final class LibraryOptionsModel {
    struct Plugin: Hashable {
        let name: String
        let defaultEnabled: Bool
    }

    /// The LibraryOptions object as the server stores it (unknown keys are kept).
    private(set) var options: [String: Any] = [:]
    private(set) var avail: [String: Any]?
    private(set) var cultures: [[String: Any]] = []
    private(set) var countries: [[String: Any]] = []
    var error: String?
    private(set) var saving = false
    var savedNote: String?
    @ObservationIgnored private var baseline: [String: Any]?
    /// Bumped on every edit so `dirty` is re-evaluated.
    private var revision = 0

    /// jellyfin-web's defaults for a new library.
    static let newLibraryDefaults: [String: Any] = [
        "Enabled": true, "EnableRealtimeMonitor": true, "EnablePhotos": true, "EnableInternetProviders": true,
        "EnableArchiveMediaFiles": false, "SaveLocalMetadata": false, "EnableAutomaticSeriesGrouping": true,
        "AutomaticRefreshIntervalDays": 0, "SeasonZeroDisplayName": "Specials", "EnableEmbeddedTitles": false,
        "EnableEmbeddedExtrasTitles": false, "EnableEmbeddedEpisodeInfos": false, "AllowEmbeddedSubtitles": "AllowAll",
        "SkipSubtitlesIfEmbeddedSubtitlesPresent": false, "SkipSubtitlesIfAudioTrackMatches": false,
        "SaveSubtitlesWithMedia": true, "SaveLyricsWithMedia": false, "RequirePerfectSubtitleMatch": true,
        "AutomaticallyAddToCollection": false, "EnableTrickplayImageExtraction": true,
        "ExtractTrickplayImagesDuringLibraryScan": false, "SaveTrickplayWithMedia": false,
        "EnableChapterImageExtraction": false, "ExtractChapterImagesDuringLibraryScan": false, "EnableLUFSScan": true,
        "PreferNonstandardArtistsTag": false, "UseCustomTagDelimiters": false, "CustomTagDelimiters": [String](),
        "DelimiterWhitelist": [String](), "TypeOptions": [[String: Any]](),
    ]

    var ready: Bool { avail != nil }
    var dirty: Bool {
        _ = revision
        guard let baseline else { return false }
        return Self.json(options) != Self.json(baseline)
    }

    func load(client: JellyfinClient?, contentType: String?, isNew: Bool, initial: [String: Any]) async {
        options = initial
        avail = nil
        baseline = nil
        error = nil
        guard let client else { return }
        let type = contentType ?? ""
        var query: [String: Any?] = ["isNewLibrary": isNew]
        if !type.isEmpty, type != "mixed" { query["libraryContentType"] = type }
        do {
            let data = try await client.send("GET", "/Libraries/AvailableOptions", query: query)
            let available = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            if cultures.isEmpty { cultures = await Self.list(client, "/Localization/Cultures") }
            if countries.isEmpty { countries = await Self.list(client, "/Localization/Countries") }
            avail = available
            fillExplicitLists()
            baseline = options
            revision += 1
        } catch {
            if !AppModel.isCancellation(error) { self.error = error.localizedDescription }
        }
    }

    func discard() {
        guard let baseline else { return }
        options = baseline
        revision += 1
        savedNote = nil
    }

    /// Saves an existing library's options.
    func save(client: JellyfinClient?, libraryId: String) async {
        guard let client else { return }
        saving = true
        defer { saving = false }
        error = nil
        do {
            let body = try JSONSerialization.data(withJSONObject: ["Id": libraryId, "LibraryOptions": options])
            try await client.send("POST", "/Library/VirtualFolders/LibraryOptions", body: body)
            baseline = options
            revision += 1
            savedNote = "Saved to the server."
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: Values

    func value(_ key: String) -> Any? { Self.get(options, key) }

    func set(_ key: String, _ newValue: Any) {
        options[Self.realKey(options, key)] = newValue
        revision += 1
        savedNote = nil
    }

    func strings(_ key: String) -> [String] { Self.names(value(key)) ?? [] }

    func bool(_ key: String, default def: Bool = false) -> Binding<Bool> {
        Binding(get: { (self.value(key) as? Bool) ?? def }, set: { self.set(key, $0) })
    }

    func string(_ key: String, default def: String = "") -> Binding<String> {
        Binding(get: {
            let s = self.value(key) as? String ?? ""
            return s.isEmpty ? def : s
        }, set: { self.set(key, $0) })
    }

    func plugins(_ key: String) -> [Plugin] { Self.plugins(avail.flatMap { Self.get($0, key) }) }

    // Per item type (TypeOptions).
    var availableTypes: [[String: Any]] { (avail.flatMap { Self.get($0, "TypeOptions") } as? [[String: Any]]) ?? [] }

    func typeOptions(_ type: String) -> [String: Any] {
        ((value("TypeOptions") as? [[String: Any]]) ?? []).first { (Self.get($0, "Type") as? String) == type } ?? ["Type": type]
    }

    func setType(_ type: String, _ patch: [String: Any]) {
        var list = (value("TypeOptions") as? [[String: Any]]) ?? []
        if let i = list.firstIndex(where: { (Self.get($0, "Type") as? String) == type }) {
            for (k, v) in patch { list[i][Self.realKey(list[i], k)] = v }
        } else {
            var entry: [String: Any] = ["Type": type]
            for (k, v) in patch { entry[k] = v }
            list.append(entry)
        }
        set("TypeOptions", list)
    }

    /// jellyfin-web saves explicit provider lists; fill them in once the available plugins are known.
    private func fillExplicitLists() {
        guard let avail else { return }
        func pick(_ plugins: [Plugin], _ enabled: [String]?) -> [String] {
            plugins.filter { enabled?.contains($0.name) ?? $0.defaultEnabled }.map(\.name)
        }
        func disabled(_ plugins: [Plugin], _ current: [String]?) -> [String] {
            current ?? plugins.filter { !$0.defaultEnabled }.map(\.name)
        }
        func order(_ plugins: [Plugin], _ current: Any?) -> [String] {
            Self.ordered(plugins, Self.names(current) ?? []).map(\.name)
        }
        var o = options
        func put(_ k: String, _ v: Any) { o[Self.realKey(o, k)] = v }
        let a = { (k: String) in Self.plugins(Self.get(avail, k)) }
        put("MetadataSavers", pick(a("MetadataSavers"), Self.names(Self.get(o, "MetadataSavers"))))
        put("LocalMetadataReaderOrder", order(a("MetadataReaders"), Self.get(o, "LocalMetadataReaderOrder")))
        put("DisabledSubtitleFetchers", disabled(a("SubtitleFetchers"), Self.names(Self.get(o, "DisabledSubtitleFetchers"))))
        put("SubtitleFetcherOrder", order(a("SubtitleFetchers"), Self.get(o, "SubtitleFetcherOrder")))
        put("DisabledLyricFetchers", disabled(a("LyricFetchers"), Self.names(Self.get(o, "DisabledLyricFetchers"))))
        put("LyricFetcherOrder", order(a("LyricFetchers"), Self.get(o, "LyricFetcherOrder")))
        put("DisabledMediaSegmentProviders", disabled(a("MediaSegmentProviders"), Self.names(Self.get(o, "DisabledMediaSegmentProviders"))))
        put("MediaSegmentProviderOrder", order(a("MediaSegmentProviders"), Self.get(o, "MediaSegmentProviderOrder")))

        var types = (Self.get(o, "TypeOptions") as? [[String: Any]]) ?? []
        for t in (Self.get(avail, "TypeOptions") as? [[String: Any]]) ?? [] {
            guard let type = Self.get(t, "Type") as? String else { continue }
            let i = types.firstIndex { (Self.get($0, "Type") as? String) == type }
            var cur: [String: Any] = i.map { types[$0] } ?? ["Type": type]
            func putT(_ k: String, _ v: Any) { cur[Self.realKey(cur, k)] = v }
            let fetchers = Self.plugins(Self.get(t, "MetadataFetchers"))
            putT("MetadataFetchers", pick(fetchers, Self.names(Self.get(cur, "MetadataFetchers"))))
            putT("MetadataFetcherOrder", order(fetchers, Self.get(cur, "MetadataFetcherOrder")))
            let images = Self.plugins(Self.get(t, "ImageFetchers"))
            putT("ImageFetchers", pick(images, Self.names(Self.get(cur, "ImageFetchers"))))
            putT("ImageFetcherOrder", order(images, Self.get(cur, "ImageFetcherOrder")))
            let similar = Self.plugins(Self.get(t, "SimilarItemProviders"))
            if !similar.isEmpty {
                putT("SimilarItemProviders", pick(similar, Self.names(Self.get(cur, "SimilarItemProviders"))))
                putT("SimilarItemProviderOrder", order(similar, Self.get(cur, "SimilarItemProviderOrder")))
            }
            if let i { types[i] = cur } else { types.append(cur) }
        }
        put("TypeOptions", types)
        options = o
    }

    // MARK: Helpers

    static func get(_ d: [String: Any], _ key: String) -> Any? {
        if let v = d[key] { return v }
        return d.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
    }
    static func realKey(_ d: [String: Any], _ key: String) -> String {
        d.keys.first { $0.caseInsensitiveCompare(key) == .orderedSame } ?? key
    }
    static func names(_ v: Any?) -> [String]? { (v as? [Any])?.compactMap { $0 as? String } }
    static func plugins(_ v: Any?) -> [Plugin] {
        ((v as? [[String: Any]]) ?? []).compactMap { p in
            (get(p, "Name") as? String).map { Plugin(name: $0, defaultEnabled: (get(p, "DefaultEnabled") as? Bool) ?? false) }
        }
    }
    /// Plugins in the configured order; unknown names first (as jellyfin-web sorts them), stable otherwise.
    static func ordered(_ plugins: [Plugin], _ order: [String]) -> [Plugin] {
        plugins.enumerated().sorted { a, b in
            let ia = order.firstIndex(of: a.element.name) ?? -1
            let ib = order.firstIndex(of: b.element.name) ?? -1
            return ia != ib ? ia < ib : a.offset < b.offset
        }.map(\.element)
    }
    private static func json(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
    private static func list(_ client: JellyfinClient, _ path: String) async -> [[String: Any]] {
        guard let d = try? await client.send("GET", path) else { return [] }
        return (try? JSONSerialization.jsonObject(with: d) as? [[String: Any]]) ?? []
    }
}

/// The options as Form sections (put inside a Form).
struct LibraryOptionsSections: View {
    let model: LibraryOptionsModel
    let contentType: String?

    private static let chapterTypes = ["homevideos", "movies", "musicvideos", "tvshows"]
    private static let typeLabels: [String: String] = [
        "Series": "Shows", "Season": "Seasons", "Episode": "Episodes", "Movie": "Movies", "MusicVideo": "Music videos",
        "MusicAlbum": "Albums", "MusicArtist": "Artists", "Audio": "Songs", "BoxSet": "Collections", "Book": "Books",
        "AudioBook": "Audiobooks", "Person": "People", "Video": "Videos", "Photo": "Photos", "PhotoAlbum": "Photo albums",
        "Trailer": "Trailers",
    ]

    private var type: String { (contentType ?? "") == "mixed" ? "" : (contentType ?? "") }

    var body: some View {
        if let error = model.error {
            Section { Text(error).font(.footnote).foregroundStyle(.red) }
        }
        if !model.ready {
            Section { HStack { Spacer(); ProgressView(); Spacer() } }
        } else {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        let isTv = type == "tvshows"
        let isMusic = type == "music"
        let embedded = !["books", "boxsets", "playlists", "music"].contains(type)
        let subtitles = type.isEmpty || ["tvshows", "movies", "musicvideos", "mixed"].contains(type)
        let hasChapters = type.isEmpty || Self.chapterTypes.contains(type)

        Section("General") {
            row("Enabled", "Include this library in scans and on your home screen.", model.bool("Enabled", default: true))
            row("Real-time monitoring", "Changes to files are picked up straight away on supported file systems.", model.bool("EnableRealtimeMonitor"))
            if type == "homevideos" || type == "photos" { row("Display photos", nil, model.bool("EnablePhotos")) }
            if isMusic { row("Audio normalization (LUFS scan)", "Analyses loudness so tracks play at a similar volume.", model.bool("EnableLUFSScan")) }
            if isTv { row("Automatically merge series spread across multiple folders", nil, model.bool("EnableAutomaticSeriesGrouping")) }
            if type == "movies" || type.isEmpty {
                row("Automatically add to collection", "Movies of the same collection (from TMDB) are grouped.", model.bool("AutomaticallyAddToCollection"))
            }
            if isTv {
                LabeledContent("Season zero display name") {
                    TextField("Specials", text: model.string("SeasonZeroDisplayName", default: "Specials"))
                        .multilineTextAlignment(.trailing).submitLabel(.done)
                }
            }
        }

        Section("Metadata") {
            Picker("Preferred download language", selection: model.string("PreferredMetadataLanguage")) {
                Text("Server default").tag("")
                ForEach(Array(cultureOptions(threeLetter: false).enumerated()), id: \.offset) { _, c in Text(c.name).tag(c.code) }
            }
            .pickerStyle(.menu)
            Picker("Country/region", selection: model.string("MetadataCountryCode")) {
                Text("Server default").tag("")
                ForEach(Array(countryOptions.enumerated()), id: \.offset) { _, c in Text(c.name).tag(c.code) }
            }
            .pickerStyle(.menu)
            Picker("Automatically refresh metadata from the internet", selection: refreshDays) {
                ForEach(refreshChoices, id: \.self) { d in Text(d == 0 ? "Never" : "Every \(d) days").tag(d) }
            }
            .pickerStyle(.menu)
            if embedded {
                row("Prefer embedded titles over filenames", "Uses the title stored inside the file, if there is one.", model.bool("EnableEmbeddedTitles"))
                if (model.value("EnableEmbeddedTitles") as? Bool) == true {
                    row("Prefer embedded titles for extras", nil, model.bool("EnableEmbeddedExtrasTitles"))
                }
            }
            if isTv { row("Prefer embedded episode information over filenames", nil, model.bool("EnableEmbeddedEpisodeInfos")) }
            row("Save artwork into media folders", "Images and metadata are kept next to your media, where other apps can use them.", model.bool("SaveLocalMetadata"))
        }

        let savers = model.plugins("MetadataSavers")
        if !savers.isEmpty {
            Section {
                ForEach(savers, id: \.self) { p in
                    Toggle(p.name, isOn: Binding(get: { model.strings("MetadataSavers").contains(p.name) }, set: { on in
                        var list = model.strings("MetadataSavers").filter { $0 != p.name }
                        if on { list.append(p.name) }
                        model.set("MetadataSavers", list)
                    }))
                }
            } header: { Text("Metadata savers") } footer: { Text("File formats to save your metadata to.") }
        }
        let readers = model.plugins("MetadataReaders")
        if readers.count > 1 {
            PluginPriorityList(title: "Metadata readers", help: "Local metadata sources in order of priority. The first file found is read.",
                               plugins: LibraryOptionsModel.ordered(readers, model.strings("LocalMetadataReaderOrder")),
                               enabled: nil) { _, order in model.set("LocalMetadataReaderOrder", order) }
        }

        ForEach(Array(model.availableTypes.enumerated()), id: \.offset) { _, t in
            typeSections(t)
        }

        if subtitles {
            Section("Subtitles") {
                Picker("Allow embedded subtitles", selection: model.string("AllowEmbeddedSubtitles", default: "AllowAll")) {
                    Text("Allow all").tag("AllowAll")
                    Text("Allow text").tag("AllowText")
                    Text("Allow image").tag("AllowImage")
                    Text("Allow none").tag("AllowNone")
                }
                .pickerStyle(.menu)
                NavigationLink {
                    LanguageChecklist(model: model, cultures: cultureOptions(threeLetter: true))
                } label: {
                    LabeledContent("Download languages", value: model.strings("SubtitleDownloadLanguages").isEmpty
                                   ? "None" : model.strings("SubtitleDownloadLanguages").joined(separator: ", "))
                }
                row("Only download subtitles that are a perfect match for my video files", nil, model.bool("RequirePerfectSubtitleMatch", default: true))
                row("Skip if the video already has embedded subtitles", nil, model.bool("SkipSubtitlesIfEmbeddedSubtitlesPresent"))
                row("Skip if the default audio track matches the download language", nil, model.bool("SkipSubtitlesIfAudioTrackMatches"))
                row("Save subtitles into media folders", nil, model.bool("SaveSubtitlesWithMedia", default: true))
            }
            disabledList(title: "Subtitle downloaders", help: "Enable and rank your preferred subtitle downloaders in order of priority.",
                         available: "SubtitleFetchers", disabledKey: "DisabledSubtitleFetchers", orderKey: "SubtitleFetcherOrder")
        }

        if isMusic {
            disabledList(title: "Lyric downloaders", help: "Enable and rank your preferred lyric downloaders in order of priority.",
                         available: "LyricFetchers", disabledKey: "DisabledLyricFetchers", orderKey: "LyricFetcherOrder")
            Section("Lyrics and tags") {
                row("Save lyrics into media folders", nil, model.bool("SaveLyricsWithMedia"))
                row("Prefer the non-standard artists tag", "Use the ARTISTS tag instead of ARTIST when available.", model.bool("PreferNonstandardArtistsTag"))
                row("Use custom tag delimiters", nil, model.bool("UseCustomTagDelimiters"))
                if (model.value("UseCustomTagDelimiters") as? Bool) == true {
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent("Custom tag delimiters") {
                            TextField("e.g. ;/", text: Binding(get: { model.strings("CustomTagDelimiters").joined() },
                                                              set: { model.set("CustomTagDelimiters", $0.map(String.init)) }))
                                .multilineTextAlignment(.trailing).textInputAutocapitalization(.never).autocorrectionDisabled()
                        }
                        Text("Each character splits a tag.").font(.caption).foregroundStyle(.secondary)
                    }
                    TagsEditor(label: "Delimiter whitelist", placeholder: "Add a name", numeric: false,
                               values: Binding(get: { model.strings("DelimiterWhitelist") }, set: { model.set("DelimiterWhitelist", $0) }))
                }
            }
        }

        disabledList(title: "Media segment providers", help: "Enable and rank the providers that find intros, credits and other segments.",
                     available: "MediaSegmentProviders", disabledKey: "DisabledMediaSegmentProviders", orderKey: "MediaSegmentProviderOrder")

        if hasChapters {
            Section("Trickplay and chapter images") {
                row("Enable trickplay image extraction", "Preview pictures while you scrub through a video.", model.bool("EnableTrickplayImageExtraction"))
                row("Extract trickplay images during the library scan", "Otherwise they're made by the scheduled task.", model.bool("ExtractTrickplayImagesDuringLibraryScan"))
                row("Save trickplay images into media folders", nil, model.bool("SaveTrickplayWithMedia"))
                row("Enable chapter image extraction", nil, model.bool("EnableChapterImageExtraction"))
                row("Extract chapter images during the library scan", nil, model.bool("ExtractChapterImagesDuringLibraryScan"))
            }
        }
    }

    // MARK: Pieces

    private func row(_ label: String, _ detail: String?, _ binding: Binding<Bool>) -> some View {
        Toggle(isOn: binding) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    @ViewBuilder
    private func typeSections(_ t: [String: Any]) -> some View {
        let type = LibraryOptionsModel.get(t, "Type") as? String ?? ""
        let label = Self.typeLabels[type] ?? type
        let current = model.typeOptions(type)
        let fetchers = LibraryOptionsModel.plugins(LibraryOptionsModel.get(t, "MetadataFetchers"))
        let images = LibraryOptionsModel.plugins(LibraryOptionsModel.get(t, "ImageFetchers"))
        let similar = LibraryOptionsModel.plugins(LibraryOptionsModel.get(t, "SimilarItemProviders"))
        if !fetchers.isEmpty {
            PluginPriorityList(title: "\(label): metadata downloaders",
                               help: "Enable and rank your preferred metadata downloaders. Lower priority downloaders are only used to fill in missing information.",
                               plugins: LibraryOptionsModel.ordered(fetchers, LibraryOptionsModel.names(LibraryOptionsModel.get(current, "MetadataFetcherOrder")) ?? []),
                               enabled: LibraryOptionsModel.names(LibraryOptionsModel.get(current, "MetadataFetchers")) ?? []) { enabled, order in
                model.setType(type, ["MetadataFetchers": enabled, "MetadataFetcherOrder": order])
            }
        }
        if !images.isEmpty {
            PluginPriorityList(title: "\(label): image downloaders", help: "Enable and rank your preferred image fetchers in order of priority.",
                               plugins: LibraryOptionsModel.ordered(images, LibraryOptionsModel.names(LibraryOptionsModel.get(current, "ImageFetcherOrder")) ?? []),
                               enabled: LibraryOptionsModel.names(LibraryOptionsModel.get(current, "ImageFetchers")) ?? [],
                               onChange: { enabled, order in model.setType(type, ["ImageFetchers": enabled, "ImageFetcherOrder": order]) },
                               trailing: AnyView(NavigationLink {
                                   LibraryImageOptionsView(model: model, type: type, label: label, available: t)
                               } label: { Label("Fetcher settings", systemImage: "photo.on.rectangle") }))
        }
        if !similar.isEmpty {
            PluginPriorityList(title: "\(label): similar item providers", help: "Enable and rank the sources used for similar items.",
                               plugins: LibraryOptionsModel.ordered(similar, LibraryOptionsModel.names(LibraryOptionsModel.get(current, "SimilarItemProviderOrder")) ?? []),
                               enabled: LibraryOptionsModel.names(LibraryOptionsModel.get(current, "SimilarItemProviders")) ?? []) { enabled, order in
                model.setType(type, ["SimilarItemProviders": enabled, "SimilarItemProviderOrder": order])
            }
        }
    }

    /// Lists saved as "disabled" names + an order (subtitle and lyric downloaders, segment providers).
    @ViewBuilder
    private func disabledList(title: String, help: String, available: String, disabledKey: String, orderKey: String) -> some View {
        let plugins = model.plugins(available)
        if !plugins.isEmpty {
            let disabled = model.strings(disabledKey)
            PluginPriorityList(title: title, help: help,
                               plugins: LibraryOptionsModel.ordered(plugins, model.strings(orderKey)),
                               enabled: plugins.map(\.name).filter { !disabled.contains($0) }) { enabled, order in
                model.set(disabledKey, order.filter { !enabled.contains($0) })
                model.set(orderKey, order)
            }
        }
    }

    private var refreshChoices: [Int] {
        let current = (model.value("AutomaticRefreshIntervalDays") as? Int) ?? 0
        return [0, 30, 60, 90].contains(current) ? [0, 30, 60, 90] : ([0, 30, 60, 90] + [current]).sorted()
    }
    private var refreshDays: Binding<Int> {
        Binding(get: { (model.value("AutomaticRefreshIntervalDays") as? Int) ?? 0 }, set: { model.set("AutomaticRefreshIntervalDays", $0) })
    }

    private func cultureOptions(threeLetter: Bool) -> [(code: String, name: String)] {
        model.cultures.compactMap { c -> (code: String, name: String)? in
            let code = LibraryOptionsModel.get(c, threeLetter ? "ThreeLetterISOLanguageName" : "TwoLetterISOLanguageName") as? String ?? ""
            guard !code.isEmpty else { return nil }
            return (code, LibraryOptionsModel.get(c, "DisplayName") as? String ?? code)
        }
    }
    private var countryOptions: [(code: String, name: String)] {
        model.countries.compactMap { c -> (code: String, name: String)? in
            let code = LibraryOptionsModel.get(c, "TwoLetterISORegionName") as? String ?? ""
            guard !code.isEmpty else { return nil }
            return (code, LibraryOptionsModel.get(c, "DisplayName") as? String ?? code)
        }
    }
}

/// Plugins with on/off and up/down (priority), like jellyfin-web.
struct PluginPriorityList: View {
    let title: String
    let help: String
    let plugins: [LibraryOptionsModel.Plugin]
    /// nil = order only (no on/off).
    let enabled: [String]?
    let onChange: ([String], [String]) -> Void
    var trailing: AnyView? = nil

    var body: some View {
        Section {
            ForEach(Array(plugins.enumerated()), id: \.element) { i, p in
                HStack(spacing: 12) {
                    if enabled == nil {
                        Image(systemName: "square.stack.3d.up").foregroundStyle(.secondary)
                    }
                    Text(p.name)
                    Spacer(minLength: 8)
                    Button { move(i, -1) } label: { Image(systemName: "chevron.up") }
                        .buttonStyle(.borderless).foregroundStyle(.primary).disabled(i == 0)
                        .accessibilityLabel("Higher priority")
                    Button { move(i, 1) } label: { Image(systemName: "chevron.down") }
                        .buttonStyle(.borderless).foregroundStyle(.primary).disabled(i == plugins.count - 1)
                        .accessibilityLabel("Lower priority")
                    if let enabled {
                        Toggle("Use \(p.name)", isOn: Binding(get: { enabled.contains(p.name) }, set: { on in
                            var list = enabled.filter { $0 != p.name }
                            if on { list.append(p.name) }
                            onChange(list, order)
                        }))
                        .labelsHidden()
                    }
                }
            }
            if let trailing { trailing }
        } header: { Text(title) } footer: { Text(help) }
    }

    private var order: [String] { plugins.map(\.name) }

    private func move(_ i: Int, _ d: Int) {
        var o = order
        guard o.indices.contains(i + d) else { return }
        o.swapAt(i, i + d)
        onChange(enabled ?? [], o)
    }
}

/// Which images to download for a type, and how many backdrops (jellyfin-web's "Fetcher settings").
struct LibraryImageOptionsView: View {
    let model: LibraryOptionsModel
    let type: String
    let label: String
    let available: [String: Any]

    private static let names: [String: String] = [
        "Primary": "Primary", "Art": "Art", "Banner": "Banner", "Disc": "Disc", "Logo": "Logo", "Thumb": "Thumb",
        "Box": "Box", "BoxRear": "Box (rear)", "Menu": "Menu", "Screenshot": "Screenshot", "Chapter": "Chapter", "Profile": "Profile",
    ]

    private var supported: [String] { LibraryOptionsModel.names(LibraryOptionsModel.get(available, "SupportedImageTypes")) ?? [] }

    var body: some View {
        Form {
            Section("Images to download") {
                ForEach(supported.filter { $0 != "Backdrop" }, id: \.self) { t in
                    Toggle(Self.names[t] ?? t, isOn: Binding(get: { limit(t) > 0 }, set: { on in
                        update(t, limit: on ? 1 : 0, minWidth: 0)
                    }))
                }
            }
            if supported.contains("Backdrop") {
                Section("Backdrops") {
                    LabeledContent("Maximum number of backdrops per item") {
                        TextField("0", text: Binding(get: { String(limit("Backdrop")) }, set: {
                            update("Backdrop", limit: max(0, Int($0) ?? 0), minWidth: minWidth("Backdrop"))
                        }))
                        .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(maxWidth: 80)
                    }
                    LabeledContent("Minimum backdrop download width") {
                        TextField("0", text: Binding(get: { String(minWidth("Backdrop")) }, set: {
                            update("Backdrop", limit: limit("Backdrop"), minWidth: max(0, Int($0) ?? 0))
                        }))
                        .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(maxWidth: 80)
                    }
                }
            }
        }
        .navigationTitle("\(label): images")
        .keyboardDoneBar()
    }

    private func config(_ t: String) -> [String: Any] {
        let mine = (LibraryOptionsModel.get(model.typeOptions(type), "ImageOptions") as? [[String: Any]]) ?? []
        let defaults = (LibraryOptionsModel.get(available, "DefaultImageOptions") as? [[String: Any]]) ?? []
        let match = { (list: [[String: Any]]) in list.first { (LibraryOptionsModel.get($0, "Type") as? String) == t } }
        return match(mine) ?? match(defaults) ?? ["Type": t, "Limit": t == "Primary" ? 1 : 0, "MinWidth": 0]
    }
    private func limit(_ t: String) -> Int { (LibraryOptionsModel.get(config(t), "Limit") as? Int) ?? 0 }
    private func minWidth(_ t: String) -> Int { (LibraryOptionsModel.get(config(t), "MinWidth") as? Int) ?? 0 }

    /// Saves the whole list, as jellyfin-web does.
    private func update(_ t: String, limit: Int, minWidth: Int) {
        var types = supported.filter { $0 != "Backdrop" }
        if supported.contains("Backdrop") { types.append("Backdrop") }
        let list: [[String: Any]] = types.map { name in
            name == t ? ["Type": t, "Limit": limit, "MinWidth": minWidth]
                : ["Type": name, "Limit": self.limit(name), "MinWidth": self.minWidth(name)]
        }
        model.setType(type, ["ImageOptions": list])
    }
}

/// Subtitle download languages (three-letter codes), like jellyfin-web's checklist.
struct LanguageChecklist: View {
    let model: LibraryOptionsModel
    let cultures: [(code: String, name: String)]
    @State private var search = ""

    var body: some View {
        List {
            ForEach(Array(filtered.enumerated()), id: \.offset) { _, c in
                let on = model.strings("SubtitleDownloadLanguages").contains(c.code)
                Button {
                    var list = model.strings("SubtitleDownloadLanguages").filter { $0 != c.code }
                    if !on { list.append(c.code) }
                    model.set("SubtitleDownloadLanguages", list)
                } label: {
                    HStack {
                        Text(c.name).foregroundStyle(.primary)
                        Spacer()
                        if on { Image(systemName: "checkmark").foregroundStyle(.primary).fontWeight(.semibold) }
                    }
                }
            }
        }
        .searchable(text: $search, prompt: "Search languages")
        .navigationTitle("Download languages")
    }

    private var filtered: [(code: String, name: String)] {
        search.isEmpty ? cultures : cultures.filter { $0.name.localizedCaseInsensitiveContains(search) || $0.code.localizedCaseInsensitiveContains(search) }
    }
}
