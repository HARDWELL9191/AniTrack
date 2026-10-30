// The player: picks what to play, asks Jellyfin for the stream, drives mpv, maps tracks between
// Jellyfin and mpv, reports progress, skips intros/credits (Media Segments), and plays the next
// episode. mpv plays every container/codec FFmpeg knows, so the file is played as stored
// (direct play) unless a lower quality is chosen, which asks the server to transcode.

import { ApiError, type Jellyfin } from "./api";
import { type Engine, type EngineEvent, getEngine } from "./engine";
import type { Settings } from "./settings";
import type { Chapter, Item, MediaSegment, MediaSource, MediaStream, TrickplayInfo } from "./types";
import { secondsToTicks, ticksToSeconds } from "./types";

export interface MpvTrack {
  id: number;
  type: "video" | "audio" | "sub";
  title?: string;
  lang?: string;
  codec?: string;
  external?: boolean;
  "external-filename"?: string;
  default?: boolean;
  forced?: boolean;
  selected?: boolean;
  "ff-index"?: number;
  "src-id"?: number;
  "demux-channel-count"?: number;
  "demux-w"?: number;
  "demux-h"?: number;
  "hearing-impaired"?: boolean;
}

export interface TrackOption {
  key: string; // stable key for the UI
  label: string;
  detail?: string;
  /** mpv's track id (null = off). */
  mpvId: number | null;
  /** Jellyfin MediaStream.Index (reported back to the server). */
  jfIndex: number | null;
  /** External subtitle not loaded into mpv yet. */
  pendingUrl?: string;
  selected: boolean;
}

export type PlayMethod = "DirectPlay" | "DirectStream" | "Transcode";

export interface PlayerState {
  active: boolean;
  item: Item | null;
  queue: Item[];
  index: number;
  loading: boolean;
  error: string | null;
  paused: boolean;
  buffering: boolean;
  bufferingPercent: number;
  position: number; // seconds
  duration: number;
  cachedUntil: number; // seconds of demuxer cache ahead
  volume: number;
  muted: boolean;
  speed: number;
  subDelay: number;
  audioDelay: number;
  subScale: number;
  subPos: number;
  aspect: string; // "-1" auto, "16:9", ...
  videoFit: Settings["videoFit"];
  zoom: number;
  tracks: MpvTrack[];
  audioOptions: TrackOption[];
  subOptions: TrackOption[];
  secondarySid: number | null;
  chapters: Chapter[];
  segments: MediaSegment[];
  activeSegment: MediaSegment | null;
  trickplay: { info: TrickplayInfo; mediaSourceId: string } | null;
  mediaSource: MediaSource | null;
  playMethod: PlayMethod;
  maxBitrate: number;
  playSessionId: string | null;
  upNext: Item | null;
  upNextCountdown: number | null;
  ended: boolean;
  isAudio: boolean;
  hwdec: string;
  videoCodec: string;
  stats: Record<string, string>;
  repeat: "none" | "one" | "all";
  shuffle: boolean;
  abLoop: [number | null, number | null];
}

const OBSERVED = [
  "pause", "time-pos", "duration", "paused-for-cache", "cache-buffering-state", "demuxer-cache-time", "volume", "mute", "speed",
  "track-list", "aid", "sid", "secondary-sid", "sub-delay", "audio-delay", "eof-reached", "hwdec-current", "current-tracks/video/codec",
  "video-params", "idle-active", "seeking", "sub-scale", "sub-pos", "video-aspect-override", "panscan", "video-zoom",
];

const initial = (settings: Settings): PlayerState => ({
  active: false, item: null, queue: [], index: 0, loading: false, error: null, paused: false, buffering: false, bufferingPercent: 0,
  position: 0, duration: 0, cachedUntil: 0, volume: settings.volume, muted: false, speed: settings.defaultSpeed, subDelay: 0, audioDelay: 0,
  subScale: 1, subPos: 100, aspect: "-1", videoFit: settings.videoFit, zoom: 0, tracks: [], audioOptions: [], subOptions: [], secondarySid: null,
  chapters: [], segments: [], activeSegment: null, trickplay: null, mediaSource: null, playMethod: "DirectPlay", maxBitrate: 0,
  playSessionId: null, upNext: null, upNextCountdown: null, ended: false, isAudio: false, hwdec: "", videoCodec: "", stats: {},
  repeat: "none", shuffle: false, abLoop: [null, null],
});

export interface PlayOptions {
  /** Continue where you left off (asks first if the setting says so). */
  resume?: boolean;
  startSeconds?: number;
  mediaSourceId?: string;
  audioIndex?: number;
  subtitleIndex?: number;
  /** Play these items in order, starting at `startIndex`. */
  queue?: Item[];
  startIndex?: number;
  shuffle?: boolean;
}

export class PlayerController {
  state: PlayerState;
  private listeners = new Set<() => void>();
  private engine: Engine = getEngine();
  private started = false;
  private unsub: (() => void) | null = null;
  private progressTimer: ReturnType<typeof setInterval> | null = null;
  private countdownTimer: ReturnType<typeof setInterval> | null = null;
  private skippedSegments = new Set<string>();
  private reportedStart = false;
  private loadToken = 0;
  private pendingStart: { audio?: number; sub?: number } = {};
  private lastAudioLang: string | null = null;
  private lastSubLang: string | null = null;
  private upNextDismissed = false;
  /** Set by the UI: shows "Resume from …?" and resolves true to resume. */
  askResume: ((seconds: number, item: Item) => Promise<boolean | null>) | null = null;
  onClose: (() => void) | null = null;
  /** SyncPlay: while in a group, play/pause/seek go through the server. */
  sync: { pause(): Promise<unknown>; unpause(): Promise<unknown>; seek(s: number): Promise<unknown>; buffering(): void; ready(): void } | null = null;
  onDataChanged: (() => void) | null = null;
  onError: ((msg: string) => void) | null = null;

  private getApi: () => Jellyfin | null;
  private getSettings: () => Settings;
  constructor(getApi: () => Jellyfin | null, getSettings: () => Settings) {
    this.getApi = getApi;
    this.getSettings = getSettings;
    this.state = initial(getSettings());
  }

  subscribe = (fn: () => void) => {
    this.listeners.add(fn);
    return () => void this.listeners.delete(fn);
  };
  version = 0;
  private emit() {
    this.version++;
    for (const fn of this.listeners) fn();
  }
  private patch(p: Partial<PlayerState>) {
    this.state = { ...this.state, ...p };
    this.emit();
  }

  private get api(): Jellyfin {
    const api = this.getApi();
    if (!api) throw new Error("Not signed in.");
    return api;
  }

  // MARK: What to play

