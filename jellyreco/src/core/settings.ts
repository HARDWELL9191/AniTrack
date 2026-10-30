// App and player settings, kept in this browser profile (per install). Server-side user settings
// (audio/subtitle language, subtitle mode, autoplay next episode...) live in the user's Jellyfin
// configuration and are edited in Settings → Playback, like jellyfin-web.

import type { SegmentType } from "./types";

export type SegmentAction = "none" | "ask" | "skipOnce" | "skip";
export type AutoNext = "off" | "smart" | "always";
export type VideoFit = "contain" | "cover" | "stretch";
export type Hwdec = "auto-safe" | "d3d11va" | "d3d11va-copy" | "no";
export type ToneMapping = "auto" | "bt.2390" | "spline" | "hable" | "mobius" | "reinhard" | "clip";
export type Upscaler = "default" | "ewa_lanczossharp" | "spline36" | "lanczos" | "bilinear";
export type Theme = "system" | "dark" | "light";

export interface SubtitleStyle {
  fontSize: number; // mpv sub-font-size (scaled 720p)
  bold: boolean;
  color: string;
  borderColor: string;
  borderSize: number;
  backgroundColor: string; // #00000000 = none
  marginY: number;
  font: string;
  /** Use the subtitle's own styling (ASS); when off, styles are forced. */
  assOverride: "no" | "yes" | "force" | "scale" | "strip";
}

export interface Settings {
  // Appearance
  theme: Theme;
  showBackdrops: boolean;
  blurUnwatched: boolean;
  homeSections: HomeSection[];
  libraryCardSize: number;
  showRatings: boolean;
  hideWatchedInLatest: boolean;
  enableThemeSongs: boolean;

  // Player
  hwdec: Hwdec;
  highQuality: boolean; // vo=gpu-next with high-quality scalers
  upscaler: Upscaler;
  deband: boolean;
  toneMapping: ToneMapping;
  hdrPeakDetect: boolean;
  videoFit: VideoFit;
  interpolation: boolean;
  defaultSpeed: number;
  volume: number;
  volumeBoostMax: number; // mpv volume-max
  audioNormalize: boolean;
  audioPassthrough: boolean; // spdif for AC3/DTS/E-AC3/TrueHD
  audioChannels: "auto" | "stereo" | "5.1" | "7.1";
  audioDevice: string;
  cacheSeconds: number;
  maxBitrateLocal: number; // 0 = original (direct play)
  maxBitrateRemote: number;
  seekShort: number; // seconds (arrow keys)
  seekLong: number; // seconds (J/L, Shift+arrows)
  autoNext: AutoNext;
  upNextSeconds: number; // countdown before the next episode
  segmentActions: Record<SegmentType, SegmentAction>;
  rememberAudio: boolean;
  rememberSubs: boolean;
  preferredAudioLang: string; // ISO 639-2, overrides the server setting when set
  preferredSubLang: string;
  subtitleStyle: SubtitleStyle;
  trickplay: boolean;
  resumeBehavior: "ask" | "resume" | "start";
  pauseOnMinimize: boolean;
  screenshotFolder: string;
  showClock: boolean;
  remainingTime: boolean;
  doubleClickFullscreen: boolean;
  wheelVolume: boolean;
  startFullscreen: boolean;

  // For You
  useOnDeviceAI: boolean;
  /** First dropdown: a library id, "all", or "" = the library named "Anime" (else all). */
  forYouLibrary: string;
  forYouCategory: string; // second dropdown: "" = all categories
  forYouMinRating: number; // community rating floor (0 = any)
}

export type HomeSection = "resume" | "nextUp" | "forYouRow" | "watchLater" | "latest" | "favorites" | "libraries" | "liveTv" | "none";

export const ALL_HOME_SECTIONS: { id: HomeSection; label: string }[] = [
  { id: "resume", label: "Continue watching" },
  { id: "nextUp", label: "Next up" },
  { id: "forYouRow", label: "Picked for you" },
  { id: "watchLater", label: "Watch later" },
  { id: "latest", label: "Latest in each library" },
  { id: "favorites", label: "Favorites" },
  { id: "libraries", label: "My media" },
  { id: "liveTv", label: "On now (Live TV)" },
];

