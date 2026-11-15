// Anime: opening / ending / recap times from AniSkip (api.aniskip.com), the open skip database for
// anime. AniSkip knows a show by its MyAnimeList ID, where every season or cour is its own entry
// that counts its episodes from 1, so a server's "series + season + episode" is first turned into
// "MyAnimeList ID + episode" with the open anime ID list (Fribb/anime-lists, the AniDB / TVDB /
// TMDB / AniList / MyAnimeList crosswalk), which also tells whether a title is anime at all.
// The list is downloaded once a week and kept as a small index.
// The same logic as the iPhone app's AniSkip.swift.

import type { MediaSegment, SegmentType } from "./types";

type FetchFn = (url: string, init?: RequestInit) => Promise<Response>;
let fetchImpl: FetchFn = (url, init) => fetch(url, init);
export const setAniSkipFetch = (f: FetchFn) => (fetchImpl = f);

interface KeyValue { get(key: string): string | null; set(key: string, value: string): void }
let storage: KeyValue = {
  get: (k) => { try { return localStorage.getItem(k); } catch { return null; } },
  set: (k, v) => { try { localStorage.setItem(k, v); } catch { /* full or unavailable: downloaded again next time */ } },
};
export const setAniSkipStorage = (s: KeyValue) => (storage = s);

const ANISKIP = "https://api.aniskip.com/v2/skip-times";
const ANIME_LIST = "https://raw.githubusercontent.com/Fribb/anime-lists/master/anime-list-full.json";
const INDEX_KEY = "skipdb.animeIndex.v1";
const INDEX_DAYS = 7;

// MARK: The anime ID index

/** One entry of a series: [mal, tvdb, tvdbSeason, tvdbOffset, tmdb, tmdbSeason, tmdbOffset, rank]. */
type ShowRow = [number, number, number, number, number, number, number, number];

/** What is kept of the anime ID list. */
export interface AnimeIndex {
  at: number;                          // when it was downloaded (ms)
  shows: ShowRow[];                    // entries with a TVDB or TMDB series ID
  movieTmdb: Record<string, number>;   // TMDB movie ID → MyAnimeList ID (0: anime, but no single entry)
  movieImdb: Record<string, number>;   // IMDb ID → MyAnimeList ID, movies only
  anilist: Record<string, number>;     // AniList ID → MyAnimeList ID
  anidb: Record<string, number>;       // AniDB ID → MyAnimeList ID
}

const int = (v: unknown): number => (typeof v === "number" && Number.isSafeInteger(v) && v > 0 ? v : 0);
const seasonOf = (v: unknown, has: boolean): number => (typeof v === "number" && Number.isInteger(v) && v >= 0 ? v : has ? 1 : -1);

/** The index of the downloaded list (an array of entries; every field of an entry is optional). */
export function buildAnimeIndex(list: unknown, at: number): AnimeIndex | null {
  if (!Array.isArray(list)) return null;
  const index: AnimeIndex = { at, shows: [], movieTmdb: {}, movieImdb: {}, anilist: {}, anidb: {} };
  const once = (map: Record<string, number>, key: string, mal: number) => { map[key] = key in map && map[key] !== mal ? 0 : mal; };
  for (const raw of list) {
    if (!raw || typeof raw !== "object") continue;
    const e = raw as Record<string, unknown>;
    const mal = int(e.mal_id);
    const type = typeof e.type === "string" ? e.type.toUpperCase() : "";
    const movie = type === "MOVIE";
    const tm = e.themoviedb_id && typeof e.themoviedb_id === "object" ? (e.themoviedb_id as Record<string, unknown>) : {};
    const season = e.season && typeof e.season === "object" ? (e.season as Record<string, unknown>) : {};
    const offset = e.episode_offset && typeof e.episode_offset === "object" ? (e.episode_offset as Record<string, unknown>) : {};
    const tvdb = int(e.tvdb_id), tmdb = int(tm.tv);
    if (tvdb || tmdb) {
      index.shows.push([mal, tvdb, seasonOf(season.tvdb, !!tvdb), int(offset.tvdb), tmdb, seasonOf(season.tmdb, !!tmdb), int(offset.tmdb), movie ? 2 : type === "TV" ? 0 : 1]);
    }
    if (Array.isArray(tm.movie)) for (const id of tm.movie) if (int(id)) once(index.movieTmdb, String(id), mal);
    if (movie && Array.isArray(e.imdb_id)) for (const id of e.imdb_id) if (typeof id === "string" && /^tt\d+$/.test(id)) once(index.movieImdb, id, mal);
    if (mal && int(e.anilist_id)) index.anilist[String(e.anilist_id)] = mal;
    if (mal && int(e.anidb_id)) index.anidb[String(e.anidb_id)] = mal;
  }
  return index.shows.length > 1000 ? index : null;   // a list this short is not the list
}

