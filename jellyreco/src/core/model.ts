// The app's state: servers and the signed-in user, settings, libraries, and small helpers every
// screen shares. Screens subscribe through useModel() and re-render on notify().

import { ApiError, deviceIdFor, Jellyfin, ReadOnlyJellyfin } from "./api";
import { Discovery, type DiscoveryContext } from "./discovery";
import type { PlayerController } from "./player";
import { Reco, sourcesOf } from "./reco";
import { applyShared, loadSettings, mergeServerSettings, saveSettings, type Settings, sharedPart, syncedPart } from "./settings";
import { AccountStorage } from "./storage";
import { Tmdb } from "./tmdb";
import type { Item, User } from "./types";

export type Tab = "home" | "forYou" | "search" | "favorites" | "library" | "myList" | "notForMe" | "settings" | "dashboard";

export interface SavedServer {
  id: string; // Jellyfin server id (or the URL until we know it)
  name: string;
  url: string;
  version?: string;
  /** Signed-in accounts on this server. */
  accounts: { userId: string; name: string; token: string; imageTag?: string | null }[];
  lastUserId?: string;
}

export interface TokenStore {
  load(): Promise<string | null>;
  save(data: string | null): Promise<void>;
}

export interface Toast { id: number; text: string; tone?: "info" | "error" | "success"; action?: { label: string; run: () => void } }

export class AppModel {
  version = 0;
  private listeners = new Set<() => void>();

  settings: Settings = loadSettings();
  servers: SavedServer[] = [];
  api: Jellyfin | null = null;
  user: User | null = null;
  server: SavedServer | null = null;
  views: Item[] = [];
  didBootstrap = false;
  tab: Tab = "home";
  libraryId: string | null = null;
  toasts: Toast[] = [];
  errorMessage: string | null = null;
  /** Bumped when user data (played, favorite, progress) changes anywhere, so lists refetch. */
  dataVersion = 0;
  player: PlayerController | null = null;
  /** "Not for me" set this session (the server keeps them as thumbs-down). */
  dismissed: Set<string> = new Set();
  /** My List, Not for me, Already seen, TMDB key and settings: your account's JellyReco storage
   * on the server, shared with the iPhone app. */
  storage: AccountStorage | null = null;
  /** Your library and taste (read-only), and the For You picks from TMDB: the iPhone's engines. */
  reco = new Reco(() => (this.api ? {
    api: new ReadOnlyJellyfin(this.api), views: this.views, storage: this.storage, dismissed: this.dismissed,
    includeWatchingAsLiked: this.settings.includeWatchingAsLiked,
  } : null));
  discovery = new Discovery(() => this.notify());
  private tmdbClient: { key: string; client: Tmdb } | null = null;
  /** Battery saver on: the AI part pauses (set by main.tsx). */
  powerSaver = false;
  readonly deviceId = deviceIdFor(localStorage);
  readonly deviceName: string;
  private store: TokenStore;
  private toastId = 0;

  constructor(store: TokenStore, deviceName: string) {
    this.store = store;
    this.deviceName = deviceName;
  }

  subscribe = (fn: () => void) => {
    this.listeners.add(fn);
    return () => void this.listeners.delete(fn);
  };

  notify() {
    this.version++;
    for (const fn of this.listeners) fn();
  }

  get isAdmin() { return !!this.user?.Policy?.IsAdministrator; }
  get signedIn() { return !!(this.api && this.user); }

  updateSettings(patch: Partial<Settings>) {
    this.settings = { ...this.settings, ...patch };
    saveSettings(this.settings);
    this.scheduleSettingsSync();
    applyTheme(this.settings.theme);
    void this.player?.applySettings(this.settings);
    this.notify();
  }

  toast(text: string, tone: Toast["tone"] = "info", action?: Toast["action"]) {
    const id = ++this.toastId;
    this.toasts = [...this.toasts, { id, text, tone, action }];
    this.notify();
    setTimeout(() => this.dismissToast(id), action ? 7000 : 3800);
  }

  dismissToast(id: number) {
    this.toasts = this.toasts.filter((t) => t.id !== id);
    this.notify();
  }

  fail(e: unknown, context?: string) {
    if ((e as Error)?.name === "AbortError") return;
    const msg = e instanceof Error ? e.message : String(e);
    if (e instanceof ApiError && e.status === 401 && this.signedIn) {
      void this.signOut(true);
      this.errorMessage = "Your session ended. Sign in again.";
    } else this.toast(context ? `${context}: ${msg}` : msg, "error");
    this.notify();
  }

