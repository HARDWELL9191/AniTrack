// The admin Dashboard: everything jellyfin-web's dashboard has, regrouped. An overview (server,
// storage, live sessions, activity, tasks) and pages for settings, users, libraries, playback,
// networking, devices, activity, Live TV, plugins, tasks, API keys, logs and backups.
// Every config page shows the common options first, then every other option the server reports,
// so nothing is missing even when the server adds settings.

import { LibraryOptionsEditor, type LibraryOptions } from "./libraryadmin";
import { type ReactNode, useEffect, useMemo, useState } from "react";
import { getSocket } from "../core/socket";
import type {
  ActivityLogEntry, ApiKey, BackupManifest, BackupOptions, Culture, Country, DeviceInfo, FileSystemEntry, LogFile, PackageInfo, PluginInfo, RepositoryInfo,
  SessionInfo, TaskInfo, TaskTrigger, User, UserPolicy, VirtualFolder,
} from "../core/types";
import { secondsToTicks, ticksToSeconds } from "../core/types";
import { cardImage, Cover, Empty, ErrorNote, Field, Group, Modal, PageHeader, Segmented, Spinner, Toggle, useAction, useLoad } from "./components";
import { bitrate, bytes, clock, dateTime, relativeTime } from "./fmt";
import { Icon } from "./icons";
import { writeTextFile } from "./native";
import { ui, useModel } from "./state";

const PAGES: { id: string; label: string; icon: string; group: string }[] = [
  { id: "general", label: "General", icon: "settings", group: "Server" },
  { id: "branding", label: "Branding", icon: "palette", group: "Server" },
  { id: "users", label: "Users", icon: "users", group: "Server" },
  { id: "libraries", label: "Libraries", icon: "folder", group: "Server" },
  { id: "display", label: "Display", icon: "grid", group: "Server" },
  { id: "metadata", label: "Metadata", icon: "tag", group: "Server" },
  { id: "nfo", label: "NFO settings", icon: "edit", group: "Server" },
  { id: "transcoding", label: "Transcoding", icon: "zap", group: "Playback" },
  { id: "resume", label: "Resume & streaming", icon: "play", group: "Playback" },
  { id: "trickplay", label: "Trickplay", icon: "image", group: "Playback" },
  { id: "networking", label: "Networking", icon: "network", group: "Server" },
  { id: "devices", label: "Devices", icon: "devices", group: "Devices" },
  { id: "activity", label: "Activity", icon: "activity", group: "Devices" },
  { id: "livetv", label: "Live TV", icon: "live", group: "Live TV" },
  { id: "plugins", label: "Plugins", icon: "puzzle", group: "Advanced" },
  { id: "catalog", label: "Plugin catalog", icon: "download", group: "Advanced" },
  { id: "repositories", label: "Repositories", icon: "link", group: "Advanced" },
  { id: "tasks", label: "Scheduled tasks", icon: "clock", group: "Advanced" },
  { id: "apikeys", label: "API keys", icon: "key2", group: "Advanced" },
  { id: "logs", label: "Logs", icon: "terminal", group: "Advanced" },
  { id: "backups", label: "Backups", icon: "archive", group: "Advanced" },
];

function open(page: string, arg?: string) {
  ui.push("dashboard", { kind: "dashboard", page, arg });
}

// MARK: Overview

export function DashboardRoot() {
  const model = useModel();
  const api = model.api!;
  const { data: info, reload: reloadInfo } = useLoad(() => api.systemInfo(), []);
  const { data: storage } = useLoad(() => api.get<{ ProgramDataFolder?: Folder; CacheFolder?: Folder; LogFolder?: Folder; TranscodingTempFolder?: Folder; LibraryFolders?: Folder[] }>("/System/Info/Storage").catch(() => null), []);
  const groups = [...new Set(PAGES.map((p) => p.group))];
  const { busy, run } = useAction();
  return (
    <div className="page">
      <PageHeader title="Dashboard" subtitle={info?.ServerName ? `${info.ServerName}${info.Version ? ` · Jellyfin ${info.Version}` : ""}` : undefined}>
        <button className="glass-button" disabled={busy} onClick={() => void run(() => api.post("/Library/Refresh"), "Scanning all libraries")}><Icon name="refresh" size={15} /> Scan all libraries</button>
        <button className="glass-button" onClick={() => ui.openSheet({ kind: "confirm", title: "Restart the server?", text: "Playback on every device stops for a moment.", confirmLabel: "Restart", run: async () => { await api.post("/System/Restart"); model.toast("Restarting…"); setTimeout(reloadInfo, 15000); } })}><Icon name="repeat" size={15} /> Restart</button>
        <button className="glass-button danger" onClick={() => ui.openSheet({ kind: "confirm", danger: true, title: "Shut down the server?", text: "You'll need to start it again on the server machine.", confirmLabel: "Shut down", run: () => api.post("/System/Shutdown") })}><Icon name="power" size={15} /> Shut down</button>
      </PageHeader>
      {info?.HasPendingRestart && <div className="banner warn"><Icon name="info" size={16} /> The server needs a restart to apply changes.</div>}
      {info?.HasUpdateAvailable && <div className="banner"><Icon name="download" size={16} /> A Jellyfin update is available.</div>}
      <div className="dash-grid">
        <Group title="Server">
          {info ? (
            <div className="kv">
              <Kv k="Name" v={info.ServerName} /><Kv k="Version" v={info.Version} /><Kv k="System" v={`${info.OperatingSystemDisplayName ?? ""} ${info.SystemArchitecture ?? ""}`} />
              <Kv k="Address" v={info.LocalAddress} /><Kv k="FFmpeg" v={info.EncoderLocation} /><Kv k="Data" v={info.ProgramDataPath} wide />
              <Kv k="Cache" v={info.CachePath} wide /><Kv k="Logs" v={info.LogPath} wide /><Kv k="Transcodes" v={info.TranscodingTempPath} wide /><Kv k="Metadata" v={info.InternalMetadataPath} wide />
            </div>
          ) : <Spinner />}
        </Group>
        {storage && (
          <Group title="Storage">
            {[["Program data", storage.ProgramDataFolder], ["Cache", storage.CacheFolder], ["Transcodes", storage.TranscodingTempFolder], ["Logs", storage.LogFolder], ...(storage.LibraryFolders ?? []).map((f) => [f.Path ?? "Library", f] as const)].map(([label, f]) => f && <StorageBar key={String(label)} label={String(label)} f={f as Folder} />)}
          </Group>
        )}
      </div>
      <Sessions />
      <div className="dash-grid">
        <RunningTasks />
        <RecentActivity />
      </div>
      {groups.map((g) => (
        <section key={g}>
          <h2 className="section-title">{g}</h2>
          <div className="dash-tiles">
            {PAGES.filter((p) => p.group === g).map((p) => (
              <button key={p.id} className="dash-tile panel" onClick={() => open(p.id)}><Icon name={p.icon} size={22} /><span>{p.label}</span><Icon name="chevronRight" size={16} className="row-chevron" /></button>
            ))}
          </div>
        </section>
      ))}
    </div>
  );
}

interface Folder { Path?: string; FreeSpace?: number; UsedSpace?: number; StorageType?: string; DeviceId?: string }

function StorageBar({ label, f }: { label: string; f: Folder }) {
  const total = (f.FreeSpace ?? 0) + (f.UsedSpace ?? 0);
  const pct = total ? ((f.UsedSpace ?? 0) / total) * 100 : 0;
  return (
    <div className="storage">
      <div className="slider-head"><span title={f.Path}>{label}</span><span className="muted small tabular">{bytes(f.FreeSpace)} free of {bytes(total)}</span></div>
      <div className="progress"><div style={{ width: `${pct}%`, background: pct > 90 ? "var(--low)" : pct > 75 ? "var(--ok)" : undefined }} /></div>
    </div>
  );
}

function Sessions() {
  const model = useModel();
  const api = model.api!;
  const [sessions, setSessions] = useState<SessionInfo[] | null>(null);
  useEffect(() => {
    let alive = true;
    const load = () => api.sessions(960).then((s) => { if (alive) setSessions(s); }).catch(() => {});
    void load();
    const socket = getSocket();
    socket?.send("SessionsStart", "0,1500");
    const off = socket?.on("Sessions", (d) => setSessions(d as SessionInfo[]));
    const t = setInterval(load, 10000);
    return () => { alive = false; clearInterval(t); off?.(); socket?.send("SessionsStop"); };
  }, [api]);
  if (!sessions) return <Spinner />;
  const active = sessions.filter((s) => s.NowPlayingItem);
  const idle = sessions.filter((s) => !s.NowPlayingItem);
  const cmd = (s: SessionInfo, path: string, body?: unknown) => api.post(`/Sessions/${s.Id}/${path}`, body).catch((e) => model.fail(e));
  const message = (s: SessionInfo) => ui.openSheet({ kind: "prompt", title: `Message ${s.UserName} on ${s.DeviceName}`, label: "Message", confirmLabel: "Send", run: async (text) => { await api.post(`/Sessions/${s.Id}/Message`, { Header: "Message from the server", Text: text, TimeoutMs: 10000 }); model.toast("Sent", "success"); } });
  return (
    <section>
      <h2 className="section-title">Now playing <span className="muted small">{active.length} of {sessions.length} devices</span></h2>
      {!active.length && <p className="muted">Nobody is playing anything right now.</p>}
      <div className="session-grid">
        {active.map((s) => {
          const item = s.NowPlayingItem!;
          const pos = ticksToSeconds(s.PlayState?.PositionTicks);
          const dur = ticksToSeconds(item.RunTimeTicks);
          const t = s.TranscodingInfo;
          return (
            <div key={s.Id} className="session panel">
              <Cover url={cardImage(api, item, "landscape", 320)} width="100%" height={150} radius={12} />
              <div className="session-text">
                <strong>{item.SeriesName ? `${item.SeriesName} · ${item.Name}` : item.Name}</strong>
                <span className="muted small">{s.UserName} · {s.DeviceName} · {s.Client} {s.ApplicationVersion}</span>
                <div className="progress"><div style={{ width: `${dur ? (pos / dur) * 100 : 0}%` }} /></div>
                <span className="muted small tabular">{clock(pos)} / {clock(dur)} · {s.PlayState?.IsPaused ? "Paused" : "Playing"}</span>
                <span className={`chip ${s.PlayState?.PlayMethod === "Transcode" ? "chip-danger" : "chip-muted"}`}>
                  {s.PlayState?.PlayMethod === "Transcode" ? `Transcoding${t ? `: ${t.VideoCodec ?? ""}/${t.AudioCodec ?? ""} ${bitrate(t.Bitrate)}${t.HardwareAccelerationType ? ` (${t.HardwareAccelerationType})` : ""}${t.TranscodeReasons?.length ? ` · ${t.TranscodeReasons.join(", ")}` : ""}` : ""}` : s.PlayState?.PlayMethod ?? "Direct play"}
                </span>
                {s.RemoteEndPoint && <span className="muted small">From {s.RemoteEndPoint}</span>}
              </div>
              <div className="row-line">
                {s.SupportsRemoteControl && <button className="round-button" onClick={() => void cmd(s, "Playing/PlayPause")} title="Play/pause"><Icon name={s.PlayState?.IsPaused ? "playFill" : "pauseFill"} size={14} /></button>}
                {s.SupportsRemoteControl && <button className="round-button" onClick={() => void cmd(s, "Playing/Stop")} title="Stop"><Icon name="x" size={14} /></button>}
                <button className="round-button" onClick={() => message(s)} title="Send a message"><Icon name="bell" size={14} /></button>
              </div>
            </div>
          );
        })}
      </div>
      {idle.length > 0 && (
        <div className="chips-wrap">{idle.map((s) => <span key={s.Id} className="chip chip-muted" title={`Last active ${relativeTime(s.LastActivityDate)}`}><Icon name="devices" size={12} /> {s.UserName} · {s.DeviceName}</span>)}</div>
      )}
    </section>
  );
}

