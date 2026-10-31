import SwiftUI
import PhotosUI
import UIKit

// MARK: - Store

/// The server's own configuration objects, exactly as jellyfin-web's dashboard edits them.
enum ConfigStore: String, CaseIterable, Identifiable, Hashable {
    case system, encoding, network, livetv, metadata, xbmcmetadata, branding
    var id: String { rawValue }
    var path: String { self == .system ? "/System/Configuration" : "/System/Configuration/\(rawValue)" }
    var title: String {
        switch self {
        case .system: return "Server"
        case .encoding: return "Transcoding"
        case .network: return "Networking"
        case .livetv: return "Live TV"
        case .metadata: return "Metadata"
        case .xbmcmetadata: return "NFO"
        case .branding: return "Branding"
        }
    }
}

/// Loads, edits and saves configuration objects as raw JSON, so every field the server has
/// (including ones this app doesn't know by name) is kept intact when saving.
@Observable
@MainActor
final class ConfigEditor {
    private(set) var values: [ConfigStore: [String: Any]] = [:]
    private(set) var dirty: Set<ConfigStore> = []
    private(set) var loading = false
    /// Values loaded from the server (for Discard).
    @ObservationIgnored private var original: [ConfigStore: [String: Any]] = [:]
    /// Server lists some dropdowns need (languages, countries, users).
    var ctx: [String: [ConfigOption]] = [:]
    private(set) var saving = false
    var error: String?
    var savedNote: String?

    func load(_ stores: [ConfigStore], client: JellyfinClient?) async {
        guard let client else { return }
        loading = true
        defer { loading = false }
        for store in stores {
            do {
                let data = try await client.send("GET", store.path)
                values[store] = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
                original[store] = values[store]
            } catch {
                if !AppModel.isCancellation(error) { self.error = "\(store.title): \(error.localizedDescription)" }
            }
        }
        dirty = []
    }

    /// For objects that aren't one of the configuration stores (e.g. a library's options):
    /// edit `object` under `.system` and save through `customSave`.
    @ObservationIgnored var customSave: (([String: Any]) async throws -> Void)?
    func inject(_ object: [String: Any]) {
        values[.system] = object
        dirty = []
    }

    func save(client: JellyfinClient?) async {
        if let customSave {
            saving = true
            defer { saving = false }
            error = nil
            do {
                try await customSave(values[.system] ?? [:])
                dirty = []
                savedNote = "Saved to the server."
            } catch {
                self.error = error.localizedDescription
            }
            return
        }
        guard let client else { return }
        saving = true
        defer { saving = false }
        error = nil
        for store in dirty {
            guard let object = values[store] else { continue }
            do {
                let body = try JSONSerialization.data(withJSONObject: object)
                try await client.send("POST", store.path, body: body)
            } catch {
                self.error = "\(store.title): \(error.localizedDescription)"
                return
            }
        }
        dirty = []
        savedNote = "Saved to the server."
    }

    // Keys may be nested one level: "TrickplayOptions.Interval".
    func value(_ store: ConfigStore, _ key: String) -> Any? {
        let parts = key.split(separator: ".").map(String.init)
        guard let root = values[store] else { return nil }
        if parts.count == 2 { return (Self.lookup(root, parts[0]) as? [String: Any]).flatMap { Self.lookup($0, parts[1]) } }
        return Self.lookup(root, key)
    }

    func set(_ store: ConfigStore, _ key: String, _ newValue: Any) {
        var root = values[store] ?? [:]
        let parts = key.split(separator: ".").map(String.init)
        if parts.count == 2 {
            let outerKey = Self.realKey(root, parts[0])
            var inner = root[outerKey] as? [String: Any] ?? [:]
            inner[Self.realKey(inner, parts[1])] = newValue
            root[outerKey] = inner
        } else {
            root[Self.realKey(root, key)] = newValue
        }
        values[store] = root
        dirty.insert(store)
        savedNote = nil
    }

    func has(_ store: ConfigStore, _ key: String) -> Bool {
        value(store, key) != nil
    }

    /// Values without a server (UI tests and previews).
    func preload(_ stores: [ConfigStore: [String: Any]]) {
        for (store, v) in stores { values[store] = v; original[store] = v }
        dirty = []
    }

    func discard() {
        for (store, v) in original { values[store] = v }
        dirty = []
        savedNote = nil
    }

    private static func realKey(_ dict: [String: Any], _ key: String) -> String {
        dict.keys.first { $0.caseInsensitiveCompare(key) == .orderedSame } ?? key
    }
    private static func lookup(_ dict: [String: Any], _ key: String) -> Any? {
        dict[realKey(dict, key)]
    }

    // MARK: Typed bindings

    func bool(_ store: ConfigStore, _ key: String) -> Binding<Bool> {
        Binding(get: { (self.value(store, key) as? NSNumber)?.boolValue ?? false },
                set: { self.set(store, key, $0) })
    }

    func int(_ store: ConfigStore, _ key: String) -> Binding<String> {
        Binding(get: {
            if let n = self.value(store, key) as? NSNumber { return n.stringValue }
            return ""
        }, set: { text in
            let digits = text.filter { $0.isNumber || $0 == "-" }
            if digits.isEmpty { self.set(store, key, NSNull()) } else if let n = Int(digits) { self.set(store, key, n) }
        })
    }

    func double(_ store: ConfigStore, _ key: String) -> Binding<String> {
        Binding(get: { (self.value(store, key) as? NSNumber).map { "\($0.doubleValue)" } ?? "" },
                set: { if let d = Double($0.replacingOccurrences(of: ",", with: ".")) { self.set(store, key, d) } })
    }

    func text(_ store: ConfigStore, _ key: String) -> Binding<String> {
        Binding(get: { self.value(store, key) as? String ?? "" },
                set: { self.set(store, key, $0) })
    }

    /// Enums come back as strings in Jellyfin's JSON.
    func choice(_ store: ConfigStore, _ key: String) -> Binding<String> {
        Binding(get: {
            if let s = self.value(store, key) as? String { return s }
            if let n = self.value(store, key) as? NSNumber { return n.stringValue }
            return ""
        }, set: { self.set(store, key, $0) })
    }

    /// String lists edited as one entry per line.
    func list(_ store: ConfigStore, _ key: String) -> Binding<String> {
        Binding(get: {
            ((self.value(store, key) as? [Any]) ?? []).map { "\($0)" }.joined(separator: "\n")
        }, set: { text in
            let items = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            // Keep numbers numbers (e.g. trickplay widths), strings strings.
            let numeric = ((self.value(store, key) as? [Any]) ?? []).first is NSNumber
            if numeric {
                self.set(store, key, items.compactMap { Int($0) })
            } else {
                self.set(store, key, items)
            }
        })
    }

    /// Bits per second shown as Mbps (like jellyfin-web); empty / 0 = no limit.
    func mbps(_ store: ConfigStore, _ key: String) -> Binding<String> {
        Binding(get: {
            let bits = (self.value(store, key) as? NSNumber)?.doubleValue ?? 0
            return bits > 0 ? String(format: "%g", bits / 1_000_000) : ""
        }, set: { text in
            let mb = Double(text.replacingOccurrences(of: ",", with: ".")) ?? 0
            self.set(store, key, Int(mb * 1_000_000))
        })
    }
}

// MARK: - Field descriptions (jellyfin-web's dashboard pages, as in JellyReco desktop)

/// A dropdown value: Jellyfin stores strings, numbers, booleans or null.
enum ConfigValue: Hashable {
    case string(String), int(Int), bool(Bool), null

    init(_ raw: Any?) {
        switch raw {
        case let n as NSNumber where CFGetTypeID(n) == CFBooleanGetTypeID(): self = .bool(n.boolValue)
        case let n as NSNumber: self = .int(n.intValue)
        case let s as String: self = s.isEmpty ? .null : .string(s)
        default: self = .null
        }
    }

    var raw: Any {
        switch self {
        case .string(let s): return s
        case .int(let i): return i
        case .bool(let b): return b
        case .null: return NSNull()
        }
    }
}

