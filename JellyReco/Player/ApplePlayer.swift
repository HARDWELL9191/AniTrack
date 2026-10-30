import AVFoundation
import AVKit
import UIKit
import VideoToolbox

/// Which player a file gets.
enum PlayerRoute: Equatable {
    /// Apple's own AVPlayerViewController. `direct`: the file as it is (MP4/MOV). Otherwise
    /// Jellyfin repackages it losslessly into HLS (video and audio copied, nothing re-encoded).
    case apple(direct: Bool)
    /// JellyReco's mpv player (Apple-style controls) for everything Apple's player can't do properly.
    case mpv
}

@MainActor
enum PlayerRouter {
    static let appleContainers: Set<String> = ["mp4", "m4v", "mov"]
    static let appleAudio: Set<String> = ["aac", "ac3", "eac3", "alac", "mp3", "flac"]
    static var deviceDecodesAV1: Bool { VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1) }

    /// Apple's player only when it plays the file with nothing lost; mpv otherwise:
    /// - video Apple can't decode (VP9, MPEG-2, VC-1, 10-bit H.264, >10-bit, interlaced, AV1 without hardware)
    /// - audio Apple can't decode (DTS, TrueHD, Opus, Vorbis, PCM in MKV…)
    /// - picture subtitles (PGS/VobSub/DVB) and styled ASS/SSA subtitles (Apple would flatten them)
    /// - several audio tracks in a file that needs repackaging (the repackaged stream carries one)
    /// - remote/.strm links and Live TV
    static func route(for source: MediaSourceInfo, item: BaseItem) -> PlayerRoute {
        if [.tvChannel, .program, .liveTvProgram].contains(item.kind) { return .mpv }
        if let p = source.protocol, p.lowercased() != "file" { return .mpv }
        if source.isRemote == true || source.isInfiniteStream == true { return .mpv }
        let streams = source.mediaStreams ?? []
        let audio = streams.filter(\.isAudio)
        let subs = streams.filter(\.isSubtitle)
        guard let v = streams.first(where: \.isVideo) else { return .mpv }

        let depth = v.bitDepth ?? 8
        switch (v.codec ?? "").lowercased() {
        case "h264", "avc":
            if depth > 8 || (v.profile ?? "").lowercased().contains("10") { return .mpv }
        case "hevc", "h265":
            if depth > 10 { return .mpv }
            if (v.videoRangeType ?? "").uppercased().contains("DOVI") && (v.profile ?? "").contains("7") { return .mpv }
        case "av1":
            if !deviceDecodesAV1 || depth > 10 { return .mpv }
        default:
            return .mpv
        }
        if v.isInterlaced == true { return .mpv }
        guard audio.allSatisfy({ appleAudio.contains(($0.codec ?? "").lowercased()) }) else { return .mpv }

        for s in subs {
            let c = (s.codec ?? "").lowercased()
            if PlaybackController.isPictureSubtitle(c) || c == "ass" || c == "ssa" { return .mpv }
        }
        let containers = Set((source.container ?? "").lowercased().split(separator: ",").map(String.init))
        let appleFile = !containers.isDisjoint(with: appleContainers)
        let onlyAppleSubs = subs.allSatisfy {
            !($0.isExternal ?? false) && ["mov_text", "tx3g"].contains(($0.codec ?? "").lowercased())
        }
        if appleFile && onlyAppleSubs { return .apple(direct: true) }
        if audio.count > 1 { return .mpv }
        return .apple(direct: false)
    }

    /// What we tell Jellyfin for Apple's player: MP4/MOV play as they are; anything else is
    /// repackaged into HLS (fMP4) with the video and audio copied and text subtitles as WebVTT.
    static func profile() -> DeviceProfile {
        var video = "h264,hevc"
        if deviceDecodesAV1 { video += ",av1" }
        let audio = appleAudio.sorted().joined(separator: ",")
        return DeviceProfile(
            name: "JellyReco (Apple player)",
            directPlayProfiles: [
                DeviceProfile.DirectPlayProfile(container: "mp4,m4v,mov", type: "Video", videoCodec: video, audioCodec: audio),
            ],
            transcodingProfiles: [
                DeviceProfile.TranscodingProfile(container: "mp4", type: "Video", videoCodec: video, audioCodec: audio,
                                                 protocol: "hls", breakOnNonKeyFrames: true,
                                                 enableSubtitlesInManifest: true),
            ],
            subtitleProfiles: ["srt", "subrip", "vtt", "webvtt", "ttml", "smi", "microdvd", "mpl2", "sub"].map {
                DeviceProfile.SubtitleProfile(format: $0, method: "Hls")
            } + ["mov_text", "tx3g"].map { DeviceProfile.SubtitleProfile(format: $0, method: "Embed") }
        )
    }

    /// Jellyfin's reasons that only mean "repackage" (video and audio are still copied).
    static let repackageReasons: Set<String> = ["ContainerNotSupported", "SubtitleCodecNotSupported", "DirectPlayError"]
}

