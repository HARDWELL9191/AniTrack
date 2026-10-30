import Foundation
import Observation
import SwiftUI

// MARK: - Option enums

enum PlayerEngine: String, CaseIterable, Identifiable, Codable {
    /// Picks per file: Apple's player when it can play the file untouched, mpv for everything else.
    case automatic
    /// mpv (FFmpeg + libass): every container, codec and subtitle format.
    case mpv
    /// Apple's AVPlayer: Picture in Picture, AirPlay, Dolby Vision; the server converts what it can't play.
    case native
    var id: String { rawValue }
    var label: String {
        switch self {
        case .automatic: return "Automatic"
        case .mpv: return "JellyReco (mpv)"
        case .native: return "Apple (AVPlayer)"
        }
    }
    var footnote: String {
        switch self {
        case .automatic: return "Apple's player for files it plays natively (PiP, AirPlay, Dolby Vision); mpv for everything else (MKV, DTS, TrueHD, ASS/PGS subtitles…). Nothing is converted on the server."
        case .mpv: return "Plays every file directly on your iPhone, including styled ASS subtitles and PGS/VobSub."
        case .native: return "Apple's player. Files it can't play are converted by your server."
        }
    }
}

enum MaxBitrate: Int, CaseIterable, Identifiable, Codable {
    case auto = 0
    case max = 200_000_000
    case b120 = 120_000_000, b80 = 80_000_000, b60 = 60_000_000, b40 = 40_000_000
    case b20 = 20_000_000, b15 = 15_000_000, b10 = 10_000_000, b8 = 8_000_000
    case b6 = 6_000_000, b4 = 4_000_000, b3 = 3_000_000, b1_5 = 1_500_000, b720k = 720_000, b420k = 420_000
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .auto: return "Auto (measure connection)"
        case .max: return "Maximum (original)"
        default:
            let mbps = Double(rawValue) / 1_000_000
            let res: String
            switch rawValue {
            case 40_000_000...: res = "4K"
            case 10_000_000...: res = "1080p"
            case 4_000_000...: res = "720p"
            case 1_500_000...: res = "480p"
            default: res = "360p"
            }
            return mbps >= 1 ? String(format: "%g Mbps · %@", mbps, res) : "\(rawValue / 1000) kbps · \(res)"
        }
    }
}

enum CompatibilityProfile: String, CaseIterable, Identifiable, Codable {
    case auto, mostCompatible, directPlay
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Auto"
        case .mostCompatible: return "Most compatible (H.264/AAC)"
        case .directPlay: return "Direct play only"
        }
    }
}

enum GestureAction: String, CaseIterable, Identifiable, Codable {
    case none, brightness, volume, scrub, speed, audioOffset, subtitleOffset
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: return "None"
        case .brightness: return "Brightness"
        case .volume: return "Volume"
        case .scrub: return "Scrub"
        case .speed: return "Playback speed"
        case .audioOffset: return "Audio offset"
        case .subtitleOffset: return "Subtitle offset"
        }
    }
}

enum DoubleTapAction: String, CaseIterable, Identifiable, Codable {
    case jump, playPause, none
    var id: String { rawValue }
    var label: String {
        switch self {
        case .jump: return "Jump back / forward (sides)"
        case .playPause: return "Play / pause"
        case .none: return "None"
        }
    }
}

enum LongPressAction: String, CaseIterable, Identifiable, Codable {
    case speed2x, none
    var id: String { rawValue }
    var label: String { self == .speed2x ? "Hold for 2× speed" : "None" }
}

enum TimestampStyle: String, CaseIterable, Identifiable, Codable {
    case remaining, total
    var id: String { rawValue }
    var label: String { self == .remaining ? "Time remaining" : "Total duration" }
}

enum LibraryLayout: String, CaseIterable, Identifiable, Codable {
    case grid, list
    var id: String { rawValue }
}

enum PosterStyle: String, CaseIterable, Identifiable, Codable {
    case portrait, landscape
    var id: String { rawValue }
    var label: String { self == .portrait ? "Portrait" : "Landscape" }
}

enum AppearanceMode: String, CaseIterable, Identifiable, Codable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var scheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum SubtitleColor: String, CaseIterable, Identifiable, Codable {
    case white, yellow, cyan, green
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var mpvHex: String {
        switch self {
        case .white: return "#FFFFFF"
        case .yellow: return "#FFEB3B"
        case .cyan: return "#4DD0E1"
        case .green: return "#81C784"
        }
    }
    var color: Color {
        switch self {
        case .white: return .white
        case .yellow: return .yellow
        case .cyan: return .cyan
        case .green: return .green
        }
    }
}

