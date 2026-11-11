// For You on the Anime / Anime Movies libraries runs on your AniList account, the same way as the
// iPhone app (JellyReco/AniList/AniListService.swift) and AniReco:
//   picks          learned from your AniList list (see anilist.ts), never anything on your server
//   Add to My List your AniList Planning list (every season of the show)
//   Not for me     a private, hidden "Not for me" custom list on AniList (the one AniReco uses)
//   Already seen   Completed on AniList, then "How did you like it?"
// The AniList login belongs to the Jellyfin account it was made in and is kept with this PC's
// sign-ins (Windows: DPAPI, Linux: the desktop keyring).

import {
  type AgeRating, type AniListLibrary, AniListClient, AniListOwnedIndex, type AnimeCategory, type EntryLite, FEATURED, type ListEntry, type ListStatus,
  type Media, type Recommendation, type RecommendationResult, type TitleLanguage, type Viewer, allTitles, anilistTitle, availableEpisodes, categoryId,
  fingerprint, isAuthError, isLaterSeason, isMovieMedia, isSeasonMedia, kitsuRatings, languageFromOption, ListFranchises, recommend, SeasonRoots, Seasons, seasonChain,
} from "./anilist";
import { Queries } from "./anilistQueries";
import type { ExternalPick } from "./discovery";
import { embed } from "./reco";
import type { ExternalTitle } from "./titles";
import { isAnime, titleKey } from "./titles";
import type { Item } from "./types";

/** What the service needs from the app. */
export interface AniListHost {
  notify(): void;
  toast(text: string, tone?: "info" | "error" | "success"): void;
  /** "<server id>|<user id>" of the signed-in Jellyfin account, or null. */
  accountKey(): string | null;
  token(accountKey: string): string | null;
  saveToken(accountKey: string, token: string | null): Promise<void>;
  settings(): { hideChinese: boolean; includeUnreleased: boolean; titleLanguage: string; useAI: boolean };
  /** Everything on the server (movies and shows), and the library read to make sure it's there. */
  owned(): Item[];
  ensureLibrary(): Promise<void>;
  /** Your AniList list was read (the one-time move of old anime entries can run). */
  listRefreshed(): void;
}

const WRITE_SPACING = 2100; // AniList is strict about request rates: writes go ~2 s apart
const NOT_FOR_ME = "Not for me";
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const load = <T,>(key: string): T | null => { try { const raw = localStorage.getItem(key); return raw ? (JSON.parse(raw) as T) : null; } catch { return null; } };
const save = (key: string, value: unknown) => { try { localStorage.setItem(key, JSON.stringify(value)); } catch { /* full */ } };

export const feedKey = (library: AniListLibrary, category: AnimeCategory | null) => `${library}|${category ? categoryId(category) : "any"}`;

export class AniListService {
  readonly client = new AniListClient();
  viewer: Viewer | null = null;
  entries: ListEntry[] = [];
  listLoadedOnce = false;
  loadingList = false;
  listError: string | null = null;
  loggingIn = false;
  feeds = new Map<string, RecommendationResult>();
  building = new Set<string>();
  loadingMore = new Set<string>();
  errors = new Map<string, string>();
  categories: AnimeCategory[] = [];
  /** Shows marked Not for me (AniList ids), and their details for the Not for me page. */
  dismissed = new Set<number>();
  notForMeMedia = new Map<number, Media>();
  /** Kitsu age ratings by AniList id. */
  ages = new Map<number, AgeRating>();
  /** "How did you like it?" after Already seen. */
  ratePrompt: Media | null = null;

  private host: AniListHost;
  private account: string | null = null;
  private byMedia = new Map<number, ListEntry>();
  private franchises = new ListFranchises();
  private notForMeEntries = new Map<number, number>(); // mediaId → AniList entry id
  private pendingNotForMe = new Set<number>();
  private notForMeLoadedFor: number | null = null;
  private notForMeListReady = false;
  private notForMeSyncing = false;
  private loadTask: Promise<void> | null = null;
  private generating = new Map<string, Promise<void>>();
  private moreTasks = new Map<string, Promise<void>>();
  private forceRebuild = new Set<string>();
  private showSync: Promise<void> = Promise.resolve();
  private titleCache = new Map<string, ExternalTitle>();
  private ownedCache: { from: Item[]; index: AniListOwnedIndex<Item> } | null = null;
  private ageRequested = new Set<number>();
  private agePending = new Map<number, number | null>();
  private ageTimer: ReturnType<typeof setTimeout> | null = null;

  constructor(host: AniListHost) { this.host = host; }

  private changed() { this.host.notify(); }
  get loggedIn() { return !!this.client.token; }

  private setEntries(list: ListEntry[]) {
    this.entries = list;
    this.byMedia = new Map();
    for (const e of list) if (!this.byMedia.has(e.mediaId)) this.byMedia.set(e.mediaId, e);
    this.franchises = new ListFranchises(list.map((e) => e.media));
  }