  /** Plays any item: folders, series, seasons, albums and playlists play their contents. */
  async playItem(item: Item, opts: PlayOptions = {}) {
    try {
      const { queue, index } = opts.queue ? { queue: opts.queue, index: opts.startIndex ?? 0 } : await this.resolveQueue(item, opts.shuffle);
      if (!queue.length) throw new Error("There's nothing to play here.");
      let q = queue;
      if (opts.shuffle && opts.queue) q = shuffled(queue);
      await this.start(q, index, opts);
    } catch (e) {
      this.fail(e);
    }
  }

  private async resolveQueue(item: Item, shuffle?: boolean): Promise<{ queue: Item[]; index: number }> {
    const api = this.api;
    const fields = ["MediaSources", "Chapters", "Trickplay", "PrimaryImageAspectRatio", "Overview"];
    switch (item.Type) {
      case "Series": {
        if (shuffle) {
          const r = await api.items({ parentId: item.Id, recursive: true, includeItemTypes: ["Episode"], sortBy: ["Random"], limit: 300, fields });
          return { queue: r.Items, index: 0 };
        }
        const all = await api.episodes(item.Id, { limit: 2000 });
        const eps = all.Items.filter((e) => e.LocationType !== "Virtual");
        // Next up: the first episode not watched (resuming a started one first).
        const next = await api.nextUp({ seriesId: item.Id, limit: 1, enableResumable: true, disableFirstEpisode: false }).catch(() => null);
        const target = next?.Items[0]?.Id;
        let index = target ? eps.findIndex((e) => e.Id === target) : -1;
        if (index < 0) index = Math.max(0, eps.findIndex((e) => !e.UserData?.Played));
        return { queue: eps, index };
      }
      case "Season": {
        const r = await api.episodes(item.SeriesId ?? item.ParentId ?? "", { seasonId: item.Id, limit: 2000 });
        const eps = r.Items.filter((e) => e.LocationType !== "Virtual");
        if (shuffle) return { queue: shuffled(eps), index: 0 };
        const index = Math.max(0, eps.findIndex((e) => !e.UserData?.Played));
        return { queue: eps, index };
      }
      case "Episode": {
        // The whole series around it, for next/previous.
        if (item.SeriesId) {
          const r = await api.episodes(item.SeriesId, { limit: 2000 }).catch(() => null);
          const eps = r?.Items.filter((e) => e.LocationType !== "Virtual") ?? [];
          const index = eps.findIndex((e) => e.Id === item.Id);
          if (index >= 0) return { queue: eps, index };
        }
        return { queue: [item], index: 0 };
      }
      case "Playlist": {
        const r = await api.get<{ Items: Item[] }>(`/Playlists/${item.Id}/Items`, { userId: api.userId, fields });
        return { queue: shuffle ? shuffled(r.Items) : r.Items, index: 0 };
      }
      case "MusicAlbum": {
        const r = await api.items({ parentId: item.Id, includeItemTypes: ["Audio"], sortBy: ["ParentIndexNumber", "IndexNumber", "SortName"], fields });
        return { queue: shuffle ? shuffled(r.Items) : r.Items, index: 0 };
      }
      case "MusicArtist": {
        const r = await api.items({ artistIds: [item.Id], recursive: true, includeItemTypes: ["Audio"], sortBy: shuffle ? ["Random"] : ["Album", "ParentIndexNumber", "IndexNumber"], limit: 500, fields });
        return { queue: r.Items, index: 0 };
      }
      case "MusicGenre":
      case "Genre": {
        const r = await api.items({ genreIds: [item.Id], recursive: true, includeItemTypes: ["Audio", "Movie", "Episode"], sortBy: ["Random"], limit: 200, fields });
        return { queue: r.Items, index: 0 };
      }
      case "BoxSet":
      case "Folder":
      case "CollectionFolder":
      case "PhotoAlbum": {
        const r = await api.items({ parentId: item.Id, recursive: true, isFolder: false, mediaTypes: ["Video", "Audio"], sortBy: shuffle ? ["Random"] : ["SortName"], limit: 500, fields });
        return { queue: r.Items, index: 0 };
      }
      default:
        return { queue: [item], index: 0 };
    }
  }

  async playNow(items: Item[], startIndex = 0) {
    await this.start(items, startIndex, {});
  }

  /** Adds to the end of the queue (or plays, if nothing is playing). */
  async enqueue(item: Item, next = false) {
    const { queue } = await this.resolveQueue(item);
    if (!this.state.active) return this.start(queue, 0, {});
    const q = [...this.state.queue];
    if (next) q.splice(this.state.index + 1, 0, ...queue);
    else q.push(...queue);
    this.patch({ queue: q });
  }

  // MARK: Starting

  private async ensureEngine() {
    if (this.started) return;
    const s = this.getSettings();
    await this.engine.start(mpvOptions(s), OBSERVED);
    this.unsub = this.engine.onEvent((e) => this.onEngine(e));
    this.started = true;
  }

  private async start(queue: Item[], index: number, opts: PlayOptions) {
    const prev = this.state;
    if (prev.active && prev.item) await this.reportStop();
    this.patch({
      ...initial(this.getSettings()), active: true, loading: true, queue, index, repeat: prev.repeat, shuffle: prev.shuffle,
      volume: prev.active ? prev.volume : this.getSettings().volume, muted: prev.muted,
    });
    try {
      await this.ensureEngine();
      await this.engine.setVisible(true);
      await this.load(index, opts);
    } catch (e) {
      this.fail(e);
    }
  }

