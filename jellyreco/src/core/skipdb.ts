// Intro / recap / credits times from the open, community-run skip databases, for episodes and
// movies the server has no media segments for (the same two databases Infuse uses):
//   - TheIntroDB (api.theintrodb.org, API v4): asked first. Intro, recap, credits, preview.
//   - IntroDB (api.introdb.app): fills intro, recap or credits TheIntroDB doesn't have.
// Both are read without an account or a key. Only the title's TVDB / TMDB / IMDb ID, the season
// and episode number and the runtime are sent; nothing about the server, the user or the file.
// The same logic as the iPhone app's SkipDatabase.swift.

import type { Item, MediaSegment, SegmentType } from "./types";

type FetchFn = (url: string, init?: RequestInit) => Promise<Response>;
let fetchImpl: FetchFn = (url, init) => fetch(url, init);
export const setSkipDbFetch = (f: FetchFn) => (fetchImpl = f);

const THE_INTRO_DB = "https://api.theintrodb.org/v4/media";
const INTRO_DB = "https://api.introdb.app/segments";
const TIMEOUT_MS = 8000;
const TICKS_PER_MS = 10_000;

/** The segment types a database can fill in (ads are never in them). */
export const SKIP_DB_TYPES: SegmentType[] = ["Intro", "Recap", "Outro", "Preview"];

/** What identifies a title in the databases. */
export interface SkipLookup {
  itemId: string;
  movie: boolean;
  tvdb?: number;          // the series' (or movie's) TVDB ID
  tmdb?: number;
  imdb?: string;          // "tt…"
  season?: number;
  episode?: number;
  tvdbEpisode?: number;   // the episode's own TVDB ID: the same episode in every episode order
  mapping?: string;       // the series' episode order on the server, when it isn't the default one
  durationMs: number;     // 0 = unknown
}

const positiveInt = (v: unknown): number | undefined => {
  const n = typeof v === "number" ? v : typeof v === "string" && /^\d+$/.test(v.trim()) ? Number(v.trim()) : NaN;
  return Number.isSafeInteger(n) && n > 0 ? n : undefined;
};
const imdbId = (v: unknown): string | undefined => (typeof v === "string" && /^tt\d+$/.test(v.trim()) ? v.trim() : undefined);
/** Provider IDs are matched without regard to case ("Tvdb", "tvdb", "TVDB"). */
function provider(ids: Record<string, string | null | undefined> | null | undefined, name: string): string | undefined {
  for (const [k, v] of Object.entries(ids ?? {})) if (k.toLowerCase() === name && v) return v;
  return undefined;
}

// Jellyfin's display orders that are TVDB episode orders TheIntroDB can convert from.
const ORDERS: Record<string, string> = { dvd: "dvd", absolute: "absolute", alternate: "alternate", regional: "regional", altdvd: "altdvd", alttwo: "alttwo" };

/** The lookup for an episode (with its series) or a movie; null when it can't be looked up. */
export function skipLookup(item: Item, series: Item | null): SkipLookup | null {
  const durationMs = Math.max(0, Math.round((item.RunTimeTicks ?? 0) / TICKS_PER_MS));
  if (item.Type === "Movie") {
    const l: SkipLookup = { itemId: item.Id, movie: true, tvdb: positiveInt(provider(item.ProviderIds, "tvdb")), tmdb: positiveInt(provider(item.ProviderIds, "tmdb")), imdb: imdbId(provider(item.ProviderIds, "imdb")), durationMs };
    return l.tvdb || l.tmdb || l.imdb ? l : null;
  }
  if (item.Type !== "Episode" || !series) return null;
  const season = item.ParentIndexNumber, episode = item.IndexNumber;
  if (!Number.isInteger(season) || !Number.isInteger(episode) || season! < 0 || episode! < 1) return null;
  // One file holding several episodes: the times of its first episode don't fit the file.
  if (item.IndexNumberEnd != null && item.IndexNumberEnd !== episode) return null;
  const l: SkipLookup = {
    itemId: item.Id, movie: false, season: season!, episode: episode!, durationMs,
    tvdb: positiveInt(provider(series.ProviderIds, "tvdb")), tmdb: positiveInt(provider(series.ProviderIds, "tmdb")), imdb: imdbId(provider(series.ProviderIds, "imdb")),
    tvdbEpisode: positiveInt(provider(item.ProviderIds, "tvdb")),
    mapping: ORDERS[(series.DisplayOrder ?? "").toLowerCase()],
  };
  return l.tvdb || l.tmdb || l.imdb ? l : null;
}

