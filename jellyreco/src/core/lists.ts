// Your JellyReco data, saved on the Jellyfin server per user (so a new PC has everything), in your
// JellyReco display preferences (DisplayPreferences custom prefs, client "JellyReco"):
// - Settings: everything except a few per-device ones (see DEVICE_KEYS in settings.ts).
// - Watch later (AniReco's Plan to watch): titles on your server (Jellyfin ids) and titles you
//   don't have yet (TMDB keys, "tmdb:tv:1429", with a snapshot to show them). A Jellyfin playlist
//   doesn't fit: adding a show to a playlist expands it into every episode.
// - Not for me / Already watched for titles you don't have (TMDB). For titles on your server,
//   Not for me is Jellyfin's own thumbs-down (UserData.Likes = false), seen by every client.

import type { Jellyfin } from "./api";

const PREFS_ID = "jellyreco-lists";
const CLIENT = "JellyReco";
const SETTINGS_KEY = "settings";

export interface ListEntry {
  id: string; // Jellyfin item id, or "tmdb:<tv|movie>:<id>"
  added: number;
  title?: string;
  poster?: string | null; // TMDB poster path
  year?: number | null;
  genres?: string[];
  overview?: string;
}

export type ListName = "watchLater" | "notForMe" | "seen";
const LISTS: ListName[] = ["watchLater", "notForMe", "seen"];

interface DisplayPreferencesDto {
  Id?: string;
  CustomPrefs?: Record<string, string | null>;
  [key: string]: unknown;
}

export class ServerLists {
  lists: Record<ListName, ListEntry[]> = { watchLater: [], notForMe: [], seen: [] };
  /** Settings saved on the server (null until loaded or if none saved yet). */
  settings: Record<string, unknown> | null = null;
  private settingsTimer: ReturnType<typeof setTimeout> | null = null;
  private prefs: DisplayPreferencesDto | null = null;
  private saving: Promise<void> = Promise.resolve();

  private api: Jellyfin;
  constructor(api: Jellyfin) { this.api = api; }

  get watchLater() { return this.lists.watchLater; }

  async load() {
    try {
      this.prefs = await this.api.get<DisplayPreferencesDto>(`/DisplayPreferences/${PREFS_ID}`, { userId: this.api.userId, client: CLIENT });
      for (const name of LISTS) {
        const raw = this.prefs?.CustomPrefs?.[name];
        const parsed = raw ? (JSON.parse(raw) as ListEntry[]) : [];
        this.lists[name] = Array.isArray(parsed) ? parsed.filter((e) => typeof e?.id === "string") : [];
      }
      const rawSettings = this.prefs?.CustomPrefs?.[SETTINGS_KEY];
      this.settings = rawSettings ? (JSON.parse(rawSettings) as Record<string, unknown>) : null;
    } catch {
      this.settings = null;
    }
  }

  has(id: string, list: ListName = "watchLater") { return this.lists[list].some((e) => e.id === id); }

  async add(entry: Omit<ListEntry, "added"> | string, list: ListName = "watchLater") {
    const e: ListEntry = typeof entry === "string" ? { id: entry, added: Date.now() } : { ...entry, added: Date.now() };
    if (this.has(e.id, list)) return;
    this.lists[list] = [e, ...this.lists[list]].slice(0, 3000);
    await this.save();
  }

  async remove(ids: string[], list: ListName = "watchLater") {
    const drop = new Set(ids);
    const before = this.lists[list].length;
    this.lists[list] = this.lists[list].filter((e) => !drop.has(e.id));
    if (this.lists[list].length !== before) await this.save();
  }

  /** Saves settings a moment after the last change (sliders send many). */
  saveSettings(values: Record<string, unknown>) {
    this.settings = values;
    if (this.settingsTimer) clearTimeout(this.settingsTimer);
    this.settingsTimer = setTimeout(() => void this.save().catch(() => {}), 1200);
  }

  /** Saves everything (queued, so quick changes never overwrite each other). */
  private save(): Promise<void> {
    const job = this.saving.catch(() => {}).then(async () => {
      const prefs: Record<string, string | null> = { ...(this.prefs?.CustomPrefs ?? {}) };
      for (const name of LISTS) prefs[name] = JSON.stringify(this.lists[name]);
      if (this.settings) prefs[SETTINGS_KEY] = JSON.stringify(this.settings);
      const body: DisplayPreferencesDto = {
        ...(this.prefs ?? {}),
        Id: PREFS_ID,
        Client: CLIENT,
        SortBy: (this.prefs?.SortBy as string) ?? "SortName",
        SortOrder: (this.prefs?.SortOrder as string) ?? "Ascending",
        RememberIndexing: false, RememberSorting: false, ScrollDirection: "Horizontal", ShowBackdrop: true, ShowSidebar: false,
        PrimaryImageHeight: 250, PrimaryImageWidth: 250, IndexBy: null,
        CustomPrefs: prefs,
      };
      await this.api.post(`/DisplayPreferences/${PREFS_ID}`, body, { userId: this.api.userId, client: CLIENT });
      this.prefs = body;
    });
    this.saving = job;
    return job;
  }
}

/** "Not for me" for a title on your server: thumbs-down on the server (Undo clears it). */
export function setNotForMe(api: Jellyfin, id: string, on: boolean) {
  return api.setLikes(id, on ? false : null);
}
