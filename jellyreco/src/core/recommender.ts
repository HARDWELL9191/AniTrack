// For You (AniReco's recommender, for a Jellyfin library). Picks come only from what's on your
// server and you haven't watched. Your taste comes from your watch history: completed shows and
// movies, how far you got into the rest, favorites and thumbs up/down.
//
// Score = similar-to-what-you-watched (Jellyfin's similarity graph, the stand-in for AniList's fan
// recommendations) + genre/tag/studio match to your taste profile + on-device synopsis similarity
// (bge-small on the Snapdragon NPU) + community rating, then shown as a match %.

import { accumulate, cosine, normalized, vectorsFor } from "./ai";
import type { Jellyfin } from "./api";
import type { Item } from "./types";

export interface Pick {
  item: Item;
  score: number;
  match: number;
  because: string[]; // titles you watched that it's similar to
  highlights: string[]; // genres/tags you like that it has
  libraryId: string;
}

export interface Feed {
  picks: Pick[];
  generatedAt: number;
  usedAI: boolean;
  exhausted: boolean;
  /** Genres available in the chosen library (second dropdown). */
  categories: { name: string; count: number }[];
  watchedCount: number;
}

export interface Library {
  /** Every series and movie the user can see, with the library it lives in. */
  items: Item[];
  libraryOf: Map<string, string>;
  /** The libraries For You offers (first dropdown), "placeholder" ones left out. */
  libraries: { id: string; name: string; count: number }[];
  loadedAt: number;
}

const FIELDS = ["Genres", "Tags", "Studios", "Overview", "ProductionYear", "ProviderIds", "OriginalTitle", "ParentId", "RecursiveItemCount", "DateCreated", "PrimaryImageAspectRatio"];

/** Libraries named "placeholder" (anywhere in the name), "playlist" or "playlists" (any case)
 * never take part in For You: not in the dropdown, not as picks, not as taste. */
export const isPlaceholder = (name?: string | null) => /placeholder/i.test(name ?? "") || /^\s*playlists?\s*$/i.test(name ?? "");

/** The libraries For You can draw from: TV, movie and mixed ones, except placeholders. */
export function pickableViews(views: Item[]): Item[] {
  return views.filter((v) => (!v.CollectionType || ["tvshows", "movies", "mixed", "homevideos"].includes(v.CollectionType)) && v.CollectionType !== "playlists" && !isPlaceholder(v.Name));
}

/** Loads every series and movie (paged) from those libraries. */
export async function loadLibrary(api: Jellyfin, views: Item[]): Promise<Library> {
  const libs = pickableViews(views);
  const items: Item[] = [];
  const libraryOf = new Map<string, string>();
  const libraries: Library["libraries"] = [];
  for (const lib of libs) {
    let start = 0;
    let count = 0;
    for (;;) {
      const r = await api.items({
        parentId: lib.Id, recursive: true, includeItemTypes: ["Series", "Movie"], fields: FIELDS, enableUserData: true,
        enableImageTypes: ["Primary", "Backdrop", "Thumb"], imageTypeLimit: 1, startIndex: start, limit: 500, sortBy: ["SortName"],
      });
      for (const i of r.Items) {
        if (libraryOf.has(i.Id)) continue;
        libraryOf.set(i.Id, lib.Id);
        items.push(i);
        count++;
      }
      start += r.Items.length;
      if (!r.Items.length || start >= r.TotalRecordCount) break;
    }
    libraries.push({ id: lib.Id, name: lib.Name ?? "Library", count });
  }
  return { items, libraryOf, libraries, loadedAt: Date.now() };
}

/** The first dropdown's default: the library called "Anime", else everything. */
export function defaultLibrary(lib: Library): string {
  const exact = lib.libraries.find((l) => l.name.trim().toLowerCase() === "anime");
  return exact?.id ?? "all";
}

export function inLibrary(i: Item, libraryId: string, lib: Library): boolean {
  return libraryId === "all" || lib.libraryOf.get(i.Id) === libraryId;
}

export function categoriesFor(items: Item[]): { name: string; count: number }[] {
  const counts = new Map<string, number>();
  for (const i of items) for (const g of i.Genres ?? []) counts.set(g, (counts.get(g) ?? 0) + 1);
  return [...counts].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0])).map(([name, count]) => ({ name, count }));
}

// MARK: Taste

export class TasteProfile {
  features = new Map<string, number>();
  norm = 0;

  static vector(i: Item): Map<string, number> {
    const v = new Map<string, number>();
    for (const g of i.Genres ?? []) v.set("g:" + g.toLowerCase(), 1);
    for (const t of (i.Tags ?? []).slice(0, 20)) v.set("t:" + t.toLowerCase(), 0.6);
    for (const s of (i.Studios ?? []).slice(0, 3)) if (s.Name) v.set("s:" + s.Name.toLowerCase(), 0.45);
    return v;
  }

