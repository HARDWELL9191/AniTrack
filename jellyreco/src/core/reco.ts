// Your library and taste, the same logic as the iPhone app's RecoEngine (JellyReco/AI/RecoEngine.swift):
// - a snapshot of the libraries For You can use (never "placeholder" or "playlist(s)"), read
//   through a read-only API handle: the AI can't change anything on the server
// - how strongly each title says "liked" or "not for me" (finished, rewatched, favourite, thumbs
//   up/down, on My List, gave up after a few episodes…)
// - a taste profile of genres, tags, studios and decades, the match % and "More like this".

import { getEmbedder, cosine } from "./ai";
import type { Jellyfin } from "./api";
import type { AccountStorage } from "./storage";
import type { Item } from "./types";

export const ALL = "all";

/** Libraries never offered for recommendations (e.g. a "placeholder" library). */
export function isExcluded(name?: string | null) {
  const n = (name ?? "").trim();
  return /placeholder/i.test(n) || /^playlists?$/i.test(n);
}

export interface Source { id: string; name: string; collectionType: string | null }

/** The first dropdown: your own libraries by name, plus All (last, as on the iPhone). */
export function sourcesOf(views: Item[]): Source[] {
  const libs = views
    .filter((v) => ["movies", "tvshows", "mixed", "homevideos", ""].includes(v.CollectionType ?? ""))
    .filter((v) => !isExcluded(v.Name))
    .map((v) => ({ id: v.Id, name: v.Name ?? "Library", collectionType: v.CollectionType ?? null }));
  return [...libs, { id: ALL, name: "All", collectionType: null }];
}

/** The saved choice if it still exists, else the library named Anime. */
export function currentSourceId(sources: Source[], saved: string): string {
  if (saved && sources.some((s) => s.id === saved)) return saved;
  const exact = sources.find((s) => s.name.toLowerCase() === "anime");
  if (exact) return exact.id;
  const anime = sources.find((s) => /anime/i.test(s.name) && !/movie|film/i.test(s.name));
  return anime?.id ?? sources[0]?.id ?? ALL;
}

const FIELDS = ["Overview", "Genres", "Tags", "Studios", "ProductionYear", "CommunityRating", "OfficialRating", "RecursiveItemCount", "ChildCount",
  "ProductionLocations", "OriginalTitle", "DateCreated", "PrimaryImageAspectRatio", "Status", "EndDate", "RunTimeTicks", "ProviderIds"];

const plain = (s?: string | null) => (s ?? "").replace(/<[^>]+>/g, " ").replace(/\s+/g, " ").trim();

// MARK: Taste profile (genres, tags, studios, decade)

export interface Tasteable { Genres?: string[] | null; Tags?: string[] | null; Studios?: { Name?: string | null }[] | null; ProductionYear?: number | null }

export class TasteProfile {
  features = new Map<string, number>();
  norm = 0;

  static vector(item: Tasteable): Map<string, number> {
    const v = new Map<string, number>();
    for (const g of item.Genres ?? []) v.set("g:" + g, 1);
    for (const t of (item.Tags ?? []).slice(0, 15)) v.set("t:" + t.toLowerCase(), 0.6);
    for (const s of (item.Studios ?? []).slice(0, 3)) if (s.Name) v.set("s:" + s.Name, 0.45);
    if (item.ProductionYear) v.set(`d:${Math.floor(item.ProductionYear / 10) * 10}`, 0.15);
    return v;
  }

  add(item: Tasteable, weight: number) {
    if (!weight) return;
    for (const [k, x] of TasteProfile.vector(item)) this.features.set(k, (this.features.get(k) ?? 0) + x * weight);
  }

  finalize() {
    let s = 0;
    for (const x of this.features.values()) s += x * x;
    this.norm = Math.sqrt(s);
  }

  similarity(item: Tasteable): number {
    if (!(this.norm > 0)) return 0;
    const v = TasteProfile.vector(item);
    let vn = 0, dot = 0;
    for (const [k, x] of v) { vn += x * x; dot += x * (this.features.get(k) ?? 0); }
    vn = Math.sqrt(vn);
    return vn > 0 ? dot / (this.norm * vn) : 0;
  }

