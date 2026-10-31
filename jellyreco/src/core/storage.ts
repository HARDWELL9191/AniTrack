// Your JellyReco data, saved on the Jellyfin server in your account's private JellyReco storage
// (DisplayPreferences "jellyreco-lists", client "jellyreco"), shared with the iPhone app:
//   mylist          My List: titles on your server and For You picks you don't have yet
//   notforme        For You picks you passed on
//   seenelsewhere   For You picks you've already seen somewhere else
//   tmdbkey         your TMDB key (entered once, on either device)
//   settings        the iPhone's settings; the ones both apps have are kept in step (see SHARED)
//   windowssettings this PC app's own settings
// For titles on your server, Not for me is Jellyfin's own thumbs-down (UserData.Likes = false).
//
// Every save reads the record first and changes only its own keys, so the phone and the PC never
// overwrite each other's changes.

import type { Jellyfin } from "./api";
import { encodeEntry, type ExternalTitle, externalTitle, listEntryForServer, listEntryForTitle, type MyListEntry, myListEntry, slim, titleId } from "./titles";

export const STORAGE_ID = "jellyreco-lists";
export const STORAGE_CLIENT = "jellyreco";
/** Where the first Windows builds kept their lists (moved over once). */
const OLD_CLIENT = "JellyReco";

export type ExternalListName = "notforme" | "seenelsewhere";

interface DisplayPreferencesDto {
  Id?: string;
  CustomPrefs?: Record<string, string | null>;
  [key: string]: unknown;
}

function parse(raw: string | null | undefined): unknown {
  if (!raw) return null;
  try { return JSON.parse(raw); } catch { return null; }
}
const titlesOf = (raw: string | null | undefined) => (Array.isArray(parse(raw)) ? (parse(raw) as unknown[]).map(externalTitle).filter((t): t is ExternalTitle => !!t) : []);
const entriesOf = (raw: string | null | undefined) => (Array.isArray(parse(raw)) ? (parse(raw) as unknown[]).map(myListEntry).filter((e): e is MyListEntry => !!e) : []);

export class AccountStorage {
  myList: MyListEntry[] = [];
  notForMe: ExternalTitle[] = [];
  seenElsewhere: ExternalTitle[] = [];
  tmdbKey = "";
  /** The iPhone's settings JSON (shared keys are read from and written into it). */
  phoneSettings: Record<string, unknown> | null = null;
  /** This app's own settings (null until loaded or if none saved yet). */
  windowsSettings: Record<string, unknown> | null = null;
  loaded = false;
  private queue: Promise<void> = Promise.resolve();
  private api: Jellyfin;
  constructor(api: Jellyfin) { this.api = api; }

  private read(client = STORAGE_CLIENT) {
    return this.api.get<DisplayPreferencesDto>(`/DisplayPreferences/${STORAGE_ID}`, { userId: this.api.userId, client });
  }

  private apply(custom: Record<string, string | null>) {
    this.myList = entriesOf(custom.mylist);
    // Older iPhone builds kept For You picks in "wishlist": they belong on My List.
    for (const t of titlesOf(custom.wishlist)) if (!this.myList.some((e) => e.external && titleId(e.external) === titleId(t))) this.myList.push(listEntryForTitle(t));
    this.notForMe = titlesOf(custom.notforme);
    this.seenElsewhere = titlesOf(custom.seenelsewhere);
    this.tmdbKey = (custom.tmdbkey ?? "").trim();
    const phone = parse(custom.settings);
    this.phoneSettings = phone && typeof phone === "object" && !Array.isArray(phone) ? (phone as Record<string, unknown>) : null;
    const win = parse(custom.windowssettings);
    this.windowsSettings = win && typeof win === "object" && !Array.isArray(win) ? (win as Record<string, unknown>) : null;
  }

  async load() {
    const prefs = await this.read();
    this.apply(prefs?.CustomPrefs ?? {});
    await this.migrateOldWindowsLists().catch(() => {});
    this.loaded = true;
  }

