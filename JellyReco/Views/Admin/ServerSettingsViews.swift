import SwiftUI

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

    func has(_ store: ConfigStore, _ key: String) -> Bool { value(store, key) != nil }

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

// MARK: - Field descriptions

struct ConfigField: Identifiable {
    enum Kind {
        case toggle, int, double, text, multiline, secure, list, mbps
        case choice([(value: String, label: String)])
    }
    let store: ConfigStore
    let key: String
    let label: String
    var footer: String?
    let kind: Kind
    var id: String { "\(store.rawValue).\(key)" }

    init(_ store: ConfigStore, _ key: String, _ label: String, _ kind: Kind, _ footer: String? = nil) {
        self.store = store
        self.key = key
        self.label = label
        self.kind = kind
        self.footer = footer
    }
}

struct ConfigSection: Identifiable {
    let title: String
    var footer: String?
    let fields: [ConfigField]
    var id: String { title + (fields.first?.id ?? "") }
    init(_ title: String, footer: String? = nil, _ fields: [ConfigField]) {
        self.title = title
        self.footer = footer
        self.fields = fields
    }
}

struct ConfigPage: Identifiable, Hashable {
    let title: String
    let symbol: String
    let sections: [ConfigSection]
    var id: String { title }
    var stores: [ConfigStore] { Array(Set(sections.flatMap { $0.fields.map(\.store) })).sorted { $0.rawValue < $1.rawValue } }
    static func == (a: ConfigPage, b: ConfigPage) -> Bool { a.title == b.title }
    func hash(into h: inout Hasher) { h.combine(title) }
}

private func opts(_ values: String...) -> [(value: String, label: String)] {
    values.map { ($0, $0.prefix(1).uppercased() + $0.dropFirst()) }
}