  private async load(index: number, opts: PlayOptions = {}) {
    const token = ++this.loadToken;
    const api = this.api;
    const s = this.getSettings();
    const base = this.state.queue[index];
    if (!base) return;
    this.clearUpNext();
    this.skippedSegments.clear();
    this.reportedStart = false;
    this.upNextDismissed = false;
    // A file opened with the app from this PC: mpv plays it directly, nothing goes to the server.
    if (base.Id.startsWith("local:")) {
      this.patch({ index, item: base, loading: true, error: null, ended: false, position: 0, duration: 0, tracks: [], audioOptions: [], subOptions: [], chapters: [], segments: [], trickplay: null, activeSegment: null, mediaSource: null, playMethod: "DirectPlay", isAudio: false });
      await this.engine.set("start", "none");
      await this.engine.command(["loadfile", base.Path ?? base.Id.slice(6), "replace"]);
      return;
    }
    this.patch({ index, item: base, loading: true, error: null, ended: false, position: 0, duration: ticksToSeconds(base.RunTimeTicks), tracks: [], audioOptions: [], subOptions: [], chapters: [], segments: [], trickplay: null, activeSegment: null, stats: {}, abLoop: [null, null] });

    const item = await api.itemFull(base.Id).catch(() => base);
    if (token !== this.loadToken) return;
    const isAudio = item.MediaType === "Audio" || item.Type === "Audio" || item.Type === "AudioBook";

    // Where to start.
    let start = opts.startSeconds ?? 0;
    const saved = ticksToSeconds(item.UserData?.PlaybackPositionTicks);
    if (opts.startSeconds === undefined && opts.resume && saved > 5) {
      if (s.resumeBehavior === "resume") start = saved;
      else if (s.resumeBehavior === "ask" && this.askResume) {
        const answer = await this.askResume(saved, item);
        if (answer === null) { if (token === this.loadToken) this.close(); return; }
        if (answer) start = saved;
      }
    }
    if (token !== this.loadToken) return;

    // Direct play first (the file as stored, decoded by mpv). Remuxing (direct stream) and then
    // transcoding are fallbacks only, for when the server can't hand over the file as is, or when a
    // lower quality is chosen on purpose.
    const maxBitrate = this.state.maxBitrate || (this.isRemote() ? s.maxBitrateRemote : s.maxBitrateLocal);
    const info = await api.playbackInfo(item.Id, {
      StartTimeTicks: secondsToTicks(start),
      MediaSourceId: opts.mediaSourceId,
      AudioStreamIndex: opts.audioIndex,
      SubtitleStreamIndex: opts.subtitleIndex,
      MaxStreamingBitrate: maxBitrate || undefined,
      EnableDirectPlay: !maxBitrate,
      EnableDirectStream: !maxBitrate,
      EnableTranscoding: true,
      AllowVideoStreamCopy: true,
      AllowAudioStreamCopy: true,
      AutoOpenLiveStream: true,
      DeviceProfile: deviceProfile(maxBitrate),
    });
    if (token !== this.loadToken) return;
    if (info.ErrorCode) throw new Error(info.ErrorCode === "NotAllowed" ? "Your account isn't allowed to play this." : info.ErrorCode === "RateLimitExceeded" ? "The server's streaming limit was reached." : "The server couldn't find a way to stream this.");
    const source = (opts.mediaSourceId && info.MediaSources.find((m) => m.Id === opts.mediaSourceId)) || info.MediaSources[0];
    if (!source) throw new Error("This item has no playable file.");

    let url: string;
    let method: PlayMethod;
    if (source.Protocol === "Http" && source.Path && source.IsRemote && !maxBitrate) {
      method = "DirectPlay";
      url = source.Path; // a remote URL (e.g. .strm) mpv opens itself
    } else if (source.SupportsDirectPlay && !maxBitrate) {
      method = "DirectPlay";
      url = api.staticStreamUrl(item.Id, source.Id ?? item.Id, info.PlaySessionId, source.Container, isAudio);
    } else if (source.SupportsDirectStream && !maxBitrate) {
      method = "DirectStream";
      url = api.staticStreamUrl(item.Id, source.Id ?? item.Id, info.PlaySessionId, source.Container, isAudio);
    } else if (source.TranscodingUrl) {
      method = "Transcode";
      url = api.server + source.TranscodingUrl + (/[?&](ApiKey|api_key)=/.test(source.TranscodingUrl) ? "" : `&ApiKey=${encodeURIComponent(api.token ?? "")}`);
    } else {
      throw new Error("The server offered no way to play this file.");
    }
    if (source.LiveStreamId && method !== "Transcode" && url.includes("/stream")) url += `&LiveStreamId=${encodeURIComponent(source.LiveStreamId)}`;

    const trickplay = pickTrickplay(item, source.Id ?? item.Id);
    this.pendingStart = { audio: opts.audioIndex ?? source.DefaultAudioStreamIndex ?? undefined, sub: opts.subtitleIndex ?? source.DefaultSubtitleStreamIndex ?? undefined };
    this.patch({
      item, mediaSource: source, playMethod: method, playSessionId: info.PlaySessionId ?? null, chapters: item.Chapters ?? [], isAudio,
      trickplay: s.trickplay ? trickplay : null, maxBitrate,
    });

    // Transcoded streams already start at StartTimeTicks; files seek.
    const startAt = method === "Transcode" ? 0 : start;
    await this.engine.set("start", startAt > 0 ? String(startAt) : "none");
    const headers = source.RequiredHttpHeaders ? Object.entries(source.RequiredHttpHeaders).map(([k, v]) => `${k}: ${v}`) : [];
    await this.engine.set("http-header-fields", headers.join(","));
    await this.engine.set("force-media-title", mediaTitle(item));
    await this.engine.command(["loadfile", url, "replace"]);
    this.transcodeOffset = method === "Transcode" ? start : 0;
    if (method !== "DirectPlay") this.onError?.(method === "Transcode" ? "This file is being transcoded by the server (it couldn't be direct played)." : "This file is being remuxed by the server (it couldn't be direct played).");

    // Segments (intro/credits) and next episode, in the background.
    void api.segments(item.Id).then((r) => { if (token === this.loadToken) this.patch({ segments: r.Items ?? [] }); }).catch(() => {});
  }

  /** Transcoded streams start at 0 where the file is at `transcodeOffset`. */
  private transcodeOffset = 0;

  private isRemote(): boolean {
    try {
      const host = new URL(this.api.server).hostname;
      return !(host === "localhost" || /^(127\.|10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|169\.254\.)/.test(host) || host.endsWith(".local") || host.endsWith(".lan") || host.endsWith(".home.arpa"));
    } catch {
      return false;
    }
  }

  // MARK: Engine events

  private onEngine(e: EngineEvent) {
    switch (e.type) {
      case "property": this.onProperty(e.name, e.value); break;
      case "file-loaded": void this.onFileLoaded(); break;
      case "playback-restart": this.patch({ loading: false, buffering: false }); this.sync?.ready(); break;
      case "end-file": void this.onEndFile(e.reason, e.error); break;
      case "shutdown": this.started = false; break;
      default: break;
    }
  }