  /** Read-modify-write of only the keys this change touches (queued, one at a time). */
  private save(change: (custom: Record<string, string | null>) => void): Promise<void> {
    const job = this.queue.catch(() => {}).then(async () => {
      const prefs = (await this.read().catch(() => null)) ?? {};
      const custom: Record<string, string | null> = { ...(prefs.CustomPrefs ?? {}) };
      change(custom);
      const body: DisplayPreferencesDto = {
        ...prefs,
        Id: (prefs.Id as string) ?? STORAGE_ID,
        Client: STORAGE_CLIENT,
        SortBy: (prefs.SortBy as string) ?? "SortName",
        SortOrder: (prefs.SortOrder as string) ?? "Ascending",
        ScrollDirection: (prefs.ScrollDirection as string) ?? "Horizontal",
        ShowBackdrop: (prefs.ShowBackdrop as boolean) ?? true,
        ShowSidebar: (prefs.ShowSidebar as boolean) ?? false,
        RememberIndexing: (prefs.RememberIndexing as boolean) ?? false,
        RememberSorting: (prefs.RememberSorting as boolean) ?? false,
        PrimaryImageWidth: (prefs.PrimaryImageWidth as number) ?? 0,
        PrimaryImageHeight: (prefs.PrimaryImageHeight as number) ?? 0,
        CustomPrefs: custom,
      };
      await this.api.post(`/DisplayPreferences/${STORAGE_ID}`, body, { userId: this.api.userId, client: STORAGE_CLIENT });
    });
    this.queue = job;
    return job;
  }

  // The iPhone keeps at most 1000 My List entries and 500 titles per list.
  private saveMyList() { const json = JSON.stringify(this.myList.slice(0, 1000).map(encodeEntry)); return this.save((c) => { c.mylist = json; if (c.wishlist && c.wishlist !== "[]") c.wishlist = "[]"; }); }
  private saveTitles(list: ExternalListName) {
    const json = JSON.stringify((list === "notforme" ? this.notForMe : this.seenElsewhere).slice(0, 500).map(slim));
    return this.save((c) => { c[list] = json; });
  }

  // MARK: My List

  /** Episodes and seasons go on My List as their show (like the iPhone). */
  static listId(item: { Id: string; Type?: string; SeriesId?: string | null }) {
    return item.Type === "Episode" || item.Type === "Season" ? (item.SeriesId ?? item.Id) : item.Id;
  }
  hasServer(id: string) { return this.myList.some((e) => e.serverId === id); }
  hasTitle(t: ExternalTitle) { const id = titleId(t); return this.myList.some((e) => e.external && titleId(e.external) === id); }

  async toggleServer(item: { Id: string; Type?: string; SeriesId?: string | null; Name?: string | null; SeriesName?: string | null }) {
    const id = AccountStorage.listId(item);
    if (this.hasServer(id)) this.myList = this.myList.filter((e) => e.serverId !== id);
    else this.myList = [listEntryForServer(id, item.Type === "Episode" || item.Type === "Season" ? item.SeriesName ?? item.Name : item.Name), ...this.myList];
    await this.saveMyList();
  }

  async toggleTitle(t: ExternalTitle) {
    const id = titleId(t);
    if (this.hasTitle(t)) {
      this.myList = this.myList.filter((e) => !(e.external && titleId(e.external) === id));
      await this.saveMyList();
      return;
    }
    this.myList = [listEntryForTitle(t), ...this.myList];
    const wasOut = this.notForMe.some((x) => titleId(x) === id), wasSeen = this.seenElsewhere.some((x) => titleId(x) === id);
    this.notForMe = this.notForMe.filter((x) => titleId(x) !== id);
    this.seenElsewhere = this.seenElsewhere.filter((x) => titleId(x) !== id);
    if (wasOut) await this.saveTitles("notforme");
    if (wasSeen) await this.saveTitles("seenelsewhere");
    await this.saveMyList();
  }

  async removeEntries(ids: Set<string>, key: (e: MyListEntry) => string) {
    const before = this.myList.length;
    this.myList = this.myList.filter((e) => !ids.has(key(e)));
    if (this.myList.length !== before) await this.saveMyList();
  }

  // MARK: Not for me / Already seen (titles you don't have)

  isHidden(t: ExternalTitle) {
    const id = titleId(t);
    return this.hasTitle(t) || this.notForMe.some((x) => titleId(x) === id) || this.seenElsewhere.some((x) => titleId(x) === id);
  }
  /** Every title For You never shows: on My List, Not for me or Already seen. */
  hiddenIds(): Set<string> {
    return new Set([...this.myList.flatMap((e) => (e.external ? [titleId(e.external)] : [])), ...this.notForMe.map(titleId), ...this.seenElsewhere.map(titleId)]);
  }

  async markNotForMe(t: ExternalTitle, on = true) {
    const id = titleId(t);
    this.notForMe = this.notForMe.filter((x) => titleId(x) !== id);
    if (on) {
      this.notForMe = [slim(t), ...this.notForMe];
      if (this.hasTitle(t)) { this.myList = this.myList.filter((e) => !(e.external && titleId(e.external) === id)); await this.saveMyList(); }
    }
    await this.saveTitles("notforme");
  }