function RunningTasks() {
  const model = useModel();
  const api = model.api!;
  const [tasks, setTasks] = useState<TaskInfo[] | null>(null);
  useEffect(() => {
    const load = () => api.get<TaskInfo[]>("/ScheduledTasks", { isHidden: false }).then((r) => setTasks(Array.isArray(r) ? r : [])).catch(() => {});
    void load();
    const socket = getSocket();
    socket?.send("ScheduledTasksInfoStart", "0,1000");
    const off = socket?.on("ScheduledTasksInfo", (d) => { if (Array.isArray(d)) setTasks(d as TaskInfo[]); });
    const t = setInterval(load, 5000);
    return () => { clearInterval(t); off?.(); socket?.send("ScheduledTasksInfoStop"); };
  }, [api]);
  const running = tasks?.filter((t) => t.State !== "Idle") ?? [];
  return (
    <Group title="Running tasks" actions={<button className="link-button small" onClick={() => open("tasks")}>All tasks</button>}>
      {!tasks ? <Spinner /> : !running.length ? <p className="muted small">Nothing running.</p> : running.map((t) => (
        <div key={t.Id} className="storage">
          <div className="slider-head"><span>{t.Name}</span><span className="muted small tabular">{Math.round(t.CurrentProgressPercentage ?? 0)}%</span></div>
          <div className="progress"><div style={{ width: `${t.CurrentProgressPercentage ?? 0}%` }} /></div>
        </div>
      ))}
    </Group>
  );
}

function RecentActivity() {
  const model = useModel();
  const { data } = useLoad(() => model.api!.get<{ Items: ActivityLogEntry[] }>("/System/ActivityLog/Entries", { limit: 8 }), []);
  return (
    <Group title="Recent activity" actions={<button className="link-button small" onClick={() => open("activity")}>All activity</button>}>
      {!data ? <Spinner /> : <ActivityRows entries={data.Items} />}
    </Group>
  );
}

function ActivityRows({ entries }: { entries: ActivityLogEntry[] }) {
  return (
    <div className="activity">
      {entries.map((e) => (
        <div key={e.Id} className={`activity-row sev-${e.Severity.toLowerCase()}`}>
          <Icon name={e.Severity === "Error" || e.Severity === "Critical" ? "info" : e.Severity === "Warning" ? "bell" : "activity"} size={15} />
          <div><strong>{e.Name}</strong>{e.ShortOverview && <span className="muted small"> · {e.ShortOverview}</span>}</div>
          <span className="muted small" title={dateTime(e.Date)}>{relativeTime(e.Date)}</span>
        </div>
      ))}
    </div>
  );
}

// MARK: Pages

export function DashboardPage({ page, arg, back }: { page: string; arg?: string; back: () => void }) {
  const title = PAGES.find((p) => p.id === page)?.label ?? (page === "user" ? "User" : page === "library" ? "Library" : page === "plugin" ? "Plugin" : page === "log" ? arg ?? "Log" : page);
  return (
    <div className="page">
      <PageHeader title={title} back={back} />
      {page === "general" && <ServerConfigPage curated={["ServerName", "UICulture", "PreferredMetadataLanguage", "MetadataCountryCode", "QuickConnectAvailable", "EnableMetrics", "IsStartupWizardCompleted", "CachePath", "MetadataPath", "LibraryScanFanoutConcurrency", "LibraryMetadataRefreshConcurrency", "ParallelImageEncodingLimit", "LogFileRetentionDays", "ActivityLogRetentionDays", "EnableLegacyAuthorization"]} />}
      {page === "branding" && <NamedConfigPage name="branding" curated={["LoginDisclaimer", "CustomCss", "SplashscreenEnabled"]} />}
      {page === "display" && <ServerConfigPage curated={["EnableFolderView", "DisplaySpecialsWithinSeasons", "EnableGroupingMoviesIntoCollections", "EnableGroupingShowsIntoCollections", "EnableExternalContentInSuggestions", "SortReplaceCharacters", "SortRemoveCharacters", "SortRemoveWords"]} only />}
      {page === "metadata" && <><ServerConfigPage curated={["PreferredMetadataLanguage", "MetadataCountryCode", "DummyChapterDuration", "ChapterImageResolution", "ImageExtractionTimeoutMs", "SaveMetadataHidden", "EnableSlowResponseWarning", "ContentTypes", "MetadataOptions", "PathSubstitutions"]} only /><NamedConfigPage name="metadata" title="Image extraction" /></>}
      {page === "nfo" && <NamedConfigPage name="xbmcmetadata" curated={["UserId", "ReleaseDateFormat", "SaveImagePathsInNfo", "EnablePathSubstitution", "EnableExtraThumbsDuplication"]} />}
      {page === "transcoding" && <NamedConfigPage name="encoding" curated={[
        "HardwareAccelerationType", "EnableHardwareEncoding", "HardwareDecodingCodecs", "EnableDecodingColorDepth10Hevc", "EnableDecodingColorDepth10Vp9", "EnableDecodingColorDepth10HevcRext",
        "EnableDecodingColorDepth12HevcRext", "AllowHevcEncoding", "AllowAv1Encoding", "EnableTonemapping", "TonemappingAlgorithm", "TonemappingMode", "TonemappingRange", "TonemappingPeak",
        "EncoderPreset", "H264Crf", "H265Crf", "EncodingThreadCount", "EnableThrottling", "ThrottleDelaySeconds", "EnableSegmentDeletion", "SegmentKeepSeconds", "DownMixAudioBoost",
        "DownMixStereoAlgorithm", "MaxMuxingQueueSize", "EnableFallbackFont", "FallbackFontPath", "TranscodingTempPath", "EncoderAppPathDisplay", "VaapiDevice", "QsvDevice",
      ]} />}
      {page === "resume" && <ServerConfigPage curated={["MinResumePct", "MaxResumePct", "MinResumeDurationSeconds", "MinAudiobookResume", "MaxAudiobookResume", "InactiveSessionThreshold", "RemoteClientBitrateLimit", "MaxAudioChannels"]} only />}
      {page === "trickplay" && <ServerConfigPage curated={["TrickplayOptions"]} only />}
      {page === "networking" && <NamedConfigPage name="network" curated={[
        "BaseUrl", "EnableHttps", "RequireHttps", "CertificatePath", "CertificatePassword", "InternalHttpPort", "InternalHttpsPort", "PublicHttpPort", "PublicHttpsPort",
        "EnableRemoteAccess", "LocalNetworkSubnets", "LocalNetworkAddresses", "KnownProxies", "IgnoreVirtualInterfaces", "VirtualInterfaceNames", "EnableIPv4", "EnableIPv6",
        "RemoteIPFilter", "IsRemoteIPFilterBlacklist", "EnablePublishedServerUriByRequest", "PublishedServerUriBySubnet", "AutoDiscovery",
      ]} warn="Wrong network settings can make the server unreachable. Change with care." />}
      {page === "users" && <UsersPage />}
      {page === "user" && arg && <UserPage id={arg} />}
      {page === "libraries" && <LibrariesPage />}
      {page === "library" && arg && <LibraryEditPage name={arg} />}
      {page === "devices" && <DevicesPage />}
      {page === "activity" && <ActivityPage />}
      {page === "livetv" && <LiveTvPage />}
      {page === "plugins" && <PluginsPage />}
      {page === "plugin" && arg && <PluginPage id={arg} />}
      {page === "catalog" && <CatalogPage />}
      {page === "repositories" && <RepositoriesPage />}
      {page === "tasks" && <TasksPage />}
      {page === "task" && arg && <TaskPage id={arg} />}
      {page === "apikeys" && <ApiKeysPage />}
      {page === "logs" && <LogsPage />}
      {page === "log" && arg && <LogPage name={arg} />}
      {page === "backups" && <BackupsPage />}
    </div>
  );
}

// MARK: Generic config editor

