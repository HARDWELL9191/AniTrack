// The app's state and everything it does with AniList (port of AppModel.swift).

import { AniListClient, isAuthError, isCancellation, Queries } from "./anilist";
import { clearPersonal, Defaults, DiskCache } from "./cache";
import { AgeRatings } from "./kitsu";
import { MatchEngine } from "./match";
import {
  type AnimeCategory, availableEpisodes, categoryId, categoryVariables, displayTitle, type EntryLite, FEATURED_CATEGORIES, genre,
  isAdultOnly, isLaterSeason, isMovie, isSeason, type ListEntry, ListFranchises, type ListStatus, type Media, type MediaDetail, type MediaTitle,
  prequelId, progressValue, Seasons, scoreValue, tag, type Viewer,
} from "./models";
import { fingerprint, type RecOptions, type RecommendationResult, runRecommender } from "./recommender";
import { type Found, SeasonChain, SeasonRoots } from "./seasons";
import { AppSettings } from "./settings";

export type AccountMode = { kind: "none" } | { kind: "loggedIn" } | { kind: "username"; name: string };
export type AppTab = "home" | "forYou" | "discover" | "lists" | "profile";
export type ShowChange = { kind: "planned" } | { kind: "watched" } | { kind: "removed" } | { kind: "scored"; score: number };

export interface TokenStore {
  get(): Promise<string | null>;
  set(token: string | null): Promise<void>;
}

export interface ShowRow { entry: ListEntry; extraSeasons: number; foldedTitles: MediaTitle[] }
export interface ShelfSpec { sort: string[]; season?: string; seasonYear?: number }

type PageData = { Page: { media: Media[]; pageInfo?: { hasNextPage?: boolean | null } | null } };

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const NOT_FOR_ME_LIST = "Not for me";
/** AniList is currently strict about request rates: space writes ~2 s apart. */
const WRITE_SPACING = 2100;

export class AppModel {
  readonly client = new AniListClient();
  readonly settings = new AppSettings();
  readonly matcher = new MatchEngine();
  readonly ages = new AgeRatings();

  /** Bumped on every change; the UI re-renders from it. */
  version = 0;
  private listeners = new Set<() => void>();

  mode: AccountMode = { kind: "none" };
  viewer: Viewer | null = null;
  private _entries: ListEntry[] = [];
  private entryIndex = new Map<number, number>();
  franchises = new ListFranchises();
  private grouping: { folded: Set<number>; extra: Map<number, number>; titles: Map<number, MediaTitle[]> } | null = null;
  isLoadingList = false;
  listLoadedOnce = false;
  didBootstrap = false;
  deletedEntryIds = new Set<number>();
  errorMessage: string | null = null;

  feeds = new Map<string, RecommendationResult>();
  loadingFeeds = new Set<string>();
  loadingMore = new Set<string>();
  recommendationErrors = new Map<string, string>();
  allCategories: AnimeCategory[] = [];
  private forceRebuild = new Set<string>();

  selectedTab: AppTab = "home";
  ratePrompt: Media | null = null;
  notForMeMedia = new Map<number, Media>();
  isResettingNotForMe = false;

  private detailCache = new Map<number, { detail: MediaDetail; at: number }>();
  private generationTasks = new Map<string, Promise<void>>();
  private moreTasks = new Map<string, Promise<void>>();
  private showSync: Promise<void> = Promise.resolve();
  private accountGeneration = 0;

  private readonly tokens: TokenStore;
  private readonly aiAllowedNow: () => boolean;

  constructor(tokens: TokenStore, aiAllowedNow: () => boolean = () => true) {
    this.tokens = tokens;
    this.aiAllowedNow = aiAllowedNow;
    const changed = () => this.notify();
    this.settings.onChange = changed;
    this.matcher.onChange = changed;
    this.ages.onChange = changed;
    this.matcher.aiEnabled = () => this.settings.useOnDeviceAI && this.aiAllowedNow();
  }

  subscribe(fn: () => void) {
    this.listeners.add(fn);
    return () => void this.listeners.delete(fn);
  }

  private notifyQueued = false;
  notify() {
    this.version++;
    // Many changes in one tick → one redraw.
    if (this.notifyQueued) return;
    this.notifyQueued = true;
    queueMicrotask(() => {
      this.notifyQueued = false;
      for (const fn of this.listeners) fn();
    });
  }

  get canEdit() { return this.mode.kind === "loggedIn"; }

  get entries() { return this._entries; }
  private set entries(list: ListEntry[]) {
    this._entries = list;
    this.entryIndex = new Map();
    list.forEach((e, i) => { if (!this.entryIndex.has(e.mediaId)) this.entryIndex.set(e.mediaId, i); });
    this.matcher.update(list);
    this.franchises = new ListFranchises(list.map((e) => e.media));
    this.grouping = null;
    this.notify();
  }

  showError(message: string) {
    this.errorMessage = message;
    this.notify();
  }

  // MARK: Lifecycle

  async bootstrap() {
    if (this.didBootstrap) return;
    this.didBootstrap = true;
    const token = await this.tokens.get();
    if (token) {
      this.client.token = token;
      this.mode = { kind: "loggedIn" };
    } else {
      const name = Defaults.get<string>("readOnlyUsername", "");
      if (name) this.mode = { kind: "username", name };
    }
    this.notify();
    if (this.mode.kind !== "none") await this.reloadAll();
  }

  async reloadAll() {
    await this.useCachedViewer();
    await this.loadCachedList();
    await this.loadCachedFanSignal();
    await this.loadViewer();
    await this.refreshList();
  }