  private onProperty(name: string, value: string | null) {
    const num = (v: string | null, d = 0) => (v === null || v === "" ? d : Number(v));
    const flag = (v: string | null) => v === "yes" || v === "true";
    switch (name) {
      case "pause": this.patch({ paused: flag(value) }); this.scheduleProgress(); break;
      case "time-pos": {
        const pos = num(value) + this.transcodeOffset;
        this.state = { ...this.state, position: pos };
        this.onTime(pos);
        this.emit();
        break;
      }
      case "duration": if (value !== null) this.patch({ duration: num(value) + this.transcodeOffset }); break;
      case "paused-for-cache": this.patch({ buffering: flag(value) }); if (flag(value)) this.sync?.buffering(); else this.sync?.ready(); break;
      case "cache-buffering-state": this.patch({ bufferingPercent: num(value) }); break;
      case "demuxer-cache-time": this.state = { ...this.state, cachedUntil: num(value) + this.transcodeOffset }; break;
      case "volume": this.patch({ volume: num(value, 100) }); break;
      case "mute": this.patch({ muted: flag(value) }); break;
      case "speed": this.patch({ speed: num(value, 1) }); break;
      case "sub-delay": this.patch({ subDelay: num(value) }); break;
      case "audio-delay": this.patch({ audioDelay: num(value) }); break;
      case "sub-scale": this.patch({ subScale: num(value, 1) }); break;
      case "sub-pos": this.patch({ subPos: num(value, 100) }); break;
      case "video-aspect-override": this.patch({ aspect: value ?? "-1" }); break;
      case "video-zoom": this.patch({ zoom: num(value) }); break;
      case "hwdec-current": this.patch({ hwdec: value ?? "" }); break;
      case "current-tracks/video/codec": this.patch({ videoCodec: value ?? "" }); break;
      case "track-list": {
        let tracks: MpvTrack[] = [];
        try { tracks = value ? JSON.parse(value) : []; } catch { tracks = []; }
        this.state = { ...this.state, tracks };
        this.rebuildTrackOptions();
        break;
      }
      case "aid":
      case "sid": this.rebuildTrackOptions(); break;
      case "secondary-sid": this.patch({ secondarySid: value && value !== "no" ? Number(value) : null }); break;
      case "eof-reached": break;
      default: break;
    }
  }

  private async onFileLoaded() {
    const api = this.getApi();
    const s = this.state;
    if (!s.item) return;
    this.patch({ loading: false, error: null });
    if (s.item.Id.startsWith("local:")) { this.rebuildTrackOptions(); return; }
    if (!api) return;
    await this.applyStartTracks();
    await this.engine.set("volume", String(this.state.volume)).catch(() => {});
    await this.engine.set("speed", String(this.getSettings().defaultSpeed)).catch(() => {});
    this.applyFit(this.state.videoFit);
    if (!this.reportedStart) {
      this.reportedStart = true;
      void api.reportStart(this.progressBody()).catch(() => {});
      this.onDataChanged?.();
    }
    this.scheduleProgress();
    void this.findUpNext();
  }

  /** Default audio/subtitle: the server's pick (from the user's language settings), or what you chose last. */
  private async applyStartTracks() {
    const st = this.state;
    const src = st.mediaSource;
    const settings = this.getSettings();
    const streams = src?.MediaStreams ?? [];
    let audio = this.pendingStart.audio;
    let sub = this.pendingStart.sub;
    if (settings.rememberAudio && this.lastAudioLang) {
      const match = streams.find((x) => x.Type === "Audio" && x.Language === this.lastAudioLang);
      if (match) audio = match.Index;
    } else if (settings.preferredAudioLang) {
      const match = streams.find((x) => x.Type === "Audio" && x.Language === settings.preferredAudioLang);
      if (match) audio = match.Index;
    }
    if (settings.rememberSubs && this.lastSubLang !== null) {
      if (this.lastSubLang === "off") sub = -1;
      else {
        const match = streams.find((x) => x.Type === "Subtitle" && x.Language === this.lastSubLang && !x.IsForced) ?? streams.find((x) => x.Type === "Subtitle" && x.Language === this.lastSubLang);
        if (match) sub = match.Index;
      }
    } else if (settings.preferredSubLang) {
      const match = streams.find((x) => x.Type === "Subtitle" && x.Language === settings.preferredSubLang);
      if (match) sub = match.Index;
    }
    if (st.playMethod !== "Transcode") {
      if (audio !== undefined && audio >= 0) await this.selectAudioByIndex(audio, false);
      if (sub !== undefined) await this.selectSubByIndex(sub, false);
    }
  }

  private async onEndFile(reason: string, error?: string) {
    const st = this.state;
    if (!st.active) return;
    if (reason === "error") {
      this.fail(new Error(error ? `Playback failed: ${error}` : "Playback failed."));
      return;
    }
    if (reason !== "eof") return; // replaced by another file or stopped by us
    await this.reportStop();
    if (st.repeat === "one") return this.load(st.index, { startSeconds: 0 });
    const s = this.getSettings();
    const isEpisode = st.item?.Type === "Episode";
    const hasNext = st.index < st.queue.length - 1;
    if (hasNext && (!isEpisode || s.autoNext !== "off")) return this.load(st.index + 1, { startSeconds: 0 });
    if (!hasNext && st.repeat === "all" && st.queue.length) return this.load(0, { startSeconds: 0 });
    this.patch({ ended: true, paused: true });
    this.close();
  }

  // MARK: Time-based work: segments and up next

  private onTime(pos: number) {
    const st = this.state;
    const s = this.getSettings();
    // A-B loop
    const [a, b] = st.abLoop;
    if (a !== null && b !== null && pos >= b) void this.seek(a);
    // Media segments
    const seg = st.segments.find((x) => pos >= ticksToSeconds(x.StartTicks) && pos < ticksToSeconds(x.EndTicks) - 0.5) ?? null;
    if (seg?.Id !== st.activeSegment?.Id) this.state = { ...this.state, activeSegment: seg };
    if (seg && !this.skippedSegments.has(seg.Id)) {
      const action = s.segmentActions[seg.Type] ?? "none";
      if (action === "skip" || (action === "skipOnce" && !this.skippedSegments.has(`type:${seg.Type}`))) {
        this.skippedSegments.add(seg.Id);
        this.skippedSegments.add(`type:${seg.Type}`);
        void this.skipSegment(seg);
      }
    }
    // Up next: during the credits (Outro segment) or the last seconds.
    if (st.upNext && !this.upNextDismissed && st.upNextCountdown === null && st.item?.Type === "Episode" && s.autoNext !== "off") {
      const outro = st.segments.find((x) => x.Type === "Outro");
      const remaining = st.duration - pos;
      const credits = outro ? pos >= ticksToSeconds(outro.StartTicks) : false;
      if ((s.autoNext === "smart" && (credits || (remaining > 0 && remaining <= Math.max(s.upNextSeconds + 5, 20)))) || (s.autoNext === "always" && remaining > 0 && remaining <= s.upNextSeconds + 1)) {
        this.startCountdown();
      }
    }
  }

  async skipSegment(seg: MediaSegment) {
    const end = ticksToSeconds(seg.EndTicks);
    this.skippedSegments.add(seg.Id);
    // Credits running to the end: go straight to the next episode.
    if (seg.Type === "Outro" && this.state.duration - end < 3 && this.state.upNext) return this.next();
    await this.seek(Math.min(end, this.state.duration - 0.5));
  }

