// "Match %" for any show, everywhere in the app (port of MatchEngine.swift).
// Layer 1 (instant): genres/tags vs your taste profile, memoized per show.
// Layer 2 (AI): if the show's synopsis has been embedded, its similarity to your taste vector is
// blended in. Unseen shows are queued and analyzed in one small batch after scrolling settles.

import { accumulate, cosine, getEmbedder, leaveOneOutCosine, normalized, vectorsFor } from "./ai";
import { ListEntry, Media, scoreValue } from "./models";
import { entryWeight, scoreStats, TasteProfile } from "./recommender";

export class MatchEngine {
  /** Bumped whenever percentages change, so badges redraw. */
  version = 0;
  onChange: () => void = () => {};
  aiEnabled: () => boolean = () => true;

  private entries: ListEntry[] = [];
  private dirty = true;
  private profile = new TasteProfile();
  private weights = new Map<number, number>();
  private ratings = new Map<number, number>();
  private fanSignal = new Map<number, number>();
  private tagScale = { lo: 0, hi: 1 };
  private memo = new Map<number, number>();

  private tasteVector: Float32Array | null = null;
  private tasteRaw: Float32Array = new Float32Array(0);
  private anchorWeights = new Map<number, number>();
  private semScale = { lo: 0, hi: 1 };
  private semantic = new Map<number, number>();
  private pending = new Map<number, Media>();
  private batchTimer: ReturnType<typeof setTimeout> | null = null;
  private tasteJob = 0;

  private bump() {
    this.version++;
    this.onChange();
  }

  update(entries: ListEntry[]) {
    this.entries = entries;
    this.dirty = true;
    this.memo.clear();
    this.bump();
  }

  private rebuildIfNeeded() {
    if (!this.dirty) return;
    this.dirty = false;
    const { mean, spread } = scoreStats(this.entries);
    const profile = new TasteProfile();
    const weights = new Map<number, number>();
    for (const e of this.entries) {
      const w = entryWeight(e, mean, spread);
      weights.set(e.mediaId, w);
      if (w !== 0) profile.add(e.media, w);
    }
    profile.finalize();
    this.profile = profile;
    this.weights = weights;
    this.ratings = new Map();
    for (const e of this.entries) if (scoreValue(e) > 0 && !this.ratings.has(e.mediaId)) this.ratings.set(e.mediaId, Math.min(1, scoreValue(e) / 100));

    // Calibrate: your well-liked shows define "very high match", the spread of your list "low".
    const loo = (e: ListEntry) => profile.similarityExcluding(e.media, weights.get(e.mediaId) ?? 0);
    const liked = this.entries.filter((e) => (weights.get(e.mediaId) ?? 0) > 0.5).map(loo).sort((a, b) => a - b);
    const all = this.entries.filter((e) => e.status !== "PLANNING").map(loo).sort((a, b) => a - b);
    const hi = liked.length ? liked[Math.min(liked.length - 1, Math.floor(liked.length * 0.75))] : 0.6;
    const lo = all.length ? Math.min(all[Math.floor((all.length - 1) * 0.1)], hi * 0.4) : 0;
    this.tagScale = { lo, hi: Math.max(hi, lo + 0.05) };

    this.semantic.clear();
    this.tasteVector = null;
    this.refreshTasteVector();
  }

  /** Match % for any show; nil only while your list is empty. */
  match(media: Media): number | undefined {
    this.rebuildIfNeeded();
    if (!(this.profile.norm > 0)) return undefined;
    const cached = this.memo.get(media.id);
    if (cached !== undefined) return cached;

    const raw = this.profile.similarityExcluding(media, this.weights.get(media.id) ?? 0);
    let z = Math.max(-1, Math.min(1, (raw - this.tagScale.lo) / (this.tagScale.hi - this.tagScale.lo)));
    const sem = this.semantic.get(media.id);
    if (sem !== undefined) z = 0.55 * z + 0.45 * sem;
    else if (this.aiEnabled()) this.queueForAI(media);
    const fans = this.fanSignal.get(media.id);
    if (fans && fans > 0 && z < 1) z += (1 - z) * 0.6 * fans;

    let percent: number;
    const rating = this.ratings.get(media.id);
    if (rating !== undefined) {
      const predicted = Math.max(0, Math.min(1, z));
      percent = Math.round(20 + 79 * (0.95 * rating + 0.05 * predicted));
    } else if (z >= 0) {
      percent = Math.round(50 + 49 * Math.min(z, 1));
    } else {
      percent = Math.round(50 + 30 * z);
    }
    this.memo.set(media.id, percent);
    return percent;
  }

  get fanSnapshot(): Record<number, number> {
    return Object.fromEntries(this.fanSignal);
  }

  resetSignals() {
    this.fanSignal.clear();
    this.memo.clear();
    this.bump();
  }