/** TheIntroDB's address for a lookup: one ID per request, as its API reads the numbers by that ID's own numbering. */
export function theIntroDbUrl(l: SkipLookup): string | null {
  const q = new URLSearchParams();
  if (l.movie) {
    if (l.tmdb) q.set("tmdb_id", String(l.tmdb));
    else if (l.imdb) q.set("imdb_id", l.imdb);
    else if (l.tvdb) q.set("tvdb_id", String(l.tvdb));
    else return null;
  } else {
    if (l.tvdb && l.tvdbEpisode) {
      // The episode's own TVDB ID names the episode whatever order the numbers are in.
      q.set("tvdb_id", String(l.tvdb));
      q.set("tvdb_episode_id", String(l.tvdbEpisode));
    } else if (l.tmdb) q.set("tmdb_id", String(l.tmdb));
    else if (l.tvdb) {
      q.set("tvdb_id", String(l.tvdb));
      if (l.mapping) q.set("mapping", l.mapping);
    } else if (l.imdb) q.set("imdb_id", l.imdb);
    else return null;
    q.set("season", String(l.season));
    q.set("episode", String(l.episode));
  }
  if (l.durationMs > 0) q.set("duration_ms", String(l.durationMs));
  return `${THE_INTRO_DB}?${q}`;
}

/** IntroDB's address for a lookup (it knows titles by IMDb ID only). */
export function introDbUrl(l: SkipLookup): string | null {
  if (!l.imdb) return null;
  const q = new URLSearchParams({ imdb_id: l.imdb });
  if (l.movie) q.set("is_movie", "true");
  else { q.set("season", String(l.season)); q.set("episode", String(l.episode)); }
  return `${INTRO_DB}?${q}`;
}

const ms = (v: unknown): number | null => (typeof v === "number" && Number.isFinite(v) && v >= 0 ? v : null);

/** One database entry as a media segment, or null when it can't be right for this file. */
export function skipSegment(source: string, type: SegmentType, startMs: number | null, endMs: number | null, l: SkipLookup): MediaSegment | null {
  const duration = l.durationMs;
  const start = Math.max(0, startMs ?? 0);              // no start: from the beginning
  let end = endMs ?? duration;                           // no end: to the end of the file
  if (duration > 0) end = Math.min(end, duration);
  if (!(end - start >= 2000)) return null;
  if (duration > 0) {
    // An intro in the second half or credits in the first belong to another cut or another episode.
    const early = type === "Intro" || type === "Recap";
    if (early ? start >= duration / 2 : start < duration / 2) return null;
  }
  return { Id: `skipdb:${source}:${type}:${Math.round(start)}`, ItemId: l.itemId, Type: type, StartTicks: Math.round(start) * TICKS_PER_MS, EndTicks: Math.round(end) * TICKS_PER_MS };
}