  private async findUpNext() {
    const st = this.state;
    const next = st.queue[st.index + 1] ?? null;
    if (next) { this.patch({ upNext: next }); return; }
    const item = st.item;
    if (item?.Type === "Episode" && item.SeriesId) {
      try {
        const r = await this.api.episodes(item.SeriesId, { adjacentTo: item.Id, limit: 3 });
        const i = r.Items.findIndex((e) => e.Id === item.Id);
        const after = i >= 0 ? r.Items[i + 1] : undefined;
        if (after && after.LocationType !== "Virtual") {
          this.patch({ queue: [...this.state.queue, after], upNext: after });
        }
      } catch { /* no next */ }
    }
  }

  private startCountdown() {
    const s = this.getSettings();
    this.patch({ upNextCountdown: s.upNextSeconds });
    this.countdownTimer = setInterval(() => {
      const c = (this.state.upNextCountdown ?? 0) - 1;
      if (this.state.paused) return;
      if (c <= 0) {
        this.clearUpNext();
        void this.next();
      } else this.patch({ upNextCountdown: c });
    }, 1000);
  }

  private clearUpNext() {
    if (this.countdownTimer) clearInterval(this.countdownTimer);
    this.countdownTimer = null;
    if (this.state.upNextCountdown !== null) this.patch({ upNextCountdown: null });
  }

  dismissUpNext() {
    this.upNextDismissed = true;
    this.clearUpNext();
  }

  // MARK: Progress reports

  private progressBody(extra: Record<string, unknown> = {}) {
    const st = this.state;
    const api = this.getApi();
    return {
      ItemId: st.item?.Id,
      MediaSourceId: st.mediaSource?.Id,
      PlaySessionId: st.playSessionId,
      PositionTicks: secondsToTicks(st.position),
      IsPaused: st.paused,
      IsMuted: st.muted,
      VolumeLevel: Math.round(Math.min(100, st.volume)),
      PlaybackRate: st.speed,
      AudioStreamIndex: this.currentAudioIndex(),
      SubtitleStreamIndex: this.currentSubIndex(),
      PlayMethod: st.playMethod,
      CanSeek: true,
      LiveStreamId: st.mediaSource?.LiveStreamId ?? undefined,
      RepeatMode: st.repeat === "one" ? "RepeatOne" : st.repeat === "all" ? "RepeatAll" : "RepeatNone",
      PlaybackOrder: st.shuffle ? "Shuffle" : "Default",
      NowPlayingQueue: st.queue.slice(0, 100).map((q) => ({ Id: q.Id, PlaylistItemId: q.PlaylistItemId ?? q.Id })),
      SessionId: undefined,
      ...(api ? {} : {}),
      ...extra,
    };
  }

  private scheduleProgress() {
    if (this.progressTimer) clearInterval(this.progressTimer);
    if (!this.state.active) return;
    this.reportProgress();
    this.progressTimer = setInterval(() => this.reportProgress(), 10_000);
  }

  private reportProgress(event?: string) {
    const api = this.getApi();
    if (!api || !this.state.item || !this.reportedStart || this.state.item.Id.startsWith("local:")) return;
    void api.reportProgress(this.progressBody(event ? { EventName: event } : {})).catch(() => {});
  }

  private async reportStop() {
    const api = this.getApi();
    const st = this.state;
    if (this.progressTimer) clearInterval(this.progressTimer);
    this.progressTimer = null;
    if (!api || !st.item || !this.reportedStart) return;
    this.reportedStart = false;
    try {
      await api.reportStopped({
        ItemId: st.item.Id, MediaSourceId: st.mediaSource?.Id, PlaySessionId: st.playSessionId,
        PositionTicks: secondsToTicks(st.position), LiveStreamId: st.mediaSource?.LiveStreamId ?? undefined,
        NowPlayingQueue: st.queue.slice(0, 100).map((q) => ({ Id: q.Id, PlaylistItemId: q.PlaylistItemId ?? q.Id })),
      });
      if (st.playMethod === "Transcode" && st.playSessionId) await api.stopEncoding(st.playSessionId).catch(() => {});
      if (st.mediaSource?.LiveStreamId) await api.closeLiveStream(st.mediaSource.LiveStreamId).catch(() => {});
    } catch { /* best effort */ }
    this.onDataChanged?.();
  }

  // MARK: Controls

  async togglePause() {
    if (this.sync) { await (this.state.paused ? this.sync.unpause() : this.sync.pause()); return; }
    await this.engine.command(["cycle", "pause"]);
  }
  async setPaused(p: boolean) { await this.engine.set("pause", p ? "yes" : "no"); }

  async seek(seconds: number) {
    if (this.sync) { await this.sync.seek(seconds); return; }
    return this.seekLocal(seconds);
  }

  /** Seeks this player only (SyncPlay commands land here). */
  async seekLocal(seconds: number) {
    const st = this.state;
    const target = Math.max(0, Math.min(seconds, st.duration || seconds));
    if (st.playMethod === "Transcode") {
      // The transcode only covers what the server encoded: seeking far restarts it at the new point.
      const local = target - this.transcodeOffset;
      if (local < 0 || target > st.position + 60) {
        return this.load(st.index, { startSeconds: target, mediaSourceId: st.mediaSource?.Id ?? undefined, audioIndex: this.currentAudioIndex() ?? undefined, subtitleIndex: this.currentSubIndex() ?? undefined });
      }
      await this.engine.command(["seek", String(local), "absolute"]);
    } else await this.engine.command(["seek", String(target), "absolute+exact"]);
    this.state = { ...this.state, position: target };
    if (st.upNextCountdown !== null && st.duration - target > 30) this.clearUpNext();
    this.emit();
    this.reportProgress("TimeUpdate");
  }

  async seekBy(delta: number) {
    if (this.state.playMethod === "Transcode") return this.seek(this.state.position + delta);
    await this.engine.command(["seek", String(delta), "relative+exact"]);
  }

