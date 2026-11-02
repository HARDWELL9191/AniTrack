import AVFoundation
import Foundation
import MediaPlayer
import MPVUI
import Observation
import UIKit

/// One playback session: finds the file on the server, plays it directly in mpv, keeps the
/// server informed (resume points, Continue Watching, the dashboard), and handles tracks,
/// skipping, next episode and the fallback ladder:
///
///   1. Direct play, native video layer (PiP, AirPlay, Dolby Vision)
///   2. Direct play, mpv's Metal renderer (anything the native layer can't show)
///   3. Server conversion, only if allowed in Settings (last resort)
@Observable
@MainActor
final class PlaybackController {
    enum Phase: Equatable {
        case loading
        case playing
        case failed(String)
    }

    enum PlayMethod: String { case directPlay = "DirectPlay", transcode = "Transcode" }

    struct TrackOption: Identifiable, Hashable {
        let id: MPVMediaTrackIdentifier
        let title: String
        let detail: String
        let isSelected: Bool
        let isExternal: Bool
    }

    // Public state
    private(set) var player: MPVPlayer
    private(set) var item: BaseItem
    private(set) var phase: Phase = .loading
    private(set) var source: MediaSourceInfo?
    private(set) var method: PlayMethod = .directPlay
    private(set) var queue: [BaseItem]
    private(set) var segments: [MediaSegment] = []
    private(set) var activeSegment: MediaSegment?
    private(set) var upNext: BaseItem?
    /// The episode before this one in the whole series (across seasons), nil on the very first.
    private(set) var previousEpisode: BaseItem?
    private(set) var upNextCountdown: Int?
    private(set) var askStillWatching = false
    private(set) var statusNote: String?
    private(set) var audioDelay: Double = 0
    private(set) var subtitleDelay: Double = 0
    /// Fill instead of fit (the surface is scaled up to cover the screen, like Apple's player).
    /// Fit (whole picture), Fill (zoom until the screen is covered) or Stretch (picture pulled
    /// to the screen's shape: nothing cut off, nothing black).
    enum AspectMode: String, CaseIterable { case fit, fill, stretch }
    private(set) var aspectMode: AspectMode = .fit
    var isFilled: Bool { aspectMode == .fill }
    /// Recent engine messages (shown in Playback info) so problems are visible.
    private(set) var diagnostics: [String] = []
    var trickplay: TrickplayProvider?

    @ObservationIgnored private let model: AppModel
    @ObservationIgnored private let client: JellyfinClient
    @ObservationIgnored private var request: PlaybackRequest
    @ObservationIgnored private var playSessionId: String?
    @ObservationIgnored private var streams: [MediaStream] = []
    @ObservationIgnored private var externalSubs: [MediaStream] = []
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var lastReport = Date.distantPast
    @ObservationIgnored private var lastPaused = true
    @ObservationIgnored private var didApplyTracks = false
    @ObservationIgnored private var triedMetal = false
    @ObservationIgnored private var triedTranscode = false
    @ObservationIgnored private var skippedSegments: Set<String> = []
    @ObservationIgnored private var autoplayStreak = 0
    @ObservationIgnored private var playedIds: [String] = []
    @ObservationIgnored private var countdownTask: Task<Void, Never>?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var remoteCommandsInstalled = false
    @ObservationIgnored private var playingSince: Date?
    /// "Cancel" on the Up Next card: no countdown again for this episode (the credits segment and
    /// the end of the file used to restart it every half second).
    @ObservationIgnored private var countdownDismissed = false
    @ObservationIgnored private var stopped = false
    /// Where this file was opened and whether it ever actually played: until it does, reports
    /// carry the start position, so a file that failed to open doesn't reset your resume point to 0.
    @ObservationIgnored private var openedAt: Double = 0
    @ObservationIgnored private var hasPlayed = false

    var settings: AppSettings { model.settings }

    init(request: PlaybackRequest, model: AppModel, client: JellyfinClient) {
        self.request = request
        self.model = model
        self.client = client
        self.item = request.item
        self.queue = request.queue
        self.player = MPVPlayer(configuration: Self.configuration(settings: model.settings,
                                                                  output: .sampleBuffer))   // renderer is automatic (see open())
        player.setDiagnosticsEnabled(true)
        attachLog()
        appliedSubtitleProperties = ["sub-ass-override": model.settings.subtitleASSMode, "sub-ass-style-overrides": ""]
    }

    private func attachLog() {
        player.logHandler = { [weak self] msg in
            guard let self else { return }
            // Info messages only carry the ASS header the app asks mpv to print (see
            // requestASSHeader); Playback info keeps showing warnings and errors as before.
            if msg.level == .info {
                self.collectASSHeader(msg)
                return
            }
            let line = JellyfinClient.redacted("[\(msg.prefix)] \(msg.message.trimmingCharacters(in: .whitespacesAndNewlines))")
            self.noteSkippedTrack(msg.message)
            self.noteDecodeError(msg.message)
            // A message repeating every frame would push everything else out of Playback info.
            if self.diagnostics.suffix(4).contains(line) { return }
            self.diagnostics.append(line)
            if self.diagnostics.count > 40 { self.diagnostics.removeFirst(self.diagnostics.count - 40) }
        }
    }

    // MARK: Configuration

    static func configuration(settings: AppSettings, output: MPVPlayerConfiguration.VideoOutput,
                              logLevel: MPVPlayerConfiguration.LogLevel = .info) -> MPVPlayerConfiguration {
        var options: [String: String] = [
            // Subtitles: mpv/libass renders ASS with its own styles; these shape plain text ones.
            "sub-auto": "no",
            "sid": "no",
            "sub-codepage": "auto",
            "sub-ass-override": settings.subtitleASSMode,
            "sub-scale": String(format: "%.2f", settings.subtitleSize),
            "sub-color": settings.subtitleColor.mpvHex,
            "sub-bold": settings.subtitleBold ? "yes" : "no",
            "sub-pos": "\(min(settings.subtitlePosition, 100))",   // the exact place is set per subtitle once it's known
            "sub-font-size": "52",
            "demuxer-readahead-secs": "30",
            "embeddedfonts": "yes",
            "network-timeout": "30",
            "screenshot-format": "png",
        ]
        switch settings.subtitleBackground {
        case .outline:
            options["sub-border-style"] = "outline-and-shadow"
            options["sub-border-size"] = String(format: "%g", settings.subtitleOutlineSize)
            options["sub-shadow-offset"] = "1"
        case .shadow:
            options["sub-border-style"] = "outline-and-shadow"
            options["sub-border-size"] = "1"
            options["sub-shadow-offset"] = "3"
        case .box:
            options["sub-border-style"] = "background-box"
            options["sub-back-color"] = "#99000000"
        }
        // Fonts for mpv's subtitle renderer: without them text subtitles have nothing to draw with.
        if let fonts = SubtitleFonts.prepare() {
            options["sub-fonts-dir"] = fonts.directory
            options["sub-font"] = fonts.family
            options["osd-font"] = fonts.family
            // Only so mpv finds subfont.ttf (libass's last-resort font); the folder holds nothing else.
            if let config = fonts.configDirectory {
                options["config"] = "yes"
                options["config-dir"] = config
            }
        }
        if settings.stereoDownmix { options["audio-channels"] = "stereo" }
        return MPVPlayerConfiguration(
            additionalOptions: options,
            audio: MPVAudioConfiguration(audioSession: .automatic, dolbyDecoding: .automatic,
                                         spatialization: settings.stereoDownmix ? .disabled : .automatic),
            automaticallyPlays: true,
            cache: MPVCacheConfiguration(mode: .enabled, maximumBytes: 300 * 1024 * 1024, maximumBackBytes: 120 * 1024 * 1024),
            dolbyVisionPolicy: .strict,
            hardwareDecoding: settings.hardwareDecoding ? .automatic : .disabled,
            initialBufferDuration: .seconds(1),
            logLevel: logLevel,   // info: for the ASS header the app reads (only warnings are shown)
            networkCacheDuration: .seconds(30),
            playbackRate: settings.defaultSpeed,
            videoOutput: output
        )
    }

    // MARK: Start

    func start() async {
        guard !started else { return }
        started = true
        aspectMode = AspectMode(rawValue: settings.defaultAspect) ?? .fit
        installRemoteCommands()
        observeAudioRoute()
        await open(item, start: request.startSeconds, fallback: false)
        startTicker()
    }