  get language(): TitleLanguage {
    const chosen = this.host.settings().titleLanguage;
    return chosen === "english" || chosen === "romaji" || chosen === "native" ? chosen : languageFromOption(this.viewer?.options?.titleLanguage);
  }

  private cacheKey(kind: string) { return `anilist-${kind}-${this.viewer?.id ?? 0}`; }

  // MARK: Account

  /** The Jellyfin account in use: its own AniList login. */
  syncAccount() {
    const key = this.host.accountKey();
    if (key === this.account) return;
    this.clear();
    this.account = key;
    const token = key ? this.host.token(key) : null;
    if (token) { this.client.token = token; this.loadAccount(); }
    this.changed();
  }

  loadAccount() {
    if (!this.loggedIn || this.loadTask) return this.loadTask ?? Promise.resolve();
    const task = this.reloadAll().finally(() => { if (this.loadTask === task) this.loadTask = null; });
    this.loadTask = task;
    return task;
  }

  async reloadAll() {
    if (!this.viewer && this.account) {
      const cached = load<Viewer>(`anilist-viewer-${this.account}`);
      if (cached) { this.viewer = cached; this.loadNotForMe(); }
    }
    if (!this.entries.length && this.viewer) { const cached = load<ListEntry[]>(this.cacheKey("list")); if (cached?.length) this.setEntries(cached); }
    this.changed();
    await this.loadViewer();
    await this.refreshList();
  }

  async logIn(token: string) {
    const trimmed = token.trim();
    this.syncAccount();
    if (!trimmed || !this.account) return;
    const account = this.account;
    await this.host.saveToken(account, trimmed);
    this.clear();
    this.account = account;
    this.client.token = trimmed;
    this.loggingIn = true;
    this.changed();
    try { await this.reloadAll(); } finally { this.loggingIn = false; this.changed(); }
    if (this.viewer) this.host.toast(`Logged in to AniList as ${this.viewer.name}`, "success");
  }

  async logOut() {
    if (this.account) await this.host.saveToken(this.account, null);
    const account = this.account;
    this.clear();
    this.account = account;
    this.changed();
  }

  private clear() {
    this.client.token = null;
    this.viewer = null;
    this.setEntries([]);
    this.listLoadedOnce = false; this.loadingList = false; this.listError = null;
    this.feeds.clear(); this.building.clear(); this.loadingMore.clear(); this.errors.clear(); this.forceRebuild.clear();
    this.generating.clear(); this.moreTasks.clear();
    this.dismissed = new Set(); this.notForMeMedia = new Map(); this.notForMeEntries = new Map(); this.pendingNotForMe = new Set();
    this.notForMeLoadedFor = null; this.notForMeListReady = false;
    this.titleCache.clear();
    this.ratePrompt = null;
    this.loadTask = null;
  }

  private async loadViewer() {
    if (!this.loggedIn) return;
    try {
      const data = await this.client.run<{ Viewer: Viewer }>(Queries.viewer, {}, !this.viewer);
      if (!this.loggedIn) return;
      if (this.viewer?.id !== data.Viewer.id) this.notForMeLoadedFor = null;
      this.viewer = data.Viewer;
      if (this.account) save(`anilist-viewer-${this.account}`, data.Viewer);
      this.loadNotForMe();
    } catch (e) {
      if (isAuthError(e)) { this.host.toast("Your AniList login expired. Log in again in Settings → For You.", "error"); await this.logOut(); }
      else if (!this.viewer) this.listError = `Couldn't reach AniList: ${(e as Error).message}`;
    }
    this.changed();
  }

  async refreshList() {
    const userId = this.viewer?.id;
    if (!this.loggedIn || !userId) { this.listLoadedOnce = true; this.changed(); return; }
    this.loadingList = true;
    this.changed();
    try {
      type Group = { name?: string | null; isCustomList?: boolean | null; entries?: ListEntry[] | null };
      const data = await this.client.run<{ MediaListCollection: { lists?: Group[] | null } | null }>(Queries.listCollection, { userId });
      if (this.viewer?.id !== userId) return;
      const groups = data.MediaListCollection?.lists ?? [];
      const notForMe = new Map<number, number>();
      for (const g of groups) if (g.isCustomList && g.name === NOT_FOR_ME) for (const e of g.entries ?? []) { notForMe.set(e.mediaId, e.id); this.notForMeMedia.set(e.mediaId, e.media); }
      const seen = new Set<number>();
      const result: ListEntry[] = [];
      for (const g of groups) if (!g.isCustomList) for (const e of g.entries ?? []) if (!seen.has(e.id)) { seen.add(e.id); result.push(e); }
      // A Not for me entry never appears in your lists or shapes your taste.
      this.setEntries(result.filter((e) => notForMe.get(e.mediaId) !== e.id));
      this.listError = null;
      save(this.cacheKey("list"), this.entries);
      this.mergeNotForMe(notForMe);
      this.removeKnownFromFeeds();
      setTimeout(() => this.host.listRefreshed(), 0);
    } catch (e) {
      if (isAuthError(e)) { this.host.toast("Your AniList login expired. Log in again in Settings → For You.", "error"); await this.logOut(); }
      else this.listError = `Couldn't read your AniList list: ${(e as Error).message}`;
    } finally {
      this.loadingList = false;
      this.listLoadedOnce = true;
      this.changed();
    }
  }

