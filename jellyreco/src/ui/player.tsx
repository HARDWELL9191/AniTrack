// The player UI. The video itself is drawn by mpv behind this (transparent) page; everything here
// floats over it: timeline with trickplay previews, chapters and intro/credits regions, track menus,
// an episodes drawer, skip buttons, up next, stats, and keyboard control.

import { type CSSProperties, type ReactNode, useEffect, useMemo, useRef, useState, useSyncExternalStore } from "react";
import { Select } from "./select";
import type { PlayerController, PlayerState, TrackOption } from "../core/player";
import { BITRATES, SPEEDS } from "../core/settings";
import type { Item, MediaSegment } from "../core/types";
import { ticksToSeconds } from "../core/types";
import { cardImage, Cover, logoUrl, Range, Segmented } from "./components";
import { audioBadge, bitrate, bytes, clock, episodeCode, languageName, runtime, videoBadges } from "./fmt";
import { Icon } from "./icons";
import { routeFor, ui, useModel } from "./state";

const EMPTY_SUB = () => () => {};
let windowApi: typeof import("@tauri-apps/api/window") | null = null;
void import("@tauri-apps/api/window").then((m) => (windowApi = m)).catch(() => {});

/** The player's state; the component re-renders on every change. */
export function usePlayer(): PlayerState {
  const model = useModel();
  const p = model.player;
  useSyncExternalStore(p ? p.subscribe : EMPTY_SUB, () => p?.version ?? 0);
  return p?.state ?? ({ active: false, isAudio: false } as PlayerState);
}

const SEGMENT_LABEL: Record<string, string> = { Intro: "Skip intro", Outro: "Skip credits", Recap: "Skip recap", Preview: "Skip preview", Commercial: "Skip ad", Unknown: "Skip" };

type Panel = null | "audio" | "subs" | "episodes" | "chapters" | "queue" | "settings" | "speed" | "help";

