// Kitsu's free public API: age ratings and episode descriptions/thumbnails (port of Kitsu.swift).

import { AniListClient, getFetch, Queries } from "./anilist";
import { DiskCache } from "./cache";
import { Media } from "./models";

export interface AgeRating { code?: string | null; guide?: string | null }

export function ageLabel(r?: AgeRating | null): string | undefined {
  switch (r?.code?.toUpperCase()) {
    case "R18": return "18+";
    case "R": return "17+";
    case "PG": return r.guide?.toLowerCase().includes("13") ? "13+" : "PG";
    case "G": return "PG";
    default: return undefined;
  }
}

export function ageExplanation(r?: AgeRating | null): string | undefined {
  const label = ageLabel(r);
  if (!label) return undefined;
  const g = r?.guide?.trim();
  if (g) return `${label} · ${g}`;
  switch (r?.code?.toUpperCase()) {
    case "G": return "PG · All ages";
    case "PG": return "PG · Parental guidance";
    case "R": return "17+ · Restricted";
    case "R18": return "18+ · Adults only";
    default: return label;
  }
}

export interface EpisodeInfo { number: number; title?: string; description?: string; thumbnail?: string }

interface Mapping { kitsuId?: string; rating?: AgeRating; checkedAt: number }
export interface Lookup { id: number; mal?: number | null }

const BASE = "https://kitsu.app/api/edge";
const RATINGS_FILE = "kitsu-ratings-v1";
const RECHECK_AFTER = 86_400_000;

async function getJSON<T>(url: string): Promise<T | undefined> {
  try {
    const res = await getFetch()(url, { headers: { Accept: "application/vnd.api+json" } });
    if (res.status !== 200) return undefined;
    return JSON.parse(await res.text()) as T;
  } catch {
    return undefined;
  }
}

class KitsuClientImpl {
  private mappings: Record<number, Mapping> = {};
  private loaded: Promise<void> | null = null;
  private saveTimer: ReturnType<typeof setTimeout> | null = null;

  private load() {
    if (!this.loaded) {
      this.loaded = DiskCache.load<Record<number, Mapping>>(RATINGS_FILE).then((saved) => {
        if (saved) this.mappings = { ...saved, ...this.mappings };
      });
    }
    return this.loaded;
  }

  private scheduleSave() {
    if (this.saveTimer) clearTimeout(this.saveTimer);
    this.saveTimer = setTimeout(() => void DiskCache.save(RATINGS_FILE, this.mappings), 2000);
  }

  async savedRatings(ids: number[]): Promise<Map<number, AgeRating>> {
    await this.load();
    const out = new Map<number, AgeRating>();
    for (const id of ids) {
      const r = this.mappings[id]?.rating;
      if (r) out.set(id, r);
    }
    return out;
  }

  /** Ratings, 10 shows per request. `failed`: Kitsu couldn't be reached (try again later). */
  async ratings(lookups: Lookup[]): Promise<{ found: Map<number, AgeRating>; failed: boolean }> {
    await this.load();
    const found = new Map<number, AgeRating>();
    const toFetch: Lookup[] = [];
    const now = Date.now();
    const seen = new Set<number>();
    for (const l of lookups) {
      if (seen.has(l.id)) continue;
      seen.add(l.id);
      const m = this.mappings[l.id];
      if (m) {
        if (m.rating) { found.set(l.id, m.rating); continue; }
        if (now - m.checkedAt < RECHECK_AFTER) continue;
      }
      toFetch.push(l);
    }
    let failed = false;
    for (let i = 0; i < toFetch.length; i += 10) {
      const chunk = toFetch.slice(i, i + 10);
      const fetched = await this.fetchMappings("anilist/anime", chunk.map((l) => l.id));
      if (!fetched) { failed = true; break; }
      const unlinked = chunk.filter((l) => !fetched.has(l.id) && l.mal);
      if (unlinked.length) {
        const byMal = await this.fetchMappings("myanimelist/anime", unlinked.map((l) => l.mal!));
        if (byMal) for (const l of unlinked) { const m = byMal.get(l.mal!); if (m) fetched.set(l.id, m); }
      }
      for (const l of chunk) {
        const m = fetched.get(l.id) ?? { kitsuId: this.mappings[l.id]?.kitsuId, checkedAt: now };
        this.mappings[l.id] = m;
        if (m.rating) found.set(l.id, m.rating);
      }
    }
    if (toFetch.length) this.scheduleSave();
    return { found, failed };
  }

  async kitsuIdLookup(l: Lookup): Promise<{ id?: string; failed: boolean }> {
    await this.load();
    const known = this.mappings[l.id]?.kitsuId;
    if (known) return { id: known, failed: false };
    const { failed } = await this.ratings([l]);
    return { id: this.mappings[l.id]?.kitsuId, failed };
  }