export const DEFAULT_SUB_STYLE: SubtitleStyle = {
  fontSize: 46,
  bold: false,
  color: "#FFFFFFFF",
  borderColor: "#000000FF",
  borderSize: 2.5,
  backgroundColor: "#00000000",
  marginY: 34,
  font: "Segoe UI",
  assOverride: "no",
};

export const DEFAULT_SETTINGS: Settings = {
  theme: "system",
  showBackdrops: true,
  blurUnwatched: false,
  homeSections: ["resume", "nextUp", "forYouRow", "watchLater", "libraries", "latest", "favorites"],
  libraryCardSize: 168,
  showRatings: true,
  hideWatchedInLatest: false,
  enableThemeSongs: false,

  hwdec: "auto-safe",
  highQuality: true,
  upscaler: "ewa_lanczossharp",
  deband: true,
  toneMapping: "auto",
  hdrPeakDetect: true,
  videoFit: "contain",
  interpolation: false,
  defaultSpeed: 1,
  volume: 100,
  volumeBoostMax: 150,
  audioNormalize: false,
  audioPassthrough: false,
  audioChannels: "auto",
  audioDevice: "auto",
  cacheSeconds: 120,
  maxBitrateLocal: 0,
  maxBitrateRemote: 0,
  seekShort: 10,
  seekLong: 30,
  autoNext: "smart",
  upNextSeconds: 10,
  segmentActions: { Intro: "ask", Outro: "ask", Recap: "ask", Preview: "ask", Commercial: "skip", Unknown: "none" },
  rememberAudio: true,
  rememberSubs: true,
  preferredAudioLang: "",
  preferredSubLang: "",
  subtitleStyle: DEFAULT_SUB_STYLE,
  trickplay: true,
  resumeBehavior: "ask",
  pauseOnMinimize: false,
  screenshotFolder: "",
  showClock: true,
  remainingTime: false,
  doubleClickFullscreen: true,
  wheelVolume: true,
  startFullscreen: false,

  useOnDeviceAI: true,
  forYouLibrary: "",
  forYouCategory: "",
  forYouMinRating: 0,
};

const KEY = "settings-v1";

export function loadSettings(): Settings {
  try {
    const raw = localStorage.getItem(KEY);
    if (!raw) return structuredClone(DEFAULT_SETTINGS);
    const saved = JSON.parse(raw) as Partial<Settings>;
    return {
      ...structuredClone(DEFAULT_SETTINGS),
      ...saved,
      segmentActions: { ...DEFAULT_SETTINGS.segmentActions, ...(saved.segmentActions ?? {}) },
      subtitleStyle: { ...DEFAULT_SUB_STYLE, ...(saved.subtitleStyle ?? {}) },
    };
  } catch {
    return structuredClone(DEFAULT_SETTINGS);
  }
}

export function saveSettings(s: Settings) {
  try { localStorage.setItem(KEY, JSON.stringify(s)); } catch { /* storage full or blocked */ }
}

export const BITRATES: { value: number; label: string }[] = [
  { value: 0, label: "Original (direct play)" },
  { value: 120_000_000, label: "120 Mbps (4K)" },
  { value: 80_000_000, label: "80 Mbps (4K)" },
  { value: 60_000_000, label: "60 Mbps (4K)" },
  { value: 40_000_000, label: "40 Mbps (1080p)" },
  { value: 20_000_000, label: "20 Mbps (1080p)" },
  { value: 15_000_000, label: "15 Mbps (1080p)" },
  { value: 10_000_000, label: "10 Mbps (1080p)" },
  { value: 8_000_000, label: "8 Mbps (720p)" },
  { value: 6_000_000, label: "6 Mbps (720p)" },
  { value: 4_000_000, label: "4 Mbps (720p)" },
  { value: 3_000_000, label: "3 Mbps (480p)" },
  { value: 1_500_000, label: "1.5 Mbps (480p)" },
  { value: 720_000, label: "720 kbps (360p)" },
];

export const SPEEDS = [0.25, 0.5, 0.75, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3];