  async markSeen(t: ExternalTitle, on = true) {
    const id = titleId(t);
    this.seenElsewhere = this.seenElsewhere.filter((x) => titleId(x) !== id);
    if (on) {
      this.seenElsewhere = [slim(t), ...this.seenElsewhere];
      if (this.hasTitle(t)) { this.myList = this.myList.filter((e) => !(e.external && titleId(e.external) === id)); await this.saveMyList(); }
    }
    await this.saveTitles("seenelsewhere");
  }

  async clear(list: ExternalListName) {
    if (list === "notforme") this.notForMe = []; else this.seenElsewhere = [];
    await this.saveTitles(list);
  }

  // MARK: TMDB key and settings

  async saveTmdbKey(key: string) { this.tmdbKey = key.trim(); const k = this.tmdbKey; await this.save((c) => { c.tmdbkey = k; }); }

  /** Saves this app's settings and the shared ones into the iPhone's settings (keeping its others). */
  async saveSettings(windows: Record<string, unknown>, shared: Record<string, unknown>) {
    this.windowsSettings = windows;
    await this.save((c) => {
      c.windowssettings = JSON.stringify(windows);
      const phone = parse(c.settings);
      const merged = { ...(phone && typeof phone === "object" && !Array.isArray(phone) ? (phone as Record<string, unknown>) : {}), ...shared };
      c.settings = JSON.stringify(merged);
      this.phoneSettings = merged;
    });
  }

  // MARK: Moving the first Windows builds' lists over (once)

  private async migrateOldWindowsLists() {
    const old = await this.read(OLD_CLIENT).catch(() => null);
    const c = old?.CustomPrefs;
    if (!c || c.movedToShared === "1") return;
    type OldEntry = { id: string; title?: string; poster?: string | null; year?: number | null; genres?: string[]; overview?: string };
    const oldList = (k: string) => (Array.isArray(parse(c[k])) ? (parse(c[k]) as OldEntry[]).filter((e) => typeof e?.id === "string") : []);
    const toTitle = (e: OldEntry): ExternalTitle | null => {
      const m = /^tmdb:(tv|movie):(\d+)$/.exec(e.id);
      if (!m) return null;
      return externalTitle({
        source: m[1] === "tv" ? "tmdbTV" : "tmdbMovie", sourceId: Number(m[2]), title: e.title ?? "Untitled", overview: e.overview ?? "",
        genres: e.genres ?? [], tags: [], isAdult: false, year: e.year ?? undefined,
        posterURL: e.poster ? `https://image.tmdb.org/t/p/w500${e.poster}` : undefined,
      });
    };
    let changedList = false, changedOut = false, changedSeen = false;
    for (const e of oldList("watchLater")) {
      const t = toTitle(e);
      if (t) { if (!this.hasTitle(t)) { this.myList.push(listEntryForTitle(t)); changedList = true; } }
      else if (!this.hasServer(e.id)) { this.myList.push(listEntryForServer(e.id, e.title)); changedList = true; }
    }
    for (const e of oldList("notForMe")) { const t = toTitle(e); if (t && !this.notForMe.some((x) => titleId(x) === titleId(t))) { this.notForMe.push(t); changedOut = true; } }
    for (const e of oldList("seen")) { const t = toTitle(e); if (t && !this.seenElsewhere.some((x) => titleId(x) === titleId(t))) { this.seenElsewhere.push(t); changedSeen = true; } }
    const oldSettings = parse(c.settings) as Record<string, unknown> | null;
    if (oldSettings && typeof oldSettings === "object") {
      if (!this.tmdbKey && typeof oldSettings.tmdbKey === "string" && oldSettings.tmdbKey.trim()) await this.saveTmdbKey(oldSettings.tmdbKey);
      if (!this.windowsSettings) { this.windowsSettings = oldSettings; await this.save((cc) => { cc.windowssettings = JSON.stringify(oldSettings); }); }
    }
    if (changedList) await this.saveMyList();
    if (changedOut) await this.saveTitles("notforme");
    if (changedSeen) await this.saveTitles("seenelsewhere");
    // Mark the old record as moved (its contents stay, as a backup).
    await this.api.post(`/DisplayPreferences/${STORAGE_ID}`, { ...old, Client: OLD_CLIENT, CustomPrefs: { ...c, movedToShared: "1" } }, { userId: this.api.userId, client: OLD_CLIENT });
  }
}

/** "Not for me" for a title on your server: thumbs-down on the server (Undo clears it). */
export function setNotForMe(api: Jellyfin, id: string, on: boolean) {
  return api.setLikes(id, on ? false : null);
}
