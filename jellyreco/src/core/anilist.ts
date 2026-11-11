// For You on the Anime / Anime Movies libraries, the AniReco way (the same engine as the iPhone
// app's JellyReco/AniList/*.swift, which is AniReco's): picks are learned from your AniList list
// (fan recommendations from the shows you rated, your genre/tag taste, on-device AI), shows only
// for Anime and movies only for Anime Movies, and never anything already on your server.
//
// This file has no app dependencies (only titles.ts), so CI runs it in Node against live AniList
// (tools/anilist_check.ts).

import { Queries } from "./anilistQueries.ts";
import { type ExternalTitle, titleKey } from "./titles.ts";

// MARK: Types (AniList's, as the iPhone decodes them)

export interface MediaTitle { romaji?: string | null; english?: string | null; native?: string | null; userPreferred?: string | null }
export interface MediaTag { name: string; rank?: number | null; isMediaSpoiler?: boolean | null; category?: string | null }
export interface RelationNode { id: number; type?: string | null; format?: string | null; episodes?: number | null; title?: MediaTitle | null }
export interface Media {
  id: number;
  idMal?: number | null;
  title: MediaTitle;
  coverImage?: { large?: string | null; extraLarge?: string | null; color?: string | null } | null;
  bannerImage?: string | null;
  format?: string | null;
  status?: string | null;
  episodes?: number | null;
  duration?: number | null;
  season?: string | null;
  seasonYear?: number | null;
  averageScore?: number | null;
  meanScore?: number | null;
  popularity?: number | null;
  genres?: string[] | null;
  countryOfOrigin?: string | null;
  isAdult?: boolean | null;
  siteUrl?: string | null;
  nextAiringEpisode?: { episode: number; airingAt: number; timeUntilAiring: number } | null;
  description?: string | null;
  tags?: MediaTag[] | null;
  relations?: { edges?: { relationType?: string | null; node?: RelationNode | null }[] | null } | null;
}
export type ListStatus = "CURRENT" | "PLANNING" | "COMPLETED" | "PAUSED" | "DROPPED" | "REPEATING";
export interface ListEntry { id: number; mediaId: number; status: ListStatus; score?: number | null; progress?: number | null; updatedAt?: number | null; createdAt?: number | null; media: Media }
export interface EntryLite { id: number; mediaId: number; status?: ListStatus | null; score?: number | null; progress?: number | null; updatedAt?: number | null }
export interface Viewer { id: number; name: string; avatar?: { large?: string | null } | null; options?: { titleLanguage?: string | null } | null }
export type TitleLanguage = "english" | "romaji" | "native";

// MARK: Media helpers

export function displayTitle(m: Media, lang: TitleLanguage): string {
  const t = m.title;
  if (lang === "english") return t.english ?? t.romaji ?? t.userPreferred ?? t.native ?? "Untitled";
  if (lang === "native") return t.native ?? t.romaji ?? t.english ?? t.userPreferred ?? "Untitled";
  return t.romaji ?? t.english ?? t.userPreferred ?? t.native ?? "Untitled";
}
export const languageFromOption = (o: string | null | undefined): TitleLanguage => {
  const u = (o ?? "").toUpperCase();
  return u.startsWith("ENGLISH") ? "english" : u.startsWith("NATIVE") ? "native" : "romaji";
};
export const isMovieMedia = (m: Media) => m.format === "MOVIE";
export const coverURL = (m: Media) => m.coverImage?.extraLarge ?? m.coverImage?.large ?? null;
export const visibleTags = (m: Media) => (m.tags ?? []).filter((t) => t.isMediaSpoiler !== true);
export const availableEpisodes = (m: Media) => (m.nextAiringEpisode ? Math.max(0, m.nextAiringEpisode.episode - 1) : m.status === "FINISHED" ? m.episodes ?? null : null);
export const allTitles = (m: Media) => [m.title.english, m.title.romaji, m.title.native, m.title.userPreferred].filter((x): x is string => !!x);

export function plainDescription(m: Media): string {
  let text = m.description ?? "";
  if (!text) return "No synopsis available.";
  text = text.replace(/<br\s*\/?>/gi, "\n").replace(/<[^>]+>/g, "");
  const entities: Record<string, string> = { "&quot;": "\"", "&amp;": "&", "&#039;": "'", "&apos;": "'", "&lt;": "<", "&gt;": ">", "&mdash;": "—", "&ndash;": "–", "&hellip;": "…" };
  for (const [k, v] of Object.entries(entities)) text = text.split(k).join(v);
  while (text.includes("\n\n\n")) text = text.split("\n\n\n").join("\n\n");
  return text.trim();
}

export function statusLabel(m: Media): string | null {
  switch (m.status) {
    case "RELEASING": return "Airing";
    case "FINISHED": return "Finished";
    case "NOT_YET_RELEASED": return "Upcoming";
    case "CANCELLED": return "Cancelled";
    case "HIATUS": return "Hiatus";
    default: return m.status ? m.status[0] + m.status.slice(1).toLowerCase() : null;
  }
}

// MARK: Seasons (one pick per show: numbered TV seasons collapse into the first one)

const SERIES_FORMATS = new Set(["TV", "TV_SHORT", "ONA"]);
const normalizedTitle = (s?: string | null) => (s ?? "").toLowerCase().replace(/[^\p{L}\p{N}]/gu, "");
const words = (s?: string | null) => (s ?? "").toLowerCase().split(/[^\p{L}\p{N}]+/u).filter(Boolean);
const ROMANS = new Set(["ii", "iii", "iv", "vi", "vii", "viii", "ix"]);
const UNITS = new Set(["season", "part", "cour"]);
const ORDINAL_WORDS = new Set(["second", "third", "fourth", "fifth", "sixth", "final"]);

