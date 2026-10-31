// The Dashboard's settings pages, option for option as in jellyfin-web 10.11 (General, Branding,
// Display, Metadata, NFO settings, Transcoding, Resume, Streaming, Trickplay, Networking, DVR), in
// the same sections and order, with the same conditions (e.g. the QSV device only shows for Intel
// QSV, and the "hardware decoding for" list only has the codecs that acceleration type can decode).

import { useState } from "react";
import type { Country, Culture, User } from "../core/types";
import { Spinner, Toggle, useLoad } from "./components";
import { ConfigForm, type Ctx, type Draft, get, namedConfig, type Opt, type SectionDef, serverConfig, type Source } from "./configform";
import { Icon } from "./icons";
import { useModel } from "./state";

const has = (key: string) => (d: Draft) => get(d, key) !== undefined;
const opts = (...pairs: [Opt["value"], string][]): Opt[] => pairs.map(([value, label]) => ({ value, label }));

// MARK: Transcoding (jellyfin-web's features/playback/constants/codecs.ts)

const HW_TYPES = opts(["none", "None"], ["amf", "AMD AMF"], ["nvenc", "Nvidia NVENC"], ["qsv", "Intel Quicksync (QSV)"], ["vaapi", "Video Acceleration API (VAAPI)"],
  ["rkmpp", "Rockchip MPP (RKMPP)"], ["videotoolbox", "Apple VideoToolBox"], ["v4l2m2m", "Video4Linux2 (V4L2)"]);

const CODECS: { name: string; codec: string; types: string[] }[] = [
  { name: "H264", codec: "h264", types: ["amf", "nvenc", "qsv", "vaapi", "rkmpp", "videotoolbox", "v4l2m2m"] },
  { name: "HEVC", codec: "hevc", types: ["amf", "nvenc", "qsv", "vaapi", "rkmpp", "videotoolbox"] },
  { name: "MPEG1", codec: "mpeg1video", types: ["rkmpp"] },
  { name: "MPEG2", codec: "mpeg2video", types: ["amf", "nvenc", "qsv", "vaapi", "rkmpp"] },
  { name: "MPEG4", codec: "mpeg4", types: ["nvenc", "rkmpp"] },
  { name: "VC1", codec: "vc1", types: ["amf", "nvenc", "qsv", "vaapi"] },
  { name: "VP8", codec: "vp8", types: ["nvenc", "qsv", "vaapi", "rkmpp", "videotoolbox"] },
  { name: "VP9", codec: "vp9", types: ["amf", "nvenc", "qsv", "vaapi", "rkmpp", "videotoolbox"] },
  { name: "AV1", codec: "av1", types: ["amf", "nvenc", "qsv", "vaapi", "rkmpp", "videotoolbox"] },
];
const HEVC_VP9_10BIT = ["amf", "nvenc", "qsv", "vaapi", "rkmpp"];
const HEVC_REXT = ["nvenc", "qsv", "vaapi"];
const HWA = ["amf", "nvenc", "qsv", "vaapi", "rkmpp", "videotoolbox"];

/** Older servers saved "" for no acceleration. */
const hw = (d: Draft) => (get(d, "encoding.HardwareAccelerationType") as string) || "none";
const hwIs = (...t: string[]) => (d: Draft) => t.includes(hw(d));
const hwOn = (d: Draft) => hw(d) !== "none";
const hwa = (d: Draft) => HWA.includes(hw(d));

