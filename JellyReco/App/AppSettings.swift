import Foundation
import Observation
import SwiftUI

// MARK: - Option enums

/// How mpv draws the picture. Both play every file directly.
enum PlayerEngine: String, CaseIterable, Identifiable, Codable {
    /// Apple's native video layer: Picture in Picture, AirPlay, Dolby Vision, lowest battery use.
    /// Falls back to the Metal renderer automatically for anything the native layer can't show.
    case automatic
    /// mpv's own Metal renderer (libplacebo): best scaling and HDR tone mapping, no PiP.
    case mpv
    var id: String { rawValue }
    var label: String {
        switch self {
        case .automatic: return "Native (recommended)"
        case .mpv: return "High-quality renderer"
        }
    }
    var footnote: String {
        switch self {
        case .automatic: return "mpv decodes every file directly; Apple's video layer shows it, with Picture in Picture, AirPlay and Dolby Vision. Files it can't show switch to the high-quality renderer by themselves."
        case .mpv: return "mpv's libplacebo renderer for everything: sharper scaling and HDR tone mapping, but no Picture in Picture."
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
    var stereoDownmix: Bool { didSet { save(stereoDownmix, "stereoDownmix") } }

    /// Direct play always comes first; only if the iPhone can't play a file is the server asked to convert it.
    var transcodeFallback: Bool { didSet { save(transcodeFallback, "transcodeFallback") } }

    // For You
    var useOnDeviceAI: Bool { didSet { save(useOnDeviceAI, "useOnDeviceAI") } }
    /// Library id for For You, `RecoSource.all`, or "" = the default (the library named Anime).
    var recoSource: String { didSet { save(recoSource, "recoSource") } }
    var dismissedPicks: Set<String> { didSet { save(Array(dismissedPicks), "dismissedPicks") } }
    var includeWatchingAsLiked: Bool { didSet { save(includeWatchingAsLiked, "includeWatchingAsLiked") } }
    /// TMDB API key or read access token (For You looks for new titles there). Synced with your
    /// account's private JellyReco storage on your server, like every other setting.
    var tmdbKey: String { didSet { save(tmdbKey, "tmdbKey") } }

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
        nextUpMaxDays = i("nextUpMaxDays", 365)
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
        stereoDownmix = b("stereoDownmix", false)

        transcodeFallback = b("transcodeFallback", true)
        useOnDeviceAI = b("useOnDeviceAI", true)
        recoSource = s("recoSource", "")
        dismissedPicks = set("dismissedPicks")
        includeWatchingAsLiked = b("includeWatchingAsLiked", true)
        tmdbKey = s("tmdbKey", "")

        requireFaceID = b("requireFaceID", false)
    }

    private func save(_ value: Any, _ key: String) {
        d.set(value, forKey: key)
        if !isApplyingRemote && Self.syncedKeys.contains(key) { onChange?() }
    }

    // MARK: Sync with the server

    /// Called after a synced setting changes (AppModel saves them to the server, debounced).
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var isApplyingRemote = false

    /// Everything that's a preference (not a cache or a per-device thing like Face ID).
    static let syncedKeys: Set<String> = [
        "appearance", "showPosterLabels", "showRatingBadges", "showProgressIndicator", "showUnplayedIndicator",
        "showPlayedIndicator", "showFavoriteIndicator", "homeShowContinue", "homeShowNextUp", "homeMergeNextUp",
        "homeShowLatest", "homeShowPicks", "nextUpRewatching", "nextUpMaxDays", "hiddenLatestLibraries",
        "libraryLayout", "libraryPosterStyle", "gridColumns", "rememberLayoutPerLibrary", "showLetterPicker",
        "showRandomButton", "layoutOverrides", "showMissingEpisodes", "landscapeEpisodeThumbs", "hideSpoilers",
        "playerEngine", "hardwareDecoding", "resumeOffset", "jumpBackward", "jumpForward", "defaultSpeed",
        "autoPlayNext", "nextUpCountdown", "stillWatchingAfter", "autoSkipIntro", "autoSkipRecap", "autoSkipOutro",
        "showSkipButtons", "timestampStyle", "showChaptersOnSlider", "trickplayPreviews", "startInLandscape",
        "pipAutomatically", "backgroundAudio", "gestureLeftVertical", "gestureRightVertical", "gestureHorizontal",
        "doubleTap", "longPress", "pinchToFill", "preferredAudioLanguage", "preferredSubtitleLanguage",
        "subtitlesByDefault", "preferSignsAndSongs", "subtitleSize", "subtitleColor", "subtitleBackground",
        "subtitleBold", "subtitlePosition", "overrideASSStyles", "stereoDownmix", "transcodeFallback",
        "useOnDeviceAI", "recoSource", "includeWatchingAsLiked", "tmdbKey",
    ]

    /// Current synced settings as JSON.
    func exportJSON() -> String? {
        var out: [String: Any] = [:]
        for key in Self.syncedKeys { if let v = d.object(forKey: key) { out[key] = v } }
        guard let data = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Applies settings saved on the server (from another device or a reinstall).
    func importJSON(_ json: String) {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        isApplyingRemote = true
        defer { isApplyingRemote = false }
        for (key, value) in dict where Self.syncedKeys.contains(key) { d.set(value, forKey: key) }
        reloadFromDefaults()
    }

    /// Re-reads every property from UserDefaults (after importing).
    private func reloadFromDefaults() {
        let fresh = AppSettings()
        appearance = fresh.appearance; showPosterLabels = fresh.showPosterLabels; showRatingBadges = fresh.showRatingBadges
        showProgressIndicator = fresh.showProgressIndicator; showUnplayedIndicator = fresh.showUnplayedIndicator
        showPlayedIndicator = fresh.showPlayedIndicator; showFavoriteIndicator = fresh.showFavoriteIndicator
        homeShowContinue = fresh.homeShowContinue; homeShowNextUp = fresh.homeShowNextUp; homeMergeNextUp = fresh.homeMergeNextUp
        homeShowLatest = fresh.homeShowLatest; homeShowPicks = fresh.homeShowPicks; nextUpRewatching = fresh.nextUpRewatching
        nextUpMaxDays = fresh.nextUpMaxDays; hiddenLatestLibraries = fresh.hiddenLatestLibraries
        libraryLayout = fresh.libraryLayout; libraryPosterStyle = fresh.libraryPosterStyle; gridColumns = fresh.gridColumns
        rememberLayoutPerLibrary = fresh.rememberLayoutPerLibrary; showLetterPicker = fresh.showLetterPicker
        showRandomButton = fresh.showRandomButton; layoutOverrides = fresh.layoutOverrides
        showMissingEpisodes = fresh.showMissingEpisodes; landscapeEpisodeThumbs = fresh.landscapeEpisodeThumbs
        hideSpoilers = fresh.hideSpoilers
        playerEngine = fresh.playerEngine; hardwareDecoding = fresh.hardwareDecoding; resumeOffset = fresh.resumeOffset
        jumpBackward = fresh.jumpBackward; jumpForward = fresh.jumpForward; defaultSpeed = fresh.defaultSpeed
        autoPlayNext = fresh.autoPlayNext; nextUpCountdown = fresh.nextUpCountdown; stillWatchingAfter = fresh.stillWatchingAfter
        autoSkipIntro = fresh.autoSkipIntro; autoSkipRecap = fresh.autoSkipRecap; autoSkipOutro = fresh.autoSkipOutro
        showSkipButtons = fresh.showSkipButtons; timestampStyle = fresh.timestampStyle
        showChaptersOnSlider = fresh.showChaptersOnSlider; trickplayPreviews = fresh.trickplayPreviews
        startInLandscape = fresh.startInLandscape; pipAutomatically = fresh.pipAutomatically
        backgroundAudio = fresh.backgroundAudio
        gestureLeftVertical = fresh.gestureLeftVertical; gestureRightVertical = fresh.gestureRightVertical
        gestureHorizontal = fresh.gestureHorizontal; doubleTap = fresh.doubleTap; longPress = fresh.longPress
        pinchToFill = fresh.pinchToFill
        preferredAudioLanguage = fresh.preferredAudioLanguage; preferredSubtitleLanguage = fresh.preferredSubtitleLanguage
        subtitlesByDefault = fresh.subtitlesByDefault; preferSignsAndSongs = fresh.preferSignsAndSongs
        subtitleSize = fresh.subtitleSize; subtitleColor = fresh.subtitleColor; subtitleBackground = fresh.subtitleBackground
        subtitleBold = fresh.subtitleBold; subtitlePosition = fresh.subtitlePosition
        overrideASSStyles = fresh.overrideASSStyles; stereoDownmix = fresh.stereoDownmix
        transcodeFallback = fresh.transcodeFallback
        useOnDeviceAI = fresh.useOnDeviceAI; recoSource = fresh.recoSource; includeWatchingAsLiked = fresh.includeWatchingAsLiked
        tmdbKey = fresh.tmdbKey
    }

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
                    "overrideASSStyles", "stereoDownmix"] {
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
        stereoDownmix = fresh.stereoDownmix
    }
}