  // MARK: Your list

  entry(mediaId: number) { return this.byMedia.get(mediaId); }
  isPlanned(mediaId: number) { return this.entry(mediaId)?.status === "PLANNING"; }
  /** Your AniList Planning list, newest first (My List shows it). */
  get planning(): ListEntry[] {
    return this.entries.filter((e) => e.status === "PLANNING").sort((a, b) => (b.createdAt ?? b.updatedAt ?? 0) - (a.createdAt ?? a.updatedAt ?? 0));
  }
  /** Your strongest likes on AniList (for "Why would I like this?"). */
  topLiked(limit = 8): string[] {
    return this.entries.filter((e) => ["COMPLETED", "REPEATING", "CURRENT"].includes(e.status))
      .sort((a, b) => (b.score ?? 0) - (a.score ?? 0) || (b.updatedAt ?? 0) - (a.updatedAt ?? 0)).slice(0, limit).map((e) => this.titleOf(e.media));
  }
  titleOf(m: Media) { return anilistTitle(m, this.language).title; }

  /** An AniList show shaped like a For You title (cached per language). */
  title(m: Media): ExternalTitle {
    const key = `${this.language}:${m.id}`;
    let t = this.titleCache.get(key);
    if (!t) { if (this.titleCache.size > 3000) this.titleCache.clear(); t = anilistTitle(m, this.language); this.titleCache.set(key, t); }
    return t;
  }

  // MARK: Your server

  ownedIndex(): AniListOwnedIndex<Item> {
    const items = this.host.owned();
    if (this.ownedCache?.from === items) return this.ownedCache.index;
    const index = new AniListOwnedIndex<Item>(items);
    if (items.length) this.ownedCache = { from: items, index };
    return index;
  }
  /** The server title an AniList pick turned into once it was added to the server. */
  ownedItem(t: ExternalTitle): Item | undefined { return this.ownedIndex().findTitle(t); }

  // MARK: Picks

  private stillWanted(m: Media, library: AniListLibrary, owned: AniListOwnedIndex<Item>) {
    const s = this.host.settings();
    if (this.entry(m.id) || this.franchises.contains(m) || this.dismissed.has(m.id)) return false;
    if (s.hideChinese && m.countryOfOrigin === "CN") return false;
    if (library === "movies" ? !isMovieMedia(m) : isMovieMedia(m) || isLaterSeason(m)) return false;
    if (!s.includeUnreleased && m.status === "NOT_YET_RELEASED") return false;
    return !owned.contains(m);
  }

  picks(library: AniListLibrary, category: AnimeCategory | null): Recommendation[] {
    const owned = this.ownedIndex();
    return (this.feeds.get(feedKey(library, category))?.picks ?? []).filter((p) => this.stillWanted(p.media, library, owned));
  }

  /** The picks shaped like For You's TMDB picks (same cards and sheets). */
  externalPicks(library: AniListLibrary, category: AnimeCategory | null): ExternalPick[] {
    return this.picks(library, category).map((p) => ({ title: this.title(p.media), score: p.score, match: p.match, because: p.because, highlights: p.highlights }));
  }

  private options(library: AniListLibrary, category: AnimeCategory | null) {
    const s = this.host.settings();
    return {
      hideChinese: s.hideChinese, includeUnreleased: s.includeUnreleased, dismissed: this.dismissed, titleLanguage: this.language,
      useAI: s.useAI, category, movies: library === "movies", owned: this.ownedIndex(), embed,
    };
  }

  /** Saved picks are reused unless your list changed or they're over 3 days old (AniReco's rule). */
  generate(library: AniListLibrary, category: AnimeCategory | null, force = false): Promise<void> {
    const key = feedKey(library, category);
    const running = this.generating.get(key);
    if (running && !force) return running;
    const task = (running ?? Promise.resolve()).then(() => this.performGenerate(library, category, force)).finally(() => {
      if (this.generating.get(key) === task) this.generating.delete(key);
    });
    this.generating.set(key, task);
    return task;
  }