const TRANSCODING: SectionDef[] = [
  {
    title: "Hardware acceleration",
    fields: [
      { kind: "note", warn: true, text: "Enabling hardware acceleration may cause instability in some environments. Make sure the server's operating system and video drivers are fully up to date. If video doesn't play after enabling this, change it back to None." },
      { kind: "select", key: "encoding.HardwareAccelerationType", label: "Hardware acceleration", help: "Hardware acceleration requires additional configuration on the server (see jellyfin.org/docs → Hardware Acceleration).", options: HW_TYPES, normalize: (v) => v || "none" },
      { kind: "text", key: "encoding.VaapiDevice", label: "VA-API device", help: "The render node used for hardware acceleration, e.g. /dev/dri/renderD128.", show: hwIs("vaapi") },
      { kind: "text", key: "encoding.QsvDevice", label: "QSV device", help: "The device for Intel QSV on a multi-GPU system. On Linux, the render node (e.g. /dev/dri/renderD128); on Windows, the device index starting from 0. Leave blank unless you know what you're doing.", show: hwIs("qsv") },
    ],
  },
  {
    title: "Enable hardware decoding for",
    show: hwOn,
    fields: [
      {
        kind: "switches", key: "encoding.HardwareDecodingCodecs",
        options: (d) => [
          ...CODECS.filter((c) => c.types.includes(hw(d))).map((c) => ({ value: c.codec, label: c.name })),
          { value: null, label: "HEVC 10bit", flag: "encoding.EnableDecodingColorDepth10Hevc", show: (x) => HEVC_VP9_10BIT.includes(hw(x)) },
          { value: null, label: "VP9 10bit", flag: "encoding.EnableDecodingColorDepth10Vp9", show: (x) => HEVC_VP9_10BIT.includes(hw(x)) },
          { value: null, label: "HEVC RExt 8/10bit", flag: "encoding.EnableDecodingColorDepth10HevcRext", show: (x) => HEVC_REXT.includes(hw(x)) && has("encoding.EnableDecodingColorDepth10HevcRext")(x) },
          { value: null, label: "HEVC RExt 12bit", flag: "encoding.EnableDecodingColorDepth12HevcRext", show: (x) => HEVC_REXT.includes(hw(x)) && has("encoding.EnableDecodingColorDepth12HevcRext")(x) },
        ],
      },
      { kind: "toggle", key: "encoding.EnableEnhancedNvdecDecoder", label: "Enable enhanced NVDEC decoder", help: "Turn this off to use CUVID if you get decoding errors.", show: hwIs("nvenc") },
      { kind: "toggle", key: "encoding.PreferSystemNativeHwDecoder", label: "Prefer OS native DXVA or VA-API hardware decoders", show: hwIs("qsv") },
    ],
  },
  {
    title: "Hardware encoding options",
    show: hwOn,
    fields: [
      { kind: "toggle", key: "encoding.EnableHardwareEncoding", label: "Enable hardware encoding" },
      { kind: "toggle", key: "encoding.EnableIntelLowPowerH264HwEncoder", label: "Enable Intel Low-Power H.264 hardware encoder", show: hwIs("qsv", "vaapi") },
      { kind: "toggle", key: "encoding.EnableIntelLowPowerHevcHwEncoder", label: "Enable Intel Low-Power HEVC hardware encoder", help: "Low-power encoding avoids unnecessary CPU-GPU sync. On Linux, turn these off if the i915 HuC firmware isn't configured.", show: hwIs("qsv", "vaapi") },
    ],
  },
  {
    title: "Encoding format options",
    help: "The video formats Jellyfin may transcode to. It uses software encoding when hardware acceleration for a format isn't available. H.264 is always allowed.",
    fields: [
      { kind: "toggle", key: "encoding.AllowHevcEncoding", label: "Allow encoding in HEVC format" },
      { kind: "toggle", key: "encoding.AllowAv1Encoding", label: "Allow encoding in AV1 format", show: has("encoding.AllowAv1Encoding") },
    ],
  },
  {
    title: "VPP tone mapping",
    show: hwIs("qsv", "vaapi"),
    fields: [
      { kind: "toggle", key: "encoding.EnableVppTonemapping", label: "Enable VPP tone mapping", help: "Intel driver tone mapping. Works only on certain hardware with HDR10 video; takes priority over the OpenCL tone mapping." },
      { kind: "number", key: "encoding.VppTonemappingBrightness", label: "VPP tone mapping brightness gain", help: "Recommended: 16.", min: 0, max: 100, step: 0.00001, integer: false },
      { kind: "number", key: "encoding.VppTonemappingContrast", label: "VPP tone mapping contrast gain", help: "Recommended: 1.", min: 1, max: 2, step: 0.00001, integer: false },
    ],
  },
  {
    title: "VideoToolbox tone mapping",
    show: hwIs("videotoolbox"),
    fields: [
      { kind: "toggle", key: "encoding.EnableVideoToolboxTonemapping", label: "Enable VideoToolbox tone mapping", help: "Works with HDR10, HDR10+ and HLG, not Dolby Vision profile 5. Takes priority over the Metal tone mapping." },
    ],
  },
  {
    title: "Tone mapping",
    show: (d) => hw(d) === "none" || hwa(d),
    fields: [
      { kind: "toggle", key: "encoding.EnableTonemapping", label: "Enable tone mapping", help: "Converts HDR video to SDR while keeping detail and color. Works with 10-bit HDR10, HLG and Dolby Vision, and needs the matching GPU compute runtime.", show: hwa },
      { kind: "select", key: "encoding.TonemappingAlgorithm", label: "Tone mapping algorithm", help: "If you're not sure, keep the default. Recommended: BT.2390.", options: opts(["none", "None"], ["clip", "Clip"], ["linear", "Linear"], ["gamma", "Gamma"], ["reinhard", "Reinhard"], ["hable", "Hable"], ["mobius", "Mobius"], ["bt2390", "BT.2390"]) },
      { kind: "select", key: "encoding.TonemappingMode", label: "Tone mapping mode", help: "If highlights look blown out, try RGB.", options: opts(["auto", "Auto"], ["max", "MAX"], ["rgb", "RGB"], ["lum", "LUM"], ["itp", "ITP"]), show: hwa },
      { kind: "select", key: "encoding.TonemappingRange", label: "Tone mapping range", help: "The output color range. Auto is the same as the input.", options: opts(["auto", "Auto"], ["tv", "TV"], ["pc", "PC"]) },
      { kind: "number", key: "encoding.TonemappingDesat", label: "Tone mapping desat", help: "Desaturates highlights brighter than this. Recommended: 0 (off).", min: 0, step: 0.00001, integer: false },
      { kind: "number", key: "encoding.TonemappingPeak", label: "Tone mapping peak", help: "Overrides the video's own peak value. Default: 100 (1000 nits).", min: 0, step: 0.00001, integer: false },
      { kind: "number", key: "encoding.TonemappingParam", label: "Tone mapping param", help: "Tunes the algorithm. Usually leave it blank.", min: 0, step: 0.00001, integer: false, nullable: true },
    ],
  },
  {
    title: "Transcoding",
    fields: [
      { kind: "select", key: "encoding.EncodingThreadCount", label: "Transcoding thread count", help: "The most threads a transcode may use. Fewer threads lower CPU use but may not keep up with playback.", options: [{ value: -1, label: "Auto" }, ...Array.from({ length: 16 }, (_, i) => ({ value: i + 1, label: String(i + 1) })), { value: 0, label: "Max" }] },
      { kind: "text", key: "encoding.EncoderAppPathDisplay", label: "FFmpeg path", help: "Set on the server (in its config or with --ffmpeg).", readOnly: true },
      { kind: "path", key: "encoding.TranscodingTempPath", label: "Transcode path", help: "Where transcoded files for clients go. Leave blank for the server default." },
      { kind: "path", key: "encoding.FallbackFontPath", label: "Fallback font folder", help: "Fonts some clients use to render subtitles." },
      { kind: "toggle", key: "encoding.EnableFallbackFont", label: "Enable fallback fonts", help: "Custom fonts that can fix wrongly rendered subtitles." },
      { kind: "toggle", key: "encoding.EnableAudioVbr", label: "Enable VBR audio encoding", help: "Better quality for the bitrate, but in rare cases can cause buffering or compatibility problems.", show: has("encoding.EnableAudioVbr") },
      { kind: "number", key: "encoding.DownMixAudioBoost", label: "Audio boost when downmixing", help: "1 keeps the original volume.", min: 0.5, max: 3, step: 0.1, integer: false },
      { kind: "select", key: "encoding.DownMixStereoAlgorithm", label: "Stereo downmix algorithm", help: "How multi-channel audio is mixed down to stereo.", options: opts(["None", "None"], ["Dave750", "Dave750"], ["NightmodeDialogue", "NightmodeDialogue"], ["Rfc7845", "RFC7845"], ["Ac4", "AC-4"]), show: has("encoding.DownMixStereoAlgorithm") },
      { kind: "select", key: "encoding.HlsAudioSeekStrategy", label: "Audio seek strategy", help: "How audio is handled when seeking in HLS streams.", options: opts(["TrimCopiedAudio", "TrimCopiedAudio"], ["TranscodeAudio", "TranscodeAudio"]), show: has("encoding.HlsAudioSeekStrategy") },
      { kind: "number", key: "encoding.MaxMuxingQueueSize", label: "Max muxing queue size", help: "Packets buffered while waiting for all streams to start. Raise it if FFmpeg logs \"Too many packets buffered for output stream\". Recommended: 2048.", min: 0 },
      { kind: "select", key: "encoding.EncoderPreset", label: "Encoding preset", help: "Faster improves performance, slower improves quality.", options: opts(["auto", "Auto"], ["veryslow", "veryslow"], ["slower", "slower"], ["slow", "slow"], ["medium", "medium"], ["fast", "fast"], ["faster", "faster"], ["veryfast", "veryfast"], ["superfast", "superfast"], ["ultrafast", "ultrafast"]), normalize: (v) => v || "auto" },
      { kind: "number", key: "encoding.H265Crf", label: "H.265 encoding CRF", min: 0, max: 51 },
      { kind: "number", key: "encoding.H264Crf", label: "H.264 encoding CRF", help: "Quality for the x264/x265 software encoders, 0–51: lower is better quality and bigger files. 18–28 is sensible; x264's default is 23, x265's 28. Hardware encoders don't use this.", min: 0, max: 51 },
      { kind: "select", key: "encoding.DeinterlaceMethod", label: "Deinterlacing method", help: "For software transcoding of interlaced video. With hardware deinterlacing available, that's used instead.", options: opts(["yadif", "Yet Another DeInterlacing Filter (YADIF)"], ["bwdif", "Bob Weaver DeInterlacing Filter (BWDIF)"]) },
      { kind: "toggle", key: "encoding.DeinterlaceDoubleRate", label: "Double the frame rate when deinterlacing", help: "\"Bob\" deinterlacing: full motion like interlaced video on a TV." },
      { kind: "toggle", key: "encoding.EnableSubtitleExtraction", label: "Allow subtitle extraction on the fly", help: "Embedded subtitles are extracted and sent as text to avoid transcoding video. Can stall playback while extracting on some systems; turn off to burn them in instead." },
      { kind: "toggle", key: "encoding.EnableThrottling", label: "Throttle transcodes", help: "Pause a transcode once it's far enough ahead of playback, to use fewer resources. Turn off if you get playback problems." },
      { kind: "toggle", key: "encoding.EnableSegmentDeletion", label: "Delete segments", help: "Delete old segments once the client has them, so the whole transcode isn't stored on disk. Turn off if you get playback problems." },
      { kind: "number", key: "encoding.ThrottleDelaySeconds", label: "Throttle after (seconds)", help: "Must be long enough for the client to keep a healthy buffer. Only with throttling on.", min: 10, max: 3600 },
      { kind: "number", key: "encoding.SegmentKeepSeconds", label: "Time to keep segments (seconds)", help: "How long segments are kept after the client downloads them. Only with segment deletion on.", min: 10, max: 3600 },
    ],
  },
];

