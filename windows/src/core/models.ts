// AniList data shapes and the season rules, ported from the iOS app (Models.swift).

export interface MediaTitle {
  romaji?: string | null;
  english?: string | null;
  native?: string | null;
  userPreferred?: string | null;
}

export interface CoverImage {
  large?: string | null;
  extraLarge?: string | null;
  color?: string | null;
}

export interface AiringEpisode {
  episode: number;
  airingAt: number;
  timeUntilAiring: number;
}

export interface MediaTag {
  name: string;
  rank?: number | null;
  isMediaSpoiler?: boolean | null;
  category?: string | null;
}

export interface RelationNode {
  id: number;
  type?: string | null;
  format?: string | null;
  episodes?: number | null;
  title?: MediaTitle | null;
  /** Only on the details page's relations. */
  coverImage?: CoverImage | null;
}

export interface MediaRelations {
  edges?: { relationType?: string | null; node?: RelationNode | null }[] | null;
}

export interface Media {
  id: number;
  idMal?: number | null;
  title: MediaTitle;
  coverImage?: CoverImage | null;
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
  nextAiringEpisode?: AiringEpisode | null;
  description?: string | null;
  tags?: MediaTag[] | null;
  relations?: MediaRelations | null;
}

export type TitleLanguage = "english" | "romaji" | "native";

export const TITLE_LANGUAGES: { id: TitleLanguage; label: string }[] = [
  { id: "english", label: "English" },
  { id: "romaji", label: "Romaji" },
  { id: "native", label: "Native (日本語)" },
];

export function displayTitle(m: { title: MediaTitle }, lang: TitleLanguage): string {
  const t = m.title;
  switch (lang) {
    case "english":
      return t.english ?? t.romaji ?? t.userPreferred ?? t.native ?? "Untitled";
    case "romaji":
      return t.romaji ?? t.english ?? t.userPreferred ?? t.native ?? "Untitled";
    case "native":
      return t.native ?? t.romaji ?? t.english ?? t.userPreferred ?? "Untitled";
  }
}

export const coverURL = (m: Media) => m.coverImage?.extraLarge ?? m.coverImage?.large ?? undefined;
export const thumbURL = (m: Media) => m.coverImage?.large ?? m.coverImage?.extraLarge ?? undefined;

/** Episodes a viewer can currently watch. */
export function availableEpisodes(m: Media): number | undefined {
  if (m.nextAiringEpisode) return Math.max(0, m.nextAiringEpisode.episode - 1);
  if (m.status === "FINISHED") return m.episodes ?? undefined;
  return undefined;
}

export function plainDescription(m: Media): string {
  let text = m.description ?? "";
  if (!text) return "No synopsis available.";
  text = text.replace(/<br\s*\/?>/gi, "\n").replace(/<[^>]+>/g, "");
  const entities: Record<string, string> = {
    "&quot;": '"', "&amp;": "&", "&#039;": "'", "&apos;": "'", "&lt;": "<", "&gt;": ">",
    "&mdash;": "—", "&ndash;": "–", "&hellip;": "…",
  };
  for (const [k, v] of Object.entries(entities)) text = text.split(k).join(v);
  while (text.includes("\n\n\n")) text = text.split("\n\n\n").join("\n\n");
  return text.trim();
}

const capitalized = (s: string) => s.toLowerCase().replace(/(^|[\s_])\w/g, (c) => c.toUpperCase());

export function formatLabel(m: Media): string {
  switch (m.format) {
    case "TV": return "TV";
    case "TV_SHORT": return "TV Short";
    case "MOVIE": return "Movie";
    case "SPECIAL": return "Special";
    case "OVA": return "OVA";
    case "ONA": return "ONA";
    case "MUSIC": return "Music";
    default: return m.format ? capitalized(m.format) : "—";
  }
}

export function statusLabel(m: Media): string {
  switch (m.status) {
    case "RELEASING": return "Airing";
    case "FINISHED": return "Finished";
    case "NOT_YET_RELEASED": return "Upcoming";
    case "CANCELLED": return "Cancelled";
    case "HIATUS": return "Hiatus";
    default: return m.status ? capitalized(m.status) : "—";
  }
}

export function seasonLabel(m: Media): string | undefined {
  if (!m.season || !m.seasonYear) return m.seasonYear ? String(m.seasonYear) : undefined;
  return `${capitalized(m.season)} ${m.seasonYear}`;
}

/** Movies only appear when you search for them (and on your own lists). */
export const isMovie = (m: Media) => m.format === "MOVIE";

export const visibleTags = (m: Media) => (m.tags ?? []).filter((t) => t.isMediaSpoiler !== true);

// MARK: Seasons

const SERIES = new Set(["TV", "TV_SHORT", "ONA"]);