let memory: { index: AnimeIndex; byTvdb: Map<number, ShowRow[]>; byTmdb: Map<number, ShowRow[]> } | null = null;
let loading: Promise<void> | null = null;
let lastTry = 0;

function remember(index: AnimeIndex) {
  const byTvdb = new Map<number, ShowRow[]>(), byTmdb = new Map<number, ShowRow[]>();
  for (const row of index.shows) {
    if (row[1]) byTvdb.set(row[1], [...(byTvdb.get(row[1]) ?? []), row]);
    if (row[4]) byTmdb.set(row[4], [...(byTmdb.get(row[4]) ?? []), row]);
  }
  memory = { index, byTvdb, byTmdb };
}
/** For the checks: use this index as it is. */
export function setAnimeIndex(index: AnimeIndex | null) { if (index) remember(index); else { memory = null; lastTry = 0; } }

function validIndex(v: unknown): v is AnimeIndex {
  const o = v as AnimeIndex | null;
  return !!o && typeof o === "object" && typeof o.at === "number" && Array.isArray(o.shows) && !!o.movieTmdb && !!o.movieImdb && !!o.anilist && !!o.anidb;
}

/** The index: from memory, else the saved one, downloaded again when it's a week old (a saved one stays in use when that fails). */
async function animeIndex(): Promise<typeof memory> {
  const fresh = (i: AnimeIndex) => Date.now() - i.at < INDEX_DAYS * 86_400_000;
  if (!memory) {
    try {
      const saved = JSON.parse(storage.get(INDEX_KEY) ?? "null") as unknown;
      if (validIndex(saved)) remember(saved);
    } catch { /* unreadable: downloaded again */ }
  }
  if (memory && fresh(memory.index)) return memory;
  if (!loading && Date.now() - lastTry > 10 * 60_000) {
    lastTry = Date.now();
    loading = (async () => {
      const abort = new AbortController();
      const timer = setTimeout(() => abort.abort(), 30_000);
      try {
        const r = await fetchImpl(ANIME_LIST, { signal: abort.signal });
        if (!r.ok) return;
        const index = buildAnimeIndex(await r.json(), Date.now());
        if (!index) return;
        remember(index);
        storage.set(INDEX_KEY, JSON.stringify(index));
      } catch { /* not reachable now: the saved one (if any) stays */ } finally {
        clearTimeout(timer);
        loading = null;
      }
    })();
  }
  if (loading) await loading;
  return memory;
}

// MARK: From a server title to MyAnimeList ID + episode

/** What the server knows about the title being played. */
export interface AnimeQuery {
  movie: boolean;
  tvdb?: number; tmdb?: number; imdb?: string;         // the series' (or movie's) IDs
  mal?: number; anilist?: number; anidb?: number;      // IDs from anime metadata plugins
  season?: number; episode?: number;
  /** The episode has its own TVDB ID: the server's numbers are most likely TVDB's. */
  tvdbNumbering?: boolean;
  /** Anime by the server's own account: an Anime / Anime Movies library, an "Anime" genre, or anime plugin IDs. */
  hint: boolean;
}

export interface AniSkipTarget { mal: number; episode: number }

function fromRows(rows: ShowRow[] | undefined, at: 1 | 4, season: number, episode: number): AniSkipTarget | null {
  let best: ShowRow | null = null;
  for (const row of rows ?? []) {
    const s = row[at + 1], offset = row[at + 2];
    if (s !== season || row[7] === 2 || offset >= episode) continue;
    if (!best || offset > best[at + 2] || (offset === best[at + 2] && row[7] < best[7])) best = row;
  }
  return best && best[0] ? { mal: best[0], episode: episode - best[at + 2] } : null;
}