  private async fetchMappings(site: string, ids: number[]): Promise<Map<number, Mapping> | undefined> {
    const url = `${BASE}/mappings?filter%5BexternalSite%5D=${site}&filter%5BexternalId%5D=${ids.join(",")}`
      + "&include=item&page%5Blimit%5D=20&fields%5Banime%5D=ageRating,ageRatingGuide";
    type R = {
      data?: { attributes?: { externalId?: string }; relationships?: { item?: { data?: { id: string; type: string } } } }[];
      included?: { id: string; type: string; attributes?: { ageRating?: string; ageRatingGuide?: string } }[];
    };
    const response = await getJSON<R>(url);
    if (!response) return undefined;
    const byKitsu = new Map<string, AgeRating>();
    for (const item of response.included ?? []) {
      if (item.type === "anime") byKitsu.set(item.id, { code: item.attributes?.ageRating, guide: item.attributes?.ageRatingGuide });
    }
    const out = new Map<number, Mapping>();
    for (const row of response.data ?? []) {
      const external = Number(row.attributes?.externalId);
      const item = row.relationships?.item?.data;
      if (!Number.isFinite(external) || !item || item.type !== "anime" || out.has(external)) continue;
      const rating = byKitsu.get(item.id);
      out.set(external, { kitsuId: item.id, rating: ageLabel(rating) ? rating : undefined, checkedAt: Date.now() });
    }
    return out;
  }

  async episodes(kitsuId: string, offset: number): Promise<{ episodes: EpisodeInfo[]; total?: number } | undefined> {
    const url = `${BASE}/anime/${kitsuId}/episodes?page%5Blimit%5D=20&page%5Boffset%5D=${offset}&sort=number`
      + "&fields%5Bepisodes%5D=number,canonicalTitle,description,synopsis,thumbnail";
    type R = {
      data?: { attributes?: { number?: number; canonicalTitle?: string; description?: string; synopsis?: string; thumbnail?: { original?: string } } }[];
      meta?: { count?: number };
    };
    const response = await getJSON<R>(url);
    if (!response) return undefined;
    const episodes: EpisodeInfo[] = [];
    for (const row of response.data ?? []) {
      const a = row.attributes;
      if (!a || a.number == null) continue;
      const text = [a.description, a.synopsis].map((s) => s?.trim()).find((s) => !!s);
      episodes.push({ number: a.number, title: a.canonicalTitle?.trim() || undefined, description: text, thumbnail: a.thumbnail?.original ?? undefined });
    }
    return { episodes, total: response.meta?.count };
  }
}

export const KitsuClient = new KitsuClientImpl();

/** Age ratings for covers on screen, gathered for a moment and asked for in batches. */
export class AgeRatings {
  ratings = new Map<number, AgeRating>();
  onChange: () => void = () => {};
  private requested = new Set<number>();
  private pending = new Map<number, Lookup>();
  private timer: ReturnType<typeof setTimeout> | null = null;

  rating(id: number) {
    return this.ratings.get(id);
  }

  request(m: Media) {
    if (this.ratings.has(m.id) || this.requested.has(m.id)) return;
    this.requested.add(m.id);
    this.pending.set(m.id, { id: m.id, mal: m.idMal });
    if (this.timer) return;
    this.timer = setTimeout(() => void this.flush(), 250);
  }

  private async flush() {
    while (this.pending.size) {
      const batch = [...this.pending.values()].slice(0, 30);
      for (const l of batch) this.pending.delete(l.id);
      const saved = await KitsuClient.savedRatings(batch.map((l) => l.id));
      if (saved.size) { for (const [k, v] of saved) this.ratings.set(k, v); this.onChange(); }
      const missing = batch.filter((l) => !saved.has(l.id));
      if (!missing.length) continue;
      const { found, failed } = await KitsuClient.ratings(missing);
      if (found.size) { for (const [k, v] of found) this.ratings.set(k, v); this.onChange(); }
      if (failed) {
        for (const l of missing) if (!found.has(l.id)) this.requested.delete(l.id);
        for (const k of this.pending.keys()) this.requested.delete(k);
        this.pending.clear();
      }
    }
    this.timer = null;
  }
}

// MARK: Episodes

export interface EpisodePage {
  episodes: EpisodeInfo[];
  total: number;
  kitsuId?: string;
  kitsuLoaded: number;
  kitsuTotal?: number;
  savedAt: number;
  finished: boolean;
  sources?: "kitsu" | "anilist";
}

const pageComplete = (p: EpisodePage) => p.episodes.every((e) => e.description && e.thumbnail);