export const Seasons = {
  isSeries: (format?: string | null) => !!format && SERIES_FORMATS.has(format),
  isSeason: (format?: string | null, episodes?: number | null) => Seasons.isSeries(format) && (episodes ?? 3) >= 3,
  /** Same base title: "Tensei shitara Slime Datta Ken 2nd Season" vs "Tensei shitara Slime Datta Ken". */
  sameShow(a?: MediaTitle | null, b?: MediaTitle | null): boolean {
    for (const [x, y] of [[a?.romaji, b?.romaji], [a?.english, b?.english]] as const) {
      const p = [...normalizedTitle(x)], q = [...normalizedTitle(y)];
      if (!p.length || !q.length) continue;
      let common = 0;
      while (common < p.length && common < q.length && p[common] === q[common]) common++;
      const shorter = Math.min(p.length, q.length);
      if (common >= Math.min(shorter, Math.max(8, Math.floor((shorter * 6) / 10)))) return true;
    }
    return false;
  },
  /** Title words with trailing season markers removed, and whether any were found. */
  split(title?: string | null): { base: string[]; marked: boolean } {
    const w = words(title);
    const original = w.length;
    const isCount = (x: string, before: string) => ROMANS.has(x) || (/^\d+$/.test(x) && Number(x) >= 1 && Number(x) <= 20 && UNITS.has(before));
    const isOrdinal = (x: string) => ORDINAL_WORDS.has(x) || (x.length >= 3 && /^\d+$/.test(x.slice(0, -2)) && Number(x.slice(0, -2)) >= 1 && ["st", "nd", "rd", "th"].includes(x.slice(-2)));
    let changed = true;
    while (changed && w.length > 1) {
      changed = false;
      const last = w[w.length - 1];
      const before = w.length > 2 ? w[w.length - 2] : "";
      if (isCount(last, before)) {
        w.splice(UNITS.has(before) ? -2 : -1);
        changed = true;
      } else if (UNITS.has(last) && isOrdinal(before)) {
        w.splice(-2);
        if (w.length > 1 && w[w.length - 1] === "the") w.pop();
        changed = true;
      }
    }
    return { base: w, marked: w.length < original };
  },
  hasSeasonMarker: (t?: MediaTitle | null) => Seasons.split(t?.romaji).marked || Seasons.split(t?.english).marked,
  endsWithSeasonNumber(t?: MediaTitle | null) {
    for (const title of [t?.romaji, t?.english]) {
      const w = words(title);
      if (w.length > 1 && /^\d+$/.test(w[w.length - 1]) && Number(w[w.length - 1]) >= 2 && Number(w[w.length - 1]) <= 20) return true;
    }
    return false;
  },
};

const prequels = (m: Media) => (m.relations?.edges ?? []).filter((e) => e.relationType === "PREQUEL" && e.node && (e.node.type == null || e.node.type === "ANIME") && Seasons.sameShow(m.title, e.node.title));
export const isSeasonMedia = (m: Media) => Seasons.isSeason(m.format, m.episodes);
export function prequelId(m: Media): number | null {
  const edges = prequels(m);
  return (edges.find((e) => Seasons.isSeries(e.node?.format)) ?? edges[0])?.node?.id ?? null;
}
/** A TV/ONA entry that continues an earlier entry of the same show (Season 2+). */
export function isLaterSeason(m: Media): boolean {
  if (!isSeasonMedia(m)) return false;
  const p = prequels(m);
  if (p.some((e) => Seasons.isSeason(e.node?.format, e.node?.episodes))) return true;
  return p.length > 0 && (Seasons.hasSeasonMarker(m.title) || Seasons.endsWithSeasonNumber(m.title));
}

/** TV/ONA shows on your list by base title, so other seasons of them aren't suggested. */
export class ListFranchises {
  private plain = new Set<string>();
  private seasons = new Set<string>();
  constructor(media: Media[] = []) {
    for (const m of media) {
      if (!Seasons.isSeries(m.format)) continue;
      for (const title of [m.title.romaji, m.title.english]) {
        const s = Seasons.split(title);
        if (!s.base.length) continue;
        (s.marked ? this.seasons : this.plain).add(s.base.join(" "));
      }
    }
  }
  contains(m: Media): boolean {
    if (!Seasons.isSeries(m.format)) return false;
    for (const title of [m.title.romaji, m.title.english]) {
      const s = Seasons.split(title);
      if (!s.base.length) continue;
      const key = s.base.join(" ");
      if (this.seasons.has(key) || (s.marked && this.plain.has(key))) return true;
    }
    return false;
  }
}

// MARK: Categories (AniList genres and tags)

export interface AnimeCategory { name: string; kind: "genre" | "tag" }
export const categoryId = (c: AnimeCategory) => `${c.kind}:${c.name}`;
const g = (name: string): AnimeCategory => ({ name, kind: "genre" });
const t = (name: string): AnimeCategory => ({ name, kind: "tag" });
/** AniReco's quick picks (anything AniList doesn't know is filtered out at run time). */
export const FEATURED: AnimeCategory[] = [
  t("Isekai"), g("Romance"), g("Ecchi"), g("Action"), g("Fantasy"), t("Reincarnation"), t("Harem"), g("Comedy"), t("Magic"), t("Super Power"),
  g("Adventure"), g("Slice of Life"), t("School"), g("Drama"), t("Demons"), g("Mystery"), g("Psychological"), g("Sci-Fi"), t("Revenge"), g("Supernatural"),
  g("Horror"), g("Sports"), g("Mecha"), g("Thriller"), g("Hentai"),
];
export const isAdultOnly = (c: AnimeCategory | null | undefined) => !!c && c.kind === "genre" && c.name === "Hentai";
export const categoryMatches = (c: AnimeCategory, m: Media) => (c.kind === "genre" ? !!m.genres?.includes(c.name) : !!m.tags?.some((x) => x.name === c.name && (x.rank ?? 0) >= 45));
const browseVariables = (c: AnimeCategory): Record<string, unknown> => (c.kind === "genre" ? { genres: [c.name] } : { tags: [c.name] });

