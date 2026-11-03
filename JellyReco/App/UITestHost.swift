import SwiftUI
import CoreText
import MPVUI
import AVFoundation

/// Only used by the UI tests (launched with JELLYRECO_UITEST set): the real For You screen
/// without a Jellyfin server, so the TMDB key flow can be reproduced in the simulator.
/// "foryou" = the app as shipped; "foryou-unattached" = the old bug (engine not connected).
struct UITestHost: View {
    @Environment(AppModel.self) private var model
    let mode: String
    @State private var ready = false

    /// A Jellyfin 10.11 encoding configuration as the server returns it (Quick Sync chosen).
    static let encodingJSON = """
    {"EncodingThreadCount":-1,"FallbackFontPath":"","EnableFallbackFont":false,"EnableAudioVbr":false,"DownMixAudioBoost":2,
     "DownMixStereoAlgorithm":"None","MaxMuxingQueueSize":2048,"EnableThrottling":false,"ThrottleDelaySeconds":180,
     "EnableSegmentDeletion":false,"SegmentKeepSeconds":720,"HardwareAccelerationType":"qsv",
     "EncoderAppPathDisplay":"/usr/lib/jellyfin-ffmpeg/ffmpeg","VaapiDevice":"/dev/dri/renderD128","QsvDevice":"",
     "EnableTonemapping":false,"EnableVppTonemapping":false,"EnableVideoToolboxTonemapping":false,"TonemappingAlgorithm":"bt2390",
     "TonemappingMode":"auto","TonemappingRange":"auto","TonemappingDesat":0,"TonemappingPeak":100,"TonemappingParam":0,
     "VppTonemappingBrightness":16,"VppTonemappingContrast":1,"H264Crf":23,"H265Crf":28,"EncoderPreset":"auto",
     "DeinterlaceDoubleRate":false,"DeinterlaceMethod":"yadif","EnableDecodingColorDepth10Hevc":true,
     "EnableDecodingColorDepth10Vp9":true,"EnableDecodingColorDepth10HevcRext":false,"EnableDecodingColorDepth12HevcRext":false,
     "EnableEnhancedNvdecDecoder":true,"PreferSystemNativeHwDecoder":true,"EnableIntelLowPowerH264HwEncoder":false,
     "EnableIntelLowPowerHevcHwEncoder":false,"EnableHardwareEncoding":true,"AllowHevcEncoding":false,"AllowAv1Encoding":false,
     "EnableSubtitleExtraction":true,"HardwareDecodingCodecs":["h264","hevc","mpeg2video","vc1","vp9","av1"],
     "HlsAudioSeekStrategy":"TranscodeAudio"}
    """

    static let episodeJSON = """
    {"Id":"e1","Name":"Romio and Hasuki","Type":"Episode","SeriesName":"Boarding School Juliet","IndexNumber":4,"ParentIndexNumber":1,"OfficialRating":"TV-14"}
    """