struct ConfigOption: Hashable {
    let value: ConfigValue
    let label: String
    init(_ value: ConfigValue, _ label: String) { self.value = value; self.label = label }
}

/// One switch in a "switches" set: a value in a list (`listValue`) or its own true/false key (`flag`).
struct ConfigSwitch {
    let label: String
    var listValue: String? = nil
    var flag: String? = nil
    var show: (@MainActor (ConfigEditor) -> Bool)? = nil
}

struct ConfigField: Identifiable {
    struct NumberSpec {
        var min: Double? = nil
        var max: Double? = nil
        /// Stored value = shown value × scale (Mbps → bits, minutes → seconds).
        var scale: Double = 1
        var nullable = false
        var integer = true
        var placeholder: String? = nil
    }
    enum Kind {
        case toggle, int, double, text, multiline, secure, list, mbps
        case choice([(value: String, label: String)])
        case number(NumberSpec)
        case select(options: @MainActor (ConfigEditor) -> [ConfigOption], emptyAs: ConfigValue?)
        case switches(@MainActor (ConfigEditor) -> [ConfigSwitch])
        case tags(numeric: Bool, placeholder: String)
        case path(files: Bool)
        case readOnly
        case note(warn: Bool)
        case publishedURIs
        case splash
    }
    let store: ConfigStore
    let key: String
    let label: String
    var footer: String?
    let kind: Kind
    var show: (@MainActor (ConfigEditor) -> Bool)? = nil
    var id: String { "\(store.rawValue).\(key).\(label)" }

    init(_ store: ConfigStore, _ key: String, _ label: String, _ kind: Kind, _ footer: String? = nil,
         show: (@MainActor (ConfigEditor) -> Bool)? = nil) {
        self.store = store
        self.key = key
        self.label = label
        self.kind = kind
        self.footer = footer
        self.show = show
    }
}

struct ConfigSection: Identifiable {
    let title: String
    var footer: String?
    let fields: [ConfigField]
    var show: (@MainActor (ConfigEditor) -> Bool)? = nil
    var id: String { title + (fields.first?.id ?? "") }
    init(_ title: String, footer: String? = nil, show: (@MainActor (ConfigEditor) -> Bool)? = nil, _ fields: [ConfigField]) {
        self.title = title
        self.footer = footer
        self.show = show
        self.fields = fields
    }
}

/// Server lists a page's dropdowns need.
enum ConfigContext: String { case languages, cultures, countries, users }

struct ConfigPage: Identifiable, Hashable {
    let title: String
    let symbol: String
    var intro: String? = nil
    var context: [ConfigContext] = []
    let sections: [ConfigSection]
    var id: String { title }
    var stores: [ConfigStore] { Array(Set(sections.flatMap { $0.fields.map(\.store) })).sorted { $0.rawValue < $1.rawValue } }
    static func == (a: ConfigPage, b: ConfigPage) -> Bool { a.title == b.title }
    func hash(into h: inout Hasher) { h.combine(title) }
}

// MARK: - Catalog

private typealias F = ConfigField
private typealias S = ConfigSection
private func o(_ pairs: (ConfigValue, String)...) -> [ConfigOption] { pairs.map { ConfigOption($0.0, $0.1) } }
private func s(_ pairs: [(String, String)]) -> [ConfigOption] { pairs.map { ConfigOption(.string($0.0), $0.1) } }
@MainActor private func fixed(_ list: [ConfigOption]) -> @MainActor (ConfigEditor) -> [ConfigOption] { { _ in list } }
@MainActor private func has(_ store: ConfigStore, _ key: String) -> @MainActor (ConfigEditor) -> Bool { { $0.value(store, key) != nil } }

/// Transcoding helpers (jellyfin-web features/playback/constants/codecs.ts).
@MainActor private enum HW {
    static let types = s([("none", "None"), ("amf", "AMD AMF"), ("nvenc", "Nvidia NVENC"), ("qsv", "Intel Quicksync (QSV)"),
                          ("vaapi", "Video Acceleration API (VAAPI)"), ("rkmpp", "Rockchip MPP (RKMPP)"),
                          ("videotoolbox", "Apple VideoToolBox"), ("v4l2m2m", "Video4Linux2 (V4L2)")])
    static let codecs: [(name: String, codec: String, types: [String])] = [
        ("H264", "h264", ["amf", "nvenc", "qsv", "vaapi", "rkmpp", "videotoolbox", "v4l2m2m"]),
        ("HEVC", "hevc", ["amf", "nvenc", "qsv", "vaapi", "rkmpp", "videotoolbox"]),
        ("MPEG1", "mpeg1video", ["rkmpp"]),
        ("MPEG2", "mpeg2video", ["amf", "nvenc", "qsv", "vaapi", "rkmpp"]),
        ("MPEG4", "mpeg4", ["nvenc", "rkmpp"]),
        ("VC1", "vc1", ["amf", "nvenc", "qsv", "vaapi"]),
        ("VP8", "vp8", ["nvenc", "qsv", "vaapi", "rkmpp", "videotoolbox"]),
        ("VP9", "vp9", ["amf", "nvenc", "qsv", "vaapi", "rkmpp", "videotoolbox"]),
        ("AV1", "av1", ["amf", "nvenc", "qsv", "vaapi", "rkmpp", "videotoolbox"]),
    ]
    static let tenBit = ["amf", "nvenc", "qsv", "vaapi", "rkmpp"]
    static let rext = ["nvenc", "qsv", "vaapi"]
    static let hwa = ["amf", "nvenc", "qsv", "vaapi", "rkmpp", "videotoolbox"]
    /// Older servers saved "" for no acceleration.
    static func current(_ e: ConfigEditor) -> String {
        let v = e.value(.encoding, "HardwareAccelerationType") as? String ?? ""
        return v.isEmpty ? "none" : v
    }
    static func only(_ t: String...) -> @MainActor (ConfigEditor) -> Bool { { t.contains(current($0)) } }
    static func on(_ e: ConfigEditor) -> Bool { current(e) != "none" }
    /// jellyfin-web's "Enable hardware decoding for" checkboxes for the chosen acceleration.
    static func decodeSwitches(_ e: ConfigEditor) -> [ConfigSwitch] {
        let type = current(e)
        var out: [ConfigSwitch] = codecs.filter { $0.types.contains(type) }.map { ConfigSwitch(label: $0.name, listValue: $0.codec) }
        if tenBit.contains(type) {
            out.append(ConfigSwitch(label: "HEVC 10bit", flag: "EnableDecodingColorDepth10Hevc"))
            out.append(ConfigSwitch(label: "VP9 10bit", flag: "EnableDecodingColorDepth10Vp9"))
        }
        if rext.contains(type) {
            if e.value(.encoding, "EnableDecodingColorDepth10HevcRext") != nil {
                out.append(ConfigSwitch(label: "HEVC RExt 8/10bit", flag: "EnableDecodingColorDepth10HevcRext"))
            }
            if e.value(.encoding, "EnableDecodingColorDepth12HevcRext") != nil {
                out.append(ConfigSwitch(label: "HEVC RExt 12bit", flag: "EnableDecodingColorDepth12HevcRext"))
            }
        }
        return out
    }
    static func accel(_ e: ConfigEditor) -> Bool { hwa.contains(current(e)) }
}

private let resolutions = s([("MatchSource", "Match source"), ("P2160", "2160p"), ("P1440", "1440p"), ("P1080", "1080p"),
                             ("P720", "720p"), ("P480", "480p"), ("P360", "360p"), ("P240", "240p"), ("P144", "144p")])

@MainActor private func fromContext(_ key: ConfigContext, leading: [ConfigOption] = []) -> @MainActor (ConfigEditor) -> [ConfigOption] {
    { leading + ($0.ctx[key.rawValue] ?? []) }
}

@MainActor enum ServerSettingsCatalog {
    static let pages: [ConfigPage] = [general, branding, display, metadata, nfo, transcoding, resume, streaming, trickplay, networking, dvr]

