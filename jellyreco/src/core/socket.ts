// The server's WebSocket: keeps the session alive, lets other devices control this one (Play,
// Playstate, GeneralCommand), refreshes screens when watch status or the library changes, feeds
// the dashboard live, and runs SyncPlay (watch together).

import type { Jellyfin } from "./api";
import type { PlayerController } from "./player";
import type { Item, SyncPlayGroup } from "./types";
import { secondsToTicks, ticksToSeconds } from "./types";

type Msg = { MessageType: string; Data?: unknown; MessageId?: string };

export interface SocketHooks {
  player: () => PlayerController | null;
  dataChanged: () => void;
  toast: (text: string) => void;
  message: (header: string, text: string) => void;
  goHome: () => void;
}

export class ServerSocket {
  private ws: WebSocket | null = null;
  private keepAlive: ReturnType<typeof setInterval> | null = null;
  private retry = 0;
  private closed = false;
  private dataTimer: ReturnType<typeof setTimeout> | null = null;
  private listeners = new Map<string, Set<(data: unknown) => void>>();
  /** Server clock minus ours (ms), for SyncPlay's scheduled commands. */
  private clockOffset = 0;
  syncGroup: SyncPlayGroup | null = null;
  private syncPlaylist: { ItemId: string; PlaylistItemId: string }[] = [];

  constructor(private api: Jellyfin, private hooks: SocketHooks) {
    this.connect();
    void this.syncClock();
  }

  private connect() {
    if (this.closed) return;
    const base = this.api.server.replace(/^http/i, "ws");
    const url = `${base}/socket?ApiKey=${encodeURIComponent(this.api.token ?? "")}&deviceId=${encodeURIComponent(this.api.deviceId)}`;
    let ws: WebSocket;
    try { ws = new WebSocket(url); } catch { this.scheduleReconnect(); return; }
    this.ws = ws;
    ws.onopen = () => { this.retry = 0; };
    ws.onmessage = (ev) => { try { this.onMessage(JSON.parse(ev.data as string) as Msg); } catch { /* ignore */ } };
    ws.onclose = () => { if (this.keepAlive) clearInterval(this.keepAlive); this.keepAlive = null; this.scheduleReconnect(); };
    ws.onerror = () => ws.close();
  }

  private scheduleReconnect() {
    if (this.closed) return;
    const delay = Math.min(30_000, 1000 * 2 ** this.retry++);
    setTimeout(() => this.connect(), delay);
  }

  send(type: string, data?: unknown) {
    if (this.ws?.readyState === WebSocket.OPEN) this.ws.send(JSON.stringify({ MessageType: type, Data: data }));
  }

  close() {
    this.closed = true;
    if (this.keepAlive) clearInterval(this.keepAlive);
    this.ws?.close();
  }

  on(type: string, fn: (data: unknown) => void): () => void {
    const set = this.listeners.get(type) ?? new Set();
    set.add(fn);
    this.listeners.set(type, set);
    return () => void set.delete(fn);
  }

  private async syncClock() {
    try {
      const t0 = Date.now();
      const r = await this.api.get<{ RequestReceptionTime: string; ResponseTransmissionTime: string }>("/GetUtcTime");
      const t1 = Date.now();
      const server = (Date.parse(r.RequestReceptionTime) + Date.parse(r.ResponseTransmissionTime)) / 2;
      this.clockOffset = server - (t0 + t1) / 2;
    } catch { /* keep 0 */ }
  }

  private dataChangedSoon() {
    if (this.dataTimer) clearTimeout(this.dataTimer);
    this.dataTimer = setTimeout(() => this.hooks.dataChanged(), 1500);
  }