/** Whether the title is anime, and where AniSkip would have it (most likely first). */
export function animeTargets(q: AnimeQuery, memo = memory): { anime: boolean; targets: AniSkipTarget[] } {
  const index = memo?.index;
  const targets: AniSkipTarget[] = [];
  const add = (t: AniSkipTarget | null) => { if (t && t.mal > 0 && t.episode > 0 && !targets.some((x) => x.mal === t.mal && x.episode === t.episode)) targets.push(t); };
  const direct = q.mal || (q.anilist && index?.anilist[String(q.anilist)]) || (q.anidb && index?.anidb[String(q.anidb)]) || 0;
  let known = q.hint || !!(q.mal || q.anilist || q.anidb);
  if (q.movie) {
    if (direct) add({ mal: direct, episode: 1 });
    const byTmdb = q.tmdb ? index?.movieTmdb[String(q.tmdb)] : undefined, byImdb = q.imdb ? index?.movieImdb[q.imdb] : undefined;
    if (byTmdb !== undefined || byImdb !== undefined) known = true;
    if (byTmdb) add({ mal: byTmdb, episode: 1 });
    if (byImdb) add({ mal: byImdb, episode: 1 });
    return { anime: known, targets };
  }
  const tvdbRows = q.tvdb ? memo?.byTvdb.get(q.tvdb) : undefined, tmdbRows = q.tmdb ? memo?.byTmdb.get(q.tmdb) : undefined;
  if (tvdbRows?.length || tmdbRows?.length) known = true;
  const season = q.season ?? -1, episode = q.episode ?? 0;
  if (episode < 1) return { anime: known, targets };
  // An anime plugin's ID names one entry: the series as the server has it, when it isn't a later season.
  if (direct && season <= 1) add({ mal: direct, episode });
  if (season >= 1) {
    const byTvdb = fromRows(tvdbRows, 1, season, episode), byTmdb = fromRows(tmdbRows, 4, season, episode);
    // The server's numbers are TVDB's or TMDB's; the more likely one first, the other after it.
    for (const t of q.tvdbNumbering === false ? [byTmdb, byTvdb] : [byTvdb, byTmdb]) add(t);
  }
  return { anime: known, targets };
}

// MARK: AniSkip

const TYPES: Record<string, SegmentType> = { op: "Intro", ed: "Outro", recap: "Recap", "mixed-op": "Intro", "mixed-ed": "Outro" };

export function aniSkipUrl(t: AniSkipTarget, durationMs: number): string {
  // The file's length picks the times made for a file of that length (0: unknown, the top-voted ones).
  const length = durationMs > 0 ? (durationMs / 1000).toFixed(3) : "0";
  return `${ANISKIP}/${t.mal}/${t.episode}?types=op&types=ed&types=mixed-op&types=mixed-ed&types=recap&episodeLength=${length}`;
}

type MakeSegment = (source: string, type: SegmentType, startMs: number | null, endMs: number | null) => MediaSegment | null;

/** AniSkip's answer: { found, results: [{ interval: { startTime, endTime }, skipType, episodeLength }] }, in seconds. */
export function parseAniSkip(body: unknown, make: MakeSegment): MediaSegment[] {
  if (!body || typeof body !== "object") return [];
  const results = (body as Record<string, unknown>).results;
  if (!Array.isArray(results)) return [];
  const plain: MediaSegment[] = [], mixed: MediaSegment[] = [];
  for (const r of results.slice(0, 12)) {
    if (!r || typeof r !== "object") continue;
    const o = r as Record<string, unknown>;
    const kind = typeof o.skipType === "string" ? o.skipType : "";
    const type = TYPES[kind];
    const interval = o.interval && typeof o.interval === "object" ? (o.interval as Record<string, unknown>) : null;
    if (!type || !interval) continue;
    const start = interval.startTime, end = interval.endTime;
    if (typeof start !== "number" || typeof end !== "number" || !Number.isFinite(start) || !Number.isFinite(end) || start < 0 || end <= start) continue;
    const seg = make("aniskip", type, start * 1000, end * 1000);
    if (seg) (kind.startsWith("mixed") ? mixed : plain).push(seg);
  }
  // An opening or ending mixed with the story only stands in when there's no plain one.
  const have = new Set(plain.map((s) => s.Type));
  return [...plain, ...mixed.filter((s) => !have.has(s.Type))];
}

/** Whether the title is anime (with the list when it can be had), and its AniSkip segments. */
export async function aniSkipSegments(q: AnimeQuery, durationMs: number, make: MakeSegment): Promise<{ anime: boolean; segments: MediaSegment[]; complete: boolean }> {
  const { anime, targets } = animeTargets(q, await animeIndex());
  if (!anime) return { anime, segments: [], complete: true };
  let complete = true;
  for (const t of targets.slice(0, 3)) {
    const abort = new AbortController();
    const timer = setTimeout(() => abort.abort(), 8000);
    try {
      const r = await fetchImpl(aniSkipUrl(t, durationMs), { headers: { Accept: "application/json" }, signal: abort.signal });
      if (r.status === 404 || r.status === 400) continue;   // no times for this entry / episode
      if (!r.ok) { complete = false; continue; }
      const segments = parseAniSkip(await r.json(), make);
      if (segments.length) return { anime, segments, complete: true };
    } catch {
      complete = false;
    } finally {
      clearTimeout(timer);
    }
  }
  return { anime, segments: [], complete };
}