    static let general = ConfigPage(title: "General", symbol: "gearshape.fill", context: [.languages], sections: [
        S("Settings", [
            F(.system, "ServerName", "Server name", .text, "Identifies this server. Defaults to the server's hostname."),
            F(.system, "UICulture", "Preferred display language", .select(options: fromContext(.languages), emptyAs: nil),
              "The language of the server's own pages and messages."),
        ]),
        S("Paths", [
            F(.system, "CachePath", "Cache path", .path(files: false), "Where cache files like images go. Leave blank for the server default."),
            F(.system, "MetadataPath", "Metadata path", .path(files: false), "Where downloaded artwork and metadata go."),
        ]),
        S("Quick Connect", [
            F(.system, "QuickConnectAvailable", "Enable Quick Connect on this server", .toggle,
              "Sign in on a new device with a code from one that's already signed in."),
        ]),
        S("Performance", [
            F(.system, "LibraryScanFanoutConcurrency", "Parallel library scan tasks limit", .number(.init(min: 0)),
              "The most tasks a library scan runs at once. 0 picks a limit from the CPU core count. Too high can cause problems with network drives."),
            F(.system, "ParallelImageEncodingLimit", "Parallel image encoding limit", .number(.init(min: 0)),
              "The most image encodings at once. 0 picks a limit from the CPU core count."),
        ]),
        S("More server options", footer: "Options jellyfin-web doesn't show (they're normally only in the server's config file).", [
            F(.system, "LibraryMetadataRefreshConcurrency", "Parallel metadata refreshes", .number(.init(min: 0)),
              "0 picks a limit from the CPU core count.", show: has(.system, "LibraryMetadataRefreshConcurrency")),
            F(.system, "ActivityLogRetentionDays", "Keep activity for (days)", .number(.init(min: 0, nullable: true, placeholder: "Forever")),
              show: has(.system, "ActivityLogRetentionDays")),
            F(.system, "LogFileRetentionDays", "Keep log files for (days)", .number(.init(min: 1)), show: has(.system, "LogFileRetentionDays")),
            F(.system, "EnableMetrics", "Prometheus metrics", .toggle, "Serve server metrics at /metrics.", show: has(.system, "EnableMetrics")),
            F(.system, "EnableSlowResponseWarning", "Log slow responses", .toggle, show: has(.system, "EnableSlowResponseWarning")),
            F(.system, "SlowResponseThresholdMs", "Slow response threshold (ms)", .number(.init(min: 0)),
              show: { $0.value(.system, "SlowResponseThresholdMs") != nil && (($0.value(.system, "EnableSlowResponseWarning") as? NSNumber)?.boolValue ?? false) }),
            F(.system, "InactiveSessionThreshold", "Stop inactive sessions after (minutes)", .number(.init(min: 0)), "0 never stops them.",
              show: has(.system, "InactiveSessionThreshold")),
            F(.system, "EnableLegacyAuthorization", "Accept old clients' authorization", .toggle,
              "Lets old apps sign requests with api_key or X-Emby-Token.", show: has(.system, "EnableLegacyAuthorization")),
        ]),
    ])

    static let branding = ConfigPage(title: "Branding", symbol: "paintpalette.fill", sections: [
        S("Splash screen", [
            F(.branding, "SplashscreenEnabled", "Enable the splash screen image", .toggle),
            F(.branding, "splash", "Splash image", .splash),
        ]),
        S("Text and style", [
            F(.branding, "LoginDisclaimer", "Login disclaimer", .multiline, "Shown at the bottom of the sign-in page."),
            F(.branding, "CustomCss", "Custom CSS code", .multiline, "Your own CSS for theming the web interface."),
        ]),
    ])

    static let display = ConfigPage(title: "Display", symbol: "rectangle.on.rectangle", sections: [
        S("Display", [
            F(.metadata, "UseFileCreationTimeForDateAdded", "Date added behavior for new content",
              .select(options: fixed(o((.bool(false), "Use date scanned into the library"), (.bool(true), "Use file creation date"))), emptyAs: nil),
              "A date from the metadata is always used first."),
            F(.system, "EnableFolderView", "Display a folder view to show plain media folders", .toggle, "Shows your folders next to your libraries."),
            F(.system, "DisplaySpecialsWithinSeasons", "Display specials within the seasons they aired in", .toggle),
            F(.system, "EnableGroupingMoviesIntoCollections", "Group movies into collections", .toggle, "Movies in a collection show as one item in movie lists."),
            F(.system, "EnableGroupingShowsIntoCollections", "Group shows into collections", .toggle, "Shows in a collection show as one item in show lists.",
              show: has(.system, "EnableGroupingShowsIntoCollections")),
            F(.system, "EnableExternalContentInSuggestions", "Enable external content in suggestions", .toggle,
              "Lets internet trailers and live TV programs appear in suggestions."),
        ]),
    ])

    static let metadata = ConfigPage(title: "Metadata", symbol: "text.below.photo.fill", context: [.cultures, .countries], sections: [
        S("Preferred metadata language", footer: "Defaults for new libraries; each library can have its own.", [
            F(.system, "PreferredMetadataLanguage", "Language", .select(options: fromContext(.cultures, leading: [ConfigOption(.null, "Default")]), emptyAs: nil)),
            F(.system, "MetadataCountryCode", "Country/Region", .select(options: fromContext(.countries, leading: [ConfigOption(.null, "Default")]), emptyAs: nil)),
        ]),
        S("Chapter images", [
            F(.system, "DummyChapterDuration", "Interval (seconds)", .number(.init(min: 0)),
              "Time between generated chapters for videos without any. 0 turns this off. Doesn't change existing chapters."),
            F(.system, "ChapterImageResolution", "Resolution", .select(options: fixed(resolutions), emptyAs: nil),
              "The size of extracted chapter images. Doesn't change existing ones."),
        ]),
    ])

    static let nfo = ConfigPage(title: "NFO settings", symbol: "doc.text.fill",
                                intro: "Changes apply to content added from now on. To turn NFO files on or off, edit a library and find Metadata savers.",
                                context: [.users], sections: [
        S("NFO", [
            F(.xbmcmetadata, "UserId", "Save user watch data to NFO files for",
              .select(options: fromContext(.users, leading: [ConfigOption(.null, "None")]), emptyAs: nil),
              "Saves watch data into NFO files for other apps (like Kodi) to use."),
            F(.xbmcmetadata, "SaveImagePathsInNfo", "Save image paths within NFO files", .toggle,
              "Recommended if your image file names don't follow Kodi's naming."),
            F(.xbmcmetadata, "EnablePathSubstitution", "Enable path substitution", .toggle, "Rewrites image paths with the server's path substitutions."),
            F(.xbmcmetadata, "EnableExtraThumbsDuplication", "Copy extrafanart to extrathumbs", .toggle, "Saves images to both, for the most Kodi skins."),
        ]),
    ])

