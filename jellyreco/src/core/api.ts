// Jellyfin REST client (Jellyfin 10.10 – 12.x). Auth is the `Authorization: MediaBrowser ...`
// header; URLs that mpv or <img> open carry the token as `ApiKey=` (Jellyfin 12 only accepts the
// old `api_key` when an admin turns legacy authorization on).

import type {
  AuthResult, BackupManifest, BackupOptions, Item, ItemsResult, Lyrics, MediaSegment, PlaybackInfoResponse,
  PublicSystemInfo, QuickConnectResult, SessionInfo, SystemInfo, User,
} from "./types";

export const APP_NAME = "JellyReco";
export const APP_VERSION = "1.0.0";

type FetchFn = (url: string, init?: RequestInit) => Promise<Response>;
let fetchImpl: FetchFn = (url, init) => fetch(url, init);
/** The installed app sends requests from the native side (no CORS limits, any server). */
export const setFetch = (f: FetchFn) => (fetchImpl = f);

export class ApiError extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

export type Query = Record<string, string | number | boolean | null | undefined | (string | number)[]>;

export function queryString(q?: Query): string {
  if (!q) return "";
  const parts: string[] = [];
  for (const [k, v] of Object.entries(q)) {
    if (v === undefined || v === null || v === "") continue;
    if (Array.isArray(v)) {
      if (!v.length) continue;
      parts.push(`${encodeURIComponent(k)}=${encodeURIComponent(v.join(","))}`);
    } else parts.push(`${encodeURIComponent(k)}=${encodeURIComponent(String(v))}`);
  }
  return parts.length ? `?${parts.join("&")}` : "";
}

/** Fields the browse screens need on every item. */
export const LIST_FIELDS = ["PrimaryImageAspectRatio", "Overview", "Genres", "ProductionYear", "ChildCount", "RecursiveItemCount", "MediaSourceCount", "Tags", "Studios", "OriginalTitle"];
export const DETAIL_FIELDS = [
  ...LIST_FIELDS, "People", "MediaSources", "MediaStreams", "Chapters", "Trickplay", "ProviderIds", "ExternalUrls", "Taglines",
  "RemoteTrailers", "LocalTrailerCount", "SpecialFeatureCount", "CanDelete", "CanDownload", "Path", "DateCreated", "CustomRating",
  "ProductionLocations", "SortName", "LockedFields", "SeasonUserData", "CumulativeRunTimeTicks", "ItemCounts", "Width", "Height", "IsHD",
];

