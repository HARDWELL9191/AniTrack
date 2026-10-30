// Formatting helpers shared by every screen.

import type { Item, MediaStream } from "../core/types";
import { ticksToSeconds } from "../core/types";

/** 5425 → "1:30:25", 65 → "1:05" */
export function clock(seconds: number): string {
  if (!isFinite(seconds) || seconds < 0) seconds = 0;
  const s = Math.floor(seconds % 60);
  const m = Math.floor((seconds / 60) % 60);
  const h = Math.floor(seconds / 3600);
  const pad = (n: number) => String(n).padStart(2, "0");
  return h > 0 ? `${h}:${pad(m)}:${pad(s)}` : `${m}:${pad(s)}`;
}

/** Ticks → "1h 42m" / "24m" */
export function runtime(ticks?: number | null): string | null {
  if (!ticks) return null;
  const minutes = Math.round(ticksToSeconds(ticks) / 60);
  if (minutes < 1) return "< 1m";
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  return h ? (m ? `${h}h ${m}m` : `${h}h`) : `${m}m`;
}

export function endsAt(ticks?: number | null, positionTicks = 0): string | null {
  if (!ticks) return null;
  const end = new Date(Date.now() + ticksToSeconds(ticks - positionTicks) * 1000);
  return `Ends at ${end.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })}`;
}

export function bytes(n?: number | null): string {
  if (!n) return "—";
  const units = ["B", "KB", "MB", "GB", "TB"];
  let i = 0;
  let v = n;
  while (v >= 1024 && i < units.length - 1) { v /= 1024; i++; }
  return `${v.toFixed(v >= 100 || i === 0 ? 0 : 1)} ${units[i]}`;
}

export function bitrate(bps?: number | null): string {
  if (!bps) return "—";
  return bps >= 1_000_000 ? `${(bps / 1_000_000).toFixed(1)} Mbps` : `${Math.round(bps / 1000)} kbps`;
}

export function relativeTime(date?: string | number | null): string {
  if (!date) return "";
  const t = typeof date === "number" ? date : Date.parse(date);
  if (!isFinite(t)) return "";
  const diff = (Date.now() - t) / 1000;
  const abs = Math.abs(diff);
  const fmt = new Intl.RelativeTimeFormat(undefined, { numeric: "auto" });
  const sign = diff >= 0 ? -1 : 1;
  if (abs < 60) return fmt.format(sign * Math.round(abs), "second");
  if (abs < 3600) return fmt.format(sign * Math.round(abs / 60), "minute");
  if (abs < 86_400) return fmt.format(sign * Math.round(abs / 3600), "hour");
  if (abs < 30 * 86_400) return fmt.format(sign * Math.round(abs / 86_400), "day");
  if (abs < 365 * 86_400) return fmt.format(sign * Math.round(abs / (30 * 86_400)), "month");
  return fmt.format(sign * Math.round(abs / (365 * 86_400)), "year");
}

export function dateTime(date?: string | null): string {
  if (!date) return "—";
  const d = new Date(date);
  return isFinite(d.getTime()) ? d.toLocaleString([], { dateStyle: "medium", timeStyle: "short" }) : "—";
}

export function dateOnly(date?: string | null): string {
  if (!date) return "";
  const d = new Date(date);
  return isFinite(d.getTime()) ? d.toLocaleDateString([], { dateStyle: "medium" }) : "";
}

/** "S1:E4", "S1:E4-5", "Special" */
export function episodeCode(i: Item): string {
  if (i.Type !== "Episode") return "";
  if (i.ParentIndexNumber === 0) return "Special";
  const s = i.ParentIndexNumber ?? "?";
  const e = i.IndexNumber ?? "?";
  return `S${s}:E${e}${i.IndexNumberEnd ? `-${i.IndexNumberEnd}` : ""}`;
}

/** The name a card shows. */
export function itemTitle(i: Item): string {
  return i.Name ?? "Untitled";
}

/** Second line under a card. */
export function itemSubtitle(i: Item): string {
  switch (i.Type) {
    case "Episode": return [i.SeriesName, episodeCode(i)].filter(Boolean).join(" · ");
    case "Season": return i.SeriesName ?? "";
    case "Series": {
      const end = i.Status === "Continuing" ? "Present" : i.EndDate ? new Date(i.EndDate).getFullYear() : null;
      return i.ProductionYear ? (end && end !== i.ProductionYear ? `${i.ProductionYear} – ${end}` : `${i.ProductionYear}`) : "";
    }
    case "MusicAlbum": return i.AlbumArtist ?? i.Artists?.join(", ") ?? "";
    case "Audio": return i.Artists?.join(", ") ?? i.Album ?? "";
    case "MusicVideo": return i.Artists?.join(", ") ?? "";
    case "BoxSet": return i.ChildCount ? `${i.ChildCount} items` : "";
    case "Playlist": return i.ChildCount ? `${i.ChildCount} items` : "";
    case "Person": return "";
    case "Program":
    case "TvProgram":
    case "LiveTvProgram": return i.StartDate ? new Date(i.StartDate).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" }) : "";
    case "TvChannel":
    case "LiveTvChannel": return i.CurrentProgram?.Name ?? i.ChannelNumber ?? "";
    default: return i.ProductionYear ? String(i.ProductionYear) : "";
  }
}

