import Foundation

// Jellyfin's JSON uses PascalCase ("ImageTags"); the coders map it to Swift's camelCase.

enum JSONCoding {
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .custom { keys in
            let last = keys.last!.stringValue
            return AnyKey(lowerFirst(last))
        }
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            if let date = parseDate(s) { return date }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Bad date \(s)")
        }
        return d
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .custom { keys in
            AnyKey(upperFirst(keys.last!.stringValue))
        }
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(isoFormatter.string(from: date))
        }
        return e
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parseDate(_ raw: String) -> Date? {
        // Jellyfin sends 7 fractional digits ("2026-10-30T18:00:00.0000000Z"); trim to 3.
        var s = raw
        if let dot = s.firstIndex(of: ".") {
            let afterDot = s.index(after: dot)
            var end = afterDot
            while end < s.endIndex, s[end].isNumber { end = s.index(after: end) }
            let digits = s[afterDot..<end]
            let trimmed = String(digits.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
            s.replaceSubrange(afterDot..<end, with: trimmed)
        }
        if !s.hasSuffix("Z") && !s.contains("+") && s.count >= 19 && s.dropFirst(10).firstIndex(of: "-") == nil {
            s += "Z"
        }
        return isoFormatter.date(from: s) ?? isoPlain.date(from: s)
    }

    private static func lowerFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        // "ID"-only keys stay as they are lowered fully ("Id" → "id").
        return first.lowercased() + s.dropFirst()
    }

    private static func upperFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }

    struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int?
        init(_ s: String) { stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { self.intValue = intValue; stringValue = "\(intValue)" }
    }
}

// MARK: - Server & auth

struct PublicSystemInfo: Codable, Hashable {
    var localAddress: String?
    var serverName: String?
    var version: String?
    var productName: String?
    var id: String?
    var startupWizardCompleted: Bool?
}

struct SystemInfo: Codable, Hashable {
    var serverName: String?
    var version: String?
    var id: String?
    var operatingSystem: String?
    var operatingSystemDisplayName: String?
    var hasPendingRestart: Bool?
    var hasUpdateAvailable: Bool?
    var canSelfRestart: Bool?
    var localAddress: String?
    var webSocketPortNumber: Int?
    var programDataPath: String?
    var logPath: String?
    var cachePath: String?
    var transcodingTempPath: String?
    var systemArchitecture: String?
}

struct UserDto: Codable, Hashable, Identifiable {
    var id: String
    var name: String?
    var serverId: String?
    var primaryImageTag: String?
    var hasPassword: Bool?
    var hasConfiguredPassword: Bool?
    var enableAutoLogin: Bool?
    var lastLoginDate: Date?
    var lastActivityDate: Date?
    var policy: UserPolicy?
    var configuration: UserConfiguration?
}

struct UserPolicy: Codable, Hashable {
    var isAdministrator: Bool?
    var isHidden: Bool?
    var isDisabled: Bool?
    var enableCollectionManagement: Bool?
    var enableSubtitleManagement: Bool?
    var enableLyricManagement: Bool?
    var enableRemoteControlOfOtherUsers: Bool?
    var enableSharedDeviceControl: Bool?
    var enableRemoteAccess: Bool?
    var enableLiveTvManagement: Bool?
    var enableLiveTvAccess: Bool?
    var enableMediaPlayback: Bool?
    var enableAudioPlaybackTranscoding: Bool?
    var enableVideoPlaybackTranscoding: Bool?
    var enablePlaybackRemuxing: Bool?
    var forceRemoteSourceTranscoding: Bool?
    var enableContentDeletion: Bool?
    var enableContentDownloading: Bool?
    var enableSyncTranscoding: Bool?
    var enableMediaConversion: Bool?
    var enableAllDevices: Bool?
    var enableAllChannels: Bool?
    var enableAllFolders: Bool?
    var enabledFolders: [String]?
    var enablePublicSharing: Bool?
    var invalidLoginAttemptCount: Int?
    var loginAttemptsBeforeLockout: Int?
    var maxActiveSessions: Int?
    var remoteClientBitrateLimit: Int?
    var maxParentalRating: Int?
    var blockedTags: [String]?
    var allowedTags: [String]?
    var blockUnratedItems: [String]?
    var authenticationProviderId: String?
    var passwordResetProviderId: String?
    var syncPlayAccess: String?
}