const LABELS: Record<string, string> = {
  UICulture: "Display language", QuickConnectAvailable: "Allow Quick Connect", EnableMetrics: "Prometheus metrics (/metrics)", IsStartupWizardCompleted: "Setup wizard completed",
  LibraryScanFanoutConcurrency: "Parallel library scan tasks (0 = automatic)", LibraryMetadataRefreshConcurrency: "Parallel metadata refreshes (0 = automatic)",
  ParallelImageEncodingLimit: "Parallel image encodings (0 = automatic)", EnableLegacyAuthorization: "Accept old clients' authorization (api_key, X-Emby-Token)",
  MinResumePct: "Minimum resume percentage", MaxResumePct: "Maximum resume percentage", MinResumeDurationSeconds: "Shortest resumable length (seconds)",
  RemoteClientBitrateLimit: "Internet streaming bitrate limit (bits/s, 0 = none)", HardwareAccelerationType: "Hardware acceleration", EncoderPreset: "Encoder preset",
  H264Crf: "H.264 quality (CRF)", H265Crf: "HEVC quality (CRF)", BaseUrl: "Base URL", EnableHttps: "Enable HTTPS", RequireHttps: "Require HTTPS",
  EnableRemoteAccess: "Allow remote connections", LocalNetworkSubnets: "LAN networks", KnownProxies: "Known proxies", InternalHttpPort: "HTTP port", InternalHttpsPort: "HTTPS port",
  PublicHttpPort: "Public HTTP port", PublicHttpsPort: "Public HTTPS port", LoginDisclaimer: "Login disclaimer", CustomCss: "Custom CSS", SplashscreenEnabled: "Splash screen",
  EnableFolderView: "Show a folder view", DisplaySpecialsWithinSeasons: "Show specials within their seasons", EnableGroupingMoviesIntoCollections: "Group movies into collections",
  EnableGroupingShowsIntoCollections: "Group shows into collections", EnableExternalContentInSuggestions: "External content in suggestions",
};

function label(key: string) {
  return LABELS[key] ?? key.replace(/([a-z0-9])([A-Z])/g, "$1 $2").replace(/([A-Z]+)([A-Z][a-z])/g, "$1 $2").replace(/^./, (c) => c.toUpperCase());
}

/** Edits one JSON object: booleans, numbers, text, lists; nested objects open in place. */
function ObjectEditor({ value, onChange, keys, skip }: { value: Record<string, unknown>; onChange: (v: Record<string, unknown>) => void; keys?: string[]; skip?: Set<string> }) {
  const all = keys ?? Object.keys(value);
  return (
    <div className="form">
      {all.filter((k) => k in value && !skip?.has(k)).map((k) => <ValueEditor key={k} name={k} value={value[k]} onChange={(v) => onChange({ ...value, [k]: v })} />)}
    </div>
  );
}

function ValueEditor({ name, value, onChange }: { name: string; value: unknown; onChange: (v: unknown) => void }) {
  const [open, setOpen] = useState(false);
  if (typeof value === "boolean") return <Toggle label={label(name)} checked={value} onChange={onChange} />;
  if (typeof value === "number") return <Field label={label(name)}><input type="number" step="any" value={value} onChange={(e) => onChange(e.target.value === "" ? 0 : Number(e.target.value))} /></Field>;
  if (typeof value === "string" || value === null) {
    const long = name.toLowerCase().includes("css") || name.toLowerCase().includes("disclaimer");
    return <Field label={label(name)}>{long ? <textarea rows={6} value={value ?? ""} onChange={(e) => onChange(e.target.value)} /> : <input value={value ?? ""} onChange={(e) => onChange(e.target.value)} type={name.toLowerCase().includes("password") ? "password" : "text"} />}</Field>;
  }
  if (Array.isArray(value)) {
    if (value.every((x) => typeof x === "string" || typeof x === "number")) {
      return <Field label={label(name)} hint="One per line"><textarea rows={Math.min(8, Math.max(2, value.length + 1))} value={value.join("\n")} onChange={(e) => onChange(e.target.value.split("\n").map((x) => x.trim()).filter(Boolean).map((x) => (value.length && typeof value[0] === "number" ? Number(x) : x)))} /></Field>;
    }
    return (
      <div className="nested">
        <button className="text-button" onClick={() => setOpen(!open)}><Icon name={open ? "chevronDown" : "chevronRight"} size={14} /> {label(name)} <span className="muted small">({value.length})</span></button>
        {open && <Field label="As JSON"><JsonArea value={value} onChange={onChange} /></Field>}
      </div>
    );
  }
  if (typeof value === "object") {
    return (
      <div className="nested">
        <button className="text-button" onClick={() => setOpen(!open)}><Icon name={open ? "chevronDown" : "chevronRight"} size={14} /> {label(name)}</button>
        {open && <ObjectEditor value={value as Record<string, unknown>} onChange={onChange} />}
      </div>
    );
  }
  return null;
}

function JsonArea({ value, onChange }: { value: unknown; onChange: (v: unknown) => void }) {
  const [text, setText] = useState(() => JSON.stringify(value, null, 2));
  const [bad, setBad] = useState(false);
  return <textarea className={`mono ${bad ? "bad" : ""}`} rows={10} value={text} onChange={(e) => { setText(e.target.value); try { onChange(JSON.parse(e.target.value)); setBad(false); } catch { setBad(true); } }} />;
}

/** A config with the chosen fields first and every other field under "All options". */
function ConfigEditor({ load, save, curated, only, warn, title }: { load: () => Promise<Record<string, unknown>>; save: (v: Record<string, unknown>) => Promise<unknown>; curated?: string[]; only?: boolean; warn?: string; title?: string }) {
  const { data, error, reload } = useLoad(load, []);
  const [draft, setDraft] = useState<Record<string, unknown> | null>(null);
  const [showAll, setShowAll] = useState(false);
  useEffect(() => { if (data) setDraft(structuredClone(data)); }, [data]);
  const { busy, run } = useAction();
  const dirty = useMemo(() => JSON.stringify(draft) !== JSON.stringify(data), [draft, data]);
  if (error) return <ErrorNote text={error} retry={reload} />;
  if (!draft) return <Spinner />;
  const first = (curated ?? []).filter((k) => k in draft);
  const rest = Object.keys(draft).filter((k) => !first.includes(k));
  return (
    <Group title={title} actions={<button className="glass-button prominent" disabled={busy || !dirty} onClick={() => void run(async () => { await save(draft); reload(); }, "Saved")}>Save</button>}>
      {warn && <div className="banner warn"><Icon name="info" size={15} /> {warn}</div>}
      {first.length > 0 && <ObjectEditor value={draft} onChange={setDraft} keys={first} />}
      {(!first.length || !only) && rest.length > 0 && (
        <div className="nested">
          {first.length > 0 && <button className="text-button" onClick={() => setShowAll(!showAll)}><Icon name={showAll ? "chevronDown" : "chevronRight"} size={14} /> All options ({rest.length})</button>}
          {(showAll || !first.length) && <ObjectEditor value={draft} onChange={setDraft} keys={rest} />}
        </div>
      )}
      {dirty && <div className="sticky-save"><span>Unsaved changes</span><button className="glass-button" onClick={() => setDraft(structuredClone(data!))}>Discard</button><button className="glass-button prominent" disabled={busy} onClick={() => void run(async () => { await save(draft); reload(); }, "Saved")}>Save</button></div>}
    </Group>
  );
}

function ServerConfigPage({ curated, only }: { curated: string[]; only?: boolean }) {
  const model = useModel();
  const api = model.api!;
  const { data: cultures } = useLoad(() => api.get<Culture[]>("/Localization/Cultures"), []);
  const { data: countries } = useLoad(() => api.get<Country[]>("/Localization/Countries"), []);
  return (
    <>
      {cultures && countries && <p className="muted small">Languages use codes like "en" or "en-US"; countries like "US" or "SI". {cultures.length} languages and {countries.length} countries are available.</p>}
      <ConfigEditor load={() => api.get<Record<string, unknown>>("/System/Configuration")} save={(v) => api.post("/System/Configuration", v)} curated={curated} only={only} />
    </>
  );
}

function NamedConfigPage({ name, curated, warn, title }: { name: string; curated?: string[]; warn?: string; title?: string }) {
  const model = useModel();
  const api = model.api!;
  return <ConfigEditor title={title} load={() => api.get<Record<string, unknown>>(`/System/Configuration/${name}`)} save={(v) => (name === "branding" ? api.post("/System/Configuration/Branding", v) : api.post(`/System/Configuration/${name}`, v))} curated={curated} warn={warn} />;
}

function Kv({ k, v, wide }: { k: string; v?: string | null; wide?: boolean }) {
  if (!v) return null;
  return <div className={`kv-item ${wide ? "wide" : ""}`}><span>{k}</span><strong>{v}</strong></div>;
}

// MARK: Users

function UsersPage() {
  const model = useModel();
  const api = model.api!;
  const { data, error, reload } = useLoad(() => api.get<User[]>("/Users"), []);
  const add = () => ui.openSheet({ kind: "prompt", title: "New user", label: "Name", confirmLabel: "Create", run: async (name) => { const u = await api.post<User>("/Users/New", { Name: name }); reload(); open("user", u.Id); } });
  if (error) return <ErrorNote text={error} retry={reload} />;
  if (!data) return <Spinner />;
  return (
    <>
      <div className="toolbar-row"><button className="glass-button prominent" onClick={add}><Icon name="plus" size={15} /> Add user</button></div>
      <div className="user-cards">
        {data.map((u) => (
          <button key={u.Id} className="user-card panel" onClick={() => open("user", u.Id)}>
            <Cover url={u.PrimaryImageTag ? api.userImage(u.Id, u.PrimaryImageTag, 120) : undefined} width={64} height={64} radius={32} icon="user" />
            <div>
              <strong>{u.Name}</strong>
              <span className="muted small">{u.Policy?.IsAdministrator ? "Administrator" : "User"}{u.Policy?.IsDisabled ? " · Disabled" : ""}{u.Policy?.IsHidden ? " · Hidden" : ""}</span>
              <span className="muted small">{u.LastActivityDate ? `Active ${relativeTime(u.LastActivityDate)}` : "Never active"}</span>
            </div>
          </button>
        ))}
      </div>
    </>
  );
}