// MARK: - Starting playback

extension AppModel {
    /// Every play button ends here: Apple's player when the file allows it (and the setting is
    /// on), otherwise the mpv player.
    func startPlayback(_ request: PlaybackRequest) async {
        guard settings.applePlayer, let client, ApplePlayerSession.current == nil else {
            playback = request
            return
        }
        let target = request.item
        let full = target.mediaSources == nil ? ((try? await client.item(target.id)) ?? target) : target
        let sources = full.mediaSources ?? []
        guard let src = sources.first(where: { $0.id == request.mediaSourceId }) ?? sources.first,
              case .apple(let direct) = PlayerRouter.route(for: src, item: full) else {
            playback = request
            return
        }
        guard let info = try? await client.playbackInfo(itemId: full.id, ApplePlayerSession.infoRequest(
                client: client, direct: direct, mediaSourceId: src.id,
                audio: request.audioIndex, subtitle: request.subtitleIndex)),
              let served = (info.mediaSources ?? []).first(where: { $0.id == src.id }) ?? info.mediaSources?.first,
              ApplePlayerSession.isLossless(served, direct: direct),
              let presenter = UIApplication.topViewController else {
            playback = request
            return
        }
        var req = request
        req.item = full
        let session = ApplePlayerSession(request: req, model: self)
        ApplePlayerSession.current = session
        session.present(from: presenter, info: info, source: served, direct: direct)
    }
}

extension UIApplication {
    @MainActor static var topViewController: UIViewController? {
        let scenes = shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first?.windows.first
        var top = window?.rootViewController
        while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }
}

// MARK: - Apple's player

/// One playback in Apple's AVPlayerViewController (its own controls, menus, Picture in Picture,
/// AirPlay). JellyReco only adds what Jellyfin needs: resume point, progress reports (Continue
/// Watching, the dashboard), your server's default audio/subtitle, skip intro and next episode
/// (Apple's own contextual buttons). If Apple's player can't open the file, mpv takes over.
@MainActor
final class ApplePlayerSession: NSObject, AVPlayerViewControllerDelegate {
    static var current: ApplePlayerSession?

    private let model: AppModel
    private let client: JellyfinClient
    private var item: BaseItem
    private var queue: [BaseItem]
    private var request: PlaybackRequest
    private let player = AVPlayer()
    private let controller = JellyRecoAVPlayerViewController()
    private var source: MediaSourceInfo?
    private var playSessionId: String?
    private var isDirect = true
    private var timeObserver: Any?
    private var itemObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var segments: [MediaSegment] = []
    private var skipped: Set<String> = []
    private var lastReport = Date.distantPast
    private var playedIds: [String] = []
    private var startedPlaying = false
    private var finished = false
    private var resumeAt: Double = 0

    init(request: PlaybackRequest, model: AppModel) {
        self.request = request
        self.model = model
        self.client = model.client!
        self.item = request.item
        self.queue = request.queue
        super.init()
    }

    static func infoRequest(client: JellyfinClient, direct: Bool, mediaSourceId: String?,
                            audio: Int?, subtitle: Int?) -> JellyfinClient.PlaybackInfoRequest {
        JellyfinClient.PlaybackInfoRequest(
            userId: client.userId ?? "",
            maxStreamingBitrate: 400_000_000,
            startTimeTicks: nil,              // Apple's player seeks itself (HLS covers the whole file)
            audioStreamIndex: audio,
            subtitleStreamIndex: subtitle,
            maxAudioChannels: 8,
            mediaSourceId: mediaSourceId,
            deviceProfile: PlayerRouter.profile(),
            enableDirectPlay: direct,
            enableDirectStream: true,
            enableTranscoding: !direct,
            allowVideoStreamCopy: true,
            allowAudioStreamCopy: true,
            autoOpenLiveStream: false,
            alwaysBurnInSubtitleWhenTranscoding: false
        )
    }