  async frameStep(forward: boolean) { await this.engine.command([forward ? "frame-step" : "frame-back-step"]); }
  async setVolume(v: number) { await this.engine.set("volume", String(Math.max(0, Math.min(v, this.getSettings().volumeBoostMax)))); if (this.state.muted) await this.engine.set("mute", "no"); }
  async toggleMute() { await this.engine.command(["cycle", "mute"]); }
  async setSpeed(v: number) { await this.engine.set("speed", String(v)); }
  async setSubDelay(v: number) { await this.engine.set("sub-delay", v.toFixed(3)); }
  async setAudioDelay(v: number) { await this.engine.set("audio-delay", v.toFixed(3)); }
  async setSubScale(v: number) { await this.engine.set("sub-scale", v.toFixed(2)); }
  async setSubPos(v: number) { await this.engine.set("sub-pos", String(Math.round(v))); }
  async setAspect(v: string) { await this.engine.set("video-aspect-override", v); }
  async setZoom(v: number) { await this.engine.set("video-zoom", v.toFixed(2)); }
  async screenshot(withSubs: boolean) {
    await this.engine.command(["screenshot", withSubs ? "subtitles" : "video"]);
  }
  async cycleRepeat() {
    const order: PlayerState["repeat"][] = ["none", "all", "one"];
    this.patch({ repeat: order[(order.indexOf(this.state.repeat) + 1) % order.length] });
  }
  toggleShuffle() {
    const st = this.state;
    if (!st.shuffle) {
      const rest = shuffled(st.queue.filter((_, i) => i !== st.index));
      this.patch({ shuffle: true, queue: [st.queue[st.index], ...rest], index: 0 });
    } else this.patch({ shuffle: false });
  }
  setAbLoop() {
    const [a, b] = this.state.abLoop;
    const pos = this.state.position;
    if (a === null) this.patch({ abLoop: [pos, null] });
    else if (b === null) this.patch({ abLoop: [a, Math.max(pos, a + 1)] });
    else this.patch({ abLoop: [null, null] });
  }

  applyFit(fit: Settings["videoFit"]) {
    this.patch({ videoFit: fit });
    // contain: letterbox; cover: crop to fill (panscan); stretch: ignore aspect.
    void this.engine.set("panscan", fit === "cover" ? "1.0" : "0.0");
    void this.engine.set("keepaspect", fit === "stretch" ? "no" : "yes");
  }

  async next() {
    const st = this.state;
    this.clearUpNext();
    if (st.index < st.queue.length - 1) {
      await this.reportStop();
      await this.load(st.index + 1, { startSeconds: 0 });
    } else if (st.repeat === "all" && st.queue.length) {
      await this.reportStop();
      await this.load(0, { startSeconds: 0 });
    }
  }

  async previous() {
    const st = this.state;
    if (st.position > 5 || st.index === 0) return this.seek(0);
    await this.reportStop();
    await this.load(st.index - 1, { startSeconds: 0 });
  }

  async jumpTo(index: number) {
    if (index < 0 || index >= this.state.queue.length) return;
    await this.reportStop();
    await this.load(index, { startSeconds: 0 });
  }

  /** Plays another version (e.g. 4K vs 1080p) from the same spot. */
  async switchVersion(mediaSourceId: string) {
    const st = this.state;
    await this.reportStop();
    await this.load(st.index, { startSeconds: st.position, mediaSourceId });
  }

  /** A deliberately lower quality (the server transcodes); 0 goes back to direct play. */
  async setQuality(maxBitrate: number) {
    const st = this.state;
    this.state = { ...this.state, maxBitrate };
    await this.reportStop();
    await this.load(st.index, { startSeconds: st.position, mediaSourceId: st.mediaSource?.Id ?? undefined, audioIndex: this.currentAudioIndex() ?? undefined, subtitleIndex: this.currentSubIndex() ?? undefined });
  }

  // MARK: Tracks

  private streams(type: MediaStream["Type"]): MediaStream[] {
    return (this.state.mediaSource?.MediaStreams ?? []).filter((s) => s.Type === type);
  }

  /** mpv's track for a Jellyfin stream: embedded streams match by container index. */
  private mpvTrackFor(stream: MediaStream, type: MpvTrack["type"]): MpvTrack | undefined {
    const tracks = this.state.tracks.filter((t) => t.type === type);
    if (stream.IsExternal) {
      return tracks.find((t) => t.external && t["external-filename"]?.includes(`/Subtitles/${stream.Index}/`));
    }
    const byIndex = tracks.find((t) => !t.external && t["ff-index"] === stream.Index);
    if (byIndex) return byIndex;
    // Fallback: the n-th embedded stream of this type.
    const embedded = this.streams(stream.Type).filter((s) => !s.IsExternal);
    const n = embedded.findIndex((s) => s.Index === stream.Index);
    return tracks.filter((t) => !t.external)[n];
  }

  private currentAudioIndex(): number | null {
    const sel = this.state.tracks.find((t) => t.type === "audio" && t.selected);
    if (!sel) return this.state.playMethod === "Transcode" ? this.pendingStart.audio ?? null : null;
    const s = this.streams("Audio").find((x) => this.mpvTrackFor(x, "audio")?.id === sel.id);
    return s?.Index ?? null;
  }

  private currentSubIndex(): number | null {
    const sel = this.state.tracks.find((t) => t.type === "sub" && t.selected && t.id !== this.state.secondarySid);
    if (!sel) return -1;
    const s = this.streams("Subtitle").find((x) => this.mpvTrackFor(x, "sub")?.id === sel.id);
    return s?.Index ?? -1;
  }

  private rebuildTrackOptions() {
    const st = this.state;
    const audio: TrackOption[] = [];
    const subs: TrackOption[] = [{ key: "off", label: "Off", mpvId: null, jfIndex: -1, selected: !st.tracks.some((t) => t.type === "sub" && t.selected && t.id !== st.secondarySid) }];
    const usedAudio = new Set<number>();
    const usedSubs = new Set<number>();
    const api = this.getApi();

    if (st.playMethod !== "Transcode") {
      for (const s of this.streams("Audio")) {
        const t = this.mpvTrackFor(s, "audio");
        if (t) usedAudio.add(t.id);
        audio.push({ key: `jf-a-${s.Index}`, label: s.DisplayTitle ?? s.Language ?? `Track ${s.Index}`, detail: s.Title && s.DisplayTitle?.includes(s.Title) ? undefined : s.Title ?? undefined, mpvId: t?.id ?? null, jfIndex: s.Index, selected: !!t?.selected });
      }
      for (const s of this.streams("Subtitle")) {
        const t = this.mpvTrackFor(s, "sub");
        if (t) usedSubs.add(t.id);
        let pendingUrl: string | undefined;
        if (!t && s.IsExternal && api && st.item && st.mediaSource?.Id) {
          const fmt = externalFormat(s);
          pendingUrl = s.DeliveryUrl && !s.IsExternalUrl ? api.server + s.DeliveryUrl : api.subtitleUrl(st.item.Id, st.mediaSource.Id, s.Index, fmt);
          if (pendingUrl && !pendingUrl.includes("ApiKey=") && !pendingUrl.includes("api_key=")) pendingUrl += `${pendingUrl.includes("?") ? "&" : "?"}ApiKey=${encodeURIComponent(api.token ?? "")}`;
        }
        subs.push({ key: `jf-s-${s.Index}`, label: s.DisplayTitle ?? s.Language ?? `Track ${s.Index}`, detail: [s.IsExternal ? "External" : null, s.Title].filter(Boolean).join(" · ") || undefined, mpvId: t?.id ?? null, jfIndex: s.Index, pendingUrl, selected: !!t?.selected && t.id !== st.secondarySid });
      }
    }
    // Tracks mpv found that Jellyfin didn't list (or a transcode's own tracks).
    for (const t of st.tracks) {
      if (t.type === "audio" && !usedAudio.has(t.id)) audio.push({ key: `mpv-a-${t.id}`, label: [t.title, t.lang, t.codec].filter(Boolean).join(" · ") || `Audio ${t.id}`, mpvId: t.id, jfIndex: null, selected: !!t.selected });
      if (t.type === "sub" && !usedSubs.has(t.id)) subs.push({ key: `mpv-s-${t.id}`, label: [t.title, t.lang, t.codec].filter(Boolean).join(" · ") || `Subtitle ${t.id}`, mpvId: t.id, jfIndex: null, selected: !!t.selected && t.id !== st.secondarySid });
    }
    this.patch({ audioOptions: audio, subOptions: subs });
  }

