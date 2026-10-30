import Foundation

/// What JellyReco tells the server it can play.
///
/// Direct play is the rule: the profile accepts every container, codec and subtitle format
/// (empty lists mean "any" to Jellyfin), so the server always hands over the original file.
/// The transcoding profile is only used for the last-resort fallback, when a file failed on
/// the iPhone and the user allows server conversion.
struct DeviceProfile: Encodable {
    var name = "JellyReco (mpv)"
    var maxStreamingBitrate = 400_000_000
    var maxStaticBitrate = 400_000_000
    var musicStreamingTranscodingBitrate = 384_000
    var directPlayProfiles: [DirectPlayProfile]
    var transcodingProfiles: [TranscodingProfile]
    var containerProfiles: [String] = []
    var codecProfiles: [String] = []
    var subtitleProfiles: [SubtitleProfile]

    struct DirectPlayProfile: Encodable {
        var container: String = ""
        var type: String
        var videoCodec: String?
        var audioCodec: String?
    }

    struct TranscodingProfile: Encodable {
        var container: String
        var type: String
        var videoCodec: String
        var audioCodec: String
        var `protocol`: String
        var context = "Streaming"
        var maxAudioChannels = "8"
        var minSegments = 1
        var breakOnNonKeyFrames = true
        var enableSubtitlesInManifest = false
        var copyTimestamps = false
    }

    struct SubtitleProfile: Encodable {
        var format: String
        var method: String     // Embed, External, Encode, Hls
    }

    static let subtitleFormats = [
        "ass", "ssa", "srt", "subrip", "vtt", "webvtt", "pgs", "pgssub", "sup", "dvdsub", "vobsub", "sub", "idx",
        "dvbsub", "dvb_subtitle", "mov_text", "tx3g", "ttml", "smi", "microdvd", "mpl2", "eia_608", "cc_dec", "xsub",
    ]

    /// Everything direct, nothing converted.
    static let directPlay = DeviceProfile(
        directPlayProfiles: [
            DirectPlayProfile(type: "Video"),
            DirectPlayProfile(type: "Audio"),
        ],
        transcodingProfiles: [],
        subtitleProfiles: subtitleFormats.flatMap {
            [SubtitleProfile(format: $0, method: "Embed"), SubtitleProfile(format: $0, method: "External")]
        }
    )

    /// Last resort: the server converts to HEVC/H.264 in HLS; subtitles stay as separate files
    /// mpv renders (burned in only when the server must, e.g. bitmap subtitles while converting).
    static func fallback(hevc: Bool) -> DeviceProfile {
        DeviceProfile(
            name: "JellyReco (fallback)",
            directPlayProfiles: [],
            transcodingProfiles: [
                TranscodingProfile(container: "ts", type: "Video",
                                   videoCodec: hevc ? "hevc,h264" : "h264",
                                   audioCodec: "aac,ac3,eac3,mp3,flac,opus", protocol: "hls"),
                TranscodingProfile(container: "mp3", type: "Audio", videoCodec: "", audioCodec: "mp3", protocol: "http"),
            ],
            subtitleProfiles: subtitleFormats.map { SubtitleProfile(format: $0, method: "External") }
                + [SubtitleProfile(format: "pgssub", method: "Encode"), SubtitleProfile(format: "dvdsub", method: "Encode")]
        )
    }
}