  private async performGenerate(library: AniListLibrary, category: AnimeCategory | null, force: boolean) {
    const key = feedKey(library, category);
    if (!this.loggedIn) return;
    if (!this.viewer || !this.listLoadedOnce) await (this.loadTask ?? this.loadAccount());
    if (!this.viewer) { this.errors.set(key, this.listError ?? "Couldn't reach AniList. Refresh to try again."); this.changed(); return; }
    if (!this.entries.length) {
      this.errors.set(key, this.listError ?? "Your AniList list is empty. Add and rate a few shows on AniList first.");
      this.changed();
      return;
    }
    // What's on your server (never picked) comes with the library read.
    await this.host.ensureLibrary().catch(() => {});
    const options = this.options(library, category);
    const print = fingerprint(this.entries, options);
    const mustRebuild = force || this.forceRebuild.has(key);
    this.forceRebuild.delete(key);
    if (!mustRebuild) {
      if (!this.feeds.has(key)) { const saved = load<RecommendationResult>(this.cacheKey(`feed-${key}`)); if (saved?.picks?.length) { this.feeds.set(key, saved); this.changed(); } }
      const current = this.feeds.get(key);
      if (current?.picks.length) {
        const age = Date.now() - current.generatedAt;
        if ((current.fingerprint === print && age < 3 * 86_400_000) || age < 86_400_000) return;
      }
    }
    this.building.add(key);
    this.errors.delete(key);
    this.changed();
    const account = this.viewer.id;
    let found: Recommendation[] = [];
    try {
      const { picks, usedAI } = await recommend(this.entries, this.client, options);
      if (this.viewer?.id !== account) return;
      const owned = this.ownedIndex();
      found = picks.filter((p) => this.stillWanted(p.media, library, owned));
      const result: RecommendationResult = { picks: found, generatedAt: Date.now(), fingerprint: print, usedAI, round: 1, exhausted: false };
      this.feeds.set(key, result);
      save(this.cacheKey(`feed-${key}`), result);
    } catch (e) {
      this.errors.set(key, (e as Error).message);
      return;
    } finally {
      this.building.delete(key);
      this.changed();
    }
    // A thin first round (small list, narrow category, much already on your server): top up.
    if (found.length < 10) await this.loadMore(library, category);
  }

  /** The next round, when you reach the end (AniReco's endless feed). */
  loadMore(library: AniListLibrary, category: AnimeCategory | null): Promise<void> {
    const key = feedKey(library, category);
    const running = this.moreTasks.get(key);
    if (running) return running;
    const task = this.performLoadMore(library, category).finally(() => this.moreTasks.delete(key));
    this.moreTasks.set(key, task);
    return task;
  }

  private async performLoadMore(library: AniListLibrary, category: AnimeCategory | null) {
    const key = feedKey(library, category);
    const start = this.feeds.get(key);
    if (!start || start.exhausted || this.building.has(key)) return;
    this.loadingMore.add(key);
    this.changed();
    const options = this.options(library, category);
    const account = this.viewer?.id;
    const shown = new Set(start.picks.map((p) => p.media.id));
    let round = start.round, empty = 0, failed = false;
    let added: Recommendation[] = [], usedAI = false;
    try {
      while (empty < 3) {
        round++;
        try {
          const r = await recommend(this.entries, this.client, options, round, shown);
          if (this.viewer?.id !== account) return;
          const fresh = r.picks.filter((p) => !shown.has(p.media.id));
          if (!fresh.length) { empty++; continue; }
          added = fresh; usedAI = r.usedAI;
          for (const p of fresh) shown.add(p.media.id);
          break;
        } catch (e) {
          this.errors.set(key, (e as Error).message);
          failed = true;
          break;
        }
      }
      const latest = this.feeds.get(key);
      if (!latest || latest.generatedAt !== start.generatedAt) return;
      const present = new Set(latest.picks.map((p) => p.media.id));
      const owned = this.ownedIndex();
      const next: RecommendationResult = {
        ...latest,
        picks: [...latest.picks, ...added.filter((p) => !present.has(p.media.id) && this.stillWanted(p.media, library, owned))],
        round: Math.max(latest.round, round),
        usedAI: latest.usedAI || usedAI,
        exhausted: !failed && empty >= 3,
      };
      this.feeds.set(key, next);
      save(this.cacheKey(`feed-${key}`), next);
    } finally {
      this.loadingMore.delete(key);
      this.changed();
    }
  }

  private removeFromFeeds(mediaId: number) {
    for (const [key, feed] of this.feeds) {
      if (!feed.picks.some((p) => p.media.id === mediaId)) continue;
      const next = { ...feed, picks: feed.picks.filter((p) => p.media.id !== mediaId) };
      this.feeds.set(key, next);
      save(this.cacheKey(`feed-${key}`), next);
    }
  }

  private removeKnownFromFeeds() {
    for (const [key, feed] of this.feeds) {
      const keep = feed.picks.filter((p) => !this.entry(p.media.id) && !this.franchises.contains(p.media) && !this.dismissed.has(p.media.id));
      if (keep.length === feed.picks.length) continue;
      const next = { ...feed, picks: keep };
      this.feeds.set(key, next);
      save(this.cacheKey(`feed-${key}`), next);
    }
  }

  /** Pick settings changed: every feed is rebuilt on its next visit. */
  invalidatePicks() {
    for (const key of this.feeds.keys()) this.forceRebuild.add(key);
    this.forceRebuild.add(feedKey("shows", null)); this.forceRebuild.add(feedKey("movies", null));
    this.feeds.clear();
    this.changed();
  }

