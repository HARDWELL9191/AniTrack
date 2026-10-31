// For You: new titles to get, from TMDB, based on what you watched on your server. The same steps,
// limits and weights as the iPhone app's DiscoveryEngine (JellyReco/AI/External/DiscoveryEngine.swift):
//
// 1. Taste: what you finished, favourited, are watching, gave up on or marked Not for me, in the
//    chosen library (counts 1.5×) and the rest of your server (read-only).
// 2. Your strongest likes are found on TMDB by the ids Jellyfin stored (TMDB, else IMDb/TVDB, else
//    a title search) and TMDB's "people who liked this also liked" lists are collected, weighted by
//    how much you liked each one.
// 3. Well-rated titles in your favourite genres are added (anime = Animation + Japanese).
// 4. Anything already on your server is removed (TMDB/IMDb/TVDB id or title + year), and anything
//    on My List or marked Already seen / Not for me.
// 5. The short list is re-ranked here: genre/keyword match with your taste and the on-device AI
//    comparing each overview with your favourites (and away from what you passed on).

import { type EmbedInput, embed, ALL, type Reco, type Source, TasteProfile, itemInput } from "./reco";
import type { AccountStorage } from "./storage";
import { type ExternalTitle, isAnime, isMovie, titleId, titleKey } from "./titles";
import type { Tmdb } from "./tmdb";
import { cosine, normalized, accumulate } from "./ai";
import type { Item } from "./types";

export interface ExternalPick {
  title: ExternalTitle;
  score: number;
  match: number;
  because: string[];
  highlights: string[];
}

type Kind = "animeShows" | "animeMovies" | "movies" | "shows" | "mixed" | "all";

/** What a library means, from its name and type (the iPhone's rules). */
export function kindOf(source: Source | undefined): Kind {
  if (!source || source.id === ALL) return "all";
  const name = source.name.toLowerCase();
  const moviesish = name.includes("movie") || name.includes("film") || source.collectionType === "movies";
  if (name.includes("anime")) return moviesish ? "animeMovies" : "animeShows";
  if (source.collectionType === "movies") return "movies";
  if (source.collectionType === "tvshows") return "shows";
  return moviesish ? "movies" : "mixed";
}

const provider = (i: Item, name: string) => {
  const ids = i.ProviderIds ?? {};
  const k = Object.keys(ids).find((x) => x.toLowerCase() === name.toLowerCase());
  return k ? ids[k] ?? null : null;
};

/** TMDB TV uses combined genres ("Action & Adventure"); Jellyfin libraries usually have both halves. */
const splitGenre = (g: string) => (g.includes("&") ? [...g.split("&").map((x) => x.trim()), g] : [g]);

/** A TMDB title shaped like a library item, so the same taste profile can score it. */
export const pseudoItem = (t: ExternalTitle) => ({ Genres: t.genres.flatMap(splitGenre), Tags: t.tags, ProductionYear: t.year ?? null });

const quality = (t: ExternalTitle) => {
  const s = (t.score ?? 6) / 10;
  const confidence = Math.min(1, Math.log10(Math.max(t.voteCount ?? 1, 1)) / 4); // 10k votes = full confidence
  return s * (0.6 + 0.4 * confidence);
};

export const titleInput = (t: ExternalTitle): EmbedInput => ({
  key: titleId(t),
  text: `${t.title}. ${t.genres.join(", ")}. ${t.tags.slice(0, 6).join(", ")}. ${t.overview.slice(0, 500)}`,
});

/** Everything on the server, indexed every way a TMDB title could match it. */
export class OwnedIndex {
  private movieIds = new Map<number, Item>();
  private tvIds = new Map<number, Item>();
  private imdb = new Map<string, Item>();
  private tvdb = new Map<number, Item>();
  private titles = new Map<string, { year: number | null; item: Item }[]>();

