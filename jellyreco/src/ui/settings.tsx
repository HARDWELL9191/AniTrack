// Settings: account, display, home, playback (your server-side Jellyfin preferences), the player
// (mpv), subtitles, For You, devices & servers, and about. Everything except a few per-PC options
// is saved to your Jellyfin account, so a new PC picks it up.

import { useEffect, useState } from "react";
import { getEmbedder, type EngineStatus } from "../core/ai";
import { APP_VERSION } from "../core/api";
import { getEngine } from "../core/engine";
import { ALL_HOME_SECTIONS, BITRATES, DEFAULT_SETTINGS, DEFAULT_SUB_STYLE, type HomeSection, type SegmentAction, type Settings } from "../core/settings";
import type { Culture, UserConfiguration } from "../core/types";
import { Range, Cover, Field, Group, PageHeader, Segmented, Toggle, useAction, useLoad } from "./components";
import { Icon } from "./icons";
import { ui, useModel } from "./state";

type Section = "account" | "display" | "home" | "playback" | "player" | "subtitles" | "forYou" | "devices" | "about";
const SECTIONS: { id: Section; label: string; icon: string }[] = [
  { id: "account", label: "Account", icon: "user" },
  { id: "display", label: "Display", icon: "palette" },
  { id: "home", label: "Home", icon: "home" },
  { id: "playback", label: "Playback", icon: "play" },
  { id: "player", label: "Player", icon: "film" },
  { id: "subtitles", label: "Subtitles", icon: "subtitles" },
  { id: "forYou", label: "For You", icon: "wand" },
  { id: "devices", label: "Devices & servers", icon: "devices" },
  { id: "about", label: "About", icon: "info" },
];

export function SettingsPage() {
  const [section, setSection] = useState<Section>("account");
  return (
    <div className="page">
      <PageHeader title="Settings" />
      <div className="settings-layout">
        <nav className="settings-nav">
          {SECTIONS.map((s) => <button key={s.id} className={`nav-item ${s.id === section ? "on" : ""}`} onClick={() => setSection(s.id)}><Icon name={s.icon} size={18} /> {s.label}</button>)}
        </nav>
        <div className="settings-body">
          {section === "account" && <AccountSettings />}
          {section === "display" && <DisplaySettings />}
          {section === "home" && <HomeSettings />}
          {section === "playback" && <PlaybackSettings />}
          {section === "player" && <PlayerSettings />}
          {section === "subtitles" && <SubtitleSettings />}
          {section === "forYou" && <ForYouSettings />}
          {section === "devices" && <DevicesSettings />}
          {section === "about" && <About />}
        </div>
      </div>
    </div>
  );
}

function useSet() {
  const model = useModel();
  return <K extends keyof Settings>(k: K, v: Settings[K]) => model.updateSettings({ [k]: v } as Partial<Settings>);
}

// MARK: Account