export function PlayerOverlay() {
  const model = useModel();
  const st = usePlayer();
  const p = model.player!;
  const [visible, setVisible] = useState(true);
  const [panel, setPanel] = useState<Panel>(null);
  const [anchor, setAnchor] = useState(24);
  const [stats, setStats] = useState(false);
  const [fullscreen, setFullscreen] = useState(false);
  const [pip, setPip] = useState(false);
  const [flash, setFlash] = useState<{ icon: string; text?: string; key: number } | null>(null);
  const hideTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const pipRestore = useRef<{ w: number; h: number; x: number; y: number; maximized: boolean } | null>(null);
  const isVideo = !st.isAudio;

  // Video mode: the page becomes see-through so mpv's picture shows.
  useEffect(() => {
    if (!isVideo) return;
    document.documentElement.classList.add("video-mode");
    return () => document.documentElement.classList.remove("video-mode");
  }, [isVideo]);

  useEffect(() => {
    if (model.settings.startFullscreen) void setFull(true);
    return () => { void setFull(false); };
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

  const poke = () => {
    setVisible(true);
    if (hideTimer.current) clearTimeout(hideTimer.current);
    hideTimer.current = setTimeout(() => { if (!panelRef.current) setVisible(false); }, 3200);
  };
  const panelRef = useRef<Panel>(null);
  panelRef.current = panel;
  useEffect(() => { poke(); return () => { if (hideTimer.current) clearTimeout(hideTimer.current); }; }, []); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => { if (st.paused) setVisible(true); }, [st.paused]);

  const show = (icon: string, text?: string) => setFlash({ icon, text, key: Date.now() });

  async function setFull(on: boolean) {
    try {
      const w = windowApi?.getCurrentWindow();
      if (!w) return;
      await w.setFullscreen(on);
      setFullscreen(on);
    } catch { /* browser preview */ }
  }

  async function togglePip() {
    const w = windowApi?.getCurrentWindow();
    if (!w || !windowApi) return;
    try {
      if (!pip) {
        if (fullscreen) await setFull(false);
        // A maximized window ignores a new size (Windows and Linux): restore it first.
        const maximized = await w.isMaximized().catch(() => false);
        if (maximized) { await w.unmaximize(); await new Promise((r) => setTimeout(r, 120)); }
        const size = await w.outerSize();
        const pos = await w.outerPosition();
        pipRestore.current = { w: size.width, h: size.height, x: pos.x, y: pos.y, maximized };
        const mon = await windowApi.currentMonitor();
        const scale = mon?.scaleFactor ?? 1;
        const width = Math.round(480 * scale), height = Math.round(270 * scale);
        await w.setMinSize(null);
        await w.setDecorations(false);
        await w.setAlwaysOnTop(true);
        await w.setSize(new windowApi.PhysicalSize(width, height));
        if (mon) await w.setPosition(new windowApi.PhysicalPosition(mon.position.x + mon.size.width - width - Math.round(24 * scale), mon.position.y + mon.size.height - height - Math.round(72 * scale)));
        setPip(true);
      } else {
        const r = pipRestore.current;
        await w.setAlwaysOnTop(false);
        await w.setDecorations(true);
        if (r) {
          await w.setSize(new windowApi.PhysicalSize(r.w, r.h));
          await w.setPosition(new windowApi.PhysicalPosition(r.x, r.y));
        }
        await w.setMinSize(new windowApi.LogicalSize(960, 600));
        if (r?.maximized) await w.maximize();
        setPip(false);
      }
    } catch (e) {
      model.fail(e, "Picture in picture");
    }
  }

  const close = async () => {
    if (pip) await togglePip();
    await setFull(false);
    await p.close();
  };

  // Keyboard: the whole player is usable without a mouse. "?" shows the list.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (ui.sheets.length) return;
      const target = e.target as HTMLElement;
      if (target?.tagName === "INPUT" || target?.tagName === "TEXTAREA" || target?.tagName === "SELECT") return;
      const s = model.settings;
      const k = e.key;
      const handled = () => { e.preventDefault(); e.stopPropagation(); poke(); };
      if (k === " " || k === "k" || k === "MediaPlayPause") { handled(); void p.togglePause(); show(st.paused ? "playFill" : "pauseFill"); }
      else if (k === "ArrowRight" && !e.shiftKey) { handled(); void p.seekBy(s.seekShort); show("forward10", `+${s.seekShort}s`); }
      else if (k === "ArrowLeft" && !e.shiftKey) { handled(); void p.seekBy(-s.seekShort); show("rewind10", `−${s.seekShort}s`); }
      else if (k === "l" || (k === "ArrowRight" && e.shiftKey)) { handled(); void p.seekBy(s.seekLong); show("forward10", `+${s.seekLong}s`); }
      else if (k === "j" || (k === "ArrowLeft" && e.shiftKey)) { handled(); void p.seekBy(-s.seekLong); show("rewind10", `−${s.seekLong}s`); }
      else if (k === "ArrowUp") { handled(); void p.setVolume(st.volume + 5); show("speakerFill", `${Math.round(Math.min(st.volume + 5, s.volumeBoostMax))}%`); }
      else if (k === "ArrowDown") { handled(); void p.setVolume(st.volume - 5); show("speakerLowFill", `${Math.round(Math.max(st.volume - 5, 0))}%`); }
      else if (k === "m") { handled(); void p.toggleMute(); show(st.muted ? "speakerFill" : "speakerMuteFill"); }
      else if (k === "f" || k === "F11") { handled(); void setFull(!fullscreen); }
      else if (k === "Escape") {
        handled();
        if (panel) setPanel(null);
        else if (pip) void togglePip();
        else if (fullscreen) void setFull(false);
        else void close();
      }
      else if (k === "n" || k === "MediaTrackNext") { handled(); void p.next(); }
      else if (k === "p" || k === "MediaTrackPrevious") { handled(); void p.previous(); }
      else if (k === "]") { handled(); const v = Math.min(4, Math.round((st.speed + 0.1) * 100) / 100); void p.setSpeed(v); show("gauge", `${v}×`); }
      else if (k === "[") { handled(); const v = Math.max(0.1, Math.round((st.speed - 0.1) * 100) / 100); void p.setSpeed(v); show("gauge", `${v}×`); }
      else if (k === "Backspace") { handled(); void p.setSpeed(1); show("gauge", "1×"); }
      else if (k === "c") { handled(); cycleSubs(p, st); }
      else if (k === "a") { handled(); cycleAudio(p, st); }
      else if (k === "z") { handled(); void p.setSubDelay(st.subDelay - 0.1); show("subtitles", `Subtitle delay ${(st.subDelay - 0.1).toFixed(1)}s`); }
      else if (k === "x") { handled(); void p.setSubDelay(st.subDelay + 0.1); show("subtitles", `Subtitle delay ${(st.subDelay + 0.1).toFixed(1)}s`); }
      else if (k === "s" && !e.ctrlKey) { handled(); void p.screenshot(!e.shiftKey); show("camera", "Screenshot saved"); }
      else if (k === "i") { handled(); setStats((v) => !v); }
      else if (k === ",") { handled(); void p.frameStep(false); }
      else if (k === ".") { handled(); void p.frameStep(true); }
      else if (k === "PageDown") { handled(); jumpChapter(p, st, 1); }
      else if (k === "PageUp") { handled(); jumpChapter(p, st, -1); }
      else if (k === "Enter" && st.activeSegment) { handled(); void p.skipSegment(st.activeSegment); }
      else if (/^[0-9]$/.test(k) && st.duration) { handled(); void p.seek((Number(k) / 10) * st.duration); }
      else if (k === "Home") { handled(); void p.seek(0); }
      else if (k === "End" && st.duration) { handled(); void p.seek(st.duration - 5); }
      else if (k === "?" || k === "h") { handled(); setPanel((x) => (x === "help" ? null : "help")); }
      else if (k === "e") { handled(); setPanel((x) => (x === "episodes" ? null : "episodes")); }
      else if (k === "b") { handled(); p.setAbLoop(); }
      else if (k === "r") { handled(); void p.cycleRepeat(); }
      else if (k === "Tab") { handled(); setVisible((v) => !v); }
    };
    window.addEventListener("keydown", onKey, true);
    return () => window.removeEventListener("keydown", onKey, true);
  });

  // Subtitle files dropped on the window are loaded into the player.
  useEffect(() => {
    let unlisten: (() => void) | undefined;
    void import("@tauri-apps/api/webview").then(async (m) => {
      unlisten = await m.getCurrentWebview().onDragDropEvent((ev) => {
        if (ev.payload.type !== "drop") return;
        for (const path of ev.payload.paths) {
          if (/\.(srt|ass|ssa|vtt|sub|sup|idx|smi|ttml)$/i.test(path)) { void p.addSubtitleFile(path); show("subtitles", "Subtitle added"); }
        }
      });
    }).catch(() => {});
    return () => unlisten?.();
  }, [p]);

  useEffect(() => {
    if (!stats) return;
    void p.refreshStats();
    const t = setInterval(() => void p.refreshStats(), 1000);
    return () => clearInterval(t);
  }, [stats, p]);

  const item = st.item;
  if (!item) return null;
  if (st.isAudio) return null; // audio plays under the app with the mini player

  const segment = st.activeSegment;
  const segAction = segment ? model.settings.segmentActions[segment.Type] : "none";

  const openPanel = (name: Panel, e?: { currentTarget: HTMLElement }) => {
    if (panel === name) { setPanel(null); return; }
    // The menu opens from its button (like Apple's menus), kept inside the window.
    const r = e?.currentTarget.getBoundingClientRect();
    setAnchor(r ? Math.max(16, window.innerWidth - r.right - 8) : 24);
    setPanel(name);
  };
  const isEpisode = item.Type === "Episode";
  const remaining = model.settings.remainingTime;
  const ends = new Date(Date.now() + Math.max(0, st.duration - st.position) * 1000 / Math.max(st.speed, 0.1));
  const logo = isEpisode ? logoUrl(model.api!, item, 500) : undefined;

  return (
    <div className={`player ${visible || panel ? "controls-on" : "controls-off"}`} onMouseMove={poke}
      onDoubleClick={(e) => { if (model.settings.doubleClickFullscreen && (e.target as HTMLElement).classList.contains("player-surface")) void setFull(!fullscreen); }}
      onWheel={(e) => { if (model.settings.wheelVolume && !panel && (e.target as HTMLElement).classList.contains("player-surface")) { void p.setVolume(st.volume + (e.deltaY < 0 ? 5 : -5)); poke(); } }}
      data-tauri-drag-region={pip ? "" : undefined}>
      <div className="player-surface" onClick={() => { if (panel) setPanel(null); else { void p.togglePause(); show(st.paused ? "playFill" : "pauseFill"); } }} />
      {/* Dimming behind the clear glass, only while the controls show (keeps them legible on bright video). */}
      <div className="player-dim" />

      {(st.loading || st.buffering) && !st.error && (
        <div className="player-center"><span className="spinner big" />{st.buffering && st.bufferingPercent > 0 && <span className="tabular">{Math.round(st.bufferingPercent)}%</span>}</div>
      )}
      {st.error && (
        <div className="player-error lg">
          <Icon name="info" size={28} />
          <h3>Can't play this</h3>
          <p>{st.error}</p>
          <div className="row-line"><button className="glass-button" onClick={() => void close()}>Close</button>
            <button className="glass-button prominent" onClick={() => void p.jumpTo(st.index)}>Try again</button></div>
        </div>
      )}
      {flash && <div key={flash.key} className="player-flash lg"><Icon name={flash.icon} size={40} />{flash.text && <span>{flash.text}</span>}</div>}

      {/* Top: close and picture in picture on the left (as in Apple's player), info on the right. */}
      <div className="player-top">
        <div className="pg-group lg">
          <button className="pg-button" onClick={() => void close()} title="Close (Esc)" aria-label="Close"><Icon name="x" size={19} strokeWidth={2.2} /></button>
          <button className="pg-button" onClick={() => void togglePip()} title={pip ? "Back to the full player" : "Picture in picture"} aria-label="Picture in picture"><Icon name="pip" size={19} /></button>
        </div>
        <div className="player-top-right">
          {st.playMethod && st.playMethod !== "DirectPlay" && <span className="pg-chip lg" title="The server is converting this file">{st.playMethod === "Transcode" ? "Transcoding" : "Remuxing"}</span>}
          {st.abLoop[0] !== null && <span className="pg-chip lg" title="A-B loop (B)">{st.abLoop[1] === null ? "Loop A–" : "Loop A–B"}</span>}
          <div className="pg-group lg">
            <button className={`pg-button ${stats ? "on" : ""}`} onClick={() => setStats((v) => !v)} title="Stats for nerds (I)" aria-label="Stats"><Icon name="activity" size={18} /></button>
          </div>
        </div>
      </div>

      {stats && <Stats st={st} />}

      {segment && segAction !== "none" && !st.error && (
        <button className="skip-button lg" onClick={() => void p.skipSegment(segment)}>
          {SEGMENT_LABEL[segment.Type] ?? "Skip"} <Icon name="nextFill" size={14} />
        </button>
      )}
      {st.upNext && st.upNextCountdown !== null && <UpNext p={p} next={st.upNext} countdown={st.upNextCountdown} />}

      {/* Bottom: title, then one floating glass bar with the timeline and every control. */}
      <div className="player-dock">
        <div className="pd-title">
          {logo ? <img className="pd-logo" src={logo} alt={item.SeriesName ?? ""} onError={(e) => { e.currentTarget.style.display = "none"; }} /> : null}
          <div className="pd-title-text">
            {isEpisode && <span className="pd-eyebrow">{item.SeriesName}</span>}
            <strong>{isEpisode ? `${episodeCode(item)}  ${item.Name ?? ""}` : item.Name}</strong>
            {model.settings.showClock && st.duration > 0 && <span className="pd-ends">Ends at {ends.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })}</span>}
          </div>
        </div>
        <div className="pd-bar lg">
          <div className="pd-timeline">
            <span className="pd-time tabular">{clock(st.position)}</span>
            <Timeline st={st} p={p} />
            <button className="pd-time end tabular" onClick={() => model.updateSettings({ remainingTime: !remaining })} title={remaining ? "Show the length" : "Show the time left"}>
              {remaining ? `−${clock(Math.max(0, st.duration - st.position))}` : clock(st.duration)}
            </button>
          </div>
          <div className="pd-controls">
            <div className="pd-left">
              <button className="pd-button" disabled={st.index === 0 && st.position < 5} onClick={() => void p.previous()} title="Previous (P)" aria-label="Previous"><Icon name="prevFill" size={20} /></button>
              <button className="pd-button" onClick={() => void p.seekBy(-model.settings.seekShort)} title={`Back ${model.settings.seekShort} seconds (←)`} aria-label="Back"><Icon name="rewind10" size={24} strokeWidth={1.8} /></button>
              <button className="pd-button play" onClick={() => void p.togglePause()} title={st.paused ? "Play (Space)" : "Pause (Space)"} aria-label={st.paused ? "Play" : "Pause"}><Icon name={st.paused ? "playFill" : "pauseFill"} size={30} /></button>
              <button className="pd-button" onClick={() => void p.seekBy(model.settings.seekShort)} title={`Forward ${model.settings.seekShort} seconds (→)`} aria-label="Forward"><Icon name="forward10" size={24} strokeWidth={1.8} /></button>
              <button className="pd-button" disabled={st.index >= st.queue.length - 1 && !st.upNext} onClick={() => void p.next()} title="Next (N)" aria-label="Next"><Icon name="nextFill" size={20} /></button>
              <Volume st={st} p={p} />
            </div>
            <div className="pd-right">
              {isEpisode && <PanelButton icon="stack" label="Episodes (E)" on={panel === "episodes"} onClick={(e) => openPanel("episodes", e)} />}
              {st.chapters.length > 1 && <PanelButton icon="chapters" label="Chapters" on={panel === "chapters"} onClick={(e) => openPanel("chapters", e)} />}
              {st.queue.length > 1 && !isEpisode && <PanelButton icon="queue" label="Up next" on={panel === "queue"} onClick={(e) => openPanel("queue", e)} />}
              <PanelButton icon="captions" label="Subtitles (C)" on={panel === "subs"} onClick={(e) => openPanel("subs", e)} />
              <PanelButton icon="waveform" label="Audio (A)" on={panel === "audio"} onClick={(e) => openPanel("audio", e)} />
              <button className={`pd-button speed ${panel === "speed" ? "on" : ""}`} onClick={(e) => openPanel("speed", e)} title="Playback speed" aria-label="Playback speed">
                {st.speed === 1 ? <Icon name="gauge" size={21} /> : <span className="tabular">{st.speed}×</span>}
              </button>
              <PanelButton icon="ellipsis" label="More" on={panel === "settings"} onClick={(e) => openPanel("settings", e)} />
              <button className="pd-button" onClick={() => void setFull(!fullscreen)} title={fullscreen ? "Exit full screen (F)" : "Full screen (F)"} aria-label="Full screen"><Icon name={fullscreen ? "shrink" : "expand"} size={20} /></button>
            </div>
          </div>
        </div>
      </div>

      {panel && (
        <aside className={`player-panel lg ${panel === "episodes" || panel === "queue" || panel === "chapters" ? "wide" : ""}`} style={{ right: anchor }} onMouseMove={(e) => e.stopPropagation()}>
          {panel === "audio" && <AudioPanel st={st} p={p} />}
          {panel === "subs" && <SubsPanel st={st} p={p} />}
          {panel === "speed" && <SpeedPanel st={st} p={p} />}
          {panel === "settings" && <SettingsPanel st={st} p={p} onStats={() => setStats((v) => !v)} />}
          {panel === "chapters" && <ChaptersPanel st={st} p={p} close={() => setPanel(null)} />}
          {panel === "episodes" && <EpisodesPanel st={st} p={p} close={() => setPanel(null)} />}
          {panel === "queue" && <QueuePanel st={st} p={p} />}
          {panel === "help" && <HelpPanel />}
        </aside>
      )}
    </div>
  );
}