/// The dashboard pages of jellyfin-web, field by field (property names from Jellyfin's own
/// configuration classes).
enum ServerSettingsCatalog {
    static let pages: [ConfigPage] = [
        ConfigPage(title: "General", symbol: "gearshape.fill", sections: [
            ConfigSection("Settings", [
                ConfigField(.system, "ServerName", "Server name", .text, "Shown to clients and on the login screen."),
                ConfigField(.system, "UICulture", "Preferred display language", .text, "Language code, e.g. en-US."),
            ]),
            ConfigSection("Paths", [
                ConfigField(.system, "CachePath", "Cache path", .text),
                ConfigField(.system, "MetadataPath", "Metadata path", .text),
            ]),
            ConfigSection("Quick Connect", [
                ConfigField(.system, "QuickConnectAvailable", "Enable Quick Connect on this server", .toggle),
            ]),
            ConfigSection("Performance", [
                ConfigField(.system, "LibraryScanFanoutConcurrency", "Parallel library scan tasks limit", .int, "0 = automatic (number of CPU cores)."),
                ConfigField(.system, "LibraryMetadataRefreshConcurrency", "Parallel metadata refresh limit", .int, "0 = automatic."),
                ConfigField(.system, "ParallelImageEncodingLimit", "Parallel image encoding limit", .int, "0 = automatic."),
            ]),
            ConfigSection("Logs", [
                ConfigField(.system, "LogFileRetentionDays", "Log file retention (days)", .int),
                ConfigField(.system, "ActivityLogRetentionDays", "Activity log retention (days)", .int, "Empty = keep forever."),
                ConfigField(.system, "AllowClientLogUpload", "Allow clients to upload logs", .toggle),
            ]),
        ]),
        ConfigPage(title: "Branding", symbol: "paintpalette.fill", sections: [
            ConfigSection("Login screen", [
                ConfigField(.branding, "LoginDisclaimer", "Login disclaimer", .multiline),
                ConfigField(.branding, "SplashscreenEnabled", "Enable the splash screen", .toggle),
            ]),
            ConfigSection("Custom CSS", footer: "Applies to the Jellyfin web client.", [
                ConfigField(.branding, "CustomCss", "Custom CSS", .multiline),
            ]),
        ]),
        ConfigPage(title: "Display", symbol: "rectangle.on.rectangle", sections: [
            ConfigSection("Display", [
                ConfigField(.system, "EnableFolderView", "Display a folder view to show plain media folders", .toggle),
                ConfigField(.system, "DisplaySpecialsWithinSeasons", "Display specials within seasons they aired in", .toggle),
                ConfigField(.system, "EnableGroupingMoviesIntoCollections", "Group movies into collections", .toggle),
                ConfigField(.system, "EnableGroupingShowsIntoCollections", "Group shows into collections", .toggle),
                ConfigField(.system, "EnableExternalContentInSuggestions", "Enable external content in suggestions", .toggle),
                ConfigField(.metadata, "UseFileCreationTimeForDateAdded", "Use the file's creation date for 'date added'", .toggle,
                            "Off: date the file was scanned into the library."),
            ]),
        ]),
        ConfigPage(title: "Metadata", symbol: "text.below.photo.fill", sections: [
            ConfigSection("Preferred metadata", [
                ConfigField(.system, "PreferredMetadataLanguage", "Language", .text, "Two-letter code, e.g. en."),
                ConfigField(.system, "MetadataCountryCode", "Country", .text, "Two-letter code, e.g. US."),
            ]),
            ConfigSection("Chapters", [
                ConfigField(.system, "DummyChapterDuration", "Dummy chapter duration (seconds)", .int, "0 = off."),
                ConfigField(.system, "ChapterImageResolution", "Chapter image resolution", .choice([
                    ("MatchSource", "Match source"), ("P144", "144p"), ("P240", "240p"), ("P360", "360p"), ("P480", "480p"),
                    ("P720", "720p"), ("P1080", "1080p"), ("P1440", "1440p"), ("P2160", "2160p")])),
                ConfigField(.system, "ImageExtractionTimeoutMs", "Image extraction timeout (ms)", .int, "0 = default."),
            ]),
        ]),
        ConfigPage(title: "NFO Settings", symbol: "doc.text.fill", sections: [
            ConfigSection("NFO", footer: "User id whose watch data is saved to NFO files (empty = none).", [
                ConfigField(.xbmcmetadata, "UserId", "Save user watch data for user id", .text),
                ConfigField(.xbmcmetadata, "ReleaseDateFormat", "Release date format", .text),
                ConfigField(.xbmcmetadata, "SaveImagePathsInNfo", "Save image paths within NFO files", .toggle),
                ConfigField(.xbmcmetadata, "EnablePathSubstitution", "Enable path substitution", .toggle),
                ConfigField(.xbmcmetadata, "EnableExtraThumbsDuplication", "Copy extrafanart to extrathumbs", .toggle),
            ]),
        ]),
        ConfigPage(title: "Resume", symbol: "playpause.fill", sections: [
            ConfigSection("Video", [
                ConfigField(.system, "MinResumePct", "Minimum resume percentage", .int),
                ConfigField(.system, "MaxResumePct", "Maximum resume percentage", .int),
                ConfigField(.system, "MinResumeDurationSeconds", "Shortest video duration for resume (seconds)", .int),
            ]),
            ConfigSection("Audiobooks", [
                ConfigField(.system, "MinAudiobookResume", "Minimum resume (minutes)", .int),
                ConfigField(.system, "MaxAudiobookResume", "Remaining minutes to count as finished", .int),
            ]),
        ]),
        ConfigPage(title: "Streaming", symbol: "dot.radiowaves.left.and.right", sections: [
            ConfigSection("Streaming", footer: "Per-stream limit for devices outside your network. Empty = no limit.", [
                ConfigField(.system, "RemoteClientBitrateLimit", "Internet streaming bitrate limit (Mbps)", .mbps),
            ]),
        ]),
        ConfigPage(title: "Transcoding", symbol: "cpu.fill", sections: [
            ConfigSection("Hardware acceleration", [
                ConfigField(.encoding, "HardwareAccelerationType", "Hardware acceleration", .choice([
                    ("none", "None"), ("amf", "AMD AMF"), ("qsv", "Intel QuickSync (QSV)"), ("nvenc", "NVIDIA NVENC"),
                    ("v4l2m2m", "Video4Linux2 (V4L2)"), ("vaapi", "Video Acceleration API (VAAPI)"),
                    ("videotoolbox", "Apple VideoToolbox"), ("rkmpp", "Rockchip MPP (RKMPP)")])),
                ConfigField(.encoding, "VaapiDevice", "VA-API device", .text),
                ConfigField(.encoding, "QsvDevice", "QSV device", .text),
                ConfigField(.encoding, "HardwareDecodingCodecs", "Hardware decoding codecs (one per line)", .list),
                ConfigField(.encoding, "EnableDecodingColorDepth10Hevc", "HEVC 10-bit decoding", .toggle),
                ConfigField(.encoding, "EnableDecodingColorDepth10Vp9", "VP9 10-bit decoding", .toggle),
                ConfigField(.encoding, "EnableDecodingColorDepth10HevcRext", "HEVC RExt 8/10-bit decoding", .toggle),
                ConfigField(.encoding, "EnableDecodingColorDepth12HevcRext", "HEVC RExt 12-bit decoding", .toggle),
                ConfigField(.encoding, "EnableEnhancedNvdecDecoder", "Enhanced NVDEC decoder", .toggle),
                ConfigField(.encoding, "PreferSystemNativeHwDecoder", "Prefer OS native DXVA or VA-API decoders", .toggle),
                ConfigField(.encoding, "EnableHardwareEncoding", "Hardware encoding", .toggle),
                ConfigField(.encoding, "EnableIntelLowPowerH264HwEncoder", "Intel low-power H.264 encoder", .toggle),
                ConfigField(.encoding, "EnableIntelLowPowerHevcHwEncoder", "Intel low-power HEVC encoder", .toggle),
            ]),
            ConfigSection("Encoding formats", [
                ConfigField(.encoding, "AllowHevcEncoding", "Allow encoding in HEVC", .toggle),
                ConfigField(.encoding, "AllowAv1Encoding", "Allow encoding in AV1", .toggle),
            ]),
            ConfigSection("Tone mapping", [
                ConfigField(.encoding, "EnableTonemapping", "Enable tone mapping", .toggle),
                ConfigField(.encoding, "EnableVppTonemapping", "Enable VPP tone mapping", .toggle),
                ConfigField(.encoding, "EnableVideoToolboxTonemapping", "Enable VideoToolbox tone mapping", .toggle),
                ConfigField(.encoding, "TonemappingAlgorithm", "Algorithm", .choice(opts("none", "clip", "linear", "gamma", "reinhard", "hable", "mobius", "bt2390"))),
                ConfigField(.encoding, "TonemappingMode", "Mode", .choice(opts("auto", "max", "rgb", "lum", "itp"))),
                ConfigField(.encoding, "TonemappingRange", "Range", .choice(opts("auto", "tv", "pc"))),
                ConfigField(.encoding, "TonemappingDesat", "Desat", .double),
                ConfigField(.encoding, "TonemappingPeak", "Peak", .double),
                ConfigField(.encoding, "TonemappingParam", "Param", .double),
                ConfigField(.encoding, "VppTonemappingBrightness", "VPP brightness gain", .double),
                ConfigField(.encoding, "VppTonemappingContrast", "VPP contrast gain", .double),
            ]),
            ConfigSection("Encoding", [
                ConfigField(.encoding, "EncoderPreset", "Encoding preset", .choice(opts("auto", "placebo", "veryslow", "slower", "slow", "medium", "fast", "faster", "veryfast", "superfast", "ultrafast"))),
                ConfigField(.encoding, "H264Crf", "H.264 encoding CRF", .int),
                ConfigField(.encoding, "H265Crf", "HEVC encoding CRF", .int),
                ConfigField(.encoding, "EncodingThreadCount", "Transcoding thread count", .int, "-1 = automatic, 0 = maximum."),
                ConfigField(.encoding, "DeinterlaceMethod", "Deinterlacing method", .choice([("yadif", "YADIF"), ("bwdif", "BWDIF")])),
                ConfigField(.encoding, "DeinterlaceDoubleRate", "Double the frame rate when deinterlacing", .toggle),
                ConfigField(.encoding, "MaxMuxingQueueSize", "Max muxing queue size", .int),
            ]),
            ConfigSection("Audio", [
                ConfigField(.encoding, "EnableAudioVbr", "Enable VBR audio encoding", .toggle),
                ConfigField(.encoding, "DownMixAudioBoost", "Audio boost when downmixing", .double),
                ConfigField(.encoding, "DownMixStereoAlgorithm", "Stereo downmix algorithm", .choice([
                    ("None", "None"), ("Dave750", "Dave750"), ("NightmodeDialogue", "Night mode dialogue"), ("Rfc7845", "RFC 7845"), ("Ac4", "AC-4")])),
                ConfigField(.encoding, "HlsAudioSeekStrategy", "HLS audio seek strategy", .choice([
                    ("TrimCopiedAudio", "Trim copied audio"), ("TranscodeAudio", "Transcode audio")])),
            ]),
            ConfigSection("Paths & files", [
                ConfigField(.encoding, "EncoderAppPathDisplay", "FFmpeg path", .text),
                ConfigField(.encoding, "TranscodingTempPath", "Transcode path", .text),
                ConfigField(.encoding, "EnableFallbackFont", "Enable fallback fonts", .toggle),
                ConfigField(.encoding, "FallbackFontPath", "Fallback font folder path", .text),
            ]),
            ConfigSection("Throttling & segments", [
                ConfigField(.encoding, "EnableThrottling", "Throttle transcodes", .toggle),
                ConfigField(.encoding, "ThrottleDelaySeconds", "Throttle after (seconds)", .int),
                ConfigField(.encoding, "EnableSegmentDeletion", "Delete segments", .toggle),
                ConfigField(.encoding, "SegmentKeepSeconds", "Time to keep segments (seconds)", .int),
            ]),
            ConfigSection("Subtitles", [
                ConfigField(.encoding, "EnableSubtitleExtraction", "Allow subtitle extraction on the fly", .toggle),
                ConfigField(.encoding, "SubtitleExtractionTimeoutMinutes", "Subtitle extraction timeout (minutes)", .int),
            ]),
            ConfigSection("Keyframes", [
                ConfigField(.encoding, "AllowOnDemandMetadataBasedKeyframeExtractionForExtensions", "On-demand keyframe extraction for extensions (one per line)", .list),
            ]),
        ]),
        ConfigPage(title: "Trickplay", symbol: "photo.stack.fill", sections: [
            ConfigSection("Hardware", [
                ConfigField(.system, "TrickplayOptions.EnableHwAcceleration", "Enable hardware decoding", .toggle),
                ConfigField(.system, "TrickplayOptions.EnableHwEncoding", "Enable hardware-accelerated MJPEG encoding", .toggle),
                ConfigField(.system, "TrickplayOptions.EnableKeyFrameOnlyExtraction", "Only generate images from key frames", .toggle),
            ]),
            ConfigSection("Generation", [
                ConfigField(.system, "TrickplayOptions.ScanBehavior", "Scan behaviour", .choice([("NonBlocking", "Non-blocking"), ("Blocking", "Blocking")])),
                ConfigField(.system, "TrickplayOptions.ProcessPriority", "Process priority", .choice([
                    ("Idle", "Idle"), ("BelowNormal", "Below normal"), ("Normal", "Normal"), ("AboveNormal", "Above normal"),
                    ("High", "High"), ("RealTime", "Real time")])),
                ConfigField(.system, "TrickplayOptions.Interval", "Image interval (ms)", .int),
                ConfigField(.system, "TrickplayOptions.WidthResolutions", "Width resolutions (one per line)", .list),
                ConfigField(.system, "TrickplayOptions.TileWidth", "Tile width", .int),
                ConfigField(.system, "TrickplayOptions.TileHeight", "Tile height", .int),
                ConfigField(.system, "TrickplayOptions.Qscale", "Quality scale (qscale)", .int),
                ConfigField(.system, "TrickplayOptions.JpegQuality", "JPEG quality", .int),
                ConfigField(.system, "TrickplayOptions.ProcessThreads", "FFmpeg threads", .int),
            ]),
        ]),
        ConfigPage(title: "Networking", symbol: "network", sections: [
            ConfigSection("Server address", [
                ConfigField(.network, "LocalNetworkAddresses", "Bind to local network address (one per line)", .list),
                ConfigField(.network, "LocalNetworkSubnets", "LAN networks (one per line)", .list),
                ConfigField(.network, "KnownProxies", "Known proxies (one per line)", .list),
                ConfigField(.network, "PublishedServerUriBySubnet", "Published server URIs (one per line)", .list),
                ConfigField(.network, "EnablePublishedServerUriByRequest", "Published server URI from request", .toggle),
            ]),
            ConfigSection("Ports", footer: "Port changes need a server restart.", [
                ConfigField(.network, "InternalHttpPort", "Local HTTP port", .int),
                ConfigField(.network, "InternalHttpsPort", "Local HTTPS port", .int),
                ConfigField(.network, "PublicHttpPort", "Public HTTP port", .int),
                ConfigField(.network, "PublicHttpsPort", "Public HTTPS port", .int),
            ]),
            ConfigSection("HTTPS", [
                ConfigField(.network, "EnableHttps", "Enable HTTPS", .toggle),
                ConfigField(.network, "RequireHttps", "Require HTTPS", .toggle),
                ConfigField(.network, "CertificatePath", "Custom SSL certificate path", .text),
                ConfigField(.network, "CertificatePassword", "Certificate password", .secure),
            ]),
            ConfigSection("Remote access", [
                ConfigField(.network, "EnableRemoteAccess", "Allow remote connections to this server", .toggle),
                ConfigField(.network, "RemoteIPFilter", "Remote IP address filter (one per line)", .list),
                ConfigField(.network, "IsRemoteIPFilterBlacklist", "Filter is a blocklist (off = allowlist)", .toggle),
                ConfigField(.network, "EnableUPnP", "Enable automatic port mapping", .toggle),
            ]),
            ConfigSection("IP protocols & discovery", [
                ConfigField(.network, "EnableIPv4", "Enable IPv4", .toggle),
                ConfigField(.network, "EnableIPv6", "Enable IPv6", .toggle),
                ConfigField(.network, "AutoDiscovery", "Enable auto-discovery", .toggle),
                ConfigField(.network, "IgnoreVirtualInterfaces", "Ignore virtual interfaces", .toggle),
                ConfigField(.network, "VirtualInterfaceNames", "Virtual interface names (one per line)", .list),
            ]),
        ]),
        ConfigPage(title: "Live TV & DVR", symbol: "tv.fill", sections: [
            ConfigSection("Guide", [
                ConfigField(.livetv, "GuideDays", "Number of days of guide data", .int, "Empty = automatic."),
            ]),
            ConfigSection("Recordings", [
                ConfigField(.livetv, "RecordingPath", "Default recording path", .text),
                ConfigField(.livetv, "MovieRecordingPath", "Movie recording path", .text),
                ConfigField(.livetv, "SeriesRecordingPath", "Series recording path", .text),
                ConfigField(.livetv, "EnableRecordingSubfolders", "Create subfolders for categories", .toggle),
                ConfigField(.livetv, "EnableOriginalAudioWithEncodedRecordings", "Keep original audio in encoded recordings", .toggle),
                ConfigField(.livetv, "PrePaddingSeconds", "Start recording early (seconds)", .int),
                ConfigField(.livetv, "PostPaddingSeconds", "Keep recording after the end (seconds)", .int),
                ConfigField(.livetv, "SaveRecordingNFO", "Save recording EPG metadata in NFO files", .toggle),
                ConfigField(.livetv, "SaveRecordingImages", "Save recording EPG images", .toggle),
            ]),
            ConfigSection("Post-processing", [
                ConfigField(.livetv, "RecordingPostProcessor", "Post-processor application", .text),
                ConfigField(.livetv, "RecordingPostProcessorArguments", "Post-processor arguments", .text),
            ]),
        ]),
        ConfigPage(title: "Advanced", symbol: "slider.horizontal.3", sections: [
            ConfigSection("Library monitoring", [
                ConfigField(.system, "LibraryMonitorDelay", "Library monitor delay (seconds)", .int),
                ConfigField(.system, "LibraryUpdateDuration", "Library update delay (seconds)", .int),
            ]),
            ConfigSection("Sorting", [
                ConfigField(.system, "SortRemoveWords", "Words ignored when sorting (one per line)", .list),
                ConfigField(.system, "SortRemoveCharacters", "Characters removed when sorting (one per line)", .list),
                ConfigField(.system, "SortReplaceCharacters", "Characters replaced when sorting (one per line)", .list),
            ]),
            ConfigSection("Server", [
                ConfigField(.system, "CorsHosts", "CORS hosts (one per line)", .list),
                ConfigField(.system, "EnableSlowResponseWarning", "Warn about slow responses", .toggle),
                ConfigField(.system, "SlowResponseThresholdMs", "Slow response threshold (ms)", .int),
                ConfigField(.system, "EnableMetrics", "Enable Prometheus metrics", .toggle),
                ConfigField(.system, "InactiveSessionThreshold", "Inactive session threshold (minutes)", .int, "0 = off."),
                ConfigField(.system, "CacheSize", "Cache size", .int),
                ConfigField(.system, "SaveMetadataHidden", "Save metadata as hidden files", .toggle),
                ConfigField(.system, "EnableLegacyAuthorization", "Enable legacy authorization", .toggle),
            ]),
        ]),
    ]
}