// MARK: Client

type FetchFn = (url: string, init?: RequestInit) => Promise<Response>;
let fetchImpl: FetchFn = (url, init) => fetch(url, init);
/** The app sends AniList and Kitsu requests through Tauri's HTTP client (no browser CORS). */
export const setAniListFetch = (f: FetchFn) => (fetchImpl = f);

export class AniListError extends Error {
  status: number;
  constructor(message: string, status = 0) { super(message); this.status = status; }
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

export class AniListClient {
  token: string | null = null;

  /** `waitOnRateLimit: false`: give up at once when AniList is busy (optional lookups). */
  async run<T>(query: string, variables: Record<string, unknown> = {}, waitOnRateLimit = true): Promise<T> {
    const mutation = query.trim().startsWith("mutation");
    for (let attempt = 1; ; attempt++) {
      let res: Response;
      try {
        res = await fetchImpl("https://graphql.anilist.co", {
          method: "POST",
          headers: { "Content-Type": "application/json", Accept: "application/json", ...(this.token ? { Authorization: `Bearer ${this.token}` } : {}) },
          body: JSON.stringify({ query, variables }),
        });
      } catch (e) {
        // One quiet retry for a dropped connection (reads only: a change is never sent twice).
        if (attempt < 2 && !mutation) { await sleep(1000); continue; }
        throw new AniListError(`Couldn't reach AniList: ${(e as Error).message}`);
      }
      if (res.status === 429) {
        if (!waitOnRateLimit || attempt >= 4) throw new AniListError("AniList rate limit reached. Try again in a minute.", 429);
        const retry = Number(res.headers.get("Retry-After")) || 5;
        await sleep(Math.min(retry, 65) * 1000);
        continue;
      }
      let body: { data?: T | null; errors?: { message: string }[] } | null = null;
      try { body = await res.json(); } catch { /* not JSON */ }
      if (body?.data) return body.data;
      if (body?.errors?.length) throw new AniListError(body.errors.map((e) => e.message).join("\n"), res.status);
      throw new AniListError(res.status >= 400 ? `AniList returned HTTP ${res.status}.` : "AniList returned no data.", res.status);
    }
  }
}

export const isAuthError = (e: unknown) => e instanceof AniListError && (e.status === 401 || /invalid token|unauthori[sz]ed/i.test(e.message));

// MARK: Saved first seasons (later season → first season), so feeds don't look them up again

interface KV { get(key: string): string | null; set(key: string, value: string): void }
const memoryKV = (): KV => { const m = new Map<string, string>(); return { get: (k) => m.get(k) ?? null, set: (k, v) => void m.set(k, v) }; };
let kv: KV = (() => {
  try {
    if (typeof localStorage !== "undefined") return { get: (k: string) => localStorage.getItem(k), set: (k: string, v: string) => { try { localStorage.setItem(k, v); } catch { /* full */ } } };
  } catch { /* no storage */ }
  return memoryKV();
})();
export const setAniListStorage = (s: KV) => (kv = s);

interface SavedRoot { root: Media; later: Media; chain: number[]; savedAt: number }
const ROOTS_KEY = "anilist-season-roots-v2";
const ROOTS_MAX_AGE = 7 * 86_400_000;
const seasonMedia = new Map<number, Media>();
let roots: Map<number, SavedRoot> | null = null;
let rootsTimer: ReturnType<typeof setTimeout> | null = null;
function loadRoots(): Map<number, SavedRoot> {
  if (roots) return roots;
  roots = new Map();
  try { for (const [k, v] of Object.entries(JSON.parse(kv.get(ROOTS_KEY) ?? "{}") as Record<string, SavedRoot>)) roots.set(Number(k), v); } catch { /* */ }
  return roots;
}
function storeRoots(found: { later: Media; root: Media; chain: number[] }[]) {
  if (!found.length) return;
  const r = loadRoots();
  if (r.size > 3000) r.clear();
  for (const f of found) r.set(f.later.id, { root: f.root, later: f.later, chain: f.chain, savedAt: Date.now() });
  if (rootsTimer) clearTimeout(rootsTimer);
  rootsTimer = setTimeout(() => kv.set(ROOTS_KEY, JSON.stringify(Object.fromEntries(r))), 2000);
}
const savedRoot = (id: number) => { const s = loadRoots().get(id); return s && Date.now() - s.savedAt < ROOTS_MAX_AGE ? s : null; };
const laterSeasonsOf = (rootId: number) => [...loadRoots().values()].filter((s) => s.root.id === rootId && Date.now() - s.savedAt < ROOTS_MAX_AGE).map((s) => s.later);

interface Found { root: Media | null; chain: number[]; complete: boolean }

export const SeasonRoots = {
  /** First seasons for these later seasons: saved answers first, the rest by walking prequels. */
  async resolve(later: Media[], start: Map<number, Media>, client: AniListClient, waitOnRateLimit: boolean): Promise<Map<number, Found>> {
    const result = new Map<number, Found>();
    const toWalk: Media[] = [];
    for (const m of later) {
      const s = savedRoot(m.id);
      if (s) result.set(m.id, { root: s.root, chain: s.chain, complete: true }); else toWalk.push(m);
    }
    if (!toWalk.length) return result;
    const known = new Map<number, Media>([...seasonMedia, ...start]);
    const walk = (m: Media) => {
      const visited = new Set([m.id]);
      const chain: number[] = [];
      let current = m;
      let root: Media | null = null;
      for (let prev = prequelId(current); prev !== null && visited.size < 15 && !visited.has(prev); prev = prequelId(current)) {
        visited.add(prev);
        const earlier = known.get(prev);
        if (!earlier) return { root, chain, next: prev as number | null };
        chain.push(earlier.id);
        if (isSeasonMedia(earlier)) root = earlier;
        current = earlier;
      }
      return { root, chain, next: null as number | null };
    };
    for (let hop = 0; hop < 10; hop++) {
      const missing = [...new Set(toWalk.map((m) => walk(m).next).filter((x): x is number => x !== null))];
      if (!missing.length) break;
      const fetched: Media[] = [];
      for (let i = 0; i < missing.length; i += 50) {
        const chunk = missing.slice(i, i + 50);
        try {
          const data = await client.run<{ Page: { media: Media[] } }>(Queries.mediaByIds, { ids: chunk, perPage: chunk.length }, waitOnRateLimit);
          for (const m of data.Page.media) { known.set(m.id, m); fetched.push(m); }
        } catch { /* offline or busy: use what we have */ }
      }
      if (!fetched.length) break;
      if (seasonMedia.size > 1500) seasonMedia.clear();
      for (const m of fetched) seasonMedia.set(m.id, m);
    }
    const complete: { later: Media; root: Media; chain: number[] }[] = [];
    for (const m of toWalk) {
      const w = walk(m);
      result.set(m.id, { root: w.root, chain: w.chain, complete: w.next === null });
      if (w.root && w.next === null) complete.push({ later: m, root: w.root, chain: w.chain });
    }
    storeRoots(complete);
    return result;
  },

  /** Same order, each later season replaced by its first season, no duplicates. */
  async collapse(items: Media[], client: AniListClient): Promise<Media[]> {
    const later = items.filter(isLaterSeason);
    if (!later.length) return items;
    const found = await SeasonRoots.resolve(later, new Map(items.map((m) => [m.id, m])), client, false);
    const seen = new Set<number>();
    const out: Media[] = [];
    for (const m of items) { const shown = found.get(m.id)?.root ?? m; if (!seen.has(shown.id)) { seen.add(shown.id); out.push(shown); } }
    return out;
  },
};

/** The TV/ONA seasons of a show, in order (for planning / completing every season). */
export async function seasonChain(media: Media, client: AniListClient): Promise<Media[]> {
  const link = (m: Media, type: string) => {
    const edges = (m.relations?.edges ?? []).filter((e) => e.relationType === type && (e.node?.type == null || e.node?.type === "ANIME"));
    return (edges.find((e) => Seasons.isSeries(e.node?.format)) ?? edges[0])?.node?.id ?? null;
  };
  const known = new Map<number, Media>([[media.id, media]]);
  const visited = new Set([media.id]);
  const before: Media[] = [], after: Media[] = [];
  let back = link(media, "PREQUEL"), forward = link(media, "SEQUEL");
  for (let i = 0; i < 12; i++) {
    const wanted = [back, forward].filter((x): x is number => x !== null && !known.has(x));
    if (wanted.length) {
      try {
        const data = await client.run<{ Page: { media: Media[] } }>(Queries.mediaByIds, { ids: wanted, perPage: wanted.length });
        for (const m of data.Page.media) known.set(m.id, m);
      } catch { break; }
    }
    let moved = false;
    const b = back !== null && !visited.has(back) ? known.get(back) : undefined;
    if (b) { visited.add(b.id); if (isSeasonMedia(b)) before.unshift(b); back = link(b, "PREQUEL"); moved = true; } else back = null;
    const f = forward !== null && !visited.has(forward) ? known.get(forward) : undefined;
    if (f) { visited.add(f.id); if (isSeasonMedia(f)) after.push(f); forward = link(f, "SEQUEL"); moved = true; } else forward = null;
    if (!moved) break;
  }
  let result = [...before, media, ...after];
  // Seasons tied together by the first-season lookups (Dragon Ball → Z → GT, and Super).
  const rootIds = [result[0].id];
  const extras: Media[] = [];
  for (const m of result) { const s = savedRoot(m.id); if (s && !rootIds.includes(s.root.id)) { rootIds.push(s.root.id); extras.push(s.root); } }
  for (const id of rootIds) extras.push(...laterSeasonsOf(id));
  const present = new Set(result.map((m) => m.id));
  const added = extras.filter((m, i) => !present.has(m.id) && isSeasonMedia(m) && extras.findIndex((x) => x.id === m.id) === i);
  if (added.length) {
    const order: Record<string, number> = { WINTER: 0, SPRING: 1, SUMMER: 2, FALL: 3 };
    const key = (m: Media) => [m.seasonYear ?? Number.MAX_SAFE_INTEGER, order[m.season ?? ""] ?? 4, m.id];
    result = [...result, ...added].sort((a, b) => { const ka = key(a), kb = key(b); return ka[0] - kb[0] || ka[1] - kb[1] || ka[2] - kb[2]; });
  }
  return result;
}

// MARK: What's on your Jellyfin server (never picked)

export interface OwnedItem { Name?: string | null; OriginalTitle?: string | null; ProductionYear?: number | null; Type?: string | null; ProviderIds?: Record<string, string | null | undefined> | null }

/** Indexed every way an AniList show could match it: the AniList / MyAnimeList id Jellyfin stored
 *  (anime metadata plugins), then any of its titles. Shows match by name, movies within a year. */
export class AniListOwnedIndex<T extends OwnedItem = OwnedItem> {
  private anilistIds = new Map<number, T>();
  private malIds = new Map<number, T>();
  private showTitles = new Map<string, T>();
  private movieTitles = new Map<string, { year: number | null; item: T }[]>();

