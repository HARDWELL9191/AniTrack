// Titles from TMDB that aren't on your server (For You picks), in exactly the shape the iPhone app
// (JellyReco for iOS) saves them, so My List / Not for me / Already seen sync between the two.
//
// The iPhone decodes these with Swift's Codable, which is strict: every non-optional field must be
// present (source, sourceId, title, overview, genres, tags, isAdult) and one bad entry makes the
// whole list unreadable. Everything written from here goes through `externalTitle()` /
// `listEntry*()` so it always has every required field with the right type.

export type TitleSource = "tmdbMovie" | "tmdbTV";

/** Swift `ExternalTitle` (JellyReco/AI/External/ExternalTitle.swift). */
export interface ExternalTitle {
  source: TitleSource;
  sourceId: number;
  title: string;
  originalTitle?: string | null;
  originalLanguage?: string | null;
  year?: number | null;
  overview: string;
  genres: string[];
  tags: string[];
  posterURL?: string | null; // full https URL (Swift URL)
  backdropURL?: string | null;
  score?: number | null; // TMDB user score 0–10
  voteCount?: number | null;
  popularity?: number | null;
  episodes?: number | null;
  seasons?: number | null;
  runtime?: number | null; // minutes
  imdbId?: string | null;
  tvdbId?: number | null;
  status?: string | null;
  isAdult: boolean;
}

/** Swift `MyListEntry` (JellyReco/App/MyList.swift): a title on your server or a For You pick. */
export interface MyListEntry {
  serverId?: string | null;
  name?: string | null;
  external?: ExternalTitle | null;
  /** Swift Date as JSONEncoder writes it by default: seconds since 2001-01-01 00:00 UTC. */
  addedAt: number;
}

/** "tmdbTV:1429" / "tmdbMovie:603" (the iPhone's id). */
export const titleId = (t: { source: TitleSource; sourceId: number }) => `${t.source}:${t.sourceId}`;
export const isMovie = (t: ExternalTitle) => t.source === "tmdbMovie";
export const isAnime = (t: ExternalTitle) => t.originalLanguage === "ja" && t.genres.includes("Animation");
export const tmdbWebUrl = (t: ExternalTitle) => `https://www.themoviedb.org/${isMovie(t) ? "movie" : "tv"}/${t.sourceId}`;

/** My List entry id, as on the iPhone ("server:<id>" or the title id). */
export const entryId = (e: MyListEntry) => (e.serverId ? `server:${e.serverId}` : e.external ? titleId(e.external) : `x:${e.addedAt}`);

const SWIFT_EPOCH = Date.UTC(2001, 0, 1) / 1000;
export const swiftNow = () => Date.now() / 1000 - SWIFT_EPOCH;
export const fromSwiftDate = (s: number) => new Date((s + SWIFT_EPOCH) * 1000);