    var body: some View {
        ZStack {
            Color.clear
            if mode == "audioswitch" {
                AudioSwitchHost(settings: model.settings)
            } else if mode == "subrender" {
                SubtitleRenderHost(settings: model.settings)
            } else if mode == "fonttest" {
                FontFallbackHost(settings: model.settings)
            } else if ready, mode == "transcoding" {
                NavigationStack {
                    ConfigPageView(page: ServerSettingsCatalog.transcoding, preview: [
                        .encoding: (try? JSONSerialization.jsonObject(with: Data(Self.encodingJSON.utf8)) as? [String: Any]) ?? [:],
                    ])
                }
            } else if ready, mode == "dashboard" {
                NavigationStack { AdminDashboardView() }
            } else if ready, mode == "settings" {
                SettingsView()
            } else if ready, mode == "start" {
                SignInFlow()
            } else if ready, mode == "longpress" {
                // Your Next Up card: text starting at the card's left edge, where the lifted
                // preview's rounded corner cut the "S".
                ScrollView {
                    HStack(spacing: 14) {
                        if let item = try? JSONCoding.decoder.decode(BaseItem.self, from: Data(Self.episodeJSON.utf8)) {
                            LandscapeCard(item: item, width: 280)
                            PosterCard(item: item, width: 112)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 120)
                }
            } else if ready {
                ForYouView()
                    .overlay(alignment: .bottom) {
                        Text(model.discovery.hasKey ? "STATE: For You sees the key" : "STATE: For You sees no key")
                            .font(.caption).accessibilityIdentifier("tmdb-state").padding(.bottom, 90)
                    }
            }
        }
        .onAppear {
            model.settings.tmdbKey = ""
            #if DEBUG
            if mode == "foryou-unattached" { model.discovery.detachForTesting() }
            #endif
            ready = true
        }
    }
}


/// UI test only: plays a test file (black picture, one white picture-subtitle caption from 0.5 s
/// to 5 s) with the app's own player configuration on the chosen renderer, selects the subtitle
/// and pauses inside the caption, so the test can count the caption's pixels on screen.
@MainActor private final class LogBox {
    var lines: [String] = []
}

private struct SubtitleRenderHost: View {
    let settings: AppSettings
    @State private var player: MPVPlayer?
    @State private var status = "starting"

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player { MPVVideoPlayer(player: player).ignoresSafeArea() }
            VStack {
                Text(status).font(.system(size: 9)).foregroundStyle(Color(white: 0.35))
                    .accessibilityIdentifier("subrender-state")
                Spacer()
            }
        }
        .task { await run() }
    }

    private func run() async {
        let env = ProcessInfo.processInfo.environment
        guard let s = env["JELLYRECO_SAMPLE"], let url = URL(string: s) else { status = "FAIL no sample"; return }
        let output: MPVPlayerConfiguration.VideoOutput = env["JELLYRECO_OUTPUT"] == "metal" ? .metal : .sampleBuffer
        let p = MPVPlayer(configuration: PlaybackController.configuration(settings: settings, output: output))
        player = p
        let log = LogBox()
        p.logHandler = { msg in
            log.lines.append("[\(msg.prefix)] \(msg.message.trimmingCharacters(in: .whitespacesAndNewlines))")
            if log.lines.count > 12 { log.lines.removeFirst() }
        }
        p.load(url, playAutomatically: true, startTime: nil)
        for _ in 0..<150 where p.subtitleTracks.isEmpty || p.duration <= .zero {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let sub = p.subtitleTracks.first else { status = "FAIL no subtitle track (\(p.state))"; return }
        p.selectSubtitle(sub.id)
        try? await Task.sleep(for: .milliseconds(300))
        // Like a viewer turning subtitles on and then skipping: a seek makes the player read the
        // subtitle packets again even if playback was already past them when it was selected.
        p.seek(to: .seconds(0.2))   // before the caption's packets (0.5 s), whatever the keyframe spacing
        let native = p.videoFeatureCapabilities.nativeSubtitles
        var frame = ""
        if output == .metal {
            try? await Task.sleep(for: .milliseconds(1500))
        } else {
            // While it plays through the caption (0.5–5 s), read back the frames the native layer
            // shows (the simulator's screenshots leave that layer out) and keep the brightest.
            var best = -1, sample = "none", seen: [Int] = []
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(100))
                let r = Self.displayedFramePixels()
                // Video layer and subtitle layer: the caption is on whichever draws it.
                let n = r.matches(of: #/brightpx:(\d+)/#).compactMap { Int($0.output.1) }.max() ?? -1
                seen.append(n)
                if n > best { best = n; sample = r }
                if best == -1 { sample = r }
            }
            frame = " frame=\(sample) best=brightpx:\(best) all=\(seen.map(String.init).joined(separator: "/"))"
        }
        p.pause()
        status = "READY output=\(output == .metal ? "metal" : "native") codec=\(sub.codec ?? "?") "
            + "nativeSubtitles=\(native.availability.rawValue) at=\(p.position)\(frame) log=\(log.lines.joined(separator: " || "))"
    }

    /// Bright pixels in the frames the native layers display ("brightpx:N" per layer: the video,
    /// then the subtitle layer above it), or why there's none.
    static func displayedFramePixels() -> String {
        var layers: [AVSampleBufferDisplayLayer] = []
        func walk(_ l: CALayer) {
            if let d = l as? AVSampleBufferDisplayLayer { layers.append(d) }
            l.sublayers?.forEach(walk)
        }
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows { walk(window.layer) }
        }
        guard !layers.isEmpty else { return "nolayer" }
        var results: [String] = []
        for layer in layers {
            guard let pb = layer.sampleBufferRenderer.displayedPixelBuffer() else { results.append("noframe"); continue }
            results.append(brightPixels(pb))
        }
        return results.joined(separator: ",")
    }

    private static func brightPixels(_ pb: CVPixelBuffer) -> String {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let format = CVPixelBufferGetPixelFormatType(pb)
        let fourCC = String(bytes: [24, 16, 8, 0].map { UInt8((format >> $0) & 0xFF) }, encoding: .ascii) ?? "\(format)"
        var count = 0
        if CVPixelBufferIsPlanar(pb) {
            // Luma plane: 8-bit (420v/420f) or 16-bit containers for 10-bit (x420…, value in the high bits).
            guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return "nobase(\(fourCC))" }
            let w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0)
            let row = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
            let wide = row >= w * 2
            for y in 0..<h {
                let line = base.advanced(by: y * row)
                for x in 0..<w {
                    let v: Int = wide ? Int(line.load(fromByteOffset: x * 2, as: UInt16.self) >> 8)
                                      : Int(line.load(fromByteOffset: x, as: UInt8.self))
                    if v > 150 { count += 1 }
                }
            }
            return "brightpx:\(count)(\(fourCC) \(w)x\(h))"
        }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return "nobase(\(fourCC))" }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), row = CVPixelBufferGetBytesPerRow(pb)
        let bpp = row / max(w, 1)
        guard bpp == 4 else { return "unsupported(\(fourCC) bpp=\(bpp))" }
        for y in 0..<h {
            let line = base.advanced(by: y * row)
            for x in 0..<w {
                let px = line.advanced(by: x * 4).assumingMemoryBound(to: UInt8.self)
                if max(px[0], px[1], px[2]) > 150 { count += 1 }
            }
        }
        return "brightpx:\(count)(\(fourCC) \(w)x\(h))"
    }
}