function PanelButton({ icon, label, on, onClick }: { icon: string; label: string; on: boolean; onClick: (e: { currentTarget: HTMLElement }) => void }) {
  return <button className={`pd-button ${on ? "on" : ""}`} onClick={onClick} title={label} aria-label={label} aria-pressed={on}><Icon name={icon} size={21} /></button>;
}

function cycleSubs(p: PlayerController, st: PlayerState) {
  const opts = st.subOptions;
  if (!opts.length) return;
  const i = opts.findIndex((o) => o.selected);
  void p.selectSub(opts[(i + 1) % opts.length]);
}

function cycleAudio(p: PlayerController, st: PlayerState) {
  const opts = st.audioOptions;
  if (opts.length < 2) return;
  const i = opts.findIndex((o) => o.selected);
  void p.selectAudio(opts[(i + 1) % opts.length]);
}

function jumpChapter(p: PlayerController, st: PlayerState, dir: 1 | -1) {
  const starts = st.chapters.map((c) => ticksToSeconds(c.StartPositionTicks));
  if (!starts.length) return;
  if (dir > 0) {
    const next = starts.find((s) => s > st.position + 1);
    if (next !== undefined) void p.seek(next);
  } else {
    const prev = [...starts].reverse().find((s) => s < st.position - 3);
    void p.seek(prev ?? 0);
  }
}

