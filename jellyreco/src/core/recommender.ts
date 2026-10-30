// For You (AniReco's recommender, for a Jellyfin library):
// - Picks are shows and movies you DON'T have yet, from TMDB (anime included), never anything on
//   your server, on Watch later, marked Not for me, or already seen.
// - Your taste comes from your server: completed and in-progress titles, favorites, likes,
//   ratings, Watch later and "already watched" picks.
// Score = TMDB recommendations/similar for the titles you liked (the "fans also liked" signal) +
// genre/language match to your taste + on-device overview similarity (bge-small on the Snapdragon
// NPU) + rating, shown as a match %.
// Also here: "More like this" for a details page, from your own library with the on-device AI.
// Everything here only reads: Jellyfin through a read-only handle, TMDB with GETs.

import { accumulate, cosine, getEmbedder, normalized, vectorsFor } from "./ai";
import type { Jellyfin } from "./api";
import type { ListEntry } from "./lists";
import { Tmdb, type TmdbItem, type TmdbKind, tmdbKey, tmdbVectorId } from "./tmdb";
import type { Item } from "./types";

export interface Pick {
  key: string;
  tmdb: TmdbItem;
  score: number;
  match: number;
  because: string[]; // titles you watched that it's close to
  highlights: string[]; // genres you like that it has
  genres: string[];
}

export interface Feed {
  picks: Pick[];
  generatedAt: number;
  usedAI: boolean;
  exhausted: boolean;
  /** Genres for the chosen library (second dropdown). */
  categories: { name: string; count: number }[];
  watchedCount: number;
  error?: string;
}

export interface LibraryInfo { id: string; name: string; count: number; kind: TmdbKind | "both"; anime: boolean }

export interface Library {
  /** Every series and movie in the libraries For You uses, with the library each lives in. */
  items: Item[];
  libraryOf: Map<string, string>;
  /** The libraries For You offers (first dropdown); "placeholder"/"playlist(s)" ones left out. */
  libraries: LibraryInfo[];
  /** Everything on the server (all video libraries), so it's never recommended. */
  owned: { tmdb: Set<string>; titles: Set<string> };
  loadedAt: number;
}

const FIELDS = ["Genres", "Tags", "Studios", "Overview", "ProductionYear", "ProviderIds", "OriginalTitle", "ProductionLocations", "ParentId", "RecursiveItemCount", "DateCreated", "PrimaryImageAspectRatio"];
const KANA = /[぀-ヿ]/;

/** Libraries named "placeholder" (anywhere in the name), "playlist" or "playlists" never appear in For You. */
export const isPlaceholder = (name?: string | null) => /placeholder/i.test(name ?? "") || /^\s*playlists?\s*$/i.test(name ?? "");

const videoLibrary = (v: Item) => !v.CollectionType || ["tvshows", "movies", "mixed", "homevideos"].includes(v.CollectionType);

/** The libraries For You can draw from: TV, movie and mixed ones, except placeholders/playlists. */
export function pickableViews(views: Item[]): Item[] {
  return views.filter((v) => videoLibrary(v) && v.CollectionType !== "playlists" && !isPlaceholder(v.Name));
}

export function normTitle(s?: string | null): string {
  return (s ?? "").toLowerCase().normalize("NFKD").replace(/[̀-ͯ]/g, "").replace(/&/g, "and").replace(/[^a-z0-9぀-ヿ一-鿿]+/g, " ").replace(/\b(the|a|an)\b/g, " ").replace(/\s+/g, " ").trim();
}

const yearOf = (d?: string | null) => (d ? Number(d.slice(0, 4)) || null : null);

function looksAnime(i: Item): boolean {
  const g = (i.Genres ?? []).map((x) => x.toLowerCase());
  if (g.includes("anime")) return true;
  if (!g.includes("animation")) return false;
  return (i.ProductionLocations ?? []).some((p) => /japan/i.test(p)) || KANA.test(i.OriginalTitle ?? "") || !!(i.ProviderIds?.AniDB || i.ProviderIds?.AniList || i.ProviderIds?.AniSearch);
}