function AccountSettings() {
  const model = useModel();
  const api = model.api!;
  const user = model.user!;
  const [current, setCurrent] = useState("");
  const [next, setNext] = useState("");
  const [confirm, setConfirm] = useState("");
  const { busy, run } = useAction();
  const uploadPicture = async () => {
    try {
      const { open } = await import("@tauri-apps/plugin-dialog");
      const path = await open({ filters: [{ name: "Images", extensions: ["jpg", "jpeg", "png", "webp"] }] });
      if (typeof path !== "string") return;
      const { readFile } = await import("./native");
      const b64 = await readFile(path);
      await run(async () => { await api.request("POST", `/Users/${user.Id}/Images/Primary`, { body: b64, contentType: /\.png$/i.test(path) ? "image/png" : "image/jpeg" }); await model.refreshUser(); }, "Picture updated");
    } catch (e) { model.fail(e); }
  };
  return (
    <>
      <Group title="Profile">
        <div className="profile-header">
          <Cover url={user.PrimaryImageTag ? api.userImage(user.Id, user.PrimaryImageTag, 160) : undefined} width={72} height={72} radius={36} icon="user" />
          <div>
            <div className="profile-name">{user.Name}</div>
            <div className="muted small">{model.isAdmin ? "Administrator" : "User"} on {model.server?.name}</div>
          </div>
          <div className="page-head-actions">
            <button className="glass-button" disabled={busy} onClick={() => void uploadPicture()}><Icon name="image" size={15} /> Change picture</button>
            {user.PrimaryImageTag && <button className="glass-button danger" disabled={busy} onClick={() => void run(async () => { await api.del(`/Users/${user.Id}/Images/Primary`); await model.refreshUser(); }, "Picture removed")}>Remove</button>}
          </div>
        </div>
      </Group>
      <Group title="Password">
        <form className="form" onSubmit={async (e) => {
          e.preventDefault();
          if (next !== confirm) return model.toast("The new passwords don't match.", "error");
          if (await run(() => api.post("/Users/Password", { CurrentPw: current, NewPw: next }, { userId: user.Id }), "Password changed")) { setCurrent(""); setNext(""); setConfirm(""); }
        }}>
          {user.HasPassword && <Field label="Current password"><input type="password" value={current} onChange={(e) => setCurrent(e.target.value)} autoComplete="current-password" /></Field>}
          <Field label="New password"><input type="password" value={next} onChange={(e) => setNext(e.target.value)} autoComplete="new-password" /></Field>
          <Field label="Confirm new password"><input type="password" value={confirm} onChange={(e) => setConfirm(e.target.value)} autoComplete="new-password" /></Field>
          <button className="glass-button prominent" disabled={busy || !next}>Change password</button>
        </form>
      </Group>
      <Group title="Sign in other devices">
        <p className="muted small">Approve a device showing a Quick Connect code.</p>
        <button className="glass-button" onClick={() => ui.openSheet({ kind: "quickConnectApprove" })}><Icon name="zap" size={15} /> Quick Connect</button>
      </Group>
      <Group title="Watch together & remote">
        <div className="row-line">
          <button className="glass-button" onClick={() => ui.openSheet({ kind: "syncPlay" })}><Icon name="syncplay" size={15} /> SyncPlay</button>
          <button className="glass-button" onClick={() => ui.openSheet({ kind: "remoteControl" })}><Icon name="remote" size={15} /> Control another device</button>
        </div>
      </Group>
      <Group>
        <button className="glass-button danger" onClick={() => ui.openSheet({ kind: "confirm", title: "Sign out?", text: `You'll need to sign in to ${model.server?.name} again on this PC.`, confirmLabel: "Sign out", danger: true, run: () => model.signOut() })}>
          <Icon name="logout" size={15} /> Sign out
        </button>
      </Group>
    </>
  );
}

// MARK: Display & Home

function DisplaySettings() {
  const model = useModel();
  const set = useSet();
  const s = model.settings;
  return (
    <Group title="Display">
      <div className="toggle-row"><span>Theme</span><Segmented value={s.theme} options={[{ value: "system", label: "Windows" }, { value: "dark", label: "Dark" }, { value: "light", label: "Light" }]} onChange={(v) => set("theme", v)} /></div>
      <Toggle label="Backdrops on details pages" checked={s.showBackdrops} onChange={(v) => set("showBackdrops", v)} />
      <Toggle label="Blur unwatched episode thumbnails" detail="No spoilers in episode stills" checked={s.blurUnwatched} onChange={(v) => set("blurUnwatched", v)} />
      <Toggle label="Show ratings on cards" checked={s.showRatings} onChange={(v) => set("showRatings", v)} />
      <div className="slider-row">
        <div className="slider-head"><span>Poster size</span><span className="muted tabular">{s.libraryCardSize}px</span></div>
        <Range min={120} max={260} step={4} value={s.libraryCardSize} onChange={(e) => set("libraryCardSize", Number(e.target.value))} />
      </div>
    </Group>
  );
}