  dataChanged() {
    this.dataVersion++;
    this.notify();
  }

  // MARK: Persistence

  private async persist() {
    await this.store.save(JSON.stringify({ servers: this.servers, current: this.server?.id ?? null }));
  }

  async bootstrap() {
    applyTheme(this.settings.theme);
    try {
      const raw = await this.store.load();
      if (raw) {
        const data = JSON.parse(raw) as { servers: SavedServer[]; current: string | null };
        this.servers = data.servers ?? [];
        const current = this.servers.find((s) => s.id === data.current);
        const account = current?.accounts.find((a) => a.userId === current.lastUserId) ?? current?.accounts[0];
        if (current && account) await this.resume(current, account);
      }
    } catch {
      /* start signed out */
    }
    this.didBootstrap = true;
    this.notify();
  }

  private async resume(server: SavedServer, account: SavedServer["accounts"][number]) {
    const api = new Jellyfin(server.url, this.deviceId, this.deviceName, account.token, account.userId);
    try {
      const user = await api.me();
      await this.enter(server, api, user);
    } catch (e) {
      if (e instanceof ApiError && e.status === 401) {
        // Token revoked: forget it but keep the server.
        server.accounts = server.accounts.filter((a) => a.userId !== account.userId);
        await this.persist();
      } else {
        // Offline: open signed in anyway so the user sees an error per screen, not a login page.
        this.api = api;
        this.server = server;
        this.user = { Id: account.userId, Name: account.name, HasPassword: true, HasConfiguredPassword: true, PrimaryImageTag: account.imageTag };
        this.errorMessage = `Can't reach ${server.name} right now. ${(e as Error).message}`;
      }
    }
  }

  private async enter(server: SavedServer, api: Jellyfin, user: User) {
    this.api = api;
    this.user = user;
    this.server = server;
    server.lastUserId = user.Id;
    this.tab = "home";
    this.libraryId = null;
    this.dismissed = new Set();
    this.reco.reset();
    this.discovery.reset();
    const storage = new AccountStorage(api);
    this.storage = storage;
    await this.persist();
    void storage.load().then(() => {
      if (this.storage !== storage) return;
      // What's saved for your account wins: this app's settings, then the ones shared with the iPhone.
      const before = JSON.stringify(sharedPart(this.settings));
      let next = storage.windowsSettings ? mergeServerSettings(this.settings, storage.windowsSettings) : this.settings;
      next = applyShared(next, storage.phoneSettings);
      // The TMDB key: either device's copy fills in the other.
      if (storage.tmdbKey) next = { ...next, tmdbKey: storage.tmdbKey };
      else if (next.tmdbKey) void storage.saveTmdbKey(next.tmdbKey).catch(() => {});
      this.settings = next;
      saveSettings(next);
      applyTheme(next.theme);
      if (!storage.windowsSettings || JSON.stringify(sharedPart(next)) !== before) this.scheduleSettingsSync();
      this.reco.rebuild();
      this.notify();
    }).catch((e) => this.fail(e, "Couldn't load My List"));
    void api.reportCapabilities().catch(() => {});
    await this.loadViews();
    this.notify();
  }

  async loadViews() {
    if (!this.api) return;
    try {
      const r = await this.api.views();
      this.views = r.Items;
    } catch (e) {
      this.fail(e, "Couldn't load your libraries");
    }
    this.notify();
  }

  /** Probes an address and returns a Jellyfin client for it (normalizing http/https). */
  async connect(address: string): Promise<{ api: Jellyfin; name: string; id: string; version?: string; startupDone: boolean }> {
    const candidates = /^https?:\/\//i.test(address.trim()) ? [address] : [`https://${address.trim()}`, `http://${address.trim()}`];
    let last: unknown = null;
    for (const url of candidates) {
      const api = new Jellyfin(url, this.deviceId, this.deviceName);
      try {
        const info = await api.publicInfo();
        if (!info?.Id) throw new Error("That address isn't a Jellyfin server.");
        return { api, name: info.ServerName ?? "Jellyfin", id: info.Id, version: info.Version ?? undefined, startupDone: info.StartupWizardCompleted !== false };
      } catch (e) {
        last = e;
      }
    }
    throw last instanceof Error ? last : new Error("Couldn't connect.");
  }