  addFanSignal(signal: Map<number, number> | Record<number, number>) {
    const entries = signal instanceof Map ? [...signal] : Object.entries(signal).map(([k, v]) => [Number(k), v] as const);
    if (!entries.length) return;
    if (this.fanSignal.size > 5000) this.fanSignal.clear();
    let changed = false;
    for (const [id, value] of entries) {
      if (value > (this.fanSignal.get(id) ?? 0) + 0.01) {
        this.fanSignal.set(id, value);
        this.memo.delete(id);
        changed = true;
      }
    }
    if (changed) this.bump();
  }

  /** AI turned on or became available again: badges computed without it pick it up. */
  aiAvailabilityChanged() {
    if (!this.aiEnabled()) return;
    this.rebuildIfNeeded();
    let changed = false;
    for (const id of [...this.memo.keys()]) {
      if (!this.semantic.has(id)) {
        this.memo.delete(id);
        changed = true;
      }
    }
    if (!this.tasteVector) this.refreshTasteVector();
    if (changed) this.bump();
  }

  private refreshTasteVector() {
    const job = ++this.tasteJob;
    if (!this.aiEnabled()) return;
    const w = this.weights;
    const anchors = this.entries
      .filter((e) => Math.abs(w.get(e.mediaId) ?? 0) >= 0.4)
      .sort((a, b) => Math.abs(w.get(b.mediaId) ?? 0) - Math.abs(w.get(a.mediaId) ?? 0))
      .slice(0, 40)
      .map((e) => e.media);
    if (!anchors.length) return;
    const reference = this.entries.filter((e) => e.status !== "PLANNING").slice(0, 150).map((e) => e.media.id);
    void (async () => {
      let vectors: Map<number, Float32Array>;
      try {
        vectors = await vectorsFor(anchors);
      } catch {
        return;
      }
      if (job !== this.tasteJob) return;
      let taste: Float32Array | null = null;
      const anchorW = new Map<number, number>();
      for (const m of anchors) {
        const v = vectors.get(m.id);
        if (!v) continue;
        if (!taste) taste = new Float32Array(v.length);
        accumulate(v, w.get(m.id) ?? 0, taste);
        anchorW.set(m.id, w.get(m.id) ?? 0);
      }
      if (!taste) return;
      const raw = taste;
      const refVectors = await getEmbedder().cached(reference);
      if (job !== this.tasteJob) return;
      const sims: number[] = [];
      for (const [id, v] of refVectors) if (v.length === raw.length) sims.push(leaveOneOutCosine(raw, v, anchorW.get(id) ?? 0));
      sims.sort((a, b) => a - b);
      this.tasteRaw = raw;
      this.anchorWeights = anchorW;
      this.semScale = sims.length >= 3
        ? { lo: sims[Math.floor((sims.length - 1) * 0.1)], hi: sims[Math.floor((sims.length - 1) * 0.9)] }
        : { lo: 0.5, hi: 0.95 };
      this.tasteVector = normalized(raw);
      await this.applyCached([...this.memo.keys()]);
    })();
  }

  private async applyCached(ids: number[]) {
    if (!this.tasteVector || !ids.length) return;
    const vectors = await getEmbedder().cached(ids);
    this.apply(vectors);
    if (this.pending.size) this.scheduleBatch();
  }

  private apply(vectors: Map<number, Float32Array>) {
    const taste = this.tasteVector;
    if (!taste || !vectors.size) return;
    const span = Math.max(this.semScale.hi - this.semScale.lo, 0.0001);
    let changed = false;
    for (const [id, v] of vectors) {
      if (v.length !== taste.length) continue;
      const aw = this.anchorWeights.get(id);
      const c = aw !== undefined ? leaveOneOutCosine(this.tasteRaw, v, aw) : cosine(taste, v);
      this.semantic.set(id, Math.max(-1, Math.min(1, (c - this.semScale.lo) / span)));
      this.memo.delete(id);
      this.pending.delete(id);
      changed = true;
    }
    if (changed) this.bump();
  }

  private queueForAI(media: Media) {
    if (this.pending.has(media.id)) return;
    this.pending.set(media.id, media);
    this.scheduleBatch();
  }

  /** Restarts on every new cover: work starts only once scrolling has settled. */
  private scheduleBatch() {
    if (this.batchTimer) clearTimeout(this.batchTimer);
    this.batchTimer = setTimeout(() => void this.runBatch(), 2500);
  }

  private async runBatch() {
    if (!this.aiEnabled() || !this.tasteVector) return;
    const batch = [...this.pending.values()].slice(0, 30);
    if (!batch.length) return;
    for (const m of batch) this.pending.delete(m.id);
    try {
      this.apply(await vectorsFor(batch));
    } catch {
      /* try again with the next batch */
    }
    if (this.pending.size) this.scheduleBatch();
  }
}