function HomeSettings() {
  const model = useModel();
  const set = useSet();
  const api = model.api!;
  const sections = model.settings.homeSections;
  const [config, setConfig] = useState<UserConfiguration | null>(model.user?.Configuration ?? null);
  const { run } = useAction();
  const saveConfig = (patch: Partial<UserConfiguration>) => {
    if (!config) return;
    const next = { ...config, ...patch } as UserConfiguration;
    setConfig(next);
    void run(async () => { await api.post("/Users/Configuration", next, { userId: model.user!.Id }); await model.refreshUser(); await model.loadViews(); });
  };
  const move = (i: number, d: number) => {
    const a = [...sections];
    const j = i + d;
    if (j < 0 || j >= a.length) return;
    [a[i], a[j]] = [a[j], a[i]];
    set("homeSections", a);
  };
  const toggle = (id: HomeSection) => set("homeSections", sections.includes(id) ? sections.filter((x) => x !== id) : [...sections, id]);
  const ordered = config?.OrderedViews?.length ? [...model.views].sort((a, b) => (config.OrderedViews!.indexOf(a.Id) + 1 || 999) - (config.OrderedViews!.indexOf(b.Id) + 1 || 999)) : model.views;
  const moveView = (i: number, d: number) => {
    const ids = ordered.map((v) => v.Id);
    const j = i + d;
    if (j < 0 || j >= ids.length) return;
    [ids[i], ids[j]] = [ids[j], ids[i]];
    saveConfig({ OrderedViews: ids });
  };
  return (
    <>
      <Group title="Home sections">
        <p className="muted small">Turn sections on and put them in your order.</p>
        {[...sections, ...ALL_HOME_SECTIONS.map((x) => x.id).filter((id) => !sections.includes(id))].map((id) => {
          const on = sections.includes(id);
          const i = sections.indexOf(id);
          return (
            <div key={id} className="toggle-row">
              <span>{ALL_HOME_SECTIONS.find((x) => x.id === id)?.label}</span>
              <span className="row-line">
                {on && <><button className="round-button" onClick={() => move(i, -1)}><Icon name="arrowUp" size={14} /></button><button className="round-button" onClick={() => move(i, 1)}><Icon name="arrowDown" size={14} /></button></>}
                <input type="checkbox" className="switch" checked={on} onChange={() => toggle(id)} />
              </span>
            </div>
          );
        })}
        <Toggle label="Hide watched items in Latest" checked={model.settings.hideWatchedInLatest} onChange={(v) => set("hideWatchedInLatest", v)} />
      </Group>
      {config && (
        <Group title="Libraries (saved in your Jellyfin account)">
          {ordered.map((v, i) => (
            <div key={v.Id} className="toggle-row">
              <span>{v.Name}</span>
              <span className="row-line">
                <button className="round-button" onClick={() => moveView(i, -1)}><Icon name="arrowUp" size={14} /></button>
                <button className="round-button" onClick={() => moveView(i, 1)}><Icon name="arrowDown" size={14} /></button>
                <label className="mini-check"><input type="checkbox" className="switch sm" checked={!(config.LatestItemsExcludes ?? []).includes(v.Id)} onChange={(e) => saveConfig({ LatestItemsExcludes: e.target.checked ? (config.LatestItemsExcludes ?? []).filter((x) => x !== v.Id) : [...(config.LatestItemsExcludes ?? []), v.Id] })} /> Latest</label>
                <label className="mini-check"><input type="checkbox" className="switch sm" checked={!(config.MyMediaExcludes ?? []).includes(v.Id)} onChange={(e) => saveConfig({ MyMediaExcludes: e.target.checked ? (config.MyMediaExcludes ?? []).filter((x) => x !== v.Id) : [...(config.MyMediaExcludes ?? []), v.Id] })} /> My media</label>
              </span>
            </div>
          ))}
          <Toggle label="Group shared folders" detail="Show folders shared between libraries as one" checked={!!config.GroupedFolders?.length} onChange={() => {}} disabled />
          <Toggle label="Show a Collections library" checked={config.DisplayCollectionsView} onChange={(v) => saveConfig({ DisplayCollectionsView: v })} />
          <Toggle label="Show missing episodes" detail="Episodes you don't have, inside seasons" checked={config.DisplayMissingEpisodes} onChange={(v) => saveConfig({ DisplayMissingEpisodes: v })} />
        </Group>
      )}
    </>
  );
}