enum SubtitleBackground: String, CaseIterable, Identifiable, Codable {
    case outline, shadow, box
    var id: String { rawValue }
    var label: String {
        switch self {
        case .outline: return "Outline"
        case .shadow: return "Drop shadow"
        case .box: return "Dark box"
        }
    }
}

/// For You's first dropdown: one of the user's libraries (by id), or every library.
enum RecoSource {
    static let all = "all"
    /// Libraries never offered for recommendations (e.g. a "placeholder" library).
    static func isExcluded(_ name: String?) -> Bool {
        let n = (name ?? "").trimmingCharacters(in: .whitespaces)
        return n.localizedCaseInsensitiveContains("placeholder")
            || n.compare("playlist", options: .caseInsensitive) == .orderedSame
            || n.compare("playlists", options: .caseInsensitive) == .orderedSame
    }
}

// MARK: - Settings

/// Every user-facing preference, persisted in UserDefaults.
@Observable
final class AppSettings {
    @ObservationIgnored private let d = UserDefaults.standard

    // Appearance
    var appearance: AppearanceMode { didSet { save(appearance.rawValue, "appearance") } }
    var showPosterLabels: Bool { didSet { save(showPosterLabels, "showPosterLabels") } }
    var showRatingBadges: Bool { didSet { save(showRatingBadges, "showRatingBadges") } }

    // Indicators
    var showProgressIndicator: Bool { didSet { save(showProgressIndicator, "showProgressIndicator") } }
    var showUnplayedIndicator: Bool { didSet { save(showUnplayedIndicator, "showUnplayedIndicator") } }
    var showPlayedIndicator: Bool { didSet { save(showPlayedIndicator, "showPlayedIndicator") } }
    var showFavoriteIndicator: Bool { didSet { save(showFavoriteIndicator, "showFavoriteIndicator") } }

    // Home
    var homeShowContinue: Bool { didSet { save(homeShowContinue, "homeShowContinue") } }
    var homeShowNextUp: Bool { didSet { save(homeShowNextUp, "homeShowNextUp") } }
    var homeMergeNextUp: Bool { didSet { save(homeMergeNextUp, "homeMergeNextUp") } }
    var homeShowLatest: Bool { didSet { save(homeShowLatest, "homeShowLatest") } }
    var homeShowPicks: Bool { didSet { save(homeShowPicks, "homeShowPicks") } }
    var nextUpRewatching: Bool { didSet { save(nextUpRewatching, "nextUpRewatching") } }
    /// 0 = no limit.
    var nextUpMaxDays: Int { didSet { save(nextUpMaxDays, "nextUpMaxDays") } }
    var hiddenLatestLibraries: Set<String> { didSet { save(Array(hiddenLatestLibraries), "hiddenLatestLibraries") } }

    // Library
    var libraryLayout: LibraryLayout { didSet { save(libraryLayout.rawValue, "libraryLayout") } }
    var libraryPosterStyle: PosterStyle { didSet { save(libraryPosterStyle.rawValue, "libraryPosterStyle") } }
    var gridColumns: Int { didSet { save(gridColumns, "gridColumns") } }
    var rememberLayoutPerLibrary: Bool { didSet { save(rememberLayoutPerLibrary, "rememberLayoutPerLibrary") } }
    var showLetterPicker: Bool { didSet { save(showLetterPicker, "showLetterPicker") } }
    var showRandomButton: Bool { didSet { save(showRandomButton, "showRandomButton") } }
    var layoutOverrides: [String: String] { didSet { save(layoutOverrides, "layoutOverrides") } }

    // Item pages
    var showMissingEpisodes: Bool { didSet { save(showMissingEpisodes, "showMissingEpisodes") } }
    var landscapeEpisodeThumbs: Bool { didSet { save(landscapeEpisodeThumbs, "landscapeEpisodeThumbs") } }
    var hideSpoilers: Bool { didSet { save(hideSpoilers, "hideSpoilers") } }