/** Loads every series and movie (paged). All video libraries count as owned; only pickable ones are offered. */
export async function loadLibrary(api: Jellyfin, views: Item[]): Promise<Library> {
  const all = views.filter(videoLibrary);
  const pickable = new Set(pickableViews(views).map((v) => v.Id));
  const items: Item[] = [];
  const libraryOf = new Map<string, string>();
  const libraries: LibraryInfo[] = [];
  const owned = { tmdb: new Set<string>(), titles: new Set<string>() };
  for (const lib of all) {
    const mine: Item[] = [];
    let start = 0;
    for (;;) {
      const r = await api.items({
        parentId: lib.Id, recursive: true, includeItemTypes: ["Series", "Movie"], fields: FIELDS, enableUserData: true,
        enableImageTypes: ["Primary", "Backdrop", "Thumb"], imageTypeLimit: 1, startIndex: start, limit: 500, sortBy: ["SortName"],
      });
      mine.push(...r.Items);
      start += r.Items.length;
      if (!r.Items.length || start >= r.TotalRecordCount) break;
    }
    for (const i of mine) {
      const kind: TmdbKind = i.Type === "Movie" ? "movie" : "tv";
      const t = i.ProviderIds?.Tmdb;
      if (t) owned.tmdb.add(`tmdb:${kind}:${t}`);
      const y = i.ProductionYear;
      for (const name of [i.Name, i.OriginalTitle]) {
        const n = normTitle(name);
        if (n) { owned.titles.add(`${kind}|${n}`); if (y) owned.titles.add(`${kind}|${n}|${y}`); }
      }
      if (pickable.has(lib.Id) && !libraryOf.has(i.Id)) { libraryOf.set(i.Id, lib.Id); items.push(i); }
    }
    if (pickable.has(lib.Id)) {
      const movies = mine.filter((i) => i.Type === "Movie").length;
      const kind: LibraryInfo["kind"] = lib.CollectionType === "movies" ? "movie" : lib.CollectionType === "tvshows" ? "tv" : movies > mine.length * 0.8 ? "movie" : movies < mine.length * 0.2 ? "tv" : "both";
      const animeShare = mine.length ? mine.filter(looksAnime).length / mine.length : 0;
      libraries.push({ id: lib.Id, name: lib.Name ?? "Library", count: mine.length, kind, anime: /anime|アニメ/i.test(lib.Name ?? "") || animeShare >= 0.5 });
    }
  }
  return { items, libraryOf, libraries, owned, loadedAt: Date.now() };
}

/** The first dropdown's default: the library called "Anime", else everything. */
export function defaultLibrary(lib: Library): string {
  return lib.libraries.find((l) => l.name.trim().toLowerCase() === "anime")?.id ?? "all";
}

export const isAnimeTmdb = (t: TmdbItem) => t.genreIds.includes(16) && (t.originalLanguage === "ja" || (t.originCountry ?? []).includes("JP"));

/** On your server already (by TMDB id, else title + year): never recommended. */
export function isOwned(t: TmdbItem, lib: Library): boolean {
  if (lib.owned.tmdb.has(tmdbKey(t))) return true;
  const y = yearOf(t.date);
  for (const name of [t.title, t.originalTitle]) {
    const n = normTitle(name);
    if (!n) continue;
    if (y && (lib.owned.titles.has(`${t.kind}|${n}|${y}`) || lib.owned.titles.has(`${t.kind}|${n}|${y - 1}`) || lib.owned.titles.has(`${t.kind}|${n}|${y + 1}`))) return true;
    if (!y && lib.owned.titles.has(`${t.kind}|${n}`)) return true;
  }
  return false;
}

// MARK: Taste

export class TasteProfile {
  features = new Map<string, number>();
  norm = 0;

  /** Local items: genres, tags and studios. */
  static vector(i: Item): Map<string, number> {
    const v = new Map<string, number>();
    for (const g of i.Genres ?? []) v.set("g:" + g.toLowerCase(), 1);
    for (const t of (i.Tags ?? []).slice(0, 20)) v.set("t:" + t.toLowerCase(), 0.6);
    for (const s of (i.Studios ?? []).slice(0, 3)) if (s.Name) v.set("s:" + s.Name.toLowerCase(), 0.45);
    return v;
  }

  add(v: Map<string, number>, weight: number) {
    for (const [k, value] of v) this.features.set(k, (this.features.get(k) ?? 0) + value * weight);
  }

  finalize() {
    let s = 0;
    for (const v of this.features.values()) s += v * v;
    this.norm = Math.sqrt(s);
  }