  /** AniList's genres and tags (featured first), loaded once a week. */
  async loadCategories() {
    if (this.categories.length) return;
    const saved = load<{ categories: AnimeCategory[]; savedAt: number }>("anilist-categories");
    if (saved?.categories?.length && Date.now() - saved.savedAt < 7 * 86_400_000) { this.categories = saved.categories; this.changed(); return; }
    try {
      const data = await this.client.run<{ GenreCollection?: string[] | null; MediaTagCollection?: { name: string; isAdult?: boolean | null; isGeneralSpoiler?: boolean | null }[] | null }>(Queries.categories, {}, false);
      const all: AnimeCategory[] = [
        ...(data.GenreCollection ?? []).map((name) => ({ name, kind: "genre" as const })),
        ...(data.MediaTagCollection ?? []).filter((x) => !x.isAdult && !x.isGeneralSpoiler).map((x) => ({ name: x.name, kind: "tag" as const })),
      ];
      const known = new Set(all.map(categoryId));
      const featured = FEATURED.filter((c) => known.has(categoryId(c)));
      const featuredIds = new Set(featured.map(categoryId));
      const rest = all.filter((c) => !featuredIds.has(categoryId(c))).sort((a, b) => a.name.localeCompare(b.name));
      this.categories = [...featured, ...rest];
      save("anilist-categories", { categories: this.categories, savedAt: Date.now() });
    } catch { this.categories = FEATURED; }
    this.changed();
  }

  // MARK: Writing to your AniList

  private async writeEntry(media: Media, status: ListStatus, progress?: number | null, scoreRaw?: number | null): Promise<EntryLite> {
    const vars: Record<string, unknown> = { mediaId: media.id, status };
    if (progress != null) vars.progress = Math.max(0, progress);
    if (scoreRaw != null) vars.scoreRaw = Math.min(100, Math.max(0, scoreRaw));
    this.loadNotForMe();
    const wasNotForMe = this.notForMeEntries.has(media.id);
    // Same AniList entry: turn it back into a normal, visible one.
    if (wasNotForMe) { vars.private = false; vars.hiddenFromStatusLists = false; vars.customLists = []; }
    const saved = (await this.client.run<{ SaveMediaListEntry: EntryLite }>(Queries.saveEntry, vars)).SaveMediaListEntry;
    if (wasNotForMe || this.dismissed.has(media.id)) {
      this.notForMeEntries.delete(media.id); this.pendingNotForMe.delete(media.id); this.dismissed.delete(media.id);
      this.saveNotForMe();
    }
    return saved;
  }

  private apply(saved: EntryLite, media: Media, status: ListStatus, list: ListEntry[]) {
    const now = Math.floor(Date.now() / 1000);
    const i = list.findIndex((e) => e.mediaId === media.id);
    const next: ListEntry = { ...(i >= 0 ? list[i] : { id: saved.id, mediaId: media.id, media, createdAt: now }), status: saved.status ?? status, progress: saved.progress, score: saved.score, updatedAt: saved.updatedAt ?? now } as ListEntry;
    if (i >= 0) list[i] = next; else list.push(next);
  }

  private async saveEntry(media: Media, status: ListStatus, progress?: number | null, scoreRaw?: number | null) {
    const saved = await this.writeEntry(media, status, progress, scoreRaw);
    const list = [...this.entries];
    this.apply(saved, media, status, list);
    this.setEntries(list);
    this.removeKnownFromFeeds();
    this.changed();
    return saved;
  }

  /** "Add to My List": the show (every season) goes on your AniList Planning list. */
  async planToWatch(media: Media): Promise<boolean> {
    try {
      await this.saveEntry(media, "PLANNING");
      this.removeFromFeeds(media.id);
      this.updateOtherSeasons(media, { kind: "planned" });
      return true;
    } catch (e) { this.host.toast(`Couldn't add it to your AniList: ${(e as Error).message}`, "error"); return false; }
  }

  /** "Already seen": Completed on AniList (your score stays), then "How did you like it?". */
  async markCompleted(media: Media, askRating = true): Promise<boolean> {
    const existing = this.entry(media.id);
    try {
      await this.saveEntry(media, "COMPLETED", media.episodes ?? availableEpisodes(media) ?? existing?.progress ?? null);
      if (askRating && !(existing?.score ?? 0)) this.ratePrompt = media;
      this.removeFromFeeds(media.id);
      this.updateOtherSeasons(media, { kind: "watched" });
      this.changed();
      return true;
    } catch (e) { this.host.toast(`Couldn't update your AniList: ${(e as Error).message}`, "error"); return false; }
  }

  /** Off your Planning list (and its other seasons'). */
  async removeFromPlanning(mediaId: number) {
    const entry = this.entry(mediaId);
    if (!entry) return;
    this.setEntries(this.entries.filter((e) => e.id !== entry.id));
    this.changed();
    try {
      await this.client.run(Queries.deleteEntry, { id: entry.id });
      this.updateOtherSeasons(entry.media, { kind: "removed" });
    } catch (e) {
      if (!this.entries.some((x) => x.id === entry.id)) this.setEntries([...this.entries, entry]);
      this.host.toast(`Couldn't update your AniList: ${(e as Error).message}`, "error");
      this.changed();
    }
  }