  /** Leave-one-out: a title in your history compared with the rest of your taste. */
  similarityExcluding(item: Tasteable, w: number): number {
    if (!w) return this.similarity(item);
    const v = TasteProfile.vector(item);
    let vn = 0;
    for (const x of v.values()) vn += x * x;
    vn = Math.sqrt(vn);
    if (!(vn > 0)) return 0;
    let normSq = this.norm * this.norm, dot = 0;
    for (const [k, x] of v) {
      const f = this.features.get(k) ?? 0;
      const without = f - x * w;
      normSq += without * without - f * f;
      dot += x * without;
    }
    return normSq > 1e-9 ? dot / (Math.sqrt(normSq) * vn) : 0;
  }

  /** Your strongest features of one kind ("g:" genres, "t:" tags). */
  top(prefix: string, count: number): string[] {
    return [...this.features].filter(([k, x]) => k.startsWith(prefix) && x > 0).sort((a, b) => b[1] - a[1]).slice(0, count).map(([k]) => k.slice(prefix.length));
  }

  highlights(item: Tasteable, limit = 3): string[] {
    return [...TasteProfile.vector(item)]
      .filter(([k]) => !k.startsWith("d:"))
      .map(([k, x]) => [k, (this.features.get(k) ?? 0) * x] as const)
      .filter(([, w]) => w > 0)
      .sort((a, b) => b[1] - a[1])
      .slice(0, limit)
      .map(([k]) => k.slice(2).replace(/\b\p{L}/gu, (c) => c.toUpperCase()));
  }
}

// MARK: On-device AI inputs (same text recipe as the iPhone, so the vectors compare)

/** 52-bit FNV-1a of a string: the vector store's id for this exact text. */
export function vectorKey(s: string): number {
  let h = 0xcbf29ce484222325n;
  const bytes = new TextEncoder().encode(s);
  for (const b of bytes) { h ^= BigInt(b); h = (h * 0x100000001b3n) & 0xffffffffffffffffn; }
  return Number(h & 0xfffffffffffffn);
}

export interface EmbedInput { key: string; text: string }

export function itemInput(i: Item): EmbedInput {
  return { key: i.Id, text: `${i.Name ?? ""}. ${(i.Genres ?? []).join(", ")}. ${(i.Tags ?? []).slice(0, 6).join(", ")}. ${plain(i.Overview).slice(0, 500)}` };
}

/** Vectors by input key (the model runs only for texts it hasn't seen). */
export async function embed(inputs: EmbedInput[]): Promise<Map<string, Float32Array>> {
  const ids = new Map<number, string>();
  const unique = new Map<number, EmbedInput>();
  for (const x of inputs) { const id = vectorKey(`${x.key}|${x.text}`); ids.set(id, x.key); unique.set(id, x); }
  const raw = await getEmbedder().vectors([...unique].map(([id, x]) => ({ id, text: x.text })));
  const out = new Map<string, Float32Array>();
  for (const [id, v] of raw) { const k = ids.get(id); if (k) out.set(k, v); }
  return out;
}

// MARK: The library and your signals

export interface RecoContext {
  api: Jellyfin; // read-only handle
  views: Item[];
  storage: AccountStorage | null;
  dismissed: Set<string>; // Not for me this session (before the server confirms)
  includeWatchingAsLiked: boolean;
}

export class Reco {
  snapshot = new Map<string, Item[]>(); // source id → its movies and shows
  byId = new Map<string, Item>();
  itemLibrary = new Map<string, string>();
  /** Movies and shows in every video library (also ones For You doesn't use), for "already have it". */
  owned: Item[] = [];
  weights = new Map<string, number>();
  profile = new TasteProfile();
  private tagScale = { lo: 0, hi: 0.55 };
  loadedAt = 0;
  private loading: Promise<void> | null = null;
  error: string | null = null;
  private ctx: () => RecoContext | null;
  constructor(ctx: () => RecoContext | null) { this.ctx = ctx; }

  get ready() { return this.byId.size > 0; }

  /** Another account or server: forget everything. */
  reset() {
    this.snapshot = new Map(); this.byId = new Map(); this.itemLibrary = new Map(); this.owned = [];
    this.weights = new Map(); this.profile = new TasteProfile(); this.loadedAt = 0; this.error = null;
  }

  /** Reads the libraries (once per 10 minutes unless forced) and rebuilds your taste. */
  ensure(force = false): Promise<void> {
    if (!force && this.ready && Date.now() - this.loadedAt < 10 * 60_000) return Promise.resolve();
    if (this.loading) return this.loading;
    this.loading = this.load().finally(() => { this.loading = null; });
    return this.loading;
  }

