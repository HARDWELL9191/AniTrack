// For You picks (port of Recommender.swift): AniList fan recommendations from the shows you
// rated highly, genre/tag similarity to your taste, on-device synopsis similarity, and the
// community score.

import { accumulate, cosine, normalized, vectorsFor } from "./ai";
import { AniListClient, Queries } from "./anilist";
import {
  type AnimeCategory, categoryId, categoryMatches, categoryVariables, displayTitle, isAdultOnly, isLaterSeason, isMovie,
  type ListEntry, ListFranchises, type Media, scoreValue, type TitleLanguage,
} from "./models";
import { type Found, SeasonRoots } from "./seasons";

export interface Recommendation {
  id: number;
  media: Media;
  score: number;
  match: number;
  because: string[];
  sharedHighlights: string[];
}

export interface RecommendationResult {
  picks: Recommendation[];
  generatedAt: number;
  fingerprint: number;
  usedOnDeviceAI: boolean;
  round: number;
  exhausted: boolean;
}

export interface RecOptions {
  hideChinese: boolean;
  includeUnreleased: boolean;
  dismissed: Set<number>;
  titleLanguage: TitleLanguage;
  useOnDeviceAI: boolean;
  category?: AnimeCategory | null;
  aiAllowedNow: boolean;
}

/** FNV-1a over the list, so the fingerprint survives restarts. */
export function fingerprint(entries: ListEntry[], o: RecOptions): number {
  let text = "";
  for (const e of [...entries].sort((a, b) => a.id - b.id)) text += `${e.id}:${e.status}:${Math.trunc(scoreValue(e))};`;
  text += `|${o.hideChinese}|${o.includeUnreleased}|${o.useOnDeviceAI}|${o.category ? categoryId(o.category) : "any"}|`;
  let hash = 0x811c9dc5;
  for (const byte of new TextEncoder().encode(text)) {
    hash ^= byte;
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  return hash;
}

// MARK: Taste profile

export class TasteProfile {
  features = new Map<string, number>();
  norm = 0;

  static vector(m: Media): Map<string, number> {
    const v = new Map<string, number>();
    for (const g of m.genres ?? []) v.set("g:" + g, 1);
    for (const t of m.tags ?? []) {
      const rank = (t.rank ?? 50) / 100;
      if (rank >= 0.3) v.set("t:" + t.name, rank);
    }
    return v;
  }

  add(m: Media, weight: number) {
    for (const [k, value] of TasteProfile.vector(m)) this.features.set(k, (this.features.get(k) ?? 0) + value * weight);
  }

  finalize() {
    let s = 0;
    for (const v of this.features.values()) s += v * v;
    this.norm = Math.sqrt(s);
  }

  similarity(m: Media): number {
    if (!(this.norm > 0)) return 0;
    const v = TasteProfile.vector(m);
    let vn = 0;
    for (const x of v.values()) vn += x * x;
    vn = Math.sqrt(vn);
    if (!(vn > 0)) return 0;
    let dot = 0;
    for (const [k, x] of v) dot += x * (this.features.get(k) ?? 0);
    return dot / (this.norm * vn);
  }

  /** Similarity without this show's own contribution (leave-one-out). */
  similarityExcluding(m: Media, w: number): number {
    if (w === 0) return this.similarity(m);
    const v = TasteProfile.vector(m);
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

  highlights(m: Media, limit = 3): string[] {
    return [...TasteProfile.vector(m)]
      .map(([k, v]) => [k, (this.features.get(k) ?? 0) * v] as const)
      .filter(([, w]) => w > 0)
      .sort((a, b) => b[1] - a[1])
      .slice(0, limit)
      .map(([k]) => k.slice(2));
  }

  top(prefix: string, count: number): string[] {
    return [...this.features]
      .filter(([k, v]) => k.startsWith(prefix) && v > 0)
      .sort((a, b) => b[1] - a[1])
      .slice(0, count)
      .map(([k]) => k.slice(prefix.length));
  }
}

/** How strongly an entry says "I liked this" (positive) or "not for me" (negative). */
export function entryWeight(e: ListEntry, mean: number, spread: number): number {
  const score = scoreValue(e);
  if (score > 0) {
    switch (e.status) {
      case "COMPLETED":
      case "REPEATING":
      case "PLANNING": {
        const t = Math.min(1, score / 100);
        return 0.3 + 1.7 * t * t;
      }
      case "DROPPED":
        return -1.0 - 0.5 * (1 - Math.min(1, score / 100));
      default: {
        const w = (score - mean) / Math.max(spread, 8) + 0.6;
        return Math.min(2.0, Math.max(-1.0, w));
      }
    }
  }
  switch (e.status) {
    case "COMPLETED":
    case "REPEATING": return 0.7;
    case "CURRENT": return 0.5;
    case "PLANNING": return 0.5;
    case "PAUSED": return 0.1;
    case "DROPPED": return -1.0;
  }
}

export function scoreStats(entries: ListEntry[]) {
  const scored = entries.map(scoreValue).filter((s) => s > 0);
  const mean = scored.length ? scored.reduce((a, b) => a + b, 0) / scored.length : 70;
  const variance = scored.length ? scored.reduce((a, s) => a + (s - mean) * (s - mean), 0) / scored.length : 0;
  return { mean, spread: Math.sqrt(variance) };
}

// MARK: Seasons

async function collapseSeasons(candidates: Map<number, Media>, collab: Map<number, number>, reasons: Map<number, string[]>,
  onList: Map<number, ListEntry>, client: AniListClient): Promise<Map<number, Media>> {
  const franchises = new ListFranchises([...onList.values()].map((e) => e.media));
  const later = [...candidates.values()].filter(isLaterSeason);
  let found = new Map<number, Found>();
  if (later.length) found = await SeasonRoots.resolve(later, candidates, client, true);
  const result = new Map<number, Media>();
  for (const [id, media] of candidates) {
    if (franchises.contains(media)) continue;
    if (!isLaterSeason(media)) {
      if (!result.has(id)) result.set(id, media);
      continue;
    }
    const f = found.get(id);
    if (f?.chain.some((c) => onList.has(c))) continue;
    const root = f?.root ?? media;
    if (root.id !== id) {
      if (onList.has(root.id) || franchises.contains(root)) continue;
      collab.set(root.id, (collab.get(root.id) ?? 0) + (collab.get(id) ?? 0));
      const rootReasons = reasons.get(root.id) ?? [];
      for (const r of reasons.get(id) ?? []) if (!rootReasons.includes(r)) rootReasons.push(r);
      reasons.set(root.id, rootReasons);
    }
    result.set(root.id, root);
  }
  return result;
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

type SeedPage = { Page: { media: { id: number; recommendations?: { nodes?: { rating?: number | null; mediaRecommendation?: Media | null }[] | null } | null }[] } };
type PageData = { Page: { media: Media[] } };

/** New picks for `round` (1 = first screen). `exclude` holds ids already shown. */
export async function runRecommender(entries: ListEntry[], client: AniListClient, options: RecOptions, round = 1,
  exclude: Set<number> = new Set()): Promise<{ picks: Recommendation[]; usedAI: boolean; fanSignal: Map<number, number> }> {
  const { mean, spread } = scoreStats(entries);
  const profile = new TasteProfile();
  const weights = new Map<number, number>();
  for (const e of entries) {
    const w = entryWeight(e, mean, spread);
    weights.set(e.mediaId, w);
    if (w !== 0) profile.add(e.media, w);
  }
  profile.finalize();
  const onList = new Map<number, ListEntry>();
  for (const e of entries) if (!onList.has(e.mediaId)) onList.set(e.mediaId, e);

  const seeds = entries
    .filter((e) => (weights.get(e.mediaId) ?? 0) > 0.3)
    .sort((a, b) => {
      const wa = weights.get(a.mediaId) ?? 0, wb = weights.get(b.mediaId) ?? 0;
      return wa === wb ? (b.updatedAt ?? 0) - (a.updatedAt ?? 0) : wb - wa;
    })
    .slice(0, 30);

  const collab = new Map<number, number>();
  const reasons = new Map<number, string[]>();
  let candidates = new Map<number, Media>();

  // 1) Fan recommendations from your top shows (deeper pages on later rounds).
  let firstBatch = true;
  for (let i = 0; i < seeds.length; i += 6) {
    const ids = seeds.slice(i, i + 6).map((e) => e.mediaId);
    try {
      const data = await client.run<SeedPage>(Queries.seedRecommendations, { ids, perPage: ids.length, recsPage: round, recsPerMedia: 8 });
      for (const seedMedia of data.Page.media) {
        const seed = onList.get(seedMedia.id);
        if (!seed) continue;
        const seedWeight = weights.get(seedMedia.id) ?? 0.5;
        const seedTitle = displayTitle(seed.media, options.titleLanguage);
        for (const node of seedMedia.recommendations?.nodes ?? []) {
          const rec = node.mediaRecommendation;
          if (!rec || rec.id === seedMedia.id) continue;
          const rating = Math.max(node.rating ?? 0, 0);
          if (!(rating > 0)) continue;
          collab.set(rec.id, (collab.get(rec.id) ?? 0) + seedWeight * Math.log(1 + rating));
          candidates.set(rec.id, rec);
          const r = reasons.get(rec.id) ?? [];
          if (!r.includes(seedTitle)) r.push(seedTitle);
          reasons.set(rec.id, r);
        }
      }
    } catch (e) {
      if (firstBatch && round === 1) throw e;
    }
    firstBatch = false;
    await sleep(300);
  }

  // 2) Explore beyond what fans linked: your top tags/genres, and the chosen category.
  const excludeIds = [...onList.keys()];
  const topTags = profile.top("t:", 3);
  const topGenres = profile.top("g:", 2);
  const adultOnly = isAdultOnly(options.category);
  const base = { page: round, perPage: 40, isAdult: adultOnly, excludeIds, formatNot: ["MOVIE"] };
  const explorations: Record<string, unknown>[] = [];
  const category = options.category;
  if (category) {
    explorations.push({ ...categoryVariables(category), ...base, sort: ["SCORE_DESC"] });
    explorations.push({ ...categoryVariables(category), ...base, sort: ["POPULARITY_DESC"] });
    if (topTags[0] && category.kind === "genre") explorations.push({ ...categoryVariables(category), ...base, tags: [topTags[0]], sort: ["SCORE_DESC"] });
  } else {
    if (topTags.length) explorations.push({ ...base, tags: topTags, sort: ["SCORE_DESC"] });
    if (topGenres.length) {
      const vars: Record<string, unknown> = { ...base, genres: topGenres, sort: ["POPULARITY_DESC"] };
      if (topTags[0]) vars.tags = [topTags[0]];
      explorations.push(vars);
    }
  }
  for (const vars of explorations) {
    try {
      const data = await client.run<PageData>(Queries.browseWithRelations, vars);
      for (const m of data.Page.media) if (!candidates.has(m.id)) candidates.set(m.id, m);
    } catch {
      /* one exploration failing doesn't stop the round */
    }
    await sleep(300);
  }

  // 2b) One pick per show: Season 2+ becomes Season 1; shows you already have are skipped.
  candidates = await collapseSeasons(candidates, collab, reasons, onList, client);

  // 3) Cheap first pass (no AI) to pick a short list worth spending the AI work on.
  const maxCollab = Math.max(Math.max(0, ...collab.values()) || 1, 0.0001);
  const fanSignal = new Map<number, number>();
  for (const [id, c] of collab) fanSignal.set(id, Math.min(1, Math.max(0, c / maxCollab)));

  const allowed = (m: Media) => {
    if (onList.has(m.id) || exclude.has(m.id)) return false;
    if (m.isAdult === true && !adultOnly) return false;
    if (options.hideChinese && m.countryOfOrigin === "CN") return false;
    if (m.format === "MUSIC" || isMovie(m)) return false;
    if (!options.includeUnreleased && m.status === "NOT_YET_RELEASED") return false;
    if (options.dismissed.has(m.id)) return false;
    if (category && !categoryMatches(category, m)) return false;
    return true;
  };

  type Scored = { media: Media; collab: number; tagSim: number; quality: number; score: number };
  const pre: Scored[] = [];
  for (const [id, m] of candidates) {
    if (!allowed(m)) continue;
    const c = (collab.get(id) ?? 0) / maxCollab;
    const sim = Math.max(0, profile.similarity(m));
    const quality = (m.averageScore ?? m.meanScore ?? 60) / 100;
    pre.push({ media: m, collab: c, tagSim: sim, quality, score: 0.5 * c + 0.38 * sim + 0.12 * quality });
  }
  pre.sort((a, b) => b.score - a.score);
  const shortList = pre.slice(0, 80);

  // 4) On-device semantic re-rank of the short list.
  let usedAI = false;
  let ranked = shortList.map((s) => ({ media: s.media, score: s.score }));
  if (options.useOnDeviceAI && options.aiAllowedNow && shortList.length) {
    const anchors = entries
      .filter((e) => Math.abs(weights.get(e.mediaId) ?? 0) >= 0.4)
      .sort((a, b) => Math.abs(weights.get(b.mediaId) ?? 0) - Math.abs(weights.get(a.mediaId) ?? 0))
      .slice(0, 40)
      .map((e) => e.media);
    let vectors = new Map<number, Float32Array>();
    try {
      vectors = await vectorsFor([...anchors, ...shortList.map((s) => s.media)]);
    } catch {
      /* AI unavailable: keep the cheap ranking */
    }
    let taste: Float32Array | null = null;
    for (const m of anchors) {
      const v = vectors.get(m.id);
      if (!v) continue;
      if (!taste) taste = new Float32Array(v.length);
      accumulate(v, weights.get(m.id) ?? 0, taste);
    }
    if (taste) {
      taste = normalized(taste);
      const sims = shortList.map((s) => {
        const v = vectors.get(s.media.id);
        return v ? cosine(taste!, v) : null;
      });
      const known = sims.filter((x): x is number => x !== null);
      if (known.length) {
        const lo = Math.min(...known), hi = Math.max(...known);
        const span = Math.max(hi - lo, 0.0001);
        ranked = shortList.map((s, i) => {
          const semantic = sims[i] === null ? 0.5 : (sims[i]! - lo) / span;
          return { media: s.media, score: 0.38 * s.collab + 0.24 * s.tagSim + 0.28 * semantic + 0.1 * s.quality };
        });
        usedAI = true;
      }
    }
  }
  ranked.sort((a, b) => b.score - a.score);

  const top = Math.max(ranked[0]?.score ?? 1, 0.0001);
  const roundPenalty = (round - 1) * 0.04;
  const picks = ranked.slice(0, 40).map((item): Recommendation => {
    const ratio = item.score / top;
    const match = Math.round(Math.max(0.5, Math.min(0.99, 0.55 + 0.44 * ratio - roundPenalty)) * 100);
    return {
      id: item.media.id,
      media: item.media,
      score: item.score,
      match,
      because: (reasons.get(item.media.id) ?? []).slice(0, 3),
      sharedHighlights: profile.highlights(item.media),
    };
  });
  return { picks, usedAI, fanSignal };
}