    static let transcoding = ConfigPage(title: "Transcoding", symbol: "cpu.fill", sections: [
        S("Hardware acceleration", [
            F(.encoding, "warn", "Enabling hardware acceleration may cause instability in some environments. Make sure the server's operating system and video drivers are fully up to date. If video doesn't play after enabling this, change it back to None.", .note(warn: true)),
            F(.encoding, "HardwareAccelerationType", "Hardware acceleration", .select(options: fixed(HW.types), emptyAs: .string("none")),
              "Hardware acceleration requires additional configuration on the server (see jellyfin.org/docs → Hardware Acceleration)."),
            F(.encoding, "VaapiDevice", "VA-API device", .text, "The render node used for hardware acceleration, e.g. /dev/dri/renderD128.", show: HW.only("vaapi")),
            F(.encoding, "QsvDevice", "QSV device", .text,
              "The device for Intel QSV on a multi-GPU system. On Linux, the render node (e.g. /dev/dri/renderD128); on Windows, the device index starting from 0. Leave blank unless you know what you're doing.",
              show: HW.only("qsv")),
        ]),
        S("Enable hardware decoding for", show: HW.on, [
            F(.encoding, "HardwareDecodingCodecs", "Hardware decoding", .switches(HW.decodeSwitches)),
            F(.encoding, "EnableEnhancedNvdecDecoder", "Enable enhanced NVDEC decoder", .toggle, "Turn this off to use CUVID if you get decoding errors.", show: HW.only("nvenc")),
            F(.encoding, "PreferSystemNativeHwDecoder", "Prefer OS native DXVA or VA-API hardware decoders", .toggle, show: HW.only("qsv")),
        ]),
        S("Hardware encoding options", show: HW.on, [
            F(.encoding, "EnableHardwareEncoding", "Enable hardware encoding", .toggle),
            F(.encoding, "EnableIntelLowPowerH264HwEncoder", "Enable Intel Low-Power H.264 hardware encoder", .toggle, show: HW.only("qsv", "vaapi")),
            F(.encoding, "EnableIntelLowPowerHevcHwEncoder", "Enable Intel Low-Power HEVC hardware encoder", .toggle,
              "Low-power encoding avoids unnecessary CPU-GPU sync. On Linux, turn these off if the i915 HuC firmware isn't configured.", show: HW.only("qsv", "vaapi")),
        ]),
        S("Encoding format options", footer: "The video formats Jellyfin may transcode to. It uses software encoding when hardware acceleration for a format isn't available. H.264 is always allowed.", [
            F(.encoding, "AllowHevcEncoding", "Allow encoding in HEVC format", .toggle),
            F(.encoding, "AllowAv1Encoding", "Allow encoding in AV1 format", .toggle, show: has(.encoding, "AllowAv1Encoding")),
        ]),
        S("VPP tone mapping", show: HW.only("qsv", "vaapi"), [
            F(.encoding, "EnableVppTonemapping", "Enable VPP tone mapping", .toggle,
              "Intel driver tone mapping. Works only on certain hardware with HDR10 video; takes priority over the OpenCL tone mapping."),
            F(.encoding, "VppTonemappingBrightness", "VPP tone mapping brightness gain", .number(.init(min: 0, max: 100, integer: false)), "Recommended: 16."),
            F(.encoding, "VppTonemappingContrast", "VPP tone mapping contrast gain", .number(.init(min: 1, max: 2, integer: false)), "Recommended: 1."),
        ]),
        S("VideoToolbox tone mapping", show: HW.only("videotoolbox"), [
            F(.encoding, "EnableVideoToolboxTonemapping", "Enable VideoToolbox tone mapping", .toggle,
              "Works with HDR10, HDR10+ and HLG, not Dolby Vision profile 5. Takes priority over the Metal tone mapping."),
        ]),
        S("Tone mapping", show: { HW.current($0) == "none" || HW.accel($0) }, [
            F(.encoding, "EnableTonemapping", "Enable tone mapping", .toggle,
              "Converts HDR video to SDR while keeping detail and color. Works with 10-bit HDR10, HLG and Dolby Vision, and needs the matching GPU compute runtime.",
              show: HW.accel),
            F(.encoding, "TonemappingAlgorithm", "Tone mapping algorithm", .select(options: fixed(s([("none", "None"), ("clip", "Clip"), ("linear", "Linear"),
                ("gamma", "Gamma"), ("reinhard", "Reinhard"), ("hable", "Hable"), ("mobius", "Mobius"), ("bt2390", "BT.2390")])), emptyAs: nil),
              "If you're not sure, keep the default. Recommended: BT.2390."),
            F(.encoding, "TonemappingMode", "Tone mapping mode", .select(options: fixed(s([("auto", "Auto"), ("max", "MAX"), ("rgb", "RGB"), ("lum", "LUM"), ("itp", "ITP")])), emptyAs: nil),
              "If highlights look blown out, try RGB.", show: HW.accel),
            F(.encoding, "TonemappingRange", "Tone mapping range", .select(options: fixed(s([("auto", "Auto"), ("tv", "TV"), ("pc", "PC")])), emptyAs: nil),
              "The output color range. Auto is the same as the input."),
            F(.encoding, "TonemappingDesat", "Tone mapping desat", .number(.init(min: 0, integer: false)), "Desaturates highlights brighter than this. Recommended: 0 (off)."),
            F(.encoding, "TonemappingPeak", "Tone mapping peak", .number(.init(min: 0, integer: false)), "Overrides the video's own peak value. Default: 100 (1000 nits)."),
            F(.encoding, "TonemappingParam", "Tone mapping param", .number(.init(min: 0, nullable: true, integer: false)), "Tunes the algorithm. Usually leave it blank."),
        ]),
        S("Transcoding", [
            F(.encoding, "EncodingThreadCount", "Transcoding thread count",
              .select(options: fixed([ConfigOption(.int(-1), "Auto")] + (1...16).map { ConfigOption(.int($0), "\($0)") } + [ConfigOption(.int(0), "Max")]), emptyAs: nil),
              "The most threads a transcode may use. Fewer threads lower CPU use but may not keep up with playback."),
            F(.encoding, "EncoderAppPathDisplay", "FFmpeg path", .readOnly, "Set on the server (in its config or with --ffmpeg)."),
            F(.encoding, "TranscodingTempPath", "Transcode path", .path(files: false), "Where transcoded files for clients go. Leave blank for the server default."),
            F(.encoding, "FallbackFontPath", "Fallback font folder", .path(files: false), "Fonts some clients use to render subtitles."),
            F(.encoding, "EnableFallbackFont", "Enable fallback fonts", .toggle, "Custom fonts that can fix wrongly rendered subtitles."),
            F(.encoding, "EnableAudioVbr", "Enable VBR audio encoding", .toggle,
              "Better quality for the bitrate, but in rare cases can cause buffering or compatibility problems.", show: has(.encoding, "EnableAudioVbr")),
            F(.encoding, "DownMixAudioBoost", "Audio boost when downmixing", .number(.init(min: 0.5, max: 3, integer: false)), "1 keeps the original volume."),
            F(.encoding, "DownMixStereoAlgorithm", "Stereo downmix algorithm", .select(options: fixed(s([("None", "None"), ("Dave750", "Dave750"),
                ("NightmodeDialogue", "NightmodeDialogue"), ("Rfc7845", "RFC7845"), ("Ac4", "AC-4")])), emptyAs: nil),
              "How multi-channel audio is mixed down to stereo.", show: has(.encoding, "DownMixStereoAlgorithm")),
            F(.encoding, "HlsAudioSeekStrategy", "Audio seek strategy", .select(options: fixed(s([("TrimCopiedAudio", "TrimCopiedAudio"), ("TranscodeAudio", "TranscodeAudio")])), emptyAs: nil),
              "How audio is handled when seeking in HLS streams.", show: has(.encoding, "HlsAudioSeekStrategy")),
            F(.encoding, "MaxMuxingQueueSize", "Max muxing queue size", .number(.init(min: 0)),
              "Packets buffered while waiting for all streams to start. Raise it if FFmpeg logs \"Too many packets buffered for output stream\". Recommended: 2048."),
            F(.encoding, "EncoderPreset", "Encoding preset", .select(options: fixed(s([("auto", "Auto"), ("veryslow", "veryslow"), ("slower", "slower"), ("slow", "slow"),
                ("medium", "medium"), ("fast", "fast"), ("faster", "faster"), ("veryfast", "veryfast"), ("superfast", "superfast"), ("ultrafast", "ultrafast")])), emptyAs: .string("auto")),
              "Faster improves performance, slower improves quality."),
            F(.encoding, "H265Crf", "H.265 encoding CRF", .number(.init(min: 0, max: 51))),
            F(.encoding, "H264Crf", "H.264 encoding CRF", .number(.init(min: 0, max: 51)),
              "Quality for the x264/x265 software encoders, 0–51: lower is better quality and bigger files. 18–28 is sensible; x264's default is 23, x265's 28. Hardware encoders don't use this."),
            F(.encoding, "DeinterlaceMethod", "Deinterlacing method", .select(options: fixed(s([("yadif", "Yet Another DeInterlacing Filter (YADIF)"),
                ("bwdif", "Bob Weaver DeInterlacing Filter (BWDIF)")])), emptyAs: nil),
              "For software transcoding of interlaced video. With hardware deinterlacing available, that's used instead."),
            F(.encoding, "DeinterlaceDoubleRate", "Double the frame rate when deinterlacing", .toggle, "\"Bob\" deinterlacing: full motion like interlaced video on a TV."),
            F(.encoding, "EnableSubtitleExtraction", "Allow subtitle extraction on the fly", .toggle,
              "Embedded subtitles are extracted and sent as text to avoid transcoding video. Can stall playback while extracting on some systems; turn off to burn them in instead."),
            F(.encoding, "EnableThrottling", "Throttle transcodes", .toggle,
              "Pause a transcode once it's far enough ahead of playback, to use fewer resources. Turn off if you get playback problems."),
            F(.encoding, "EnableSegmentDeletion", "Delete segments", .toggle,
              "Delete old segments once the client has them, so the whole transcode isn't stored on disk. Turn off if you get playback problems."),
            F(.encoding, "ThrottleDelaySeconds", "Throttle after (seconds)", .number(.init(min: 10, max: 3600)),
              "Must be long enough for the client to keep a healthy buffer. Only with throttling on."),
            F(.encoding, "SegmentKeepSeconds", "Time to keep segments (seconds)", .number(.init(min: 10, max: 3600)),
              "How long segments are kept after the client downloads them. Only with segment deletion on."),
        ]),
    ])