    /// Asks the server for the file (direct play only, or conversion when falling back) and loads it.
    private func open(_ target: BaseItem, start: Double?, fallback: Bool) async {
        phase = .loading
        statusNote = fallback ? "Your server is converting this file…" : nil
        didApplyTracks = false
        playingSince = nil
        externalSubs = []
        loadGeneration &+= 1
        // A decoder fallback for the previous file doesn't carry over.
        if decoderRecoveries > 0 {
            decoderRecoveries = 0
            hwdecAlternated = false
            player.setProperty("hwdec", to: settings.hardwareDecoding ? hwdecValue : "no")
        }
        skippedEmbedded = []
        pendingSubtitleSelection = nil
        skippedSegments = []
        activeSegment = nil
        upNextCountdown = nil
        countdownDismissed = false
        hasPlayed = false
        // The previous episode's intro / credits times and lock-screen picture don't carry over.
        segments = []
        nowPlayingArtwork = nil
        previousEpisode = nil
        layoutKind = nil
        let resumeSeconds: Double = {
            if let start { return start }
            let ticks = model.userData(for: target)?.playbackPositionTicks ?? target.resumeTicks
            guard ticks > 0, !(model.userData(for: target)?.played ?? false) else { return 0 }
            return max(0, Fmt.seconds(ticks) - Double(settings.resumeOffset))
        }()
        openedAt = resumeSeconds

        do {
            // Full item (streams, chapters, trickplay) when the caller only had a list entry.
            let full = (target.mediaSources == nil || target.chapters == nil) ? ((try? await client.item(target.id)) ?? target) : target
            item = full
            let info = try await client.playbackInfo(itemId: full.id, JellyfinClient.PlaybackInfoRequest(
                userId: client.userId ?? "",
                maxStreamingBitrate: fallback ? 40_000_000 : 400_000_000,
                startTimeTicks: Fmt.ticks(resumeSeconds),
                audioStreamIndex: fallback ? request.audioIndex : nil,
                subtitleStreamIndex: fallback ? request.subtitleIndex : nil,
                maxAudioChannels: settings.stereoDownmix ? 2 : 8,
                mediaSourceId: request.mediaSourceId,
                deviceProfile: fallback ? .fallback(hevc: true) : .directPlay,
                enableDirectPlay: !fallback,
                enableDirectStream: fallback,
                enableTranscoding: fallback,
                allowVideoStreamCopy: fallback,
                allowAudioStreamCopy: fallback,
                autoOpenLiveStream: true,
                alwaysBurnInSubtitleWhenTranscoding: nil
            ))
            playSessionId = info.playSessionId
            let sources = info.mediaSources ?? []
            guard let src = sources.first(where: { $0.id == request.mediaSourceId }) ?? sources.first else {
                throw JellyfinError.message(info.errorCode.map { "The server can't play this (\($0))." } ?? "No playable file found.")
            }
            source = src
            streams = src.mediaStreams ?? full.mediaStreams ?? []

            // The native layer (far less battery than the Metal renderer) draws subtitles on their own
            // layer above the video with JellyReco's libmpv, Dolby Vision included. Without that
            // layer, native Dolby Vision frames can't be drawn on, so such a file starting with a
            // subtitle on would open on the Metal renderer straight away.
            let startSubtitle = request.subtitleIndex ?? src.defaultSubtitleStreamIndex ?? -1
            let startsWithSubtitle = streams.contains { $0.isSubtitle && $0.index == startSubtitle }
            let dolbyVision = streams.contains { $0.isVideo && ($0.videoRangeType ?? "").uppercased().contains("DOVI") }
            if !Self.nativeSubtitleLayer, !fallback, dolbyVision, startsWithSubtitle {
                if usesNativeOutput { rebuildPlayer(output: .metal) }
                metalForSubtitles = true
            } else if metalForSubtitles, !usesNativeOutput, !triedMetal {
                // The previous file only needed Metal for its subtitles: back to the native layer.
                rebuildPlayer(output: .sampleBuffer)
                metalForSubtitles = false
            }

            let url: URL?
            if fallback, let t = src.transcodingUrl {
                url = client.absolute(t)
                method = .transcode
                transcodedAudioIndex = request.audioIndex ?? src.defaultAudioStreamIndex
                    ?? streams.first(where: \.isAudio)?.index
            } else {
                url = client.directStreamURL(itemId: full.id, source: src, playSessionId: playSessionId)
                method = .directPlay
            }
            guard let url else { throw JellyfinError.message("Couldn't build the stream address.") }

            player.load(url, playAutomatically: true, startTime: resumeSeconds > 1 ? .seconds(resumeSeconds) : nil)
            applySubtitleLayout()
            player.setPlaybackRate(settings.defaultSpeed)
            loadExternalSubtitles(itemId: full.id, source: src)
            prepareTrickplay(full, source: src)
            let generation = loadGeneration
            Task { [weak self, client = self.client] in
                let found = await client.mediaSegments(itemId: full.id)
                // A late answer for an episode that's no longer playing is dropped.
                guard let self, self.loadGeneration == generation else { return }
                self.segments = found
            }

            if full.kind == .episode { findNeighbours(of: full, generation: generation) }

            await client.reportStart(report())
            lastReport = Date()
            if !playedIds.contains(full.id) { playedIds.append(full.id) }
            upNext = queue.first
            updateNowPlaying()
        } catch {
            if AppModel.isCancellation(error) { return }
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: Tracks the player library can't read (zlib-compressed in the MKV)

    /// mkvmerge stores PGS (and some other) subtitle tracks zlib-compressed; the player
    /// library's libmpv is built without zlib, so it drops those tracks entirely
    /// ("Track N was compressed with zlib… Skipping track."). Jellyfin's own ffmpeg can read
    /// them: fetch each such subtitle from the server (PGS as the original .sup stream, text
    /// as-is) and add it as a separate subtitle. Nothing is converted or burned in.
    @ObservationIgnored private var skippedEmbedded: Set<Int> = []
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var pendingSubtitleSelection: Int?

    private func noteSkippedTrack(_ message: String) {
        guard message.contains("compressed with zlib"),
              let range = message.range(of: #"Track (\d+)"#, options: .regularExpression),
              let number = Int(message[range].dropFirst(6)) else { return }
        // MKV track numbers follow the file's track order, as do Jellyfin's embedded streams.
        let tracks = streams.filter { !($0.isExternal ?? false) && ($0.isVideo || $0.isAudio || $0.isSubtitle || $0.type == "Data") }
            .sorted { $0.index < $1.index }
        guard tracks.indices.contains(number - 1) else { return }
        let stream = tracks[number - 1]
        guard stream.isSubtitle, !skippedEmbedded.contains(stream.index), let src = source else { return }
        let codec = (stream.codec ?? "").lowercased()
        let format: String
        switch codec {
        case "pgssub", "hdmv_pgs_subtitle", "pgs", "sup": format = "pgssub"
        // DVD VobSub: Jellyfin hands its copy over as a plain (uncompressed) Matroska file, which
        // the player opens as it is (checked against a real server and the app's libmpv in CI).
        case "dvdsub", "dvd_subtitle", "vobsub": format = "mks"
        case "ass", "ssa": format = "ass"
        case "subrip", "srt", "text": format = "srt"
        case "webvtt", "vtt": format = "vtt"
        default: return   // DVB: Jellyfin can't hand it over in a form the player can add
        }
        var plain = stream
        plain.deliveryUrl = nil
        guard let url = client.subtitleURL(itemId: item.id, sourceId: src.id, stream: plain, format: format) else { return }
        skippedEmbedded.insert(stream.index)
        diagnostics.append("[JellyReco] Loading subtitle \(stream.index) (\(codec)) from the server instead")
        addServerSubtitle(stream, url: url, rawPGS: format == "pgssub")
        // It's the subtitle that should be on: select it as soon as it arrives.
        if wantedSubtitleIndex == stream.index { pendingSubtitleSelection = stream.index }
    }

    /// Adds a subtitle file the server provides as a separate track. Raw PGS (.sup) can't be
    /// opened by the player as it is, so it's downloaded and wrapped in Matroska first (off the
    /// main thread); everything else is added straight from its address. `externalSubs` follows
    /// the order tracks are added to mpv, which is how they're told apart.
    private func addServerSubtitle(_ stream: MediaStream, url: URL, rawPGS: Bool) {
        guard rawPGS else {
            externalSubs.append(stream)
            player.loadExternalSubtitle(url, selecting: nil)
            return
        }
        let itemId = item.id
        let generation = loadGeneration
        let language = stream.language ?? "und"
        let index = stream.index
        Task { [weak self] in
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                let file = try await Task.detached(priority: .userInitiated) { () -> URL? in
                    guard (200..<300).contains(code), let mks = PGSContainer.matroska(fromSUP: data, language: language) else { return nil }
                    let file = Self.subtitleDirectory.appendingPathComponent("\(itemId)-\(index).mks")
                    try mks.write(to: file, options: .atomic)
                    return file
                }.value
                guard let file else {
                    self?.diagnostics.append("[JellyReco] Subtitle \(index): server answered HTTP \(code), \(data.count) bytes, not PGS")
                    return
                }
                guard let self, self.loadGeneration == generation else { return }
                self.externalSubs.append(stream)
                self.player.loadExternalSubtitle(file, selecting: nil)
                self.diagnostics.append("[JellyReco] Subtitle \(index) ready (\(data.count) bytes of PGS)")
            } catch {
                self?.diagnostics.append("[JellyReco] Subtitle \(index): \(error.localizedDescription)")
            }
        }
    }

    /// The subtitle that should be on when the file starts (-1: off).
    private var wantedSubtitleIndex: Int {
        request.subtitleIndex ?? source?.defaultSubtitleStreamIndex ?? -1
    }

    /// Converted picture subtitles for this session (emptied when the player closes).
    nonisolated static var subtitleDirectory: URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jellyreco-subs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Subtitle files beside the video (and, when the server converts, every subtitle it
    /// delivers separately): each one as its own track, in a form the player can open.
    private func loadExternalSubtitles(itemId: String, source: MediaSourceInfo) {
        let separate: [MediaStream]
        if method == .transcode {
            // A converted stream carries no subtitles: Jellyfin extracts the text ones (and sends
            // PGS as-is) at their delivery addresses; picture ones it can't send are burned in.
            separate = streams.filter { $0.isSubtitle && $0.deliveryMethod?.lowercased() == "external" && !($0.deliveryUrl ?? "").isEmpty }
        } else {
            separate = streams.filter { $0.isSubtitle && ($0.isExternal ?? false) }
        }
        for sub in separate {
            let codec = (sub.codec ?? "").lowercased()
            var plain = sub
            let format: String
            switch codec {
            case "pgssub", "hdmv_pgs_subtitle", "pgs", "sup":
                format = "pgssub"                     // the original .sup, wrapped before adding
                plain.deliveryUrl = nil
            case "dvdsub", "dvd_subtitle", "vobsub", "dvbsub", "dvb_subtitle":
                // External VobSub is an .idx + .sub pair and the server only hands out the .idx:
                // not added (a track that fails to load would shift every later one's name).
                if method != .transcode { continue }
                format = "mks"
                plain.deliveryUrl = nil
            case "ass", "ssa": format = codec
            case "subrip", "srt": format = "srt"
            case "webvtt", "vtt": format = "vtt"
            default:
                // Other text formats (SAMI, MicroDVD, TTML…): the server converts them to SRT.
                format = "srt"
                plain.deliveryUrl = nil
            }
            guard let url = client.subtitleURL(itemId: itemId, sourceId: source.id, stream: plain, format: format) else { continue }
            addServerSubtitle(sub, url: url, rawPGS: format == "pgssub")
        }
    }

    private func prepareTrickplay(_ item: BaseItem, source: MediaSourceInfo) {
        guard settings.trickplayPreviews,
              let bySource = item.trickplay?[source.id] ?? item.trickplay?.values.first,
              let best = bySource.values.min(by: { abs($0.width - 320) < abs($1.width - 320) }) else {
            trickplay = nil
            return
        }
        trickplay = TrickplayProvider(client: client, itemId: item.id, sourceId: source.id, info: best)
    }

    // MARK: Ticker (state, reporting, segments, next up, failures)

    /// The player's controls (or a panel, menu or Playback info) are on screen: set by PlayerScreen.
    /// Showing them, seeking or jumping wakes the ticker so it's back on the quick rhythm at once.
    @ObservationIgnored var controlsVisible = true {
        didSet { if controlsVisible && !oldValue { wakeTicker() } }
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            var interval: UInt64 = 500_000_000
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                guard let self, !Task.isCancelled else { return }   // the player is gone: stop
                self.tickInProgress = true
                await self.tick()
                self.tickInProgress = false
                // Battery: twice a second only while something can need it soon; otherwise
                // every 2.5 s (progress reports, sync and failure checks don't need more).
                interval = self.needsQuickTick ? 500_000_000 : 2_500_000_000
            }
        }
    }

    /// Restarts the ticker's wait (a seek may land right before an intro, for example). Never in the
    /// middle of a tick: that may be opening a file (renderer fallback), which must not be cancelled.
    @ObservationIgnored private var tickInProgress = false
    private func wakeTicker() {
        guard ticker != nil, !stopped, !tickInProgress else { return }
        startTicker()
    }

    /// Whether the next tick should come after 0.5 s rather than 2.5 s.
    private var needsQuickTick: Bool {
        if controlsVisible || phase == .loading { return true }
        switch player.state {
        case .playing: break
        case .paused, .ended, .failed: return false   // nothing moves (a failure is handled on the next tick)
        default: return true                           // loading / buffering: catch the start quickly
        }
        if !didApplyTracks || pendingSubtitleSelection != nil || restoreTracks != nil { return true }
        if activeSegment != nil || upNextCountdown != nil || askStillWatching || subtitleSwitchStarted { return true }
        // Media time that passes in one slow tick (more at higher speeds), plus a margin.
        let now = currentSeconds
        let ahead = 2.5 * max(1, player.playbackRate) + 1
        if segments.contains(where: { seg in
            let a = Fmt.seconds(seg.startTicks), b = Fmt.seconds(seg.endTicks)
            return (now >= a - ahead && now < b) })
        { return true }
        let duration = durationSeconds
        return duration > 0 && duration - now < ahead
    }

    private func tick() async {
        let state = player.state
        if case .failed(let error) = state {
            await handleFailure(error)
            return
        }
        if phase == .loading, state == .playing || state == .paused || (player.duration > .zero && state != .loading) {
            phase = .playing
            statusNote = nil
        }
        if state == .playing && playingSince == nil { playingSince = Date() }
        if state == .playing { hasPlayed = true }
        // Track lists arrive in pieces: wait until subtitles are known (or 3 s of playback)
        // before choosing, otherwise the subtitle choice is made against an empty list.
        let expectsSubs = streams.contains(where: \.isSubtitle)
        let subsReady = !expectsSubs || !player.subtitleTracks.isEmpty
        let waitedEnough = playingSince.map { Date().timeIntervalSince($0) > 3 } ?? false
        // After a renderer switch, wait for the exact subtitle track (external ones load a moment later).
        let restoreReady = restoreTracks?.subtitle.map { id in player.subtitleTracks.contains { $0.mpvID == id } } ?? true
        if !didApplyTracks, !player.audioTracks.isEmpty, (subsReady && restoreReady) || waitedEnough {
            didApplyTracks = true
            applyInitialTracks()
        }
        if let wanted = pendingSubtitleSelection, didApplyTracks,
           let t = track(forJellyfinIndex: wanted, type: .subtitle) {
            pendingSubtitleSelection = nil
            player.selectSubtitle(t.id)
        }
        checkAudioSync()
        updateSegments()
        checkSubtitleRendering()
        if didApplyTracks, currentLayoutKey != layoutKind { applySubtitleLayout() }

        if state == .ended { await handleEnded() }

        let paused = player.isPaused
        if paused != lastPaused || Date().timeIntervalSince(lastReport) >= 10 {
            lastPaused = paused
            lastReport = Date()
            if phase == .playing { reportProgressInBackground() }
            updateNowPlaying()
        }
    }

    private func handleFailure(_ error: MPVPlayerError) async {
        let at = seconds(player.position)
        // 2) Native layer can't show this file: same file, mpv's own renderer.
        if player.configuration.videoOutput == .sampleBuffer && !triedMetal {
            triedMetal = true
            statusNote = "Switching to the high-quality renderer…"
            endSession(failed: true)
            rebuildPlayer(output: .metal)
            await open(item, start: at > 1 ? at : request.startSeconds, fallback: false)
            return
        }
        // 3) The iPhone really can't play it: server conversion, only if allowed.
        if settings.transcodeFallback && !triedTranscode {
            triedTranscode = true
            endSession(failed: true)
            await open(item, start: at > 1 ? at : request.startSeconds, fallback: true)
            return
        }
        let codecs = describeFile()
        phase = .failed("\(error.message)\(codecs.isEmpty ? "" : "\n\n\(codecs)")")
    }

    private func rebuildPlayer(output: MPVPlayerConfiguration.VideoOutput) {
        player.stop()
        player = MPVPlayer(configuration: Self.configuration(settings: settings, output: output))
        appliedSubtitleProperties = ["sub-ass-override": settings.subtitleASSMode, "sub-ass-style-overrides": ""]
        hwdecAlternated = false
        layoutKind = nil
        assHeaderRequested = nil
        player.pictureInPicture.allowsAutomaticStartFromInline = settings.pipAutomatically
        player.setDiagnosticsEnabled(true)
        attachLog()
    }

    var usesNativeOutput: Bool { player.configuration.videoOutput == .sampleBuffer }

    // MARK: Audio/video sync

    /// mpv's own measurement of how far audio is from the picture (seconds).
    var audioVideoDrift: Double? { player.playbackDiagnostics.audioVideoDriftSeconds }
    @ObservationIgnored private var driftStrikes = 0
    @ObservationIgnored private var driftSince: Date?
    @ObservationIgnored private var lastAudioReload = Date.distantPast
    @ObservationIgnored private var routeObserver: NSObjectProtocol?

    /// Switching audio track and back fixed drift for you: it restarts the audio output.
    /// Do the same automatically when mpv measures drift for 2 s, and after the audio
    /// route changes (AirPods, AirPlay, speaker), whose latency differs.
    private func checkAudioSync() {
        guard player.state == .playing, let drift = audioVideoDrift, drift.isFinite else { driftStrikes = 0; driftSince = nil; return }
        guard abs(drift) > 0.12 else { driftStrikes = 0; driftSince = nil; return }
        driftStrikes += 1
        if driftSince == nil { driftSince = Date() }
        // Off for 2 s (measured by the clock, as the ticker's rhythm varies), seen at least twice.
        if driftStrikes >= 2, let since = driftSince, Date().timeIntervalSince(since) >= 1.9 {
            driftSince = nil
            reloadAudio(reason: String(format: "audio was %+.2f s off", drift))
        }
    }

    @ObservationIgnored private var interruptionObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var audioNeedsReload = false
    @ObservationIgnored private var audioInterrupted = false
    @ObservationIgnored private var resumeAfterInterruption = false

    /// Takes the audio session back and restarts mpv's audio output (no 15 s limit).
    private func restoreAudio(reason: String) {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            audioNeedsReload = false
        } catch {
            // Still busy (a call in progress): try again on the next resume.
            diagnostics.append("[JellyReco] Audio session: \(error.localizedDescription)")
        }
        lastAudioReload = Date()
        driftStrikes = 0
        player.executeCommand("ao-reload")
        diagnostics.append("[JellyReco] Restarted audio output (\(reason))")
    }