export const Seasons = {
  normalized(s?: string | null): string {
    return (s ?? "").toLowerCase().replace(/[^\p{L}\p{N}]/gu, "");
  },

  /** Same base title: "Slime 2nd Season" vs "Slime". */
  sameShow(a?: MediaTitle | null, b?: MediaTitle | null): boolean {
    const pairs: [string | null | undefined, string | null | undefined][] = [
      [a?.romaji, b?.romaji],
      [a?.english, b?.english],
    ];
    for (const [x, y] of pairs) {
      const p = [...Seasons.normalized(x)];
      const q = [...Seasons.normalized(y)];
      if (!p.length || !q.length) continue;
      let common = 0;
      while (common < p.length && common < q.length && p[common] === q[common]) common++;
      const shorter = Math.min(p.length, q.length);
      if (common >= Math.min(shorter, Math.max(8, Math.floor((shorter * 6) / 10)))) return true;
    }
    return false;
  },

  isSeries: (format?: string | null) => !!format && SERIES.has(format),

  /** A real season: TV/ONA with at least 3 episodes (or unknown, e.g. airing). */
  isSeason: (format?: string | null, episodes?: number | null) =>
    Seasons.isSeries(format) && (episodes ?? 3) >= 3,

  words(s?: string | null): string[] {
    return (s ?? "").toLowerCase().split(/[^\p{L}\p{N}]+/u).filter(Boolean);
  },

  split(title?: string | null): { base: string[]; marked: boolean } {
    const w = Seasons.words(title);
    const original = w.length;
    let changed = true;
    while (changed && w.length > 1) {
      changed = false;
      const last = w[w.length - 1];
      const before = w.length > 2 ? w[w.length - 2] : "";
      if (isCount(last, before)) {
        if (UNITS.has(before)) w.splice(w.length - 2, 2); else w.pop();
        changed = true;
      } else if (UNITS.has(last) && isOrdinal(before)) {
        w.splice(w.length - 2, 2);
        if (w.length > 1 && w[w.length - 1] === "the") w.pop();
        changed = true;
      }
    }
    return { base: w, marked: w.length < original };
  },

  hasSeasonMarker: (t?: MediaTitle | null) => Seasons.split(t?.romaji).marked || Seasons.split(t?.english).marked,

  /** "KonoSuba 3": only used together with a same-show prequel. */
  endsWithSeasonNumber(t?: MediaTitle | null): boolean {
    for (const title of [t?.romaji, t?.english]) {
      const w = Seasons.words(title);
      if (w.length > 1) {
        const n = Number(w[w.length - 1]);
        if (/^\d+$/.test(w[w.length - 1]) && n >= 2 && n <= 20) return true;
      }
    }
    return false;
  },
};

// "v"/"x" left out on purpose: too many titles end in a letter X or V that isn't a season.
const ROMANS = new Set(["ii", "iii", "iv", "vi", "vii", "viii", "ix"]);
const UNITS = new Set(["season", "part", "cour"]);
const ORDINAL_WORDS = new Set(["second", "third", "fourth", "fifth", "sixth", "final"]);

function isCount(w: string, before: string): boolean {
  if (ROMANS.has(w)) return true;
  if (/^\d+$/.test(w)) {
    const n = Number(w);
    if (n >= 1 && n <= 20 && UNITS.has(before)) return true;
  }
  return false;
}

function isOrdinal(w: string): boolean {
  if (ORDINAL_WORDS.has(w)) return true;
  if (w.length < 3) return false;
  const num = w.slice(0, -2);
  if (!/^\d+$/.test(num) || Number(num) < 1) return false;
  return ["st", "nd", "rd", "th"].includes(w.slice(-2));
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
        const key = s.base.join(" ");
        (s.marked ? this.seasons : this.plain).add(key);
      }
    }
  }

  contains(media: Media): boolean {
    if (!Seasons.isSeries(media.format)) return false;
    for (const title of [media.title.romaji, media.title.english]) {
      const s = Seasons.split(title);
      if (!s.base.length) continue;
      const key = s.base.join(" ");
      if (this.seasons.has(key) || (s.marked && this.plain.has(key))) return true;
    }
    return false;
  }
}

function sameShowPrequels(m: Media) {
  return (m.relations?.edges ?? []).filter((e) => {
    if (e.relationType !== "PREQUEL" || !e.node) return false;
    return (e.node.type == null || e.node.type === "ANIME") && Seasons.sameShow(m.title, e.node.title);
  });
}

/** The entry right before this one in the same franchise (any format). */
export function prequelId(m: Media): number | undefined {
  const edges = sameShowPrequels(m);
  return (edges.find((e) => Seasons.isSeries(e.node?.format)) ?? edges[0])?.node?.id;
}

export const isSeason = (m: Media) => Seasons.isSeason(m.format, m.episodes);