  constructor(items: Item[], idMap: Record<string, number>) {
    for (const i of items) {
      const tmdbId = Number(provider(i, "Tmdb")) || idMap[i.Id];
      if (tmdbId) (i.Type === "Series" ? this.tvIds : this.movieIds).set(tmdbId, i);
      const im = provider(i, "Imdb");
      if (im) this.imdb.set(im, i);
      const tv = Number(provider(i, "Tvdb"));
      if (tv) this.tvdb.set(tv, i);
      for (const name of [i.Name, i.OriginalTitle]) {
        if (!name) continue;
        const k = titleKey(name);
        this.titles.set(k, [...(this.titles.get(k) ?? []), { year: i.ProductionYear ?? null, item: i }]);
      }
    }
  }

  contains(t: ExternalTitle): boolean { return !!this.find(t); }

  /** The library title that is this TMDB title (by TMDB / IMDb / TVDB id, else by name and year). */
  find(t: ExternalTitle): Item | undefined {
    const byId = (isMovie(t) ? this.movieIds : this.tvIds).get(t.sourceId) ?? (t.imdbId ? this.imdb.get(t.imdbId) : undefined) ?? (t.tvdbId ? this.tvdb.get(t.tvdbId) : undefined);
    if (byId) return byId;
    for (const name of [t.title, t.originalTitle]) {
      if (!name) continue;
      const k = titleKey(name);
      const found = this.titles.get(k);
      if (k.length < 3 || !found) continue;
      // Same title within a year (or no year known) = the same work.
      const sameYear = !t.year ? found[0] : found.find((f) => f.year === null || Math.abs(f.year - (t.year ?? 0)) <= 1);
      if (sameYear) return sameYear.item;
      // A series you have under the same name (later seasons are part of the same TMDB show).
      if (!isMovie(t)) return found[0].item;
    }
    return undefined;
  }
}

export interface DiscoveryContext {
  reco: Reco;
  tmdb: Tmdb;
  storage: AccountStorage | null;
  sources: Source[];
  serverId: string;
  userId: string;
  useAI: boolean;
}

// The iPhone keeps its TMDB id map and picks on the device: here they're in this PC's app storage.
const ID_MAP_KEY = "tmdb-idmap";
function loadIdMap(): Record<string, number> {
  try { return JSON.parse(localStorage.getItem(ID_MAP_KEY) ?? "{}") as Record<string, number>; } catch { return {}; }
}
function saveIdMap(m: Record<string, number>) { try { localStorage.setItem(ID_MAP_KEY, JSON.stringify(m)); } catch { /* */ } }

/** How long For You waits for the on-device AI (its first start can take longer; it carries on in the background). */
const AI_WAIT_MS = 25_000;

export class Discovery {
  picks = new Map<string, ExternalPick[]>();
  building = new Set<string>();
  errors = new Map<string, string>();
  status = new Map<string, string>();
  builtAt = new Map<string, number>();
  usedAI = false;
  private generation = new Map<string, number>();
  private idMap = loadIdMap();
  private onChange: () => void;
  constructor(onChange: () => void) { this.onChange = onChange; }

  /** Forgets every pick (new key, account or server). `quiet`: no screen update (called while drawing). */
  reset(quiet = false) {
    this.picks.clear(); this.errors.clear(); this.status.clear(); this.building.clear(); this.builtAt.clear(); this.generation.clear();
    if (!quiet) this.onChange();
  }

  private cacheName(c: DiscoveryContext, sourceId: string) { return `reco-ext-${c.serverId}-${c.userId}-${sourceId}`; }

  /** Picks to show: never anything on My List or marked Not for me / Already seen since. */
  visible(c: DiscoveryContext, sourceId: string, genre: string | null): ExternalPick[] {
    const hidden = c.storage?.hiddenIds() ?? new Set<string>();
    return (this.picks.get(sourceId) ?? []).filter((p) => !hidden.has(titleId(p.title)) && (!genre || p.title.genres.includes(genre)));
  }