  /** The score from "How did you like it?" (1–10), for this show and its unscored seasons. */
  async rate(media: Media, value: number): Promise<boolean> {
    try {
      await this.saveEntry(media, this.entry(media.id)?.status ?? "COMPLETED", null, value * 10);
      this.updateOtherSeasons(media, { kind: "scored", score: value * 10 });
      return true;
    } catch (e) { this.host.toast(`Couldn't save the score on AniList: ${(e as Error).message}`, "error"); return false; }
  }

  /** AniList keeps one entry per season; the app treats a show as one (as AniReco does). */
  private updateOtherSeasons(media: Media, change: { kind: "planned" | "watched" | "removed" } | { kind: "scored"; score: number }) {
    if (!this.loggedIn || !isSeasonMedia(media)) return;
    const account = this.viewer?.id;
    this.showSync = this.showSync.then(async () => {
      if (this.viewer?.id !== account) return;
      const seasons = (await seasonChain(media, this.client)).filter((s) => s.id !== media.id && isSeasonMedia(s) && Seasons.sameShow(media.title, s.title));
      let failed = false;
      const written: [EntryLite, Media, ListStatus][] = [];
      const removed = new Set<number>();
      const removedEntries = new Map<number, ListEntry>();
      if (change.kind === "removed") {
        for (const s of seasons) { const e = this.entry(s.id); if (e) removedEntries.set(s.id, e); }
        const ids = new Set([...removedEntries.values()].map((e) => e.id));
        if (ids.size) { this.setEntries(this.entries.filter((e) => !ids.has(e.id))); this.changed(); }
      }
      for (const s of seasons) {
        if (this.viewer?.id !== account) break;
        const current = this.entry(s.id) ?? removedEntries.get(s.id);
        const write = async (status: ListStatus, progress?: number | null, score?: number | null) => { written.push([await this.writeEntry(s, status, progress, score), s, status]); };
        try {
          let wrote = true;
          if (change.kind === "planned") { if (!current) await write("PLANNING"); else wrote = false; }
          else if (change.kind === "watched") {
            if (current?.status === "COMPLETED") wrote = false;
            else if (s.status === "NOT_YET_RELEASED") { if (!current) await write("PLANNING"); else wrote = false; }
            else if (s.status === "RELEASING") await write("CURRENT", Math.max(availableEpisodes(s) ?? current?.progress ?? 0, current?.progress ?? 0));
            else await write("COMPLETED", s.episodes ?? current?.progress ?? null);
          } else if (change.kind === "removed") {
            if (current) { await this.client.run(Queries.deleteEntry, { id: current.id }); removed.add(current.id); } else wrote = false;
          } else if (change.kind === "scored" && current && !(current.score ?? 0) && change.score > 0) await write(current.status, null, change.score);
          else wrote = false;
          if (wrote) await sleep(WRITE_SPACING);
        } catch { failed = true; }
      }
      if ((written.length || removed.size) && this.viewer?.id === account) {
        const list = [...this.entries];
        for (const [saved, s, status] of written) this.apply(saved, s, status, list);
        this.setEntries(list.filter((e) => !removed.has(e.id)));
        this.removeKnownFromFeeds();
        this.changed();
      }
      if (failed && change.kind === "removed" && this.viewer?.id === account) await this.refreshList();
      if (failed) this.host.toast(`Couldn't update every season of ${this.titleOf(media)} on AniList. Try again in a moment.`, "error");
    }).catch(() => {});
  }

  // MARK: Not for me, synced through AniList (the same private list AniReco and the iPhone use)

  private loadNotForMe() {
    const id = this.viewer?.id;
    if (!id || this.notForMeLoadedFor === id) return;
    this.notForMeLoadedFor = id;
    const saved = load<{ entries: [number, number][]; pending: number[] }>(this.cacheKey("notforme-state"));
    this.notForMeEntries = new Map(saved?.entries ?? []);
    this.pendingNotForMe = new Set(saved?.pending ?? []);
    this.dismissed = new Set([...this.notForMeEntries.keys(), ...this.pendingNotForMe]);
    for (const m of load<Media[]>(this.cacheKey("notforme-media")) ?? []) if (!this.notForMeMedia.has(m.id)) this.notForMeMedia.set(m.id, m);
  }

  private saveNotForMe() {
    if (!this.viewer || this.notForMeLoadedFor !== this.viewer.id) return;
    save(this.cacheKey("notforme-state"), { entries: [...this.notForMeEntries], pending: [...this.pendingNotForMe] });
    save(this.cacheKey("notforme-media"), [...this.dismissed].map((id) => this.notForMeMedia.get(id)).filter((m): m is Media => !!m));
  }