  constructor(items: T[] = []) {
    for (const i of items) {
      if (i.Type !== "Series" && i.Type !== "Movie") continue;
      const provider = (...names: string[]) => {
        for (const [k, v] of Object.entries(i.ProviderIds ?? {})) if (names.some((n) => n.toLowerCase() === k.toLowerCase()) && Number(v)) return Number(v);
        return null;
      };
      const a = provider("AniList"); if (a && !this.anilistIds.has(a)) this.anilistIds.set(a, i);
      const mal = provider("MyAnimeList", "Mal"); if (mal && !this.malIds.has(mal)) this.malIds.set(mal, i);
      for (const name of [i.Name, i.OriginalTitle]) {
        if (!name) continue;
        const key = titleKey(name);
        if (key.length < 3) continue;
        if (i.Type === "Series") { if (!this.showTitles.has(key)) this.showTitles.set(key, i); }
        else this.movieTitles.set(key, [...(this.movieTitles.get(key) ?? []), { year: i.ProductionYear ?? null, item: i }]);
      }
    }
  }

  get isEmpty() { return !this.anilistIds.size && !this.malIds.size && !this.showTitles.size && !this.movieTitles.size; }

  private byNames(names: (string | null | undefined)[], movie: boolean, year: number | null | undefined): T | undefined {
    for (const name of names) {
      if (!name) continue;
      const key = titleKey(name);
      if (key.length < 3) continue;
      if (movie) {
        const hit = this.movieTitles.get(key)?.find((x) => !year || x.year === null || Math.abs(x.year - year) <= 1);
        if (hit) return hit.item;
      } else {
        const hit = this.showTitles.get(key);
        if (hit) return hit;
      }
    }
    return undefined;
  }