  /** The second dropdown: genres of this library's picks (two or more), most common first. */
  genres(sourceId: string): string[] {
    const counts = new Map<string, number>();
    for (const p of this.picks.get(sourceId) ?? []) for (const g of p.title.genres) counts.set(g, (counts.get(g) ?? 0) + 1);
    return [...counts].filter(([, n]) => n >= 2).sort((a, b) => b[1] - a[1]).map(([g]) => g);
  }

  /** Shows the last picks saved on this PC at once, then builds fresh ones (if there are none yet). */
  async ensureBuilt(c: DiscoveryContext, sourceId: string) {
    if (this.picks.get(sourceId)?.length) return;
    try {
      const saved = JSON.parse(localStorage.getItem(this.cacheName(c, sourceId)) ?? "null") as ExternalPick[] | null;
      if (Array.isArray(saved) && saved.length) { this.picks.set(sourceId, saved); this.onChange(); }
    } catch { /* */ }
    await this.build(c, sourceId, null);
  }

  async build(c: DiscoveryContext, sourceId: string, genre: string | null) {
    // Only the newest build of a library owns its spinner and status.
    const gen = (this.generation.get(sourceId) ?? 0) + 1;
    this.generation.set(sourceId, gen);
    const mine = () => this.generation.get(sourceId) === gen;
    const step = (text: string) => { if (mine()) { this.status.set(sourceId, text); this.onChange(); } };
    const fail = (text: string) => {
      if (!mine()) return;
      this.errors.set(sourceId, text);
      if (!genre && !this.picks.has(sourceId)) this.picks.set(sourceId, []);
    };
    this.building.add(sourceId);
    this.errors.delete(sourceId);
    this.onChange();
    try {
      await this.run(c, sourceId, genre, step, fail, mine);
    } catch (e) {
      fail((e as Error).message);
    } finally {
      if (mine()) { this.building.delete(sourceId); this.status.delete(sourceId); }
      this.onChange();
    }
  }

  private async tmdbId(i: Item, tmdb: Tmdb): Promise<number | null> {
    const known = this.idMap[i.Id];
    if (known) return known;
    const tv = i.Type === "Series";
    let found: number | null = Number(provider(i, "Tmdb")) || null;
    const im = provider(i, "Imdb"), tvdb = provider(i, "Tvdb");
    if (!found && im) found = await tmdb.find(im, "imdb_id", tv);
    if (!found && tvdb && tv) found = await tmdb.find(tvdb, "tvdb_id", tv);
    if (!found) found = await tmdb.search(i.OriginalTitle ?? i.Name ?? "", i.ProductionYear, tv);
    if (!found && i.OriginalTitle) found = await tmdb.search(i.Name ?? "", i.ProductionYear, tv);
    if (found) this.idMap[i.Id] = found;
    return found;
  }