    // Player
    var playerEngine: PlayerEngine { didSet { save(playerEngine.rawValue, "playerEngine") } }
    var hardwareDecoding: Bool { didSet { save(hardwareDecoding, "hardwareDecoding") } }
    var resumeOffset: Int { didSet { save(resumeOffset, "resumeOffset") } }          // seconds back on resume
    var jumpBackward: Int { didSet { save(jumpBackward, "jumpBackward") } }
    var jumpForward: Int { didSet { save(jumpForward, "jumpForward") } }
    var defaultSpeed: Double { didSet { save(defaultSpeed, "defaultSpeed") } }
    var autoPlayNext: Bool { didSet { save(autoPlayNext, "autoPlayNext") } }
    var nextUpCountdown: Int { didSet { save(nextUpCountdown, "nextUpCountdown") } }
    var stillWatchingAfter: Int { didSet { save(stillWatchingAfter, "stillWatchingAfter") } }   // episodes, 0 = off
    var autoSkipIntro: Bool { didSet { save(autoSkipIntro, "autoSkipIntro") } }
    var autoSkipRecap: Bool { didSet { save(autoSkipRecap, "autoSkipRecap") } }
    var autoSkipOutro: Bool { didSet { save(autoSkipOutro, "autoSkipOutro") } }
    var showSkipButtons: Bool { didSet { save(showSkipButtons, "showSkipButtons") } }
    var timestampStyle: TimestampStyle { didSet { save(timestampStyle.rawValue, "timestampStyle") } }
    var showChaptersOnSlider: Bool { didSet { save(showChaptersOnSlider, "showChaptersOnSlider") } }
    var trickplayPreviews: Bool { didSet { save(trickplayPreviews, "trickplayPreviews") } }
    var startInLandscape: Bool { didSet { save(startInLandscape, "startInLandscape") } }
    var pipAutomatically: Bool { didSet { save(pipAutomatically, "pipAutomatically") } }
    var backgroundAudio: Bool { didSet { save(backgroundAudio, "backgroundAudio") } }

    // Gestures
    var gestureLeftVertical: GestureAction { didSet { save(gestureLeftVertical.rawValue, "gestureLeftVertical") } }
    var gestureRightVertical: GestureAction { didSet { save(gestureRightVertical.rawValue, "gestureRightVertical") } }
    var gestureHorizontal: GestureAction { didSet { save(gestureHorizontal.rawValue, "gestureHorizontal") } }
    var doubleTap: DoubleTapAction { didSet { save(doubleTap.rawValue, "doubleTap") } }
    var longPress: LongPressAction { didSet { save(longPress.rawValue, "longPress") } }
    var pinchToFill: Bool { didSet { save(pinchToFill, "pinchToFill") } }

    // Audio & subtitles
    var preferredAudioLanguage: String { didSet { save(preferredAudioLanguage, "preferredAudioLanguage") } }
    var preferredSubtitleLanguage: String { didSet { save(preferredSubtitleLanguage, "preferredSubtitleLanguage") } }
    var subtitlesByDefault: Bool { didSet { save(subtitlesByDefault, "subtitlesByDefault") } }
    var preferSignsAndSongs: Bool { didSet { save(preferSignsAndSongs, "preferSignsAndSongs") } }
    var subtitleSize: Double { didSet { save(subtitleSize, "subtitleSize") } }       // 0.6 ... 2.0
    var subtitleColor: SubtitleColor { didSet { save(subtitleColor.rawValue, "subtitleColor") } }
    var subtitleBackground: SubtitleBackground { didSet { save(subtitleBackground.rawValue, "subtitleBackground") } }
    var subtitleBold: Bool { didSet { save(subtitleBold, "subtitleBold") } }
    var subtitlePosition: Int { didSet { save(subtitlePosition, "subtitlePosition") } } // 0...100 (mpv sub-pos)
    var overrideASSStyles: Bool { didSet { save(overrideASSStyles, "overrideASSStyles") } }
    var audioNormalization: Bool { didSet { save(audioNormalization, "audioNormalization") } }
    var stereoDownmix: Bool { didSet { save(stereoDownmix, "stereoDownmix") } }

    // Playback quality
    var maxBitrate: MaxBitrate { didSet { save(maxBitrate.rawValue, "maxBitrate") } }
    var cellularBitrate: MaxBitrate { didSet { save(cellularBitrate.rawValue, "cellularBitrate") } }
    var compatibility: CompatibilityProfile { didSet { save(compatibility.rawValue, "compatibility") } }
    var allowTranscoding: Bool { didSet { save(allowTranscoding, "allowTranscoding") } }