// MARK: Timeline

function Timeline({ st, p }: { st: PlayerState; p: PlayerController }) {
  const model = useModel();
  const bar = useRef<HTMLDivElement>(null);
  const [hover, setHover] = useState<{ x: number; t: number } | null>(null);
  const [drag, setDrag] = useState<number | null>(null);
  const dur = st.duration || 1;
  const pos = drag ?? st.position;
  const at = (clientX: number) => {
    const r = bar.current!.getBoundingClientRect();
    const f = Math.max(0, Math.min(1, (clientX - r.left) / r.width));
    return { x: f * r.width, t: f * dur, f };
  };
  const pct = (s: number) => `${Math.max(0, Math.min(100, (s / dur) * 100))}%`;
  const chapterAt = (t: number) => [...st.chapters].reverse().find((c) => ticksToSeconds(c.StartPositionTicks) <= t);

  return (
    <div className={`timeline ${drag !== null ? "dragging" : ""}`} ref={bar}
      onMouseMove={(e) => { const a = at(e.clientX); setHover({ x: a.x, t: a.t }); if (drag !== null) setDrag(a.t); }}
      onMouseLeave={() => { setHover(null); }}
      onMouseDown={(e) => {
        const a = at(e.clientX);
        setDrag(a.t);
        const move = (ev: MouseEvent) => setDrag(at(ev.clientX).t);
        const up = (ev: MouseEvent) => {
          window.removeEventListener("mousemove", move);
          window.removeEventListener("mouseup", up);
          void p.seek(at(ev.clientX).t);
          setDrag(null);
        };
        window.addEventListener("mousemove", move);
        window.addEventListener("mouseup", up);
      }}>
      <div className="tl-track">
        <div className="tl-buffer" style={{ width: pct(Math.max(st.cachedUntil, st.position)) }} />
        {st.segments.map((s: MediaSegment) => s.Type !== "Unknown" && (
          <div key={s.Id} className={`tl-segment seg-${s.Type.toLowerCase()}`} style={{ left: pct(ticksToSeconds(s.StartTicks)), width: `calc(${pct(ticksToSeconds(s.EndTicks))} - ${pct(ticksToSeconds(s.StartTicks))})` }} title={s.Type} />
        ))}
        <div className="tl-played" style={{ width: pct(pos) }} />
        {st.abLoop[0] !== null && <div className="tl-ab" style={{ left: pct(st.abLoop[0]), width: st.abLoop[1] !== null ? `calc(${pct(st.abLoop[1])} - ${pct(st.abLoop[0])})` : "2px" }} />}
        {st.chapters.slice(1).map((c, i) => <div key={i} className="tl-chapter" style={{ left: pct(ticksToSeconds(c.StartPositionTicks)) }} />)}
        <div className="tl-thumb" style={{ left: pct(pos) }} />
      </div>
      {hover && (
        <div className="tl-preview" style={{ left: hover.x }}>
          {st.trickplay && model.settings.trickplay && <Trickplay st={st} t={hover.t} />}
          <div className="tl-preview-text">
            {chapterAt(hover.t)?.Name && <span>{chapterAt(hover.t)!.Name}</span>}
            <strong className="tabular">{clock(hover.t)}</strong>
          </div>
        </div>
      )}
    </div>
  );
}