// MARK: Pages

interface PageDef { sources: Source[]; sections: SectionDef[]; ctx?: (api: NonNullable<ReturnType<typeof useModel>["api"]>) => Promise<Ctx>; intro?: string }

const RESOLUTIONS = opts(["MatchSource", "Match source"], ["P2160", "2160p"], ["P1440", "1440p"], ["P1080", "1080p"], ["P720", "720p"], ["P480", "480p"], ["P360", "360p"], ["P240", "240p"], ["P144", "144p"]);

const cultureOpts = (_: Draft, c: Ctx) => [{ value: null, label: "Default" }, ...((c.cultures as Culture[]) ?? []).filter((x) => x.TwoLetterISOLanguageName).map((x) => ({ value: x.TwoLetterISOLanguageName!, label: x.DisplayName }))];
const countryOpts = (_: Draft, c: Ctx) => [{ value: null, label: "Default" }, ...((c.countries as Country[]) ?? []).filter((x) => x.TwoLetterISORegionName).map((x) => ({ value: x.TwoLetterISORegionName!, label: x.DisplayName }))];

const PAGES: Record<string, PageDef> = {
  general: {
    sources: [serverConfig],
    ctx: async (api) => ({ languages: await api.get("/Localization/Options").catch(() => []) }),
    sections: [
      {
        title: "Settings",
        fields: [
          { kind: "text", key: "server.ServerName", label: "Server name", help: "Identifies this server. Defaults to the server's hostname." },
          { kind: "select", key: "server.UICulture", label: "Preferred display language", help: "The language of the server's own pages and messages.", options: (_, c) => ((c.languages as { Name: string; Value: string }[]) ?? []).map((l) => ({ value: l.Value, label: l.Name })) },
        ],
      },
      {
        title: "Paths",
        fields: [
          { kind: "path", key: "server.CachePath", label: "Cache path", help: "Where cache files like images go. Leave blank for the server default." },
          { kind: "path", key: "server.MetadataPath", label: "Metadata path", help: "Where downloaded artwork and metadata go." },
        ],
      },
      {
        title: "Quick Connect",
        fields: [{ kind: "toggle", key: "server.QuickConnectAvailable", label: "Enable Quick Connect on this server", help: "Sign in on a new device with a code from one that's already signed in." }],
      },
      {
        title: "Performance",
        fields: [
          { kind: "number", key: "server.LibraryScanFanoutConcurrency", label: "Parallel library scan tasks limit", help: "The most tasks a library scan runs at once. 0 picks a limit from the CPU core count. Too high can cause problems with network drives.", min: 0 },
          { kind: "number", key: "server.ParallelImageEncodingLimit", label: "Parallel image encoding limit", help: "The most image encodings at once. 0 picks a limit from the CPU core count.", min: 0 },
        ],
      },
      {
        title: "More server options",
        help: "Options jellyfin-web doesn't show (they're normally only in the server's config file).",
        fields: [
          { kind: "number", key: "server.LibraryMetadataRefreshConcurrency", label: "Parallel metadata refreshes", help: "0 picks a limit from the CPU core count.", min: 0, show: has("server.LibraryMetadataRefreshConcurrency") },
          { kind: "number", key: "server.ActivityLogRetentionDays", label: "Keep activity for (days)", min: 0, nullable: true, placeholder: "Forever", show: has("server.ActivityLogRetentionDays") },
          { kind: "number", key: "server.LogFileRetentionDays", label: "Keep log files for (days)", min: 1, show: has("server.LogFileRetentionDays") },
          { kind: "toggle", key: "server.EnableMetrics", label: "Prometheus metrics", help: "Serve server metrics at /metrics.", show: has("server.EnableMetrics") },
          { kind: "toggle", key: "server.EnableSlowResponseWarning", label: "Log slow responses", show: has("server.EnableSlowResponseWarning") },
          { kind: "number", key: "server.SlowResponseThresholdMs", label: "Slow response threshold (ms)", min: 0, show: (d) => has("server.SlowResponseThresholdMs")(d) && !!get(d, "server.EnableSlowResponseWarning") },
          { kind: "number", key: "server.InactiveSessionThreshold", label: "Stop inactive sessions after (minutes)", help: "0 never stops them.", min: 0, show: has("server.InactiveSessionThreshold") },
          { kind: "toggle", key: "server.EnableLegacyAuthorization", label: "Accept old clients' authorization", help: "Lets old apps sign requests with api_key or X-Emby-Token.", show: has("server.EnableLegacyAuthorization") },
        ],
      },
    ],
  },
  display: {
    sources: [serverConfig, namedConfig("metadata")],
    sections: [{
      fields: [
        { kind: "select", key: "metadata.UseFileCreationTimeForDateAdded", label: "Date added behavior for new content", help: "A date from the metadata is always used first.", options: opts([false, "Use date scanned into the library"], [true, "Use file creation date"]) },
        { kind: "toggle", key: "server.EnableFolderView", label: "Display a folder view to show plain media folders", help: "Shows your folders next to your libraries." },
        { kind: "toggle", key: "server.DisplaySpecialsWithinSeasons", label: "Display specials within the seasons they aired in" },
        { kind: "toggle", key: "server.EnableGroupingMoviesIntoCollections", label: "Group movies into collections", help: "Movies in a collection show as one item in movie lists." },
        { kind: "toggle", key: "server.EnableGroupingShowsIntoCollections", label: "Group shows into collections", help: "Shows in a collection show as one item in show lists.", show: has("server.EnableGroupingShowsIntoCollections") },
        { kind: "toggle", key: "server.EnableExternalContentInSuggestions", label: "Enable external content in suggestions", help: "Lets internet trailers and live TV programs appear in suggestions." },
      ],
    }],
  },
  metadata: {
    sources: [serverConfig],
    ctx: async (api) => ({ cultures: await api.get("/Localization/Cultures").catch(() => []), countries: await api.get("/Localization/Countries").catch(() => []) }),
    sections: [
      {
        title: "Preferred metadata language",
        help: "Defaults for new libraries; each library can have its own.",
        fields: [
          { kind: "select", key: "server.PreferredMetadataLanguage", label: "Language", options: cultureOpts },
          { kind: "select", key: "server.MetadataCountryCode", label: "Country/Region", options: countryOpts },
        ],
      },
      {
        title: "Chapter images",
        fields: [
          { kind: "number", key: "server.DummyChapterDuration", label: "Interval (seconds)", help: "Time between generated chapters for videos without any. 0 turns this off. Doesn't change existing chapters.", min: 0 },
          { kind: "select", key: "server.ChapterImageResolution", label: "Resolution", help: "The size of extracted chapter images. Doesn't change existing ones.", options: RESOLUTIONS },
        ],
      },
    ],
  },
  nfo: {
    sources: [namedConfig("xbmcmetadata")],
    ctx: async (api) => ({ users: await api.get("/Users").catch(() => []) }),
    intro: "Changes apply to content added from now on. To turn NFO files on or off, edit a library and find Metadata savers.",
    sections: [{
      fields: [
        { kind: "select", key: "xbmcmetadata.UserId", label: "Save user watch data to NFO files for", help: "Saves watch data into NFO files for other apps (like Kodi) to use.", options: (_, c) => [{ value: null, label: "None" }, ...((c.users as User[]) ?? []).map((u) => ({ value: u.Id, label: u.Name ?? u.Id }))] },
        { kind: "toggle", key: "xbmcmetadata.SaveImagePathsInNfo", label: "Save image paths within NFO files", help: "Recommended if your image file names don't follow Kodi's naming." },
        { kind: "toggle", key: "xbmcmetadata.EnablePathSubstitution", label: "Enable path substitution", help: "Rewrites image paths with the server's path substitutions." },
        { kind: "toggle", key: "xbmcmetadata.EnableExtraThumbsDuplication", label: "Copy extrafanart to extrathumbs", help: "Saves images to both, for the most Kodi skins." },
      ],
    }],
  },
  transcoding: { sources: [namedConfig("encoding")], sections: TRANSCODING },
  resume: {
    sources: [serverConfig],
    sections: [{
      fields: [
        { kind: "number", key: "server.MinResumePct", label: "Minimum resume percentage", help: "Titles stopped before this count as unplayed.", min: 0, max: 100 },
        { kind: "number", key: "server.MaxResumePct", label: "Maximum resume percentage", help: "Titles stopped after this count as fully played.", min: 1, max: 100 },
        { kind: "number", key: "server.MinAudiobookResume", label: "Minimum audiobook resume (minutes)", help: "Audiobooks stopped before this count as unplayed.", min: 0, max: 100 },
        { kind: "number", key: "server.MaxAudiobookResume", label: "Audiobook remaining minutes to resume", help: "Audiobooks stopped with less than this left count as fully played.", min: 1, max: 100 },
        { kind: "number", key: "server.MinResumeDurationSeconds", label: "Minimum resume duration (seconds)", help: "The shortest video that saves where you stopped.", min: 0 },
      ],
    }],
  },
  streaming: {
    sources: [serverConfig],
    sections: [{
      fields: [
        { kind: "number", key: "server.RemoteClientBitrateLimit", label: "Internet streaming bitrate limit (Mbps)", help: "An optional per-stream limit for devices outside your network, so they don't ask for more than your upload can handle. May make the server transcode more. Blank or 0 = no limit.", min: 0, max: 2147.25, step: 0.25, scale: 1e6, integer: false },
      ],
    }],
  },
  trickplay: {
    sources: [serverConfig],
    sections: [{
      fields: [
        { kind: "toggle", key: "server.TrickplayOptions.EnableHwAcceleration", label: "Enable hardware decoding" },
        { kind: "toggle", key: "server.TrickplayOptions.EnableHwEncoding", label: "Enable hardware accelerated MJPEG encoding", help: "Only with QSV, VA-API, VideoToolbox and RKMPP.", show: has("server.TrickplayOptions.EnableHwEncoding") },
        { kind: "toggle", key: "server.TrickplayOptions.EnableKeyFrameOnlyExtraction", label: "Only generate images from key frames", help: "Much faster, with less exact timing. Falls back to software decoding if the hardware decoder can't do this.", show: has("server.TrickplayOptions.EnableKeyFrameOnlyExtraction") },
        { kind: "select", key: "server.TrickplayOptions.ScanBehavior", label: "Scan behavior", help: "Non-blocking adds media before its trickplay images are done. Blocking waits for them, which makes scans much longer.", options: opts(["NonBlocking", "Non blocking: queue generation, then return"], ["Blocking", "Blocking: wait for generation before finishing the scan"]) },
        { kind: "select", key: "server.TrickplayOptions.ProcessPriority", label: "Process priority", help: "Lower it if the server slows down while generating images.", options: opts(["High", "High"], ["AboveNormal", "Above normal"], ["Normal", "Normal"], ["BelowNormal", "Below normal"], ["Idle", "Idle"]) },
        { kind: "number", key: "server.TrickplayOptions.Interval", label: "Image interval (ms)", help: "Time between trickplay images.", min: 1 },
        { kind: "tags", key: "server.TrickplayOptions.WidthResolutions", label: "Width resolutions (px)", help: "Widths to generate images at. A width of 320 on a 16:9 video gives about 320×180.", numeric: true, placeholder: "e.g. 320" },
        { kind: "number", key: "server.TrickplayOptions.TileWidth", label: "Tile width", help: "Most images per tile across.", min: 1 },
        { kind: "number", key: "server.TrickplayOptions.TileHeight", label: "Tile height", help: "Most images per tile down.", min: 1 },
        { kind: "number", key: "server.TrickplayOptions.JpegQuality", label: "JPEG quality", min: 1, max: 100 },
        { kind: "number", key: "server.TrickplayOptions.Qscale", label: "Qscale", help: "FFmpeg's image quality scale: 2 is best, 31 worst.", min: 2, max: 31 },
        { kind: "number", key: "server.TrickplayOptions.ProcessThreads", label: "FFmpeg threads", help: "Passed to FFmpeg's -threads. 0 = automatic.", min: 0 },
      ],
    }],
  },
  networking: {
    sources: [namedConfig("network")],
    intro: "Wrong network settings can make the server unreachable. Most changes need a server restart.",
    sections: [
      {
        title: "Server address settings",
        fields: [
          { kind: "number", key: "network.InternalHttpPort", label: "Local HTTP port number", min: 1, max: 65535 },
          { kind: "toggle", key: "network.EnableHttps", label: "Enable HTTPS", help: "Listen on the HTTPS port. Needs a valid certificate too." },
          { kind: "number", key: "network.InternalHttpsPort", label: "Local HTTPS port number", min: 1, max: 65535 },
          { kind: "text", key: "network.BaseUrl", label: "Base URL", help: "A subfolder for the server's address, e.g. https://example.com/<base url>.", placeholder: "/jellyfin" },
          { kind: "tags", key: "network.LocalNetworkAddresses", label: "Bind to local network address", help: "Addresses the server listens on. Empty = all of them.", placeholder: "e.g. 192.168.1.10" },
          { kind: "tags", key: "network.LocalNetworkSubnets", label: "LAN networks", help: "IP addresses or IP/mask ranges that count as your local network. Empty = the usual private ranges (RFC 1918).", placeholder: "e.g. 192.168.1.0/24" },
          { kind: "tags", key: "network.KnownProxies", label: "Known proxies", help: "Reverse proxies in front of the server (IPs or hostnames), so X-Forwarded-For is trusted.", placeholder: "e.g. 127.0.0.1" },
        ],
      },
      {
        title: "HTTPS settings",
        fields: [
          { kind: "toggle", key: "network.RequireHttps", label: "Require HTTPS", help: "Redirect every HTTP request to HTTPS. Only works while HTTPS is on." },
          { kind: "path", key: "network.CertificatePath", label: "Custom SSL certificate path", help: "A PKCS #12 (.pfx) file with the certificate and private key.", files: true },
          { kind: "text", key: "network.CertificatePassword", label: "Certificate password", password: true },
        ],
      },
      {
        title: "Remote access settings",
        fields: [
          { kind: "toggle", key: "network.EnableRemoteAccess", label: "Allow remote connections to this server", help: "Off blocks every connection from outside your network." },
          { kind: "tags", key: "network.RemoteIPFilter", label: "Remote IP address filter", help: "IP addresses or IP/mask ranges. Empty = every remote address may connect.", placeholder: "e.g. 203.0.113.0/24" },
          { kind: "select", key: "network.IsRemoteIPFilterBlacklist", label: "Remote IP address filter mode", options: opts([false, "Whitelist (only these may connect)"], [true, "Blacklist (these are blocked)"]) },
          { kind: "number", key: "network.PublicHttpPort", label: "Public HTTP port number", help: "The public port mapped to the local HTTP port.", min: 1, max: 65535 },
          { kind: "number", key: "network.PublicHttpsPort", label: "Public HTTPS port number", help: "The public port mapped to the local HTTPS port.", min: 1, max: 65535 },
        ],
      },
      {
        title: "IP protocols",
        fields: [
          { kind: "toggle", key: "network.EnableIPv4", label: "Enable IPv4" },
          { kind: "toggle", key: "network.EnableIPv6", label: "Enable IPv6" },
        ],
      },
      {
        title: "Network discovery",
        fields: [{ kind: "toggle", key: "network.AutoDiscovery", label: "Enable auto discovery", help: "Lets apps find the server on UDP port 7359." }],
      },
      {
        title: "Firewall and proxy settings",
        fields: [{ kind: "custom", key: "published", render: (d, put) => <PublishedUris value={(get(d, "network.PublishedServerUriBySubnet") as string[] | null) ?? []} onChange={(v) => put("network.PublishedServerUriBySubnet", v)} /> }],
      },
    ],
  },
  branding: {
    sources: [namedConfig("branding")],
    sections: [
      {
        title: "Splash screen",
        fields: [
          { kind: "toggle", key: "branding.SplashscreenEnabled", label: "Enable the splash screen image" },
          { kind: "custom", key: "splash", render: () => <SplashImage /> },
        ],
      },
      {
        title: "Text and style",
        fields: [
          { kind: "text", key: "branding.LoginDisclaimer", label: "Login disclaimer", help: "Shown at the bottom of the sign-in page.", rows: 5 },
          { kind: "text", key: "branding.CustomCss", label: "Custom CSS code", help: "Your own CSS for theming the web interface.", rows: 10, mono: true },
        ],
      },
    ],
  },
  dvr: {
    sources: [namedConfig("livetv")],
    sections: [
      {
        title: "Default recording settings",
        fields: [
          { kind: "select", key: "livetv.GuideDays", label: "Number of days of guide data to download", help: "More days let you plan further ahead, but downloads take longer. Auto picks by the number of channels.", options: [{ value: null, label: "Auto" }, ...Array.from({ length: 14 }, (_, i) => ({ value: i + 1, label: String(i + 1) }))] },
          { kind: "path", key: "livetv.RecordingPath", label: "Default recording path", help: "Where recordings go. Leave blank to use the server's data folder." },
          { kind: "path", key: "livetv.MovieRecordingPath", label: "Movie recording path (optional)" },
          { kind: "path", key: "livetv.SeriesRecordingPath", label: "Series recording path (optional)" },
          { kind: "number", key: "livetv.PrePaddingSeconds", label: "Start when possible (minutes before)", min: 0, scale: 60 },
          { kind: "number", key: "livetv.PostPaddingSeconds", label: "Stop when possible (minutes after)", min: 0, scale: 60 },
        ],
      },
      {
        title: "Recording post-processing",
        fields: [
          { kind: "path", key: "livetv.RecordingPostProcessor", label: "Post-processing application", files: true },
          { kind: "text", key: "livetv.RecordingPostProcessorArguments", label: "Post-processor command line arguments", help: "Use {path} for the recording's path.", placeholder: "\"{path}\"" },
        ],
      },
      {
        title: "Recording metadata",
        fields: [
          { kind: "toggle", key: "livetv.SaveRecordingNFO", label: "Save recording EPG metadata in NFO files", help: "Saves the guide data next to the recording." },
          { kind: "toggle", key: "livetv.SaveRecordingImages", label: "Save recording EPG images", help: "Saves the guide images next to the recording." },
        ],
      },
    ],
  },
};

