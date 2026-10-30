// The app's state: servers and the signed-in user, settings, libraries, and small helpers every
// screen shares. Screens subscribe through useModel() and re-render on notify().

import { ApiError, deviceIdFor, Jellyfin } from "./api";
import { ServerLists } from "./lists";
import type { PlayerController } from "./player";
import type { Feed, Library } from "./recommender";
import { loadSettings, mergeServerSettings, saveSettings, type Settings, syncedPart } from "./settings";
import type { Item, User } from "./types";

export type Tab = "home" | "forYou" | "search" | "favorites" | "library" | "settings" | "dashboard";

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
  /** For You: the library snapshot and feeds per (library, category). */
  forYouLibrary: Library | null = null;
  feeds = new Map<string, Feed>();
  /** "Not for me" set this session (the server keeps them as thumbs-down). */
  dismissed: Set<string> = new Set();
  /** Watch later, saved on the server. */
  lists: ServerLists | null = null;
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
    this.lists?.saveSettings(syncedPart(this.settings));
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
    this.forYouLibrary = null;
    this.feeds.clear();
    this.dismissed = new Set();
    this.lists = new ServerLists(api);
    await this.persist();
    void this.lists.load().then(() => {
      // Your settings follow you: what's saved on the server wins over this PC's copy.
      const lists = this.lists;
      if (!lists) return;
      if (lists.settings) {
        this.settings = mergeServerSettings(this.settings, lists.settings);
        saveSettings(this.settings);
        applyTheme(this.settings.theme);
        this.feeds.clear();
      } else lists.saveSettings(syncedPart(this.settings)); // first time: upload this PC's settings
      this.notify();
    });
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
    this.forYouLibrary = null;
    this.feeds.clear();
    this.lists = null;
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
