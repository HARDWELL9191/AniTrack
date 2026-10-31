import SwiftUI

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
            if ready, mode == "transcoding" {
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