export function normalizeServerUrl(input: string): string {
  let s = input.trim();
  if (!s) return s;
  if (!/^https?:\/\//i.test(s)) s = `http://${s}`;
  s = s.replace(/\/+$/, "");
  // The web client's address works as a server address.
  s = s.replace(/\/web(\/index\.html)?(#.*)?$/i, "");
  return s;
}

export class Jellyfin {
  server: string;
  deviceId: string;
  deviceName: string;
  token: string | null;
  userId: string | null;

  constructor(server: string, deviceId: string, deviceName: string, token: string | null = null, userId: string | null = null) {
    this.server = normalizeServerUrl(server);
    this.deviceId = deviceId;
    this.deviceName = deviceName;
    this.token = token;
    this.userId = userId;
  }

  authHeader(): string {
    const v = (s: string) => `"${encodeURIComponent(s)}"`;
    const parts = [`Client=${v(APP_NAME)}`, `Device=${v(this.deviceName)}`, `DeviceId=${v(this.deviceId)}`, `Version=${v(APP_VERSION)}`];
    if (this.token) parts.push(`Token=${v(this.token)}`);
    return `MediaBrowser ${parts.join(", ")}`;
  }

  url(path: string, q?: Query): string {
    return `${this.server}${path}${queryString(q)}`;
  }

  /** A URL mpv (or an <img>/<a>) opens on its own: the token goes in the query. */
  authedUrl(path: string, q?: Query): string {
    return this.url(path, { ...q, ApiKey: this.token ?? undefined });
  }

  async request<T>(method: string, path: string, opts: { query?: Query; body?: unknown; raw?: boolean; text?: boolean; signal?: AbortSignal; contentType?: string } = {}): Promise<T> {
    const headers: Record<string, string> = { Authorization: this.authHeader(), Accept: "application/json" };
    let body: BodyInit | undefined;
    if (opts.body !== undefined) {
      if (typeof opts.body === "string" && opts.contentType) {
        headers["Content-Type"] = opts.contentType;
        body = opts.body;
      } else {
        headers["Content-Type"] = "application/json";
        body = JSON.stringify(opts.body);
      }
    }
    let res: Response;
    try {
      res = await fetchImpl(this.url(path, opts.query), { method, headers, body, signal: opts.signal });
    } catch (e) {
      if ((e as Error)?.name === "AbortError") throw e;
      throw new ApiError(0, `Can't reach the server (${(e as Error)?.message ?? e}).`);
    }
    if (!res.ok) {
      let detail = "";
      try { detail = (await res.text()).slice(0, 300); } catch { /* none */ }
      const msg = res.status === 401 ? "Your session has expired. Sign in again."
        : res.status === 403 ? "You don't have permission to do that."
        : res.status === 404 ? "Not found on the server."
        : `The server answered ${res.status}${detail ? `: ${detail}` : ""}`;
      throw new ApiError(res.status, msg);
    }
    if (opts.raw) return res as unknown as T;
    if (opts.text) return (await res.text()) as unknown as T;
    if (res.status === 204) return undefined as T;
    const text = await res.text();
    if (!text) return undefined as T;
    try { return JSON.parse(text) as T; } catch { return text as unknown as T; }
  }

  get<T>(path: string, query?: Query, signal?: AbortSignal) { return this.request<T>("GET", path, { query, signal }); }
  post<T>(path: string, body?: unknown, query?: Query) { return this.request<T>("POST", path, { body, query }); }
  del<T>(path: string, query?: Query) { return this.request<T>("DELETE", path, { query }); }

  // MARK: Server & sign in

  publicInfo() { return this.get<PublicSystemInfo>("/System/Info/Public"); }
  systemInfo() { return this.get<SystemInfo>("/System/Info"); }
  publicUsers() { return this.get<User[]>("/Users/Public"); }

  async authenticate(username: string, password: string): Promise<AuthResult> {
    return this.post<AuthResult>("/Users/AuthenticateByName", { Username: username, Pw: password });
  }

  quickConnectEnabled() { return this.get<boolean>("/QuickConnect/Enabled"); }
  quickConnectInitiate() { return this.post<QuickConnectResult>("/QuickConnect/Initiate"); }
  quickConnectState(secret: string) { return this.get<QuickConnectResult>("/QuickConnect/Connect", { secret }); }
  quickConnectAuthenticate(secret: string) { return this.post<AuthResult>("/Users/AuthenticateWithQuickConnect", { Secret: secret }); }
  /** Approves a code shown on another device (signed-in user). */
  quickConnectAuthorize(code: string) { return this.post<boolean>("/QuickConnect/Authorize", undefined, { code, userId: this.userId }); }

  logout() { return this.post<void>("/Sessions/Logout"); }
  me() { return this.get<User>("/Users/Me"); }

  /** Tells the server what this client can do (remote control, media types). */
  reportCapabilities() {
    return this.post<void>("/Sessions/Capabilities/Full", {
      PlayableMediaTypes: ["Video", "Audio", "Photo"],
      SupportedCommands: [
        "MoveUp", "MoveDown", "MoveLeft", "MoveRight", "Select", "Back", "ToggleFullscreen", "GoHome", "GoToSettings", "VolumeUp",
        "VolumeDown", "ToggleMute", "SetVolume", "SetAudioStreamIndex", "SetSubtitleStreamIndex", "DisplayContent", "DisplayMessage",
        "SetPlaybackOrder", "SetRepeatMode", "PlayMediaSource", "PlayTrailers", "Mute", "Unmute",
      ],
      SupportsMediaControl: true,
      SupportsPersistentIdentifier: true,
    });
  }

  // MARK: Browsing

  views() { return this.get<ItemsResult>("/UserViews", { userId: this.userId }); }
  items(q: Query, signal?: AbortSignal) { return this.get<ItemsResult>("/Items", { userId: this.userId, enableTotalRecordCount: true, ...q }, signal); }
  item(id: string) { return this.get<Item>(`/Items/${id}`, { userId: this.userId }); }
  /** One item with every field the details page shows. */
  async itemFull(id: string): Promise<Item> {
    const r = await this.items({ ids: [id], fields: DETAIL_FIELDS, enableUserData: true });
    return r.Items[0] ?? (await this.item(id));
  }
  resume(q: Query = {}) { return this.get<ItemsResult>("/UserItems/Resume", { userId: this.userId, fields: LIST_FIELDS, enableUserData: true, ...q }); }
  nextUp(q: Query = {}) { return this.get<ItemsResult>("/Shows/NextUp", { userId: this.userId, fields: LIST_FIELDS, enableUserData: true, ...q }); }
  latest(parentId: string, limit = 24) { return this.get<Item[]>("/Items/Latest", { userId: this.userId, parentId, limit, fields: LIST_FIELDS, enableUserData: true }); }
  seasons(seriesId: string) { return this.get<ItemsResult>(`/Shows/${seriesId}/Seasons`, { userId: this.userId, fields: LIST_FIELDS, enableUserData: true }); }
  episodes(seriesId: string, q: Query = {}) {
    return this.get<ItemsResult>(`/Shows/${seriesId}/Episodes`, { userId: this.userId, fields: [...LIST_FIELDS, "MediaSources", "Trickplay", "Chapters"], enableUserData: true, ...q });
  }
  similar(id: string, limit = 16) { return this.get<ItemsResult>(`/Items/${id}/Similar`, { userId: this.userId, limit, fields: LIST_FIELDS }); }
  specialFeatures(id: string) { return this.get<Item[]>(`/Items/${id}/SpecialFeatures`, { userId: this.userId }); }
  localTrailers(id: string) { return this.get<Item[]>(`/Items/${id}/LocalTrailers`, { userId: this.userId }); }
  additionalParts(id: string) { return this.get<ItemsResult>(`/Videos/${id}/AdditionalParts`, { userId: this.userId }); }
  intros(id: string) { return this.get<ItemsResult>(`/Items/${id}/Intros`, { userId: this.userId }); }
  themeMedia(id: string) { return this.get<{ ThemeSongsResult?: ItemsResult; ThemeVideosResult?: ItemsResult }>(`/Items/${id}/ThemeMedia`, { userId: this.userId, inheritFromParent: true }); }
  ancestors(id: string) { return this.get<Item[]>(`/Items/${id}/Ancestors`, { userId: this.userId }); }
  genres(q: Query = {}) { return this.get<ItemsResult>("/Genres", { userId: this.userId, ...q }); }
  musicGenres(q: Query = {}) { return this.get<ItemsResult>("/MusicGenres", { userId: this.userId, ...q }); }
  studios(q: Query = {}) { return this.get<ItemsResult>("/Studios", { userId: this.userId, ...q }); }
  persons(q: Query = {}) { return this.get<ItemsResult>("/Persons", { userId: this.userId, ...q }); }
  artists(q: Query = {}) { return this.get<ItemsResult>("/Artists", { userId: this.userId, ...q }); }
  albumArtists(q: Query = {}) { return this.get<ItemsResult>("/Artists/AlbumArtists", { userId: this.userId, ...q }); }
  filters(parentId?: string, includeItemTypes?: string[]) {
    return this.get<{ Genres?: { Name: string; Id: string }[]; Tags?: string[]; OfficialRatings?: string[]; Years?: number[] }>("/Items/Filters2", { userId: this.userId, parentId, includeItemTypes });
  }
  suggestions(q: Query = {}) { return this.get<ItemsResult>("/Items/Suggestions", { userId: this.userId, ...q }); }
  instantMix(id: string, limit = 100) { return this.get<ItemsResult>(`/Items/${id}/InstantMix`, { userId: this.userId, limit, fields: LIST_FIELDS }); }
  lyrics(id: string) { return this.get<Lyrics>(`/Audio/${id}/Lyrics`); }

  // MARK: User data

  setFavorite(id: string, on: boolean) { return on ? this.post<unknown>(`/UserFavoriteItems/${id}`, undefined, { userId: this.userId }) : this.del<unknown>(`/UserFavoriteItems/${id}`, { userId: this.userId }); }
  setPlayed(id: string, on: boolean) { return on ? this.post<unknown>(`/UserPlayedItems/${id}`, undefined, { userId: this.userId }) : this.del<unknown>(`/UserPlayedItems/${id}`, { userId: this.userId }); }
  /** Likes / dislikes (thumbs); null clears. */
  setLikes(id: string, likes: boolean | null) {
    return likes === null ? this.del<unknown>(`/UserItems/${id}/Rating`, { userId: this.userId }) : this.post<unknown>(`/UserItems/${id}/Rating`, undefined, { userId: this.userId, likes });
  }
  updateUserData(id: string, data: Record<string, unknown>) { return this.post<unknown>(`/UserItems/${id}/UserData`, data, { userId: this.userId }); }

  // MARK: Playback

  playbackInfo(id: string, body: Record<string, unknown>) {
    return this.post<PlaybackInfoResponse>(`/Items/${id}/PlaybackInfo`, { UserId: this.userId, ...body }, { userId: this.userId });
  }
  closeLiveStream(liveStreamId: string) { return this.post<void>("/LiveStreams/Close", undefined, { liveStreamId }); }
  segments(id: string) { return this.get<{ Items: MediaSegment[] }>(`/MediaSegments/${id}`); }
  reportStart(body: Record<string, unknown>) { return this.post<void>("/Sessions/Playing", body); }
  reportProgress(body: Record<string, unknown>) { return this.post<void>("/Sessions/Playing/Progress", body); }
  reportStopped(body: Record<string, unknown>) { return this.post<void>("/Sessions/Playing/Stopped", body); }
  pingTranscode(playSessionId: string) { return this.post<void>("/Sessions/Playing/Ping", undefined, { playSessionId }); }
  stopEncoding(playSessionId: string) { return this.del<void>("/Videos/ActiveEncodings", { deviceId: this.deviceId, playSessionId }); }

  /** The file as stored: what mpv plays when it can play anything (no transcoding). */
  staticStreamUrl(id: string, mediaSourceId: string, playSessionId?: string | null, container?: string | null, audio = false) {
    const kind = audio ? "Audio" : "Videos";
    const ext = container ? `.${container.split(",")[0]}` : "";
    return this.authedUrl(`/${kind}/${id}/stream${ext}`, { static: true, mediaSourceId, deviceId: this.deviceId, playSessionId: playSessionId ?? undefined });
  }

  subtitleUrl(id: string, mediaSourceId: string, index: number, format: string) {
    return this.authedUrl(`/Videos/${id}/${mediaSourceId}/Subtitles/${index}/Stream.${format}`);
  }

  trickplayTileUrl(id: string, width: number, index: number, mediaSourceId?: string) {
    return this.authedUrl(`/Videos/${id}/Trickplay/${width}/${index}.jpg`, { mediaSourceId });
  }

  downloadUrl(id: string) { return this.authedUrl(`/Items/${id}/Download`); }

  // MARK: Images

  image(id: string | null | undefined, type: string, opts: { tag?: string | null; maxWidth?: number; maxHeight?: number; index?: number; quality?: number; blur?: number } = {}): string | undefined {
    if (!id) return undefined;
    const path = opts.index !== undefined ? `/Items/${id}/Images/${type}/${opts.index}` : `/Items/${id}/Images/${type}`;
    return this.url(path, { tag: opts.tag ?? undefined, maxWidth: opts.maxWidth, maxHeight: opts.maxHeight, quality: opts.quality ?? 90, blur: opts.blur });
  }

  userImage(userId: string, tag?: string | null, size = 96) {
    return this.url(`/Users/${userId}/Images/Primary`, { tag: tag ?? undefined, maxWidth: size, quality: 90 });
  }

  // MARK: Library & item management

  refreshItem(id: string, opts: { metadata: "None" | "ValidationOnly" | "Default" | "FullRefresh"; images: "None" | "ValidationOnly" | "Default" | "FullRefresh"; replaceMetadata: boolean; replaceImages: boolean; regenerateTrickplay?: boolean }) {
    return this.post<void>(`/Items/${id}/Refresh`, undefined, {
      metadataRefreshMode: opts.metadata, imageRefreshMode: opts.images, replaceAllMetadata: opts.replaceMetadata,
      replaceAllImages: opts.replaceImages, regenerateTrickplay: opts.regenerateTrickplay ?? false,
    });
  }
  deleteItem(id: string) { return this.del<void>(`/Items/${id}`); }
  updateItem(id: string, item: Item) { return this.post<void>(`/Items/${id}`, item); }
  metadataEditorInfo(id: string) { return this.get<Record<string, unknown>>(`/Items/${id}/MetadataEditor`); }

  // MARK: Backups (Jellyfin 10.11+)

  backups() { return this.get<BackupManifest[]>("/Backup"); }
  createBackup(o: BackupOptions) { return this.post<BackupManifest>("/Backup/Create", o); }
  restoreBackup(archiveFileName: string) { return this.post<void>("/Backup/Restore", { ArchiveFileName: archiveFileName }); }

  sessions(activeWithinSeconds = 960) { return this.get<SessionInfo[]>("/Sessions", { activeWithinSeconds }); }
}

/** A stable id for this install, used as the Jellyfin DeviceId. */
export function deviceIdFor(storage: Storage): string {
  try {
    let id = storage.getItem("deviceId");
    if (!id) {
      id = crypto.randomUUID().replace(/-/g, "");
      storage.setItem("deviceId", id);
    }
    return id;
  } catch {
    return "jellyreco-" + Math.random().toString(36).slice(2);
  }
}

/** 64-bit-safe number for a Jellyfin id (the on-device AI keys vectors by number). */
export function numericId(guid: string): number {
  // FNV-1a over the id, folded to 52 bits so it stays an exact JS number.
  let h1 = 0x811c9dc5, h2 = 0x01000193;
  for (let i = 0; i < guid.length; i++) {
    const c = guid.charCodeAt(i);
    h1 = Math.imul(h1 ^ c, 0x01000193) >>> 0;
    h2 = Math.imul(h2 ^ c, 0x5bd1e995) >>> 0;
  }
  return (h1 & 0xfffff) * 0x100000000 + h2;
}

export type { Item };
