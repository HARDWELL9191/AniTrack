// Season 2+ shown as its first season everywhere except the details page's season dropdown
// (port of SeasonCache / SeasonRoots in Recommender.swift and SeasonChain in Kitsu.swift).

import { AniListClient, Queries } from "./anilist";
import { DiskCache } from "./cache";
import { isLaterSeason, isSeason, Media, prequelId, Seasons } from "./models";

type PageData = { Page: { media: Media[]; pageInfo?: { hasNextPage?: boolean } } };

interface SavedRoot { root: Media; later: Media; chain: number[]; savedAt: number }

const ROOTS_FILE = "season-roots-v2";
const MAX_AGE = 7 * 86_400_000;

/** Seasons fetched while collapsing, plus later season → first season answers saved for a week. */
class SeasonCacheImpl {
  private media = new Map<number, Media>();
  private roots: Record<number, SavedRoot> = {};
  private loaded: Promise<void> | null = null;
  private saveTimer: ReturnType<typeof setTimeout> | null = null;

  private load() {
    if (!this.loaded) {
      this.loaded = DiskCache.load<Record<number, SavedRoot>>(ROOTS_FILE).then((saved) => {
        if (saved) this.roots = { ...saved, ...this.roots };
      });
    }
    return this.loaded;
  }

  async root(laterId: number): Promise<{ root: Media; chain: number[] } | undefined> {
    await this.load();
    const s = this.roots[laterId];
    if (!s || Date.now() - s.savedAt >= MAX_AGE) return undefined;
    return { root: s.root, chain: s.chain };
  }

  /** Later seasons known to belong to this first season (for its season dropdown). */
  async laterSeasons(rootId: number): Promise<Media[]> {
    await this.load();
    const now = Date.now();
    return Object.values(this.roots).filter((s) => s.root.id === rootId && now - s.savedAt < MAX_AGE).map((s) => s.later);
  }

  async storeRoots(found: { later: Media; root: Media; chain: number[] }[]) {
    if (!found.length) return;
    await this.load();
    if (Object.keys(this.roots).length > 3000) this.roots = {};
    const now = Date.now();
    for (const f of found) this.roots[f.later.id] = { root: f.root, later: f.later, chain: f.chain, savedAt: now };
    if (this.saveTimer) clearTimeout(this.saveTimer);
    this.saveTimer = setTimeout(() => void DiskCache.save(ROOTS_FILE, this.roots), 2000);
  }

  merged(candidates: Map<number, Media>): Map<number, Media> {
    const out = new Map(this.media);
    for (const [k, v] of candidates) out.set(k, v);
    return out;
  }

  store(items: Media[]) {
    if (this.media.size > 1500) this.media.clear();
    for (const m of items) this.media.set(m.id, m);
  }
}

export const SeasonCache = new SeasonCacheImpl();

export interface Found { root?: Media; chain: number[]; complete: boolean }

export const SeasonRoots = {
  /** First seasons for these later seasons: saved answers first, the rest by walking prequels. */
  async resolve(later: Media[], start: Map<number, Media>, client: AniListClient, waitOnRateLimit: boolean): Promise<Map<number, Found>> {
    const result = new Map<number, Found>();
    const toWalk: Media[] = [];
    for (const m of later) {
      const saved = await SeasonCache.root(m.id);
      if (saved) result.set(m.id, { root: saved.root, chain: saved.chain, complete: true });
      else toWalk.push(m);
    }
    if (!toWalk.length) return result;
    const known = SeasonCache.merged(start);

    const walk = (m: Media) => {
      const visited = new Set([m.id]);
      const chain: number[] = [];
      let current = m;
      let root: Media | undefined;
      for (;;) {
        const previous = prequelId(current);
        if (previous === undefined || visited.size >= 15 || visited.has(previous)) break;
        visited.add(previous);
        const earlier = known.get(previous);
        if (!earlier) return { root, chain, next: previous };
        chain.push(earlier.id);
        if (isSeason(earlier)) root = earlier; // a one-off prologue never stands in
        current = earlier;
      }
      return { root, chain, next: undefined as number | undefined };
    };

    // Up to 10 hops: long franchises (JoJo Part 7 → Part 1) need that many.
    for (let hop = 0; hop < 10; hop++) {
      const missing = [...new Set(toWalk.map((m) => walk(m).next).filter((x): x is number => x !== undefined))];
      if (!missing.length) break;
      const fetched: Media[] = [];
      for (let i = 0; i < missing.length; i += 50) {
        const chunk = missing.slice(i, i + 50);
        try {
          const data = await client.run<PageData>(Queries.mediaByIds, { ids: chunk, perPage: chunk.length }, { waitOnRateLimit });
          for (const m of data.Page.media) {
            known.set(m.id, m);
            fetched.push(m);
          }
        } catch {
          /* offline or rate limited: use what we have */
        }
      }
      if (!fetched.length) break;
      SeasonCache.store(fetched);
    }

    // Only complete answers are saved, so an offline half-answer is redone next time.
    const complete: { later: Media; root: Media; chain: number[] }[] = [];
    for (const m of toWalk) {
      const w = walk(m);
      result.set(m.id, { root: w.root, chain: w.chain, complete: w.next === undefined });
      if (w.root && w.next === undefined) complete.push({ later: m, root: w.root, chain: w.chain });
    }
    await SeasonCache.storeRoots(complete);
    return result;
  },

  /** Same order, each later season replaced by its first season, no duplicates. */
  async collapse(items: Media[], client: AniListClient): Promise<Media[]> {
    const later = items.filter(isLaterSeason);
    if (!later.length) return items;
    const found = await SeasonRoots.resolve(later, new Map(items.map((m) => [m.id, m])), client, false);
    return SeasonRoots.apply(items, found);
  },

  apply(items: Media[], found: Map<number, Found>): Media[] {
    const seen = new Set<number>();
    const out: Media[] = [];
    for (const m of items) {
      const shown = found.get(m.id)?.root ?? m;
      if (!seen.has(shown.id)) {
        seen.add(shown.id);
        out.push(shown);
      }
    }
    return out;
  },
};