/** A TV/ONA entry that continues an earlier entry of the same show. */
export function isLaterSeason(m: Media): boolean {
  if (!isSeason(m)) return false;
  const prequels = sameShowPrequels(m);
  if (prequels.some((e) => Seasons.isSeason(e.node?.format, e.node?.episodes))) return true;
  return prequels.length > 0 && (Seasons.hasSeasonMarker(m.title) || Seasons.endsWithSeasonNumber(m.title));
}

// MARK: List entries

export type ListStatus = "CURRENT" | "PLANNING" | "COMPLETED" | "PAUSED" | "DROPPED" | "REPEATING";

export const LIST_STATUSES: ListStatus[] = ["CURRENT", "PLANNING", "COMPLETED", "PAUSED", "DROPPED", "REPEATING"];

export const statusName: Record<ListStatus, string> = {
  CURRENT: "Watching",
  PLANNING: "Planning",
  COMPLETED: "Completed",
  PAUSED: "Paused",
  DROPPED: "Dropped",
  REPEATING: "Rewatching",
};

export const statusIcon: Record<ListStatus, string> = {
  CURRENT: "play",
  PLANNING: "bookmark",
  COMPLETED: "check",
  PAUSED: "pause",
  DROPPED: "x",
  REPEATING: "repeat",
};

export interface ListEntry {
  id: number;
  mediaId: number;
  status: ListStatus;
  score?: number | null;
  progress?: number | null;
  updatedAt?: number | null;
  createdAt?: number | null;
  media: Media;
}

export interface EntryLite {
  id: number;
  mediaId: number;
  status?: ListStatus | null;
  score?: number | null;
  progress?: number | null;
  updatedAt?: number | null;
}

export const scoreValue = (e: { score?: number | null }) => e.score ?? 0;
export const progressValue = (e: { progress?: number | null }) => e.progress ?? 0;

// MARK: User

export interface Viewer {
  id: number;
  name: string;
  avatar?: { large?: string | null } | null;
  bannerImage?: string | null;
  options?: { titleLanguage?: string | null; displayAdultContent?: boolean | null } | null;
  statistics?: { anime?: { count?: number; episodesWatched?: number; meanScore?: number; minutesWatched?: number } | null } | null;
}

// MARK: Details

export interface RelationEdge {
  relationType?: string | null;
  node?: RelationNode | null;
}

export const relationLabel = (e: RelationEdge) => capitalized((e.relationType ?? "Related").replace(/_/g, " "));

export interface MediaDetail extends Media {
  studios?: { nodes?: { name: string }[] | null } | null;
  recommendations?: { nodes?: { rating?: number | null; mediaRecommendation?: Media | null }[] | null } | null;
  mediaListEntry?: EntryLite | null;
}

// MARK: Categories

export interface AnimeCategory {
  name: string;
  kind: "genre" | "tag";
}

export const categoryId = (c: AnimeCategory) => `${c.kind}:${c.name}`;
export const genre = (name: string): AnimeCategory => ({ name, kind: "genre" });
export const tag = (name: string): AnimeCategory => ({ name, kind: "tag" });

export const FEATURED_CATEGORIES: AnimeCategory[] = [
  tag("Isekai"), genre("Romance"), genre("Ecchi"), genre("Action"), genre("Fantasy"),
  tag("Reincarnation"), tag("Harem"), genre("Comedy"), tag("Magic"), tag("Super Power"),
  genre("Adventure"), genre("Slice of Life"), tag("School"), genre("Drama"), tag("Demons"),
  genre("Mystery"), genre("Psychological"), genre("Sci-Fi"), tag("Revenge"), genre("Supernatural"),
  genre("Horror"), genre("Sports"), genre("Mecha"), genre("Thriller"), genre("Hentai"),
];

/** AniList's adult genre: its shows appear only where this category is picked. */
export const isAdultOnly = (c?: AnimeCategory | null) => !!c && c.kind === "genre" && c.name === "Hentai";

export function categoryMatches(c: AnimeCategory, m: Media): boolean {
  if (c.kind === "genre") return (m.genres ?? []).includes(c.name);
  return (m.tags ?? []).some((t) => t.name === c.name && (t.rank ?? 0) >= 45);
}

export const categoryVariables = (c: AnimeCategory): Record<string, unknown> =>
  c.kind === "genre" ? { genres: [c.name] } : { tags: [c.name] };

export function currentSeason(offset = 0, date = new Date()): { season: string; year: number } {
  const seasons = ["WINTER", "SPRING", "SUMMER", "FALL"];
  let year = date.getFullYear();
  let index = Math.floor(date.getMonth() / 3) + offset;
  while (index > 3) { index -= 4; year += 1; }
  while (index < 0) { index += 4; year -= 1; }
  return { season: seasons[index], year };
}
