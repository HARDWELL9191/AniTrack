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
    private(set) var upNextCountdown: Int?
    private(set) var askStillWatching = false
    private(set) var statusNote: String?
    private(set) var audioDelay: Double = 0
    private(set) var subtitleDelay: Double = 0
    /// Fill instead of fit (the surface is scaled up to cover the screen, like Apple's player).
    private(set) var isFilled = false
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

    var settings: AppSettings { model.settings }

    init(request: PlaybackRequest, model: AppModel) {
        self.request = request
        self.model = model
        self.client = model.client!
        self.item = request.item
        self.queue = request.queue
        self.player = MPVPlayer(configuration: Self.configuration(settings: model.settings,
                                                                  output: model.settings.playerEngine == .mpv ? .metal : .sampleBuffer))
        attachLog()
    }

    private func attachLog() {
        player.logHandler = { [weak self] msg in
            guard let self else { return }
            let line = "[\(msg.prefix)] \(msg.message.trimmingCharacters(in: .whitespacesAndNewlines))"
            self.diagnostics.append(line)
            if self.diagnostics.count > 40 { self.diagnostics.removeFirst(self.diagnostics.count - 40) }
        }
    }

    // MARK: Configuration

    static func configuration(settings: AppSettings, output: MPVPlayerConfiguration.VideoOutput) -> MPVPlayerConfiguration {
        var options: [String: String] = [
            // Subtitles: mpv/libass renders ASS with its own styles; these shape plain text ones.
            "sub-auto": "no",
            "sid": "no",
            "sub-codepage": "auto",
            "sub-ass-override": settings.overrideASSStyles ? "force" : "scale",
            "sub-scale": String(format: "%.2f", settings.subtitleSize),
            "sub-color": settings.subtitleColor.mpvHex,
            "sub-bold": settings.subtitleBold ? "yes" : "no",
            "sub-pos": "\(settings.subtitlePosition)",
            "sub-font-size": "52",
            "demuxer-readahead-secs": "30",
            "embeddedfonts": "yes",
            "network-timeout": "30",
            "screenshot-format": "png",
        ]
        switch settings.subtitleBackground {
        case .outline:
            options["sub-border-style"] = "outline-and-shadow"
            options["sub-border-size"] = "3"
            options["sub-shadow-offset"] = "1"
        case .shadow:
            options["sub-border-style"] = "outline-and-shadow"
            options["sub-border-size"] = "1"
            options["sub-shadow-offset"] = "3"
        case .box:
            options["sub-border-style"] = "background-box"
            options["sub-back-color"] = "#99000000"
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
            logLevel: .warning,
            networkCacheDuration: .seconds(30),
            playbackRate: settings.defaultSpeed,
            videoOutput: output
        )
    }

    // MARK: Start

    func start() async {
        guard !started else { return }
        started = true
        installRemoteCommands()
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
        skippedSegments = []
        activeSegment = nil
        upNextCountdown = nil
        let resumeSeconds: Double = {
            if let start { return start }
            let ticks = model.userData(for: target)?.playbackPositionTicks ?? target.resumeTicks
            guard ticks > 0, !(model.userData(for: target)?.played ?? false) else { return 0 }
            return max(0, Fmt.seconds(ticks) - Double(settings.resumeOffset))
        }()

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

            // The subtitle that will be shown is picture-based: use the Metal renderer from the start.
            let subIndex = request.subtitleIndex ?? src.defaultSubtitleStreamIndex ?? -1
            if usesNativeOutput, subIndex >= 0,
               let sub = streams.first(where: { $0.index == subIndex && $0.isSubtitle }), Self.isPictureSubtitle(sub.codec) {
                rebuildPlayer(output: .metal)
            }

            let url: URL?
            if fallback, let t = src.transcodingUrl {
                url = client.absolute(t)
                method = .transcode
            } else {
                url = client.directStreamURL(itemId: full.id, source: src, playSessionId: playSessionId)
                method = .directPlay
            }
            guard let url else { throw JellyfinError.message("Couldn't build the stream address.") }

            player.load(url, playAutomatically: true, startTime: resumeSeconds > 1 ? .seconds(resumeSeconds) : nil)
            player.setPlaybackRate(settings.defaultSpeed)
            loadExternalSubtitles(itemId: full.id, source: src)
            prepareTrickplay(full, source: src)
            Task { segments = await client.mediaSegments(itemId: full.id) }

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

    private func loadExternalSubtitles(itemId: String, source: MediaSourceInfo) {
        let external = streams.filter { $0.isSubtitle && ($0.isExternal ?? false) }
        for sub in external {
            let format = (sub.codec ?? "srt").lowercased()
                .replacingOccurrences(of: "subrip", with: "srt")
                .replacingOccurrences(of: "pgssub", with: "sup")
                .replacingOccurrences(of: "webvtt", with: "vtt")
            guard let url = client.subtitleURL(itemId: itemId, sourceId: source.id, stream: sub, format: format) else { continue }
            externalSubs.append(sub)
            player.loadExternalSubtitle(url, selecting: nil)
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

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                await self?.tick()
            }
        }
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
        // Track lists arrive in pieces: wait until subtitles are known (or 3 s of playback)
        // before choosing, otherwise the subtitle choice is made against an empty list.
        let expectsSubs = streams.contains(where: \.isSubtitle)
        let subsReady = !expectsSubs || !player.subtitleTracks.isEmpty
        let waitedEnough = playingSince.map { Date().timeIntervalSince($0) > 3 } ?? false
        if !didApplyTracks, !player.audioTracks.isEmpty, subsReady || waitedEnough {
            didApplyTracks = true
            applyInitialTracks()
        }
        checkSubtitleRendering()
        updateSegments()

        if state == .ended { await handleEnded() }

        let paused = player.isPaused
        if paused != lastPaused || Date().timeIntervalSince(lastReport) >= 10 {
            lastPaused = paused
            lastReport = Date()
            if phase == .playing { await client.reportProgress(report()) }
            updateNowPlaying()
        }
    }

    private func handleFailure(_ error: MPVPlayerError) async {
        let at = seconds(player.position)
        // 2) Native layer can't show this file: same file, mpv's own renderer.
        if player.configuration.videoOutput == .sampleBuffer && !triedMetal {
            triedMetal = true
            statusNote = "Switching to the high-quality renderer…"
            rebuildPlayer(output: .metal)
            await open(item, start: at > 1 ? at : request.startSeconds, fallback: false)
            return
        }
        // 3) The iPhone really can't play it: server conversion, only if allowed.
        if settings.transcodeFallback && !triedTranscode {
            triedTranscode = true
            await client.reportStopped(report(failed: true))
            await open(item, start: at > 1 ? at : request.startSeconds, fallback: true)
            return
        }
        let codecs = describeFile()
        phase = .failed("\(error.message)\(codecs.isEmpty ? "" : "\n\n\(codecs)")")
    }

    private func rebuildPlayer(output: MPVPlayerConfiguration.VideoOutput) {
        player.stop()
        player = MPVPlayer(configuration: Self.configuration(settings: settings, output: output))
        player.pictureInPicture.allowsAutomaticStartFromInline = settings.pipAutomatically
        attachLog()
    }

    var usesNativeOutput: Bool { player.configuration.videoOutput == .sampleBuffer }

    /// Picture-based subtitles (Blu-ray PGS, DVD VobSub, DVB). mpv's Metal renderer always draws
    /// these; the native video layer doesn't reliably, so they get the Metal renderer.
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
        request.audioIndex = player.audioTracks.first(where: \.isSelected).flatMap { stream(for: $0)?.index }
        request.subtitleIndex = player.selectedSubtitle().flatMap { stream(for: $0)?.index } ?? -1
        triedMetal = toMetal
        rebuildPlayer(output: toMetal ? .metal : .sampleBuffer)
        await open(item, start: at, fallback: method == .transcode)
    }

    /// A picture subtitle selected while the native layer is in use: move to the Metal renderer
    /// (same spot, same tracks) so it's actually drawn.
    @ObservationIgnored private var subtitleCheckDone: Set<Int> = []
    private func checkSubtitleRendering() {
        guard usesNativeOutput, let sub = player.selectedSubtitle(), !subtitleCheckDone.contains(sub.mpvID) else { return }
        subtitleCheckDone.insert(sub.mpvID)
        let codec = stream(for: sub)?.codec ?? sub.codec
        if Self.isPictureSubtitle(codec) {
            statusNote = "Switching renderer for picture subtitles…"
            Task { await switchRenderer(toMetal: true) }
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

    private var embeddedAudio: [MediaStream] { streams.filter { $0.isAudio && !($0.isExternal ?? false) }.sorted { $0.index < $1.index } }
    private var embeddedSubs: [MediaStream] { streams.filter { $0.isSubtitle && !($0.isExternal ?? false) }.sorted { $0.index < $1.index } }

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
        let tracks = type == .audio ? player.audioTracks : player.subtitleTracks
        return tracks.first { stream(for: $0)?.index == index }
    }

    var audioOptions: [TrackOption] { player.audioTracks.map(option) }
    var subtitleOptions: [TrackOption] { player.subtitleTracks.map(option) }

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
        player.selectTrack(id)
        Task { await client.reportProgress(report()) }
    }

    func selectSubtitle(_ id: MPVMediaTrackIdentifier?, secondary: Bool = false) {
        if secondary {
            player.selectSubtitle(id, for: .secondary)
        } else if let id {
            player.selectSubtitle(id, for: .primary)
            subtitleCheckDone.remove(id.mpvID)
        } else {
            player.disableTrack(.subtitle)
        }
        Task { await client.reportProgress(report()) }
    }

    /// Like Jellyfin and Swiftfin: the tracks chosen on the item page win; otherwise the server's
    /// defaults, which follow your Jellyfin settings (preferred languages, subtitle mode,
    /// "play default audio track", remembered selections). -1 = subtitles off.
    private func applyInitialTracks() {
        let audioIndex = request.audioIndex ?? source?.defaultAudioStreamIndex
        if let idx = audioIndex, let t = track(forJellyfinIndex: idx, type: .audio), !t.isSelected {
            player.selectTrack(t.id)
        }
        let subIndex = request.subtitleIndex ?? source?.defaultSubtitleStreamIndex ?? -1
        if subIndex < 0 {
            player.disableTrack(.subtitle)
        } else if let t = track(forJellyfinIndex: subIndex, type: .subtitle) {
            player.selectSubtitle(t.id)
        }
    }

    // MARK: Controls

    func togglePlay() {
        player.togglePlayback()
        autoplayStreak = 0
    }

    func seek(to s: Double) {
        player.seek(to: .seconds(max(0, s)))
        Task { await client.reportProgress(report()) }
    }

    func jump(_ delta: Double) {
        player.seek(by: .seconds(delta))
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

    func toggleFill() { isFilled.toggle() }

    func setFill(_ on: Bool) { isFilled = on }

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
            let auto = (current.type == "Intro" && settings.autoSkipIntro)
                || (current.type == "Recap" && settings.autoSkipRecap)
                || (current.type == "Outro" && settings.autoSkipOutro && upNext == nil)
                || (current.type == "Commercial")
            if auto {
                skip(current)
                return
            }
        }
        activeSegment = settings.showSkipButtons ? current.flatMap { skippedSegments.contains($0.id) ? nil : $0 } : nil
        // Credits with another episode queued: offer it now (Netflix-style).
        if let current, current.type == "Outro", upNext != nil, settings.autoPlayNext, upNextCountdown == nil, !askStillWatching {
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
        if settings.autoPlayNext && !askStillWatching && upNextCountdown == nil { beginCountdown() }
    }

    private func beginCountdown() {
        if settings.stillWatchingAfter > 0 && autoplayStreak >= settings.stillWatchingAfter {
            askStillWatching = true
            player.pause()
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
        await client.reportStopped(report())
        queue.removeFirst()
        request.audioIndex = nil
        request.subtitleIndex = nil
        request.mediaSourceId = nil
        triedMetal = false
        triedTranscode = false
        await open(next, start: 0, fallback: false)
    }

    func playPrevious() async {
        guard let sid = item.seriesId, let all = try? await client.episodes(seriesId: sid),
              let i = all.firstIndex(where: { $0.id == item.id }), i > 0 else { return }
        await client.reportStopped(report())
        queue.insert(item, at: 0)
        await open(all[i - 1], start: 0, fallback: false)
    }

    /// Another episode chosen from the Episodes panel (the player stays open).
    func switchTo(_ episode: BaseItem) async {
        countdownTask?.cancel()
        upNextCountdown = nil
        await client.reportStopped(report())
        queue = await model.episodesAfter(episode)
        request.audioIndex = nil
        request.subtitleIndex = nil
        request.mediaSourceId = nil
        triedMetal = false
        triedTranscode = false
        autoplayStreak = 0
        await open(episode, start: nil, fallback: false)
    }

    var hasPrevious: Bool { item.kind == .episode && (item.indexNumber ?? 1) > 1 }

    // MARK: Retry / stop

    func retry() async {
        triedMetal = false
        triedTranscode = false
        await open(item, start: currentSeconds > 1 ? currentSeconds : request.startSeconds, fallback: false)
    }

    func retryWithConversion() async {
        triedTranscode = true
        await open(item, start: currentSeconds > 1 ? currentSeconds : request.startSeconds, fallback: true)
    }

    func stop() async {
        ticker?.cancel()
        countdownTask?.cancel()
        let final = report()
        player.stop()
        await client.reportStopped(final)
        if method == .transcode, let ps = playSessionId { await client.stopEncoding(playSessionId: ps) }
        clearNowPlaying()
        model.playbackEnded(itemIds: playedIds)
    }

    // MARK: Reporting

    private func report(failed: Bool = false) -> JellyfinClient.PlaybackReport {
        let audioIdx = player.audioTracks.first(where: \.isSelected).flatMap { stream(for: $0)?.index }
        let subIdx = player.selectedSubtitle().flatMap { stream(for: $0)?.index } ?? -1
        return JellyfinClient.PlaybackReport(
            itemId: item.id,
            mediaSourceId: source?.id,
            playSessionId: playSessionId,
            positionTicks: Fmt.ticks(currentSeconds),
            isPaused: player.isPaused,
            isMuted: player.isMuted,
            playMethod: method.rawValue,
            audioStreamIndex: audioIdx,
            subtitleStreamIndex: subIdx,
            canSeek: player.isSeekable,
            playbackRate: player.playbackRate,
            failed: failed ? true : nil
        )
    }

    // MARK: Lock screen / Control Center

    private func installRemoteCommands() {
        guard !remoteCommandsInstalled else { return }
        remoteCommandsInstalled = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in self?.player.play(); return .success }
        center.pauseCommand.addTarget { [weak self] _ in self?.player.pause(); return .success }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in self?.player.togglePlayback(); return .success }
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
    private var sheets: [Int: UIImage] = [:]
    private var loading: Set<Int> = []

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
        let within = index % perSheet
        let x = (within % info.tileWidth) * info.width
        let y = (within / info.tileWidth) * info.height
        let scale = CGFloat(cg.width) / CGFloat(info.tileWidth * info.width)
        let rect = CGRect(x: CGFloat(x) * scale, y: CGFloat(y) * scale, width: CGFloat(info.width) * scale, height: CGFloat(info.height) * scale)
        guard let crop = cg.cropping(to: rect) else { return nil }
        return UIImage(cgImage: crop)
    }

    private func load(_ sheet: Int) {
        guard !loading.contains(sheet), let url = client.trickplayTileURL(itemId: itemId, mediaSourceId: sourceId, width: info.width, index: sheet) else { return }
        loading.insert(sheet)
        var request = URLRequest(url: url)
        request.setValue(client.authorizationHeader, forHTTPHeaderField: "Authorization")
        Task { [weak self] in
            if let (data, _) = try? await URLSession.shared.data(for: request), let image = UIImage(data: data) {
                self?.sheets[sheet] = image
            }
            self?.loading.remove(sheet)
        }
    }
}