function UserPage({ id }: { id: string }) {
  const model = useModel();
  const api = model.api!;
  const { data: user, reload } = useLoad(() => api.get<User>(`/Users/${id}`), [id]);
  const { data: views } = useLoad(() => api.get<{ Items: { Id: string; Name: string }[] }>("/Library/MediaFolders", { isHidden: false }), []);
  const { data: channels } = useLoad(() => api.get<{ Items: { Id: string; Name: string }[] }>("/Channels").catch(() => ({ Items: [] })), []);
  const { data: devices } = useLoad(() => api.get<{ Items: DeviceInfo[] }>("/Devices"), []);
  const { data: ratings } = useLoad(() => api.get<{ Name: string; Value?: number | null }[]>("/Localization/ParentalRatings"), []);
  const [tab, setTab] = useState<"profile" | "access" | "parental" | "password">("profile");
  const [policy, setPolicy] = useState<UserPolicy | null>(null);
  const [name, setName] = useState("");
  const [pw, setPw] = useState("");
  useEffect(() => { if (user) { setPolicy(structuredClone(user.Policy!)); setName(user.Name ?? ""); } }, [user]);
  const { busy, run } = useAction();
  if (!user || !policy) return <Spinner />;
  const P = (k: keyof UserPolicy, v: unknown) => setPolicy({ ...policy, [k]: v });
  const savePolicy = () => run(async () => { await api.post(`/Users/${id}/Policy`, policy); reload(); }, "Saved");
  const listToggle = (k: keyof UserPolicy, itemId: string, on: boolean) => {
    const list = new Set((policy[k] as string[] | null | undefined) ?? []);
    if (on) list.add(itemId); else list.delete(itemId);
    P(k, [...list]);
  };
  return (
    <>
      <div className="toolbar-row">
        <Segmented value={tab} options={[{ value: "profile", label: "Profile" }, { value: "access", label: "Library access" }, { value: "parental", label: "Parental control" }, { value: "password", label: "Password" }]} onChange={setTab} />
        <div className="toolbar-spacer" />
        {id !== model.user?.Id && <button className="glass-button danger" onClick={() => ui.openSheet({ kind: "confirm", danger: true, title: `Delete ${user.Name}?`, text: "Their watch history and settings are deleted too.", confirmLabel: "Delete", run: async () => { await api.del(`/Users/${id}`); ui.pop("dashboard"); } })}><Icon name="trash" size={15} /> Delete user</button>}
      </div>
      {tab === "profile" && (
        <>
          <Group title="Profile" actions={<button className="glass-button prominent" disabled={busy} onClick={() => void run(async () => { await api.post(`/Users/${id}`, { ...user, Name: name }); await api.post(`/Users/${id}/Policy`, policy); reload(); }, "Saved")}>Save</button>}>
            <Field label="Name"><input value={name} onChange={(e) => setName(e.target.value)} /></Field>
            <Toggle label="Administrator" detail="Can manage the server" checked={policy.IsAdministrator} onChange={(v) => P("IsAdministrator", v)} />
            <Toggle label="Disabled" detail="Can't sign in" checked={policy.IsDisabled} onChange={(v) => P("IsDisabled", v)} />
            <Toggle label="Hidden from login screens" checked={policy.IsHidden} onChange={(v) => P("IsHidden", v)} />
            <Toggle label="Can manage collections" checked={policy.EnableCollectionManagement} onChange={(v) => P("EnableCollectionManagement", v)} />
            <Toggle label="Can manage subtitles" checked={policy.EnableSubtitleManagement} onChange={(v) => P("EnableSubtitleManagement", v)} />
            <Toggle label="Can manage lyrics" checked={!!policy.EnableLyricManagement} onChange={(v) => P("EnableLyricManagement", v)} />
            <Toggle label="Allow remote connections" checked={policy.EnableRemoteAccess} onChange={(v) => P("EnableRemoteAccess", v)} />
            <Toggle label="Live TV access" checked={policy.EnableLiveTvAccess} onChange={(v) => P("EnableLiveTvAccess", v)} />
            <Toggle label="Live TV recording management" checked={policy.EnableLiveTvManagement} onChange={(v) => P("EnableLiveTvManagement", v)} />
          </Group>
          <Group title="Playback" actions={<button className="glass-button prominent" disabled={busy} onClick={() => void savePolicy()}>Save</button>}>
            <Toggle label="Allow media playback" checked={policy.EnableMediaPlayback} onChange={(v) => P("EnableMediaPlayback", v)} />
            <Toggle label="Allow audio transcoding" checked={policy.EnableAudioPlaybackTranscoding} onChange={(v) => P("EnableAudioPlaybackTranscoding", v)} />
            <Toggle label="Allow video transcoding" checked={policy.EnableVideoPlaybackTranscoding} onChange={(v) => P("EnableVideoPlaybackTranscoding", v)} />
            <Toggle label="Allow remuxing" checked={policy.EnablePlaybackRemuxing} onChange={(v) => P("EnablePlaybackRemuxing", v)} />
            <Toggle label="Force transcoding of remote sources (e.g. Live TV)" checked={policy.ForceRemoteSourceTranscoding} onChange={(v) => P("ForceRemoteSourceTranscoding", v)} />
            <Field label="Internet streaming bitrate limit (Mbps, 0 = none)"><input type="number" value={policy.RemoteClientBitrateLimit / 1_000_000} onChange={(e) => P("RemoteClientBitrateLimit", Math.round(Number(e.target.value) * 1_000_000))} /></Field>
            <Field label="Maximum simultaneous streams (0 = no limit)"><input type="number" value={policy.MaxActiveSessions} onChange={(e) => P("MaxActiveSessions", Number(e.target.value))} /></Field>
            <Field label="Sign-in attempts before lockout (0 = default, -1 = never)"><input type="number" value={policy.LoginAttemptsBeforeLockout} onChange={(e) => P("LoginAttemptsBeforeLockout", Number(e.target.value))} /></Field>
            <Field label="SyncPlay">
              <Segmented value={policy.SyncPlayAccess} options={[{ value: "CreateAndJoinGroups", label: "Create & join" }, { value: "JoinGroups", label: "Join only" }, { value: "None", label: "Off" }]} onChange={(v) => P("SyncPlayAccess", v)} />
            </Field>
            <Toggle label="Allow downloads" checked={policy.EnableContentDownloading} onChange={(v) => P("EnableContentDownloading", v)} />
            <Toggle label="Allow deleting media" checked={policy.EnableContentDeletion} onChange={(v) => P("EnableContentDeletion", v)} />
            <Toggle label="Can control other users' sessions" checked={policy.EnableRemoteControlOfOtherUsers} onChange={(v) => P("EnableRemoteControlOfOtherUsers", v)} />
            <Toggle label="Can control shared devices" checked={policy.EnableSharedDeviceControl} onChange={(v) => P("EnableSharedDeviceControl", v)} />
          </Group>
        </>
      )}
      {tab === "access" && (
        <Group title="Library access" actions={<button className="glass-button prominent" disabled={busy} onClick={() => void savePolicy()}>Save</button>}>
          <Toggle label="All libraries" checked={policy.EnableAllFolders} onChange={(v) => P("EnableAllFolders", v)} />
          {!policy.EnableAllFolders && views?.Items.map((v) => <Toggle key={v.Id} label={v.Name} checked={(policy.EnabledFolders ?? []).includes(v.Id)} onChange={(on) => listToggle("EnabledFolders", v.Id, on)} />)}
          {!!channels?.Items.length && <>
            <Toggle label="All channels" checked={policy.EnableAllChannels} onChange={(v) => P("EnableAllChannels", v)} />
            {!policy.EnableAllChannels && channels.Items.map((c) => <Toggle key={c.Id} label={c.Name} checked={(policy.EnabledChannels ?? []).includes(c.Id)} onChange={(on) => listToggle("EnabledChannels", c.Id, on)} />)}
          </>}
          <Toggle label="All devices" checked={policy.EnableAllDevices} onChange={(v) => P("EnableAllDevices", v)} />
          {!policy.EnableAllDevices && devices?.Items.map((d) => <Toggle key={d.Id} label={`${d.CustomName || d.Name} (${d.AppName})`} checked={(policy.EnabledDevices ?? []).includes(d.Id ?? "")} onChange={(on) => listToggle("EnabledDevices", d.Id ?? "", on)} />)}
          <Field label="Can delete media in these libraries">
            <div className="form">{views?.Items.map((v) => <Toggle key={v.Id} label={v.Name} checked={(policy.EnableContentDeletionFromFolders ?? []).includes(v.Id)} onChange={(on) => listToggle("EnableContentDeletionFromFolders", v.Id, on)} />)}</div>
          </Field>
        </Group>
      )}
      {tab === "parental" && (
        <Group title="Parental control" actions={<button className="glass-button prominent" disabled={busy} onClick={() => void savePolicy()}>Save</button>}>
          <Field label="Highest allowed rating">
            <select value={policy.MaxParentalRating ?? ""} onChange={(e) => P("MaxParentalRating", e.target.value === "" ? null : Number(e.target.value))}>
              <option value="">No limit</option>{(ratings ?? []).filter((r) => r.Value !== null && r.Value !== undefined).map((r) => <option key={`${r.Name}-${r.Value}`} value={r.Value!}>{r.Name}</option>)}
            </select>
          </Field>
          <Field label="Block unrated items of these types">
            <div className="chips-wrap">{["Movie", "Series", "Music", "Book", "LiveTvChannel", "LiveTvProgram", "ChannelContent", "Trailer", "Other"].map((t) => {
              const on = (policy.BlockUnratedItems ?? []).includes(t);
              return <button key={t} className={`chip chip-button ${on ? "" : "chip-muted"}`} onClick={() => P("BlockUnratedItems", on ? (policy.BlockUnratedItems ?? []).filter((x) => x !== t) : [...(policy.BlockUnratedItems ?? []), t])}>{t}</button>;
            })}</div>
          </Field>
          <Field label="Only allow items with these tags" hint="One per line"><textarea rows={3} value={(policy.AllowedTags ?? []).join("\n")} onChange={(e) => P("AllowedTags", e.target.value.split("\n").map((x) => x.trim()).filter(Boolean))} /></Field>
          <Field label="Block items with these tags" hint="One per line"><textarea rows={3} value={(policy.BlockedTags ?? []).join("\n")} onChange={(e) => P("BlockedTags", e.target.value.split("\n").map((x) => x.trim()).filter(Boolean))} /></Field>
          <Field label="Access schedule" hint={'When this user may sign in, as JSON (e.g. [{"DayOfWeek":"Everyday","StartHour":8,"EndHour":21}])'}><JsonArea value={policy.AccessSchedules ?? []} onChange={(v) => P("AccessSchedules", v)} /></Field>
        </Group>
      )}
      {tab === "password" && (
        <Group title="Password">
          <Field label="New password"><input type="password" value={pw} onChange={(e) => setPw(e.target.value)} /></Field>
          <div className="row-line">
            <button className="glass-button prominent" disabled={busy || !pw} onClick={() => void run(async () => { await api.post("/Users/Password", { NewPw: pw }, { userId: id }); setPw(""); }, "Password changed")}>Set password</button>
            <button className="glass-button danger" disabled={busy} onClick={() => void run(() => api.post("/Users/Password", { ResetPassword: true }, { userId: id }), "Password removed")}>Remove password</button>
          </div>
        </Group>
      )}
      <details className="raw"><summary>Every policy option</summary><ObjectEditor value={policy as unknown as Record<string, unknown>} onChange={(v) => setPolicy(v as unknown as UserPolicy)} /><button className="glass-button prominent" disabled={busy} onClick={() => void savePolicy()}>Save</button></details>
    </>
  );
}