/** One thumbnail out of Jellyfin's trickplay tile sheets. */
function Trickplay({ st, t }: { st: PlayerState; t: number }) {
  const model = useModel();
  const tp = st.trickplay!;
  const info = tp.info;
  const index = Math.min(info.ThumbnailCount - 1, Math.floor((t * 1000) / info.Interval));
  const perSheet = info.TileWidth * info.TileHeight;
  const sheet = Math.floor(index / perSheet);
  const within = index % perSheet;
  const col = within % info.TileWidth;
  const row = Math.floor(within / info.TileWidth);
  const scale = 240 / info.Width;
  const style: CSSProperties = {
    width: info.Width * scale,
    height: info.Height * scale,
    backgroundImage: `url("${model.api!.trickplayTileUrl(st.item!.Id, info.Width, sheet, tp.mediaSourceId)}")`,
    backgroundSize: `${info.TileWidth * info.Width * scale}px ${info.TileHeight * info.Height * scale}px`,
    backgroundPosition: `-${col * info.Width * scale}px -${row * info.Height * scale}px`,
  };
  return <div className="trickplay" style={style} />;
}

function Volume({ st, p }: { st: PlayerState; p: PlayerController }) {
  const model = useModel();
  const max = model.settings.volumeBoostMax;
  const v = st.muted ? 0 : st.volume;
  // Up to 100% fills the track; a boost above 100% (if allowed in Settings) shows past a tick.
  return (
    <div className="pd-volume" title={`Volume ${Math.round(v)}%`}>
      <button className="pd-button" onClick={() => void p.toggleMute()} title="Mute (M)" aria-label={st.muted ? "Unmute" : "Mute"}>
        <Icon name={st.muted || st.volume === 0 ? "speakerMuteFill" : st.volume < 50 ? "speakerLowFill" : "speakerFill"} size={21} />
      </button>
      <Range min={0} max={max} step={1} value={v} onChange={(e) => void p.setVolume(Number(e.target.value))}
        aria-label="Volume" />
    </div>
  );
}

// MARK: Up next

function UpNext({ p, next, countdown }: { p: PlayerController; next: Item; countdown: number }) {
  const model = useModel();
  return (
    <div className="up-next lg">
      <Cover url={cardImage(model.api!, next, "landscape", 240)} width={200} height={112} radius={10} icon="tv" />
      <div className="up-next-text">
        <small>Up next in {countdown}s</small>
        <strong>{next.Type === "Episode" ? `${episodeCode(next)} · ${next.Name}` : next.Name}</strong>
        <span className="muted small clamp-3">{next.Overview}</span>
        <div className="row-line">
          <button className="glass-button prominent" onClick={() => void p.next()}><Icon name="playFill" size={14} /> Play now</button>
          <button className="glass-button" onClick={() => p.dismissUpNext()}>Hide</button>
        </div>
      </div>
    </div>
  );
}

// MARK: Panels

function TrackList({ options, onPick, empty }: { options: TrackOption[]; onPick: (o: TrackOption) => void; empty: string }) {
  if (!options.length) return <p className="muted small">{empty}</p>;
  return (
    <div className="track-list">
      {options.map((o) => (
        <button key={o.key} className={`track ${o.selected ? "on" : ""}`} onClick={() => onPick(o)}>
          <span className="track-check">{o.selected && <Icon name="check" size={16} />}</span>
          <span className="track-text"><span>{o.label}</span>{o.detail && <small>{o.detail}</small>}</span>
        </button>
      ))}
    </div>
  );
}

function AudioPanel({ st, p }: { st: PlayerState; p: PlayerController }) {
  return (
    <>
      <h3>Audio</h3>
      <TrackList options={st.audioOptions} onPick={(o) => void p.selectAudio(o)} empty="No audio tracks." />
      <Slider label="Audio delay" value={st.audioDelay} min={-5} max={5} step={0.05} format={(v) => `${v.toFixed(2)}s`} onChange={(v) => void p.setAudioDelay(v)} reset={0} />
    </>
  );
}

function SubsPanel({ st, p }: { st: PlayerState; p: PlayerController }) {
  const [secondary, setSecondary] = useState(false);
  const pickFile = async () => {
    try {
      const { open } = await import("@tauri-apps/plugin-dialog");
      const path = await open({ multiple: false, filters: [{ name: "Subtitles", extensions: ["srt", "ass", "ssa", "vtt", "sub", "sup", "idx", "smi", "ttml"] }] });
      if (typeof path === "string") await p.addSubtitleFile(path);
    } catch { /* cancelled */ }
  };
  const secondaryOptions = st.subOptions.map((o) => ({ ...o, selected: o.mpvId !== null ? o.mpvId === st.secondarySid : o.key === "off" && st.secondarySid === null }));
  return (
    <>
      <div className="panel-head-row">
        <h3>Subtitles</h3>
        <Segmented value={secondary ? "2" : "1"} options={[{ value: "1", label: "Main" }, { value: "2", label: "Second" }]} onChange={(v) => setSecondary(v === "2")} />
      </div>
      {secondary && <p className="muted small">A second subtitle shown at the top, e.g. to learn a language.</p>}
      <TrackList options={secondary ? secondaryOptions : st.subOptions} onPick={(o) => void p.selectSub(o, secondary)} empty="No subtitles." />
      <button className="glass-button wide" onClick={() => void pickFile()}><Icon name="plus" size={15} /> Load a subtitle file…</button>
      <p className="muted small">Or drop a subtitle file onto the window.</p>
      <Slider label="Delay" value={st.subDelay} min={-10} max={10} step={0.1} format={(v) => `${v.toFixed(1)}s`} onChange={(v) => void p.setSubDelay(v)} reset={0} />
      <Slider label="Size" value={st.subScale} min={0.5} max={2.5} step={0.05} format={(v) => `${Math.round(v * 100)}%`} onChange={(v) => void p.setSubScale(v)} reset={1} />
      <Slider label="Position" value={st.subPos} min={50} max={110} step={1} format={(v) => `${Math.round(v)}`} onChange={(v) => void p.setSubPos(v)} reset={100} />
    </>
  );
}

function SpeedPanel({ st, p }: { st: PlayerState; p: PlayerController }) {
  return (
    <>
      <h3>Playback speed</h3>
      <div className="speed-grid">
        {SPEEDS.map((s) => <button key={s} className={`glass-button ${Math.abs(st.speed - s) < 0.001 ? "prominent" : ""}`} onClick={() => void p.setSpeed(s)}>{s}×</button>)}
      </div>
      <Slider label="Custom" value={st.speed} min={0.1} max={4} step={0.05} format={(v) => `${v.toFixed(2)}×`} onChange={(v) => void p.setSpeed(v)} reset={1} />
      <p className="muted small">[ and ] change speed, Backspace resets it. Pitch is kept.</p>
    </>
  );
}