  private async useCachedViewer() {
    if (this.viewer) return;
    const cached = await DiskCache.load<Viewer>("viewer");
    if (!cached) return;
    if (this.mode.kind === "loggedIn") this.viewer = cached;
    else if (this.mode.kind === "username" && cached.name.toLowerCase() === this.mode.name.toLowerCase()) this.viewer = cached;
    this.notify();
  }

  // MARK: Auth

  /** anitrack://auth#access_token=...&token_type=Bearer&expires_in=... */
  async handleAuthCallback(url: string) {
    const raw = url.includes("#") ? url.split("#")[1] : url.split("?")[1] ?? "";
    const pair = raw.split("&").map((p) => p.split("=")).find(([k]) => k === "access_token");
    if (!pair?.[1]) {
      this.showError("Login failed: AniList didn't return an access token.");
      return;
    }
    await this.useToken(decodeURIComponent(pair[1]));
  }

  async useToken(token: string) {
    const t = token.trim();
    if (!t) return;
    await this.tokens.set(t);
    Defaults.remove("readOnlyUsername");
    this.client.token = t;
    this.mode = { kind: "loggedIn" };
    this.feeds = new Map();
    this.notify();
    await this.reloadAll();
  }

  async useUsername(name: string) {
    const n = name.trim();
    if (!n) return;
    Defaults.set("readOnlyUsername", n);
    this.mode = { kind: "username", name: n };
    this.feeds = new Map();
    this.notify();
    await this.reloadAll();
    if (!this.viewer) {
      Defaults.remove("readOnlyUsername");
      this.mode = { kind: "none" };
      this.notify();
    }
  }

  async logOut() {
    await this.tokens.set(null);
    Defaults.remove("readOnlyUsername");
    this.client.token = null;
    this.mode = { kind: "none" };
    this.viewer = null;
    this.entries = [];
    this.listLoadedOnce = false;
    this.feeds = new Map();
    this.notForMeEntries = new Map();
    this.pendingNotForMe = new Set();
    this.notForMeListReady = false;
    this.notForMeLoadedFor = null;
    this.notForMeMedia = new Map();
    this.recommendationErrors = new Map();
    this.forceRebuild = new Set();
    this.accountGeneration++;
    this.generationTasks.clear();
    this.moreTasks.clear();
    this.loadingFeeds = new Set();
    this.loadingMore = new Set();
    this.matcher.resetSignals();
    await clearPersonal();
    this.notify();
  }

  // MARK: Loading

  async loadViewer() {
    try {
      if (this.mode.kind === "loggedIn") {
        this.viewer = (await this.client.run<{ Viewer: Viewer }>(Queries.viewer, {}, { waitOnRateLimit: !this.viewer })).Viewer;
      } else if (this.mode.kind === "username") {
        this.viewer = (await this.client.run<{ User: Viewer }>(Queries.userByName, { name: this.mode.name }, { waitOnRateLimit: !this.viewer })).User;
      } else {
        this.viewer = null;
      }
      if (this.viewer) {
        void DiskCache.save("viewer", this.viewer);
        this.useDismissedPicks(this.viewer.id);
      }
      const lang = this.viewer?.options?.titleLanguage;
      if (lang && !Defaults.has("titleLanguage")) {
        this.settings.titleLanguage = lang.startsWith("ENGLISH") ? "english" : lang.startsWith("NATIVE") ? "native" : "romaji";
      }
    } catch (e) {
      if (this.mode.kind === "loggedIn" && isAuthError(e)) {
        this.showError("Your AniList login expired. Please log in again.");
        await this.logOut();
      } else {
        if (!this.viewer) this.viewer = (await DiskCache.load<Viewer>("viewer")) ?? null;
        if (!this.viewer && !isCancellation(e)) this.showError((e as Error).message);
      }
    }
    this.notify();
  }

  async refreshList() {
    const userId = this.viewer?.id;
    if (!userId) {
      this.listLoadedOnce = true;
      this.notify();
      return;
    }
    this.isLoadingList = true;
    this.notify();
    try {
      type C = { MediaListCollection?: { lists?: { name?: string; status?: ListStatus; isCustomList?: boolean; entries?: ListEntry[] }[] } };
      const data = await this.client.run<C>(Queries.listCollection, { userId });
      const seen = new Set<number>();
      const result: ListEntry[] = [];
      const notForMe = new Map<number, number>();
      const lists = data.MediaListCollection?.lists ?? [];
      for (const g of lists) {
        if (g.isCustomList !== true || g.name !== NOT_FOR_ME_LIST) continue;
        for (const e of g.entries ?? []) {
          notForMe.set(e.mediaId, e.id);
          this.notForMeMedia.set(e.mediaId, e.media);
        }
      }
      for (const g of lists) {
        if (g.isCustomList === true) continue;
        for (const e of g.entries ?? []) {
          if (seen.has(e.id)) continue;
          seen.add(e.id);
          result.push(e);
        }
      }
      const filtered = notForMe.size ? result.filter((e) => notForMe.get(e.mediaId) !== e.id) : result;
      this.entries = filtered;
      void DiskCache.save(this.cacheName("list"), filtered);
      if (this.mode.kind === "loggedIn") this.mergeNotForMe(notForMe);
    } catch (e) {
      if (!this._entries.length && !isCancellation(e)) this.showError((e as Error).message);
    } finally {
      this.isLoadingList = false;
      this.listLoadedOnce = true;
      this.notify();
    }
  }