// MARK: Libraries

const LIBRARY_TYPES = [
  { value: "movies", label: "Movies" }, { value: "tvshows", label: "Shows" }, { value: "music", label: "Music" }, { value: "musicvideos", label: "Music videos" },
  { value: "homevideos", label: "Home videos & photos" }, { value: "boxsets", label: "Collections" }, { value: "books", label: "Books" }, { value: "mixed", label: "Mixed movies and shows" },
];

function LibrariesPage() {
  const model = useModel();
  const api = model.api!;
  const { data, error, reload } = useLoad(() => api.get<VirtualFolder[]>("/Library/VirtualFolders"), []);
  const [adding, setAdding] = useState(false);
  const { busy, run } = useAction();
  useEffect(() => { const t = setInterval(reload, 5000); return () => clearInterval(t); }, []); // eslint-disable-line react-hooks/exhaustive-deps
  if (error) return <ErrorNote text={error} retry={reload} />;
  if (!data) return <Spinner />;
  return (
    <>
      <div className="toolbar-row">
        <button className="glass-button prominent" onClick={() => setAdding(true)}><Icon name="plus" size={15} /> Add library</button>
        <button className="glass-button" disabled={busy} onClick={() => void run(() => api.post("/Library/Refresh"), "Scanning all libraries")}><Icon name="refresh" size={15} /> Scan all</button>
      </div>
      <div className="library-cards">
        {data.map((f) => (
          <div key={f.ItemId ?? f.Name} className="library-card panel">
            <Cover url={f.PrimaryImageItemId ? api.image(f.PrimaryImageItemId, "Primary", { maxWidth: 480 }) : undefined} width="100%" height={130} radius={12} icon="folder" />
            <strong>{f.Name}</strong>
            <span className="muted small">{LIBRARY_TYPES.find((t) => t.value === f.CollectionType)?.label ?? "Mixed"} · {(f.Locations ?? []).length} {(f.Locations ?? []).length === 1 ? "folder" : "folders"}</span>
            {f.RefreshStatus === "Active" && <div className="progress"><div style={{ width: `${f.RefreshProgress ?? 0}%` }} /></div>}
            <div className="row-line">
              <button className="glass-button" onClick={() => open("library", f.Name ?? "")}><Icon name="edit" size={14} /> Edit</button>
              <button className="glass-button" disabled={busy} onClick={() => f.ItemId && void run(() => api.refreshItem(f.ItemId!, { metadata: "Default", images: "Default", replaceMetadata: false, replaceImages: false }), "Scanning")}><Icon name="refresh" size={14} /> Scan</button>
            </div>
          </div>
        ))}
      </div>
      {adding && <AddLibrary close={() => { setAdding(false); reload(); }} />}
    </>
  );
}

function AddLibrary({ close }: { close: () => void }) {
  const model = useModel();
  const api = model.api!;
  const [name, setName] = useState("");
  const [type, setType] = useState("movies");
  const [paths, setPaths] = useState<string[]>([]);
  const [browse, setBrowse] = useState(false);
  // A new library starts with jellyfin-web's defaults; the editor fills in the providers.
  const [options, setOptions] = useState<LibraryOptions>(() => ({ ...NEW_LIBRARY_DEFAULTS }));
  const { busy, run } = useAction();
  const create = () => run(async () => {
    await api.post("/Library/VirtualFolders", { LibraryOptions: { ...options, PathInfos: paths.map((p) => ({ Path: p })) } }, { name, collectionType: type === "mixed" ? undefined : type, refreshLibrary: true });
    close();
  }, `Created ${name}`);
  return (
    <Modal title="Add library" onClose={close} width={620} actions={<button className="glass-button prominent" disabled={busy || !name || !paths.length} onClick={() => void create()}>Create</button>}>
      <div className="form">
        <Field label="Type"><select value={type} onChange={(e) => setType(e.target.value)}>{LIBRARY_TYPES.map((t) => <option key={t.value} value={t.value}>{t.label}</option>)}</select></Field>
        <Field label="Name"><input value={name} onChange={(e) => setName(e.target.value)} autoFocus /></Field>
        <Field label="Folders">
          <div className="rows">{paths.map((p) => <div key={p} className="row static"><Icon name="folder" size={16} /><div className="row-text">{p}</div><button className="link-button danger" onClick={() => setPaths(paths.filter((x) => x !== p))}>Remove</button></div>)}</div>
          <button className="glass-button" onClick={() => setBrowse(true)}><Icon name="plus" size={15} /> Add folder</button>
        </Field>
        <LibraryOptionsEditor key={type} contentType={type} isNew value={options} onChange={setOptions} />
      </div>
      {browse && <FolderPicker onPick={(p) => { setPaths([...new Set([...paths, p])]); setBrowse(false); }} close={() => setBrowse(false)} />}
    </Modal>
  );
}

/** Browses folders on the server's disks. */
function FolderPicker({ onPick, close }: { onPick: (p: string) => void; close: () => void }) {
  const model = useModel();
  const api = model.api!;
  const [path, setPath] = useState<string | null>(null);
  const [typed, setTyped] = useState("");
  const { data, error } = useLoad(async (): Promise<FileSystemEntry[]> => {
    if (path === null) {
      const drives = await api.get<FileSystemEntry[]>("/Environment/Drives").catch(() => []);
      const def = await api.get<{ Path?: string }>("/Environment/DefaultDirectoryBrowser").catch(() => null);
      return [...(def?.Path ? [{ Name: def.Path, Path: def.Path, Type: "Directory" as const }] : []), ...drives];
    }
    return api.get<FileSystemEntry[]>("/Environment/DirectoryContents", { path, includeDirectories: true, includeFiles: false });
  }, [path]);
  const up = async () => {
    if (!path) return;
    const parent = await api.get<string>("/Environment/ParentPath", { path }).catch(() => null);
    setPath(parent || null);
  };
  return (
    <Modal title="Choose a folder on the server" onClose={close} width={560} actions={path ? <button className="glass-button prominent" onClick={() => onPick(path)}>Use this folder</button> : undefined}>
      <div className="row-line"><button className="round-button" disabled={path === null} onClick={() => void up()}><Icon name="arrowUp" size={14} /></button><code className="path">{path ?? "Drives"}</code></div>
      <form className="row-line" onSubmit={(e) => { e.preventDefault(); if (typed) setPath(typed); }}><input placeholder="Or type a path" value={typed} onChange={(e) => setTyped(e.target.value)} /><button className="glass-button">Go</button></form>
      {error ? <ErrorNote text={error} /> : !data ? <Spinner /> : (
        <div className="rows">{data.map((e) => <button key={e.Path} className="row" onClick={() => setPath(e.Path)}><Icon name="folder" size={16} /><div className="row-text">{e.Name}</div></button>)}</div>
      )}
    </Modal>
  );
}

const NEW_LIBRARY_DEFAULTS: LibraryOptions = {
  Enabled: true, EnableRealtimeMonitor: true, EnablePhotos: true, EnableInternetProviders: true, EnableArchiveMediaFiles: false, SaveLocalMetadata: false,
  EnableAutomaticSeriesGrouping: true, AutomaticRefreshIntervalDays: 0, SeasonZeroDisplayName: "Specials", EnableEmbeddedTitles: false, EnableEmbeddedExtrasTitles: false,
  EnableEmbeddedEpisodeInfos: false, AllowEmbeddedSubtitles: "AllowAll", SkipSubtitlesIfEmbeddedSubtitlesPresent: false, SkipSubtitlesIfAudioTrackMatches: false,
  SaveSubtitlesWithMedia: true, SaveLyricsWithMedia: false, RequirePerfectSubtitleMatch: true, AutomaticallyAddToCollection: false, EnableTrickplayImageExtraction: true,
  ExtractTrickplayImagesDuringLibraryScan: false, SaveTrickplayWithMedia: false, EnableChapterImageExtraction: false, ExtractChapterImagesDuringLibraryScan: false,
  EnableLUFSScan: true, PreferNonstandardArtistsTag: false, UseCustomTagDelimiters: false, CustomTagDelimiters: [], DelimiterWhitelist: [], TypeOptions: [],
};

/** Library options with Save, like jellyfin-web's library editor. */
function LibraryOptionsGroup({ folder, reload }: { folder: VirtualFolder; reload: () => void }) {
  const model = useModel();
  const api = model.api!;
  const saved = (folder.LibraryOptions ?? {}) as LibraryOptions;
  const [draft, setDraft] = useState<LibraryOptions>(() => structuredClone(saved));
  const [base, setBase] = useState<string | null>(null);
  const { busy, run } = useAction();
  // The editor fills in explicit provider lists first: that's the baseline, not a change.
  useEffect(() => { if (base === null) { const t = setTimeout(() => setBase(JSON.stringify(draft)), 800); return () => clearTimeout(t); } }, [draft, base]);
  const dirty = base !== null && JSON.stringify(draft) !== base;
  const save = () => run(async () => { await api.post("/Library/VirtualFolders/LibraryOptions", { Id: folder.ItemId, LibraryOptions: draft }); setBase(JSON.stringify(draft)); reload(); }, "Saved");
  return (
    <Group title="Library options" actions={<button className="glass-button prominent" disabled={busy || !dirty} onClick={() => void save()}>Save</button>}>
      <LibraryOptionsEditor contentType={folder.CollectionType} isNew={false} value={draft} onChange={setDraft} />
      {dirty && <div className="sticky-save"><span>Unsaved changes</span><button className="glass-button" onClick={() => { setDraft(JSON.parse(base!) as LibraryOptions); }}>Discard</button><button className="glass-button prominent" disabled={busy} onClick={() => void save()}>Save</button></div>}
    </Group>
  );
}