  private async run(c: DiscoveryContext, sourceId: string, genre: string | null, step: (t: string) => void, fail: (t: string) => void, mine: () => boolean) {
    const { reco, tmdb } = c;
    tmdb.resetStats();
    step("Reading your library…");
    try { await reco.ensure(); } catch (e) { fail(`Couldn't read your library: ${(e as Error).message}`); return; }
    if (!reco.ready) { fail(reco.error ? `Couldn't read your library: ${reco.error}` : "Couldn't read your library from the server. Refresh to try again."); return; }
    step("Connecting to TMDB…");
    try { await tmdb.loadGenres(); } catch (e) { fail((e as Error).message); return; }

    const source = c.sources.find((s) => s.id === sourceId);
    const kind = kindOf(source);
    // Everything you watched teaches; this library's history counts 1.5×.
    const history = reco.history(sourceId);
    if (!history.length) { fail("Finish or favourite a few titles on your server first: For You learns from them."); return; }
    const profile = new TasteProfile();
    for (const h of history) profile.add(h.item, h.weight);
    profile.finalize();

    // 1) Seeds on TMDB: your strongest likes of the right kind.
    const wantsTV = kind === "animeShows" || kind === "shows" ? true : kind === "animeMovies" || kind === "movies" ? false : null;
    const isAnimeLike = (i: Item) => {
      const g = (i.Genres ?? []).map((x) => x.toLowerCase());
      return g.includes("anime") || (g.includes("animation") && (i.ProductionLocations ?? []).some((p) => /japan/i.test(p)));
    };
    const seeds = history
      .filter((h) => h.weight > 0.6)
      .filter((h) => wantsTV === null || (h.item.Type === "Series") === wantsTV)
      .filter((h) => (kind === "animeShows" || kind === "animeMovies" ? reco.itemLibrary.get(h.item.Id) === sourceId || isAnimeLike(h.item) : true))
      .sort((a, b) => b.weight - a.weight)
      .slice(0, 18);
    const votes = new Map<string, number>();
    const reasons = new Map<string, string[]>();
    const candidates = new Map<string, ExternalTitle>();
    step(`Finding ${seeds.length} of your favourites on TMDB…`);
    const results = await Promise.all(seeds.map(async (seed) => {
      const id = await this.tmdbId(seed.item, tmdb);
      if (!id) return { seed, recs: [] as ExternalTitle[] };
      const tv = seed.item.Type === "Series";
      const page1 = await tmdb.recommendations(id, tv).catch(() => [] as ExternalTitle[]);
      const page2 = seed.weight > 1.2 ? await tmdb.recommendations(id, tv, 2).catch(() => [] as ExternalTitle[]) : [];
      return { seed, recs: [...page1, ...page2] };
    }));
    for (const { seed, recs } of results) {
      recs.forEach((rec, rank) => {
        const k = titleId(rec);
        votes.set(k, (votes.get(k) ?? 0) + seed.weight * (1 - rank / 45));
        if (!candidates.has(k)) candidates.set(k, rec);
        const r = reasons.get(k) ?? [];
        const name = seed.item.Name ?? "";
        if (name && !r.includes(name)) r.push(name);
        reasons.set(k, r);
      });
    }
    if (!mine()) return;

    // 2) Explore: well-rated titles in your top genres (and the chosen category).
    step("Exploring your favourite genres…");
    const topGenres = profile.top("g:", 4);
    const hasAnimeLibrary = c.sources.some((s) => /anime/i.test(s.name));
    const animeFilter = kind === "animeShows" || kind === "animeMovies" ? true : kind === "all" ? null : hasAnimeLibrary ? false : null;
    for (const tv of wantsTV === null ? [true, false] : [wantsTV]) {
      let genreIds = topGenres.map((g) => tmdb.genreId(g)).filter((x): x is number => x !== null);
      if (genre) { const gid = tmdb.genreId(genre); if (gid !== null) genreIds = [gid]; }
      for (const gid of genreIds.slice(0, 3)) {
        for (const page of [1, 2]) {
          for (const t of await tmdb.discover({ tv, genreIds: [gid], anime: animeFilter, page, minVotes: animeFilter === true ? 80 : 300 }).catch(() => [] as ExternalTitle[])) {
            if (!candidates.has(titleId(t))) candidates.set(titleId(t), t);
          }
        }
      }
      if (!genre) {
        for (const t of await tmdb.discover({ tv, genreIds: [], anime: animeFilter, page: 1, sort: "popularity.desc", minVotes: 150 }).catch(() => [] as ExternalTitle[])) {
          if (!candidates.has(titleId(t))) candidates.set(titleId(t), t);
        }
      }
    }
    if (!mine()) return;
    if (!candidates.size) {
      fail(tmdb.failed > 0 ? `TMDB didn't answer (${tmdb.failed} requests failed). ${tmdb.lastFailure ?? ""}` : "TMDB found nothing for your favourites. Refresh to try again.");
      return;
    }

    // 3) Never anything you already have, have seen, put on My List or passed on.
    step("Removing what you already have…");
    const owned = new OwnedIndex(reco.owned, this.idMap);
    const hidden = c.storage?.hiddenIds() ?? new Set<string>();
    const thisYear = new Date().getFullYear();
    const allowed = (t: ExternalTitle) => {
      if (owned.contains(t) || hidden.has(titleId(t)) || t.isAdult) return false;
      if (wantsTV !== null && isMovie(t) === wantsTV) return false;
      if (animeFilter === true && !isAnime(t)) return false;
      if (animeFilter === false && isAnime(t)) return false;
      if (!t.overview || (t.voteCount ?? 0) < 15) return false;
      if (t.year && t.year > thisYear) return false;
      return !!t.year;
    };
    const maxVote = Math.max(...votes.values(), 0.0001);
    type Scored = { title: ExternalTitle; collab: number; tag: number; quality: number; score: number };
    let shortlist: Scored[] = [...candidates.values()].filter(allowed).map((t) => {
      const collab = (votes.get(titleId(t)) ?? 0) / maxVote;
      const tag = Math.max(0, profile.similarity(pseudoItem(t)));
      const q = quality(t);
      return { title: t, collab, tag, quality: q, score: 0.45 * collab + 0.35 * tag + 0.2 * q };
    }).sort((a, b) => b.score - a.score).slice(0, 90);

    // 4) Details for the short list: keywords (tags) and IMDb/TVDB ids, then ownership again.
    step(`Reading details of ${shortlist.length} titles…`);
    for (let i = 0; i < shortlist.length; i += 8) {
      const batch = shortlist.slice(i, i + 8);
      const detailed = await Promise.all(batch.map((s) => tmdb.details(s.title)));
      detailed.forEach((d, j) => { batch[j].title = d; });
    }
    shortlist = shortlist.filter((s) => !owned.contains(s.title));
    for (const s of shortlist) s.tag = Math.max(0, profile.similarity(pseudoItem(s.title)));
    if (!mine()) return;

    // 5) On-device AI: overviews compared with your favourites' (and away from what you passed on).
    const semantic = new Map<string, number>();
    const nearest = new Map<string, string[]>();
    if (c.useAI && shortlist.length) {
      step("Ranking with on-device AI…");
      const anchors = history.filter((h) => Math.abs(h.weight) >= 0.5 && (h.item.Overview ?? "").trim()).sort((a, b) => Math.abs(b.weight) - Math.abs(a.weight)).slice(0, 50);
      const dislikes = (c.storage?.notForMe ?? []).slice(0, 40);
      const inputs = [...anchors.map((a) => itemInput(a.item)), ...dislikes.map(titleInput), ...shortlist.map((s) => titleInput(s.title))];
      // The model can be slow to start the first time: never wait more than 25 s.
      let timer: ReturnType<typeof setTimeout> | undefined;
      const vectors = (await Promise.race([embed(inputs), new Promise<null>((r) => { timer = setTimeout(() => r(null), AI_WAIT_MS); })]).catch(() => null)) ?? new Map<string, Float32Array>();
      clearTimeout(timer);
      let taste: Float32Array | null = null;
      const liked: [string, Float32Array][] = [];
      for (const a of anchors) {
        const v = vectors.get(a.item.Id);
        if (!v) continue;
        if (!taste) taste = new Float32Array(v.length);
        accumulate(v, a.weight, taste);
        if (a.weight > 0.8) liked.push([a.item.Name ?? "", v]);
      }
      for (const d of dislikes) { const v = vectors.get(titleId(d)); if (v && taste) accumulate(v, -0.8, taste); }
      if (taste) {
        const tv = normalized(taste);
        const raw = new Map<string, number>();
        for (const s of shortlist) {
          const v = vectors.get(titleId(s.title));
          if (!v) continue;
          raw.set(titleId(s.title), cosine(tv, v));
          nearest.set(titleId(s.title), liked.map(([n, lv]) => [n, cosine(lv, v)] as const).sort((a, b) => b[1] - a[1]).slice(0, 2).map(([n]) => n));
        }
        const sorted = [...raw.values()].sort((a, b) => a - b);
        if (sorted.length) {
          const lo = sorted[0], span = Math.max(sorted[sorted.length - 1] - lo, 0.0001);
          for (const [k, x] of raw) semantic.set(k, (x - lo) / span);
        }
      }
    }
    this.usedAI = semantic.size > 0;

    for (const s of shortlist) {
      const sem = semantic.get(titleId(s.title));
      s.score = sem !== undefined ? 0.3 * s.collab + 0.24 * s.tag + 0.34 * sem + 0.12 * s.quality : 0.45 * s.collab + 0.37 * s.tag + 0.18 * s.quality;
    }
    shortlist.sort((a, b) => b.score - a.score);
    const top = Math.max(shortlist[0]?.score ?? 1, 0.0001);
    const result: ExternalPick[] = shortlist.slice(0, 60).map((s) => ({
      title: s.title,
      score: s.score,
      match: Math.round(Math.max(0.5, Math.min(0.99, 0.56 + 0.43 * (s.score / top))) * 100),
      because: (reasons.get(titleId(s.title)) ?? nearest.get(titleId(s.title)) ?? []).slice(0, 3),
      highlights: profile.highlights(pseudoItem(s.title)),
    }));
    if (!mine()) return;
    if (!result.length) {
      fail(`Everything TMDB suggested (${candidates.size} titles) is already on your server, on My List, or marked Already seen / Not for me. Refresh to try again, or pick another category.`);
      return;
    }
    if (genre) {
      // A category build adds to the library's list instead of replacing it.
      const merged = [...(this.picks.get(sourceId) ?? [])];
      const known = new Set(merged.map((p) => titleId(p.title)));
      merged.push(...result.filter((p) => !known.has(titleId(p.title)) && p.title.genres.includes(genre)));
      this.picks.set(sourceId, merged);
    } else {
      this.picks.set(sourceId, result);
    }
    this.builtAt.set(sourceId, Date.now());
    try { localStorage.setItem(this.cacheName(c, sourceId), JSON.stringify(this.picks.get(sourceId))); } catch { /* */ }
    saveIdMap(this.idMap);
  }