  private async loadCachedList() {
    if (this._entries.length || !this.viewer) return;
    const cached = await DiskCache.load<ListEntry[]>(this.cacheName("list"));
    if (cached && !this._entries.length) this.entries = cached;
  }

  private async loadCachedFanSignal() {
    if (!this.viewer) return;
    const cached = await DiskCache.load<Record<number, number>>(this.cacheName("fans2"));
    if (cached) this.matcher.addFanSignal(cached);
  }

  /** "Not for me" belongs to one account. */
  private useDismissedPicks(viewerId: number) {
    const owner = Defaults.get<number | null>("dismissedPicks-owner", null);
    if (owner === viewerId) return;
    Defaults.set("dismissedPicks-owner", viewerId);
    if (owner === null) return;
    Defaults.set(`dismissedPicks-${owner}`, [...this.settings.dismissedPicks]);
    this.settings.setDismissed(Defaults.get<number[]>(`dismissedPicks-${viewerId}`, []));
  }

  private cacheName(kind: string) {
    return `${kind}-${this.viewer?.id ?? 0}`;
  }

  // MARK: Queries on the local list

  entry(mediaId: number): ListEntry | undefined {
    const i = this.entryIndex.get(mediaId);
    if (i === undefined) return undefined;
    const e = this._entries[i];
    return e?.mediaId === mediaId ? e : this._entries.find((x) => x.mediaId === mediaId);
  }

  /** Your list as shows: every later season folds into the show's earliest season on your list. */
  shows(statuses: ListStatus[]): ShowRow[] {
    const wanted = new Set(statuses);
    const g = this.grouping ?? this.makeGrouping();
    return this._entries
      .filter((e) => wanted.has(e.status) && !g.folded.has(e.mediaId))
      .map((e) => ({ entry: e, extraSeasons: g.extra.get(e.mediaId) ?? 0, foldedTitles: g.titles.get(e.mediaId) ?? [] }));
  }

  private makeGrouping() {
    const extra = new Map<number, number>();
    const titles = new Map<number, MediaTitle[]>();
    const folded = new Set<number>();
    for (const e of this._entries) {
      if (!isLaterSeason(e.media)) continue;
      let current = e.media;
      const visited = new Set([e.mediaId]);
      let anchor: number | undefined;
      for (;;) {
        const previous = prequelId(current);
        if (previous === undefined || visited.size >= 15 || visited.has(previous)) break;
        const earlier = this.entry(previous);
        if (!earlier) break;
        visited.add(previous);
        if (isSeason(earlier.media)) anchor = earlier.mediaId;
        current = earlier.media;
      }
      if (anchor !== undefined) {
        folded.add(e.mediaId);
        extra.set(anchor, (extra.get(anchor) ?? 0) + 1);
        titles.set(anchor, [...(titles.get(anchor) ?? []), e.media.title]);
      }
    }
    this.grouping = { folded, extra, titles };
    return this.grouping;
  }

  showCount(status: ListStatus) {
    return this.shows([status]).length;
  }

  get listStats() {
    const counted = this._entries.filter((e) => e.status !== "PLANNING");
    const episodes = counted.reduce((a, e) => a + progressValue(e), 0);
    const minutes = counted.reduce((a, e) => a + progressValue(e) * (e.media.duration ?? 24), 0);
    const scores = this._entries.map(scoreValue).filter((s) => s > 0);
    const meanScore = scores.length ? scores.reduce((a, b) => a + b, 0) / scores.length / 10 : undefined;
    return { count: counted.length, episodes, minutes, meanScore };
  }

  // MARK: Editing

  async save(media: Media, status: ListStatus, progress: number | null, scoreRaw: number | null): Promise<EntryLite> {
    const saved = await this.writeEntry(media, status, progress, scoreRaw);
    const list = [...this._entries];
    AppModel.apply(saved, media, status, list);
    this.entries = list;
    this.removeKnownFromFeeds();
    return saved;
  }

  private async writeEntry(media: Media, status: ListStatus, progress: number | null, scoreRaw: number | null): Promise<EntryLite> {
    this.detailCache.delete(media.id);
    const vars: Record<string, unknown> = { mediaId: media.id, status };
    if (progress !== null && progress !== undefined) vars.progress = Math.max(0, progress);
    if (scoreRaw !== null && scoreRaw !== undefined) vars.scoreRaw = Math.min(100, Math.max(0, scoreRaw));
    this.ensureNotForMeLoaded();
    const wasNotForMe = this.notForMeEntries.has(media.id);
    if (wasNotForMe) {
      vars.private = false;
      vars.hiddenFromStatusLists = false;
      vars.customLists = [];
    }
    const saved = (await this.client.run<{ SaveMediaListEntry: EntryLite }>(Queries.saveEntry, vars)).SaveMediaListEntry;
    if (wasNotForMe || this.settings.dismissedPicks.has(media.id)) {
      this.notForMeEntries.delete(media.id);
      this.pendingNotForMe.delete(media.id);
      this.settings.removeDismissed(media.id);
      this.saveNotForMeState();
    }
    return saved;
  }

  private static apply(saved: EntryLite, media: Media, status: ListStatus, list: ListEntry[]) {
    const now = Math.floor(Date.now() / 1000);
    const i = list.findIndex((e) => e.mediaId === media.id);
    if (i >= 0) {
      list[i] = { ...list[i], status: saved.status ?? status, progress: saved.progress, score: saved.score, updatedAt: saved.updatedAt ?? now };
    } else {
      list.push({ id: saved.id, mediaId: media.id, status: saved.status ?? status, score: saved.score, progress: saved.progress,
        updatedAt: saved.updatedAt ?? now, media, createdAt: now });
    }
  }

