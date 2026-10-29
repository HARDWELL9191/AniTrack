import { AiringEpisode } from "../core/models";

export function countdown(seconds: number): string {
  const days = Math.floor(seconds / 86_400);
  const hours = Math.floor((seconds % 86_400) / 3_600);
  const minutes = Math.floor((seconds % 3_600) / 60);
  if (days > 0) return `${days}d ${hours}h`;
  if (hours > 0) return `${hours}h ${minutes}m`;
  return `${Math.max(minutes, 1)}m`;
}

export function airing(next?: AiringEpisode | null): string | undefined {
  if (!next) return undefined;
  const remaining = Math.max(0, next.airingAt - Math.floor(Date.now() / 1000));
  return `Ep ${next.episode} in ${countdown(remaining)}`;
}

/** 82 → "8.2/10" */
export const outOfTen = (score: number) => `${(score / 10).toFixed(1)}/10`;

export function smiley(score: number): "smileHappy" | "smile" | "smileDashed" {
  if (score >= 75) return "smileHappy";
  if (score >= 60) return "smile";
  return "smileDashed";
}

/** Your score (0–100) as "8" or "8.5". */
export function myScore(raw?: number | null): string {
  if (!raw || raw <= 0) return "–";
  const ten = raw / 10;
  return ten === Math.round(ten) ? String(ten) : ten.toFixed(1);
}

export function relativeTime(ms: number): string {
  const diff = Date.now() - ms;
  const rtf = new Intl.RelativeTimeFormat(undefined, { numeric: "auto" });
  const mins = Math.round(diff / 60_000);
  if (mins < 60) return rtf.format(-Math.max(mins, 0), "minute");
  const hours = Math.round(mins / 60);
  if (hours < 24) return rtf.format(-hours, "hour");
  return rtf.format(-Math.round(hours / 24), "day");
}

export const capitalized = (s: string) => s.charAt(0) + s.slice(1).toLowerCase();

export function hexColor(hex?: string | null): string | undefined {
  return hex && /^#?[0-9a-f]{6}$/i.test(hex) ? (hex.startsWith("#") ? hex : `#${hex}`) : undefined;
}