// MARK: Playback (server-side user configuration, like jellyfin-web's Playback page)

function PlaybackSettings() {
  const model = useModel();
  const api = model.api!;
  const set = useSet();
  const s = model.settings;
  const { data: cultures } = useLoad(() => api.get<Culture[]>("/Localization/Cultures"), []);
  const [config, setConfig] = useState<UserConfiguration | null>(model.user?.Configuration ?? null);
  const { run } = useAction();
  const save = (patch: Partial<UserConfiguration>) => {
    if (!config) return;
    const next = { ...config, ...patch } as UserConfiguration;
    setConfig(next);
    void run(async () => { await api.post("/Users/Configuration", next, { userId: model.user!.Id }); await model.refreshUser(); });
  };
  const langs = (cultures ?? []).filter((c) => c.ThreeLetterISOLanguageName);
  return (
    <>
      {config && (
        <Group title="Languages (your Jellyfin account)">
          <Field label="Preferred audio language">
            <select value={config.AudioLanguagePreference ?? ""} onChange={(e) => save({ AudioLanguagePreference: e.target.value || null })}>
              <option value="">Any (the file's default)</option>{langs.map((c) => <option key={c.ThreeLetterISOLanguageName} value={c.ThreeLetterISOLanguageName!}>{c.DisplayName}</option>)}
            </select>
          </Field>
          <Toggle label="Play the default audio track whatever its language" checked={config.PlayDefaultAudioTrack} onChange={(v) => save({ PlayDefaultAudioTrack: v })} />
          <Field label="Preferred subtitle language">
            <select value={config.SubtitleLanguagePreference ?? ""} onChange={(e) => save({ SubtitleLanguagePreference: e.target.value || null })}>
              <option value="">Any</option>{langs.map((c) => <option key={c.ThreeLetterISOLanguageName} value={c.ThreeLetterISOLanguageName!}>{c.DisplayName}</option>)}
            </select>
          </Field>
          <Field label="Subtitles" hint="Smart: subtitles on when the audio isn't in your language.">
            <Segmented value={config.SubtitleMode} options={[{ value: "Default", label: "Default" }, { value: "Smart", label: "Smart" }, { value: "OnlyForced", label: "Only forced" }, { value: "Always", label: "Always" }, { value: "None", label: "None" }]} onChange={(v) => save({ SubtitleMode: v })} />
          </Field>
          <Toggle label="Remember my audio choices per show" checked={config.RememberAudioSelections} onChange={(v) => { save({ RememberAudioSelections: v }); set("rememberAudio", v); }} />
          <Toggle label="Remember my subtitle choices per show" checked={config.RememberSubtitleSelections} onChange={(v) => { save({ RememberSubtitleSelections: v }); set("rememberSubs", v); }} />
          <Toggle label="Play the next episode automatically" checked={config.EnableNextEpisodeAutoPlay} onChange={(v) => { save({ EnableNextEpisodeAutoPlay: v }); set("autoNext", v ? "smart" : "off"); }} />
        </Group>
      )}
      <Group title="Next episode & skipping">
        <div className="toggle-row"><span>Up next</span><Segmented value={s.autoNext} options={[{ value: "smart", label: "At the credits" }, { value: "always", label: "At the end" }, { value: "off", label: "Off" }]} onChange={(v) => set("autoNext", v)} /></div>
        <div className="slider-row"><div className="slider-head"><span>Countdown</span><span className="muted tabular">{s.upNextSeconds}s</span></div><Range min={3} max={30} value={s.upNextSeconds} onChange={(e) => set("upNextSeconds", Number(e.target.value))} /></div>
        {(["Intro", "Recap", "Outro", "Preview", "Commercial"] as const).map((t) => (
          <div key={t} className="toggle-row">
            <span>{t === "Outro" ? "Credits" : t === "Commercial" ? "Ads" : t}</span>
            <select value={s.segmentActions[t]} onChange={(e) => set("segmentActions", { ...s.segmentActions, [t]: e.target.value as SegmentAction })}>
              <option value="ask">Show a skip button</option><option value="skip">Skip automatically</option><option value="skipOnce">Skip the first time</option><option value="none">Never</option>
            </select>
          </div>
        ))}
        <p className="muted small">Intro and credits times come from your server's media segments (e.g. the Intro Skipper plugin or chapter names).</p>
      </Group>
      <Group title="Starting">
        <div className="toggle-row"><span>Continue where you left off</span><Segmented value={s.resumeBehavior} options={[{ value: "ask", label: "Ask" }, { value: "resume", label: "Always" }, { value: "start", label: "Start over" }]} onChange={(v) => set("resumeBehavior", v)} /></div>
        <div className="toggle-row"><span>Short seek</span><Segmented value={s.seekShort} options={[5, 10, 15, 30].map((n) => ({ value: n, label: `${n}s` }))} onChange={(v) => set("seekShort", v)} /></div>
        <div className="toggle-row"><span>Long seek</span><Segmented value={s.seekLong} options={[30, 60, 90, 120].map((n) => ({ value: n, label: `${n}s` }))} onChange={(v) => set("seekLong", v)} /></div>
      </Group>
      <Group title="Quality">
        <p className="muted small">Original plays every file as stored (direct play). A lower cap asks the server to transcode and is only for slow connections.</p>
        <Field label="On your home network"><select value={s.maxBitrateLocal} onChange={(e) => set("maxBitrateLocal", Number(e.target.value))}>{BITRATES.map((b) => <option key={b.value} value={b.value}>{b.label}</option>)}</select></Field>
        <Field label="Over the internet"><select value={s.maxBitrateRemote} onChange={(e) => set("maxBitrateRemote", Number(e.target.value))}>{BITRATES.map((b) => <option key={b.value} value={b.value}>{b.label}</option>)}</select></Field>
      </Group>
    </>
  );
}

// MARK: Player (mpv)

function PlayerSettings() {
  const model = useModel();
  const set = useSet();
  const s = model.settings;
  return (
    <>
      <Group title="Picture">
        <div className="toggle-row"><span>Hardware decoding <small className="muted">(this PC)</small></span>
          <select value={s.hwdec} onChange={(e) => set("hwdec", e.target.value as Settings["hwdec"])}>
            <option value="auto-safe">Automatic (recommended)</option><option value="d3d11va">Direct3D 11 (zero-copy)</option><option value="d3d11va-copy">Direct3D 11 (copy)</option><option value="no">Off (software)</option>
          </select></div>
        <Toggle label="High-quality rendering" detail="mpv's gpu-next with sharp scaling and dithering" checked={s.highQuality} onChange={(v) => set("highQuality", v)} />
        {s.highQuality && (
          <div className="toggle-row"><span>Upscaler</span>
            <select value={s.upscaler} onChange={(e) => set("upscaler", e.target.value as Settings["upscaler"])}>
              <option value="ewa_lanczossharp">EWA Lanczos sharp (best)</option><option value="spline36">Spline36</option><option value="lanczos">Lanczos</option><option value="bilinear">Bilinear (fastest)</option>
            </select></div>
        )}
        <Toggle label="Deband" detail="Smooths color banding (great for anime)" checked={s.deband} onChange={(v) => set("deband", v)} />
        <Toggle label="Motion interpolation" detail="Smoother motion on displays not at the video's frame rate" checked={s.interpolation} onChange={(v) => set("interpolation", v)} />
        <div className="toggle-row"><span>HDR tone mapping</span>
          <select value={s.toneMapping} onChange={(e) => set("toneMapping", e.target.value as Settings["toneMapping"])}>
            <option value="auto">Automatic</option><option value="bt.2390">BT.2390</option><option value="spline">Spline</option><option value="hable">Hable</option><option value="mobius">Mobius</option><option value="reinhard">Reinhard</option><option value="clip">Clip</option>
          </select></div>
        <Toggle label="Detect HDR peak brightness per scene" checked={s.hdrPeakDetect} onChange={(v) => set("hdrPeakDetect", v)} />
        <div className="toggle-row"><span>Default picture</span><Segmented value={s.videoFit} options={[{ value: "contain", label: "Fit" }, { value: "cover", label: "Fill" }, { value: "stretch", label: "Stretch" }]} onChange={(v) => set("videoFit", v)} /></div>
        <Toggle label="Trickplay previews on the timeline" checked={s.trickplay} onChange={(v) => set("trickplay", v)} />
      </Group>
      <Group title="Sound">
        <Toggle label="Pass surround audio to your receiver" detail="Dolby/DTS bitstream over HDMI or S/PDIF" checked={s.audioPassthrough} onChange={(v) => set("audioPassthrough", v)} />
        <div className="toggle-row"><span>Channels</span><Segmented value={s.audioChannels} options={[{ value: "auto", label: "Automatic" }, { value: "stereo", label: "Stereo" }, { value: "5.1", label: "5.1" }, { value: "7.1", label: "7.1" }]} onChange={(v) => set("audioChannels", v)} /></div>
        <Toggle label="Even out loudness" detail="Quiet dialogue louder, explosions softer" checked={s.audioNormalize} onChange={(v) => set("audioNormalize", v)} />
        <div className="slider-row"><div className="slider-head"><span>Volume boost up to</span><span className="muted tabular">{s.volumeBoostMax}%</span></div><Range min={100} max={200} step={10} value={s.volumeBoostMax} onChange={(e) => set("volumeBoostMax", Number(e.target.value))} /></div>
        <div className="toggle-row"><span>Default speed</span><Segmented value={s.defaultSpeed} options={[0.75, 1, 1.25, 1.5].map((v) => ({ value: v, label: `${v}×` }))} onChange={(v) => set("defaultSpeed", v)} /></div>
      </Group>
      <Group title="Controls">
        <Toggle label="Double-click for full screen" checked={s.doubleClickFullscreen} onChange={(v) => set("doubleClickFullscreen", v)} />
        <Toggle label="Mouse wheel changes volume" checked={s.wheelVolume} onChange={(v) => set("wheelVolume", v)} />
        <Toggle label="Start in full screen (this PC)" checked={s.startFullscreen} onChange={(v) => set("startFullscreen", v)} />
        <Toggle label="Show when it ends" checked={s.showClock} onChange={(v) => set("showClock", v)} />
        <Toggle label="Show remaining time" checked={s.remainingTime} onChange={(v) => set("remainingTime", v)} />
        <div className="slider-row"><div className="slider-head"><span>Buffer ahead</span><span className="muted tabular">{s.cacheSeconds}s</span></div><Range min={30} max={600} step={30} value={s.cacheSeconds} onChange={(e) => set("cacheSeconds", Number(e.target.value))} /></div>
        <Field label="Screenshot folder (this PC)" hint="Empty: your Pictures folder">
          <div className="row-line">
            <input value={s.screenshotFolder} onChange={(e) => set("screenshotFolder", e.target.value)} placeholder="Pictures" />
            <button className="glass-button" onClick={async () => { try { const { open } = await import("@tauri-apps/plugin-dialog"); const d = await open({ directory: true }); if (typeof d === "string") set("screenshotFolder", d); } catch { /* */ } }}>Choose…</button>
          </div>
        </Field>
      </Group>
      <button className="text-button" onClick={() => model.updateSettings({ ...pick(DEFAULT_SETTINGS, ["hwdec", "highQuality", "upscaler", "deband", "interpolation", "toneMapping", "hdrPeakDetect", "videoFit", "audioPassthrough", "audioChannels", "audioNormalize", "volumeBoostMax", "defaultSpeed", "cacheSeconds"]) })}>
        <Icon name="undo" size={15} /> Reset player settings
      </button>
    </>
  );
}

function pick<T extends object, K extends keyof T>(o: T, keys: K[]): Pick<T, K> {
  const out = {} as Pick<T, K>;
  for (const k of keys) out[k] = o[k];
  return out;
}

// MARK: Subtitles

function SubtitleSettings() {
  const model = useModel();
  const s = model.settings.subtitleStyle;
  const set = (patch: Partial<typeof s>) => model.updateSettings({ subtitleStyle: { ...s, ...patch } });
  const toHex = (rgba: string) => rgba.slice(0, 7);
  return (
    <Group title="Subtitle style">
      <div className="sub-preview" style={{ fontFamily: s.font, fontWeight: s.bold ? 700 : 500, color: toHex(s.color), fontSize: s.fontSize / 2, WebkitTextStroke: `${s.borderSize / 3}px ${toHex(s.borderColor)}`, background: s.backgroundColor.endsWith("00") ? "transparent" : toHex(s.backgroundColor) }}>
        The quick brown fox jumps over the lazy dog
      </div>
      <Field label="Font"><select value={s.font} onChange={(e) => set({ font: e.target.value })}>{["Segoe UI", "Arial", "Verdana", "Tahoma", "Trebuchet MS", "Georgia", "Times New Roman", "Consolas", "Bahnschrift", "Yu Gothic UI", "Meiryo UI"].map((f) => <option key={f}>{f}</option>)}</select></Field>
      <div className="slider-row"><div className="slider-head"><span>Size</span><span className="muted tabular">{s.fontSize}</span></div><Range min={24} max={90} value={s.fontSize} onChange={(e) => set({ fontSize: Number(e.target.value) })} /></div>
      <Toggle label="Bold" checked={s.bold} onChange={(v) => set({ bold: v })} />
      <div className="toggle-row"><span>Text color</span><input type="color" value={toHex(s.color)} onChange={(e) => set({ color: `${e.target.value.toUpperCase()}FF` })} /></div>
      <div className="toggle-row"><span>Outline color</span><input type="color" value={toHex(s.borderColor)} onChange={(e) => set({ borderColor: `${e.target.value.toUpperCase()}FF` })} /></div>
      <div className="slider-row"><div className="slider-head"><span>Outline</span><span className="muted tabular">{s.borderSize}</span></div><Range min={0} max={6} step={0.5} value={s.borderSize} onChange={(e) => set({ borderSize: Number(e.target.value) })} /></div>
      <div className="toggle-row"><span>Background box</span>
        <span className="row-line"><input type="checkbox" className="switch" checked={!s.backgroundColor.endsWith("00")} onChange={(e) => set({ backgroundColor: e.target.checked ? "#000000B0" : "#00000000" })} />
          {!s.backgroundColor.endsWith("00") && <input type="color" value={toHex(s.backgroundColor)} onChange={(e) => set({ backgroundColor: `${e.target.value.toUpperCase()}B0` })} />}</span></div>
      <div className="slider-row"><div className="slider-head"><span>Distance from the bottom</span><span className="muted tabular">{s.marginY}</span></div><Range min={0} max={150} value={s.marginY} onChange={(e) => set({ marginY: Number(e.target.value) })} /></div>
      <div className="toggle-row"><span>Styled subtitles (ASS, anime typesetting)</span>
        <select value={s.assOverride} onChange={(e) => set({ assOverride: e.target.value as typeof s.assOverride })}>
          <option value="no">Keep their own styling (recommended)</option><option value="scale">Keep styling, use my size</option><option value="force">Force my style</option><option value="strip">Plain text</option>
        </select></div>
      <button className="text-button" onClick={() => model.updateSettings({ subtitleStyle: DEFAULT_SUB_STYLE })}><Icon name="undo" size={15} /> Reset subtitle style</button>
    </Group>
  );
}

// MARK: For You

function ForYouSettings() {
  const model = useModel();
  const set = useSet();
  const s = model.settings;
  const [status, setStatus] = useState<EngineStatus | null>(null);
  useEffect(() => { void getEmbedder().status().then(setStatus).catch(() => {}); }, []);
  return (
    <Group title="For You">
      <Field label="TMDB API Read Access Token or API key" hint="For You picks come from TMDB (free key at themoviedb.org → Settings → API). Saved to your Jellyfin account, so the iPhone app has it too.">
        <input type="password" defaultValue={s.tmdbKey} onBlur={(e) => { if (e.target.value.trim() !== s.tmdbKey) void model.setTmdbKey(e.target.value); }} spellCheck={false} />
      </Field>
      <Toggle label="On-device AI ranking" detail={status ? `Engine: ${status.detail}` : "Compares overviews with a small model on this PC"} checked={s.useOnDeviceAI} onChange={(v) => set("useOnDeviceAI", v)} />
      <Toggle label="Count what you're watching as liked" detail="Shows and movies you're partway through count towards your taste" checked={s.includeWatchingAsLiked} onChange={(v) => { set("includeWatchingAsLiked", v); model.tasteChanged(); }} />
      <p className="muted small">For You never suggests anything already on your server: titles are matched by the TMDB, IMDb and TVDB ids Jellyfin stored, then by title and year. Your taste comes from what you finished, favourited or are watching on your server (the chosen library counts most), what you gave up on, and what you marked Not for me. The AI reads your library with read-only requests: it can't change, move or delete anything. My List, Not for me, Already seen and your settings are saved in your account's private JellyReco storage on your server, so they follow you to every device, including the iPhone app. Libraries named "placeholder" or "playlist(s)" never appear.</p>
      <div className="row-line">
        <button className="glass-button" onClick={() => { model.discovery.reset(); model.reco.loadedAt = 0; model.toast("Picks will be rebuilt", "success"); }}><Icon name="refresh" size={15} /> Rebuild picks now</button>
        <button className="glass-button" onClick={() => ui.openSheet({ kind: "confirm", title: "Reset Not for me on For You picks?", text: "Titles you passed on can be suggested again.", confirmLabel: "Reset", danger: true, run: async () => { await model.storage?.clear("notforme"); model.tasteChanged(); } })}>Reset "Not for me" on For You picks</button>
      </div>
    </Group>
  );
}

// MARK: Devices & servers, about

function DevicesSettings() {
  const model = useModel();
  return (
    <>
      <Group title="Servers & accounts on this PC">
        {model.servers.map((sv) => (
          <div key={sv.id} className="server-block">
            <div className="row static"><Icon name="server" size={20} /><div className="row-text"><div className="row-title">{sv.name}{sv.id === model.server?.id ? " (current)" : ""}</div><div className="row-sub">{sv.url}{sv.version ? ` · Jellyfin ${sv.version}` : ""}</div></div></div>
            <div className="chips-wrap">
              {sv.accounts.map((a) => <button key={a.userId} className={`chip chip-button ${a.userId === model.user?.Id && sv.id === model.server?.id ? "" : "chip-muted"}`} onClick={() => void model.switchAccount(sv, a.userId)}>{a.name}</button>)}
            </div>
          </div>
        ))}
        <button className="glass-button" onClick={() => void model.signOut()}><Icon name="plus" size={15} /> Add a server or account</button>
      </Group>
    </>
  );
}

function About() {
  const model = useModel();
  const [engine, setEngine] = useState<string>("…");
  const [ai, setAi] = useState<string>("…");
  useEffect(() => {
    void getEngine().info().then((i) => setEngine(i.available ? i.detail : `Not available: ${i.detail}`));
    void getEmbedder().status().then((s) => setAi(s.detail)).catch(() => setAi("Not available"));
  }, []);
  return (
    <Group title="About JellyReco">
      <div className="kv">
        <div className="kv-item"><span>Version</span><strong>{APP_VERSION}</strong></div>
        <div className="kv-item"><span>Server</span><strong>{model.server?.name} · Jellyfin {model.server?.version}</strong></div>
        <div className="kv-item"><span>Address</span><strong>{model.server?.url}</strong></div>
        <div className="kv-item"><span>Player engine</span><strong>{engine}</strong></div>
        <div className="kv-item"><span>On-device AI</span><strong>{ai}</strong></div>
        <div className="kv-item"><span>This device</span><strong>{model.deviceName}</strong></div>
      </div>
      <p className="muted small">An unofficial Jellyfin client. Playback by mpv and FFmpeg. Recommendations by AniReco's engine with BAAI bge-small-en-v1.5.</p>
    </Group>
  );
}