  private mergeNotForMe(remote: Map<number, number>) {
    this.loadNotForMe();
    for (const id of remote.keys()) this.pendingNotForMe.delete(id);
    this.pendingNotForMe = new Set([...this.pendingNotForMe].filter((id) => !this.entry(id)));
    this.notForMeEntries = remote;
    this.dismissed = new Set([...remote.keys(), ...this.pendingNotForMe]);
    this.saveNotForMe();
    void this.syncNotForMe();
  }

  /** "Not for me" on a pick: off every feed now, onto AniList's private list in the background. */
  dismiss(media: Media) {
    this.loadNotForMe();
    if (!this.notForMeMedia.has(media.id)) this.notForMeMedia.set(media.id, media);
    this.dismissed.add(media.id);
    if (!this.notForMeEntries.has(media.id)) this.pendingNotForMe.add(media.id);
    this.saveNotForMe();
    this.removeFromFeeds(media.id);
    this.changed();
    void this.syncNotForMe();
  }

  async undoNotForMe(mediaId: number) {
    this.loadNotForMe();
    this.dismissed.delete(mediaId);
    this.pendingNotForMe.delete(mediaId);
    this.saveNotForMe();
    this.changed();
    const entryId = this.notForMeEntries.get(mediaId);
    if (entryId === undefined) return;
    try {
      await this.client.run(Queries.deleteEntry, { id: entryId });
      this.notForMeEntries.delete(mediaId);
      this.saveNotForMe();
    } catch {
      this.dismissed.add(mediaId);
      this.saveNotForMe();
      this.host.toast("Couldn't update AniList. Try again in a moment.", "error");
    }
    this.changed();
  }

  /** The Not for me shows, for the Not for me page. */
  get notForMeTitles(): Media[] { return [...this.dismissed].map((id) => this.notForMeMedia.get(id)).filter((m): m is Media => !!m).sort((a, b) => b.id - a.id); }

  private async syncNotForMe() {
    if (!this.loggedIn || !this.pendingNotForMe.size || this.notForMeSyncing) return;
    this.notForMeSyncing = true;
    try {
      if (!(await this.ensureNotForMeList())) return;
      let first = true;
      for (const mediaId of [...this.pendingNotForMe]) {
        if (!first) await sleep(WRITE_SPACING);
        first = false;
        if (this.entry(mediaId) || !this.dismissed.has(mediaId)) { this.pendingNotForMe.delete(mediaId); continue; }
        try {
          const saved = (await this.client.run<{ SaveMediaListEntry: { id: number; mediaId: number } }>(Queries.saveNotForMe, { mediaId, lists: [NOT_FOR_ME] })).SaveMediaListEntry;
          this.notForMeEntries.set(saved.mediaId, saved.id);
          this.pendingNotForMe.delete(mediaId);
          this.saveNotForMe();
        } catch { break; } // offline or rate limited: the rest goes up on the next refresh
      }
      this.saveNotForMe();
    } finally { this.notForMeSyncing = false; }
  }

  /** Adds "Not for me" to your AniList custom lists, keeping every list you already have. */
  private async ensureNotForMeList() {
    if (this.notForMeListReady) return true;
    type Opts = { mediaListOptions?: { animeList?: { customLists?: string[] | null } | null } | null } | null;
    const data = await this.client.run<{ Viewer: Opts }>(Queries.listOptions).catch(() => null);
    const current = data?.Viewer?.mediaListOptions?.animeList?.customLists;
    if (!current) return false; // couldn't read your lists: never risk overwriting them
    if (current.includes(NOT_FOR_ME)) { this.notForMeListReady = true; return true; }
    const updated = await this.client.run<{ UpdateUser: Opts }>(Queries.updateCustomLists, { lists: [...current, NOT_FOR_ME] }).catch(() => null);
    if (!updated?.UpdateUser?.mediaListOptions?.animeList?.customLists?.includes(NOT_FOR_ME)) return false;
    this.notForMeListReady = true;
    await sleep(WRITE_SPACING);
    return true;
  }

  // MARK: Details

  /** One show by AniList id (from your list, Not for me, the feeds, or AniList). */
  async media(id: number): Promise<Media | null> {
    const known = this.entry(id)?.media ?? this.notForMeMedia.get(id) ?? [...this.feeds.values()].flatMap((f) => f.picks).find((p) => p.media.id === id)?.media;
    if (known) return known;
    const data = await this.client.run<{ Page: { media: Media[] } }>(Queries.mediaByIds, { ids: [id], perPage: 1 }).catch(() => null);
    return data?.Page.media[0] ?? null;
  }