    static let resume = ConfigPage(title: "Resume", symbol: "playpause.fill", sections: [
        S("Resume", [
            F(.system, "MinResumePct", "Minimum resume percentage", .number(.init(min: 0, max: 100)), "Titles stopped before this count as unplayed."),
            F(.system, "MaxResumePct", "Maximum resume percentage", .number(.init(min: 1, max: 100)), "Titles stopped after this count as fully played."),
            F(.system, "MinAudiobookResume", "Minimum audiobook resume (minutes)", .number(.init(min: 0, max: 100)), "Audiobooks stopped before this count as unplayed."),
            F(.system, "MaxAudiobookResume", "Audiobook remaining minutes to resume", .number(.init(min: 1, max: 100)),
              "Audiobooks stopped with less than this left count as fully played."),
            F(.system, "MinResumeDurationSeconds", "Minimum resume duration (seconds)", .number(.init(min: 0)), "The shortest video that saves where you stopped."),
        ]),
    ])

    static let streaming = ConfigPage(title: "Streaming", symbol: "dot.radiowaves.left.and.right", sections: [
        S("Streaming", [
            F(.system, "RemoteClientBitrateLimit", "Internet streaming bitrate limit (Mbps)",
              .number(.init(min: 0, max: 2147.25, scale: 1_000_000, integer: false, placeholder: "No limit")),
              "An optional per-stream limit for devices outside your network, so they don't ask for more than your upload can handle. May make the server transcode more. Blank or 0 = no limit."),
        ]),
    ])

    static let trickplay = ConfigPage(title: "Trickplay", symbol: "photo.stack.fill", sections: [
        S("Trickplay", [
            F(.system, "TrickplayOptions.EnableHwAcceleration", "Enable hardware decoding", .toggle),
            F(.system, "TrickplayOptions.EnableHwEncoding", "Enable hardware accelerated MJPEG encoding", .toggle,
              "Only with QSV, VA-API, VideoToolbox and RKMPP.", show: has(.system, "TrickplayOptions.EnableHwEncoding")),
            F(.system, "TrickplayOptions.EnableKeyFrameOnlyExtraction", "Only generate images from key frames", .toggle,
              "Much faster, with less exact timing. Falls back to software decoding if the hardware decoder can't do this.",
              show: has(.system, "TrickplayOptions.EnableKeyFrameOnlyExtraction")),
            F(.system, "TrickplayOptions.ScanBehavior", "Scan behavior", .select(options: fixed(s([("NonBlocking", "Non blocking: queue generation, then return"),
                ("Blocking", "Blocking: wait for generation before finishing the scan")])), emptyAs: nil),
              "Non-blocking adds media before its trickplay images are done. Blocking waits for them, which makes scans much longer."),
            F(.system, "TrickplayOptions.ProcessPriority", "Process priority", .select(options: fixed(s([("High", "High"), ("AboveNormal", "Above normal"),
                ("Normal", "Normal"), ("BelowNormal", "Below normal"), ("Idle", "Idle")])), emptyAs: nil),
              "Lower it if the server slows down while generating images."),
            F(.system, "TrickplayOptions.Interval", "Image interval (ms)", .number(.init(min: 1)), "Time between trickplay images."),
            F(.system, "TrickplayOptions.WidthResolutions", "Width resolutions (px)", .tags(numeric: true, placeholder: "e.g. 320"),
              "Widths to generate images at. A width of 320 on a 16:9 video gives about 320×180."),
            F(.system, "TrickplayOptions.TileWidth", "Tile width", .number(.init(min: 1)), "Most images per tile across."),
            F(.system, "TrickplayOptions.TileHeight", "Tile height", .number(.init(min: 1)), "Most images per tile down."),
            F(.system, "TrickplayOptions.JpegQuality", "JPEG quality", .number(.init(min: 1, max: 100))),
            F(.system, "TrickplayOptions.Qscale", "Qscale", .number(.init(min: 2, max: 31)), "FFmpeg's image quality scale: 2 is best, 31 worst."),
            F(.system, "TrickplayOptions.ProcessThreads", "FFmpeg threads", .number(.init(min: 0)), "Passed to FFmpeg's -threads. 0 = automatic."),
        ]),
    ])

    static let networking = ConfigPage(title: "Networking", symbol: "network",
                                       intro: "Wrong network settings can make the server unreachable. Most changes need a server restart.", sections: [
        S("Server address settings", [
            F(.network, "InternalHttpPort", "Local HTTP port number", .number(.init(min: 1, max: 65535))),
            F(.network, "EnableHttps", "Enable HTTPS", .toggle, "Listen on the HTTPS port. Needs a valid certificate too."),
            F(.network, "InternalHttpsPort", "Local HTTPS port number", .number(.init(min: 1, max: 65535))),
            F(.network, "BaseUrl", "Base URL", .text, "A subfolder for the server's address, e.g. https://example.com/<base url>.", show: has(.network, "BaseUrl")),
            F(.network, "LocalNetworkAddresses", "Bind to local network address", .tags(numeric: false, placeholder: "e.g. 192.168.1.10"),
              "Addresses the server listens on. Empty = all of them."),
            F(.network, "LocalNetworkSubnets", "LAN networks", .tags(numeric: false, placeholder: "e.g. 192.168.1.0/24"),
              "IP addresses or IP/mask ranges that count as your local network. Empty = the usual private ranges (RFC 1918)."),
            F(.network, "KnownProxies", "Known proxies", .tags(numeric: false, placeholder: "e.g. 127.0.0.1"),
              "Reverse proxies in front of the server (IPs or hostnames), so X-Forwarded-For is trusted."),
        ]),
        S("HTTPS settings", [
            F(.network, "RequireHttps", "Require HTTPS", .toggle, "Redirect every HTTP request to HTTPS. Only works while HTTPS is on."),
            F(.network, "CertificatePath", "Custom SSL certificate path", .path(files: true), "A PKCS #12 (.pfx) file with the certificate and private key."),
            F(.network, "CertificatePassword", "Certificate password", .secure),
        ]),
        S("Remote access settings", [
            F(.network, "EnableRemoteAccess", "Allow remote connections to this server", .toggle, "Off blocks every connection from outside your network."),
            F(.network, "RemoteIPFilter", "Remote IP address filter", .tags(numeric: false, placeholder: "e.g. 203.0.113.0/24"),
              "IP addresses or IP/mask ranges. Empty = every remote address may connect."),
            F(.network, "IsRemoteIPFilterBlacklist", "Remote IP address filter mode",
              .select(options: fixed(o((.bool(false), "Whitelist (only these may connect)"), (.bool(true), "Blacklist (these are blocked)"))), emptyAs: nil)),
            F(.network, "PublicHttpPort", "Public HTTP port number", .number(.init(min: 1, max: 65535)), "The public port mapped to the local HTTP port."),
            F(.network, "PublicHttpsPort", "Public HTTPS port number", .number(.init(min: 1, max: 65535)), "The public port mapped to the local HTTPS port."),
        ]),
        S("IP protocols", [
            F(.network, "EnableIPv4", "Enable IPv4", .toggle),
            F(.network, "EnableIPv6", "Enable IPv6", .toggle),
        ]),
        S("Network discovery", [
            F(.network, "AutoDiscovery", "Enable auto discovery", .toggle, "Lets apps find the server on UDP port 7359."),
        ]),
        S("Firewall and proxy settings", [
            F(.network, "PublishedServerUriBySubnet", "Published server URI", .publishedURIs),
        ]),
    ])