// MARK: - Views

struct ServerSettingsHub: View {
    var body: some View {
        List {
            Section {
                ForEach(ServerSettingsCatalog.pages) { page in
                    NavigationLink { ConfigPageView(page: page) } label: { Label(page.title, systemImage: page.symbol) }
                }
            } footer: {
                Text("The same settings as the Jellyfin web dashboard, saved straight to your server.")
            }
            Section {
                NavigationLink { AllServerSettingsView() } label: { Label("All settings", systemImage: "list.bullet.rectangle") }
            } footer: {
                Text("Every value in the server's configuration, including ones not shown above.")
            }
        }
        .navigationTitle("Server settings")
    }
}

struct ConfigPageView: View {
    @Environment(AppModel.self) private var model
    let page: ConfigPage
    @State private var editor = ConfigEditor()

    var body: some View {
        Form {
            if let error = editor.error {
                Section { Text(error).foregroundStyle(.red).font(.footnote) }
            }
            ForEach(page.sections) { section in
                let fields = section.fields.filter { editor.loading || editor.has($0.store, $0.key) || editor.values[$0.store] == nil }
                if !fields.isEmpty {
                    Section {
                        ForEach(fields) { ConfigFieldRow(field: $0, editor: editor) }
                    } header: { Text(section.title) } footer: {
                        if let footer = section.footer { Text(footer) }
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
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Keyboard.dismiss()
                    Task { await editor.save(client: model.client) }
                }
                .disabled(editor.dirty.isEmpty || editor.saving)
            }
        }
        .overlay { if editor.loading && editor.values.isEmpty { ProgressView() } }
        .task { await editor.load(page.stores, client: model.client) }
        .refreshable { await editor.load(page.stores, client: model.client) }
    }
}

struct ConfigFieldRow: View {
    let field: ConfigField
    let editor: ConfigEditor

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            control
            if let footer = field.footer {
                Text(footer).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var control: some View {
        switch field.kind {
        case .toggle:
            Toggle(field.label, isOn: editor.bool(field.store, field.key))
        case .int:
            LabeledContent(field.label) {
                TextField("", text: editor.int(field.store, field.key))
                    .keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing).frame(maxWidth: 120)
            }
        case .double:
            LabeledContent(field.label) {
                TextField("", text: editor.double(field.store, field.key))
                    .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(maxWidth: 120)
            }
        case .mbps:
            LabeledContent(field.label) {
                TextField("No limit", text: editor.mbps(field.store, field.key))
                    .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(maxWidth: 120)
            }
        case .text:
            VStack(alignment: .leading, spacing: 4) {
                Text(field.label).font(.subheadline)
                TextField(field.label, text: editor.text(field.store, field.key))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .submitLabel(.done)
                    .foregroundStyle(.secondary)
            }
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