  async signedInWith(api: Jellyfin, serverInfo: { id: string; name: string; version?: string }, token: string, user: User) {
    api.token = token;
    api.userId = user.Id;
    let server = this.servers.find((s) => s.id === serverInfo.id);
    if (!server) {
      server = { id: serverInfo.id, name: serverInfo.name, url: api.server, version: serverInfo.version, accounts: [] };
      this.servers = [...this.servers, server];
    }
    server.url = api.server;
    server.name = serverInfo.name;
    server.version = serverInfo.version;
    server.accounts = [...server.accounts.filter((a) => a.userId !== user.Id), { userId: user.Id, name: user.Name ?? "", token, imageTag: user.PrimaryImageTag }];
    await this.enter(server, api, user);
  }

  async switchAccount(server: SavedServer, userId: string) {
    const account = server.accounts.find((a) => a.userId === userId);
    if (!account) return;
    await this.resume(server, account);
    this.notify();
  }

  async signOut(expired = false) {
    const api = this.api;
    const server = this.server;
    if (api && !expired) await api.logout().catch(() => {});
    if (server && this.user) server.accounts = server.accounts.filter((a) => a.userId !== this.user!.Id);
    this.api = null;
    this.user = null;
    this.server = null;
    this.views = [];
    this.storage = null;
    this.reco.reset();
    this.discovery.reset();
    await this.player?.shutdown();
    await this.persist();
    this.notify();
  }

  async forgetServer(id: string) {
    this.servers = this.servers.filter((s) => s.id !== id);
    await this.persist();
    this.notify();
  }

  async refreshUser() {
    if (!this.api) return;
    try {
      this.user = await this.api.me();
      this.notify();
    } catch (e) {
      this.fail(e);
    }
  }

  // MARK: Account storage and For You

  private settingsTimer: ReturnType<typeof setTimeout> | null = null;
  /** Saves settings to the server a moment after the last change (one request per burst). */
  scheduleSettingsSync() {
    if (this.settingsTimer) clearTimeout(this.settingsTimer);
    this.settingsTimer = setTimeout(() => {
      const st = this.storage;
      if (!st?.loaded) return;
      void st.saveSettings(syncedPart(this.settings), sharedPart(this.settings)).catch(() => {});
    }, 1500);
  }

  /** The TMDB client for the current key. */
  get tmdb(): Tmdb {
    const key = this.settings.tmdbKey;
    if (!this.tmdbClient || this.tmdbClient.key !== key) { this.tmdbClient = { key, client: new Tmdb(key) }; this.discovery.reset(true); }
    return this.tmdbClient.client;
  }

  /** Sets the TMDB key on this PC and in your account (so the iPhone has it too). */
  async setTmdbKey(key: string) {
    this.updateSettings({ tmdbKey: key.trim() });
    await this.storage?.saveTmdbKey(key.trim());
  }

  discoveryContext(): DiscoveryContext | null {
    if (!this.api || !this.user || !this.server) return null;
    return {
      reco: this.reco, tmdb: this.tmdb, storage: this.storage, sources: sourcesOf(this.views),
      serverId: this.server.id, userId: this.user.Id, useAI: this.settings.useOnDeviceAI && !this.powerSaver,
    };
  }

  /** After My List / Not for me / watched changes: taste again (cheap) and screens refresh. */
  tasteChanged() {
    this.reco.rebuild();
    this.dataChanged();
  }

  // MARK: Shortcuts used everywhere

  async toggleFavorite(item: Item) {
    if (!this.api) return;
    const on = !item.UserData?.IsFavorite;
    try {
      await this.api.setFavorite(item.Id, on);
      item.UserData = { ...(item.UserData ?? {}), IsFavorite: on };
      this.toast(on ? "Added to favorites" : "Removed from favorites", "success");
      this.dataChanged();
    } catch (e) {
      this.fail(e);
    }
  }

  async togglePlayed(item: Item) {
    if (!this.api) return;
    const on = !item.UserData?.Played;
    try {
      await this.api.setPlayed(item.Id, on);
      item.UserData = { ...(item.UserData ?? {}), Played: on, PlaybackPositionTicks: 0 };
      this.toast(on ? "Marked as watched" : "Marked as unwatched", "success");
      this.dataChanged();
    } catch (e) {
      this.fail(e);
    }
  }
}

export function applyTheme(theme: Settings["theme"]) {
  const root = document.documentElement;
  if (theme === "system") root.removeAttribute("data-theme");
  else root.setAttribute("data-theme", theme);
}