  /** "More like this" for an outside title: TMDB's also-liked list, minus anything you have. */
  async moreLike(c: DiscoveryContext, t: ExternalTitle): Promise<ExternalTitle[]> {
    await c.reco.ensure().catch(() => {});
    const owned = new OwnedIndex(c.reco.owned, this.idMap);
    const hidden = c.storage?.hiddenIds() ?? new Set<string>();
    const recs = await c.tmdb.recommendations(t.sourceId, !isMovie(t)).catch(() => [] as ExternalTitle[]);
    return recs.filter((x) => !owned.contains(x) && !hidden.has(titleId(x)) && !x.isAdult);
  }

  /** Is an outside title on your server now (you added it since)? */
  ownedNow(c: DiscoveryContext, t: ExternalTitle) { return !!this.ownedItem(c, t); }
  /** The server title a pick turned into once it was added to the server (My List's green cloud). */
  ownedItem(c: DiscoveryContext, t: ExternalTitle): Item | undefined {
    const ids = Object.keys(this.idMap).length;
    if (this.ownedIndexFor !== c.reco.owned || this.ownedIndexIds !== ids) { this.ownedIndex = new OwnedIndex(c.reco.owned, this.idMap); this.ownedIndexFor = c.reco.owned; this.ownedIndexIds = ids; }
    return this.ownedIndex!.find(t);
  }
  private ownedIndex: OwnedIndex | null = null;
  private ownedIndexFor: Item[] | null = null;
  private ownedIndexIds = -1;
}