  /** Cosine with a feature vector, optionally leaving out an item's own share (weight w). */
  similarityTo(v: Map<string, number>, w = 0): number {
    if (!(this.norm > 0)) return 0;
    let vn = 0;
    for (const x of v.values()) vn += x * x;
    vn = Math.sqrt(vn);
    if (!(vn > 0)) return 0;
    let normSq = this.norm * this.norm;
    let dot = 0;
    for (const [k, value] of v) {
      const f = this.features.get(k) ?? 0;
      const without = f - value * w;
      normSq += without * without - f * f;
      dot += value * without;
    }
    if (!(normSq > 1e-9)) return 0;
    return dot / (Math.sqrt(normSq) * vn);
  }

  highlights(v: Map<string, number>, names: Map<string, string>, limit = 3): string[] {
    return [...v].map(([k, x]) => [k, (this.features.get(k) ?? 0) * x] as const).filter(([, w]) => w > 0).sort((a, b) => b[1] - a[1]).slice(0, limit).map(([k]) => names.get(k) ?? k.slice(2));
  }
}

/** Genres (and language) of a TMDB title, in the same feature space as local items' genres. */
function tmdbVector(t: TmdbItem, genreNames: Map<number, string>): Map<string, number> {
  const v = new Map<string, number>();
  for (const id of t.genreIds) { const g = genreNames.get(id); if (g) v.set("g:" + g.toLowerCase(), 1); }
  if (t.originalLanguage) v.set("l:" + t.originalLanguage, 0.5);
  return v;
}

function genreLanguageVector(i: Item): Map<string, number> {
  const v = new Map<string, number>();
  for (const g of i.Genres ?? []) v.set("g:" + g.toLowerCase(), 1);
  if (looksAnime(i)) v.set("l:ja", 0.5);
  else if ((i.ProductionLocations ?? []).some((p) => /united states|united kingdom|canada|australia/i.test(p))) v.set("l:en", 0.5);
  return v;
}

/** How strongly your history says "I liked this" (positive) or "not for me" (negative). */
export function historyWeight(i: Item, dismissed: Set<string>, watchLater?: Set<string>): number {
  if (dismissed.has(i.Id)) return -1.0;
  const ud = i.UserData;
  if (!ud) return watchLater?.has(i.Id) ? 0.5 : 0;
  if (ud.Likes === false) return -1.0;
  let w = 0;
  if (i.Type === "Series") {
    const total = i.RecursiveItemCount ?? 0;
    const left = ud.UnplayedItemCount ?? total;
    const watched = total ? Math.max(0, total - left) : 0;
    const fraction = total ? watched / total : ud.Played ? 1 : 0;
    if (ud.Played || fraction >= 0.95) w = 0.75; // completed
    else if (watched > 0) {
      const last = ud.LastPlayedDate ? Date.parse(ud.LastPlayedDate) : 0;
      const stale = last && Date.now() - last > 120 * 86_400_000;
      // Watching now counts; a few episodes long ago and never finished is a weak "maybe not".
      w = stale ? (fraction < 0.25 ? -0.15 : 0.15) : 0.25 + 0.4 * fraction;
    }
  } else {
    if (ud.Played) w = 0.75;
    else if ((ud.PlayedPercentage ?? 0) > 60) w = 0.5;
    else if ((ud.PlaybackPositionTicks ?? 0) > 0) w = 0.2;
  }
  if (typeof ud.Rating === "number" && ud.Rating > 0) {
    const t = Math.min(1, ud.Rating / 10);
    w = 0.3 + 1.7 * t * t; // like AniReco's scored entries
  }
  if (ud.Likes === true) w = Math.max(w, 1.4);
  if (ud.IsFavorite) w = Math.max(w, ud.Played || w > 0.2 ? 1.6 : 0.6);
  if (watchLater?.has(i.Id) && w >= 0 && w < 0.5) w = 0.5; // Watch later = AniReco's Plan to watch
  return w;
}