export const SERVER_PAGES = Object.keys(PAGES);

export function ServerSettingsPage({ page }: { page: string }) {
  const model = useModel();
  const api = model.api!;
  const def = PAGES[page];
  const { data: ctx } = useLoad(async () => (def?.ctx ? def.ctx(api) : {}), [page]);
  if (!def) return null;
  if (!ctx) return <Spinner />;
  return <ConfigForm key={page} sources={def.sources} sections={def.sections} ctx={ctx} banner={def.intro ? <div className="banner warn"><Icon name="info" size={15} /> {def.intro}</div> : undefined} />;
}

/** jellyfin-web's "published server URI": one for everyone, or separate internal and external ones. */
function PublishedUris({ value, onChange }: { value: string[]; onChange: (v: string[]) => void }) {
  const parse = () => {
    if (value.length === 1 && !value[0].includes("=")) return { all: value[0] } as Record<string, string>;
    const out: Record<string, string> = {};
    for (const p of value) { const i = p.indexOf("="); if (i > 0) out[p.slice(0, i)] = p.slice(i + 1); }
    return out;
  };
  const uris = parse();
  const [same, setSame] = useState(() => !!uris.all || (!uris.internal && !uris.external));
  // Per-subnet entries (set in the config file) are kept as they are.
  const others = value.filter((p) => p.includes("=") && !/^(all|internal|external)=/.test(p));
  const emit = (u: Record<string, string | undefined>, s: boolean) => onChange([...(s ? (u.all ? [`all=${u.all}`] : []) : [...(u.internal ? [`internal=${u.internal}`] : []), ...(u.external ? [`external=${u.external}`] : [])]), ...others]);
  return (
    <div className="form">
      <Toggle label="Use the same published server URI for internal and external access" checked={same} onChange={(s) => { setSame(s); emit(s ? { all: uris.all ?? uris.external ?? uris.internal } : { internal: uris.all, external: uris.all }, s); }} />
      {same ? (
        <label className="field"><span>Published server URI</span><input value={uris.all ?? ""} onChange={(e) => onChange([...(e.target.value ? [`all=${e.target.value}`] : []), ...others])} placeholder="https://jellyfin.example.com" spellCheck={false} /><small className="muted">Overrides the address Jellyfin gives to apps.</small></label>
      ) : (<>
        <label className="field"><span>Internal URI</span><input value={uris.internal ?? ""} onChange={(e) => onChange([...(e.target.value ? [`internal=${e.target.value}`] : []), ...(uris.external ? [`external=${uris.external}`] : []), ...others])} placeholder="http://192.168.1.10:8096" spellCheck={false} /><small className="muted">The address given to apps on your network.</small></label>
        <label className="field"><span>External URI</span><input value={uris.external ?? ""} onChange={(e) => onChange([...(uris.internal ? [`internal=${uris.internal}`] : []), ...(e.target.value ? [`external=${e.target.value}`] : []), ...others])} placeholder="https://jellyfin.example.com" spellCheck={false} /><small className="muted">The address given to apps outside your network.</small></label>
      </>)}
    </div>
  );
}