  async selectAudio(opt: TrackOption) {
    if (this.state.playMethod === "Transcode" && opt.jfIndex !== null) {
      // The transcode carries one audio track: restart it with the other one.
      const st = this.state;
      return this.load(st.index, { startSeconds: st.position, mediaSourceId: st.mediaSource?.Id ?? undefined, audioIndex: opt.jfIndex, subtitleIndex: this.currentSubIndex() ?? undefined });
    }
    if (opt.mpvId !== null) await this.engine.set("aid", String(opt.mpvId));
    const lang = this.streams("Audio").find((s) => s.Index === opt.jfIndex)?.Language;
    if (lang) this.lastAudioLang = lang;
    this.reportProgress("AudioTrackChange");
  }

  async selectSub(opt: TrackOption, secondary = false) {
    const prop = secondary ? "secondary-sid" : "sid";
    if (opt.mpvId === null && !opt.pendingUrl) {
      await this.engine.set(prop, "no");
      if (!secondary) this.lastSubLang = "off";
    } else if (opt.mpvId !== null) {
      await this.engine.set(prop, String(opt.mpvId));
    } else if (opt.pendingUrl) {
      const s = this.streams("Subtitle").find((x) => x.Index === opt.jfIndex);
      await this.engine.command(["sub-add", opt.pendingUrl, secondary ? "auto" : "select", s?.DisplayTitle ?? s?.Title ?? "External", s?.Language ?? ""]);
      if (secondary) {
        const t = await this.engine.get("track-list");
        const list: MpvTrack[] = t ? JSON.parse(t) : [];
        const added = list.filter((x) => x.type === "sub" && x.external).pop();
        if (added) await this.engine.set("secondary-sid", String(added.id));
      }
    }
    if (!secondary && opt.jfIndex !== null && opt.jfIndex >= 0) {
      const lang = this.streams("Subtitle").find((s) => s.Index === opt.jfIndex)?.Language;
      if (lang) this.lastSubLang = lang;
    }
    this.reportProgress("SubtitleTrackChange");
  }

  private async selectAudioByIndex(index: number, report = true) {
    const opt = this.state.audioOptions.find((o) => o.jfIndex === index);
    if (opt) await this.selectAudio(opt);
    else {
      const s = this.streams("Audio").find((x) => x.Index === index);
      const t = s && this.mpvTrackFor(s, "audio");
      if (t) await this.engine.set("aid", String(t.id));
    }
    if (report) this.reportProgress("AudioTrackChange");
  }

  private async selectSubByIndex(index: number, report = true) {
    if (index < 0) { await this.engine.set("sid", "no"); return; }
    this.rebuildTrackOptions();
    const opt = this.state.subOptions.find((o) => o.jfIndex === index);
    if (opt) await this.selectSub(opt);
    if (report) this.reportProgress("SubtitleTrackChange");
  }

  /** Loads a subtitle file from disk (drag & drop or the menu). */
  async addSubtitleFile(path: string) {
    await this.engine.command(["sub-add", path, "select"]);
  }

  // MARK: Stats for nerds

  async refreshStats() {
    const names = [
      "current-tracks/video/codec", "current-tracks/video/decoder-desc", "hwdec-current", "video-params/w", "video-params/h", "video-params/pixelformat", "video-params/colormatrix",
      "video-params/primaries", "video-params/gamma", "video-params/sig-peak", "video-out-params/w", "video-out-params/h",
      "container-fps", "estimated-vf-fps", "display-fps", "video-bitrate", "audio-bitrate", "current-tracks/audio/codec", "current-tracks/audio/decoder-desc", "audio-params/samplerate",
      "audio-params/channel-count", "audio-params/hr-channels", "current-ao", "current-vo", "frame-drop-count", "decoder-frame-drop-count",
      "vo-delayed-frame-count", "demuxer-cache-duration", "cache-speed", "file-format", "file-size", "avsync", "mpv-version", "ffmpeg-version",
    ];
    const out: Record<string, string> = {};
    await Promise.all(names.map(async (n) => {
      const v = await this.engine.get(n).catch(() => null);
      if (v !== null && v !== "") out[n] = v;
    }));
    this.patch({ stats: out });
  }

  // MARK: Ending

  /** Stops playback and leaves the player. */
  async close() {
    const st = this.state;
    if (!st.active) return;
    this.clearUpNext();
    this.loadToken++;
    await this.reportStop();
    await this.engine.command(["stop"]).catch(() => {});
    await this.engine.setVisible(false).catch(() => {});
    this.patch({ ...initial(this.getSettings()), active: false, repeat: st.repeat, volume: st.volume, muted: st.muted });
    this.onClose?.();
    this.onDataChanged?.();
  }

  /** Called when the app quits or the user signs out. */
  async shutdown() {
    await this.close();
    this.unsub?.();
    this.unsub = null;
    if (this.started) await this.engine.destroy().catch(() => {});
    this.started = false;
  }

  /** Settings that apply live (quality scalers, hwdec, subtitle style...). */
  async applySettings(s: Settings) {
    if (!this.started) return;
    for (const [k, v] of Object.entries(liveOptions(s))) await this.engine.set(k, v).catch(() => {});
  }

  private fail(e: unknown) {
    const msg = e instanceof ApiError ? e.message : e instanceof Error ? e.message : String(e);
    this.patch({ error: msg, loading: false });
    this.onError?.(msg);
  }
}

// MARK: Helpers

function shuffled<T>(a: T[]): T[] {
  const b = [...a];
  for (let i = b.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [b[i], b[j]] = [b[j], b[i]];
  }
  return b;
}