export function realTitle(t?: string | null): string | undefined {
  const s = t?.trim();
  if (!s) return undefined;
  if (/^(?:(?:episode|ep\.?)\s*\d+|untitled|tba|tbd|n\/a)$/i.test(s)) return undefined;
  return s;
}

export function similarTitles(a: string, b: string): boolean {
  const words = (s: string) => new Set(s.toLowerCase().split(/[^\p{L}\p{N}]+/u).filter((w) => w.length > 2));
  const x = words(a), y = words(b);
  if (!x.size || !y.size) return a.toLowerCase() === b.toLowerCase();
  let common = 0;
  for (const w of x) if (y.has(w)) common++;
  return common / Math.min(x.size, y.size) >= 0.5;
}

export const isPromo = (t?: string | null) => !!t && /^(?:PV|CM|trailer|teaser|promo|preview)\b/i.test(t.trim());

export function parseEpisodeTitle(raw: string | null | undefined, fallback: number): [number, string | undefined, boolean] {
  const s = raw?.trim();
  if (!s) return [fallback, undefined, false];
  const m = s.match(/^(?:Episode|Ep\.?)\s*(\d+)(\.\d+)?\s*[-–—:]?\s*(.*)$/i);
  if (m) {
    const title = m[3].trim();
    return [Number(m[1]) || fallback, title || undefined, m[2] !== undefined];
  }
  return [fallback, s, false];
}

const hasPrequel = (m: Media) =>
  (m.relations?.edges ?? []).some((e) => e.relationType === "PREQUEL" && (e.node?.type == null || e.node?.type === "ANIME"));

export function alignment(anilist: EpisodeInfo[], kitsu: EpisodeInfo[], laterPart: boolean, expected?: number | null, kitsuTotal?: number):
  "same" | "kitsuOnly" | "anilistOnly" {
  const kitsuTooLong = laterPart && expected != null && kitsuTotal != null && kitsuTotal > expected * 1.5 + 2;
  const titles = (eps: EpisodeInfo[]) => {
    const out = new Map<number, string>();
    for (const e of eps) if (!out.has(e.number)) { const t = realTitle(e.title); if (t) out.set(e.number, t); }
    return out;
  };
  const a = titles(anilist), k = titles(kitsu);
  const shared = [...a.keys()].filter((n) => k.has(n)).sort((x, y) => x - y).slice(0, 8);
  if (shared.length < 2) return kitsuTooLong ? "anilistOnly" : "same";
  const matching = shared.filter((n) => similarTitles(a.get(n)!, k.get(n)!)).length;
  if (matching * 2 >= shared.length) return "same";
  return kitsuTooLong ? "anilistOnly" : "kitsuOnly";
}

class EpisodeServiceImpl {
  private memory = new Map<number, EpisodePage>();
  private cacheName = (id: number) => `episodes3-${id}`;

  async saved(mediaId: number): Promise<EpisodePage | undefined> {
    const m = this.memory.get(mediaId);
    if (m) return m;
    const page = await DiskCache.load<EpisodePage>(this.cacheName(mediaId));
    if (page) this.memory.set(mediaId, page);
    return page;
  }

  isStale(p: EpisodePage) {
    return !this.isFresh(p);
  }

  private isFresh(p: EpisodePage) {
    const age = Date.now() - p.savedAt;
    if (!p.finished) return age < 12 * 3_600_000;
    return pageComplete(p) ? age < 30 * 86_400_000 : age < 86_400_000;
  }

  async firstPage(media: Media, client: AniListClient): Promise<EpisodePage> {
    const mem = this.memory.get(media.id);
    if (mem && this.isFresh(mem)) return mem;
    const saved = await DiskCache.load<EpisodePage>(this.cacheName(media.id));
    if (saved && this.isFresh(saved)) { this.memory.set(media.id, saved); return saved; }
    const laterPart = hasPrequel(media);
    const [fromAniList, lookup] = await Promise.all([
      this.streamingEpisodes(media.id, laterPart, media.episodes, client),
      KitsuClient.kitsuIdLookup({ id: media.id, mal: media.idMal }),
    ]);
    const old = mem ?? saved;
    let kid = lookup.id ?? old?.kitsuId;
    let kitsu = kid ? await KitsuClient.episodes(kid, 0) : undefined;
    const kitsuFailed = (kid !== undefined && !kitsu) || (kid === undefined && lookup.failed);
    if (kitsuFailed && old) { this.memory.set(media.id, old); return old; }

    let anilistEpisodes = fromAniList;
    let sources: EpisodePage["sources"];
    if (kitsu?.episodes.length) {
      switch (alignment(fromAniList, kitsu.episodes, laterPart, media.episodes, kitsu.total)) {
        case "same": break;
        case "kitsuOnly": anilistEpisodes = []; sources = "kitsu"; break;
        case "anilistOnly": kitsu = undefined; kid = undefined; sources = "anilist"; break;
      }
    }
    const total = episodeCount(media, anilistEpisodes.length, kitsu?.total);
    let merged = mergeEpisodes(total, anilistEpisodes, kitsu?.episodes ?? []);
    if (old && old.sources === sources) {
      const prev = new Map(old.episodes.map((e) => [e.number, e]));
      merged = merged.map((e) => {
        const p = prev.get(e.number);
        return p ? { ...e, title: e.title ?? p.title, description: e.description ?? p.description, thumbnail: e.thumbnail ?? p.thumbnail } : e;
      });
    }
    const page: EpisodePage = {
      episodes: merged, total, kitsuId: kitsuFailed ? undefined : kid,
      kitsuLoaded: kitsu?.episodes.length ?? 0, kitsuTotal: kitsu?.total,
      savedAt: kitsuFailed ? 0 : Date.now(), finished: media.status === "FINISHED", sources,
    };
    this.memory.set(media.id, page);
    void DiskCache.save(this.cacheName(media.id), page);
    return page;
  }