  /** The server title that is this AniList show (if you have it). */
  find(m: Media): T | undefined {
    return this.anilistIds.get(m.id) ?? (m.idMal ? this.malIds.get(m.idMal) : undefined) ?? this.byNames(allTitles(m), isMovieMedia(m), m.seasonYear);
  }
  contains(m: Media): boolean { return !!this.find(m); }

  findTitle(x: ExternalTitle): T | undefined {
    if (x.source !== "anilist") return undefined;
    return this.anilistIds.get(x.sourceId) ?? this.byNames([x.title, x.originalTitle], x.format === "MOVIE", x.year);
  }
  containsTitle(x: ExternalTitle): boolean { return !!this.findTitle(x); }
}

/** The libraries named exactly "Anime" (shows) or "Anime Movies" (movies), any letter case. */
export type AniListLibrary = "shows" | "movies";
export function aniListLibrary(name: string | null | undefined): AniListLibrary | null {
  const n = (name ?? "").trim().toLowerCase().split(/\s+/).join(" ");
  return n === "anime" ? "shows" : n === "anime movies" ? "movies" : null;
}

// MARK: An AniList show shaped like a For You title (so the same cards and sheets show it)

export function anilistTitle(m: Media, lang: TitleLanguage): ExternalTitle {
  const shown = displayTitle(m, lang);
  const other = [m.title.romaji, m.title.english, m.title.native].find((x) => !!x && x !== shown) ?? null;
  const language = ({ JP: "ja", CN: "zh", KR: "ko", TW: "zh" } as Record<string, string>)[m.countryOfOrigin ?? ""] ?? null;
  const score = m.averageScore ?? m.meanScore;
  return {
    source: "anilist", sourceId: m.id, title: shown, originalTitle: other, originalLanguage: language, year: m.seasonYear ?? null,
    overview: plainDescription(m), genres: m.genres ?? [], tags: visibleTags(m).filter((x) => (x.rank ?? 0) >= 40).slice(0, 12).map((x) => x.name),
    posterURL: coverURL(m), backdropURL: m.bannerImage ?? null, score: score != null ? score / 10 : null, popularity: m.popularity ?? null,
    episodes: m.episodes ?? null, runtime: isMovieMedia(m) ? m.duration ?? null : null, status: statusLabel(m), isAdult: m.isAdult === true, format: m.format ?? null,
  };
}

// MARK: The recommender (AniReco's, round by round)

export interface Recommendation { media: Media; score: number; match: number; because: string[]; highlights: string[] }
export interface RecommendationResult { picks: Recommendation[]; generatedAt: number; fingerprint: number; usedAI: boolean; round: number; exhausted: boolean }

export interface RecoOptions {
  hideChinese: boolean;
  includeUnreleased: boolean;
  dismissed: Set<number>;
  titleLanguage: TitleLanguage;
  useAI: boolean;
  category: AnimeCategory | null;
  /** Anime Movies: movies only (Anime and AniReco itself: no movies). */
  movies: boolean;
  owned: { contains(m: Media): boolean };
  /** On-device AI: vectors by input key (the app's embedder); none = AI part skipped. */
  embed?: (inputs: { key: string; text: string }[]) => Promise<Map<string, Float32Array>>;
}

export const embeddingInput = (m: Media) => {
  const name = m.title.english ?? m.title.romaji ?? m.title.userPreferred ?? "";
  const text = `${name}. ${(m.genres ?? []).join(", ")}. ${visibleTags(m).slice(0, 6).map((x) => x.name).join(", ")}. ${plainDescription(m).slice(0, 500)}`;
  return { key: `anilist:${m.id}`, text };
};

/** FNV-1a of your list + settings: picks are rebuilt only when it changes. */
export function fingerprint(entries: ListEntry[], o: RecoOptions): number {
  let text = "";
  for (const e of [...entries].sort((a, b) => a.id - b.id)) text += `${e.id}:${e.status}:${Math.trunc(e.score ?? 0)};`;
  text += `|${o.hideChinese}|${o.includeUnreleased}|${o.useAI}|${o.category ? categoryId(o.category) : "any"}|${o.movies}|`;
  let h = 0x811c9dc5;
  for (const ch of new TextEncoder().encode(text)) { h ^= ch; h = Math.imul(h, 0x01000193) >>> 0; }
  return h;
}

class TasteProfile {
  features = new Map<string, number>();
  norm = 0;
  static vector(m: Media) {
    const v = new Map<string, number>();
    for (const genre of m.genres ?? []) v.set(`g:${genre}`, 1);
    for (const tag of m.tags ?? []) { const r = (tag.rank ?? 50) / 100; if (r >= 0.3) v.set(`t:${tag.name}`, r); }
    return v;
  }
  add(m: Media, w: number) { for (const [k, x] of TasteProfile.vector(m)) this.features.set(k, (this.features.get(k) ?? 0) + x * w); }
  finalize() { let s = 0; for (const x of this.features.values()) s += x * x; this.norm = Math.sqrt(s); }
  similarity(m: Media) {
    if (!(this.norm > 0)) return 0;
    const v = TasteProfile.vector(m);
    let vn = 0, dot = 0;
    for (const [k, x] of v) { vn += x * x; dot += x * (this.features.get(k) ?? 0); }
    return vn > 0 ? dot / (this.norm * Math.sqrt(vn)) : 0;
  }
  highlights(m: Media, limit = 3) {
    return [...TasteProfile.vector(m)].map(([k, x]) => [k, (this.features.get(k) ?? 0) * x] as const).filter(([, w]) => w > 0).sort((a, b) => b[1] - a[1]).slice(0, limit).map(([k]) => k.slice(2));
  }
  top(prefix: string, count: number) {
    return [...this.features].filter(([k, x]) => k.startsWith(prefix) && x > 0).sort((a, b) => b[1] - a[1]).slice(0, count).map(([k]) => k.slice(prefix.length));
  }
}

/** How strongly an entry says "I liked this" (positive) or "not for me" (negative). */
function entryWeight(e: ListEntry, mean: number, spread: number): number {
  const score = e.score ?? 0;
  if (score > 0) {
    if (e.status === "COMPLETED" || e.status === "REPEATING" || e.status === "PLANNING") { const x = Math.min(1, score / 100); return 0.3 + 1.7 * x * x; }
    if (e.status === "DROPPED") return -1 - 0.5 * (1 - Math.min(1, score / 100));
    return Math.min(2, Math.max(-1, (score - mean) / Math.max(spread, 8) + 0.6));
  }
  switch (e.status) {
    case "COMPLETED": case "REPEATING": return 0.7;
    case "CURRENT": case "PLANNING": return 0.5;
    case "PAUSED": return 0.1;
    default: return -1;
  }
}

const normalizedVec = (v: Float32Array) => { let s = 0; for (const x of v) s += x * x; const n = Math.sqrt(s); if (!(n > 0)) return v; const out = new Float32Array(v.length); for (let i = 0; i < v.length; i++) out[i] = v[i] / n; return out; };
const cosineVec = (a: Float32Array, b: Float32Array) => { if (a.length !== b.length || !a.length) return 0; let d = 0; for (let i = 0; i < a.length; i++) d += a[i] * b[i]; return d; };

/** New picks for `round` (1 = first screen). `exclude` holds ids already shown. */
export async function recommend(entries: ListEntry[], client: AniListClient, o: RecoOptions, round = 1, exclude = new Set<number>()): Promise<{ picks: Recommendation[]; usedAI: boolean }> {
  const scored = entries.map((e) => e.score ?? 0).filter((x) => x > 0);
  const mean = scored.length ? scored.reduce((a, b) => a + b, 0) / scored.length : 70;
  const spread = scored.length ? Math.sqrt(scored.reduce((a, x) => a + (x - mean) ** 2, 0) / scored.length) : 0;

  const profile = new TasteProfile();
  const weights = new Map<number, number>();
  for (const e of entries) { const w = entryWeight(e, mean, spread); weights.set(e.mediaId, w); if (w !== 0) profile.add(e.media, w); }
  profile.finalize();
  const onList = new Map<number, ListEntry>();
  for (const e of entries) if (!onList.has(e.mediaId)) onList.set(e.mediaId, e);

  // Seeds: your strongest likes (Planning included), newest first among equals.
  const seeds = entries.filter((e) => (weights.get(e.mediaId) ?? 0) > 0.3)
    .sort((a, b) => { const x = weights.get(a.mediaId) ?? 0, y = weights.get(b.mediaId) ?? 0; return x === y ? (b.updatedAt ?? 0) - (a.updatedAt ?? 0) : y - x; })
    .slice(0, 30);

  const collab = new Map<number, number>();
  const reasons = new Map<number, string[]>();
  let candidates = new Map<number, Media>();

  // 1) Fan recommendations from your top shows (deeper pages on later rounds).
  for (let i = 0; i < seeds.length; i += 6) {
    const ids = seeds.slice(i, i + 6).map((e) => e.mediaId);
    try {
      const data = await client.run<{ Page: { media: { id: number; recommendations?: { nodes?: { rating?: number | null; mediaRecommendation?: Media | null }[] | null } | null }[] } }>(
        Queries.seedRecommendations, { ids, perPage: ids.length, recsPage: round, recsPerMedia: 8 });
      for (const sm of data.Page.media) {
        const seed = onList.get(sm.id);
        if (!seed) continue;
        const seedWeight = weights.get(sm.id) ?? 0.5;
        const seedTitle = displayTitle(seed.media, o.titleLanguage);
        for (const node of sm.recommendations?.nodes ?? []) {
          const rec = node.mediaRecommendation;
          const rating = Math.max(node.rating ?? 0, 0);
          if (!rec || rec.id === sm.id || rating <= 0) continue;
          collab.set(rec.id, (collab.get(rec.id) ?? 0) + seedWeight * Math.log(1 + rating));
          candidates.set(rec.id, rec);
          const r = reasons.get(rec.id) ?? [];
          if (!r.includes(seedTitle)) r.push(seedTitle);
          reasons.set(rec.id, r);
        }
      }
    } catch (e) {
      if (i === 0 && round === 1) throw e;
    }
    await sleep(300);
  }

  // 2) Explore beyond what fans linked: your top tags/genres, and the chosen category.
  const topTags = profile.top("t:", 3);
  const topGenres = profile.top("g:", 2);
  const adultOnly = isAdultOnly(o.category);
  const base: Record<string, unknown> = { page: round, perPage: 40, isAdult: adultOnly, excludeIds: [...onList.keys()], ...(o.movies ? { formatIn: ["MOVIE"] } : { formatNot: ["MOVIE"] }) };
  const explorations: Record<string, unknown>[] = [];
  if (o.category) {
    explorations.push({ ...base, ...browseVariables(o.category), sort: ["SCORE_DESC"] }, { ...base, ...browseVariables(o.category), sort: ["POPULARITY_DESC"] });
    if (topTags[0] && o.category.kind === "genre") explorations.push({ ...base, ...browseVariables(o.category), tags: [topTags[0]], sort: ["SCORE_DESC"] });
  } else {
    if (topTags.length) explorations.push({ ...base, tags: topTags, sort: ["SCORE_DESC"] });
    if (topGenres.length) explorations.push({ ...base, genres: topGenres, sort: ["POPULARITY_DESC"], ...(topTags[0] ? { tags: [topTags[0]] } : {}) });
  }
  for (const vars of explorations) {
    try {
      const data = await client.run<{ Page: { media: Media[] } }>(Queries.browseWithRelations, vars);
      for (const m of data.Page.media) if (!candidates.has(m.id)) candidates.set(m.id, m);
    } catch { /* one failed exploration is fine */ }
    await sleep(300);
  }

  // 2b) One pick per show: Season 2+ becomes Season 1; shows you already have are skipped.
  const franchises = new ListFranchises([...onList.values()].map((e) => e.media));
  const later = [...candidates.values()].filter(isLaterSeason);
  const found = later.length ? await SeasonRoots.resolve(later, candidates, client, true) : new Map<number, Found>();
  const collapsed = new Map<number, Media>();
  for (const [id, m] of candidates) {
    if (franchises.contains(m)) continue;
    if (!isLaterSeason(m)) { if (!collapsed.has(id)) collapsed.set(id, m); continue; }
    const f = found.get(id);
    if (f?.chain.some((x) => onList.has(x))) continue;
    const root = f?.root ?? m;
    if (root.id !== id) {
      if (onList.has(root.id) || franchises.contains(root)) continue;
      collab.set(root.id, (collab.get(root.id) ?? 0) + (collab.get(id) ?? 0));
      const r = reasons.get(root.id) ?? [];
      for (const reason of reasons.get(id) ?? []) if (!r.includes(reason)) r.push(reason);
      reasons.set(root.id, r);
    }
    collapsed.set(root.id, root);
  }
  candidates = collapsed;

  // 3) Cheap first pass (no AI) to pick a short list worth spending the AI work on.
  const maxCollab = Math.max(...collab.values(), 0.0001);
  const allowed = (m: Media) => {
    if (onList.has(m.id) || exclude.has(m.id)) return false;
    if (m.isAdult === true && !adultOnly) return false;
    if (o.hideChinese && m.countryOfOrigin === "CN") return false;
    if (m.format === "MUSIC") return false;
    if (o.movies !== isMovieMedia(m)) return false;
    if (o.owned.contains(m)) return false;
    if (!o.includeUnreleased && m.status === "NOT_YET_RELEASED") return false;
    if (o.dismissed.has(m.id)) return false;
    if (o.category && !categoryMatches(o.category, m)) return false;
    return true;
  };
  const shortList = [...candidates].filter(([, m]) => allowed(m)).map(([id, m]) => {
    const c = (collab.get(id) ?? 0) / maxCollab;
    const sim = Math.max(0, profile.similarity(m));
    const quality = (m.averageScore ?? m.meanScore ?? 60) / 100;
    return { media: m, collab: c, tagSim: sim, quality, score: 0.5 * c + 0.38 * sim + 0.12 * quality };
  }).sort((a, b) => b.score - a.score).slice(0, 80);

  // 4) On-device semantic re-rank (synopses of your strongest likes/dislikes vs the short list).
  let usedAI = false;
  let ranked = shortList.map((s) => ({ media: s.media, score: s.score }));
  if (o.useAI && o.embed && shortList.length) {
    const anchors = entries.filter((e) => Math.abs(weights.get(e.mediaId) ?? 0) >= 0.4)
      .sort((a, b) => Math.abs(weights.get(b.mediaId) ?? 0) - Math.abs(weights.get(a.mediaId) ?? 0)).slice(0, 40).map((e) => e.media);
    const vectors = await o.embed([...anchors, ...shortList.map((s) => s.media)].map(embeddingInput)).catch(() => new Map<string, Float32Array>());
    let taste: Float32Array | null = null;
    for (const m of anchors) {
      const v = vectors.get(`anilist:${m.id}`);
      if (!v) continue;
      if (!taste) taste = new Float32Array(v.length);
      const w = weights.get(m.id) ?? 0;
      for (let i = 0; i < v.length && i < taste.length; i++) taste[i] += v[i] * w;
    }
    if (taste) {
      const tv = normalizedVec(taste);
      const sims = shortList.map((s) => { const v = vectors.get(`anilist:${s.media.id}`); return v ? cosineVec(tv, v) : null; });
      const known = sims.filter((x): x is number => x !== null);
      if (known.length) {
        const lo = Math.min(...known), hi = Math.max(...known);
        const span = Math.max(hi - lo, 0.0001);
        ranked = shortList.map((s, i) => {
          const semantic = sims[i] !== null ? ((sims[i] as number) - lo) / span : 0.5;
          return { media: s.media, score: 0.38 * s.collab + 0.24 * s.tagSim + 0.28 * semantic + 0.1 * s.quality };
        });
        usedAI = true;
      }
    }
  }
  ranked.sort((a, b) => b.score - a.score);
  const top = Math.max(ranked[0]?.score ?? 1, 0.0001);
  const roundPenalty = (round - 1) * 0.04;
  const picks = ranked.slice(0, 40).map((r) => ({
    media: r.media,
    score: r.score,
    match: Math.round(Math.max(0.5, Math.min(0.99, 0.55 + 0.44 * (r.score / top) - roundPenalty)) * 100),
    because: (reasons.get(r.media.id) ?? []).slice(0, 3),
    highlights: profile.highlights(r.media),
  }));
  return { picks, usedAI };
}

// MARK: Kitsu age ratings (as in AniReco): PG / 13+ / 17+ / 18+

export interface AgeRating { code?: string | null; guide?: string | null }
export function ageLabel(r: AgeRating | null | undefined): string | null {
  switch (r?.code?.toUpperCase()) {
    case "R18": return "18+";
    case "R": return "17+";
    case "PG": return r.guide?.toLowerCase().includes("13") ? "13+" : "PG";
    case "G": return "PG";
    default: return null;
  }
}
export function ageExplanation(r: AgeRating | null | undefined): string | null {
  const label = ageLabel(r);
  if (!label) return null;
  const guide = r?.guide?.trim();
  if (guide) return `${label} · ${guide}`;
  return ({ G: "PG · All ages", PG: "PG · Parental guidance", R: "17+ · Restricted", R18: "18+ · Adults only" } as Record<string, string>)[r?.code?.toUpperCase() ?? ""] ?? label;
}

const KITSU_KEY = "anilist-kitsu-ratings-v1";
interface KitsuSaved { rating: AgeRating | null; checkedAt: number }
let kitsu: Map<number, KitsuSaved> | null = null;
const kitsuMap = () => { if (!kitsu) { kitsu = new Map(); try { for (const [k, v] of Object.entries(JSON.parse(kv.get(KITSU_KEY) ?? "{}") as Record<string, KitsuSaved>)) kitsu.set(Number(k), v); } catch { /* */ } } return kitsu; };

/** Kitsu's ratings by AniList id (MyAnimeList id as backup), 10 per request, saved for good;
 *  a show without one is checked again after a day. `failed`: Kitsu couldn't be reached. */
export async function kitsuRatings(lookups: { id: number; mal?: number | null }[]): Promise<{ found: Map<number, AgeRating>; failed: boolean }> {
  const saved = kitsuMap();
  const found = new Map<number, AgeRating>();
  const toFetch: { id: number; mal?: number | null }[] = [];
  for (const l of lookups) {
    const s = saved.get(l.id);
    if (s?.rating) { found.set(l.id, s.rating); continue; }
    if (s && Date.now() - s.checkedAt < 86_400_000) continue;
    if (!toFetch.some((x) => x.id === l.id)) toFetch.push(l);
  }
  const fetchSite = async (site: string, ids: number[]) => {
    const url = `https://kitsu.app/api/edge/mappings?filter%5BexternalSite%5D=${site}&filter%5BexternalId%5D=${ids.join(",")}&include=item&page%5Blimit%5D=20&fields%5Banime%5D=ageRating,ageRatingGuide`;
    const res = await fetchImpl(url, { headers: { Accept: "application/vnd.api+json" } });
    if (res.status !== 200) throw new Error(`Kitsu ${res.status}`);
    const body = (await res.json()) as {
      data?: { attributes?: { externalId?: string }; relationships?: { item?: { data?: { id: string; type: string } | null } } }[];
      included?: { id: string; type: string; attributes?: { ageRating?: string | null; ageRatingGuide?: string | null } }[];
    };
    const byKitsu = new Map<string, AgeRating>();
    for (const inc of body.included ?? []) if (inc.type === "anime") byKitsu.set(inc.id, { code: inc.attributes?.ageRating ?? null, guide: inc.attributes?.ageRatingGuide ?? null });
    const out = new Map<number, AgeRating | null>();
    for (const row of body.data ?? []) {
      const ext = Number(row.attributes?.externalId);
      const item = row.relationships?.item?.data;
      if (!ext || !item || item.type !== "anime" || out.has(ext)) continue;
      const r = byKitsu.get(item.id) ?? null;
      out.set(ext, ageLabel(r) ? r : null);
    }
    return out;
  };
  let failed = false;
  for (let i = 0; i < toFetch.length; i += 10) {
    const chunk = toFetch.slice(i, i + 10);
    try {
      const got = await fetchSite("anilist/anime", chunk.map((x) => x.id));
      const unlinked = chunk.filter((x) => !got.has(x.id) && x.mal);
      if (unlinked.length) {
        const byMal = await fetchSite("myanimelist/anime", unlinked.map((x) => x.mal as number)).catch(() => new Map<number, AgeRating | null>());
        for (const x of unlinked) if (byMal.has(x.mal as number)) got.set(x.id, byMal.get(x.mal as number) ?? null);
      }
      for (const x of chunk) {
        const r = got.get(x.id) ?? null;
        saved.set(x.id, { rating: r, checkedAt: Date.now() });
        if (r) found.set(x.id, r);
      }
    } catch { failed = true; break; }
  }
  if (toFetch.length) kv.set(KITSU_KEY, JSON.stringify(Object.fromEntries(saved)));
  return { found, failed };
}