export const IMAGE_BASE = "https://image.tmdb.org/t/p/";
/** A TMDB image at another size (the saved URLs are w500 posters and w1280 backdrops). */
export function resized(url: string | null | undefined, size: string): string | undefined {
  if (!url) return undefined;
  return url.replace(/\/t\/p\/(w\d+|original)\//, `/t/p/${size}/`);
}

export function metaLine(t: ExternalTitle): string {
  const parts: string[] = [isAnime(t) ? (isMovie(t) ? "Anime movie" : "Anime") : isMovie(t) ? "Movie" : "TV show"];
  if (t.year) parts.push(String(t.year));
  if (t.seasons && !isMovie(t)) parts.push(t.seasons === 1 ? "1 season" : `${t.seasons} seasons`);
  if (t.runtime && isMovie(t) && t.runtime > 0) parts.push(t.runtime >= 60 ? `${Math.floor(t.runtime / 60)}h ${t.runtime % 60}m` : `${t.runtime}m`);
  return parts.join(" · ");
}

const num = (v: unknown) => (typeof v === "number" && Number.isFinite(v) ? v : null);
const int = (v: unknown) => (typeof v === "number" && Number.isFinite(v) ? Math.round(v) : null);
const str = (v: unknown) => (typeof v === "string" ? v : null);
const strs = (v: unknown) => (Array.isArray(v) ? v.filter((x): x is string => typeof x === "string") : []);

/** A complete, valid ExternalTitle from anything (drops what Swift couldn't read). */
export function externalTitle(raw: unknown): ExternalTitle | null {
  if (!raw || typeof raw !== "object") return null;
  const r = raw as Record<string, unknown>;
  const source = r.source === "tmdbMovie" || r.source === "tmdbTV" ? (r.source as TitleSource) : null;
  const sourceId = int(r.sourceId);
  if (!source || sourceId === null) return null;
  const t: ExternalTitle = {
    source, sourceId,
    title: str(r.title) ?? "Untitled",
    overview: str(r.overview) ?? "",
    genres: strs(r.genres),
    tags: strs(r.tags),
    isAdult: r.isAdult === true,
  };
  // Optionals only when they have a value (Swift writes nothing for nil).
  const opt: [keyof ExternalTitle, unknown][] = [
    ["originalTitle", str(r.originalTitle)], ["originalLanguage", str(r.originalLanguage)], ["year", int(r.year)],
    ["posterURL", str(r.posterURL)], ["backdropURL", str(r.backdropURL)], ["score", num(r.score)], ["voteCount", int(r.voteCount)],
    ["popularity", num(r.popularity)], ["episodes", int(r.episodes)], ["seasons", int(r.seasons)], ["runtime", int(r.runtime)],
    ["imdbId", str(r.imdbId)], ["tvdbId", int(r.tvdbId)], ["status", str(r.status)],
  ];
  for (const [k, v] of opt) if (v !== null && v !== undefined) (t as unknown as Record<string, unknown>)[k] = v;
  return t;
}

/** What the iPhone keeps of a title in a list (overview ≤ 400 characters, ≤ 8 tags). */
export function slim(t: ExternalTitle): ExternalTitle {
  return { ...t, overview: t.overview.slice(0, 400), tags: t.tags.slice(0, 8) };
}

export function listEntryForServer(serverId: string, name?: string | null): MyListEntry {
  return { serverId, name: name ?? null, addedAt: swiftNow() };
}
export function listEntryForTitle(t: ExternalTitle): MyListEntry {
  return { external: slim(t), name: t.title, addedAt: swiftNow() };
}

export function myListEntry(raw: unknown): MyListEntry | null {
  if (!raw || typeof raw !== "object") return null;
  const r = raw as Record<string, unknown>;
  const external = r.external != null ? externalTitle(r.external) : null;
  const serverId = str(r.serverId);
  if (!serverId && !external) return null;
  const e: MyListEntry = { addedAt: num(r.addedAt) ?? swiftNow() };
  if (serverId) e.serverId = serverId;
  if (str(r.name)) e.name = str(r.name);
  if (external) e.external = external;
  return e;
}

/** For writing: only keys with values, like Swift's encoder. */
export function encodeEntry(e: MyListEntry): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  if (e.serverId) out.serverId = e.serverId;
  if (e.name) out.name = e.name;
  if (e.external) out.external = slim(e.external);
  out.addedAt = e.addedAt;
  return out;
}

// MARK: Title matching (the iPhone's TitleKey)

const TAIL = /\b(\d+(st|nd|rd|th)\s+season|season\s*\d*|part\s*\d+|cour\s*\d+|final season|the movie)\b.*$/i;

/** "Mushoku Tensei: Jobless Reincarnation Season 2" → "mushokutenseijoblessreincarnation". */
export function titleKey(s: string): string {
  let t = s.normalize("NFKC").toLowerCase().normalize("NFKD").replace(/\p{M}+/gu, "");
  t = t.replace(TAIL, "");
  return (t.match(/[\p{L}\p{N}]/gu) ?? []).join("");
}