    static let dvr = ConfigPage(title: "DVR", symbol: "record.circle", sections: [
        S("Default recording settings", [
            F(.livetv, "GuideDays", "Number of days of guide data to download",
              .select(options: fixed([ConfigOption(.null, "Auto")] + (1...14).map { ConfigOption(.int($0), "\($0)") }), emptyAs: nil),
              "More days let you plan further ahead, but downloads take longer. Auto picks by the number of channels."),
            F(.livetv, "RecordingPath", "Default recording path", .path(files: false), "Where recordings go. Leave blank to use the server's data folder."),
            F(.livetv, "MovieRecordingPath", "Movie recording path (optional)", .path(files: false)),
            F(.livetv, "SeriesRecordingPath", "Series recording path (optional)", .path(files: false)),
            F(.livetv, "PrePaddingSeconds", "Start when possible (minutes before)", .number(.init(min: 0, scale: 60))),
            F(.livetv, "PostPaddingSeconds", "Stop when possible (minutes after)", .number(.init(min: 0, scale: 60))),
        ]),
        S("Recording post-processing", [
            F(.livetv, "RecordingPostProcessor", "Post-processing application", .path(files: true)),
            F(.livetv, "RecordingPostProcessorArguments", "Post-processor command line arguments", .text, "Use {path} for the recording's path."),
        ]),
        S("Recording metadata", [
            F(.livetv, "SaveRecordingNFO", "Save recording EPG metadata in NFO files", .toggle, "Saves the guide data next to the recording."),
            F(.livetv, "SaveRecordingImages", "Save recording EPG images", .toggle, "Saves the guide images next to the recording."),
        ]),
    ])

    /// Loads the server lists a page's dropdowns need.
    static func loadContext(_ kinds: [ConfigContext], into editor: ConfigEditor, client: JellyfinClient?) async {
        guard let client else { return }
        func list(_ path: String) async -> [[String: Any]] {
            guard let d = try? await client.send("GET", path) else { return [] }
            return (try? JSONSerialization.jsonObject(with: d) as? [[String: Any]]) ?? []
        }
        func str(_ d: [String: Any], _ k: String) -> String? {
            d.first { $0.key.caseInsensitiveCompare(k) == .orderedSame }?.value as? String
        }
        for kind in kinds {
            switch kind {
            case .languages:
                editor.ctx[kind.rawValue] = await list("/Localization/Options").compactMap { l in
                    str(l, "Value").map { ConfigOption(.string($0), str(l, "Name") ?? $0) }
                }
            case .cultures:
                editor.ctx[kind.rawValue] = await list("/Localization/Cultures").compactMap { c in
                    str(c, "TwoLetterISOLanguageName").flatMap { $0.isEmpty ? nil : ConfigOption(.string($0), str(c, "DisplayName") ?? $0) }
                }
            case .countries:
                editor.ctx[kind.rawValue] = await list("/Localization/Countries").compactMap { c in
                    str(c, "TwoLetterISORegionName").flatMap { $0.isEmpty ? nil : ConfigOption(.string($0), str(c, "DisplayName") ?? $0) }
                }
            case .users:
                editor.ctx[kind.rawValue] = await list("/Users").compactMap { u in
                    str(u, "Id").map { ConfigOption(.string($0), str(u, "Name") ?? $0) }
                }
            }
        }
    }
}

// MARK: - Views

struct ConfigPageView: View {
    @Environment(AppModel.self) private var model
    let page: ConfigPage
    /// Server values to show instead of loading them (UI tests).
    var preview: [ConfigStore: [String: Any]]? = nil
    @State private var editor = ConfigEditor()

    var body: some View {
        Form {
            if let intro = page.intro {
                Section { Label(intro, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.orange) }
            }
            if let error = editor.error {
                Section { Text(error).foregroundStyle(.red).font(.footnote) }
            }
            if !editor.values.isEmpty {
                ForEach(page.sections.filter { $0.show?(editor) ?? true }) { section in
                    let fields = section.fields.filter { ($0.show?(editor) ?? true) && fieldExists($0) }
                    if !fields.isEmpty {
                        Section {
                            ForEach(fields) { ConfigFieldRow(field: $0, editor: editor) }
                        } header: { Text(section.title) } footer: {
                            if let footer = section.footer { Text(footer) }
                        }
                    }
                }
            }
            if let note = editor.savedNote {
                Section { Label(note, systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            }
        }
        .navigationTitle(page.title)
        .keyboardDoneBar()
        .toolbar {
            if !editor.dirty.isEmpty {
                ToolbarItem(placement: .cancellationAction) { Button("Discard") { editor.discard() } }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Keyboard.dismiss()
                    Task { await editor.save(client: model.client) }
                }
                .disabled(editor.dirty.isEmpty || editor.saving)
            }
        }
        .overlay { if editor.loading && editor.values.isEmpty { ProgressView() } }
        .task {
            if let preview {
                editor.preload(preview)
                return
            }
            await editor.load(page.stores, client: model.client)
            await ServerSettingsCatalog.loadContext(page.context, into: editor, client: model.client)
        }
        .refreshable { await editor.load(page.stores, client: model.client) }
    }

    /// Version-dependent fields carry their own `show: has(...)` check; everything else always shows,
    /// because Jellyfin leaves null values (e.g. GuideDays = Auto) out of its JSON.
    private func fieldExists(_ f: ConfigField) -> Bool { true }
}

struct ConfigFieldRow: View {
    let field: ConfigField
    let editor: ConfigEditor
    @State private var browsing = false

    var body: some View {
        switch field.kind {
        case .switches(let source):
            // jellyfin-web's checkbox list: one switch per row.
            ForEach(Array(source(editor).filter { $0.show?(editor) ?? true }.enumerated()), id: \.offset) { _, sw in
                Toggle(sw.label, isOn: editor.switchBinding(field.store, listKey: field.key, sw))
            }
        case .toggle:
            Toggle(isOn: editor.bool(field.store, field.key)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(field.label)
                    if let footer = field.footer { Text(footer).font(.caption).foregroundStyle(.secondary) }
                }
            }
        case .publishedURIs:
            PublishedURIsEditor(editor: editor, store: field.store, key: field.key)
        default:
            VStack(alignment: .leading, spacing: 4) {
                control
                if let footer = field.footer, !isNote {
                    Text(footer).font(.caption).foregroundStyle(.secondary)
                }
            }
            .sheet(isPresented: $browsing) {
                ServerPathPicker(files: isFilePath) { picked in
                    editor.set(field.store, field.key, picked)
                }
            }
        }
    }

    private var isNote: Bool { if case .note = field.kind { return true }; return false }
    private var isFilePath: Bool { if case .path(let files) = field.kind { return files }; return false }