function LibraryEditPage({ name }: { name: string }) {
  const model = useModel();
  const api = model.api!;
  const { data, reload } = useLoad(async () => (await api.get<VirtualFolder[]>("/Library/VirtualFolders")).find((f) => f.Name === name) ?? null, [name]);
  const [browse, setBrowse] = useState(false);
  const { busy, run } = useAction();
  if (data === undefined) return <Spinner />;
  if (!data) return <Empty icon="folder" title="Library not found" />;
  return (
    <>
      <Group title="Folders" actions={<button className="glass-button" onClick={() => setBrowse(true)}><Icon name="plus" size={15} /> Add folder</button>}>
        <div className="rows">{(data.Locations ?? []).map((p) => (
          <div key={p} className="row static"><Icon name="folder" size={16} /><div className="row-text">{p}</div>
            <button className="link-button danger" disabled={busy} onClick={() => void run(async () => { await api.del("/Library/VirtualFolders/Paths", { name, path: p, refreshLibrary: true }); reload(); }, "Folder removed")}>Remove</button></div>
        ))}</div>
      </Group>
      <LibraryOptionsGroup folder={data} reload={reload} />
      <Group title="Manage">
        <div className="row-line">
          <button className="glass-button" disabled={busy} onClick={() => ui.openSheet({ kind: "prompt", title: "Rename library", label: "Name", initial: name, confirmLabel: "Rename", run: async (n) => { await api.post("/Library/VirtualFolders/Name", undefined, { name, newName: n, refreshLibrary: true }); ui.pop("dashboard"); } })}><Icon name="edit" size={15} /> Rename</button>
          <button className="glass-button" disabled={busy} onClick={() => data.ItemId && ui.openSheet({ kind: "refresh", item: { Id: data.ItemId, Name: name, Type: "CollectionFolder" } })}><Icon name="refresh" size={15} /> Refresh metadata…</button>
          <button className="glass-button danger" onClick={() => ui.openSheet({ kind: "confirm", danger: true, title: `Remove ${name}?`, text: "The library is removed from Jellyfin. Your files on disk are not deleted.", confirmLabel: "Remove", run: async () => { await api.del("/Library/VirtualFolders", { name, refreshLibrary: true }); ui.pop("dashboard"); } })}><Icon name="trash" size={15} /> Remove library</button>
        </div>
      </Group>
      {browse && <FolderPicker onPick={(p) => { setBrowse(false); void run(async () => { await api.post("/Library/VirtualFolders/Paths", { Name: name, PathInfo: { Path: p } }, { refreshLibrary: true }); reload(); }, "Folder added"); }} close={() => setBrowse(false)} />}
    </>
  );
}

// MARK: Devices & activity

function DevicesPage() {
  const model = useModel();
  const api = model.api!;
  const { data, reload } = useLoad(() => api.get<{ Items: DeviceInfo[] }>("/Devices"), []);
  const { busy, run } = useAction();
  if (!data) return <Spinner />;
  return (
    <>
      <div className="toolbar-row"><button className="glass-button danger" disabled={busy} onClick={() => ui.openSheet({ kind: "confirm", danger: true, title: "Sign out every other device?", text: "Every device except this one has to sign in again.", confirmLabel: "Sign out all", run: async () => { for (const d of data.Items) if (d.Id && d.Id !== api.deviceId) await api.del("/Devices", { id: d.Id }).catch(() => {}); reload(); } })}>Sign out all other devices</button></div>
      <div className="rows">{data.Items.map((d) => (
        <div key={d.Id} className="row static">
          <Icon name="devices" size={20} />
          <div className="row-text"><div className="row-title">{d.CustomName || d.Name}{d.Id === api.deviceId ? " (this PC)" : ""}</div><div className="row-sub">{d.AppName} {d.AppVersion} · {d.LastUserName} · {relativeTime(d.DateLastActivity)}</div></div>
          <button className="glass-button" onClick={() => ui.openSheet({ kind: "prompt", title: "Rename device", label: "Name", initial: d.CustomName || d.Name || "", run: async (n) => { await api.post("/Devices/Options", { CustomName: n }, { id: d.Id! }); reload(); } })}>Rename</button>
          {d.Id !== api.deviceId && <button className="glass-button danger" disabled={busy} onClick={() => void run(async () => { await api.del("/Devices", { id: d.Id! }); reload(); }, "Signed out")}>Sign out</button>}
        </div>
      ))}</div>
    </>
  );
}

function ActivityPage() {
  const model = useModel();
  const [filter, setFilter] = useState<"all" | "user" | "system">("all");
  const [page, setPage] = useState(0);
  const { data } = useLoad(() => model.api!.get<{ Items: ActivityLogEntry[]; TotalRecordCount: number }>("/System/ActivityLog/Entries", { startIndex: page * 100, limit: 100, hasUserId: filter === "all" ? undefined : filter === "user" }), [filter, page]);
  return (
    <>
      <div className="toolbar-row"><Segmented value={filter} options={[{ value: "all", label: "Everything" }, { value: "user", label: "Users" }, { value: "system", label: "System" }]} onChange={(v) => { setFilter(v); setPage(0); }} /></div>
      {!data ? <Spinner /> : <Group><ActivityRows entries={data.Items} /></Group>}
      {data && data.TotalRecordCount > 100 && (
        <div className="row-line center"><button className="glass-button" disabled={page === 0} onClick={() => setPage(page - 1)}>Newer</button><span className="muted small">Page {page + 1} of {Math.ceil(data.TotalRecordCount / 100)}</span><button className="glass-button" disabled={(page + 1) * 100 >= data.TotalRecordCount} onClick={() => setPage(page + 1)}>Older</button></div>
      )}
    </>
  );
}

// MARK: Live TV

function LiveTvPage() {
  const model = useModel();
  const api = model.api!;
  const { data: cfg, reload } = useLoad(() => api.get<{ TunerHosts?: { Id: string; Type: string; Url: string; FriendlyName?: string; TunerCount?: number }[]; ListingProviders?: { Id: string; Type: string; Path?: string; ListingsId?: string }[]; GuideDays?: number; RecordingPath?: string }>("/System/Configuration/livetv"), []);
  const { data: types } = useLoad(() => api.get<{ Name: string; Id: string }[]>("/LiveTv/TunerHosts/Types").catch(() => []), []);
  const { busy, run } = useAction();
  const addTuner = () => ui.openSheet({
    kind: "prompt", title: "Add a tuner (M3U URL or HDHomeRun address)", label: "Address", confirmLabel: "Add",
    run: async (url) => { await api.post("/LiveTv/TunerHosts", { Type: /^\d|hdhomerun/i.test(url) && !/\.m3u/i.test(url) ? "hdhomerun" : "m3u", Url: url, ImportFavoritesOnly: false, AllowHWTranscoding: true, EnableStreamLooping: false }); reload(); },
  });
  const addGuide = () => ui.openSheet({
    kind: "prompt", title: "Add an XMLTV guide", label: "XMLTV file path or URL", confirmLabel: "Add",
    run: async (path) => { await api.post("/LiveTv/ListingProviders", { Type: "xmltv", Path: path, EnableAllTuners: true }, { validateListings: false, validateLogin: false }); reload(); },
  });
  return (
    <>
      <Group title="Tuners" actions={<button className="glass-button" onClick={addTuner}><Icon name="plus" size={15} /> Add tuner</button>}>
        {types && <p className="muted small">Supported: {types.map((t) => t.Name).join(", ")}</p>}
        <div className="rows">{(cfg?.TunerHosts ?? []).map((t) => (
          <div key={t.Id} className="row static"><Icon name="live" size={18} /><div className="row-text"><div className="row-title">{t.FriendlyName || t.Url}</div><div className="row-sub">{t.Type} · {t.Url}</div></div>
            <button className="glass-button danger" disabled={busy} onClick={() => void run(async () => { await api.del("/LiveTv/TunerHosts", { id: t.Id }); reload(); }, "Removed")}>Remove</button></div>
        ))}</div>
      </Group>
      <Group title="TV guide" actions={<button className="glass-button" onClick={addGuide}><Icon name="plus" size={15} /> Add XMLTV</button>}>
        <div className="rows">{(cfg?.ListingProviders ?? []).map((l) => (
          <div key={l.Id} className="row static"><Icon name="calendar" size={18} /><div className="row-text"><div className="row-title">{l.Type}</div><div className="row-sub">{l.Path ?? l.ListingsId}</div></div>
            <button className="glass-button danger" disabled={busy} onClick={() => void run(async () => { await api.del("/LiveTv/ListingProviders", { id: l.Id }); reload(); }, "Removed")}>Remove</button></div>
        ))}</div>
        <button className="glass-button" disabled={busy} onClick={() => void run(async () => { const tasks = await api.get<TaskInfo[]>("/ScheduledTasks"); const t = tasks.find((x) => x.Key === "RefreshGuide"); if (t?.Id) await api.post(`/ScheduledTasks/Running/${t.Id}`); }, "Refreshing the guide")}><Icon name="refresh" size={15} /> Refresh guide data</button>
      </Group>
      <NamedConfigPage name="livetv" title="All Live TV options" curated={["GuideDays", "RecordingPath", "MovieRecordingPath", "SeriesRecordingPath", "EnableRecordingSubfolders", "EnableOriginalAudioWithEncodedRecordings", "PrePaddingSeconds", "PostPaddingSeconds", "RecordingPostProcessor", "RecordingPostProcessorArguments", "SaveRecordingNFO", "SaveRecordingImages"]} />
    </>
  );
}

// MARK: Plugins