  removeKnownFromFeeds() {
    for (const [key, value] of this.feeds) {
      const known = value.picks.filter((p) => this.entry(p.id) || this.franchises.contains(p.media)).map((p) => p.id);
      if (!known.length) continue;
      const updated = { ...value, picks: value.picks.filter((p) => !known.includes(p.id)) };
      this.feeds.set(key, updated);
      void DiskCache.save(this.feedCacheName(key), updated);
    }
    this.notify();
  }

  /** Marks a show as fully watched (keeps your score). Returns false if AniList couldn't be updated. */
  async markCompleted(media: Media, askRating = true): Promise<boolean> {
    const existing = this.entry(media.id);
    const progress = media.episodes ?? availableEpisodes(media) ?? existing?.progress ?? null;
    try {
      await this.save(media, "COMPLETED", progress, null);
      if (askRating && scoreValue(existing ?? {}) === 0) this.ratePrompt = media;
      this.removeFromFeeds(media.id);
      this.updateOtherSeasons(media, { kind: "watched" });
      this.notify();
      return true;
    } catch (e) {
      this.showError((e as Error).message);
      return false;
    }
  }

  async planToWatch(media: Media): Promise<boolean> {
    try {
      await this.save(media, "PLANNING", null, null);
      this.removeFromFeeds(media.id);
      this.updateOtherSeasons(media, { kind: "planned" });
      return true;
    } catch (e) {
      this.showError((e as Error).message);
      return false;
    }
  }

  // MARK: Whole show
  // planned → the rest are planned too; watched → all completed (airing → Watching, unreleased →
  // Planning); removed → all removed; your score → every season you haven't scored. Progress per season.

  private async otherSeasons(media: Media): Promise<Media[]> {
    if (!isSeason(media)) return [];
    const chain = await SeasonChain.seasons(media, this.client);
    return chain.filter((m) => m.id !== media.id && isSeason(m) && Seasons.sameShow(media.title, m.title));
  }

  updateOtherSeasons(media: Media, change: ShowChange) {
    if (this.mode.kind !== "loggedIn") return;
    const account = this.viewer?.id;
    const generation = this.accountGeneration;
    const still = () => this.viewer?.id === account && this.accountGeneration === generation;
    // One after another, so two quick changes never race each other.
    this.showSync = this.showSync.then(async () => {
      if (!still()) return;
      const seasons = await this.otherSeasons(media);
      let failed = false;
      const written: [EntryLite, Media, ListStatus][] = [];
      const removed = new Set<number>();
      const removedEntries = new Map<number, ListEntry>();
      if (change.kind === "removed") {
        for (const s of seasons) { const e = this.entry(s.id); if (e) removedEntries.set(s.id, e); }
        const ids = new Set([...removedEntries.values()].map((e) => e.id));
        if (ids.size) {
          for (const id of ids) this.deletedEntryIds.add(id);
          this.entries = this._entries.filter((e) => !ids.has(e.id));
        }
      }
      const write = async (season: Media, status: ListStatus, progress: number | null, score: number | null) => {
        written.push([await this.writeEntry(season, status, progress, score), season, status]);
      };
      for (const season of seasons) {
        if (!still()) break;
        const current = this.entry(season.id) ?? removedEntries.get(season.id);
        try {
          let wrote = true;
          switch (change.kind) {
            case "planned":
              if (!current) await write(season, "PLANNING", null, null); else wrote = false;
              break;
            case "watched":
              if (current?.status === "COMPLETED") { wrote = false; break; }
              if (season.status === "NOT_YET_RELEASED") {
                if (!current) await write(season, "PLANNING", null, null); else wrote = false;
              } else if (season.status === "RELEASING") {
                const aired = availableEpisodes(season) ?? current?.progress ?? 0;
                await write(season, "CURRENT", Math.max(aired ?? 0, progressValue(current ?? {})), null);
              } else {
                await write(season, "COMPLETED", season.episodes ?? current?.progress ?? null, null);
              }
              break;
            case "removed":
              if (current) {
                this.detailCache.delete(season.id);
                await this.client.run(Queries.deleteEntry, { id: current.id });
                removed.add(current.id);
              } else wrote = false;
              break;
            case "scored":
              if (current && scoreValue(current) === 0 && change.score > 0) await write(season, current.status, null, change.score);
              else wrote = false;
              break;
          }
          if (wrote) await sleep(WRITE_SPACING);
        } catch {
          failed = true;
        }
      }
      if ((written.length || removed.size) && still()) {
        const list = [...this._entries];
        for (const [saved, season, status] of written) AppModel.apply(saved, season, status, list);
        this.entries = list.filter((e) => !removed.has(e.id));
        this.removeKnownFromFeeds();
      }
      if (failed && change.kind === "removed" && still()) await this.refreshList();
      if (failed) this.showError(`Couldn't update every season of ${displayTitle(media, this.settings.titleLanguage)} on AniList. Try again in a moment.`);
    });
  }

  /** Leaves your list at once; if AniList says no, it comes back and the error is shown. */
  async removeShow(media: Media, entryId: number) {
    this.detailCache.delete(media.id);
    const removed = this._entries.find((e) => e.id === entryId);
    this.deletedEntryIds.add(entryId);
    this.entries = this._entries.filter((e) => e.id !== entryId);
    try {
      await this.client.run(Queries.deleteEntry, { id: entryId });
    } catch (e) {
      this.deletedEntryIds.delete(entryId);
      if (removed && !this._entries.some((x) => x.id === entryId)) this.entries = [...this._entries, removed];
      throw e;
    }
    this.updateOtherSeasons(media, { kind: "removed" });
  }