struct UserConfiguration: Codable, Hashable {
    var audioLanguagePreference: String?
    var playDefaultAudioTrack: Bool?
    var subtitleLanguagePreference: String?
    var displayMissingEpisodes: Bool?
    var subtitleMode: String?
    var enableNextEpisodeAutoPlay: Bool?
    var rememberAudioSelections: Bool?
    var rememberSubtitleSelections: Bool?
    var hidePlayedInLatest: Bool?
}

struct AuthenticationResult: Codable {
    var user: UserDto?
    var accessToken: String?
    var serverId: String?
}

struct QuickConnectResult: Codable {
    var authenticated: Bool?
    var secret: String?
    var code: String?
}

// MARK: - Items

struct QueryResult<T: Codable>: Codable {
    var items: [T]?
    var totalRecordCount: Int?
    var startIndex: Int?
}

enum ItemKind: String, Codable, CaseIterable {
    case movie = "Movie", series = "Series", season = "Season", episode = "Episode"
    case boxSet = "BoxSet", collectionFolder = "CollectionFolder", folder = "Folder", userView = "UserView"
    case person = "Person", musicAlbum = "MusicAlbum", musicArtist = "MusicArtist", audio = "Audio"
    case video = "Video", trailer = "Trailer", tvChannel = "TvChannel", program = "Program"
    case playlist = "Playlist", photo = "Photo", photoAlbum = "PhotoAlbum", musicVideo = "MusicVideo"
    case liveTvProgram = "LiveTvProgram", recording = "Recording", genre = "Genre", studio = "Studio"
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ItemKind(rawValue: raw) ?? .unknown
    }

    var isPlayableVideo: Bool {
        [.movie, .episode, .video, .trailer, .musicVideo, .tvChannel, .program, .recording].contains(self)
    }
}

struct UserItemData: Codable, Hashable {
    var playbackPositionTicks: Int64?
    var playCount: Int?
    var isFavorite: Bool?
    var likes: Bool?
    var played: Bool?
    var playedPercentage: Double?
    var unplayedItemCount: Int?
    var lastPlayedDate: Date?
    var rating: Double?
}

struct NameIdPair: Codable, Hashable {
    var name: String?
    var id: String?
}

struct PersonInfo: Codable, Hashable, Identifiable {
    var name: String?
    var id: String
    var role: String?
    var type: String?
    var primaryImageTag: String?
}

struct ChapterInfo: Codable, Hashable {
    var startPositionTicks: Int64
    var name: String?
    var imageTag: String?
}

struct ExternalUrl: Codable, Hashable {
    var name: String?
    var url: String?
}

struct MediaUrl: Codable, Hashable {
    var url: String?
    var name: String?
}

struct TrickplayInfo: Codable, Hashable {
    var width: Int
    var height: Int
    var tileWidth: Int
    var tileHeight: Int
    var thumbnailCount: Int
    var interval: Int
    var bandwidth: Int?
}

struct BaseItem: Codable, Hashable, Identifiable {
    var id: String
    var name: String?
    var originalTitle: String?
    var serverId: String?
    var type: ItemKind?
    var mediaType: String?
    var collectionType: String?
    var isFolder: Bool?
    var parentId: String?

    var overview: String?
    var taglines: [String]?
    var genres: [String]?
    var tags: [String]?
    var studios: [NameIdPair]?
    var genreItems: [NameIdPair]?
    var people: [PersonInfo]?
    var productionYear: Int?
    var premiereDate: Date?
    var endDate: Date?
    var dateCreated: Date?
    var officialRating: String?
    var customRating: String?
    var communityRating: Double?
    var criticRating: Double?
    var runTimeTicks: Int64?
    var status: String?
    var airDays: [String]?
    var airTime: String?
    var productionLocations: [String]?
    var externalUrls: [ExternalUrl]?
    var remoteTrailers: [MediaUrl]?
    var localTrailerCount: Int?
    var providerIds: [String: String]?