  private async load() {
    const c = this.ctx();
    if (!c || !c.views.length) return;
    this.error = null;
    try {
      const fresh = new Map<string, Item[]>();
      for (const s of sourcesOf(c.views)) if (s.id !== ALL) fresh.set(s.id, await this.fetchLibrary(c.api, s.id, s.collectionType));
      // Libraries For You doesn't use still count as "on your server".
      const others: Item[] = [];
      for (const v of c.views) {
        if (fresh.has(v.Id) || !(!v.CollectionType || ["movies", "tvshows", "mixed", "homevideos"].includes(v.CollectionType))) continue;
        others.push(...(await this.fetchLibrary(c.api, v.Id, v.CollectionType ?? null, true)));
      }
      this.snapshot = fresh;
      this.byId = new Map();
      this.itemLibrary = new Map();
      for (const [lib, items] of fresh) for (const i of items) { this.byId.set(i.Id, i); this.itemLibrary.set(i.Id, lib); }
      this.owned = [...this.byId.values(), ...others];
      this.rebuild();
      this.loadedAt = Date.now();
    } catch (e) {
      this.error = (e as Error).message;
      if (!this.ready) throw e;
    }
  }

  private async fetchLibrary(api: Jellyfin, id: string, type: string | null, light = false): Promise<Item[]> {
    const all: Item[] = [];
    for (let start = 0; ;) {
      const r = await api.items({
        parentId: id, recursive: true, includeItemTypes: type === "movies" ? ["Movie"] : type === "tvshows" ? ["Series"] : ["Movie", "Series"],
        fields: light ? ["ProviderIds", "OriginalTitle", "ProductionYear"] : FIELDS, enableUserData: !light, enableImageTypes: ["Primary", "Backdrop", "Thumb"], imageTypeLimit: 1,
        sortBy: ["SortName"], startIndex: start, limit: 400,
      });
      all.push(...r.Items);
      start += r.Items.length;
      if (!r.Items.length || all.length >= r.TotalRecordCount || all.length > 20_000) break;
    }
    return all;
  }

  isNotForMe(i: Item) {
    const c = this.ctx();
    return !!c?.dismissed.has(i.Id) || i.UserData?.Likes === false;
  }

  /** How strongly your history says "liked" (positive) or "not for me" (negative); null = no signal. */
  signal(i: Item): number | null {
    const c = this.ctx();
    if (!c) return null;
    if (this.isNotForMe(i)) return -1;
    const ud = i.UserData ?? {};
    // On My List = liked enough to plan it.
    let w: number | null = c.storage?.hasServer(i.Id) ? 0.5 : null;
    const daysSince = ud.LastPlayedDate ? (Date.now() - Date.parse(ud.LastPlayedDate)) / 86_400_000 : 0;
    if (ud.Played) {
      w = 1 + Math.min(0.4, Math.max(0, (ud.PlayCount ?? 1) - 1) * 0.2); // rewatched = loved
    } else if (i.Type === "Series") {
      const total = i.RecursiveItemCount ?? 0;
      const unplayed = ud.UnplayedItemCount ?? total;
      const watched = Math.max(0, total - unplayed);
      if (total > 0 && watched > 0) {
        const frac = watched / total;
        if (frac < 0.35 && daysSince > 60) w = -0.6; // tried it, gave up
        else if (c.includeWatchingAsLiked) w = 0.4 + 0.6 * frac;
      }
    } else if ((ud.PlayedPercentage ?? 0) > 0) {
      const pct = ud.PlayedPercentage ?? 0;
      w = pct < 25 && daysSince > 30 ? -0.4 : c.includeWatchingAsLiked ? Math.max(w ?? 0, 0.4) : w;
    }
    if (ud.IsFavorite) w = Math.max(w ?? 0, 0) + 0.9;
    if (ud.Likes === true) w = Math.max(w ?? 0, 0) + 0.5;
    else if (ud.Likes === false) w = -1;
    return w;
  }

  /** After a change to your lists or a title's watched state: weights and profile again. */
  rebuild() {
    const p = new TasteProfile();
    const w = new Map<string, number>();
    for (const i of this.byId.values()) {
      const s = this.signal(i);
      if (s === null) continue;
      w.set(i.Id, s);
      p.add(i, s);
    }
    p.finalize();
    this.profile = p;
    this.weights = w;
    // Calibrate "very high match" on your well-liked titles (each vs. the rest of your history).
    const liked = [...w].filter(([, x]) => x > 0.5).map(([id, x]) => p.similarityExcluding(this.byId.get(id)!, x)).sort((a, b) => a - b);
    const all = [...this.byId.values()].slice(0, 2000).map((i) => p.similarityExcluding(i, w.get(i.Id) ?? 0)).sort((a, b) => a - b);
    const hi = liked.length ? liked[Math.min(liked.length - 1, Math.floor(liked.length * 0.75))] : 0.55;
    const lo = all.length ? Math.min(all[Math.floor((all.length - 1) * 0.1)], hi * 0.4) : 0;
    this.tagScale = { lo, hi: Math.max(hi, lo + 0.05) };
  }