function SettingsPanel({ st, p, onStats }: { st: PlayerState; p: PlayerController; onStats: () => void }) {
  const model = useModel();
  const s = model.settings;
  const versions = st.item?.MediaSources ?? [];
  return (
    <>
      <h3>Playback</h3>
      {versions.length > 1 && (
        <div className="form-row column">
          <span className="label">Version</span>
          <div className="segmented left">{versions.map((v) => <button key={v.Id} className={v.Id === st.mediaSource?.Id ? "on" : ""} onClick={() => void p.switchVersion(v.Id!)}>{v.Name ?? v.Container}</button>)}</div>
        </div>
      )}
      <div className="form-row column">
        <span className="label">Quality</span>
        <Select value={st.maxBitrate} onChange={(e) => void p.setQuality(Number(e.target.value))}>
          {BITRATES.map((b) => <option key={b.value} value={b.value}>{b.label}</option>)}
        </Select>
        <small className="muted">Anything below Original asks the server to transcode.</small>
      </div>
      <div className="form-row column">
        <span className="label">Picture</span>
        <Segmented value={st.videoFit} options={[{ value: "contain", label: "Fit" }, { value: "cover", label: "Fill" }, { value: "stretch", label: "Stretch" }]} onChange={(v) => p.applyFit(v)} />
      </div>
      <div className="form-row column">
        <span className="label">Aspect ratio</span>
        <Segmented value={st.aspect} options={[{ value: "-1", label: "Auto" }, { value: "16:9", label: "16:9" }, { value: "4:3", label: "4:3" }, { value: "2.35:1", label: "2.35" }, { value: "21:9", label: "21:9" }]} onChange={(v) => void p.setAspect(v)} />
      </div>
      <Slider label="Zoom" value={st.zoom} min={-1} max={1} step={0.05} format={(v) => `${v > 0 ? "+" : ""}${v.toFixed(2)}`} onChange={(v) => void p.setZoom(v)} reset={0} />
      <div className="form-row">
        <span className="label">Repeat</span>
        <Segmented value={st.repeat} options={[{ value: "none", label: "Off" }, { value: "all", label: "All" }, { value: "one", label: "One" }]} onChange={(v) => { while (p.state.repeat !== v) void p.cycleRepeat(); }} />
      </div>
      <div className="form-row column">
        <span className="label">Skip</span>
        {(["Intro", "Recap", "Outro", "Preview", "Commercial"] as const).map((t) => (
          <div key={t} className="toggle-row">
            <span>{t === "Outro" ? "Credits" : t}</span>
            <Select value={s.segmentActions[t]} onChange={(e) => model.updateSettings({ segmentActions: { ...s.segmentActions, [t]: e.target.value as never } })}>
              <option value="ask">Show button</option><option value="skip">Skip automatically</option><option value="skipOnce">Skip once</option><option value="none">Never</option>
            </Select>
          </div>
        ))}
      </div>
      <div className="player-actions">
        <button className="glass-button" onClick={() => void p.screenshot(true)}><Icon name="camera" size={15} /> Screenshot</button>
        <button className="glass-button" onClick={() => p.setAbLoop()}><Icon name="repeat" size={15} /> A-B loop</button>
        <button className="glass-button" onClick={onStats}><Icon name="activity" size={15} /> Stats</button>
        <button className="glass-button" onClick={() => st.item && ui.openSheet({ kind: "mediaInfo", item: st.item })}><Icon name="info" size={15} /> Media info</button>
      </div>
    </>
  );
}

function ChaptersPanel({ st, p, close }: { st: PlayerState; p: PlayerController; close: () => void }) {
  const model = useModel();
  const current = [...st.chapters].reverse().find((c) => ticksToSeconds(c.StartPositionTicks) <= st.position);
  return (
    <>
      <h3>Chapters</h3>
      <div className="chapter-grid">
        {st.chapters.map((c, i) => (
          <button key={i} className={`chapter ${c === current ? "on" : ""}`} onClick={() => { void p.seek(ticksToSeconds(c.StartPositionTicks)); close(); }}>
            <Cover url={c.ImageTag ? model.api!.image(st.item!.Id, "Chapter", { index: i, tag: c.ImageTag, maxWidth: 320 }) : undefined} width="100%" height={96} radius={8} icon="chapters" />
            <span className="chapter-name">{c.Name || `Chapter ${i + 1}`}</span>
            <small className="muted tabular">{clock(ticksToSeconds(c.StartPositionTicks))}</small>
          </button>
        ))}
      </div>
    </>
  );
}