  private onMessage(m: Msg) {
    for (const fn of this.listeners.get(m.MessageType) ?? []) fn(m.Data);
    const p = this.hooks.player();
    switch (m.MessageType) {
      case "ForceKeepAlive": {
        const seconds = Number(m.Data) || 60;
        if (this.keepAlive) clearInterval(this.keepAlive);
        this.keepAlive = setInterval(() => this.send("KeepAlive"), (seconds * 1000) / 2);
        this.send("KeepAlive");
        break;
      }
      case "UserDataChanged":
      case "LibraryChanged":
      case "RefreshProgress":
        if (m.MessageType !== "RefreshProgress") this.dataChangedSoon();
        break;
      case "Play": {
        const d = m.Data as { ItemIds: string[]; StartPositionTicks?: number; PlayCommand: string; StartIndex?: number; MediaSourceId?: string; AudioStreamIndex?: number; SubtitleStreamIndex?: number };
        if (!p || !d.ItemIds?.length) break;
        void this.api.items({ ids: d.ItemIds, fields: ["MediaSources", "Chapters", "Trickplay"] }).then((r) => {
          const ordered = d.ItemIds.map((id) => r.Items.find((i) => i.Id === id)).filter((x): x is Item => !!x);
          if (d.PlayCommand === "PlayNext") return Promise.all(ordered.map((i) => p.enqueue(i, true)));
          if (d.PlayCommand === "PlayLast") return Promise.all(ordered.map((i) => p.enqueue(i)));
          if (d.PlayCommand === "PlayShuffle") return p.playItem(ordered[0], { shuffle: true, queue: ordered });
          if (d.PlayCommand === "PlayInstantMix") return this.api.instantMix(ordered[0].Id).then((x) => p.playNow(x.Items, 0));
          return p.playItem(ordered[d.StartIndex ?? 0], {
            queue: ordered, startIndex: d.StartIndex ?? 0, startSeconds: d.StartPositionTicks ? ticksToSeconds(d.StartPositionTicks) : undefined,
            mediaSourceId: d.MediaSourceId, audioIndex: d.AudioStreamIndex, subtitleIndex: d.SubtitleStreamIndex,
          });
        }).catch(() => {});
        break;
      }
      case "Playstate": {
        const d = m.Data as { Command: string; SeekPositionTicks?: number };
        if (!p?.state.active) break;
        switch (d.Command) {
          case "Stop": void p.close(); break;
          case "Pause": void p.setPaused(true); break;
          case "Unpause": void p.setPaused(false); break;
          case "PlayPause": void p.togglePause(); break;
          case "NextTrack": void p.next(); break;
          case "PreviousTrack": void p.previous(); break;
          case "Seek": if (d.SeekPositionTicks !== undefined) void p.seek(ticksToSeconds(d.SeekPositionTicks)); break;
          case "Rewind": void p.seekBy(-10); break;
          case "FastForward": void p.seekBy(30); break;
        }
        break;
      }
      case "GeneralCommand": {
        const d = m.Data as { Name: string; Arguments?: Record<string, string> };
        const a = d.Arguments ?? {};
        switch (d.Name) {
          case "DisplayMessage": this.hooks.message(a.Header ?? "Message", a.Text ?? ""); break;
          case "SetVolume": if (p) void p.setVolume(Number(a.Volume)); break;
          case "VolumeUp": if (p) void p.setVolume(p.state.volume + 5); break;
          case "VolumeDown": if (p) void p.setVolume(p.state.volume - 5); break;
          case "Mute": if (p && !p.state.muted) void p.toggleMute(); break;
          case "Unmute": if (p?.state.muted) void p.toggleMute(); break;
          case "ToggleMute": if (p) void p.toggleMute(); break;
          case "SetAudioStreamIndex": if (p) { const o = p.state.audioOptions.find((x) => x.jfIndex === Number(a.Index)); if (o) void p.selectAudio(o); } break;
          case "SetSubtitleStreamIndex": if (p) { const o = p.state.subOptions.find((x) => x.jfIndex === Number(a.Index)); if (o) void p.selectSub(o); } break;
          case "SetRepeatMode": if (p) { const want = a.RepeatMode === "RepeatOne" ? "one" : a.RepeatMode === "RepeatAll" ? "all" : "none"; let guard = 0; while (p.state.repeat !== want && guard++ < 3) void p.cycleRepeat(); } break;
          case "GoHome": this.hooks.goHome(); break;
        }
        break;
      }
      case "SyncPlayGroupUpdate": this.onSyncUpdate(m.Data as { Type: string; Data: unknown }); break;
      case "SyncPlayCommand": this.onSyncCommand(m.Data as { Command: string; PositionTicks?: number; When: string; PlaylistItemId?: string }); break;
    }
  }