/** TheIntroDB's answer: { intro: [{ start_ms, end_ms }], recap: […], credits: […], preview: […] }. */
export function parseTheIntroDb(body: unknown, l: SkipLookup): MediaSegment[] {
  if (!body || typeof body !== "object" || Array.isArray(body)) return [];
  const o = body as Record<string, unknown>;
  // An answer for another episode than the one asked for is not used (an episode named by its own
  // TVDB ID may come back under that order's numbers).
  if (!l.movie && !(l.tvdb && l.tvdbEpisode)) {
    if (typeof o.season === "number" && o.season !== l.season) return [];
    if (typeof o.episode === "number" && o.episode !== l.episode) return [];
  }
  const out: MediaSegment[] = [];
  const kinds: [string, SegmentType][] = [["intro", "Intro"], ["recap", "Recap"], ["credits", "Outro"], ["preview", "Preview"]];
  for (const [key, type] of kinds) {
    const list = o[key];
    if (!Array.isArray(list)) continue;
    for (const e of list.slice(0, 6)) {
      if (!e || typeof e !== "object") continue;
      const r = e as Record<string, unknown>;
      const start = ms(r.start_ms), end = ms(r.end_ms);
      if (start === null && end === null) continue;
      const seg = skipSegment("tidb", type, start, end, l);
      if (seg) out.push(seg);
    }
  }
  return out;
}

/** IntroDB's answer: { intro: { start_ms, end_ms } | null, recap: …, outro: … }. */
export function parseIntroDb(body: unknown, l: SkipLookup): MediaSegment[] {
  if (!body || typeof body !== "object" || Array.isArray(body)) return [];
  const o = body as Record<string, unknown>;
  const out: MediaSegment[] = [];
  const kinds: [string, SegmentType][] = [["intro", "Intro"], ["recap", "Recap"], ["outro", "Outro"]];
  for (const [key, type] of kinds) {
    const e = o[key];
    if (!e || typeof e !== "object" || Array.isArray(e)) continue;
    const r = e as Record<string, unknown>;
    const sec = (v: unknown) => { const n = ms(v); return n === null ? null : n * 1000; };
    const start = ms(r.start_ms) ?? sec(r.start_sec), end = ms(r.end_ms) ?? sec(r.end_sec);
    if (start === null || end === null) continue;
    const seg = skipSegment("idb", type, start, end, l);
    if (seg) out.push(seg);
  }
  return out;
}

/** The server's segments, plus the databases' for the types the server has none of. */
export function mergeSegments(server: MediaSegment[], found: MediaSegment[]): MediaSegment[] {
  const have = new Set(server.map((s) => s.Type));
  return [...server, ...found.filter((s) => !have.has(s.Type))].sort((a, b) => a.StartTicks - b.StartTicks);
}

/** JSON from a database: the parsed body, null for "nothing there" (404), or undefined when it couldn't be asked. */
async function ask(url: string): Promise<unknown | null | undefined> {
  const abort = new AbortController();
  const timer = setTimeout(() => abort.abort(), TIMEOUT_MS);
  try {
    const r = await fetchImpl(url, { headers: { Accept: "application/json" }, signal: abort.signal });
    if (r.status === 404 || r.status === 204) return null;
    if (!r.ok) return undefined;
    return (await r.json()) as unknown;
  } catch {
    return undefined;
  } finally {
    clearTimeout(timer);
  }
}

const cache = new Map<string, MediaSegment[]>();

/** Segments from the databases for the types in `wanted`; [] when there are none or they can't be reached. */
export async function skipDbSegments(l: SkipLookup, wanted: SegmentType[]): Promise<MediaSegment[]> {
  if (!wanted.length) return [];
  let all = cache.get(l.itemId);
  if (!all) {
    let complete = true;
    all = [];
    const first = theIntroDbUrl(l);
    if (first) {
      const body = await ask(first);
      if (body === undefined) complete = false;
      else all = parseTheIntroDb(body, l);
    }
    // IntroDB only for what TheIntroDB doesn't have.
    const have = new Set(all.map((s) => s.Type));
    const second = (["Intro", "Recap", "Outro"] as SegmentType[]).some((t) => !have.has(t)) ? introDbUrl(l) : null;
    if (second) {
      const body = await ask(second);
      if (body === undefined) complete = false;
      else all = [...all, ...parseIntroDb(body, l).filter((s) => !have.has(s.Type))];
    }
    // An answer is kept for the session; a database that couldn't be reached is asked again next time.
    if (complete) {
      if (cache.size >= 300) cache.delete(cache.keys().next().value!);
      cache.set(l.itemId, all);
    }
  }
  return all.filter((s) => wanted.includes(s.Type));
}