  aiAvailabilityChanged() {
    this.matcher.aiAvailabilityChanged();
  }

  // MARK: Browsing

  async browse(opts: BrowseOptions): Promise<Media[]> {
    return (await this.browsePage(opts)).media;
  }

  async browsePage(opts: BrowseOptions): Promise<{ media: Media[]; hasNextPage: boolean }> {
    const raw = await this.rawPage(opts);
    const collapsed = await SeasonRoots.collapse(raw.media, this.client);
    const searching = !!opts.search?.trim();
    return { media: this.finish(collapsed, searching, opts.category ?? null, opts.firstSeasonsOnly ?? false), hasNextPage: raw.hasNextPage };
  }

  /** Several shelves at once, with one shared first-season lookup. */
  async browseShelves(specs: ShelfSpec[], waitOnRateLimit = true): Promise<({ ok: true; media: Media[] } | { ok: false; error: unknown })[]> {
    const raw = await Promise.all(specs.map(async (s) => {
      try {
        const page = await this.rawPage({ sort: s.sort, season: s.season, seasonYear: s.seasonYear, waitOnRateLimit });
        return { ok: true as const, media: page.media };
      } catch (error) {
        return { ok: false as const, error };
      }
    }));
    const known = new Map<number, Media>();
    for (const r of raw) if (r.ok) for (const m of r.media) known.set(m.id, m);
    const later = [...known.values()].filter(isLaterSeason);
    let found = new Map<number, Found>();
    if (later.length) found = await SeasonRoots.resolve(later, known, this.client, false);
    return raw.map((r) => (r.ok ? { ok: true as const, media: this.finish(SeasonRoots.apply(r.media, found), false, null, false) } : r));
  }

  private finish(items: Media[], searching: boolean, category: AnimeCategory | null, firstSeasonsOnly: boolean): Media[] {
    const adultOK = isAdultOnly(category);
    return items.filter((m) => {
      if (m.isAdult === true && !adultOK) return false;
      if (isMovie(m) && !searching) return false;
      if (this.settings.hideChinese && m.countryOfOrigin === "CN") return false;
      if (!searching && this.settings.dismissedPicks.has(m.id)) return false;
      if (firstSeasonsOnly && this.franchises.contains(m)) return false;
      return true;
    });
  }

  private async rawPage(o: BrowseOptions & { waitOnRateLimit?: boolean }): Promise<{ media: Media[]; hasNextPage: boolean }> {
    const perPage = o.perPage ?? 25;
    const vars: Record<string, unknown> = { page: o.page ?? 1, perPage, sort: o.sort, isAdult: isAdultOnly(o.category) };
    if (o.genres?.length) vars.genres = o.genres;
    if (o.excludeGenres?.length) vars.genresNot = o.excludeGenres;
    if (o.minScore != null) vars.scoreGreater = o.minScore;
    if (o.maxPopularity != null) vars.popularityLesser = o.maxPopularity;
    if (o.minPopularity != null) vars.popularityGreater = o.minPopularity;
    const searching = !!o.search?.trim();
    if (searching) vars.search = o.search; else vars.formatNot = ["MOVIE"];
    if (o.category) for (const [k, v] of Object.entries(categoryVariables(o.category))) if (!(k in vars)) vars[k] = v;
    if (o.season) vars.season = o.season;
    if (o.seasonYear) vars.seasonYear = o.seasonYear;
    if (o.status) vars.status = o.status;
    const data = await this.client.run<PageData>(Queries.browseWithRelations, vars, { waitOnRateLimit: o.waitOnRateLimit ?? true });
    return { media: data.Page.media, hasNextPage: data.Page.pageInfo?.hasNextPage ?? data.Page.media.length >= perPage };
  }

  cachedDetail(id: number): MediaDetail | undefined {
    const hit = this.detailCache.get(id);
    return hit && Date.now() - hit.at < 600_000 ? hit.detail : undefined;
  }

  async detail(id: number): Promise<MediaDetail> {
    const hit = this.cachedDetail(id);
    if (hit) return hit;
    const loaded = (await this.client.run<{ Media: MediaDetail }>(Queries.detail, { id })).Media;
    if (this.detailCache.size > 40) this.detailCache.clear();
    this.detailCache.set(id, { detail: loaded, at: Date.now() });
    return loaded;
  }

  // MARK: Recommendations

  static feedKey(c?: AnimeCategory | null) {
    return c ? categoryId(c) : "any";
  }

  private recOptions(category?: AnimeCategory | null): RecOptions {
    return {
      hideChinese: this.settings.hideChinese,
      includeUnreleased: this.settings.includeUnreleased,
      dismissed: new Set(this.settings.dismissedPicks),
      titleLanguage: this.settings.titleLanguage,
      useOnDeviceAI: this.settings.useOnDeviceAI,
      category,
      aiAllowedNow: this.aiAllowedNow(),
    };
  }

  feed(c?: AnimeCategory | null) { return this.feeds.get(AppModel.feedKey(c)); }
  picks(c?: AnimeCategory | null) { return this.feed(c)?.picks ?? []; }
  isLoadingFeed(c?: AnimeCategory | null) { return this.loadingFeeds.has(AppModel.feedKey(c)); }
  isLoadingMore(c?: AnimeCategory | null) { return this.loadingMore.has(AppModel.feedKey(c)); }
  recommendationError(c?: AnimeCategory | null) { return this.recommendationErrors.get(AppModel.feedKey(c)); }