/** The TV/ONA seasons of a show, in order, from AniList's prequel/sequel links. */
class SeasonChainImpl {
  private cache = new Map<number, Media[]>();

  private static link(m: Media, type: string): number | undefined {
    const edges = (m.relations?.edges ?? []).filter((e) => e.relationType === type && (e.node?.type == null || e.node?.type === "ANIME"));
    return (edges.find((e) => Seasons.isSeries(e.node?.format)) ?? edges[0])?.node?.id;
  }

  private static airedBefore(a: Media, b: Media): number {
    const order: Record<string, number> = { WINTER: 0, SPRING: 1, SUMMER: 2, FALL: 3 };
    const ka = [a.seasonYear ?? Number.MAX_SAFE_INTEGER, order[a.season ?? ""] ?? 4, a.id];
    const kb = [b.seasonYear ?? Number.MAX_SAFE_INTEGER, order[b.season ?? ""] ?? 4, b.id];
    for (let i = 0; i < 3; i++) if (ka[i] !== kb[i]) return ka[i] - kb[i];
    return 0;
  }

  async seasons(media: Media, client: AniListClient): Promise<Media[]> {
    const cached = this.cache.get(media.id);
    if (cached) return cached;
    const known = new Map<number, Media>([[media.id, media]]);
    const visited = new Set([media.id]);
    const before: Media[] = [];
    const after: Media[] = [];
    let back = SeasonChainImpl.link(media, "PREQUEL");
    let forward = SeasonChainImpl.link(media, "SEQUEL");
    let failed = false;

    for (let i = 0; i < 12; i++) {
      const wanted = [back, forward].filter((x): x is number => x !== undefined && !known.has(x));
      if (wanted.length) {
        try {
          const data = await client.run<PageData>(Queries.mediaByIds, { ids: wanted, perPage: wanted.length });
          for (const m of data.Page.media) known.set(m.id, m);
        } catch {
          failed = true;
          break;
        }
      }
      let moved = false;
      if (back !== undefined && !visited.has(back) && known.has(back)) {
        const m = known.get(back)!;
        visited.add(back);
        if (isSeason(m)) before.unshift(m);
        back = SeasonChainImpl.link(m, "PREQUEL");
        moved = true;
      } else back = undefined;
      if (forward !== undefined && !visited.has(forward) && known.has(forward)) {
        const m = known.get(forward)!;
        visited.add(forward);
        if (isSeason(m)) after.push(m);
        forward = SeasonChainImpl.link(m, "SEQUEL");
        moved = true;
      } else forward = undefined;
      if (!moved) break;
    }
    let result = [...before, media, ...after];
    // Every season shown as this show anywhere is in its dropdown, even when the franchise
    // splits into two sequels (Dragon Ball → Z → GT, and Super).
    const extras = await this.foldedSeasons(result);
    const present = new Set(result.map((m) => m.id));
    const seenAdded = new Set<number>();
    let added = extras.filter((m) => !present.has(m.id) && isSeason(m) && !seenAdded.has(m.id) && (seenAdded.add(m.id), true));
    if (added.length) {
      try {
        const data = await client.run<PageData>(Queries.mediaByIds, { ids: added.map((m) => m.id), perPage: Math.min(added.length, 50) });
        const fresh = new Map(data.Page.media.map((m) => [m.id, m]));
        added = added.map((m) => fresh.get(m.id) ?? m);
      } catch {
        /* saved copies */
      }
      const seen = new Set<number>();
      result = [...result, ...added].filter((m) => !seen.has(m.id) && (seen.add(m.id), true)).sort(SeasonChainImpl.airedBefore);
    }
    if (!failed) for (const m of result) this.cache.set(m.id, result);
    return result;
  }

  private async foldedSeasons(chain: Media[]): Promise<Media[]> {
    const rootIds = chain.length ? [chain[0].id] : [];
    const extras: Media[] = [];
    for (const m of chain) {
      const saved = await SeasonCache.root(m.id);
      if (saved && !rootIds.includes(saved.root.id)) {
        rootIds.push(saved.root.id);
        extras.push(saved.root);
      }
    }
    for (const id of rootIds) extras.push(...(await SeasonCache.laterSeasons(id)));
    return extras;
  }
}

export const SeasonChain = new SeasonChainImpl();