/** Upload or delete the custom splash screen (16:9, at least 1920×1080), like jellyfin-web. */
function SplashImage() {
  const model = useModel();
  const api = model.api!;
  const [stamp, setStamp] = useState(Date.now());
  const [busy, setBusy] = useState(false);
  const upload = (file: File) => {
    const reader = new FileReader();
    reader.onload = async () => {
      setBusy(true);
      try {
        await api.request("POST", "/Branding/Splashscreen", { body: String(reader.result).split(",")[1], contentType: file.type });
        setStamp(Date.now());
        model.toast("Splash screen uploaded", "success");
      } catch (e) { model.fail(e); } finally { setBusy(false); }
    };
    reader.readAsDataURL(file);
  };
  return (
    <div className="splash-edit">
      <img src={api.url("/Branding/Splashscreen", { t: stamp })} alt="" onError={(e) => { (e.target as HTMLImageElement).style.visibility = "hidden"; }} onLoad={(e) => { (e.target as HTMLImageElement).style.visibility = "visible"; }} />
      <small className="muted">Custom images should be 16:9 and at least 1920×1080.</small>
      <div className="row-line">
        <label className={`glass-button ${busy ? "disabled" : ""}`}><Icon name="image" size={15} /> Upload custom image<input type="file" accept="image/*" hidden disabled={busy} onChange={(e) => { const f = e.target.files?.[0]; if (f) upload(f); e.target.value = ""; }} /></label>
        <button className="glass-button danger" disabled={busy} onClick={async () => { setBusy(true); try { await api.del("/Branding/Splashscreen"); setStamp(Date.now()); } catch (e) { model.fail(e); } finally { setBusy(false); } }}>Delete custom image</button>
      </div>
    </div>
  );
}