  private feedCacheName(key: string) {
    return this.cacheName(`feed3-${key.replace(/[^A-Za-z0-9]/g, "_")}`);
  }

  async generateRecommendations(category: AnimeCategory | null = null, force = false) {
    const key = AppModel.feedKey(category);
    const running = this.generationTasks.get(key);
    if (running) {
      await running;
      if (!force || this.generationTasks.has(key)) return;
    }
    const task = this.performGenerate(category, force).finally(() => this.generationTasks.delete(key));
    this.generationTasks.set(key, task);
    await task;
  }

  async loadMorePicks(category: AnimeCategory | null = null) {
    const key = AppModel.feedKey(category);
    const running = this.moreTasks.get(key);
    if (running) return running;
    const task = this.performLoadMore(category).finally(() => this.moreTasks.delete(key));
    this.moreTasks.set(key, task);
    await task;
  }

  private async performGenerate(category: AnimeCategory | null, force: boolean) {
    const key = AppModel.feedKey(category);
    if (this.loadingFeeds.has(key)) return;
    if (!this._entries.length) {
      if (this.listLoadedOnce) { this.recommendationErrors.set(key, "Your list is empty. Add and rate a few shows first."); this.notify(); }
      return;
    }
    const options = this.recOptions(category);
    const fp = fingerprint(this._entries, options);
    const mustRebuild = force || this.forceRebuild.has(key);
    this.forceRebuild.delete(key);
    if (!mustRebuild) {
      if (!this.feeds.has(key)) {
        const saved = await DiskCache.load<RecommendationResult>(this.feedCacheName(key));
        if (saved) this.feeds.set(key, saved);
      }
      const current = this.feeds.get(key);
      if (current?.picks.length) {
        const age = Date.now() - current.generatedAt;
        if ((current.fingerprint === fp && age < 3 * 86_400_000) || age < 86_400_000) {
          const kept = current.picks.filter((p) => this.stillWanted(p.media));
          if (kept.length !== current.picks.length) {
            const updated = { ...current, picks: kept };
            this.feeds.set(key, updated);
            void DiskCache.save(this.feedCacheName(key), updated);
          }
          this.notify();
          return;
        }
      }
    }
    this.loadingFeeds.add(key);
    this.recommendationErrors.delete(key);
    this.notify();
    const account = this.viewer?.id;
    const generation = this.accountGeneration;
    let count = 0;
    try {
      const { picks, usedAI, fanSignal } = await runRecommender(this._entries, this.client, options);
      if (this.viewer?.id !== account || generation !== this.accountGeneration) return;
      this.matcher.addFanSignal(fanSignal);
      void DiskCache.save(this.cacheName("fans2"), this.matcher.fanSnapshot);
      const kept = picks.filter((p) => this.stillWanted(p.media));
      count = kept.length;
      const result: RecommendationResult = { picks: kept, generatedAt: Date.now(), fingerprint: fp, usedOnDeviceAI: usedAI, round: 1, exhausted: false };
      this.feeds.set(key, result);
      void DiskCache.save(this.feedCacheName(key), result);
    } catch (e) {
      if (!isCancellation(e)) this.recommendationErrors.set(key, (e as Error).message);
      return;
    } finally {
      this.loadingFeeds.delete(key);
      this.notify();
    }
    if (count < 10) await this.loadMorePicks(category);
  }

  private async performLoadMore(category: AnimeCategory | null) {
    const key = AppModel.feedKey(category);
    const start = this.feeds.get(key);
    if (!start || start.exhausted || this.loadingMore.has(key) || this.loadingFeeds.has(key)) return;
    this.loadingMore.add(key);
    this.notify();
    try {
      const options = this.recOptions(category);
      const account = this.viewer?.id;
      const generatedAt = start.generatedAt;
      const shown = new Set(start.picks.map((p) => p.id));
      let round = start.round;
      let added: typeof start.picks = [];
      let usedAI = false;
      let emptyRounds = 0;
      let failed = false;
      while (emptyRounds < 3) {
        round += 1;
        try {
          const more = await runRecommender(this._entries, this.client, options, round, shown);
          if (this.viewer?.id !== account) return;
          this.matcher.addFanSignal(more.fanSignal);
          void DiskCache.save(this.cacheName("fans2"), this.matcher.fanSnapshot);
          const fresh = more.picks.filter((p) => !shown.has(p.id));
          if (!fresh.length) { emptyRounds++; continue; }
          added = fresh;
          usedAI = more.usedAI;
          for (const p of fresh) shown.add(p.id);
          break;
        } catch (e) {
          if (!isCancellation(e)) this.recommendationErrors.set(key, (e as Error).message);
          failed = true;
          break;
        }
      }
      const latest = this.feeds.get(key);
      if (!latest || latest.generatedAt !== generatedAt) return;
      const present = new Set(latest.picks.map((p) => p.id));
      const updated: RecommendationResult = {
        ...latest,
        picks: [...latest.picks, ...added.filter((p) => !present.has(p.id) && this.stillWanted(p.media))],
        round: Math.max(latest.round, round),
        usedOnDeviceAI: latest.usedOnDeviceAI || usedAI,
        exhausted: latest.exhausted || (!failed && emptyRounds >= 3),
      };
      this.feeds.set(key, updated);
      void DiskCache.save(this.feedCacheName(key), updated);
    } finally {
      this.loadingMore.delete(key);
      this.notify();
    }
  }