export interface RecOptions {
  libraryId: string; // a library id or "all"
  category: string; // genre name, "" = all
  minRating: number;
  dismissed: Set<string>; // Jellyfin ids marked Not for me this session
  watchLater: ListEntry[];
  notForMe: ListEntry[]; // TMDB titles you passed on
  seen: ListEntry[]; // TMDB titles you've watched elsewhere
  useAI: boolean;
  exclude: Set<string>; // keys already shown this session
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** The value, or null if it takes longer than `ms` (the work itself carries on in the background). */
export function withTimeout<T>(p: Promise<T>, ms: number): Promise<T | null> {
  return new Promise((resolve, reject) => {
    const t = setTimeout(() => resolve(null), ms);
    p.then((v) => { clearTimeout(t); resolve(v); }, (e) => { clearTimeout(t); reject(e); });
  });
}

/** How long For You waits for the on-device AI. Its first start (compiling the model for the NPU)
 * can take longer; it finishes in the background and the next build uses it. */
export const AI_WAIT_MS = 25_000;
/** After a wait ran out, later builds only wait briefly until the AI has finished starting. */
let aiTimedOutAt = 0;
const aiWait = () => (Date.now() - aiTimedOutAt < 120_000 ? 3_000 : AI_WAIT_MS);

/** Builds a batch of picks (40). `round` > 1 digs deeper (next pages). */
export async function recommend(api: Jellyfin, tmdb: Tmdb, lib: Library, o: RecOptions, round = 1, stage: (text: string) => void = () => {}): Promise<Feed> {
  void api; // reads go through `lib` (already loaded) and TMDB; kept for symmetry with moreLikeThis
  stage("Asking TMDB for titles like yours…");
  const info = o.libraryId === "all" ? null : lib.libraries.find((l) => l.id === o.libraryId) ?? null;
  const kinds: TmdbKind[] = !info || info.kind === "both" ? ["tv", "movie"] : [info.kind];
  const animeOnly = info?.anime === true;
  const noAnime = info ? !info.anime : false;
  const genreNames = new Map<TmdbKind, Map<number, string>>();
  for (const k of kinds) genreNames.set(k, await tmdb.genres(k));
  const allGenreNames = new Map<number, string>([...(genreNames.get("tv") ?? []), ...(genreNames.get("movie") ?? [])]);
  const categories = [...new Set([...allGenreNames.values()])].sort().map((name) => ({ name, count: 0 }));
  const categoryIds = (k: TmdbKind) => [...(genreNames.get(k) ?? new Map<number, string>())].filter(([, n]) => n === o.category).map(([id]) => id);

  // 1) Taste from your server: the chosen library first (anime taste for anime picks), all of it if thin.
  const watchLaterIds = new Set(o.watchLater.map((e) => e.id));
  const weights = new Map<string, number>();
  for (const i of lib.items) {
    const w = historyWeight(i, o.dismissed, watchLaterIds);
    if (w !== 0) weights.set(i.Id, w);
  }
  const inScope = (i: Item) => !info || lib.libraryOf.get(i.Id) === info.id;
  let basis = lib.items.filter((i) => inScope(i) && weights.has(i.Id));
  if (basis.filter((i) => weights.get(i.Id)! > 0.3).length < 5) basis = lib.items.filter((i) => weights.has(i.Id));
  const profile = new TasteProfile();
  for (const i of basis) profile.add(genreLanguageVector(i), weights.get(i.Id)!);
  // Outside titles you told JellyReco about count too.
  const extWeight = (e: ListEntry, w: number) => {
    const v = new Map<string, number>();
    for (const g of e.genres ?? []) v.set("g:" + g.toLowerCase(), 1);
    profile.add(v, w);
  };
  for (const e of o.seen) extWeight(e, 0.75);
  for (const e of o.notForMe) extWeight(e, -1);
  for (const e of o.watchLater) if (e.id.startsWith("tmdb:")) extWeight(e, 0.5);
  profile.finalize();

  const blocked = new Set<string>([...o.exclude, ...o.notForMe.map((e) => e.id), ...o.seen.map((e) => e.id), ...o.watchLater.map((e) => e.id)]);
  const allowed = (t: TmdbItem) => {
    if (blocked.has(tmdbKey(t)) || isOwned(t, lib)) return false;
    if (!kinds.includes(t.kind)) return false;
    if (animeOnly && !isAnimeTmdb(t)) return false;
    if (noAnime && isAnimeTmdb(t)) return false;
    if (o.category && !categoryIds(t.kind).some((id) => t.genreIds.includes(id))) return false;
    if (o.minRating && t.voteAverage < o.minRating) return false;
    if (t.voteCount < 15 || !t.overview || !t.posterPath) return false;
    if (t.date && Date.parse(t.date) > Date.now()) return false; // not out yet
    return true;
  };

  // 2) Seeds: your best-liked titles with a TMDB id (IMDb/TVDB ids are looked up).
  const seedItems = basis.filter((i) => weights.get(i.Id)! > 0.3)
    .sort((a, b) => (weights.get(b.Id)! - weights.get(a.Id)!) || (Date.parse(b.UserData?.LastPlayedDate ?? "0") - Date.parse(a.UserData?.LastPlayedDate ?? "0")))
    .slice(0, 30);
  const seeds: { kind: TmdbKind; id: number; name: string; weight: number }[] = [];
  for (const i of seedItems) {
    const kind: TmdbKind = i.Type === "Movie" ? "movie" : "tv";
    let id = Number(i.ProviderIds?.Tmdb) || 0;
    if (!id) {
      const imdb = i.ProviderIds?.Imdb, tvdb = i.ProviderIds?.Tvdb;
      const found = imdb ? await tmdb.find(imdb, "imdb_id").catch(() => null) : tvdb ? await tmdb.find(tvdb, "tvdb_id").catch(() => null) : null;
      if (found) id = found.id;
    }
    if (id) seeds.push({ kind, id, name: i.Name ?? "", weight: weights.get(i.Id)! });
  }
  for (const e of o.seen) {
    const m = /^tmdb:(tv|movie):(\d+)$/.exec(e.id);
    if (m) seeds.push({ kind: m[1] as TmdbKind, id: Number(m[2]), name: e.title ?? "", weight: 0.75 });
  }

  const candidates = new Map<string, TmdbItem>();
  const collab = new Map<string, number>();
  const reasons = new Map<string, string[]>();
  const addRec = (t: TmdbItem, seed: { name: string; weight: number }, strength: number) => {
    const k = tmdbKey(t);
    candidates.set(k, t);
    collab.set(k, (collab.get(k) ?? 0) + seed.weight * strength);
    const r = reasons.get(k) ?? [];
    if (seed.name && !r.includes(seed.name)) r.push(seed.name);
    reasons.set(k, r);
  };
  let firstError: string | undefined;
  for (let s = 0; s < seeds.length; s += 5) {
    const batch = seeds.slice(s, s + 5);
    await Promise.all(batch.map(async (seed) => {
      try {
        const [recs, sim] = await Promise.all([tmdb.recommendations(seed.kind, seed.id, round), tmdb.similar(seed.kind, seed.id, round).catch(() => [] as TmdbItem[])]);
        recs.forEach((t, rank) => addRec(t, seed, 1 - rank / 30));
        sim.forEach((t, rank) => addRec(t, seed, 0.45 * (1 - rank / 30)));
      } catch (e) { firstError ??= (e as Error).message; }
    }));
    await sleep(60);
  }
  if (firstError && !candidates.size && seeds.length) throw new Error(firstError);

  stage("Exploring your favorite genres on TMDB…");
  // 3) Explore beyond what's linked: your top genres (or the chosen category), best rated and popular.
  const topGenres = [...profile.features].filter(([k, v]) => k.startsWith("g:") && v > 0).sort((a, b) => b[1] - a[1]).slice(0, 3).map(([k]) => k.slice(2));
  for (const kind of kinds) {
    const names = genreNames.get(kind)!;
    const idsFor = (gs: string[]) => [...names].filter(([, n]) => gs.includes(n.toLowerCase())).map(([id]) => id);
    const base: Record<string, string | number | boolean | undefined> = {
      "vote_count.gte": kind === "movie" ? 300 : 80,
      ...(animeOnly ? { with_original_language: "ja" } : {}),
    };
    const genreSets: number[][] = [];
    const cat = categoryIds(kind);
    if (cat.length) genreSets.push(animeOnly ? [16, ...cat] : cat);
    else {
      const top = idsFor(topGenres).filter((id) => id !== 16);
      if (animeOnly) genreSets.push([16], top.length ? [16, top[0]] : [16]);
      else if (top.length) genreSets.push(top.slice(0, 1), top.slice(0, 2));
    }
    for (const g of genreSets) {
      for (const sort of ["vote_average.desc", "popularity.desc"]) {
        try {
          const list = await tmdb.discover(kind, { ...base, with_genres: g.join(","), sort_by: sort }, round);
          for (const t of list) if (!candidates.has(tmdbKey(t))) candidates.set(tmdbKey(t), t);
        } catch (e) { firstError ??= (e as Error).message; }
      }
    }
  }

  // 4) Cheap first pass.
  const pool = [...candidates.values()].filter(allowed);
  if (!pool.length) return { picks: [], generatedAt: Date.now(), usedAI: false, exhausted: true, categories, watchedCount: basis.length, error: firstError };
  const maxCollab = Math.max(0.0001, ...pool.map((t) => collab.get(tmdbKey(t)) ?? 0));
  type Scored = { t: TmdbItem; collab: number; tagSim: number; quality: number; score: number };
  const pre: Scored[] = pool.map((t) => {
    const c = (collab.get(tmdbKey(t)) ?? 0) / maxCollab;
    const sim = Math.max(0, profile.similarityTo(tmdbVector(t, allGenreNames)));
    // Many votes make a high average trustworthy (pulled toward 6.5 when there are few).
    const quality = ((t.voteAverage * t.voteCount) + 6.5 * 200) / (t.voteCount + 200) / 10;
    return { t, collab: c, tagSim: sim, quality, score: 0.5 * c + 0.36 * sim + 0.14 * quality };
  });
  pre.sort((a, b) => b.score - a.score);
  const shortList = pre.slice(0, 90);

  // 5) On-device semantic re-rank: the overviews of what you loved vs. each candidate's.
  let usedAI = false;
  let ranked = shortList.map((s) => ({ t: s.t, score: s.score }));
  if (o.useAI && shortList.length) {
    stage("Ranking with on-device AI…");
    try {
      const anchors = basis.filter((i) => Math.abs(weights.get(i.Id) ?? 0) >= 0.4 && (i.Overview ?? "").length > 40)
        .sort((a, b) => Math.abs(weights.get(b.Id)!) - Math.abs(weights.get(a.Id)!)).slice(0, 40);
      const text = (x: TmdbItem) => `${x.title}. ${x.genreIds.map((g) => allGenreNames.get(g)).filter(Boolean).join(", ")}. ${x.overview.slice(0, 500)}`;
      const got = await withTimeout((async () => ({
        anchorVecs: await vectorsFor(anchors),
        vecs: await getEmbedder().vectors(shortList.map((s) => ({ id: tmdbVectorId(s.t), text: text(s.t) }))),
      }))(), aiWait());
      if (!got) { aiTimedOutAt = Date.now(); throw new Error("on-device AI is still starting"); }
      aiTimedOutAt = 0;
      const { anchorVecs, vecs } = got;
      let taste: Float32Array | null = null;
      for (const a of anchors) {
        const v = anchorVecs.get(a.Id);
        if (!v) continue;
        if (!taste) taste = new Float32Array(v.length);
        accumulate(v, weights.get(a.Id) ?? 0, taste);
      }
      if (taste) {
        const tv = normalized(taste);
        const sims = shortList.map((s) => { const v = vecs.get(tmdbVectorId(s.t)); return v ? cosine(tv, v) : null; });
        const known = sims.filter((x): x is number => x !== null);
        if (known.length) {
          const lo = Math.min(...known), hi = Math.max(...known);
          const span = Math.max(hi - lo, 0.0001);
          ranked = shortList.map((s, k) => ({ t: s.t, score: 0.34 * s.collab + 0.26 * s.tagSim + 0.28 * (sims[k] === null ? 0.5 : (sims[k]! - lo) / span) + 0.12 * s.quality }));
          usedAI = true;
        }
      }
    } catch { /* AI unavailable: keep the cheap ranking */ }
  }
  ranked.sort((a, b) => b.score - a.score);

  const top = Math.max(ranked[0]?.score ?? 1, 0.0001);
  const penalty = (round - 1) * 0.04;
  const genreNameMap = new Map([...allGenreNames].map(([, n]) => [`g:${n.toLowerCase()}`, n]));
  const picks = ranked.slice(0, 40).map((r): Pick => ({
    key: tmdbKey(r.t),
    tmdb: r.t,
    score: r.score,
    match: Math.round(Math.max(0.5, Math.min(0.99, 0.55 + 0.44 * (r.score / top) - penalty)) * 100),
    because: (reasons.get(tmdbKey(r.t)) ?? []).slice(0, 3),
    highlights: profile.highlights(tmdbVector(r.t, allGenreNames), genreNameMap),
    genres: r.t.genreIds.map((g) => allGenreNames.get(g)).filter((x): x is string => !!x),
  }));
  return { picks, generatedAt: Date.now(), usedAI, exhausted: pool.length <= picks.length && round > 2, categories, watchedCount: basis.length + o.seen.length, error: firstError };
}

/** TMDB titles like one pick, that you don't have (the pick's "More like this"). */
export async function tmdbMoreLike(tmdb: Tmdb, lib: Library, t: TmdbItem, blocked: Set<string>): Promise<TmdbItem[]> {
  const [recs, sim] = await Promise.all([tmdb.recommendations(t.kind, t.id).catch(() => []), tmdb.similar(t.kind, t.id).catch(() => [])]);
  const seen = new Set<string>();
  return [...recs, ...sim].filter((x) => {
    const k = tmdbKey(x);
    if (seen.has(k) || blocked.has(k) || isOwned(x, lib) || !x.posterPath) return false;
    seen.add(k);
    return true;
  }).slice(0, 30);
}

// MARK: More like this (your own library, on-device AI)

export interface Similar { item: Item; match: number }

/**
 * Titles in your library most like this one: overview meaning (on-device AI), genres/tags/studios,
 * and the server's own similarity list. Unwatched first.
 */
export async function moreLikeThis(api: Jellyfin, lib: Library, item: Item, useAI: boolean): Promise<Similar[]> {
  const pool = lib.items.filter((i) => i.Id !== item.Id && i.Type === item.Type);
  if (!pool.length) return [];
  const one = new TasteProfile();
  one.add(TasteProfile.vector(item), 1);
  one.finalize();
  const server = await api.similar(item.Id, 40).catch(() => null);
  const serverRank = new Map((server?.Items ?? []).map((x, i) => [x.Id, 1 - i / 40]));
  const pre = pool.map((i) => ({ i, tag: Math.max(0, one.similarityTo(TasteProfile.vector(i))), srv: serverRank.get(i.Id) ?? 0 }))
    .map((x) => ({ ...x, score: 0.6 * x.tag + 0.4 * x.srv }))
    .sort((a, b) => b.score - a.score)
    .slice(0, 80);
  let ranked = pre.map((x) => ({ i: x.i, score: x.score }));
  if (useAI && (item.Overview ?? "").length > 30) {
    try {
      const vecs = (await withTimeout(vectorsFor([item, ...pre.map((x) => x.i)]), aiWait())) ?? new Map<string, Float32Array>();
      const me = vecs.get(item.Id);
      if (me) {
        const sims = pre.map((x) => { const v = vecs.get(x.i.Id); return v ? cosine(me, v) : null; });
        const known = sims.filter((x): x is number => x !== null);
        if (known.length) {
          const lo = Math.min(...known), hi = Math.max(...known);
          const span = Math.max(hi - lo, 0.0001);
          ranked = pre.map((x, k) => ({ i: x.i, score: 0.45 * (sims[k] === null ? 0.4 : (sims[k]! - lo) / span) + 0.35 * x.tag + 0.2 * x.srv }));
        }
      }
    } catch { /* no AI: tags and server similarity */ }
  }
  ranked.sort((a, b) => b.score - a.score);
  const top = Math.max(ranked[0]?.score ?? 1, 0.0001);
  const out = ranked.slice(0, 24).map((r) => ({ item: r.i, match: Math.round(Math.max(0.5, Math.min(0.99, 0.5 + 0.49 * (r.score / top))) * 100) }));
  return [...out.filter((x) => !x.item.UserData?.Played), ...out.filter((x) => x.item.UserData?.Played)];
}

/** Match % for one library title (details page), from your taste profile. */
export function quickMatch(item: Item, lib: Library, dismissed: Set<string>): number | null {
  const profile = new TasteProfile();
  let n = 0;
  for (const i of lib.items) {
    const w = historyWeight(i, dismissed);
    if (w !== 0) { profile.add(TasteProfile.vector(i), w); n++; }
  }
  if (n < 3) return null;
  profile.finalize();
  const liked = lib.items.filter((i) => historyWeight(i, dismissed) > 0.5).map((i) => profile.similarityTo(TasteProfile.vector(i), historyWeight(i, dismissed))).sort((a, b) => a - b);
  const hi = liked.length ? liked[Math.min(liked.length - 1, Math.floor(liked.length * 0.75))] : 0.6;
  const lo = hi * 0.35;
  const raw = profile.similarityTo(TasteProfile.vector(item), historyWeight(item, dismissed));
  const z = Math.max(-1, Math.min(1, (raw - lo) / Math.max(hi - lo, 0.05)));
  return Math.round(z >= 0 ? 50 + 49 * z : 50 + 30 * z);
}