    var seriesId: String?
    var seriesName: String?
    var seasonId: String?
    var seasonName: String?
    var indexNumber: Int?
    var indexNumberEnd: Int?
    var parentIndexNumber: Int?
    var childCount: Int?
    var recursiveItemCount: Int?
    var episodeCount: Int?

    var imageTags: [String: String]?
    var backdropImageTags: [String]?
    var primaryImageAspectRatio: Double?
    var parentBackdropItemId: String?
    var parentBackdropImageTags: [String]?
    var parentThumbItemId: String?
    var parentThumbImageTag: String?
    var parentLogoItemId: String?
    var parentLogoImageTag: String?
    var seriesPrimaryImageTag: String?
    var seriesThumbImageTag: String?
    var imageBlurHashes: [String: [String: String]]?

    var userData: UserItemData?
    var mediaSources: [MediaSourceInfo]?
    var mediaStreams: [MediaStream]?
    var chapters: [ChapterInfo]?
    var trickplay: [String: [String: TrickplayInfo]]?
    var container: String?
    var path: String?
    var width: Int?
    var height: Int?
    var video3DFormat: String?
    var locationType: String?

    // Live TV
    var channelId: String?
    var channelName: String?
    var channelNumber: String?
    var startDate: Date?
    var currentProgram: CurrentProgram?

    final class CurrentProgram: Codable, Hashable {
        var id: String?
        var name: String?
        var startDate: Date?
        var endDate: Date?
        static func == (a: CurrentProgram, b: CurrentProgram) -> Bool { a.id == b.id }
        func hash(into h: inout Hasher) { h.combine(id) }
    }

    // MARK: Convenience

    var kind: ItemKind { type ?? .unknown }
    var displayName: String { name ?? "Untitled" }
    var isPlayed: Bool { userData?.played ?? false }
    var isFavorite: Bool { userData?.isFavorite ?? false }
    var resumeTicks: Int64 { userData?.playbackPositionTicks ?? 0 }
    var progress: Double? {
        guard let p = userData?.playedPercentage, p > 0, p < 100 else { return nil }
        return p / 100
    }
    var runtimeSeconds: Double? { runTimeTicks.map { Double($0) / 10_000_000 } }

    var episodeLabel: String? {
        guard kind == .episode else { return nil }
        var parts: [String] = []
        if let s = parentIndexNumber { parts.append("S\(s)") }
        if let e = indexNumber {
            if let end = indexNumberEnd, end != e { parts.append("E\(e)-\(end)") } else { parts.append("E\(e)") }
        }
        return parts.isEmpty ? nil : parts.joined()
    }

    var subtitleLine: String {
        var parts: [String] = []
        switch kind {
        case .episode:
            if let label = episodeLabel { parts.append(label) }
            if let series = seriesName { parts.append(series) }
        case .series:
            if let y = productionYear {
                if status == "Ended", let end = endDate.map({ Calendar.current.component(.year, from: $0) }), end != y {
                    parts.append("\(y)–\(end)")
                } else if status == "Continuing" {
                    parts.append("\(y)–present")
                } else {
                    parts.append("\(y)")
                }
            }
        default:
            if let y = productionYear { parts.append("\(y)") }
        }
        if let r = officialRating { parts.append(r) }
        if kind != .series, let rt = runtimeSeconds, rt > 0 { parts.append(Fmt.runtime(rt)) }
        return parts.joined(separator: " · ")
    }