export function playedPercent(i: Item): number {
  const ud = i.UserData;
  if (!ud) return 0;
  if (ud.PlayedPercentage) return ud.PlayedPercentage;
  if (ud.PlaybackPositionTicks && i.RunTimeTicks) return (ud.PlaybackPositionTicks / i.RunTimeTicks) * 100;
  return 0;
}

export function languageName(code?: string | null): string {
  if (!code || code === "und") return "Unknown";
  try {
    const name = new Intl.DisplayNames(undefined, { type: "language" }).of(code.length === 3 ? ISO3_TO_2[code] ?? code : code);
    return name ?? code;
  } catch {
    return code;
  }
}

const ISO3_TO_2: Record<string, string> = {
  eng: "en", jpn: "ja", ger: "de", deu: "de", fre: "fr", fra: "fr", spa: "es", ita: "it", por: "pt", rus: "ru", chi: "zh", zho: "zh",
  kor: "ko", ara: "ar", hin: "hi", pol: "pl", dut: "nl", nld: "nl", swe: "sv", nor: "no", dan: "da", fin: "fi", tur: "tr",
  slv: "sl", hrv: "hr", srp: "sr", bos: "bs", cze: "cs", ces: "cs", slo: "sk", slk: "sk", hun: "hu", rum: "ro", ron: "ro",
  gre: "el", ell: "el", heb: "he", tha: "th", vie: "vi", ind: "id", may: "ms", msa: "ms", ukr: "uk", bul: "bg", fil: "fil",
  tgl: "tl", per: "fa", fas: "fa", cat: "ca", baq: "eu", eus: "eu", glg: "gl", ice: "is", isl: "is", est: "et", lav: "lv", lit: "lt",
};

/** "English · AAC 5.1 · Default" */
export function streamLabel(s: MediaStream): string {
  if (s.DisplayTitle) return s.DisplayTitle;
  const parts = [languageName(s.Language), s.Codec?.toUpperCase()];
  if (s.Type === "Audio" && s.ChannelLayout) parts.push(s.ChannelLayout);
  if (s.IsForced) parts.push("Forced");
  return parts.filter(Boolean).join(" · ");
}

export function videoBadges(s?: MediaStream | null): string[] {
  if (!s) return [];
  const out: string[] = [];
  const h = s.Height ?? 0, w = s.Width ?? 0;
  if (w >= 3800 || h >= 2100) out.push("4K");
  else if (w >= 2500 || h >= 1400) out.push("1440p");
  else if (w >= 1900 || h >= 1000) out.push("1080p");
  else if (w >= 1200 || h >= 700) out.push("720p");
  else if (h) out.push("SD");
  const range = s.VideoRangeType ?? s.VideoRange;
  if (range && range !== "SDR" && range !== "Unknown") out.push(range.replace("DOVIWith", "DV + ").replace("DOVI", "Dolby Vision").replace("HDR10Plus", "HDR10+"));
  if (s.Codec) out.push(s.Codec.toUpperCase().replace("HEVC", "HEVC").replace("H264", "H.264"));
  return out;
}

export function audioBadge(s?: MediaStream | null): string | null {
  if (!s) return null;
  const spatial = s.AudioSpatialFormat && s.AudioSpatialFormat !== "None" ? s.AudioSpatialFormat.replace("DolbyAtmos", "Atmos").replace("DTSX", "DTS:X") : null;
  const codec = s.Profile?.includes("MA") ? "DTS-HD MA" : s.Codec?.toUpperCase().replace("EAC3", "E-AC-3").replace("TRUEHD", "TrueHD");
  return [codec, s.ChannelLayout, spatial].filter(Boolean).join(" ");
}

export const plural = (n: number, word: string) => `${n} ${word}${n === 1 ? "" : "s"}`;

export function hexColor(v?: string | null): string | undefined {
  return v && /^#[0-9a-f]{6}/i.test(v) ? v.slice(0, 7) : undefined;
}

export function stars(rating?: number | null): string | null {
  return rating ? rating.toFixed(1) : null;
}