function EpisodesPanel({ st, p, close }: { st: PlayerState; p: PlayerController; close: () => void }) {
  const model = useModel();
  const item = st.item!;
  const [seasonId, setSeasonId] = useState<string | null>(item.SeasonId ?? null);
  const [seasons, setSeasons] = useState<Item[]>([]);
  const [episodes, setEpisodes] = useState<Item[] | null>(null);
  const current = useRef<HTMLButtonElement>(null);
  useEffect(() => {
    if (!item.SeriesId) return;
    void model.api!.seasons(item.SeriesId).then((r) => setSeasons(r.Items)).catch(() => {});
  }, [item.SeriesId, model]);
  const [failed, setFailed] = useState(false);
  const [attempt, setAttempt] = useState(0);
  useEffect(() => {
    const seriesId = item.SeriesId;
    if (!seriesId || !model.api) { setEpisodes([]); return; }
    let alive = true;
    // The queue already has this season's episodes: show them at once, then the server's list.
    const fromQueue = st.queue.filter((q) => q.Type === "Episode" && q.SeriesId === seriesId && (!seasonId || q.SeasonId === seasonId));
    setEpisodes(fromQueue.length ? fromQueue : null);
    setFailed(false);
    model.api.episodes(seriesId, seasonId ? { seasonId } : {})
      .then((r) => { if (alive) setEpisodes(r.Items ?? []); })
      .catch(() => { if (alive) { setFailed(true); setEpisodes((e) => e ?? []); } });
    return () => { alive = false; };
  }, [item.SeriesId, seasonId, model, attempt]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => { current.current?.scrollIntoView({ block: "center" }); }, [episodes]);
  const play = async (e: Item) => {
    const idx = st.queue.findIndex((q) => q.Id === e.Id);
    close();
    if (idx >= 0) await p.jumpTo(idx);
    else await p.playItem(e, { resume: true });
  };
  return (
    <>
      <div className="panel-head-row">
        <h3>{item.SeriesName}</h3>
        {seasons.length > 1 && (
          <Select value={seasonId ?? ""} onChange={(e) => setSeasonId(e.target.value)}>
            {seasons.map((s) => <option key={s.Id} value={s.Id}>{s.Name}</option>)}
          </Select>
        )}
      </div>
      {failed && !episodes?.length ? <div className="panel-note">The episodes didn't load. <button className="link-button" onClick={() => setAttempt((a) => a + 1)}>Try again</button></div>
        : episodes && !episodes.length ? <div className="panel-note">No episodes found.</div>
        : !episodes ? <div className="spinner-wrap"><span className="spinner" /></div> : (
        <div className="episode-drawer">
          {episodes.map((e) => (
            <button key={e.Id} ref={e.Id === item.Id ? current : undefined} className={`episode ${e.Id === item.Id ? "on" : ""}`} onClick={() => void play(e)} disabled={e.LocationType === "Virtual"}>
              <div className="episode-thumb">
                <Cover url={cardImage(model.api!, e, "landscape", 200)} width={170} height={96} radius={8} icon="tv" style={model.settings.blurUnwatched && !e.UserData?.Played ? { filter: "blur(8px)" } : undefined} />
                {e.UserData?.Played && <span className="episode-watched"><Icon name="check" size={12} strokeWidth={3} /></span>}
                {(e.UserData?.PlayedPercentage ?? 0) > 0 && !e.UserData?.Played && <div className="card-progress"><div style={{ width: `${e.UserData!.PlayedPercentage}%` }} /></div>}
                {e.Id === item.Id && <span className="episode-now">Playing</span>}
              </div>
              <div className="episode-text">
                <small>{episodeCode(e)}{e.RunTimeTicks ? ` · ${runtime(e.RunTimeTicks)}` : ""}</small>
                <strong>{e.Name}</strong>
                <p className="clamp-3">{e.Overview}</p>
              </div>
            </button>
          ))}
        </div>
      )}
    </>
  );
}

function QueuePanel({ st, p }: { st: PlayerState; p: PlayerController }) {
  const model = useModel();
  return (
    <>
      <div className="panel-head-row">
        <h3>Queue</h3>
        <button className={`glass-button ${st.shuffle ? "prominent" : ""}`} onClick={() => p.toggleShuffle()}><Icon name="shuffle" size={15} /> Shuffle</button>
      </div>
      <div className="episode-drawer">
        {st.queue.map((q, i) => (
          <button key={`${q.Id}-${i}`} className={`episode ${i === st.index ? "on" : ""}`} onClick={() => void p.jumpTo(i)}>
            <div className="episode-thumb"><Cover url={cardImage(model.api!, q, "landscape", 200)} width={140} height={79} radius={8} /></div>
            <div className="episode-text"><small>{i + 1}</small><strong>{q.Name}</strong><p>{q.SeriesName ?? q.AlbumArtist ?? ""}</p></div>
          </button>
        ))}
      </div>
    </>
  );
}

function HelpPanel() {
  const keys: [string, string][] = [
    ["Space / K", "Play or pause"], ["← / →", "Back / forward (short)"], ["J / L, Shift+← / →", "Back / forward (long)"],
    ["↑ / ↓", "Volume"], ["M", "Mute"], ["F / F11", "Full screen"], ["Esc", "Close panel, leave full screen, stop"],
    ["N / P", "Next / previous"], ["[ / ] / Backspace", "Slower / faster / normal speed"], ["C / A", "Next subtitle / audio track"],
    ["Z / X", "Subtitle delay −/+ 0.1s"], ["Enter", "Skip intro / credits"], ["PgUp / PgDn", "Previous / next chapter"],
    ["0–9", "Jump to 0%–90%"], [", / .", "Frame back / forward"], ["S / Shift+S", "Screenshot with / without subtitles"],
    ["I", "Stats for nerds"], ["E", "Episodes"], ["B", "A-B loop"], ["R", "Repeat"], ["Tab", "Show / hide controls"], ["Double-click", "Full screen"],
    ["Mouse wheel", "Volume"],
  ];
  return (
    <>
      <h3>Keyboard shortcuts</h3>
      <div className="keys">{keys.map(([k, v]) => <div key={k} className="key-row"><kbd>{k}</kbd><span>{v}</span></div>)}</div>
    </>
  );
}

function Slider({ label, value, min, max, step, format, onChange, reset }: { label: string; value: number; min: number; max: number; step: number; format: (v: number) => string; onChange: (v: number) => void; reset?: number }) {
  return (
    <div className="slider-row">
      <div className="slider-head"><span>{label}</span><span className="tabular muted">{format(value)}</span>
        {reset !== undefined && Math.abs(value - reset) > 1e-6 && <button className="link-button small" onClick={() => onChange(reset)}>Reset</button>}</div>
      <Range min={min} max={max} step={step} value={value} onChange={(e) => onChange(Number(e.target.value))} />
    </div>
  );
}

// MARK: Stats for nerds