  /** "More like this": AniList's fan recommendations, minus your list, Not for me and your server. */
  async moreLike(mediaId: number): Promise<ExternalTitle[]> {
    type D = { Media: { recommendations?: { nodes?: { mediaRecommendation?: Media | null }[] | null } | null } };
    const d = await this.client.run<D>(Queries.detail, { id: mediaId }).catch(() => null);
    const recs = (d?.Media.recommendations?.nodes ?? []).map((n) => n.mediaRecommendation).filter((m): m is Media => !!m);
    const collapsed = await SeasonRoots.collapse(recs, this.client);
    const owned = this.ownedIndex();
    const hideChinese = this.host.settings().hideChinese;
    return collapsed.filter((m) => m.id !== mediaId && !this.entry(m.id) && !this.franchises.contains(m) && !this.dismissed.has(m.id)
      && m.isAdult !== true && !(hideChinese && m.countryOfOrigin === "CN") && !owned.contains(m)).map((m) => this.title(m));
  }

  /** Kitsu age rating for a cover (asked as covers appear, sent in batches). */
  requestAge(id: number, mal?: number | null) {
    if (this.ages.has(id) || this.ageRequested.has(id)) return;
    this.ageRequested.add(id);
    this.agePending.set(id, mal ?? null);
    if (this.ageTimer) return;
    this.ageTimer = setTimeout(() => void this.flushAges(), 250);
  }

  private async flushAges() {
    while (this.agePending.size) {
      const batch = [...this.agePending].slice(0, 30);
      for (const [id] of batch) this.agePending.delete(id);
      const { found, failed } = await kitsuRatings(batch.map(([id, mal]) => ({ id, mal })));
      for (const [id, r] of found) this.ages.set(id, r);
      if (found.size) this.changed();
      if (failed) { for (const [id] of batch) if (!found.has(id)) this.ageRequested.delete(id); for (const id of this.agePending.keys()) this.ageRequested.delete(id); this.agePending.clear(); }
    }
    this.ageTimer = null;
  }

  /** Best AniList match for a TMDB anime (moving old My List / Not for me entries over).
   *  null: AniList doesn't know it; throws when AniList couldn't be asked. */
  async find(t: ExternalTitle): Promise<Media | null> {
    const data = await this.client.run<{ Page: { media: Media[] } }>(Queries.browse, { page: 1, perPage: 10, search: t.title, sort: ["SEARCH_MATCH"] });
    const key = titleKey(t.title), original = t.originalTitle ? titleKey(t.originalTitle) : null;
    const movie = t.source === "tmdbMovie";
    const yearOK = (m: Media) => !t.year || !m.seasonYear || Math.abs(t.year - m.seasonYear) <= 1;
    const candidates = data.Page.media.filter((m) => isMovieMedia(m) === movie && m.format !== "MUSIC");
    return candidates.find((m) => yearOK(m) && allTitles(m).some((x) => { const k = titleKey(x); return k === key || k === original; })) ?? candidates.find(yearOK) ?? null;
  }

  /** Anime that were on My List / Not for me (saved on the server) before For You moved anime to
   *  AniList: added to AniList Planning / Not for me once, then taken off the server's lists.
   *  A title AniList doesn't know stays where it was. */
  private migrating = false;
  async migrateServerLists(storage: { loaded: boolean; myList: { external?: ExternalTitle | null }[]; notForMe: ExternalTitle[]; toggleTitle(t: ExternalTitle): Promise<void>; markNotForMe(t: ExternalTitle, on?: boolean): Promise<void> } | null): Promise<boolean> {
    if (this.migrating || !storage?.loaded || !this.loggedIn || !this.listLoadedOnce || !this.viewer || !this.account) return false;
    const doneKey = `anilist-moved-lists|${this.account}|${this.viewer.id}`;
    if (load<boolean>(doneKey)) return false;
    const toPlan = storage.myList.map((e) => e.external).filter((t): t is ExternalTitle => !!t && t.source !== "anilist" && isAnime(t));
    const toDismiss = storage.notForMe.filter((t) => t.source !== "anilist" && isAnime(t));
    if (!toPlan.length && !toDismiss.length) { save(doneKey, true); return false; }
    this.migrating = true;
    const viewer = this.viewer.id;
    let incomplete = false;
    let moved = false;
    try {
      for (const [i, t] of toPlan.entries()) {
        if (this.viewer?.id !== viewer) return moved;
        if (i > 0) await sleep(WRITE_SPACING);
        try {
          const m = await this.find(t);
          if (!m) continue;
          const ok = this.entry(m.id) ? true : await this.planToWatch(m);
          if (!ok) { incomplete = true; continue; }
          await storage.toggleTitle(t); // it's on My List: this takes it off the server's copy
          moved = true;
        } catch { incomplete = true; }
      }
      for (const [i, t] of toDismiss.entries()) {
        if (this.viewer?.id !== viewer) return moved;
        if (i > 0 || toPlan.length) await sleep(700);
        try {
          const m = await this.find(t);
          if (!m) continue;
          if (!this.entry(m.id)) this.dismiss(m);
          await storage.markNotForMe(t, false);
          moved = true;
        } catch { incomplete = true; }
      }
      if (!incomplete && this.viewer?.id === viewer) save(doneKey, true);
      return moved;
    } finally {
      this.migrating = false;
      this.changed();
    }
  }
}