    // For You
    var useOnDeviceAI: Bool { didSet { save(useOnDeviceAI, "useOnDeviceAI") } }
    /// Library id for For You, `RecoSource.all`, or "" = the default (the library named Anime).
    var recoSource: String { didSet { save(recoSource, "recoSource") } }
    var dismissedPicks: Set<String> { didSet { save(Array(dismissedPicks), "dismissedPicks") } }
    var includeWatchingAsLiked: Bool { didSet { save(includeWatchingAsLiked, "includeWatchingAsLiked") } }

    // Security
    var requireFaceID: Bool { didSet { save(requireFaceID, "requireFaceID") } }

    init() {
        let d = UserDefaults.standard
        func b(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) as? Bool ?? def }
        func i(_ k: String, _ def: Int) -> Int { d.object(forKey: k) as? Int ?? def }
        func db(_ k: String, _ def: Double) -> Double { d.object(forKey: k) as? Double ?? def }
        func s(_ k: String, _ def: String) -> String { d.string(forKey: k) ?? def }
        func e<E: RawRepresentable>(_ k: String, _ def: E) -> E where E.RawValue == String {
            d.string(forKey: k).flatMap(E.init(rawValue:)) ?? def
        }
        func ei<E: RawRepresentable>(_ k: String, _ def: E) -> E where E.RawValue == Int {
            (d.object(forKey: k) as? Int).flatMap(E.init(rawValue:)) ?? def
        }
        func set(_ k: String) -> Set<String> { Set(d.array(forKey: k) as? [String] ?? []) }

        appearance = e("appearance", AppearanceMode.system)
        showPosterLabels = b("showPosterLabels", true)
        showRatingBadges = b("showRatingBadges", true)
        showProgressIndicator = b("showProgressIndicator", true)
        showUnplayedIndicator = b("showUnplayedIndicator", true)
        showPlayedIndicator = b("showPlayedIndicator", true)
        showFavoriteIndicator = b("showFavoriteIndicator", true)

        homeShowContinue = b("homeShowContinue", true)
        homeShowNextUp = b("homeShowNextUp", true)
        homeMergeNextUp = b("homeMergeNextUp", false)
        homeShowLatest = b("homeShowLatest", true)
        homeShowPicks = b("homeShowPicks", true)
        nextUpRewatching = b("nextUpRewatching", false)
        nextUpMaxDays = i("nextUpMaxDays", 0)
        hiddenLatestLibraries = set("hiddenLatestLibraries")

        libraryLayout = e("libraryLayout", LibraryLayout.grid)
        libraryPosterStyle = e("libraryPosterStyle", PosterStyle.portrait)
        gridColumns = i("gridColumns", 3)
        rememberLayoutPerLibrary = b("rememberLayoutPerLibrary", false)
        showLetterPicker = b("showLetterPicker", true)
        showRandomButton = b("showRandomButton", true)
        layoutOverrides = d.dictionary(forKey: "layoutOverrides") as? [String: String] ?? [:]

        showMissingEpisodes = b("showMissingEpisodes", false)
        landscapeEpisodeThumbs = b("landscapeEpisodeThumbs", true)
        hideSpoilers = b("hideSpoilers", false)

        playerEngine = e("playerEngine", PlayerEngine.automatic)
        hardwareDecoding = b("hardwareDecoding", true)
        resumeOffset = i("resumeOffset", 3)
        jumpBackward = i("jumpBackward", 10)
        jumpForward = i("jumpForward", 30)
        defaultSpeed = db("defaultSpeed", 1.0)
        autoPlayNext = b("autoPlayNext", true)
        nextUpCountdown = i("nextUpCountdown", 10)
        stillWatchingAfter = i("stillWatchingAfter", 0)
        autoSkipIntro = b("autoSkipIntro", false)
        autoSkipRecap = b("autoSkipRecap", false)
        autoSkipOutro = b("autoSkipOutro", false)
        showSkipButtons = b("showSkipButtons", true)
        timestampStyle = e("timestampStyle", TimestampStyle.remaining)
        showChaptersOnSlider = b("showChaptersOnSlider", true)
        trickplayPreviews = b("trickplayPreviews", true)
        startInLandscape = b("startInLandscape", true)
        pipAutomatically = b("pipAutomatically", true)
        backgroundAudio = b("backgroundAudio", false)

        gestureLeftVertical = e("gestureLeftVertical", GestureAction.brightness)
        gestureRightVertical = e("gestureRightVertical", GestureAction.volume)
        gestureHorizontal = e("gestureHorizontal", GestureAction.scrub)
        doubleTap = e("doubleTap", DoubleTapAction.jump)
        longPress = e("longPress", LongPressAction.speed2x)
        pinchToFill = b("pinchToFill", true)

