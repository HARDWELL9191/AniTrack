import SwiftUI
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
            if mode == "subrender" {
                SubtitleRenderHost(settings: model.settings)
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
                let n = r.range(of: #"brightpx:(\d+)"#, options: .regularExpression).map { Int(r[$0].dropFirst(9)) ?? -1 } ?? -1
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

    /// Bright pixels in the frame the native layer displays ("brightpx:N"), or why there's none.
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
