// Your JellyReco lists, saved on the Jellyfin server per user:
// - "Not for me" is Jellyfin's own thumbs-down (UserData.Likes = false), so it reaches every client.
// - "Watch later" (AniReco's Plan to watch) lives in your JellyReco display preferences on the
//   server (DisplayPreferences custom prefs, client "JellyReco"). A playlist doesn't fit: adding a
//   show to a Jellyfin playlist expands it into every episode.

import type { Jellyfin } from "./api";

const PREFS_ID = "jellyreco-lists";
const CLIENT = "JellyReco";
const KEY = "watchLater";

export interface WatchLaterEntry { id: string; added: number }

interface DisplayPreferencesDto {
  Id?: string;
  CustomPrefs?: Record<string, string | null>;
  [key: string]: unknown;
}

export class ServerLists {
  watchLater: WatchLaterEntry[] = [];
  private prefs: DisplayPreferencesDto | null = null;
  private saving: Promise<void> = Promise.resolve();

  constructor(private api: Jellyfin) {}

  async load() {
    try {
      this.prefs = await this.api.get<DisplayPreferencesDto>(`/DisplayPreferences/${PREFS_ID}`, { userId: this.api.userId, client: CLIENT });
      const raw = this.prefs?.CustomPrefs?.[KEY];
      const parsed = raw ? (JSON.parse(raw) as WatchLaterEntry[]) : [];
      this.watchLater = Array.isArray(parsed) ? parsed.filter((e) => typeof e?.id === "string") : [];
    } catch {
      this.watchLater = [];
    }
  }

  has(id: string) { return this.watchLater.some((e) => e.id === id); }

  async add(id: string) {
    if (this.has(id)) return;
    this.watchLater = [{ id, added: Date.now() }, ...this.watchLater];
    await this.save();
  }

  async remove(ids: string[]) {
    const drop = new Set(ids);
    const before = this.watchLater.length;
    this.watchLater = this.watchLater.filter((e) => !drop.has(e.id));
    if (this.watchLater.length !== before) await this.save();
  }

  /** Saves the list (queued, so quick changes never overwrite each other). */
  private save(): Promise<void> {
    this.saving = this.saving.then(async () => {
      const body: DisplayPreferencesDto = {
        ...(this.prefs ?? {}),
        Id: PREFS_ID,
        Client: CLIENT,
        SortBy: (this.prefs?.SortBy as string) ?? "SortName",
        SortOrder: (this.prefs?.SortOrder as string) ?? "Ascending",
        RememberIndexing: false, RememberSorting: false, ScrollDirection: "Horizontal", ShowBackdrop: true, ShowSidebar: false,
        PrimaryImageHeight: 250, PrimaryImageWidth: 250, IndexBy: null,
        CustomPrefs: { ...(this.prefs?.CustomPrefs ?? {}), [KEY]: JSON.stringify(this.watchLater) },
      };
      await this.api.post(`/DisplayPreferences/${PREFS_ID}`, body, { userId: this.api.userId, client: CLIENT });
      this.prefs = body;
    });
    return this.saving;
  }
}

/** "Not for me": thumbs-down on the server (and Undo clears it). */
export function setNotForMe(api: Jellyfin, id: string, on: boolean) {
  return api.setLikes(id, on ? false : null);
}