    func reloadAudio(reason: String) {
        guard Date().timeIntervalSince(lastAudioReload) > 15 else { return }
        lastAudioReload = Date()
        driftStrikes = 0
        player.executeCommand("ao-reload")
        diagnostics.append("[JellyReco] Restarted audio output (\(reason))")
    }

    private func observeAudioRoute() {
        guard routeObserver == nil else { return }
        routeObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    // During a call the session isn't ours: restarting the output then left it
                    // dead. While paused or interrupted, restart it when playback resumes instead.
                    if self.audioInterrupted || self.player.isPaused {
                        self.audioNeedsReload = true
                        return
                    }
                    self.lastAudioReload = .distantPast
                    self.reloadAudio(reason: "audio route changed")
                }
            }
        }
        let center = NotificationCenter.default
        // Calls, Siri, alarms, other apps: Apple leaves interruptions to the app (MPVUI says so too).
        interruptionObservers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let info = note.userInfo ?? [:]
            let type = (info[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            let options = AVAudioSession.InterruptionOptions(rawValue: info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            let suspended = (info[AVAudioSessionInterruptionReasonKey] as? UInt).flatMap(AVAudioSession.InterruptionReason.init(rawValue:)) == .appWasSuspended
            MainActor.assumeIsolated {
                guard let self, !self.stopped else { return }
                switch type {
                case .began:
                    self.audioInterrupted = true
                    self.audioNeedsReload = true
                    // A stale notice for while the app was suspended isn't a reason to resume later.
                    self.resumeAfterInterruption = !suspended && !self.player.isPaused
                    self.pause()
                    self.diagnostics.append("[JellyReco] Audio interrupted")
                case .ended:
                    self.audioInterrupted = false
                    let resume = self.resumeAfterInterruption && options.contains(.shouldResume)
                    self.resumeAfterInterruption = false
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        guard !self.stopped else { return }
                        if resume { self.play() }   // restarts the audio output first
                    }
                default: break
                }
            }
        })
        // Leaving the app while paused: iOS suspends it and may hand the audio hardware to other
        // apps, after which mpv's audio output stayed silent. Restart it when playback resumes.
        // iOS also ends the hardware video decoder's session in the background (outside Picture in
        // Picture): back in the app every frame then failed to decode ("hevc: No frame decoded?"),
        // the picture froze and the sound with it. Coming back, both are started fresh.
        interruptionObservers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.stopped else { return }
                if self.player.isPaused || !self.settings.backgroundAudio {
                    self.audioNeedsReload = true
                }
                if !self.player.pictureInPicture.isActive {
                    self.videoNeedsRefresh = true
                    self.diagnostics.append("[JellyReco] App went to the background")
                }
            }
        })
        interruptionObservers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.stopped else { return }
                if self.player.isPaused {
                    self.audioNeedsReload = true            // restarted with the video when play is pressed
                } else if self.videoNeedsRefresh {
                    self.refreshAfterBackground()          // still playing (background audio): now
                }
            }
        })
        // The phone's media services restarted: every audio output has to be set up again.
        interruptionObservers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.stopped else { return }
                if self.player.isPaused { self.audioNeedsReload = true } else { self.restoreAudio(reason: "media services were reset") }
            }
        })
    }

    /// Picture-based subtitles (Blu-ray PGS, DVD VobSub, DVB). The native layer draws them into the
    /// video frame like ASS; only native Dolby Vision frames can't take them (see below).
    static func isPictureSubtitle(_ codec: String?) -> Bool {
        let c = (codec ?? "").lowercased()
        return ["hdmv_pgs_subtitle", "pgssub", "pgs", "sup", "dvd_subtitle", "dvdsub", "vobsub", "dvb_subtitle",
                "dvbsub", "xsub"].contains(c)
    }

    /// Switches between the native layer (PiP, Dolby Vision) and the Metal renderer at the same
    /// spot, keeping the chosen audio and subtitle tracks.
    func switchRenderer(toMetal: Bool) async {
        guard toMetal == usesNativeOutput else { return }
        let at = currentSeconds
        // Same file, same track numbers: restore exactly the tracks that were playing (mpv ids),
        // never through Jellyfin's numbering, which could turn the subtitle off.
        restoreTracks = RestoreTracks(audio: player.audioTracks.first(where: \.isSelected)?.mpvID,
                                      subtitle: player.selectedSubtitle()?.mpvID,
                                      secondary: player.selectedSubtitle(for: .secondary)?.mpvID)
        request.audioIndex = player.audioTracks.first(where: \.isSelected).flatMap { stream(for: $0)?.index }
        request.subtitleIndex = player.selectedSubtitle().flatMap { stream(for: $0)?.index } ?? request.subtitleIndex
        triedMetal = toMetal
        endSession()
        rebuildPlayer(output: toMetal ? .metal : .sampleBuffer)
        await open(item, start: at, fallback: method == .transcode)
    }

    /// The native layer draws subtitles into the picture, except on native Dolby Vision frames (the
    /// player library reports that as `nativeSubtitles` unavailable and shows none). Only then, with
    /// a subtitle on, move to the Metal renderer at the same spot with the same tracks.
    @ObservationIgnored private var metalForSubtitles = false
    @ObservationIgnored private var subtitleSwitchStarted = false
    /// JellyReco's libmpv draws the native output's subtitles on a layer of their own above the
    /// video (at screen resolution, on every video including Dolby Vision; into the frames only
    /// during Picture in Picture), so no renderer switch is needed for them.
    static let nativeSubtitleLayer = true
    private func checkSubtitleRendering() {
        // Any subtitle: without the subtitle layer the native output draws none onto Dolby Vision frames.
        guard !Self.nativeSubtitleLayer, usesNativeOutput, !subtitleSwitchStarted, phase == .playing,
              player.videoFeatureCapabilities.nativeSubtitles.availability == .unavailable,
              player.selectedSubtitle() != nil || player.selectedSubtitle(for: .secondary) != nil else { return }
        subtitleSwitchStarted = true
        metalForSubtitles = true
        statusNote = "Switching renderer for subtitles…"
        Task {
            await switchRenderer(toMetal: true)
            subtitleSwitchStarted = false
        }
    }

    private func describeFile() -> String {
        let video = streams.first(where: \.isVideo)
        let audio = streams.first(where: \.isAudio)
        return [source?.container.map { "Container: \($0.uppercased())" },
                video?.codec.map { "Video: \($0.uppercased())\(video?.profile.map { " \($0)" } ?? "")" },
                audio?.codec.map { "Audio: \($0.uppercased())" }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: Tracks

    /// The file's own audio tracks, in mpv's order. A converted stream carries only the one the
    /// server was asked for.
    private var embeddedAudio: [MediaStream] {
        let all = streams.filter { $0.isAudio && !($0.isExternal ?? false) }.sorted { $0.index < $1.index }
        guard method == .transcode else { return all }
        return all.filter { $0.index == transcodedAudioIndex }.prefix(1).map { $0 }.ifEmpty(Array(all.prefix(1)))
    }
    // mpv still lists a track it skipped (no data), so it keeps its place in the numbering.
    // A converted stream has no subtitles inside it: every one is added separately.
    private var embeddedSubs: [MediaStream] {
        guard method != .transcode else { return [] }
        return streams.filter { $0.isSubtitle && !($0.isExternal ?? false) }.sorted { $0.index < $1.index }
    }

    /// The audio track the server put into a converted stream.
    @ObservationIgnored private var transcodedAudioIndex: Int?
    /// Audio choices while the server converts are its tracks, not mpv's: picking one asks the
    /// server for a new conversion with it (ids above this number are server track numbers).
    private static let serverAudioBase = 100_000

    /// An embedded subtitle mpv skipped (zlib): its working copy is the external track.
    private func isDeadTrack(_ t: MPVMediaTrack) -> Bool {
        t.type == .subtitle && !t.isExternal && (stream(for: t).map { skippedEmbedded.contains($0.index) } ?? false)
    }

    /// The Jellyfin stream behind an mpv track (mpv numbers each type from 1 in file order;
    /// external subtitles come after the embedded ones, in the order they were added).
    func stream(for track: MPVMediaTrack) -> MediaStream? {
        switch track.type {
        case .audio:
            let i = track.mpvID - 1
            return embeddedAudio.indices.contains(i) ? embeddedAudio[i] : nil
        case .subtitle:
            if track.isExternal {
                let i = track.mpvID - embeddedSubs.count - 1
                return externalSubs.indices.contains(i) ? externalSubs[i] : nil
            }
            let i = track.mpvID - 1
            return embeddedSubs.indices.contains(i) ? embeddedSubs[i] : nil
        default:
            return nil
        }
    }

    private func track(forJellyfinIndex index: Int, type: MPVTrackType) -> MPVMediaTrack? {
        let tracks = type == .audio ? player.audioTracks : player.subtitleTracks.filter { !isDeadTrack($0) }
        return tracks.first { stream(for: $0)?.index == index }
    }

    var audioOptions: [TrackOption] {
        guard method == .transcode else { return player.audioTracks.map(option) }
        return streams.filter { $0.isAudio && !($0.isExternal ?? false) }.sorted { $0.index < $1.index }.map { s in
            var details: [String] = []
            if let c = s.codec { details.append(c.uppercased()) }
            if let ch = s.channelLayout { details.append(ch) }
            return TrackOption(id: MPVMediaTrackIdentifier(type: .audio, mpvID: Self.serverAudioBase + s.index),
                               title: s.displayTitle ?? s.languageName ?? "Track \(s.index)",
                               detail: details.joined(separator: " · "),
                               isSelected: s.index == transcodedAudioIndex, isExternal: false)
        }
    }
    var subtitleOptions: [TrackOption] { player.subtitleTracks.filter { !isDeadTrack($0) }.map(option) }

    private func option(_ t: MPVMediaTrack) -> TrackOption {
        let s = stream(for: t)
        let lang = s?.languageName ?? t.language.map { Locale.current.localizedString(forLanguageCode: $0) ?? $0 }
        var title = s?.displayTitle ?? [lang, t.title].compactMap { $0 }.joined(separator: " · ")
        if title.isEmpty { title = "Track \(t.mpvID)" }
        var details: [String] = []
        if let c = s?.codec ?? t.codec { details.append(c.uppercased()) }
        if let ch = s?.channelLayout { details.append(ch) }
        if t.isForced { details.append("Forced") }
        if t.isExternal { details.append("External") }
        if s?.isHearingImpaired == true { details.append("SDH") }
        return TrackOption(id: t.id, title: title, detail: details.joined(separator: " · "),
                           isSelected: t.isSelected && (t.type != .subtitle || t.subtitleRole == .primary), isExternal: t.isExternal)
    }

    var secondarySubtitle: MPVMediaTrack? { player.selectedSubtitle(for: .secondary) }

    func selectAudio(_ id: MPVMediaTrackIdentifier) {
        if id.mpvID >= Self.serverAudioBase {
            let index = id.mpvID - Self.serverAudioBase
            guard method == .transcode, index != transcodedAudioIndex else { return }
            Task { await restartConversion(audioIndex: index) }
            return
        }
        player.selectTrack(id)
        reportProgressInBackground()
    }

    /// While the server converts, a different audio track means a new conversion with that track,
    /// from the same spot and with the same subtitle.
    private func restartConversion(audioIndex: Int) async {
        let at = currentSeconds
        request.audioIndex = audioIndex
        request.subtitleIndex = player.selectedSubtitle().flatMap { stream(for: $0)?.index } ?? -1
        statusNote = "Switching audio…"
        endSession()
        await open(item, start: at, fallback: true)
    }

    func selectSubtitle(_ id: MPVMediaTrackIdentifier?, secondary: Bool = false) {
        if secondary {
            player.selectSubtitle(id, for: .secondary)
        } else if let id {
            pendingSubtitleSelection = nil          // your choice wins over one still arriving
            player.selectSubtitle(id, for: .primary)
        } else {
            pendingSubtitleSelection = nil
            player.disableTrack(.subtitle)
        }
        reportProgressInBackground()
    }

    /// Like Jellyfin and Swiftfin: the tracks chosen on the item page win; otherwise the server's
    /// defaults, which follow your Jellyfin settings (preferred languages, subtitle mode,
    /// "play default audio track", remembered selections). -1 = subtitles off.
    private struct RestoreTracks { let audio: Int?; let subtitle: Int?; let secondary: Int? }
    @ObservationIgnored private var restoreTracks: RestoreTracks?

    private func applyInitialTracks() {
        if let restore = restoreTracks {
            restoreTracks = nil
            if let a = restore.audio, let t = player.audioTracks.first(where: { $0.mpvID == a }), !t.isSelected {
                player.selectTrack(t.id)
            }
            if let sid = restore.subtitle, let t = player.subtitleTracks.first(where: { $0.mpvID == sid }) {
                player.selectSubtitle(t.id)
            } else {
                player.disableTrack(.subtitle)
            }
            if let sec = restore.secondary, let t = player.subtitleTracks.first(where: { $0.mpvID == sec }) {
                player.selectSubtitle(t.id, for: .secondary)
            }
            return
        }
        let audioIndex = request.audioIndex ?? source?.defaultAudioStreamIndex
        if let idx = audioIndex, let t = track(forJellyfinIndex: idx, type: .audio), !t.isSelected {
            player.selectTrack(t.id)
        }
        var subIndex = wantedSubtitleIndex
        if request.subtitleIndex == nil, let text = textAlternative(to: subIndex) {
            diagnostics.append("[JellyReco] Using text subtitle \(text) instead of picture subtitle \(subIndex) (Force my style)")
            subIndex = text
        }
        if subIndex < 0 {
            pendingSubtitleSelection = nil
            player.disableTrack(.subtitle)
        } else if let t = track(forJellyfinIndex: subIndex, type: .subtitle) {
            pendingSubtitleSelection = nil
            player.selectSubtitle(t.id)
        } else {
            // Not loaded yet (a subtitle file still downloading, or a server copy of a track the
            // player can't read): turned on when it arrives.
            pendingSubtitleSelection = subIndex
        }
    }

    /// Text subtitle formats the player reads.
    private static let textSubtitleCodecs: Set<String> = [
        "subrip", "srt", "ass", "ssa", "webvtt", "vtt", "mov_text", "tx3g", "text", "microdvd",
        "sami", "smi", "mpl2", "subviewer", "realtext", "jacosub", "vplayer",
    ]

    /// With Force my style, a picture subtitle (Blu-ray/DVD, whose look comes from the disc) is
    /// swapped for a text one in the same language, so every file looks the same. Only for the
    /// automatic choice: a subtitle picked on the item page is kept.
    private func textAlternative(to index: Int) -> Int? {
        guard settings.subtitleASSMode == "force", index >= 0,
              let picture = streams.first(where: { $0.isSubtitle && $0.index == index }),
              Self.isPictureSubtitle(picture.codec) else { return nil }
        let language = picture.language?.lowercased()
        let candidates = streams.filter {
            $0.isSubtitle && $0.index != index && $0.language?.lowercased() == language
                && Self.textSubtitleCodecs.contains(($0.codec ?? "").lowercased())
        }
        // Same kind of track (full vs forced-only, SDH or not) first.
        let sameKind = candidates.first(where: { ($0.isForced ?? false) == (picture.isForced ?? false)
                                                  && ($0.isHearingImpaired ?? false) == (picture.isHearingImpaired ?? false) })
        let sameForced = candidates.first(where: { ($0.isForced ?? false) == (picture.isForced ?? false) })
        return (sameKind ?? sameForced)?.index
    }

    // MARK: Controls

    func togglePlay() {
        if player.isPaused { play() } else { pause() }
        autoplayStreak = 0
    }

    /// Resumes with working sound: after a call, Siri, an alarm, another app's audio, a route
    /// change while paused or leaving the app, iOS may have taken the audio session away; mpv's
    /// audio output is then restarted first (it otherwise stayed silent until the video was
    /// reopened). A plain pause in the app keeps the output as it is: restarting it there only
    /// made the sound come back 2-3 s late.
    func play() {
        if videoNeedsRefresh {
            refreshAfterBackground()
        } else if audioNeedsReload {
            restoreAudio(reason: "audio was interrupted")
        } else {
            try? AVAudioSession.sharedInstance().setActive(true)
        }
        player.play()
    }

    func pause() {
        player.pause()
    }

    @ObservationIgnored private var videoNeedsRefresh = false
    @ObservationIgnored private var hardwareErrors: [Date] = []
    @ObservationIgnored private var decoderRecoveries = 0
    @ObservationIgnored private var lastDecoderRecovery = Date.distantPast

    /// The hardware-decoding setting mpv gets (the same as the player library's), and an
    /// equivalent spelling of it: switching between the two makes mpv build a brand-new decoder
    /// (VideoToolbox either way), which is how a decoder iOS ended in the background is replaced.
    private var hwdecValue: String { usesNativeOutput ? "auto-safe" : "videotoolbox,auto-safe" }
    private var hwdecAlternate: String { "videotoolbox" }
    @ObservationIgnored private var hwdecAlternated = false

    /// Back in the app after the background: a new video decoder (iOS ended the old one's session,
    /// and mpv only gave up on it after ~10 s of failed frames, holding back the sound meanwhile),
    /// the picture re-read from the keyframe before the current spot, and the audio output restarted.
    private func refreshAfterBackground() {
        videoNeedsRefresh = false
        hardwareErrors = []
        restoreAudio(reason: "back in the app")
        if settings.hardwareDecoding {
            // mpv rebuilds the decoder and itself re-reads the picture from this exact spot.
            hwdecAlternated.toggle()
            player.setProperty("hwdec", to: hwdecAlternated ? hwdecAlternate : hwdecValue)
        } else {
            player.seek(to: .seconds(max(0, currentSeconds)))
        }
        diagnostics.append("[JellyReco] New video decoder (back in the app)")
    }

    /// The hardware decoder failing frame after frame (its session is gone): restart it by
    /// briefly decoding in software, then hardware again from the keyframe before this spot.
    /// At most twice per file; after that mpv stays on software decoding, which always works.
    private func noteDecodeError(_ message: String) {
        guard message.contains("Error while decoding frame (hardware decoding)") else { return }
        let now = Date()
        hardwareErrors = hardwareErrors.filter { now.timeIntervalSince($0) < 4 } + [now]
        guard hardwareErrors.count >= 15, now.timeIntervalSince(lastDecoderRecovery) > 20 else { return }
        hardwareErrors = []
        lastDecoderRecovery = now
        decoderRecoveries += 1
        player.setProperty("hwdec", to: "no")
        guard decoderRecoveries <= 2, settings.hardwareDecoding else {
            diagnostics.append("[JellyReco] Hardware decoding keeps failing: using software decoding")
            return
        }
        diagnostics.append("[JellyReco] Hardware decoding failed: restarting it")
        let generation = loadGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, !self.stopped, self.loadGeneration == generation else { return }
            self.hwdecAlternated = false
            self.player.setProperty("hwdec", to: self.hwdecValue)
            self.player.seek(to: .seconds(max(0, self.currentSeconds)))
        }
    }

    func seek(to s: Double) {
        player.seek(to: .seconds(max(0, s)))
        reportProgressInBackground()
        wakeTicker()
    }

    func jump(_ delta: Double) {
        player.seek(by: .seconds(delta))
        wakeTicker()
    }

    func setSpeed(_ rate: Double) { player.setPlaybackRate(rate) }

    func setAudioDelay(_ s: Double) {
        audioDelay = s
        player.setAudioDelay(.milliseconds(Int(s * 1000)))
    }

    func setSubtitleDelay(_ s: Double) {
        subtitleDelay = s
        player.setSubtitleDelay(.milliseconds(Int(s * 1000)))
    }

    /// Double-tap / pinch: between fit and fill (from stretch, back to fit).
    func toggleFill() { aspectMode = aspectMode == .fit ? .fill : .fit }

    func setAspect(_ mode: AspectMode) { aspectMode = mode }

    @ObservationIgnored private var fillHidden: Double = 0
    @ObservationIgnored private var fillScale: Double = 1

    /// While the video is zoomed to fill, part of the picture is off screen (the native layer
    /// draws subtitles into the picture, so they're cropped with it): lift subtitles into the
    /// visible area and scale them back to their normal size.
    func applyFill(hiddenFraction: Double, scale: Double, textScale: Double) {
        guard hiddenFraction != fillHidden || max(scale, 1) != fillScale || textScale != self.textScale else { return }
        fillHidden = hiddenFraction
        fillScale = max(scale, 1)
        self.textScale = textScale
        applySubtitleLayout()
    }

    /// mpv sizes text against the picture's height, so a wide movie (a shorter picture on the
    /// screen) got smaller subtitles than a 16:9 episode with the same setting. This factor (the
    /// height a 16:9 picture would have on this screen ÷ this picture's height in Fit) evens it
    /// out: your style comes out the same size on every file.
    @ObservationIgnored private var textScale: Double = 1

    func applySubtitleScale() { applySubtitleLayout() }

    /// The picture's width / height (16:9 until the file says otherwise).
    private var videoAspect: Double {
        guard let d = player.mediaInformation.dimensions, d.width > 0, d.height > 0 else { return 16 / 9 }
        return Double(d.width) / Double(d.height)
    }

    /// What the primary subtitle is, as far as placing it goes.
    enum SubtitleKind: Equatable { case none, text, styled, picture }
    private var primarySubtitleKind: SubtitleKind {
        guard let sub = player.selectedSubtitle() else { return .none }
        let codec = (stream(for: sub)?.codec ?? sub.codec ?? "").lowercased()
        if Self.isPictureSubtitle(codec) { return .picture }
        return ["ass", "ssa"].contains(codec) ? .styled : .text
    }
    /// The subtitle (kind and track) the layout was last worked out for.
    @ObservationIgnored private var layoutKind: String?
    private var currentLayoutKey: String { "\(primarySubtitleKind)|\(assTrackKey)" }
    /// What was last given to mpv (changing sub-ass-override reloads the subtitles, so only on change).
    @ObservationIgnored private var appliedSubtitleProperties: [String: String] = [:]

    private func setSubtitleProperty(_ name: String, _ value: String) {
        guard appliedSubtitleProperties[name] != value else { return }
        appliedSubtitleProperties[name] = value
        player.setProperty(name, to: value)
    }

    /// Lowest text / ASS lines may go below their normal place (% of the picture): about the
    /// usual bottom margin, so they reach the edge without being cut.
    static let textLoweringLimit = 2.5

    /// Where subtitles sit (mpv sub-pos: 100 = their normal place, less = higher, more = lower).
    /// - Text and styled ASS: the Vertical position setting, relative to what's visible.
    /// - Picture subtitles (PGS, VobSub, DVB): placed by JellyReco's libmpv patch from where their
    ///   visible pixels are (each disc puts them at its own height, often well above the bottom).
    ///   With your style, the bottom lines sit exactly where text lines sit (same gap, the
    ///   Vertical position setting on top); keeping their own styling, they stay where the disc
    ///   put them and are only lifted, in Fill, by as much as is cut off. Top lines move down into
    ///   view in Fill.
    /// - "Keep their own styling" ASS ignores any repositioning in mpv, so while it has to move
    ///   (Fill, or a position other than 100 %) it runs as "keep styling" with a size that only
    ///   cancels the zoom: same fonts, colours and look.
    private func applySubtitleLayout() {
        let kind = primarySubtitleKind
        layoutKind = currentLayoutKey
        let base = Double(settings.subtitlePosition)
        let visible = 1 - 2 * fillHidden
        let filled = fillHidden > 0.001
        // In Fill the subtitles look exactly as in Fit: the same size on screen (the zoom is
        // cancelled) and the same line breaks (the lines get proportionally narrower, by wider
        // side margins), only moved into the part that stays on screen.
        let zoom = filled ? fillScale : 1
        let k = textScale
        var scale = settings.subtitleSize / zoom
        var override = settings.subtitleASSMode
        let pos: Double
        var marginY = 22.0                       // mpv's default gap above / below text lines (720 lines)
        var marginX = 25.0                       // and to the sides
        var styleOverrides = ""
        // Picture subtitles (% of the picture's height from its top; -1 = where the disc put them).
        var pictureBottom = -1.0
        var pictureBottomMode = "limit"
        var pictureTop = -1.0
        switch kind {
        case .picture:
            pos = 100                                // placed by sub-image-bottom/top instead
            // The plain-text gap below the lowest line (22 of 720 lines, scaled like the text),
            // as it looks on screen in Fit.
            let gap = 22.0 / 720 * 100 * k / zoom
            let visibleBottom = 100 * (1 - fillHidden)
            if override != "no" {
                let wanted = base > 100 ? 100 + min(base - 100, Self.textLoweringLimit) : base
                pictureBottom = visibleBottom - gap - (100 - wanted) * visible
                pictureBottomMode = "anchor"
            } else if filled {
                pictureBottom = visibleBottom - gap
            }
            if filled { pictureTop = 100 * fillHidden + gap }
        case .text, .none:
            // Your style at the same size on every file; top and bottom lines move in by the
            // cropped strip in Fill; the position setting on top.
            scale = settings.subtitleSize * k / zoom
            marginY = 22 * k / zoom + fillHidden * 720
            if filled {
                let width = 720 * videoAspect             // the picture's width in mpv's 720-line units
                marginX = (width - (width - 2 * 25) / zoom) / 2
            }
            let wanted = base > 100 ? 100 + min(base - 100, Self.textLoweringLimit) : base
            pos = 100 - (100 - wanted) * visible
        case .styled:
            let wanted = base > 100 ? 100 + min(base - 100, Self.textLoweringLimit) : base
            pos = 100 - (100 - wanted) * visible
            // "Keep their own styling" ignores any repositioning in mpv: while something has to
            // move, it runs as "keep styling" at the normal size (same fonts, colours, look).
            if override == "no" {
                // Their own size too (only cancelling the zoom).
                scale = 1 / zoom
                if filled || base != 100 { override = "scale" }
            } else {
                scale = settings.subtitleSize * k / zoom   // your size, the same on every file
            }
            // Force my style: mpv replaces the font, size, colours and outline but leaves each file's
            // bold, gaps and outline scaling, so every show looked a little different. Those are set
            // too: your Bold, the plain-text gaps (in the file's own units), scaled outlines.
            let forced = override == "force"
            // Top and bottom lines (\an8 / \an2 without an exact position) move in by the cropped
            // strip in Fill: every style's top/bottom margin plus that strip, in the file's units.
            if filled || forced {
                if let header = assHeader, header.trackKey == assTrackKey {
                    var parts: [String] = []
                    if forced {
                        parts.append("Bold=\(settings.subtitleBold ? -1 : 0)")
                        parts.append("ScaledBorderAndShadow=yes")
                    }
                    let margins = header.marginOverrides(
                        hidden: fillHidden, zoom: zoom,
                        forced: forced ? (vertical: 22 * k, side: 25) : nil)
                    if !margins.isEmpty { parts.append(margins) }
                    styleOverrides = parts.joined(separator: ",")
                } else {
                    requestASSHeader()
                }
            }
        }
        setSubtitleProperty("sub-image-bottom", String(format: "%.2f", pictureBottom < 0 ? -1 : min(100, max(40, pictureBottom))))
        setSubtitleProperty("sub-image-bottom-mode", pictureBottomMode)
        setSubtitleProperty("sub-image-top", String(format: "%.2f", pictureTop < 0 ? -1 : min(60, pictureTop)))
        setSubtitleProperty("sub-ass-override", override)
        setSubtitleProperty("sub-ass-style-overrides", styleOverrides)   // reloads the subtitles when it changes
        setSubtitleProperty("sub-margin-y", String(Int(marginY.rounded())))
        setSubtitleProperty("sub-margin-x", String(Int(marginX.rounded())))
        setSubtitleProperty("sub-pos", String(format: "%.1f", min(150, max(0, pos))))
        setSubtitleProperty("sub-scale", String(format: "%.3f", scale))
    }

    // MARK: ASS header (the file's own resolution and style margins, for Fill)

    /// An ASS file's resolution and each style's margins, as written in its header.
    struct ASSHeader {
        let trackKey: String
        let playResX: Double
        let playResY: Double
        let margins: [(style: String, left: Double, right: Double, vertical: Double)]

        /// mpv's sub-ass-style-overrides value for each style's margins (only styles whose names
        /// mpv's list syntax can carry). The base margins are the style's own, or with Force my style
        /// the plain-text ones (`forced`, in mpv's 720-line units) in this file's units. Then, with the
        /// font shrunk by `zoom` in Fill so lines look as in Fit on screen:
        /// - top/bottom margin: the cropped strip (`hidden` of the height) plus the base margin as
        ///   it looks in Fit;
        /// - side margins: wider, so each line is `zoom` times narrower and breaks as in Fit.
        func marginOverrides(hidden: Double, zoom: Double, forced: (vertical: Double, side: Double)?) -> String {
            let unit = playResY / 720
            return margins
                .filter { !$0.style.contains(",") && !$0.style.contains("=") && !$0.style.contains("\\") }
                .map { m in
                    let left = forced.map { $0.side * unit } ?? m.left
                    let right = forced.map { $0.side * unit } ?? m.right
                    let vertical = forced.map { $0.vertical * unit } ?? m.vertical
                    let width = max(0, playResX - left - right)
                    let extra = (width - width / zoom) / 2
                    return ["\(m.style).MarginL=\(Int((left + extra).rounded()))",
                            "\(m.style).MarginR=\(Int((right + extra).rounded()))",
                            "\(m.style).MarginV=\(Int((hidden * playResY + vertical / zoom).rounded()))"]
                        .joined(separator: ",")
                }
                .joined(separator: ",")
        }

        static func parse(_ text: String, trackKey: String) -> ASSHeader? {
            var playResX: Double?, playResY: Double?
            var format: [String] = []
            var margins: [(style: String, left: Double, right: Double, vertical: Double)] = []
            var inStyles = false
            for raw in text.split(whereSeparator: \.isNewline) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("[") { inStyles = line.lowercased().contains("styles"); continue }
                let lower = line.lowercased()
                if lower.hasPrefix("playresx:") { playResX = Double(line.dropFirst(9).trimmingCharacters(in: .whitespaces)) }
                if lower.hasPrefix("playresy:") { playResY = Double(line.dropFirst(9).trimmingCharacters(in: .whitespaces)) }
                guard inStyles else { continue }
                if lower.hasPrefix("format:") {
                    format = line.dropFirst(7).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                } else if lower.hasPrefix("style:"), let n = format.firstIndex(of: "name"),
                          let l = format.firstIndex(of: "marginl"), let r = format.firstIndex(of: "marginr"),
                          let v = format.firstIndex(of: "marginv") {
                    let fields = line.dropFirst(6).split(separator: ",", omittingEmptySubsequences: false)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                    guard fields.count == format.count, !fields[n].isEmpty,
                          let left = Double(fields[l]), let right = Double(fields[r]), let vertical = Double(fields[v]) else { continue }
                    margins.append((style: fields[n], left: left, right: right, vertical: vertical))
                }
            }
            // libass: neither given = 384 × 288; only one given = the other at 4:3
            // (PlayResY 1024 with no PlayResX = 1280, its special case).
            let resY = playResY ?? playResX.map { $0 * 3 / 4 } ?? 288
            let resX = playResX ?? (playResY == 1024 ? 1280 : resY * 4 / 3)
            guard resY > 0, resX > 0, !margins.isEmpty else { return nil }
            return ASSHeader(trackKey: trackKey, playResX: resX, playResY: resY, margins: margins)
        }
    }

    @ObservationIgnored private var assHeader: ASSHeader?
    @ObservationIgnored private var assHeaderRequested: String?
    @ObservationIgnored private var assHeaderLines: [String]?
    private static let assHeaderStart = "JRASS-BEGIN", assHeaderEnd = "JRASS-END"

    /// The selected primary subtitle track of this file.
    private var assTrackKey: String {
        "\(loadGeneration):\(player.selectedSubtitle()?.mpvID ?? -1)"
    }

    /// The playback library can't read mpv properties, so mpv prints the selected ASS track's
    /// header into its log, between two markers, and the log handler collects it.
    private func requestASSHeader() {
        let key = assTrackKey
        guard assHeaderRequested != key else { return }
        assHeaderRequested = key
        player.executeCommand("expand-properties", arguments: [
            "print-text", "\(Self.assHeaderStart)\n${sub-ass-extradata}\n\(Self.assHeaderEnd)",
        ])
    }

    private func collectASSHeader(_ msg: MPVLogMessage) {
        let line = msg.message.trimmingCharacters(in: .newlines)
        if line == Self.assHeaderStart { assHeaderLines = []; return }
        guard var lines = assHeaderLines else { return }
        if line == Self.assHeaderEnd {
            assHeaderLines = nil
            guard let key = assHeaderRequested,
                  let header = ASSHeader.parse(lines.joined(separator: "\n"), trackKey: key) else {
                diagnostics.append("[JellyReco] Couldn't read this subtitle's styles; top lines may be cut in Fill")
                return
            }
            assHeader = header
            applySubtitleLayout()
            return
        }
        lines.append(line)
        assHeaderLines = lines.count > 4000 ? nil : lines
    }

    func setFill(_ on: Bool) { aspectMode = on ? .fill : .fit }

    var currentSeconds: Double { seconds(player.position) }
    var durationSeconds: Double {
        let d = seconds(player.duration)
        return d > 0 ? d : (item.runtimeSeconds ?? 0)
    }

    func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    /// Chapters: Jellyfin's (with images) when present, otherwise the file's own.
    var chapters: [(title: String, start: Double, imageURL: URL?)] {
        if let ch = item.chapters, !ch.isEmpty {
            return ch.enumerated().map { i, c in
                (c.name ?? "Chapter \(i + 1)", Fmt.seconds(c.startPositionTicks),
                 client.chapterImageURL(itemId: item.id, index: i, tag: c.imageTag))
            }
        }
        return player.mediaInformation.chapters.enumerated().map { i, c in
            (c.title ?? "Chapter \(i + 1)", seconds(c.startTime), nil)
        }
    }

    // MARK: Segments (intro / recap / credits)

    private func updateSegments() {
        let now = currentSeconds
        let current = segments.first { seg in
            let a = Fmt.seconds(seg.startTicks), b = Fmt.seconds(seg.endTicks)
            return now >= a && now < b - 1 && ["Intro", "Recap", "Outro", "Preview", "Commercial"].contains(seg.type)
        }
        if let current, !skippedSegments.contains(current.id) {
            let action = settings.segmentAction(current.type)
            // As in the desktop client: skipping credits with another episode queued goes straight to it.
            if (action == "skip" || (action == "skipOnce" && !skippedSegments.contains("type:\(current.type)"))) {
                skippedSegments.insert("type:\(current.type)")
                skip(current)
                return
            }
        }
        activeSegment = current.flatMap { seg in
            skippedSegments.contains(seg.id) || settings.segmentAction(seg.type) == "none" ? nil : seg
        }
        // Credits with another episode queued: offer it now (Netflix-style).
        if let current, current.type == "Outro", upNext != nil, settings.autoPlayNext, upNextCountdown == nil, !askStillWatching, !countdownDismissed {
            beginCountdown()
        }
    }

    func skip(_ segment: MediaSegment) {
        skippedSegments.insert(segment.id)
        activeSegment = nil
        if segment.type == "Outro", upNext != nil {
            Task { await playNext(auto: false) }
            return
        }
        seek(to: Fmt.seconds(segment.endTicks))
    }

    func skipLabel(_ segment: MediaSegment) -> String {
        switch segment.type {
        case "Intro": return "Skip intro"
        case "Recap": return "Skip recap"
        case "Outro": return upNext != nil ? "Next episode" : "Skip credits"
        case "Preview": return "Skip preview"
        default: return "Skip"
        }
    }

    // MARK: Next episode

    private func handleEnded() async {
        guard upNext != nil else { return }
        if settings.autoPlayNext && !askStillWatching && upNextCountdown == nil && !countdownDismissed { beginCountdown() }
    }

    private func beginCountdown() {
        if settings.stillWatchingAfter > 0 && autoplayStreak >= settings.stillWatchingAfter {
            askStillWatching = true
            pause()
            return
        }
        countdownTask?.cancel()
        upNextCountdown = settings.nextUpCountdown
        countdownTask = Task { [weak self] in
            while let self, let left = self.upNextCountdown, left > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                self.upNextCountdown = left - 1
            }
            guard !Task.isCancelled else { return }
            await self?.playNext(auto: true)
        }
    }

    func cancelCountdown() {
        countdownTask?.cancel()
        upNextCountdown = nil
        countdownDismissed = true   // stays on the credits until you pick the next episode yourself
    }

    func confirmStillWatching() {
        askStillWatching = false
        autoplayStreak = 0
        Task { await playNext(auto: false) }
    }

    func playNext(auto: Bool) async {
        countdownTask?.cancel()
        upNextCountdown = nil
        guard let next = queue.first else { return }
        autoplayStreak = auto ? autoplayStreak + 1 : 0
        endSession()
        queue.removeFirst()
        request.audioIndex = nil
        request.subtitleIndex = nil
        request.mediaSourceId = nil
        triedMetal = false
        triedTranscode = false
        await open(next, start: 0, fallback: false)
    }

    /// The episode before this one (for the previous button), and more episodes ahead when the
    /// queue has run out (it reaches 50 episodes ahead, which long series outlast with autoplay).
    private func findNeighbours(of episode: BaseItem, generation: Int) {
        guard let sid = episode.seriesId else { return }
        Task { [weak self, client] in
            var around = (try? await client.episodes(seriesId: sid, adjacentTo: episode.id)) ?? []
            var i = around.firstIndex(where: { $0.id == episode.id })
            // The neighbour is a missing (virtual) episode: look further back in the whole list.
            if i == nil || (i! > 0 && around[i! - 1].locationType == "Virtual") {
                around = (try? await client.episodes(seriesId: sid)) ?? []
                i = around.firstIndex(where: { $0.id == episode.id })
            }
            guard let self, self.loadGeneration == generation, let i else { return }
            self.previousEpisode = around[..<i].last { $0.locationType != "Virtual" && $0.id != episode.id }
            if self.queue.isEmpty {
                let more = await self.model.episodesAfter(episode)
                guard self.loadGeneration == generation, self.queue.isEmpty, !more.isEmpty else { return }
                self.queue = more
                self.upNext = more.first
            }
        }
    }

    func playPrevious() async {
        guard let previous = previousEpisode else { return }
        countdownTask?.cancel()
        upNextCountdown = nil
        endSession()
        queue.insert(item, at: 0)
        request.audioIndex = nil
        request.subtitleIndex = nil
        request.mediaSourceId = nil
        triedMetal = false
        triedTranscode = false
        await open(previous, start: 0, fallback: false)
    }

    /// Another episode chosen from the Episodes panel (the player stays open).
    func switchTo(_ episode: BaseItem) async {
        countdownTask?.cancel()
        upNextCountdown = nil
        endSession()
        queue = await model.episodesAfter(episode)
        request.audioIndex = nil
        request.subtitleIndex = nil
        request.mediaSourceId = nil
        triedMetal = false
        triedTranscode = false
        autoplayStreak = 0
        await open(episode, start: nil, fallback: false)
    }

    var hasPrevious: Bool { previousEpisode != nil }

    // MARK: Retry / stop

    func retry() async {
        triedMetal = false
        triedTranscode = false
        endSession(failed: true)
        await open(item, start: currentSeconds > 1 ? currentSeconds : request.startSeconds, fallback: false)
    }

    func retryWithConversion() async {
        triedTranscode = true
        endSession(failed: true)
        await open(item, start: currentSeconds > 1 ? currentSeconds : request.startSeconds, fallback: true)
    }

    /// Closing: the player stops at once and the screen can close; telling the server (which can
    /// take up to the request timeout on a slow connection) happens in the background, and the
    /// app's shelves refresh once the server has the final position.
    func stop() async {
        guard !stopped else { return }
        stopped = true
        ticker?.cancel()
        countdownTask?.cancel()
        let finished = sessionEnd()
        player.stop()
        clearNowPlaying()
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
        routeObserver = nil
        interruptionObservers.forEach { NotificationCenter.default.removeObserver($0) }
        interruptionObservers = []
        try? FileManager.default.removeItem(at: Self.subtitleDirectory)
        let ids = playedIds
        Task { [model = self.model] in
            await finished()
            model.playbackEnded(itemIds: ids)
        }
    }

    /// Tells the server this play session is over (stop report, the server's conversion, a live
    /// TV tuner) before another one starts: a renderer switch, a fallback, next / previous episode.
    /// Without it the dashboard kept ghost sessions and the server went on converting the old file.
    private func endSession(failed: Bool = false) {
        let finished = sessionEnd(failed: failed)
        Task { await finished() }
    }

    private func sessionEnd(failed: Bool = false) -> @Sendable () async -> Void {
        let final = report(failed: failed)
        let client = client
        let transcoding = method == .transcode ? playSessionId : nil
        let live = source?.liveStreamId
        return {
            await client.reportStopped(final)
            if let transcoding { await client.stopEncoding(playSessionId: transcoding) }
            if let live { await client.closeLiveStream(live) }
        }
    }

    private func reportProgressInBackground() {
        let r = report()
        let client = client
        Task { await client.reportProgress(r) }
    }

    // MARK: Reporting

    private func report(failed: Bool = false) -> JellyfinClient.PlaybackReport {
        let audioIdx = player.audioTracks.first(where: \.isSelected).flatMap { stream(for: $0)?.index }
        let subIdx = player.selectedSubtitle().flatMap { stream(for: $0)?.index } ?? -1
        return JellyfinClient.PlaybackReport(
            itemId: item.id,
            mediaSourceId: source?.id,
            playSessionId: playSessionId,
            positionTicks: Fmt.ticks(hasPlayed ? currentSeconds : openedAt),
            isPaused: player.isPaused,
            isMuted: player.isMuted,
            playMethod: method.rawValue,
            audioStreamIndex: audioIdx,
            subtitleStreamIndex: subIdx,
            canSeek: player.isSeekable,
            playbackRate: player.playbackRate,
            failed: failed ? true : nil,
            liveStreamId: source?.liveStreamId
        )
    }

    // MARK: Lock screen / Control Center

    private func installRemoteCommands() {
        guard !remoteCommandsInstalled else { return }
        remoteCommandsInstalled = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in self?.play(); return .success }
        center.pauseCommand.addTarget { [weak self] _ in self?.pause(); return .success }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in self?.togglePlay(); return .success }
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: settings.jumpForward)]
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: settings.jumpBackward)]
        center.skipForwardCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.jump(Double(self.settings.jumpForward)); return .success
        }
        center.skipBackwardCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.jump(-Double(self.settings.jumpBackward)); return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: e.positionTime); return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            guard let self, self.upNext != nil else { return .noSuchContent }
            Task { await self.playNext(auto: false) }; return .success
        }
    }

    private func updateNowPlaying() {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.displayName,
            MPMediaItemPropertyPlaybackDuration: durationSeconds,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentSeconds,
            MPNowPlayingInfoPropertyPlaybackRate: player.isPaused ? 0.0 : player.playbackRate,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
        ]
        if let series = item.seriesName { info[MPMediaItemPropertyArtist] = series }
        if let label = item.episodeLabel { info[MPMediaItemPropertyAlbumTitle] = label }
        if let art = nowPlayingArtwork { info[MPMediaItemPropertyArtwork] = art }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        if nowPlayingArtwork == nil, let url = client.landscapeURL(item, width: 600) {
            Task { [weak self] in
                guard let (data, _) = try? await URLSession.shared.data(from: url), let image = UIImage(data: data) else { return }
                self?.nowPlayingArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            }
        }
    }

    @ObservationIgnored private var nowPlayingArtwork: MPMediaItemArtwork?

    private func clearNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        let center = MPRemoteCommandCenter.shared()
        for cmd in [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand, center.skipForwardCommand,
                    center.skipBackwardCommand, center.changePlaybackPositionCommand, center.nextTrackCommand] as [MPRemoteCommand] {
            cmd.removeTarget(nil)
        }
    }
}