  /** Your history; titles in the given library count 1.5×. */
  history(boosting: string): { item: Item; weight: number }[] {
    const out: { item: Item; weight: number }[] = [];
    for (const [id, w] of this.weights) {
      const item = this.byId.get(id);
      if (!item) continue;
      out.push({ item, weight: w * (boosting === ALL || this.itemLibrary.get(id) === boosting ? 1.5 : 1) });
    }
    return out;
  }

  /** Personal match % for a movie or show (null until there's history). */
  match(item: Item): number | null {
    if (!(this.profile.norm > 0)) return null;
    const target = (item.Type === "Episode" || item.Type === "Season") && item.SeriesId ? this.byId.get(item.SeriesId) : this.byId.get(item.Id) ?? item;
    if (!target || (target.Type !== "Movie" && target.Type !== "Series")) return null;
    const raw = this.profile.similarityExcluding(target, this.weights.get(target.Id) ?? 0);
    const z = Math.max(-1, Math.min(1, (raw - this.tagScale.lo) / (this.tagScale.hi - this.tagScale.lo)));
    return z >= 0 ? Math.round(50 + 49 * Math.min(z, 1)) : Math.round(50 + 30 * z);
  }

  /**
   * "More like this": unwatched titles on your server close to this one. Local only. Candidates
   * are Jellyfin's similar items plus the closest titles by genres, tags and studio; the on-device
   * AI then compares their overviews with this title's.
   */
  async moreLike(item: Item, useAI: boolean, aiWaitMs: number): Promise<{ item: Item; match: number }[]> {
    const c = this.ctx();
    if (!c) return [];
    await this.ensure();
    const baseId = item.Type === "Episode" || item.Type === "Season" ? (item.SeriesId ?? item.Id) : item.Id;
    const base = this.byId.get(baseId) ?? (await c.api.itemFull(baseId).catch(() => item));
    const pool = new Map<string, Item>();
    const similar = await c.api.similar(baseId, 40).catch(() => null);
    for (const s of similar?.Items ?? []) pool.set(s.Id, this.byId.get(s.Id) ?? s);
    const single = new TasteProfile();
    single.add(base, 1);
    single.finalize();
    const sameKind = [...this.byId.values()].filter((x) => x.Type === base.Type && x.Id !== base.Id);
    for (const [x] of sameKind.map((x) => [x, single.similarity(x)] as const).sort((a, b) => b[1] - a[1]).slice(0, 80)) pool.set(x.Id, x);
    pool.delete(base.Id);
    const candidates = [...pool.values()].filter((x) => !x.UserData?.Played && !this.isNotForMe(x));
    if (!candidates.length) return [];

    const semantic = new Map<string, number>();
    if (useAI) {
      let timer: ReturnType<typeof setTimeout> | undefined;
      const vecs = await Promise.race([embed([base, ...candidates].map(itemInput)), new Promise<null>((r) => { timer = setTimeout(() => r(null), aiWaitMs); })]).catch(() => null);
      clearTimeout(timer);
      const bv = vecs?.get(base.Id);
      if (vecs && bv) for (const x of candidates) { const v = vecs.get(x.Id); if (v) semantic.set(x.Id, cosine(bv, v)); }
    }
    const sims = [...semantic.values()].sort((a, b) => a - b);
    const lo = sims[0] ?? 0, hi = sims[sims.length - 1] ?? 1;
    const span = Math.max(hi - lo, 0.0001);
    const score = (x: Item) => {
      const tag = single.similarity(x);
      const mine = (this.match(x) ?? 60) / 100;
      const s = semantic.get(x.Id);
      return s !== undefined ? 0.45 * ((s - lo) / span) + 0.35 * tag + 0.2 * mine : 0.65 * tag + 0.35 * mine;
    };
    const ranked = candidates.map((x) => ({ x, s: score(x) })).sort((a, b) => b.s - a.s).slice(0, 30);
    const top = Math.max(ranked[0]?.s ?? 1, 0.0001);
    return ranked.map(({ x, s }) => ({ item: x, match: Math.round(Math.max(0.5, Math.min(0.99, 0.5 + 0.49 * (s / top))) * 100) }));
  }
}