    var plainOverview: String {
        (overview ?? "")
            .replacingOccurrences(of: "<br>", with: "\n")
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The best item to read cover art from (an episode can fall back to its series poster).
    var primaryTag: String? { imageTag("Primary") }

    /// JSONDecoder applies the key strategy to dictionary keys too, so "Primary" may arrive as
    /// "primary": look up both spellings.
    func imageTag(_ type: String) -> String? {
        guard let tags = imageTags else { return nil }
        return tags[type] ?? tags[type.prefix(1).lowercased() + type.dropFirst()]
    }
}

// MARK: - Media sources & streams

struct MediaSourceInfo: Codable, Hashable, Identifiable {
    var id: String
    var name: String?
    var path: String?
    var `protocol`: String?
    var container: String?
    var size: Int64?
    var bitrate: Int?
    var runTimeTicks: Int64?
    var isRemote: Bool?
    var supportsDirectPlay: Bool?
    var supportsDirectStream: Bool?
    var supportsTranscoding: Bool?
    var transcodingUrl: String?
    var transcodingSubProtocol: String?
    var transcodingContainer: String?
    var directStreamUrl: String?
    var defaultAudioStreamIndex: Int?
    var defaultSubtitleStreamIndex: Int?
    var mediaStreams: [MediaStream]?
    var videoType: String?
    var eTag: String?
    var liveStreamId: String?
    var requiresOpening: Bool?
    var isInfiniteStream: Bool?
    var transcodeReasons: [String]?
}

struct MediaStream: Codable, Hashable {
    var type: String?            // Video, Audio, Subtitle, EmbeddedImage, Data, Lyric
    var index: Int
    var codec: String?
    var codecTag: String?
    var profile: String?
    var level: Double?
    var language: String?
    var title: String?
    var displayTitle: String?
    var isDefault: Bool?
    var isForced: Bool?
    var isHearingImpaired: Bool?
    var isExternal: Bool?
    var isTextSubtitleStream: Bool?
    var supportsExternalStream: Bool?
    var deliveryMethod: String?  // Encode, Embed, External, Hls, Drop
    var deliveryUrl: String?
    var path: String?
    var channels: Int?
    var channelLayout: String?
    var sampleRate: Int?
    var bitRate: Int?
    var bitDepth: Int?
    var width: Int?
    var height: Int?
    var averageFrameRate: Double?
    var realFrameRate: Double?
    var aspectRatio: String?
    var pixelFormat: String?
    var colorSpace: String?
    var colorTransfer: String?
    var colorPrimaries: String?
    var videoRange: String?        // SDR, HDR
    var videoRangeType: String?    // SDR, HDR10, HDR10Plus, HLG, DOVI, DOVIWithHDR10 …
    var videoDoViTitle: String?
    var isInterlaced: Bool?
    var isAVC: Bool?

    var isVideo: Bool { type == "Video" }
    var isAudio: Bool { type == "Audio" }
    var isSubtitle: Bool { type == "Subtitle" }

    var label: String {
        if let d = displayTitle, !d.isEmpty { return d }
        var parts: [String] = []
        if let l = language { parts.append(Locale.current.localizedString(forLanguageCode: l) ?? l) }
        if let c = codec { parts.append(c.uppercased()) }
        if let t = title { parts.append(t) }
        return parts.isEmpty ? "Track \(index)" : parts.joined(separator: " · ")
    }