function mediaTitle(i: Item): string {
  if (i.Type === "Episode") return `${i.SeriesName ?? ""} S${i.ParentIndexNumber ?? 0}E${i.IndexNumber ?? 0} ${i.Name ?? ""}`.trim();
  return i.Name ?? "JellyReco";
}

function externalFormat(s: MediaStream): string {
  const c = (s.Codec ?? "").toLowerCase();
  if (c === "subrip" || c === "srt") return "srt";
  if (c === "ass" || c === "ssa") return c;
  if (c === "webvtt" || c === "vtt") return "vtt";
  if (c === "pgssub" || c === "pgs" || c === "sup") return "sup";
  if (c === "dvdsub" || c === "vobsub" || c === "sub") return "sub";
  if (c === "ttml") return "ttml";
  return c || "srt";
}

/** The highest-resolution trickplay set for this version, if the server generated one. */
export function pickTrickplay(item: Item, mediaSourceId: string): { info: TrickplayInfo; mediaSourceId: string } | null {
  const sets = item.Trickplay?.[mediaSourceId] ?? (item.Trickplay ? Object.values(item.Trickplay)[0] : undefined);
  if (!sets) return null;
  const infos = Object.values(sets).sort((a, b) => b.Width - a.Width);
  const info = infos.find((i) => i.Width <= 480) ?? infos[infos.length - 1];
  return info ? { info, mediaSourceId: item.Trickplay?.[mediaSourceId] ? mediaSourceId : Object.keys(item.Trickplay ?? {})[0] } : null;
}

/** Everything direct plays (an empty container/codec list means "anything" in Jellyfin's
 * ContainerHelper) with no bitrate cap (Jellyfin's default is 8 Mbps). The transcoding profiles
 * are only the fallback, or used when a lower quality is chosen. */
export function deviceProfile(maxBitrate = 0) {
  const cap = maxBitrate || 2_000_000_000;
  const subs = ["srt", "subrip", "ass", "ssa", "vtt", "webvtt", "ttml", "smi", "microdvd", "mpl2", "sub", "pgs", "pgssub", "sup", "dvdsub", "vobsub", "dvbsub", "dvb_subtitle", "xsub"];
  return {
    Name: "JellyReco (mpv)",
    MaxStreamingBitrate: cap,
    MaxStaticBitrate: cap,
    MaxStaticMusicBitrate: cap,
    MusicStreamingTranscodingBitrate: 320_000,
    DirectPlayProfiles: [{ Type: "Video" }, { Type: "Audio" }, { Type: "Photo" }],
    TranscodingProfiles: [
      {
        Container: "ts", Type: "Video", Protocol: "hls", Context: "Streaming", VideoCodec: "hevc,h264", AudioCodec: "aac,ac3,eac3,mp3,opus,flac",
        MaxAudioChannels: "8", BreakOnNonKeyFrames: true, MinSegments: 1, SegmentLength: 6, CopyTimestamps: false, EnableSubtitlesInManifest: false,
      },
      { Container: "mp3", Type: "Audio", Protocol: "http", Context: "Streaming", AudioCodec: "mp3", MaxAudioChannels: "2" },
    ],
    ContainerProfiles: [],
    CodecProfiles: [],
    SubtitleProfiles: [...subs.map((f) => ({ Format: f, Method: "Embed" })), ...subs.map((f) => ({ Format: f, Method: "External" }))],
  };
}

/** mpv's start-up options (rendering, decoding, caching, subtitles). */
export function mpvOptions(s: Settings): Record<string, string> {
  return {
    // Not a standalone mpv: no config files, no OSC, no keyboard (the app handles input).
    config: "no",
    "load-scripts": "no",
    osc: "no",
    "input-default-bindings": "no",
    "input-vo-keyboard": "no",
    "input-cursor": "no",
    "cursor-autohide": "no",
    "osd-level": "0",
    "keep-open": "no",
    idle: "yes",
    "force-window": "yes",
    ytdl: "no",
    terminal: "no",
    "msg-level": "all=warn",
    // Network + cache
    cache: "yes",
    "cache-secs": String(s.cacheSeconds),
    "demuxer-max-bytes": "400MiB",
    "demuxer-max-back-bytes": "150MiB",
    "demuxer-readahead-secs": "30",
    "network-timeout": "60",
    "stream-buffer-size": "4MiB",
    "force-seekable": "yes",
    "hr-seek": "yes",
    // Subtitles: embedded fonts (ASS in MKV) are used automatically.
    "embeddedfonts": "yes",
    "sub-auto": "no",
    "sub-fix-timing": "no",
    "screenshot-format": "png",
    "screenshot-template": "JellyReco-%F-%P",
    ...(s.screenshotFolder ? { "screenshot-dir": s.screenshotFolder } : {}),
    ...liveOptions(s),
  };
}

/** Options that can change while playing. */
export function liveOptions(s: Settings): Record<string, string> {
  const st = s.subtitleStyle;
  const hq = s.highQuality;
  const o: Record<string, string> = {
    vo: "gpu-next",
    "gpu-api": "d3d11",
    "gpu-context": "d3d11",
    hwdec: s.hwdec,
    "hwdec-codecs": "all",
    "volume-max": String(s.volumeBoostMax),
    "audio-channels": s.audioChannels === "auto" ? "auto-safe" : s.audioChannels,
    "audio-device": s.audioDevice || "auto",
    "audio-spdif": s.audioPassthrough ? "ac3,dts,eac3,truehd,dts-hd" : "",
    af: s.audioNormalize ? "lavfi=[dynaudnorm=f=250:g=31:p=0.5]" : "",
    scale: hq ? (s.upscaler === "default" ? "spline36" : s.upscaler) : "bilinear",
    dscale: hq ? "mitchell" : "bilinear",
    cscale: hq ? "spline36" : "bilinear",
    deband: s.deband ? "yes" : "no",
    dither: hq ? "fruit" : "no",
    "tone-mapping": s.toneMapping,
    "hdr-compute-peak": s.hdrPeakDetect ? "yes" : "no",
    "target-colorspace-hint": "yes",
    interpolation: s.interpolation ? "yes" : "no",
    "video-sync": s.interpolation ? "display-resample" : "audio",
    "sub-font": st.font,
    "sub-font-size": String(st.fontSize),
    "sub-bold": st.bold ? "yes" : "no",
    "sub-color": st.color,
    "sub-border-color": st.borderColor,
    "sub-border-size": String(st.borderSize),
    "sub-back-color": st.backgroundColor,
    "sub-border-style": st.backgroundColor.endsWith("00") ? "outline-and-shadow" : "background-box",
    "sub-margin-y": String(st.marginY),
    "sub-ass-override": st.assOverride,
  };
  return o;
}