    @ViewBuilder
    private var control: some View {
        switch field.kind {
        case .toggle:
            Toggle(field.label, isOn: editor.bool(field.store, field.key))
        case .int:
            numberRow(editor.int(field.store, field.key), placeholder: "")
        case .double:
            numberRow(editor.double(field.store, field.key), placeholder: "")
        case .mbps:
            numberRow(editor.mbps(field.store, field.key), placeholder: "No limit")
        case .number(let spec):
            numberRow(editor.number(field.store, field.key, spec), placeholder: spec.placeholder ?? (spec.nullable ? "Auto" : ""))
        case .text:
            VStack(alignment: .leading, spacing: 4) {
                Text(field.label).font(.subheadline)
                TextField(field.label, text: editor.text(field.store, field.key))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .submitLabel(.done)
                    .foregroundStyle(.secondary)
            }
        case .readOnly:
            LabeledContent(field.label, value: (editor.value(field.store, field.key) as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "—")
        case .secure:
            VStack(alignment: .leading, spacing: 4) {
                Text(field.label).font(.subheadline)
                SecureField(field.label, text: editor.text(field.store, field.key)).submitLabel(.done)
            }
        case .multiline:
            VStack(alignment: .leading, spacing: 4) {
                Text(field.label).font(.subheadline)
                TextField(field.label, text: editor.text(field.store, field.key), axis: .vertical)
                    .lineLimit(3...10).font(.callout.monospaced())
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
        case .list:
            VStack(alignment: .leading, spacing: 4) {
                Text(field.label).font(.subheadline)
                TextField("One per line", text: editor.list(field.store, field.key), axis: .vertical)
                    .lineLimit(2...10).font(.callout.monospaced())
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
        case .choice(let options):
            Picker(field.label, selection: editor.choice(field.store, field.key)) {
                let current = editor.choice(field.store, field.key).wrappedValue
                if !current.isEmpty && !options.contains(where: { $0.value == current }) {
                    Text(current).tag(current)
                }
                ForEach(options.indices, id: \.self) { i in Text(options[i].label).tag(options[i].value) }
            }
        case .select(let source, let emptyAs):
            let options = source(editor)
            let selection = editor.option(field.store, field.key, emptyAs: emptyAs)
            Picker(field.label, selection: selection) {
                if !options.contains(where: { $0.value == selection.wrappedValue }) {
                    Text(selection.wrappedValue == .null ? "Not set" : "\(selection.wrappedValue.raw)").tag(selection.wrappedValue)
                }
                ForEach(options.indices, id: \.self) { i in Text(options[i].label).tag(options[i].value) }
            }
            .pickerStyle(.menu)
        case .switches:
            EmptyView()
        case .tags(let numeric, let placeholder):
            TagsEditor(label: field.label, placeholder: placeholder, numeric: numeric,
                       values: editor.tags(field.store, field.key, numeric: numeric))
        case .path:
            VStack(alignment: .leading, spacing: 4) {
                Text(field.label).font(.subheadline)
                HStack {
                    TextField("Server default", text: editor.text(field.store, field.key))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(.callout.monospaced()).submitLabel(.done)
                    Button { browsing = true } label: { Image(systemName: "folder") }
                        .buttonStyle(.glass).foregroundStyle(.primary)
                        .accessibilityLabel("Browse the server")
                }
            }
        case .note(let warn):
            Label(field.label, systemImage: warn ? "exclamationmark.triangle.fill" : "info.circle")
                .font(.footnote)
                .foregroundStyle(warn ? Color.orange : Color.secondary)
        case .publishedURIs:
            PublishedURIsEditor(editor: editor, store: field.store, key: field.key)
        case .splash:
            SplashImageEditor()
        }
    }

    private func numberRow(_ binding: Binding<String>, placeholder: String) -> some View {
        LabeledContent(field.label) {
            TextField(placeholder, text: binding)
                .keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing).frame(maxWidth: 120)
                .submitLabel(.done)
        }
    }
}

extension ConfigEditor {
    func option(_ store: ConfigStore, _ key: String, emptyAs: ConfigValue?) -> Binding<ConfigValue> {
        Binding(get: {
            let v = ConfigValue(self.value(store, key))
            if v == .null, let emptyAs { return emptyAs }
            return v
        }, set: { self.set(store, key, $0.raw) })
    }

    func number(_ store: ConfigStore, _ key: String, _ spec: ConfigField.NumberSpec) -> Binding<String> {
        Binding(get: {
            guard let n = self.value(store, key) as? NSNumber else { return "" }
            let shown = n.doubleValue / spec.scale
            if spec.scale == 1_000_000 && shown == 0 { return "" }
            return spec.integer && shown == shown.rounded() ? String(Int(shown)) : String(format: "%g", shown)
        }, set: { text in
            let t = text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
            if t.isEmpty {
                self.set(store, key, spec.nullable ? NSNull() : 0)
                return
            }
            guard var v = Double(t) else { return }
            if let lo = spec.min { v = Swift.max(lo, v) }
            if let hi = spec.max { v = Swift.min(hi, v) }
            let stored = v * spec.scale
            if spec.integer || spec.scale != 1 { self.set(store, key, Int(stored.rounded())) } else { self.set(store, key, stored) }
        })
    }

    func switchBinding(_ store: ConfigStore, listKey: String, _ sw: ConfigSwitch) -> Binding<Bool> {
        if let flag = sw.flag { return bool(store, flag) }
        let value = sw.listValue ?? ""
        return Binding(get: {
            ((self.value(store, listKey) as? [Any]) ?? []).contains { ($0 as? String) == value }
        }, set: { on in
            var list = ((self.value(store, listKey) as? [Any]) ?? []).compactMap { $0 as? String }
            list.removeAll { $0 == value }
            if on { list.append(value) }
            self.set(store, listKey, list)
        })
    }

    func tags(_ store: ConfigStore, _ key: String, numeric: Bool) -> Binding<[String]> {
        Binding(get: {
            ((self.value(store, key) as? [Any]) ?? []).map { "\($0)" }
        }, set: { items in
            if numeric { self.set(store, key, items.compactMap { Int($0) }) } else { self.set(store, key, items) }
        })
    }
}

/// A list of values (IP ranges, proxies, widths) as removable chips plus an add field.
struct TagsEditor: View {
    let label: String
    let placeholder: String
    let numeric: Bool
    @Binding var values: [String]
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.subheadline)
            if !values.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(values, id: \.self) { v in
                        Button { values.removeAll { $0 == v } } label: {
                            HStack(spacing: 4) {
                                Text(v).font(.caption.monospaced())
                                Image(systemName: "xmark").font(.caption2.weight(.bold))
                            }
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .glassEffect(.regular, in: .capsule)
                        }
                        // Borderless: in a list row only the tapped chip reacts, not the whole row.
                        .buttonStyle(.borderless)
                        .foregroundStyle(.primary)
                        .accessibilityLabel("Remove \(v)")
                    }
                }
            }
            HStack {
                TextField(placeholder, text: $draft)
                    .keyboardType(numeric ? .numberPad : .URL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit(add)
                Button("Add", action: add).buttonStyle(.borderless).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func add() {
        let v = draft.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty, !values.contains(v), !numeric || Int(v) != nil else { return }
        values.append(v)
        draft = ""
    }
}

/// jellyfin-web's "published server URI": one for everyone, or separate internal and external ones.
struct PublishedURIsEditor: View {
    let editor: ConfigEditor
    let store: ConfigStore
    let key: String
    @State private var same = true
    @State private var didInit = false

    private var value: [String] { ((editor.value(store, key) as? [Any]) ?? []).compactMap { $0 as? String } }
    private var uris: [String: String] {
        if value.count == 1, !value[0].contains("=") { return ["all": value[0]] }
        var out: [String: String] = [:]
        for p in value { if let i = p.firstIndex(of: "=") { out[String(p[..<i])] = String(p[p.index(after: i)...]) } }
        return out
    }
    /// Per-subnet entries (set in the config file) are kept as they are.
    private var others: [String] { value.filter { p in p.contains("=") && !["all=", "internal=", "external="].contains { p.hasPrefix($0) } } }

    var body: some View {
        Group {
            Toggle("Use the same published server URI for internal and external access", isOn: Binding(get: { same }, set: { s in
                let u = uris
                same = s
                if s { emit(["all": u["all"] ?? u["external"] ?? u["internal"]].compactMapValues { $0 }) }
                else { emit(["internal": u["all"], "external": u["all"]].compactMapValues { $0 }) }
            }))
            if same {
                uriField("Published server URI", "https://jellyfin.example.com", "all", "Overrides the address Jellyfin gives to apps.")
            } else {
                uriField("Internal URI", "http://192.168.1.10:8096", "internal", "The address given to apps on your network.")
                uriField("External URI", "https://jellyfin.example.com", "external", "The address given to apps outside your network.")
            }
        }
        .onAppear {
            guard !didInit else { return }
            didInit = true
            let u = uris
            same = u["all"] != nil || (u["internal"] == nil && u["external"] == nil)
        }
    }

    private func uriField(_ title: String, _ placeholder: String, _ part: String, _ help: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline)
            TextField(placeholder, text: Binding(get: { uris[part] ?? "" }, set: { v in
                var u = uris
                u[part] = v
                emit(u)
            }))
            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.done)
            Text(help).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func emit(_ u: [String: String]) {
        var list: [String] = []
        for part in ["all", "internal", "external"] {
            if let v = u[part], !v.isEmpty { list.append("\(part)=\(v)") }
        }
        editor.set(store, key, list + others)
    }
}