  async loadMore(mediaId: number): Promise<EpisodePage | undefined> {
    const page = this.memory.get(mediaId);
    if (!page || !page.kitsuId || page.kitsuLoaded >= (page.kitsuTotal ?? 0)) return page;
    const more = await KitsuClient.episodes(page.kitsuId, page.kitsuLoaded);
    if (!more) return page;
    const next: EpisodePage = { ...page, kitsuLoaded: page.kitsuLoaded + Math.max(more.episodes.length, 1) };
    const byNumber = new Map(page.episodes.map((e) => [e.number, e]));
    for (const k of more.episodes) {
      if (k.number < 1 || k.number > page.total) continue;
      const e = { ...(byNumber.get(k.number) ?? { number: k.number }) };
      e.title ??= realTitle(k.title);
      e.description ??= k.description;
      e.thumbnail ??= k.thumbnail;
      byNumber.set(k.number, e);
    }
    next.episodes = [...byNumber.values()].sort((a, b) => a.number - b.number);
    this.memory.set(mediaId, next);
    void DiskCache.save(this.cacheName(mediaId), next);
    return next;
  }

  private async streamingEpisodes(id: number, laterPart: boolean, expected: number | null | undefined, client: AniListClient): Promise<EpisodeInfo[]> {
    type R = { Media?: { streamingEpisodes?: { title?: string; thumbnail?: string }[] | null } | null };
    let data: R;
    try {
      data = await client.run<R>(Queries.streamingEpisodes, { id });
    } catch {
      return [];
    }
    const raw = (data.Media?.streamingEpisodes ?? []).filter((e) => !isPromo(e.title));
    let result: EpisodeInfo[] = [];
    [...raw].reverse().forEach((ep, index) => {
      const [number, title, special] = parseEpisodeTitle(ep.title, index + 1);
      if (number < 1 || special) return;
      result.push({ number, title, thumbnail: ep.thumbnail ?? undefined });
    });
    const first = result.length ? Math.min(...result.map((e) => e.number)) : undefined;
    if (first !== undefined && first > 1) {
      if (!laterPart) return [];
      result = result.map((e) => ({ ...e, number: e.number - (first - 1) }));
    } else if (laterPart && expected != null && result.length > expected * 1.5 + 2) {
      return [];
    }
    return result;
  }
}

function episodeCount(m: Media, anilist: number, kitsu?: number): number {
  if (m.status === "NOT_YET_RELEASED") return 0;
  if (m.status === "RELEASING" && m.nextAiringEpisode) return Math.max(0, m.nextAiringEpisode.episode - 1);
  return m.episodes ?? Math.max(anilist, kitsu ?? 0);
}

function mergeEpisodes(count: number, anilist: EpisodeInfo[], kitsu: EpisodeInfo[]): EpisodeInfo[] {
  if (count <= 0) return [];
  const a = new Map<number, EpisodeInfo>(), k = new Map<number, EpisodeInfo>();
  for (const e of anilist) if (!a.has(e.number)) a.set(e.number, e);
  for (const e of kitsu) if (!k.has(e.number)) k.set(e.number, e);
  const out: EpisodeInfo[] = [];
  for (let n = 1; n <= count; n++) {
    out.push({
      number: n,
      title: realTitle(a.get(n)?.title) ?? realTitle(k.get(n)?.title),
      description: k.get(n)?.description,
      thumbnail: a.get(n)?.thumbnail ?? k.get(n)?.thumbnail,
    });
  }
  return out;
}

export const EpisodeService = new EpisodeServiceImpl();