    /// True when Jellyfin will hand over the file as it is (direct) or only repackage it.
    static func isLossless(_ source: MediaSourceInfo, direct: Bool) -> Bool {
        if direct { return source.supportsDirectPlay == true }
        guard source.transcodingUrl != nil else { return false }
        return (source.transcodeReasons ?? []).allSatisfy { PlayerRouter.repackageReasons.contains($0) }
    }

    func present(from presenter: UIViewController, info: PlaybackInfoResponse, source: MediaSourceInfo, direct: Bool) {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, policy: .longFormVideo)
        try? AVAudioSession.sharedInstance().setActive(true)
        controller.player = player
        controller.delegate = self
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = model.settings.pipAutomatically
        controller.updatesNowPlayingInfoCenter = true
        controller.modalPresentationStyle = .fullScreen
        controller.onClose = { [weak self] in Task { await self?.finish() } }
        installObservers()
        load(item, info: info, source: source, direct: direct, start: request.startSeconds)
        presenter.present(controller, animated: true)
    }

    private func load(_ full: BaseItem, info: PlaybackInfoResponse, source: MediaSourceInfo, direct: Bool, start: Double?) {
        item = full
        self.source = source
        playSessionId = info.playSessionId
        isDirect = direct
        skipped = []
        segments = []
        startedPlaying = false
        controller.contextualActions = []
        guard let url = streamURL(full, source: source, direct: direct) else {
            handOffToMPV(reason: "no stream address")
            return
        }
        let playerItem = AVPlayerItem(asset: AVURLAsset(url: url))
        playerItem.externalMetadata = metadata(for: full)
        observe(playerItem)
        player.replaceCurrentItem(with: playerItem)

        resumeAt = {
            if let start { return start }
            let ticks = model.userData(for: full)?.playbackPositionTicks ?? full.resumeTicks
            guard ticks > 0, !(model.userData(for: full)?.played ?? false) else { return 0 }
            return max(0, Fmt.seconds(ticks) - Double(model.settings.resumeOffset))
        }()
        if resumeAt > 1 {
            player.seek(to: CMTime(seconds: resumeAt, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        let speed = Float(model.settings.defaultSpeed)
        player.defaultRate = speed
        player.playImmediately(atRate: speed)
        if !playedIds.contains(full.id) { playedIds.append(full.id) }
        Task {
            segments = await client.mediaSegments(itemId: full.id)
            await client.reportStart(report())
        }
        Task { await applyServerDefaultTracks(playerItem, source: source) }
    }

    private func streamURL(_ item: BaseItem, source: MediaSourceInfo, direct: Bool) -> URL? {
        if !direct { return source.transcodingUrl.flatMap { client.absolute($0) } }
        guard let base = client.directStreamURL(itemId: item.id, source: source, playSessionId: playSessionId),
              var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        // Give Apple's player the file type: /stream → /stream.mp4 (or .mov/.m4v).
        let containers = (source.container ?? "").lowercased().split(separator: ",").map(String.init)
        let ext = containers.first(where: { PlayerRouter.appleContainers.contains($0) }) ?? "mp4"
        if comps.path.hasSuffix("/stream") { comps.path += ".\(ext)" }
        return comps.url ?? base
    }

    /// Selects the audio and subtitle your Jellyfin settings pick (the server's defaults for
    /// this file, or what you chose on the item page), exactly like the mpv player does.
    private func applyServerDefaultTracks(_ playerItem: AVPlayerItem, source: MediaSourceInfo) async {
        let asset = playerItem.asset
        let streams = source.mediaStreams ?? []
        if let group = try? await asset.loadMediaSelectionGroup(for: .legible) {
            let subIndex = request.subtitleIndex ?? source.defaultSubtitleStreamIndex ?? -1
            if subIndex < 0 {
                playerItem.select(nil, in: group)
            } else if let stream = streams.first(where: { $0.index == subIndex }) {
                let options = group.options.filter { !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles) }
                let match = options.first { Self.sameLanguage($0, stream.language) && (stream.title == nil || $0.displayName == stream.title) }
                    ?? options.first { Self.sameLanguage($0, stream.language) }
                    ?? (options.count == 1 ? options.first : nil)
                if let match { playerItem.select(match, in: group) }
            }
        }
        let audioIndex = request.audioIndex ?? source.defaultAudioStreamIndex
        if let group = try? await asset.loadMediaSelectionGroup(for: .audible), group.options.count > 1,
           let stream = streams.first(where: { $0.index == audioIndex }),
           let match = group.options.first(where: { Self.sameLanguage($0, stream.language) }) {
            playerItem.select(match, in: group)
        }
    }

    private static func sameLanguage(_ option: AVMediaSelectionOption, _ language: String?) -> Bool {
        guard let language = language?.lowercased(), !language.isEmpty else { return false }
        let tag = (option.extendedLanguageTag ?? option.locale?.identifier ?? "").lowercased()
        if tag.isEmpty { return false }
        let base = String(tag.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "")
        if base == language || tag == language { return true }
        // Jellyfin uses ISO 639-2 (eng, jpn); Apple uses BCP-47 (en, ja).
        let two = Locale.Language(identifier: language).languageCode?.identifier(.alpha2) ?? language
        return base == two.lowercased()
    }

    private func metadata(for item: BaseItem) -> [AVMetadataItem] {
        func meta(_ id: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
            let m = AVMutableMetadataItem()
            m.identifier = id
            m.value = value as NSString
            m.extendedLanguageTag = "und"
            return m
        }
        let title = item.kind == .episode ? (item.seriesName ?? item.displayName) : item.displayName
        var list = [meta(.commonIdentifierTitle, title)]
        if item.kind == .episode {
            let sub = [item.episodeLabel, item.name].compactMap { $0 }.joined(separator: " · ")
            list.append(meta(.iTunesMetadataTrackSubTitle, sub))
        }
        if !item.plainOverview.isEmpty { list.append(meta(.commonIdentifierDescription, item.plainOverview)) }
        return list
    }

    // MARK: Observers

    private func installObservers() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        rateObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self, !self.finished else { return }
                await self.client.reportProgress(self.report())
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            let ended = note.object as? AVPlayerItem
            MainActor.assumeIsolated {
                guard let self, ended === self.player.currentItem else { return }
                if self.model.settings.autoPlayNext, !self.queue.isEmpty {
                    Task { await self.playNext() }
                } else {
                    self.controller.dismiss(animated: true)
                }
            }
        }
    }

    private func observe(_ playerItem: AVPlayerItem) {
        itemObservation = playerItem.observe(\.status, options: [.new]) { [weak self] obj, _ in
            let failed = obj.status == .failed
            let message = obj.error?.localizedDescription
            Task { @MainActor in
                guard let self, failed, obj === self.player.currentItem, !self.startedPlaying else { return }
                // Apple's player couldn't open it: mpv plays it instead, from the same point.
                self.handOffToMPV(reason: message ?? "failed")
            }
        }
    }

    private func tick() {
        let now = player.currentTime().seconds
        guard now.isFinite, !finished else { return }
        if player.timeControlStatus == .playing { startedPlaying = true }
        if Date().timeIntervalSince(lastReport) >= 10 {
            lastReport = Date()
            Task { await client.reportProgress(report()) }
        }
        // Apple's own contextual buttons for Skip Intro / Credits and Next Episode.
        var actions: [UIAction] = []
        let skippable = ["Intro", "Recap", "Outro", "Preview", "Commercial"]
        if let seg = segments.first(where: { skippable.contains($0.type) && now >= Fmt.seconds($0.startTicks)
            && now < Fmt.seconds($0.endTicks) - 1 }), !skipped.contains(seg.id) {
            let s = model.settings
            let auto = (seg.type == "Intro" && s.autoSkipIntro) || (seg.type == "Recap" && s.autoSkipRecap)
                || (seg.type == "Outro" && s.autoSkipOutro)
            if auto {
                skip(seg)
            } else if s.showSkipButtons {
                let title: String
                switch seg.type {
                case "Outro": title = queue.isEmpty ? "Skip Credits" : "Next Episode"
                case "Commercial": title = "Skip Ad"
                default: title = "Skip \(seg.type)"
                }
                actions.append(UIAction(title: title, image: UIImage(systemName: "forward.fill")) { [weak self] _ in self?.skip(seg) })
            }
        }
        if actions.isEmpty, !queue.isEmpty, let duration = player.currentItem?.duration.seconds, duration.isFinite,
           duration - now < Double(max(model.settings.nextUpCountdown, 10)) + 5 {
            actions.append(UIAction(title: "Next Episode", image: UIImage(systemName: "forward.end.fill")) { [weak self] _ in
                Task { await self?.playNext() }
            })
        }
        if controller.contextualActions.map(\.title) != actions.map(\.title) {
            controller.contextualActions = actions
        }
    }

    private func skip(_ seg: MediaSegment) {
        skipped.insert(seg.id)
        if seg.type == "Outro" && !queue.isEmpty {
            Task { await playNext() }
            return
        }
        player.seek(to: CMTime(seconds: Fmt.seconds(seg.endTicks), preferredTimescale: 600))
    }

    private func playNext() async {
        guard let next = queue.first, !finished else { return }
        await client.reportStopped(report())
        if !isDirect, let ps = playSessionId { await client.stopEncoding(playSessionId: ps) }
        queue.removeFirst()
        request = PlaybackRequest(item: next, startSeconds: 0, queue: queue)
        let full = (try? await client.item(next.id)) ?? next
        let sources = full.mediaSources ?? []
        if let src = sources.first, case .apple(let direct) = PlayerRouter.route(for: src, item: full),
           let info = try? await client.playbackInfo(itemId: full.id, Self.infoRequest(
               client: client, direct: direct, mediaSourceId: src.id, audio: nil, subtitle: nil)),
           let served = (info.mediaSources ?? []).first(where: { $0.id == src.id }) ?? info.mediaSources?.first,
           Self.isLossless(served, direct: direct) {
            load(full, info: info, source: served, direct: direct, start: 0)
        } else {
            // The next episode is a file Apple's player can't do: mpv continues.
            item = full
            handOffToMPV(reason: nil, startOverride: 0, reportStop: false)
        }
    }

    private func handOffToMPV(reason: String?, startOverride: Double? = nil, reportStop: Bool? = nil) {
        guard !finished else { return }
        let pos = player.currentTime().seconds
        let start = startOverride ?? (pos.isFinite && pos > 1 ? pos : (resumeAt > 1 ? resumeAt : request.startSeconds))
        let next = PlaybackRequest(item: item, startSeconds: start, mediaSourceId: nil,
                                   audioIndex: request.audioIndex, subtitleIndex: request.subtitleIndex, queue: queue)
        let model = self.model
        let controller = self.controller
        Task {
            await finish(reportStop: reportStop ?? startedPlaying)
            if controller.presentingViewController != nil {
                controller.dismiss(animated: false) {
                    MainActor.assumeIsolated { model.playback = next }
                }
            } else {
                model.playback = next
            }
        }
    }

    private func report() -> JellyfinClient.PlaybackReport {
        let pos = player.currentTime().seconds
        return JellyfinClient.PlaybackReport(
            itemId: item.id,
            mediaSourceId: source?.id,
            playSessionId: playSessionId,
            positionTicks: pos.isFinite ? Fmt.ticks(max(0, pos)) : nil,
            isPaused: player.timeControlStatus == .paused,
            isMuted: player.isMuted,
            playMethod: isDirect ? "DirectPlay" : "DirectStream",
            canSeek: true,
            playbackRate: Double(player.rate == 0 ? player.defaultRate : player.rate)
        )
    }

    private func finish(reportStop: Bool = true) async {
        guard !finished else { return }
        finished = true
        controller.onClose = nil
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        itemObservation = nil
        rateObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        controller.contextualActions = []
        let final = report()
        player.pause()
        if reportStop { await client.reportStopped(final) }
        if !isDirect, let ps = playSessionId { await client.stopEncoding(playSessionId: ps) }
        player.replaceCurrentItem(with: nil)
        model.playbackEnded(itemIds: playedIds)
        if Self.current === self { Self.current = nil }
    }

    // Picture in Picture keeps playing after the player is closed; the session ends when PiP does.
    nonisolated func playerViewControllerShouldAutomaticallyDismissAtPictureInPictureStart(_ playerViewController: AVPlayerViewController) -> Bool { false }
}

/// Apple's AVPlayerViewController, telling us when you close it (its X button or a swipe down).
final class JellyRecoAVPlayerViewController: AVPlayerViewController {
    var onClose: (() -> Void)?
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil {
            let close = onClose
            onClose = nil
            close?()
        }
    }
}