/// Upload or delete the custom splash screen (16:9, at least 1920×1080), like jellyfin-web.
struct SplashImageEditor: View {
    @Environment(AppModel.self) private var model
    @State private var item: PhotosPickerItem?
    @State private var stamp = Date().timeIntervalSince1970
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RemoteImage(url: model.client.flatMap { URL(string: "\($0.baseURL.absoluteString)/Branding/Splashscreen?t=\(Int(stamp))") })
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text("Custom images should be 16:9 and at least 1920×1080.").font(.caption).foregroundStyle(.secondary)
            HStack {
                PhotosPicker(selection: $item, matching: .images) {
                    Label("Upload custom image", systemImage: "photo")
                }
                .buttonStyle(.glass).foregroundStyle(.primary)
                .disabled(busy)
                Button(role: .destructive) {
                    Task { await delete() }
                } label: { Label("Delete custom image", systemImage: "trash").foregroundStyle(.red) }
                .buttonStyle(.glass)
                .disabled(busy)
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
        .onChange(of: item) { _, new in
            guard let new else { return }
            item = nil
            Task { await upload(new) }
        }
    }

    private func upload(_ item: PhotosPickerItem) async {
        busy = true
        defer { busy = false }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.9) else {
            message = "Couldn't read that image."
            return
        }
        do {
            _ = try await model.client?.send("POST", "/Branding/Splashscreen", body: jpeg.base64EncodedData(), contentType: "image/jpeg")
            stamp = Date().timeIntervalSince1970
            message = "Splash screen uploaded."
        } catch { message = error.localizedDescription }
    }

    private func delete() async {
        busy = true
        defer { busy = false }
        do {
            _ = try await model.client?.send("DELETE", "/Branding/Splashscreen")
            stamp = Date().timeIntervalSince1970
            message = "Custom image deleted."
        } catch { message = error.localizedDescription }
    }
}

/// Browse folders (and files) on the server, like jellyfin-web's folder picker.
struct ServerPathPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let files: Bool
    let onPick: (String) -> Void
    @State private var path: String?
    @State private var entries: [(name: String, path: String, isFile: Bool)] = []
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if let error { Text(error).foregroundStyle(.red).font(.footnote) }
                if let path, let parent = parentPath(path) {
                    Button { Task { await browse(parent) } } label: { Label("Up", systemImage: "arrow.up") }
                }
                ForEach(entries.indices, id: \.self) { i in
                    let e = entries[i]
                    Button {
                        if e.isFile { onPick(e.path); dismiss() } else { Task { await browse(e.path) } }
                    } label: {
                        Label(e.name, systemImage: e.isFile ? "doc" : "folder.fill")
                    }
                    .foregroundStyle(.primary)
                }
            }
            .navigationTitle(path ?? "Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                if !files, let path {
                    ToolbarItem(placement: .confirmationAction) { Button("Choose") { onPick(path); dismiss() } }
                }
            }
            .task { await browse(nil) }
        }
    }

    private func parentPath(_ p: String) -> String? {
        let trimmed = p.hasSuffix("/") && p.count > 1 ? String(p.dropLast()) : p
        guard let i = trimmed.lastIndex(where: { $0 == "/" || $0 == "\\" }) else { return "" }
        let parent = String(trimmed[..<i])
        return parent.isEmpty ? "/" : parent
    }

    private func browse(_ target: String?) async {
        guard let client = model.client else { return }
        error = nil
        func decode(_ d: Data?) -> [[String: Any]] { d.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? [] }
        func str(_ d: [String: Any], _ k: String) -> String? { d.first { $0.key.caseInsensitiveCompare(k) == .orderedSame }?.value as? String }
        do {
            let list: [[String: Any]]
            if let target, !target.isEmpty {
                list = decode(try await client.send("GET", "/Environment/DirectoryContents",
                                                     query: ["path": target, "includeFiles": files, "includeDirectories": true]))
            } else {
                list = decode(try await client.send("GET", "/Environment/Drives"))
            }
            path = (target?.isEmpty ?? true) ? nil : target
            entries = list.compactMap { e -> (name: String, path: String, isFile: Bool)? in
                guard let p = str(e, "Path") else { return nil }
                return (str(e, "Name") ?? p, p, (str(e, "Type") ?? "") == "File")
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Every key of every configuration object, typed by its value (so nothing on the server is
/// out of reach, whatever its version).
struct AllServerSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var editor = ConfigEditor()
    @State private var search = ""

    var body: some View {
        Form {
            if let error = editor.error { Section { Text(error).foregroundStyle(.red).font(.footnote) } }
            ForEach(ConfigStore.allCases) { store in
                let fields = Self.fields(for: store, in: editor.values[store] ?? [:])
                    .filter { search.isEmpty || $0.label.localizedCaseInsensitiveContains(search) || $0.key.localizedCaseInsensitiveContains(search) }
                if !fields.isEmpty {
                    Section(store.title) {
                        ForEach(fields) { ConfigFieldRow(field: $0, editor: editor) }
                    }
                }
            }
            if let note = editor.savedNote {
                Section { Label(note, systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            }
        }
        .searchable(text: $search, prompt: "Search settings")
        .navigationTitle("All settings")
        .keyboardDoneBar()
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Keyboard.dismiss()
                    Task { await editor.save(client: model.client) }
                }
                .disabled(editor.dirty.isEmpty || editor.saving)
            }
        }
        .overlay { if editor.loading && editor.values.isEmpty { ProgressView() } }
        .task { await editor.load(ConfigStore.allCases, client: model.client) }
    }

    /// Simple values become editable fields; nested objects one level deep too.
    static func fields(for store: ConfigStore, in object: [String: Any]) -> [ConfigField] {
        var out: [ConfigField] = []
        for key in object.keys.sorted() {
            let value = object[key]!
            if let nested = value as? [String: Any] {
                for sub in nested.keys.sorted() {
                    if let kind = kind(for: nested[sub]!) {
                        out.append(ConfigField(store, "\(key).\(sub)", "\(humanize(key)) › \(humanize(sub))", kind))
                    }
                }
            } else if let kind = kind(for: value) {
                out.append(ConfigField(store, key, humanize(key), kind))
            }
        }
        return out
    }

    private static func kind(for value: Any) -> ConfigField.Kind? {
        if let n = value as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .toggle }
            return CFNumberIsFloatType(n as CFNumber) ? .double : .int
        }
        if value is String { return .text }
        if let array = value as? [Any], array.allSatisfy({ $0 is String || $0 is NSNumber }) { return .list }
        return nil   // lists of objects (repositories, tuners…) have their own screens
    }

    static func humanize(_ key: String) -> String {
        var out = ""
        let chars = Array(key)
        for (i, c) in chars.enumerated() {
            if i > 0, c.isUppercase, !(chars[i - 1].isUppercase && (i + 1 >= chars.count || chars[i + 1].isUppercase)) {
                out.append(" ")
            }
            out.append(c)
        }
        return out
    }
}