// MARK: - Trickplay thumbnails

/// Server-generated preview thumbnails (Jellyfin trickplay tiles), cut out of the tile sheets.
@MainActor
final class TrickplayProvider {
    let info: TrickplayInfo
    private let client: JellyfinClient
    private let itemId: String
    private let sourceId: String
    /// The few most recent tile sheets (each is a large decoded image: keeping every sheet of a
    /// long film used 100–200 MB), and sheets that failed (not asked for again on every redraw).
    private var sheets: [Int: UIImage] = [:]
    private var recent: [Int] = []
    private var loading: Set<Int> = []
    private var failed: Set<Int> = []
    private let keep = 4

    init(client: JellyfinClient, itemId: String, sourceId: String, info: TrickplayInfo) {
        self.client = client
        self.itemId = itemId
        self.sourceId = sourceId
        self.info = info
    }

    var aspect: CGFloat { info.height > 0 ? CGFloat(info.width) / CGFloat(info.height) : 16 / 9 }

    /// The thumbnail for a time, or nil while its sheet downloads (the next call has it).
    func thumbnail(at seconds: Double) -> UIImage? {
        guard info.interval > 0 else { return nil }
        let perSheet = max(1, info.tileWidth * info.tileHeight)
        let index = min(max(0, Int(seconds * 1000) / info.interval), max(0, info.thumbnailCount - 1))
        let sheet = index / perSheet
        guard let image = sheets[sheet], let cg = image.cgImage else {
            load(sheet)
            return nil
        }
        if recent.last != sheet { recent.removeAll { $0 == sheet }; recent.append(sheet) }
        let within = index % perSheet
        let x = (within % info.tileWidth) * info.width
        let y = (within / info.tileWidth) * info.height
        let scale = CGFloat(cg.width) / CGFloat(info.tileWidth * info.width)
        let rect = CGRect(x: CGFloat(x) * scale, y: CGFloat(y) * scale, width: CGFloat(info.width) * scale, height: CGFloat(info.height) * scale)
        guard let crop = cg.cropping(to: rect) else { return nil }
        return UIImage(cgImage: crop)
    }

    private func load(_ sheet: Int) {
        guard !loading.contains(sheet), !failed.contains(sheet), let url = client.trickplayTileURL(itemId: itemId, mediaSourceId: sourceId, width: info.width, index: sheet) else { return }
        loading.insert(sheet)
        var request = URLRequest(url: url)
        request.setValue(client.authorizationHeader, forHTTPHeaderField: "Authorization")
        Task { [weak self] in
            guard let self else { return }
            if let (data, response) = try? await URLSession.shared.data(for: request),
               ((response as? HTTPURLResponse)?.statusCode ?? 200) < 400, let image = UIImage(data: data) {
                self.sheets[sheet] = image
                self.recent.removeAll { $0 == sheet }
                self.recent.append(sheet)
                while self.recent.count > self.keep { self.sheets[self.recent.removeFirst()] = nil }
            } else {
                self.failed.insert(sheet)
            }
            self.loading.remove(sheet)
        }
    }
}

private extension Array {
    func ifEmpty(_ other: @autoclosure () -> [Element]) -> [Element] { isEmpty ? other() : self }
}