        preferredAudioLanguage = s("preferredAudioLanguage", "")
        preferredSubtitleLanguage = s("preferredSubtitleLanguage", "")
        subtitlesByDefault = b("subtitlesByDefault", true)
        preferSignsAndSongs = b("preferSignsAndSongs", false)
        subtitleSize = db("subtitleSize", 1.0)
        subtitleColor = e("subtitleColor", SubtitleColor.white)
        subtitleBackground = e("subtitleBackground", SubtitleBackground.outline)
        subtitleBold = b("subtitleBold", true)
        subtitlePosition = i("subtitlePosition", 100)
        overrideASSStyles = b("overrideASSStyles", false)
        audioNormalization = b("audioNormalization", false)
        stereoDownmix = b("stereoDownmix", false)

        maxBitrate = ei("maxBitrate", MaxBitrate.max)
        cellularBitrate = ei("cellularBitrate", MaxBitrate.b20)
        compatibility = e("compatibility", CompatibilityProfile.auto)
        allowTranscoding = b("allowTranscoding", true)

        useOnDeviceAI = b("useOnDeviceAI", true)
        recoSource = s("recoSource", "")
        dismissedPicks = set("dismissedPicks")
        includeWatchingAsLiked = b("includeWatchingAsLiked", true)

        requireFaceID = b("requireFaceID", false)
    }

    private func save(_ value: Any, _ key: String) { d.set(value, forKey: key) }

    func layout(for libraryId: String) -> LibraryLayout {
        guard rememberLayoutPerLibrary, let raw = layoutOverrides[libraryId], let l = LibraryLayout(rawValue: raw) else {
            return libraryLayout
        }
        return l
    }

    func setLayout(_ layout: LibraryLayout, for libraryId: String) {
        if rememberLayoutPerLibrary { layoutOverrides[libraryId] = layout.rawValue } else { libraryLayout = layout }
    }

    func resetPlayer() {
        for key in ["playerEngine", "hardwareDecoding", "resumeOffset", "jumpBackward", "jumpForward", "defaultSpeed",
                    "autoPlayNext", "nextUpCountdown", "stillWatchingAfter", "autoSkipIntro", "autoSkipRecap",
                    "autoSkipOutro", "showSkipButtons", "timestampStyle", "showChaptersOnSlider", "trickplayPreviews",
                    "startInLandscape", "pipAutomatically", "backgroundAudio", "gestureLeftVertical",
                    "gestureRightVertical", "gestureHorizontal", "doubleTap", "longPress", "pinchToFill",
                    "subtitleSize", "subtitleColor", "subtitleBackground", "subtitleBold", "subtitlePosition",
                    "overrideASSStyles", "audioNormalization", "stereoDownmix"] {
            d.removeObject(forKey: key)
        }
        let fresh = AppSettings()
        playerEngine = fresh.playerEngine; hardwareDecoding = fresh.hardwareDecoding
        resumeOffset = fresh.resumeOffset; jumpBackward = fresh.jumpBackward; jumpForward = fresh.jumpForward
        defaultSpeed = fresh.defaultSpeed; autoPlayNext = fresh.autoPlayNext; nextUpCountdown = fresh.nextUpCountdown
        stillWatchingAfter = fresh.stillWatchingAfter; autoSkipIntro = fresh.autoSkipIntro
        autoSkipRecap = fresh.autoSkipRecap; autoSkipOutro = fresh.autoSkipOutro; showSkipButtons = fresh.showSkipButtons
        timestampStyle = fresh.timestampStyle; showChaptersOnSlider = fresh.showChaptersOnSlider
        trickplayPreviews = fresh.trickplayPreviews; startInLandscape = fresh.startInLandscape
        pipAutomatically = fresh.pipAutomatically; backgroundAudio = fresh.backgroundAudio
        gestureLeftVertical = fresh.gestureLeftVertical; gestureRightVertical = fresh.gestureRightVertical
        gestureHorizontal = fresh.gestureHorizontal; doubleTap = fresh.doubleTap; longPress = fresh.longPress
        pinchToFill = fresh.pinchToFill; subtitleSize = fresh.subtitleSize; subtitleColor = fresh.subtitleColor
        subtitleBackground = fresh.subtitleBackground; subtitleBold = fresh.subtitleBold
        subtitlePosition = fresh.subtitlePosition; overrideASSStyles = fresh.overrideASSStyles
        audioNormalization = fresh.audioNormalization; stereoDownmix = fresh.stereoDownmix
    }
}