  add(i: Item, weight: number) {
    for (const [k, value] of TasteProfile.vector(i)) this.features.set(k, (this.features.get(k) ?? 0) + value * weight);
  }

  finalize() {
    let s = 0;
    for (const v of this.features.values()) s += v * v;
    this.norm = Math.sqrt(s);
  }

  similarity(i: Item): number {
    return this.similarityExcluding(i, 0);
  }

  /** Similarity without this item's own share (leave-one-out). */
  similarityExcluding(i: Item, w: number): number {
    if (!(this.norm > 0)) return 0;
    const v = TasteProfile.vector(i);
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

  highlights(i: Item, limit = 3): string[] {
    const names = new Map<string, string>();
    for (const g of i.Genres ?? []) names.set("g:" + g.toLowerCase(), g);
    for (const t of i.Tags ?? []) names.set("t:" + t.toLowerCase(), t);
    for (const s of i.Studios ?? []) if (s.Name) names.set("s:" + s.Name.toLowerCase(), s.Name);
    return [...TasteProfile.vector(i)]
      .map(([k, v]) => [k, (this.features.get(k) ?? 0) * v] as const)
      .filter(([, w]) => w > 0)
      .sort((a, b) => b[1] - a[1])
      .slice(0, limit)
      .map(([k]) => names.get(k) ?? k.slice(2));
  }
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
  // Watch later = AniReco's Plan to watch: interested, not seen yet.
  if (watchLater?.has(i.Id) && w >= 0 && w < 0.5) w = 0.5;
  return w;
}

/** Started, finished, favorited, rated or on Watch later: not a pick any more. */
export function onYourList(i: Item, watchLater?: Set<string>): boolean {
  if (watchLater?.has(i.Id)) return true;
  const ud = i.UserData;
  if (!ud) return false;
  if (ud.Played || ud.IsFavorite || (ud.Likes !== null && ud.Likes !== undefined)) return true;
  if ((ud.PlaybackPositionTicks ?? 0) > 0) return true;
  if (i.Type === "Series") {
    const total = i.RecursiveItemCount ?? 0;
    const left = ud.UnplayedItemCount ?? total;
    if (total && left < total) return true;
  }
  return false;
}

export interface RecOptions {
  libraryId: string; // a library id or "all"
  category: string;
  minRating: number;
  dismissed: Set<string>;
  watchLater: Set<string>;
  useAI: boolean;
  exclude: Set<string>;
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** Builds the next batch of picks (40). `exclude` holds ids already shown. */
export async function recommend(api: Jellyfin, lib: Library, o: RecOptions, round = 1): Promise<Feed> {
  const scope = lib.items.filter((i) => inLibrary(i, o.libraryId, lib));
  const categories = categoriesFor(scope.filter((i) => !onYourList(i, o.watchLater) && !o.dismissed.has(i.Id)));

  // Taste: from the same library first (anime taste for anime picks); all history if that's thin.
  const weights = new Map<string, number>();
  for (const i of lib.items) {
    const w = historyWeight(i, o.dismissed, o.watchLater);
    if (w !== 0) weights.set(i.Id, w);
  }
  const history = (pool: Item[]) => pool.filter((i) => (weights.get(i.Id) ?? 0) !== 0);
  let basis = history(scope);
  if (basis.filter((i) => (weights.get(i.Id) ?? 0) > 0.3).length < 5) basis = history(lib.items);
  const profile = new TasteProfile();
  for (const i of basis) profile.add(i, weights.get(i.Id)!);
  profile.finalize();

  const allowed = (i: Item) => {
    if (onYourList(i, o.watchLater) || o.dismissed.has(i.Id) || o.exclude.has(i.Id)) return false;
    if (o.category && !(i.Genres ?? []).some((g) => g.toLowerCase() === o.category.toLowerCase())) return false;
    if (o.minRating && (i.CommunityRating ?? 0) < o.minRating) return false;
    return true;
  };
  const candidates = new Map(scope.filter(allowed).map((i) => [i.Id, i]));
  const empty: Feed = { picks: [], generatedAt: Date.now(), usedAI: false, exhausted: true, categories, watchedCount: basis.length };
  if (!candidates.size) return empty;

  // 1) "Similar to what you watched": Jellyfin's similarity list for your top titles.
  const seeds = basis
    .filter((i) => (weights.get(i.Id) ?? 0) > 0.3)
    .sort((a, b) => (weights.get(b.Id)! - weights.get(a.Id)!) || (Date.parse(b.UserData?.LastPlayedDate ?? "0") - Date.parse(a.UserData?.LastPlayedDate ?? "0")))
    .slice(0, 30);
  const collab = new Map<string, number>();
  const reasons = new Map<string, string[]>();
  for (let s = 0; s < seeds.length; s += 6) {
    const batch = seeds.slice(s, s + 6);
    const results = await Promise.all(batch.map((seed) => api.similar(seed.Id, 24).catch(() => null)));
    results.forEach((r, k) => {
      const seed = batch[k];
      const w = weights.get(seed.Id) ?? 0.5;
      r?.Items.forEach((rec, rank) => {
        if (!candidates.has(rec.Id)) return;
        collab.set(rec.Id, (collab.get(rec.Id) ?? 0) + w * (1 - rank / 30));
        const list = reasons.get(rec.Id) ?? [];
        if (seed.Name && !list.includes(seed.Name)) list.push(seed.Name);
        reasons.set(rec.Id, list);
      });
    });
    await sleep(50);
  }

  // 2) Cheap first pass: similarity graph + taste profile + rating.
  const maxCollab = Math.max(0.0001, ...collab.values());
  type Scored = { item: Item; collab: number; tagSim: number; quality: number; score: number };
  const pre: Scored[] = [];
  for (const [id, i] of candidates) {
    const c = (collab.get(id) ?? 0) / maxCollab;
    const sim = Math.max(0, profile.similarity(i));
    const quality = (i.CommunityRating ?? 6.5) / 10;
    // Newer additions get a nudge, like "Latest" in jellyfin-web.
    pre.push({ item: i, collab: c, tagSim: sim, quality, score: 0.45 * c + 0.43 * sim + 0.12 * quality });
  }
  pre.sort((a, b) => b.score - a.score);
  const shortList = pre.slice(0, 90);

  // 3) On-device semantic re-rank (the overview's meaning, not just its genres).
  let usedAI = false;
  let ranked = shortList.map((s) => ({ item: s.item, score: s.score }));
  if (o.useAI && shortList.length) {
    const anchors = basis
      .filter((i) => Math.abs(weights.get(i.Id) ?? 0) >= 0.4 && (i.Overview ?? "").length > 40)
      .sort((a, b) => Math.abs(weights.get(b.Id)!) - Math.abs(weights.get(a.Id)!))
      .slice(0, 40);
    let vectors = new Map<string, Float32Array>();
    try {
      vectors = await vectorsFor([...anchors, ...shortList.map((s) => s.item)]);
    } catch { /* AI unavailable: keep the cheap ranking */ }
    let taste: Float32Array | null = null;
    for (const a of anchors) {
      const v = vectors.get(a.Id);
      if (!v) continue;
      if (!taste) taste = new Float32Array(v.length);
      accumulate(v, weights.get(a.Id) ?? 0, taste);
    }
    if (taste) {
      const t = normalized(taste);
      const sims = shortList.map((s) => { const v = vectors.get(s.item.Id); return v ? cosine(t, v) : null; });
      const known = sims.filter((x): x is number => x !== null);
      if (known.length) {
        const lo = Math.min(...known), hi = Math.max(...known);
        const span = Math.max(hi - lo, 0.0001);
        ranked = shortList.map((s, k) => {
          const semantic = sims[k] === null ? 0.5 : (sims[k]! - lo) / span;
          return { item: s.item, score: 0.34 * s.collab + 0.28 * s.tagSim + 0.28 * semantic + 0.1 * s.quality };
        });
        usedAI = true;
      }
    }
  }
  ranked.sort((a, b) => b.score - a.score);

  const top = Math.max(ranked[0]?.score ?? 1, 0.0001);
  const penalty = (round - 1) * 0.04;
  const picks = ranked.slice(0, 40).map((r): Pick => ({
    item: r.item,
    score: r.score,
    match: Math.round(Math.max(0.5, Math.min(0.99, 0.55 + 0.44 * (r.score / top) - penalty)) * 100),
    because: (reasons.get(r.item.Id) ?? []).slice(0, 3),
    highlights: profile.highlights(r.item),
    libraryId: lib.libraryOf.get(r.item.Id) ?? "",
  }));
  return { picks, generatedAt: Date.now(), usedAI, exhausted: candidates.size <= picks.length, categories, watchedCount: basis.length };
}

/** Match % for one item (details page), from the taste profile alone. */
export function quickMatch(item: Item, lib: Library, dismissed: Set<string>): number | null {
  const profile = new TasteProfile();
  let n = 0;
  for (const i of lib.items) {
    const w = historyWeight(i, dismissed);
    if (w !== 0) { profile.add(i, w); n++; }
  }
  if (n < 3) return null;
  profile.finalize();
  // Calibrate against what you liked: your well-liked titles define "very high match".
  const liked = lib.items.filter((i) => historyWeight(i, dismissed) > 0.5).map((i) => profile.similarityExcluding(i, historyWeight(i, dismissed))).sort((a, b) => a - b);
  const hi = liked.length ? liked[Math.min(liked.length - 1, Math.floor(liked.length * 0.75))] : 0.6;
  const lo = hi * 0.35;
  const raw = profile.similarityExcluding(item, historyWeight(item, dismissed));
  const z = Math.max(-1, Math.min(1, (raw - lo) / Math.max(hi - lo, 0.05)));
  return Math.round(z >= 0 ? 50 + 49 * z : 50 + 30 * z);
}