  private stillWanted(m: Media): boolean {
    if (this.entry(m.id) || this.franchises.contains(m)) return false;
    if (this.settings.dismissedPicks.has(m.id)) return false;
    if (this.settings.hideChinese && m.countryOfOrigin === "CN") return false;
    if (isMovie(m) || isLaterSeason(m)) return false;
    if (!this.settings.includeUnreleased && m.status === "NOT_YET_RELEASED") return false;
    return true;
  }

  removeFromFeeds(mediaId: number) {
    for (const [key, value] of this.feeds) {
      if (!value.picks.some((p) => p.id === mediaId)) continue;
      const updated = { ...value, picks: value.picks.filter((p) => p.id !== mediaId) };
      this.feeds.set(key, updated);
      void DiskCache.save(this.feedCacheName(key), updated);
    }
    this.notify();
  }

  invalidatePicks() {
    for (const k of this.feeds.keys()) this.forceRebuild.add(k);
    this.forceRebuild.add("any");
    this.feeds = new Map();
    this.notify();
  }

  // MARK: "Not for me", synced through AniList (a private, hidden "Not for me" custom list)

  private notForMeEntries = new Map<number, number>();
  private pendingNotForMe = new Set<number>();
  private notForMeSyncing = false;
  private notForMeListReady = false;
  private notForMeLoadedFor: number | null = null;

  dismissPick(mediaId: number, media?: Media) {
    if (media && !this.notForMeMedia.has(mediaId)) this.notForMeMedia.set(mediaId, media);
    this.settings.addDismissed(mediaId);
    this.ensureNotForMeLoaded();
    if (this.mode.kind === "loggedIn" && !this.notForMeEntries.has(mediaId)) {
      this.pendingNotForMe.add(mediaId);
      this.saveNotForMeState();
      void this.syncNotForMe();
    }
    this.removeFromFeeds(mediaId);
  }

  async loadNotForMeMedia(): Promise<boolean> {
    const missing = [...this.settings.dismissedPicks].filter((id) => !this.notForMeMedia.has(id));
    for (let i = 0; i < missing.length; i += 50) {
      const chunk = missing.slice(i, i + 50);
      try {
        const data = await this.client.run<PageData>(Queries.mediaByIds, { ids: chunk, perPage: chunk.length });
        for (const m of data.Page.media) this.notForMeMedia.set(m.id, m);
      } catch {
        return false;
      }
    }
    this.notify();
    return true;
  }

  async undoNotForMe(mediaId: number) {
    this.ensureNotForMeLoaded();
    this.settings.removeDismissed(mediaId);
    this.pendingNotForMe.delete(mediaId);
    this.saveNotForMeState();
    const entryId = this.notForMeEntries.get(mediaId);
    if (this.mode.kind !== "loggedIn" || entryId === undefined) return;
    try {
      await this.client.run(Queries.deleteEntry, { id: entryId });
      this.notForMeEntries.delete(mediaId);
      this.saveNotForMeState();
    } catch {
      this.settings.addDismissed(mediaId);
      this.showError("Couldn't update AniList. Try again in a moment.");
    }
  }

  isNotForMeEntry(lite?: EntryLite | null) {
    return !!lite && this.notForMeEntries.get(lite.mediaId) === lite.id;
  }

  resetDismissedPicks() {
    this.ensureNotForMeLoaded();
    const toDelete = [...this.notForMeEntries];
    this.settings.setDismissed([]);
    this.pendingNotForMe = new Set();
    this.saveNotForMeState();
    this.invalidatePicks();
    if (this.mode.kind !== "loggedIn" || !toDelete.length) {
      this.notForMeEntries = new Map();
      this.saveNotForMeState();
      return;
    }
    this.isResettingNotForMe = true;
    this.notify();
    void (async () => {
      try {
        for (let i = 0; i < toDelete.length; i++) {
          if (i > 0) await sleep(WRITE_SPACING);
          const [mediaId, entryId] = toDelete[i];
          try {
            await this.client.run(Queries.deleteEntry, { id: entryId });
            this.notForMeEntries.delete(mediaId);
          } catch {
            this.settings.setDismissed([...this.settings.dismissedPicks, ...this.notForMeEntries.keys()]);
            this.showError('Couldn\'t reset all "Not for me" shows on AniList. Try again later.');
            break;
          }
        }
        this.saveNotForMeState();
      } finally {
        this.isResettingNotForMe = false;
        this.notify();
      }
    })();
  }

  private get notForMeKey() {
    return `notForMe-${this.viewer?.id ?? 0}`;
  }

  private ensureNotForMeLoaded() {
    const id = this.viewer?.id;
    if (id === undefined || this.notForMeLoadedFor === id) return;
    this.notForMeLoadedFor = id;
    const stored = Defaults.get<Record<string, number>>(this.notForMeKey + "-entries", {});
    this.notForMeEntries = new Map(Object.entries(stored).map(([k, v]) => [Number(k), v]));
    this.pendingNotForMe = new Set(Defaults.get<number[]>(this.notForMeKey + "-pending", []));
  }

  private saveNotForMeState() {
    if (!this.viewer || this.notForMeLoadedFor !== this.viewer.id) return;
    Defaults.set(this.notForMeKey + "-entries", Object.fromEntries(this.notForMeEntries));
    Defaults.set(this.notForMeKey + "-pending", [...this.pendingNotForMe]);
  }