  // MARK: SyncPlay

  private onSyncUpdate(u: { Type: string; Data: unknown }) {
    const p = this.hooks.player();
    switch (u.Type) {
      case "GroupJoined":
        this.syncGroup = u.Data as SyncPlayGroup;
        this.hooks.toast(`Joined ${this.syncGroup.GroupName}`);
        this.attachPlayer();
        break;
      case "UserJoined": this.hooks.toast(`${u.Data} joined SyncPlay`); break;
      case "UserLeft": this.hooks.toast(`${u.Data} left SyncPlay`); break;
      case "GroupLeft":
      case "NotInGroup":
        this.leftGroup();
        break;
      case "PlayQueue": {
        const d = u.Data as { Playlist: { ItemId: string; PlaylistItemId: string }[]; PlayingItemIndex: number; StartPositionTicks: number; IsPlaying: boolean };
        this.syncPlaylist = d.Playlist;
        const entry = d.Playlist[d.PlayingItemIndex];
        if (!p || !entry) break;
        if (p.state.item?.Id !== entry.ItemId) {
          void this.api.items({ ids: d.Playlist.map((x) => x.ItemId), fields: ["MediaSources", "Chapters", "Trickplay"] }).then((r) => {
            const ordered = d.Playlist.map((x) => r.Items.find((i) => i.Id === x.ItemId)).filter((x): x is Item => !!x);
            return p.playItem(ordered[d.PlayingItemIndex], { queue: ordered, startIndex: d.PlayingItemIndex, startSeconds: ticksToSeconds(d.StartPositionTicks) });
          }).catch(() => {});
        }
        break;
      }
    }
  }

  private onSyncCommand(c: { Command: string; PositionTicks?: number; When: string }) {
    const p = this.hooks.player();
    if (!p?.state.active) return;
    const delay = Math.max(0, Date.parse(c.When) - (Date.now() + this.clockOffset));
    setTimeout(() => {
      const target = c.PositionTicks !== undefined ? ticksToSeconds(c.PositionTicks) : null;
      switch (c.Command) {
        case "Unpause":
          if (target !== null && Math.abs(p.state.position - target) > 0.5) void p.seekLocal(target);
          void p.setPaused(false);
          break;
        case "Pause":
          void p.setPaused(true);
          if (target !== null) void p.seekLocal(target);
          break;
        case "Seek":
          if (target !== null) void p.seekLocal(target).then(() => this.ready(false));
          break;
        case "Stop": void p.close(); break;
      }
    }, delay);
  }

  /** While in a group, your play/pause/seek go to the server, which tells everyone. */
  private attachPlayer() {
    const p = this.hooks.player();
    if (!p) return;
    p.sync = {
      pause: () => this.api.post("/SyncPlay/Pause"),
      unpause: () => this.api.post("/SyncPlay/Unpause"),
      seek: (seconds: number) => this.api.post("/SyncPlay/Seek", { PositionTicks: secondsToTicks(seconds) }),
      buffering: () => this.ready(true),
      ready: () => this.ready(false),
    };
  }

  private ready(buffering: boolean) {
    const p = this.hooks.player();
    if (!p || !this.syncGroup) return;
    const entry = this.syncPlaylist.find((x) => x.ItemId === p.state.item?.Id);
    const body = {
      When: new Date(Date.now() + this.clockOffset).toISOString(), PositionTicks: secondsToTicks(p.state.position), IsPlaying: !p.state.paused,
      PlaylistItemId: entry?.PlaylistItemId ?? "00000000-0000-0000-0000-000000000000",
    };
    void this.api.post(buffering ? "/SyncPlay/Buffering" : "/SyncPlay/Ready", body).catch(() => {});
  }

  leftGroup() {
    this.syncGroup = null;
    const p = this.hooks.player();
    if (p) p.sync = null;
  }
}

let socket: ServerSocket | null = null;
export const getSocket = () => socket;
export function startSocket(api: Jellyfin, hooks: SocketHooks) {
  socket?.close();
  socket = new ServerSocket(api, hooks);
  return socket;
}
export function stopSocket() {
  socket?.close();
  socket = null;
}