/// UI test only: plays a video with a subtitle holding characters anime and film subtitles use
/// (tildes, music notes, Japanese/Korean/Chinese, other scripts, emoji) with the app's own
/// player configuration, and reports libass's font choices for each missing glyph.
private struct FontFallbackHost: View {
    let settings: AppSettings
    @State private var player: MPVPlayer?
    @State private var status = "starting"

    static let sample = """
    Whaoo～huahehu〜 ~ … — “quotes” × ° ½
    ♪ ♫ ♬ ♥ ♡ ★ ☆ ● ■ ▲ ◆ → ⇒ ※ ・ ‼ ⁉ ① Ⅰ ∞ ≒ ∼ ❤ ✓
    「こんにちは」『カタカナ』漢字ー 们这说 한국어
    Ωπ Жизнь čšžćđ ạễ שלום مرحبا สวัสดี नमस्ते 😊
    """

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player { MPVVideoPlayer(player: player).ignoresSafeArea() }
            VStack {
                Text(status).font(.system(size: 6)).foregroundStyle(Color(white: 0.35))
                    .accessibilityIdentifier("fonttest-state")
                Spacer()
            }
        }
        .task { await run() }
    }

    private func run() async {
        let env = ProcessInfo.processInfo.environment
        guard let s = env["JELLYRECO_SAMPLE"], let url = URL(string: s) else { status = "FAIL no sample"; return }
        let srt = FileManager.default.temporaryDirectory.appendingPathComponent("fonttest.srt")
        try? "1\n00:00:00,000 --> 00:00:30,000\n\(Self.sample)\n".write(to: srt, atomically: true, encoding: .utf8)
        let p = MPVPlayer(configuration: PlaybackController.configuration(settings: settings, output: .sampleBuffer, logLevel: .verbose))
        player = p
        let log = LogBox()
        p.logHandler = { msg in
            let m = msg.message.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = (msg.prefix + " " + m).lowercased()
            if lower.contains("ass") || lower.contains("font") || lower.contains("glyph") {
                if log.lines.count < 150 { log.lines.append("[\(msg.prefix)] \(m)") }
            }
        }
        p.load(url, playAutomatically: true, startTime: nil)
        for _ in 0..<150 where p.duration <= .zero { try? await Task.sleep(for: .milliseconds(100)) }
        p.loadExternalSubtitle(srt, selecting: .primary)
        try? await Task.sleep(for: .seconds(15))
        p.pause()
        // What Core Text itself picks for each character (the font libass is told to look for).
        let base = CTFontCreateWithName("HelveticaNeue" as CFString, 24, nil)
        var ct: [String] = []
        for ch in ["～", "〜", "♪", "♥", "★", "→", "※", "①", "「", "あ", "漢", "们", "한", "Ж", "ạ", "ש", "م", "ส", "न", "😊", "‼", "❤"] {
            let str = ch as CFString
            let f = CTFontCreateForString(base, str, CFRange(location: 0, length: CFStringGetLength(str)))
            let fam = CTFontCopyFamilyName(f) as String
            let ps = CTFontCopyPostScriptName(f) as String
            let url = CTFontCopyAttribute(f, kCTFontURLAttribute) as? URL
            let readable = url.map { FileManager.default.isReadableFile(atPath: $0.path) } ?? false
            let size = url.flatMap { (try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? NSNumber)?.intValue } ?? -1
            ct.append("CT \(ch) -> \(fam) / \(ps) / \(url?.path ?? "no url") readable=\(readable) size=\(size)")
        }
        status = "READY " + ct.joined(separator: " || ") + " || fonts=\(SubtitleFonts.prepare().map { "\($0.family) @ \((try? FileManager.default.contentsOfDirectory(atPath: $0.directory))?.joined(separator: ",") ?? "")" } ?? "none") || "
            + log.lines.joined(separator: " || ")
    }
}