function Stats({ st }: { st: PlayerState }) {
  const s = st.stats;
  const src = st.mediaSource;
  const video = src?.MediaStreams?.find((m) => m.Type === "Video");
  const audio = src?.MediaStreams?.find((m) => m.Type === "Audio" && m.Index === (st.audioOptions.find((o) => o.selected)?.jfIndex ?? src?.DefaultAudioStreamIndex));
  const num = (v?: string) => (v ? Number(v) : NaN);
  const rows: [string, ReactNode][] = [
    ["Play method", st.playMethod],
    ["Container", `${src?.Container ?? "?"} · ${bytes(src?.Size)} · ${bitrate(src?.Bitrate)}`],
    ["Video", `${s["current-tracks/video/codec"] ?? video?.Codec ?? "?"} · ${s["video-params/w"] ?? "?"}×${s["video-params/h"] ?? "?"} · ${s["video-params/pixelformat"] ?? ""}`],
    ["Decoder", `${s["current-tracks/video/decoder-desc"] ?? "?"} · hw: ${s["hwdec-current"] || "none (software)"}`],
    ["Color", `${s["video-params/primaries"] ?? "?"} / ${s["video-params/gamma"] ?? "?"} / ${s["video-params/colormatrix"] ?? "?"}${s["video-params/sig-peak"] && num(s["video-params/sig-peak"]) > 1 ? ` · peak ${num(s["video-params/sig-peak"]).toFixed(1)}` : ""}`],
    ["HDR", videoBadges(video).filter((b) => /HDR|Dolby|HLG/.test(b)).join(", ") || "SDR"],
    ["Output", `${s["current-vo"] ?? "?"} · ${s["video-out-params/w"] ?? "?"}×${s["video-out-params/h"] ?? "?"}`],
    ["Frame rate", `${num(s["container-fps"]).toFixed(3)} file · ${num(s["estimated-vf-fps"]).toFixed(2)} actual · ${num(s["display-fps"]).toFixed(2)} display`],
    ["Dropped", `${s["frame-drop-count"] ?? 0} output · ${s["decoder-frame-drop-count"] ?? 0} decoder · ${s["vo-delayed-frame-count"] ?? 0} delayed`],
    ["A/V sync", s["avsync"] ? `${(num(s["avsync"]) * 1000).toFixed(1)} ms` : "—"],
    ["Video bitrate", bitrate(num(s["video-bitrate"]))],
    ["Audio", `${s["current-tracks/audio/codec"] ?? audio?.Codec ?? "?"} · ${s["audio-params/hr-channels"] ?? ""} · ${s["audio-params/samplerate"] ?? "?"} Hz · ${bitrate(num(s["audio-bitrate"]))}${audioBadge(audio) ? ` · ${audioBadge(audio)}` : ""}`],
    ["Audio out", s["current-ao"] ?? "?"],
    ["Cache", `${num(s["demuxer-cache-duration"]).toFixed(1)}s ahead · ${bytes(num(s["cache-speed"]))}/s`],
    ["Engine", `${s["mpv-version"] ?? "mpv"} · FFmpeg ${s["ffmpeg-version"] ?? "?"}`],
  ];
  return (
    <div className="stats">
      {rows.map(([k, v]) => <div key={k} className="stats-row"><span>{k}</span><span>{v}</span></div>)}
    </div>
  );
}

// MARK: Audio: mini player

export function MiniPlayer() {
  const model = useModel();
  const st = usePlayer();
  const p = model.player!;
  const item = st.item;
  const [lyricsOpen, setLyricsOpen] = useState(false);
  if (!item) return null;
  return (
    <div className="mini-player lg">
      <button className="mini-cover" onClick={() => ui.push(model.tab, routeFor(item.AlbumId ? { Id: item.AlbumId, Type: "MusicAlbum" } : item))}>
        <Cover url={cardImage(model.api!, item, "square", 64)} width={52} height={52} radius={8} icon="music" />
      </button>
      <div className="mini-text">
        <strong>{item.Name}</strong>
        <span className="muted small">{[item.Artists?.join(", "), item.Album].filter(Boolean).join(" · ")}</span>
      </div>
      <div className="mini-controls">
        <button className="pd-button" onClick={() => p.toggleShuffle()} title="Shuffle"><Icon name="shuffle" size={17} className={st.shuffle ? "accent" : ""} /></button>
        <button className="pd-button" onClick={() => void p.previous()}><Icon name="prevFill" size={19} /></button>
        <button className="pd-button play" onClick={() => void p.togglePause()}><Icon name={st.paused ? "playFill" : "pauseFill"} size={26} /></button>
        <button className="pd-button" onClick={() => void p.next()}><Icon name="nextFill" size={19} /></button>
        <button className="pd-button" onClick={() => void p.cycleRepeat()} title={`Repeat: ${st.repeat}`}><Icon name="repeat" size={17} className={st.repeat !== "none" ? "accent" : ""} /></button>
      </div>
      <div className="mini-time">
        <span className="tabular small">{clock(st.position)}</span>
        <Range min={0} max={st.duration || 1} step={0.5} value={st.position} onChange={(e) => void p.seek(Number(e.target.value))} aria-label="Position" />
        <span className="tabular small">{clock(st.duration)}</span>
      </div>
      <Volume st={st} p={p} />
      {item.Type === "Audio" && <button className="pd-button" onClick={() => setLyricsOpen((v) => !v)} title="Lyrics"><Icon name="book" size={18} /></button>}
      <button className="pd-button" onClick={() => void p.close()} title="Stop"><Icon name="x" size={18} /></button>
      {lyricsOpen && <Lyrics id={item.Id} position={st.position} />}
    </div>
  );
}

function Lyrics({ id, position }: { id: string; position: number }) {
  const model = useModel();
  const [lines, setLines] = useState<{ text: string; start: number | null }[] | null>(null);
  useEffect(() => {
    void model.api!.lyrics(id).then((l) => setLines(l.Lyrics.map((x) => ({ text: x.Text, start: x.Start ? ticksToSeconds(x.Start) : null })))).catch(() => setLines([]));
  }, [id, model]);
  const activeIdx = useMemo(() => (lines ? lines.reduce((acc, l, i) => (l.start !== null && l.start <= position ? i : acc), -1) : -1), [lines, position]);
  return (
    <div className="lyrics panel">
      {!lines ? <span className="spinner" /> : !lines.length ? <p className="muted">No lyrics for this song.</p> : lines.map((l, i) => <p key={i} className={i === activeIdx ? "on" : ""}>{l.text || "♪"}</p>)}
    </div>
  );
}

/** "Resume from 12:34?" when starting something you've watched part of. */
export function ResumePrompt({ seconds, item, answer }: { seconds: number; item: Item; answer: (v: boolean | null) => void }) {
  return (
    <div className="modal-backdrop" onMouseDown={(e) => { if (e.target === e.currentTarget) answer(null); }}>
      <div className="modal resume-modal" role="dialog">
        <div className="modal-body center">
          <h3>{item.Name}</h3>
          <p className="muted">You stopped at {clock(seconds)}{item.RunTimeTicks ? ` of ${clock(ticksToSeconds(item.RunTimeTicks))}` : ""}.</p>
          <div className="row-line">
            <button className="glass-button prominent big" autoFocus onClick={() => answer(true)}><Icon name="playFill" size={16} /> Resume</button>
            <button className="glass-button big" onClick={() => answer(false)}><Icon name="repeat" size={16} /> Start over</button>
          </div>
        </div>
      </div>
    </div>
  );
}

export { languageName };