function PluginsPage() {
  const model = useModel();
  const api = model.api!;
  const { data, reload } = useLoad(() => api.get<PluginInfo[]>("/Plugins"), []);
  const { busy, run } = useAction();
  if (!data) return <Spinner />;
  return (
    <>
      <div className="toolbar-row"><button className="glass-button" onClick={() => open("catalog")}><Icon name="download" size={15} /> Plugin catalog</button></div>
      <div className="plugin-grid">{data.map((p) => (
        <div key={`${p.Id}-${p.Version}`} className="plugin panel">
          <Cover url={p.HasImage ? api.url(`/Plugins/${p.Id}/${p.Version}/Image`) : undefined} width="100%" height={110} radius={10} icon="puzzle" />
          <strong>{p.Name}</strong>
          <span className="muted small">{p.Version} · <span className={p.Status === "Active" ? "score-good" : p.Status === "Malfunctioned" || p.Status === "NotSupported" ? "score-low" : "muted"}>{p.Status}</span></span>
          <span className="muted small clamp-3">{p.Description}</span>
          <div className="row-line wrap">
            <button className="glass-button" onClick={() => open("plugin", p.Id)}><Icon name="settings" size={14} /> Settings</button>
            {p.Status === "Disabled" ? <button className="glass-button" disabled={busy} onClick={() => void run(async () => { await api.post(`/Plugins/${p.Id}/${p.Version}/Enable`); reload(); }, "Enabled after a restart")}>Enable</button>
              : <button className="glass-button" disabled={busy} onClick={() => void run(async () => { await api.post(`/Plugins/${p.Id}/${p.Version}/Disable`); reload(); }, "Disabled after a restart")}>Disable</button>}
            {p.CanUninstall && <button className="glass-button danger" disabled={busy} onClick={() => ui.openSheet({ kind: "confirm", danger: true, title: `Uninstall ${p.Name}?`, text: "It's removed when the server restarts.", confirmLabel: "Uninstall", run: async () => { await api.del(`/Plugins/${p.Id}/${p.Version}`); reload(); } })}>Uninstall</button>}
          </div>
        </div>
      ))}</div>
    </>
  );
}

function PluginPage({ id }: { id: string }) {
  const model = useModel();
  const api = model.api!;
  const { data: pages } = useLoad(() => api.get<{ Name: string; PluginId: string; DisplayName?: string }[]>("/web/ConfigurationPages", { enableInMainMenu: undefined }).catch(() => []), []);
  const mine = pages?.filter((p) => p.PluginId?.replace(/-/g, "") === id.replace(/-/g, "")) ?? [];
  return (
    <>
      <ConfigEditor title="Settings" load={() => api.get<Record<string, unknown>>(`/Plugins/${id}/Configuration`)} save={(v) => api.post(`/Plugins/${id}/Configuration`, v)} />
      {mine.length > 0 && (
        <Group title="Plugin pages">
          <p className="muted small">This plugin also has its own settings page made for the web dashboard.</p>
          {mine.map((p) => <button key={p.Name} className="glass-button" onClick={async () => { const { openUrl } = await import("@tauri-apps/plugin-opener"); await openUrl(`${api.server}/web/#/configurationpage?name=${encodeURIComponent(p.Name)}`); }}><Icon name="external" size={14} /> Open {p.DisplayName ?? p.Name} in the browser</button>)}
        </Group>
      )}
    </>
  );
}

function CatalogPage() {
  const model = useModel();
  const api = model.api!;
  const { data, error } = useLoad(() => api.get<PackageInfo[]>("/Packages"), []);
  const { data: installed } = useLoad(() => api.get<PluginInfo[]>("/Plugins"), []);
  const [q, setQ] = useState("");
  const { busy, run } = useAction();
  if (error) return <ErrorNote text={error} />;
  if (!data) return <Spinner />;
  const cats = [...new Set(data.map((p) => p.category))].sort();
  const match = (p: PackageInfo) => !q || `${p.name} ${p.description} ${p.overview}`.toLowerCase().includes(q.toLowerCase());
  return (
    <>
      <input className="search-input" placeholder="Search plugins" value={q} onChange={(e) => setQ(e.target.value)} />
      {cats.map((c) => {
        const list = data.filter((p) => p.category === c && match(p));
        if (!list.length) return null;
        return (
          <section key={c}>
            <h2 className="section-title">{c}</h2>
            <div className="plugin-grid">{list.map((p) => {
              const have = installed?.find((i) => i.Id.replace(/-/g, "") === p.guid.replace(/-/g, ""));
              const latest = p.versions[0];
              return (
                <div key={p.guid} className="plugin panel">
                  <Cover url={p.imageUrl ?? undefined} width="100%" height={110} radius={10} icon="puzzle" />
                  <strong>{p.name}</strong>
                  <span className="muted small clamp-3">{p.overview || p.description}</span>
                  <span className="muted small">{latest?.version} · {latest?.repositoryName}</span>
                  {have ? <span className="chip chip-muted">Installed {have.Version}{latest && latest.version !== have.Version ? ` (update ${latest.version})` : ""}</span> : null}
                  {(!have || (latest && latest.version !== have.Version)) && latest && (
                    <button className="glass-button prominent" disabled={busy} onClick={() => void run(() => api.post(`/Packages/Installed/${encodeURIComponent(p.name)}`, undefined, { assemblyGuid: p.guid, version: latest.version, repositoryUrl: latest.repositoryUrl }), `${p.name} installs; restart the server to finish`)}>{have ? "Update" : "Install"}</button>
                  )}
                </div>
              );
            })}</div>
          </section>
        );
      })}
    </>
  );
}

function RepositoriesPage() {
  const model = useModel();
  const api = model.api!;
  const { data, reload } = useLoad(() => api.get<RepositoryInfo[]>("/Repositories"), []);
  const { busy, run } = useAction();
  const save = (list: RepositoryInfo[]) => run(async () => { await api.post("/Repositories", list); reload(); }, "Saved");
  if (!data) return <Spinner />;
  return (
    <Group title="Plugin repositories" actions={<button className="glass-button" onClick={() => ui.openSheet({ kind: "prompt", title: "Add repository", label: "Manifest URL", confirmLabel: "Add", run: async (url) => { await api.post("/Repositories", [...data, { Name: new URL(url).hostname, Url: url, Enabled: true }]); reload(); } })}><Icon name="plus" size={15} /> Add</button>}>
      <div className="rows">{data.map((r, i) => (
        <div key={r.Url ?? i} className="row static">
          <input type="checkbox" className="switch" checked={r.Enabled} onChange={(e) => void save(data.map((x, j) => (j === i ? { ...x, Enabled: e.target.checked } : x)))} />
          <div className="row-text"><div className="row-title">{r.Name}</div><div className="row-sub">{r.Url}</div></div>
          <button className="glass-button danger" disabled={busy} onClick={() => void save(data.filter((_, j) => j !== i))}>Remove</button>
        </div>
      ))}</div>
    </Group>
  );
}

// MARK: Tasks

function TasksPage() {
  const model = useModel();
  const api = model.api!;
  const [tasks, setTasks] = useState<TaskInfo[] | null>(null);
  useEffect(() => {
    const load = () => api.get<TaskInfo[]>("/ScheduledTasks", { isHidden: false }).then(setTasks).catch((e) => model.fail(e));
    void load();
    const socket = getSocket();
    socket?.send("ScheduledTasksInfoStart", "0,1000");
    const off = socket?.on("ScheduledTasksInfo", (d) => setTasks((d as TaskInfo[]).filter((t) => !t.IsHidden)));
    const t = setInterval(load, 4000);
    return () => { clearInterval(t); off?.(); socket?.send("ScheduledTasksInfoStop"); };
  }, [api, model]);
  if (!tasks) return <Spinner />;
  const cats = [...new Set(tasks.map((t) => t.Category ?? "Other"))].sort();
  const toggle = (t: TaskInfo) => (t.State === "Running" ? api.del(`/ScheduledTasks/Running/${t.Id}`) : api.post(`/ScheduledTasks/Running/${t.Id}`)).catch((e) => model.fail(e));
  return (
    <>{cats.map((c) => (
      <Group key={c} title={c}>
        {tasks.filter((t) => (t.Category ?? "Other") === c).map((t) => (
          <div key={t.Id} className="task-row">
            <button className="task-text" onClick={() => open("task", t.Id ?? "")}>
              <strong>{t.Name}</strong>
              <span className="muted small">{t.State === "Running" ? `Running ${Math.round(t.CurrentProgressPercentage ?? 0)}%` : t.LastExecutionResult ? `${t.LastExecutionResult.Status} ${relativeTime(t.LastExecutionResult.EndTimeUtc)}` : "Never run"}</span>
              {t.State === "Running" && <div className="progress"><div style={{ width: `${t.CurrentProgressPercentage ?? 0}%` }} /></div>}
            </button>
            <button className="round-button" onClick={() => void toggle(t)} title={t.State === "Running" ? "Stop" : "Run now"}><Icon name={t.State === "Running" ? "x" : "playFill"} size={14} /></button>
          </div>
        ))}
      </Group>
    ))}</>
  );
}

function TaskPage({ id }: { id: string }) {
  const model = useModel();
  const api = model.api!;
  const { data: task, reload } = useLoad(() => api.get<TaskInfo>(`/ScheduledTasks/${id}`), [id]);
  const [adding, setAdding] = useState(false);
  const { busy, run } = useAction();
  if (!task) return <Spinner />;
  const saveTriggers = (triggers: TaskTrigger[]) => run(async () => { await api.post(`/ScheduledTasks/${id}/Triggers`, triggers); reload(); }, "Saved");
  const describe = (t: TaskTrigger) => {
    const time = (ticks?: number | null) => clock(ticksToSeconds(ticks ?? 0)).replace(/:00$/, "");
    if (t.Type === "DailyTrigger") return `Every day at ${time(t.TimeOfDayTicks)}`;
    if (t.Type === "WeeklyTrigger") return `Every ${t.DayOfWeek} at ${time(t.TimeOfDayTicks)}`;
    if (t.Type === "IntervalTrigger") return `Every ${Math.round(ticksToSeconds(t.IntervalTicks ?? 0) / 3600 * 10) / 10} hours`;
    return "When the server starts";
  };
  return (
    <>
      <Group title={task.Name ?? "Task"}>
        <p className="muted">{task.Description}</p>
        {task.LastExecutionResult && <p className="small">Last run: {task.LastExecutionResult.Status} · {dateTime(task.LastExecutionResult.StartTimeUtc)} ({Math.round((Date.parse(task.LastExecutionResult.EndTimeUtc) - Date.parse(task.LastExecutionResult.StartTimeUtc)) / 1000)}s){task.LastExecutionResult.ErrorMessage ? ` · ${task.LastExecutionResult.ErrorMessage}` : ""}</p>}
        <button className="glass-button prominent" onClick={() => void api.post(`/ScheduledTasks/Running/${id}`).then(() => model.toast("Started", "success")).catch((e) => model.fail(e))}><Icon name="playFill" size={14} /> Run now</button>
      </Group>
      <Group title="When it runs" actions={<button className="glass-button" onClick={() => setAdding(true)}><Icon name="plus" size={15} /> Add</button>}>
        {!task.Triggers?.length && <p className="muted small">Only when started by hand.</p>}
        <div className="rows">{(task.Triggers ?? []).map((t, i) => (
          <div key={i} className="row static"><Icon name="clock" size={16} /><div className="row-text">{describe(t)}{t.MaxRuntimeTicks ? ` · max ${Math.round(ticksToSeconds(t.MaxRuntimeTicks) / 3600)}h` : ""}</div>
            <button className="glass-button danger" disabled={busy} onClick={() => void saveTriggers((task.Triggers ?? []).filter((_, j) => j !== i))}>Remove</button></div>
        ))}</div>
      </Group>
      {adding && <AddTrigger close={() => setAdding(false)} onAdd={(t) => { setAdding(false); void saveTriggers([...(task.Triggers ?? []), t]); }} />}
    </>
  );
}