/// UI test only: plays a file with six audio tracks (AAC, E-AC-3, AC-3, TrueHD, FLAC, Opus) with
/// the app's own player configuration and switches between them in the patterns people use
/// (to a track and back, quickly twice, while paused), recording after each switch what mpv
/// reports: the selected track, the audio output, its format, the clock, and every audio message.
private struct AudioSwitchHost: View {
    let settings: AppSettings
    @State private var player: MPVPlayer?
    @State private var status = "starting"

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player { MPVVideoPlayer(player: player).ignoresSafeArea() }
            VStack {
                Text(status).font(.system(size: 6)).foregroundStyle(Color(white: 0.35))
                    .accessibilityIdentifier("audioswitch-state")
                Spacer()
            }
        }
        .task { await run() }
    }

    private func run() async {
        let env = ProcessInfo.processInfo.environment
        guard let s = env["JELLYRECO_SAMPLE"], let url = URL(string: s) else { status = "FAIL no sample"; return }
        let p = MPVPlayer(configuration: PlaybackController.configuration(settings: settings, output: .sampleBuffer, logLevel: .verbose))
        p.setDiagnosticsEnabled(true)
        player = p
        let log = LogBox()
        let start = Date()
        p.logHandler = { msg in
            let text = msg.message.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = text.lowercased()
            // Everything about audio, plus every warning or error.
            // The lines that tell what happened to audio (not the track list or decoder probing).
            let keys = ["delaying audio", "ao:", "audio ready", "starting audio", "refresh track", "restart", "reinit",
                        "spdif", "underrun", "no audio", "no sound", "falling back", "stalled", "eof", "seek", "resync",
                        "audio_status", "audio=", "avplayer", "renderer", "format", "pts"]
            let serious = msg.level == .error || msg.level == .warning || msg.level == .fatal
            let wanted = msg.prefix.hasPrefix("ao") || keys.contains(where: { lower.contains($0) })
            guard (wanted || serious), !lower.contains("--aid="), !lower.contains("codec list") else { return }
            if let last = log.lines.last, last.hasSuffix(text), text.hasPrefix("delaying audio") { return }
            log.lines.append(String(format: "%.1f", Date().timeIntervalSince(start)) + " [\(msg.prefix)] \(text)")
        }
        p.load(url, playAutomatically: true, startTime: nil)
        for _ in 0..<150 where p.audioTracks.count < 6 || p.duration <= .zero {
            try? await Task.sleep(for: .milliseconds(100))
        }
        let tracks = p.audioTracks
        guard tracks.count >= 2 else { status = "FAIL tracks=\(tracks.count) state=\(p.state)"; return }
        try? await Task.sleep(for: .seconds(2))

        var report: [String] = []
        func snapshot(_ label: String) {
            let d = p.playbackDiagnostics.audio
            let sel = p.audioTracks.first(where: \.isSelected).map { "\($0.mpvID)" } ?? "none"
            let lines = log.lines
            log.lines = []
            report.append("\(label): aid=\(sel) ao=\(d.output ?? "-") codec=\(d.codec ?? "-") out=\(d.outputFormat ?? "-")/\(d.outputChannels ?? "-") native=\(d.nativePath ?? "-") state=\(p.state) pos=\(String(format: "%.1f", Double(p.position.components.seconds) + Double(p.position.components.attoseconds) / 1e18)) || " + lines.prefix(25).joined(separator: " | "))
        }
        func select(_ i: Int) { if i < tracks.count { p.selectTrack(tracks[i].id) } }
        snapshot("start")
        // Tracks: 1 AAC 2.0, 2 Opus 2.0, 3 Opus 5.1, 4 Opus 7.1, 5 FLAC 2.0, 6 E-AC-3 5.1.
        for i in 1..<tracks.count {
            select(i); try? await Task.sleep(for: .seconds(2.5)); snapshot("to \(i + 1)")
            select(0); try? await Task.sleep(for: .seconds(2.5)); snapshot("back to 1 from \(i + 1)")
        }
        // Between the Opus tracks and to the others.
        for (a, b) in [(1, 2), (2, 3), (3, 1), (1, 5), (5, 2), (2, 4), (4, 3)] where max(a, b) < tracks.count {
            select(a); try? await Task.sleep(for: .seconds(2.5)); snapshot("to \(a + 1)")
            select(b); try? await Task.sleep(for: .seconds(2.5)); snapshot("\(a + 1)>\(b + 1)")
        }
        for (a, b) in [(1, 2), (2, 0), (3, 1)] where max(a, b) < tracks.count {
            select(a); try? await Task.sleep(for: .milliseconds(150)); select(b)
            try? await Task.sleep(for: .seconds(2.5)); snapshot("quick \(a + 1)>\(b + 1)")
        }
        p.pause(); try? await Task.sleep(for: .seconds(1))
        select(2); try? await Task.sleep(for: .seconds(1)); select(1); try? await Task.sleep(for: .seconds(1))
        p.play(); try? await Task.sleep(for: .seconds(2.5)); snapshot("paused 3>2 then play")
        p.pause()
        status = "READY " + report.joined(separator: " ## ")
    }
}