    var languageName: String? {
        language.map { Locale.current.localizedString(forLanguageCode: $0) ?? $0 }
    }
}

struct PlaybackInfoResponse: Codable {
    var mediaSources: [MediaSourceInfo]?
    var playSessionId: String?
    var errorCode: String?
}

struct MediaSegment: Codable, Hashable, Identifiable {
    var id: String
    var itemId: String?
    var type: String          // Unknown, Commercial, Preview, Recap, Outro, Intro
    var startTicks: Int64
    var endTicks: Int64
}

// MARK: - Filters

struct QueryFilters: Codable {
    var genres: [NameIdPair]?
    var tags: [String]?
}

struct QueryFiltersLegacy: Codable {
    var genres: [String]?
    var tags: [String]?
    var officialRatings: [String]?
    var years: [Int]?
}

// MARK: - Admin

struct SessionInfo: Codable, Hashable, Identifiable {
    var id: String
    var userId: String?
    var userName: String?
    var client: String?
    var deviceName: String?
    var deviceId: String?
    var applicationVersion: String?
    var remoteEndPoint: String?
    var lastActivityDate: Date?
    var lastPlaybackCheckIn: Date?
    var isActive: Bool?
    var supportsRemoteControl: Bool?
    var supportsMediaControl: Bool?
    var nowPlayingItem: BaseItem?
    var playState: PlayerStateInfo?
    var transcodingInfo: TranscodingInfo?
    var playableMediaTypes: [String]?
}

struct PlayerStateInfo: Codable, Hashable {
    var positionTicks: Int64?
    var canSeek: Bool?
    var isPaused: Bool?
    var isMuted: Bool?
    var volumeLevel: Int?
    var audioStreamIndex: Int?
    var subtitleStreamIndex: Int?
    var mediaSourceId: String?
    var playMethod: String?
    var repeatMode: String?
}

struct TranscodingInfo: Codable, Hashable {
    var audioCodec: String?
    var videoCodec: String?
    var container: String?
    var isVideoDirect: Bool?
    var isAudioDirect: Bool?
    var bitrate: Int?
    var framerate: Double?
    var completionPercentage: Double?
    var width: Int?
    var height: Int?
    var audioChannels: Int?
    var hardwareAccelerationType: String?
    var transcodeReasons: [String]?
}

struct TaskInfo: Codable, Hashable, Identifiable {
    var id: String
    var name: String?
    var state: String?           // Idle, Cancelling, Running
    var currentProgressPercentage: Double?
    var lastExecutionResult: TaskResult?
    var triggers: [TaskTrigger]?
    var description: String?
    var category: String?
    var isHidden: Bool?
    var key: String?
}

struct TaskResult: Codable, Hashable {
    var startTimeUtc: Date?
    var endTimeUtc: Date?
    var status: String?          // Completed, Failed, Cancelled, Aborted
    var name: String?
    var errorMessage: String?
}

struct TaskTrigger: Codable, Hashable {
    var type: String             // DailyTrigger, WeeklyTrigger, IntervalTrigger, StartupTrigger
    var timeOfDayTicks: Int64?
    var intervalTicks: Int64?
    var dayOfWeek: String?
    var maxRuntimeTicks: Int64?
}

struct DeviceInfoDto: Codable, Hashable, Identifiable {
    var id: String
    var name: String?
    var customName: String?
    var appName: String?
    var appVersion: String?
    var lastUserName: String?
    var lastUserId: String?
    var dateLastActivated: Date?
}

struct AuthKey: Codable, Hashable, Identifiable {
    var id: Int?
    var accessToken: String
    var appName: String?
    var dateCreated: Date?
    var dateLastActivity: Date?
    var deviceName: String?
    var userName: String?
}

struct LogFile: Codable, Hashable, Identifiable {
    var id: String { name }
    var name: String
    var size: Int64?
    var dateCreated: Date?
    var dateModified: Date?
}

struct ActivityLogEntry: Codable, Hashable, Identifiable {
    var id: Int64
    var name: String?
    var overview: String?
    var shortOverview: String?
    var type: String?
    var itemId: String?
    var date: Date?
    var userId: String?
    var severity: String?
}

struct VirtualFolderInfo: Codable, Hashable, Identifiable {
    var id: String { itemId ?? name ?? UUID().uuidString }
    var name: String?
    var locations: [String]?
    var collectionType: String?
    var itemId: String?
    var refreshProgress: Double?
    var refreshStatus: String?
}

struct PluginInfo: Codable, Hashable, Identifiable {
    var id: String
    var name: String?
    var version: String?
    var description: String?
    var status: String?
    var canUninstall: Bool?
    var hasImage: Bool?
}

struct ParentalRating: Codable, Hashable {
    var name: String?
    var value: Int?
}

enum Fmt {
    static func runtime(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60
        if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
        return "\(max(m, 1))m"
    }

    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func bitrate(_ bps: Int) -> String {
        if bps >= 1_000_000 { return String(format: "%.1f Mbps", Double(bps) / 1_000_000) }
        return "\(bps / 1000) kbps"
    }

    static func ticks(_ seconds: Double) -> Int64 { Int64(seconds * 10_000_000) }
    static func seconds(_ ticks: Int64) -> Double { Double(ticks) / 10_000_000 }

    static func rating(_ value: Double?) -> String? {
        guard let value, value > 0 else { return nil }
        return String(format: "%.1f", value)
    }
}