function AddTrigger({ close, onAdd }: { close: () => void; onAdd: (t: TaskTrigger) => void }) {
  const [type, setType] = useState<TaskTrigger["Type"]>("DailyTrigger");
  const [time, setTime] = useState("03:00");
  const [day, setDay] = useState("Sunday");
  const [hours, setHours] = useState(24);
  const [maxHours, setMaxHours] = useState(0);
  const ticks = () => { const [h, m] = time.split(":").map(Number); return secondsToTicks(h * 3600 + m * 60); };
  return (
    <Modal title="Add a schedule" onClose={close} width={440}>
      <div className="form">
        <Segmented value={type} options={[{ value: "DailyTrigger", label: "Daily" }, { value: "WeeklyTrigger", label: "Weekly" }, { value: "IntervalTrigger", label: "Interval" }, { value: "StartupTrigger", label: "At startup" }]} onChange={setType} />
        {(type === "DailyTrigger" || type === "WeeklyTrigger") && <Field label="Time"><input type="time" value={time} onChange={(e) => setTime(e.target.value)} /></Field>}
        {type === "WeeklyTrigger" && <Field label="Day"><select value={day} onChange={(e) => setDay(e.target.value)}>{["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"].map((d) => <option key={d}>{d}</option>)}</select></Field>}
        {type === "IntervalTrigger" && <Field label="Every (hours)"><input type="number" min={0.25} step={0.25} value={hours} onChange={(e) => setHours(Number(e.target.value))} /></Field>}
        <Field label="Stop after (hours, 0 = no limit)"><input type="number" min={0} value={maxHours} onChange={(e) => setMaxHours(Number(e.target.value))} /></Field>
        <button className="glass-button prominent" onClick={() => onAdd({
          Type: type, TimeOfDayTicks: type === "DailyTrigger" || type === "WeeklyTrigger" ? ticks() : undefined, DayOfWeek: type === "WeeklyTrigger" ? day : undefined,
          IntervalTicks: type === "IntervalTrigger" ? secondsToTicks(hours * 3600) : undefined, MaxRuntimeTicks: maxHours ? secondsToTicks(maxHours * 3600) : undefined,
        })}>Add</button>
      </div>
    </Modal>
  );
}

// MARK: API keys, logs, backups

function ApiKeysPage() {
  const model = useModel();
  const api = model.api!;
  const { data, reload } = useLoad(() => api.get<{ Items: ApiKey[] }>("/Auth/Keys"), []);
  const { busy, run } = useAction();
  const [shown, setShown] = useState<Set<string>>(new Set());
  if (!data) return <Spinner />;
  return (
    <Group title="API keys" actions={<button className="glass-button" onClick={() => ui.openSheet({ kind: "prompt", title: "New API key", label: "App name", confirmLabel: "Create", run: async (app) => { await api.post("/Auth/Keys", undefined, { app }); reload(); } })}><Icon name="plus" size={15} /> New key</button>}>
      <p className="muted small">Keys let other apps (e.g. Sonarr, Jellyseerr, Home Assistant) use the server.</p>
      <div className="rows">{data.Items.map((k) => (
        <div key={k.AccessToken} className="row static">
          <Icon name="key2" size={18} />
          <div className="row-text"><div className="row-title">{k.AppName}</div><div className="row-sub mono">{shown.has(k.AccessToken) ? k.AccessToken : "••••••••••••••••"} · created {dateTime(k.DateCreated)}</div></div>
          <button className="glass-button" onClick={() => setShown(new Set([...shown, k.AccessToken]))}>Show</button>
          <button className="glass-button" onClick={() => void navigator.clipboard.writeText(k.AccessToken).then(() => model.toast("Copied", "success"))}><Icon name="copy" size={14} /></button>
          <button className="glass-button danger" disabled={busy} onClick={() => ui.openSheet({ kind: "confirm", danger: true, title: `Revoke ${k.AppName}'s key?`, text: "Apps using it stop working.", confirmLabel: "Revoke", run: async () => { await api.del(`/Auth/Keys/${k.AccessToken}`); reload(); } })}>Revoke</button>
        </div>
      ))}</div>
      {!data.Items.length && <p className="muted">No keys yet.</p>}
      {busy && <Spinner />}
      {run.length < 0 && null}
    </Group>
  );
}

function LogsPage() {
  const model = useModel();
  const { data } = useLoad(() => model.api!.get<LogFile[]>("/System/Logs"), []);
  if (!data) return <Spinner />;
  return (
    <div className="rows">{[...data].sort((a, b) => Date.parse(b.DateModified) - Date.parse(a.DateModified)).map((l) => (
      <button key={l.Name} className="row" onClick={() => open("log", l.Name)}>
        <Icon name="terminal" size={18} /><div className="row-text"><div className="row-title">{l.Name}</div><div className="row-sub">{bytes(l.Size)} · {dateTime(l.DateModified)}</div></div>
      </button>
    ))}</div>
  );
}

function LogPage({ name }: { name: string }) {
  const model = useModel();
  const api = model.api!;
  const { data, error } = useLoad(() => api.request<string>("GET", "/System/Logs/Log", { query: { name }, text: true }), [name]);
  const [q, setQ] = useState("");
  const [level, setLevel] = useState<"all" | "WRN" | "ERR">("all");
  const lines = useMemo(() => (data ?? "").split("\n").filter((l) => (!q || l.toLowerCase().includes(q.toLowerCase())) && (level === "all" || l.includes(`[${level}]`) || (level === "WRN" && l.includes("[ERR]")))), [data, q, level]);
  const save = async () => {
    try {
      const { save: dialog } = await import("@tauri-apps/plugin-dialog");
      const path = await dialog({ defaultPath: name });
      if (path) { await writeTextFile(path, data ?? ""); model.toast("Saved", "success"); }
    } catch (e) { model.fail(e); }
  };
  if (error) return <ErrorNote text={error} />;
  if (data === undefined) return <Spinner />;
  return (
    <>
      <div className="toolbar-row">
        <input className="search-input" placeholder="Filter" value={q} onChange={(e) => setQ(e.target.value)} />
        <Segmented value={level} options={[{ value: "all", label: "All" }, { value: "WRN", label: "Warnings+" }, { value: "ERR", label: "Errors" }]} onChange={setLevel} />
        <button className="glass-button" onClick={() => void save()}><Icon name="download" size={15} /> Save</button>
      </div>
      <pre className="log">{lines.slice(-5000).map((l, i) => <div key={i} className={l.includes("[ERR]") || l.includes("[FTL]") ? "err" : l.includes("[WRN]") ? "wrn" : ""}>{l}</div>)}</pre>
    </>
  );
}

function BackupsPage() {
  const model = useModel();
  const api = model.api!;
  const { data, error, reload } = useLoad(() => api.backups(), []);
  const [opts, setOpts] = useState<BackupOptions>({ Metadata: true, Trickplay: false, Subtitles: true, Database: true });
  const { busy, run } = useAction();
  return (
    <>
      <Group title="Create a backup" actions={<button className="glass-button prominent" disabled={busy} onClick={() => void run(async () => { await api.createBackup(opts); reload(); }, "Backup created")}>{busy ? <span className="spinner small" /> : "Create backup"}</button>}>
        <Toggle label="Database (users, watch history, settings)" checked={opts.Database} onChange={(v) => setOpts({ ...opts, Database: v })} />
        <Toggle label="Metadata and images" checked={opts.Metadata} onChange={(v) => setOpts({ ...opts, Metadata: v })} />
        <Toggle label="Subtitles" checked={opts.Subtitles} onChange={(v) => setOpts({ ...opts, Subtitles: v })} />
        <Toggle label="Trickplay images" detail="Large" checked={opts.Trickplay} onChange={(v) => setOpts({ ...opts, Trickplay: v })} />
      </Group>
      <Group title="Backups on the server">
        {error ? <ErrorNote text={error} /> : !data ? <Spinner /> : !data.length ? <p className="muted">No backups yet.</p> : (
          <div className="rows">{[...data].sort((a, b) => Date.parse(b.DateCreated) - Date.parse(a.DateCreated)).map((b: BackupManifest) => (
            <div key={b.Path} className="row static">
              <Icon name="archive" size={18} />
              <div className="row-text"><div className="row-title">{dateTime(b.DateCreated)}</div><div className="row-sub">Jellyfin {b.ServerVersion} · {Object.entries(b.Options ?? {}).filter(([, v]) => v).map(([k]) => k).join(", ")} · {b.Path}</div></div>
              <button className="glass-button danger" disabled={busy} onClick={() => ui.openSheet({ kind: "confirm", danger: true, title: "Restore this backup?", text: "The server restarts and replaces its current data with this backup.", confirmLabel: "Restore", run: () => api.restoreBackup(b.Path) })}>Restore</button>
            </div>
          ))}</div>
        )}
      </Group>
    </>
  );
}

export type { ReactNode };