  private mergeNotForMe(remote: Map<number, number>) {
    this.ensureNotForMeLoaded();
    const migratedKey = this.notForMeKey + "-migrated";
    if (!Defaults.get(migratedKey, false)) {
      for (const id of this.settings.dismissedPicks) if (!remote.has(id) && !this.entry(id)) this.pendingNotForMe.add(id);
      Defaults.set(migratedKey, true);
    }
    for (const id of remote.keys()) this.pendingNotForMe.delete(id);
    this.notForMeEntries = new Map(remote);
    const merged = new Set([...remote.keys(), ...this.pendingNotForMe]);
    const current = this.settings.dismissedPicks;
    if (merged.size !== current.size || [...merged].some((id) => !current.has(id))) {
      this.settings.setDismissed(merged);
      for (const id of merged) this.removeFromFeedsQuietly(id);
    }
    this.saveNotForMeState();
    void this.syncNotForMe();
  }

  private removeFromFeedsQuietly(id: number) {
    for (const [key, value] of this.feeds) {
      if (value.picks.some((p) => p.id === id)) this.feeds.set(key, { ...value, picks: value.picks.filter((p) => p.id !== id) });
    }
  }

  private async syncNotForMe() {
    if (this.mode.kind !== "loggedIn" || !this.pendingNotForMe.size || this.notForMeSyncing) return;
    this.notForMeSyncing = true;
    try {
      if (!(await this.ensureNotForMeListExists())) return;
      let first = true;
      for (;;) {
        const mediaId = this.pendingNotForMe.values().next().value as number | undefined;
        if (mediaId === undefined) break;
        if (!first) await sleep(WRITE_SPACING);
        first = false;
        if (this.entry(mediaId) || !this.settings.dismissedPicks.has(mediaId)) {
          this.pendingNotForMe.delete(mediaId);
          continue;
        }
        try {
          const saved = (await this.client.run<{ SaveMediaListEntry: { id: number; mediaId: number } }>(
            Queries.saveNotForMe, { mediaId, lists: [NOT_FOR_ME_LIST] })).SaveMediaListEntry;
          this.notForMeEntries.set(saved.mediaId, saved.id);
          this.pendingNotForMe.delete(mediaId);
          this.saveNotForMeState();
        } catch {
          break;
        }
      }
      this.saveNotForMeState();
    } finally {
      this.notForMeSyncing = false;
    }
  }

  /** Adds "Not for me" to your custom lists, keeping every list you already have. */
  private async ensureNotForMeListExists(): Promise<boolean> {
    if (this.notForMeListReady) return true;
    type V = { Viewer?: { mediaListOptions?: { animeList?: { customLists?: string[] | null } | null } | null } | null };
    let current: string[] | null | undefined;
    try {
      current = (await this.client.run<V>(Queries.listOptions)).Viewer?.mediaListOptions?.animeList?.customLists;
    } catch {
      return false;
    }
    if (!current) return false; // couldn't read your lists: never risk overwriting them
    if (current.includes(NOT_FOR_ME_LIST)) {
      this.notForMeListReady = true;
      return true;
    }
    try {
      type U = { UpdateUser?: { mediaListOptions?: { animeList?: { customLists?: string[] | null } | null } | null } | null };
      const updated = await this.client.run<U>(Queries.updateCustomLists, { lists: [...current, NOT_FOR_ME_LIST] });
      if (!updated.UpdateUser?.mediaListOptions?.animeList?.customLists?.includes(NOT_FOR_ME_LIST)) return false;
    } catch {
      return false;
    }
    this.notForMeListReady = true;
    await sleep(WRITE_SPACING);
    return true;
  }

  // MARK: Categories

  async loadCategories() {
    if (this.allCategories.length) return;
    const cached = await DiskCache.load<{ categories: AnimeCategory[]; savedAt: number }>("categories2");
    if (cached && Date.now() - cached.savedAt < 7 * 86_400_000 && cached.categories.length) {
      this.allCategories = cached.categories;
      this.notify();
      return;
    }
    try {
      type C = { GenreCollection?: string[]; MediaTagCollection?: { name: string; isAdult?: boolean; isGeneralSpoiler?: boolean }[] };
      const data = await this.client.run<C>(Queries.categories);
      const genres = (data.GenreCollection ?? []).map(genre);
      const tags = (data.MediaTagCollection ?? []).filter((t) => t.isAdult !== true && t.isGeneralSpoiler !== true).map((t) => tag(t.name));
      const known = new Set([...genres, ...tags].map(categoryId));
      const featured = FEATURED_CATEGORIES.filter((c) => known.has(categoryId(c)));
      const featuredIds = new Set(featured.map(categoryId));
      const rest = [...genres, ...tags].filter((c) => !featuredIds.has(categoryId(c))).sort((a, b) => a.name.localeCompare(b.name));
      this.allCategories = [...featured, ...rest];
      void DiskCache.save("categories2", { categories: this.allCategories, savedAt: Date.now() });
    } catch (e) {
      if (isCancellation(e)) return;
      this.allCategories = FEATURED_CATEGORIES;
    }
    this.notify();
  }

  get featuredCategories(): AnimeCategory[] {
    if (!this.allCategories.length) return FEATURED_CATEGORIES;
    const known = new Set(this.allCategories.map(categoryId));
    return FEATURED_CATEGORIES.filter((c) => known.has(categoryId(c)));
  }
}

export interface BrowseOptions {
  search?: string;
  sort: string[];
  season?: string;
  seasonYear?: number;
  status?: string;
  category?: AnimeCategory | null;
  genres?: string[];
  excludeGenres?: string[];
  minScore?: number;
  maxPopularity?: number;
  minPopularity?: number;
  firstSeasonsOnly?: boolean;
  page?: number;
  perPage?: number;
}
