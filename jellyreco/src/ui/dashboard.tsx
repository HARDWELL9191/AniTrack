// The admin Dashboard, organized like jellyfin-web's: a menu of categories on the left (Server,
// Playback, Devices, Live TV, Plugins, Advanced) and the chosen page on the right. Settings pages
// have the same sections, options and conditions as jellyfin-web, with switches, dropdowns and
// pickers instead of typing values in (see serverpages.tsx).

import { LibraryOptionsEditor, type LibraryOptions } from "./libraryadmin";
import { type ReactNode, useEffect, useMemo, useRef, useState, useSyncExternalStore } from "react";
import { getSocket } from "../core/socket";
import type {
  ActivityLogEntry, ApiKey, BackupManifest, BackupOptions, DeviceInfo, LogFile, PackageInfo, PluginInfo, RepositoryInfo,
  SessionInfo, TaskInfo, TaskTrigger, User, UserPolicy, VirtualFolder,
} from "../core/types";
import { secondsToTicks, ticksToSeconds } from "../core/types";
import { cardImage, Cover, Empty, ErrorNote, Field, Group, Modal, PageHeader, Segmented, Spinner, Toggle, useAction, useLoad } from "./components";
import { FolderPicker, TagInput } from "./configform";
import { bitrate, bytes, clock, dateTime, relativeTime } from "./fmt";
import { Icon } from "./icons";
import { writeTextFile } from "./native";
import { ServerSettingsPage, SERVER_PAGES } from "./serverpages";
import { ui, useModel } from "./state";

// jellyfin-web's dashboard menu, in its order.
const NAV: { group: string; items: { id: string; label: string; icon: string }[] }[] = [
  { group: "Server", items: [
    { id: "overview", label: "Dashboard", icon: "dashboard" },
    { id: "general", label: "General", icon: "settings" },
    { id: "branding", label: "Branding", icon: "palette" },
    { id: "users", label: "Users", icon: "users" },
  ] },
  { group: "Libraries", items: [
    { id: "libraries", label: "Libraries", icon: "folder" },
    { id: "display", label: "Display", icon: "grid" },
    { id: "metadata", label: "Metadata", icon: "tag" },
    { id: "nfo", label: "NFO settings", icon: "edit" },
  ] },
  { group: "Playback", items: [
    { id: "transcoding", label: "Transcoding", icon: "zap" },
    { id: "resume", label: "Resume", icon: "play" },
    { id: "streaming", label: "Streaming", icon: "network" },
    { id: "trickplay", label: "Trickplay", icon: "image" },
  ] },
  { group: "Devices", items: [
    { id: "devices", label: "Devices", icon: "devices" },
    { id: "activity", label: "Activity", icon: "activity" },
  ] },
  { group: "Live TV", items: [
    { id: "livetv", label: "Live TV", icon: "live" },
    { id: "dvr", label: "DVR", icon: "calendar" },
  ] },
  { group: "Plugins", items: [
    { id: "plugins", label: "My plugins", icon: "puzzle" },
    { id: "catalog", label: "Catalog", icon: "download" },
    { id: "repositories", label: "Repositories", icon: "link" },
  ] },
  { group: "Advanced", items: [
    { id: "networking", label: "Networking", icon: "network" },
    { id: "apikeys", label: "API keys", icon: "key2" },
    { id: "backups", label: "Backups", icon: "archive" },
    { id: "logs", label: "Logs", icon: "terminal" },
    { id: "tasks", label: "Scheduled tasks", icon: "clock" },
  ] },
];
const NAV_ITEMS = NAV.flatMap((g) => g.items);

// The chosen menu item (kept while you move around the app).
let section = "overview";
const listeners = new Set<() => void>();
function useSection() {
  return useSyncExternalStore((fn) => { listeners.add(fn); return () => listeners.delete(fn); }, () => section);
}
function choose(id: string) {
  section = id;
  listeners.forEach((fn) => fn());
  ui.popToRoot("dashboard");
}

/** Opens a menu page, or a page inside one (a user, a library, a plugin, a task, a log). */
function open(page: string, arg?: string) {
  if (!arg && NAV_ITEMS.some((i) => i.id === page)) choose(page);
  else ui.push("dashboard", { kind: "dashboard", page, arg });
}

export function DashboardRoot() {
  const current = useSection();
  const item = NAV_ITEMS.find((i) => i.id === current) ?? NAV_ITEMS[0];
  const top = useRef<HTMLDivElement>(null);
  // A new page starts at the top.
  useEffect(() => { top.current?.closest(".scroll")?.scrollTo({ top: 0 }); }, [item.id]);
  return (
    <div className="page" ref={top}>
      <PageHeader title={item.id === "overview" ? "Dashboard" : item.label} subtitle={item.id === "overview" ? undefined : NAV.find((g) => g.items.includes(item))?.group} />
      <div className="settings-layout dash-layout">
        <nav className="settings-nav dash-nav">
          {NAV.map((g) => (
            <div key={g.group} className="nav-group">
              <div className="nav-group-title">{g.group}</div>
              {g.items.map((i) => <button key={i.id} className={`nav-item ${i.id === item.id ? "on" : ""}`} onClick={() => choose(i.id)}><Icon name={i.icon} size={17} /> {i.label}</button>)}
            </div>
          ))}
        </nav>
        <div className="settings-body dash-body" key={item.id}>
          {item.id === "overview" ? <Overview /> : <SectionPage page={item.id} />}
        </div>
      </div>
    </div>
  );
}

// MARK: Overview

function Overview() {
  const model = useModel();
  const api = model.api!;
  const { data: info, reload: reloadInfo } = useLoad(() => api.systemInfo(), []);
  const { data: storage } = useLoad(() => api.get<{ ProgramDataFolder?: Folder; CacheFolder?: Folder; LogFolder?: Folder; TranscodingTempFolder?: Folder; LibraryFolders?: Folder[] }>("/System/Info/Storage").catch(() => null), []);
  const { busy, run } = useAction();
  return (
    <>
      <div className="toolbar-row">
        {info?.ServerName && <span className="muted">{info.ServerName}{info.Version ? ` · Jellyfin ${info.Version}` : ""}</span>}
        <div className="toolbar-spacer" />
        <button className="glass-button" disabled={busy} onClick={() => void run(() => api.post("/Library/Refresh"), "Scanning all libraries")}><Icon name="refresh" size={15} /> Scan all libraries</button>
        <button className="glass-button" onClick={() => ui.openSheet({ kind: "confirm", title: "Restart the server?", text: "Playback on every device stops for a moment.", confirmLabel: "Restart", run: async () => { await api.post("/System/Restart"); model.toast("Restarting…"); setTimeout(reloadInfo, 15000); } })}><Icon name="repeat" size={15} /> Restart</button>
        <button className="glass-button danger" onClick={() => ui.openSheet({ kind: "confirm", danger: true, title: "Shut down the server?", text: "You'll need to start it again on the server machine.", confirmLabel: "Shut down", run: () => api.post("/System/Shutdown") })}><Icon name="power" size={15} /> Shut down</button>
      </div>
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
    </>
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

/** A page from the menu. */
function SectionPage({ page }: { page: string }) {
  if (SERVER_PAGES.includes(page)) return <ServerSettingsPage page={page} />;
  switch (page) {
    case "users": return <UsersPage />;
    case "libraries": return <LibrariesPage />;
    case "devices": return <DevicesPage />;
    case "activity": return <ActivityPage />;
    case "livetv": return <LiveTvPage />;
    case "plugins": return <PluginsPage />;
    case "catalog": return <CatalogPage />;
    case "repositories": return <RepositoriesPage />;
    case "tasks": return <TasksPage />;
    case "apikeys": return <ApiKeysPage />;
    case "logs": return <LogsPage />;
    case "backups": return <BackupsPage />;
    default: return null;
  }
}

/** A page inside a menu page (opened on top of the Dashboard, with a back button). */
export function DashboardPage({ page, arg, back }: { page: string; arg?: string; back: () => void }) {
  const title = page === "user" ? "User" : page === "library" ? arg ?? "Library" : page === "plugin" ? "Plugin" : page === "task" ? "Scheduled task" : page === "log" ? arg ?? "Log" : NAV_ITEMS.find((i) => i.id === page)?.label ?? page;
  return (
    <div className="page">
      <PageHeader title={title} back={back} />
      <div className="dash-sub">
        {page === "user" && arg && <UserPage id={arg} />}
        {page === "library" && arg && <LibraryEditPage name={arg} />}
        {page === "plugin" && arg && <PluginPage id={arg} />}
        {page === "task" && arg && <TaskPage id={arg} />}
        {page === "log" && arg && <LogPage name={arg} />}
        {!arg && <SectionPage page={page} />}
      </div>
    </div>
  );
}

// MARK: Plugin settings (each plugin has its own options, so they're read from its config)

function label(key: string) {
  return key.replace(/([a-z0-9])([A-Z])/g, "$1 $2").replace(/([A-Z]+)([A-Z][a-z])/g, "$1 $2").replace(/^./, (c) => c.toUpperCase());
}

/** Edits one JSON object: switches, numbers, text, lists as chips; nested objects open in place. */
function ObjectEditor({ value, onChange }: { value: Record<string, unknown>; onChange: (v: Record<string, unknown>) => void }) {
  return (
    <div className="form">
      {Object.keys(value).map((k) => <ValueEditor key={k} name={k} value={value[k]} onChange={(v) => onChange({ ...value, [k]: v })} />)}
    </div>
  );
}

function ValueEditor({ name, value, onChange }: { name: string; value: unknown; onChange: (v: unknown) => void }) {
  const [open, setOpen] = useState(false);
  if (typeof value === "boolean") return <Toggle label={label(name)} checked={value} onChange={onChange} />;
  if (typeof value === "number") return <Field label={label(name)}><input type="number" step="any" value={value} onChange={(e) => onChange(e.target.value === "" ? 0 : Number(e.target.value))} /></Field>;
  if (typeof value === "string" || value === null) {
    const long = /css|script|template|description/i.test(name) || (typeof value === "string" && (value.length > 120 || value.includes("\n")));
    return <Field label={label(name)}>{long ? <textarea rows={6} value={value ?? ""} onChange={(e) => onChange(e.target.value)} /> : <input value={value ?? ""} onChange={(e) => onChange(e.target.value)} type={/password|secret|token|apikey/i.test(name) ? "password" : "text"} autoComplete="off" spellCheck={false} />}</Field>;
  }
  if (Array.isArray(value)) {
    if (value.every((x) => typeof x === "string" || typeof x === "number")) {
      return <Field label={label(name)}><TagInput value={value as (string | number)[]} numeric={value.length > 0 && typeof value[0] === "number"} onChange={onChange} /></Field>;
    }
    return (
      <div className="nested">
        <button className="text-button" onClick={() => setOpen(!open)}><Icon name={open ? "chevronDown" : "chevronRight"} size={14} /> {label(name)} <span className="muted small">({value.length})</span></button>
        {open && value.map((v, i) => (
          <div key={i} className="nested-item">
            {v && typeof v === "object" ? <ObjectEditor value={v as Record<string, unknown>} onChange={(nv) => onChange(value.map((x, j) => (j === i ? nv : x)))} /> : <ValueEditor name={`${name} ${i + 1}`} value={v} onChange={(nv) => onChange(value.map((x, j) => (j === i ? nv : x)))} />}
            <button className="link-button small danger" onClick={() => onChange(value.filter((_, j) => j !== i))}>Remove</button>
          </div>
        ))}
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

function PluginConfig({ id }: { id: string }) {
  const model = useModel();
  const api = model.api!;
  const { data, error, reload } = useLoad(() => api.get<Record<string, unknown>>(`/Plugins/${id}/Configuration`), [id]);
  const [draft, setDraft] = useState<Record<string, unknown> | null>(null);
  useEffect(() => { if (data) setDraft(structuredClone(data)); }, [data]);
  const { busy, run } = useAction();
  const dirty = useMemo(() => JSON.stringify(draft) !== JSON.stringify(data), [draft, data]);
  if (error) return <ErrorNote text={error} retry={reload} />;
  if (!draft) return <Spinner />;
  const save = () => run(async () => { await api.post(`/Plugins/${id}/Configuration`, draft); reload(); }, "Saved");
  return (
    <Group title="Settings">
      {Object.keys(draft).length ? <ObjectEditor value={draft} onChange={setDraft} /> : <p className="muted">This plugin has no settings.</p>}
      <div className={`form-actions ${dirty ? "sticky-save" : ""}`}>
        {dirty && <span>Unsaved changes</span>}
        {dirty && <button className="glass-button" onClick={() => setDraft(structuredClone(data!))}>Discard</button>}
        <button className="glass-button prominent" disabled={busy || !dirty} onClick={() => void save()}>Save</button>
      </div>
    </Group>
  );
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

const UNRATED = [
  { value: "Book", label: "Books" }, { value: "ChannelContent", label: "Channels" }, { value: "LiveTvChannel", label: "Live TV" }, { value: "Movie", label: "Movies" },
  { value: "Music", label: "Music" }, { value: "Trailer", label: "Trailers" }, { value: "Series", label: "Shows" },
];
const DAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Everyday", "Weekday", "Weekend"];
const dayLabel = (d: string) => (d === "Everyday" ? "Every day" : d === "Weekday" ? "Weekdays" : d === "Weekend" ? "Weekends" : d);
const hourLabel = (h: number) => `${String(Math.floor(h) % 24).padStart(2, "0")}:${h % 1 ? "30" : "00"}`;
interface Schedule { DayOfWeek: string; StartHour: number; EndHour: number }
interface Rating { Name: string; Value?: number | null; RatingScore?: { score: number; subScore?: number | null } | null }

/** One user, in jellyfin-web's tabs: Profile, Access, Parental control, Password. */
function UserPage({ id }: { id: string }) {
  const model = useModel();
  const api = model.api!;
  const { data: user, reload } = useLoad(() => api.get<User>(`/Users/${id}`), [id]);
  const { data: views } = useLoad(() => api.get<{ Items: { Id: string; Name: string }[] }>("/Library/MediaFolders", { isHidden: false }), []);
  const { data: channels } = useLoad(() => api.get<{ Items: { Id: string; Name: string }[] }>("/Channels").catch(() => ({ Items: [] })), []);
  const { data: devices } = useLoad(() => api.get<{ Items: DeviceInfo[] }>("/Devices"), []);
  const { data: ratings } = useLoad(() => api.get<Rating[]>("/Localization/ParentalRatings"), []);
  const { data: authProviders } = useLoad(() => api.get<{ Name: string; Id: string }[]>("/Auth/Providers").catch(() => []), []);
  const { data: resetProviders } = useLoad(() => api.get<{ Name: string; Id: string }[]>("/Auth/PasswordResetProviders").catch(() => []), []);
  const [tab, setTab] = useState<"profile" | "access" | "parental" | "password">("profile");
  const [policy, setPolicy] = useState<UserPolicy | null>(null);
  const [name, setName] = useState("");
  const [pw, setPw] = useState("");
  const [pw2, setPw2] = useState("");
  useEffect(() => { if (user) { setPolicy(structuredClone(user.Policy!)); setName(user.Name ?? ""); } }, [user]);
  const { busy, run } = useAction();
  if (!user || !policy) return <Spinner />;
  const P = (k: keyof UserPolicy, v: unknown) => setPolicy({ ...policy, [k]: v });
  const dirty = JSON.stringify(policy) !== JSON.stringify(user.Policy) || name !== (user.Name ?? "");
  const save = () => run(async () => {
    if (name !== user.Name) await api.post(`/Users/${id}`, { ...user, Name: name });
    await api.post(`/Users/${id}/Policy`, policy);
    reload();
  }, "Saved");
  const inList = (k: keyof UserPolicy, itemId: string) => ((policy[k] as string[] | null | undefined) ?? []).includes(itemId);
  const listToggle = (k: keyof UserPolicy, itemId: string, on: boolean) => {
    const list = new Set((policy[k] as string[] | null | undefined) ?? []);
    if (on) list.add(itemId); else list.delete(itemId);
    P(k, [...list]);
  };
  // jellyfin-web groups ratings with the same score ("PG-13/TV-14") and picks the highest the user may see.
  const grouped: { label: string; score: number; sub: number | null }[] = [];
  for (const r of ratings ?? []) {
    const score = r.RatingScore?.score ?? r.Value;
    if (score === null || score === undefined) continue;
    const sub = r.RatingScore?.subScore ?? null;
    const last = grouped[grouped.length - 1];
    if (last && last.score === score && last.sub === sub) last.label += `/${r.Name}`;
    else grouped.push({ label: r.Name, score, sub });
  }
  const maxSub = policy.MaxParentalSubRating ?? null;
  let ratingIdx = grouped.findIndex((g) => g.score === policy.MaxParentalRating && g.sub === maxSub);
  if (ratingIdx < 0 && policy.MaxParentalRating != null) grouped.forEach((g, i) => { if (g.score <= policy.MaxParentalRating!) ratingIdx = i; });
  const schedules = (policy.AccessSchedules ?? []) as Schedule[];
  const setSchedules = (v: Schedule[]) => P("AccessSchedules", v);
  const SaveBar = () => (
    <div className={`form-actions ${dirty ? "sticky-save" : ""}`}>
      {dirty && <span>Unsaved changes</span>}
      {dirty && <button className="glass-button" onClick={() => { setPolicy(structuredClone(user.Policy!)); setName(user.Name ?? ""); }}>Discard</button>}
      <button className="glass-button prominent" disabled={busy || !dirty} onClick={() => void save()}>Save</button>
    </div>
  );
  return (
    <>
      <div className="toolbar-row">
        <Segmented value={tab} options={[{ value: "profile", label: "Profile" }, { value: "access", label: "Access" }, { value: "parental", label: "Parental control" }, { value: "password", label: "Password" }]} onChange={setTab} />
        <div className="toolbar-spacer" />
        {id !== model.user?.Id && <button className="glass-button danger" onClick={() => ui.openSheet({ kind: "confirm", danger: true, title: `Delete ${user.Name}?`, text: "Their watch history and settings are deleted too.", confirmLabel: "Delete", run: async () => { await api.del(`/Users/${id}`); ui.pop("dashboard"); } })}><Icon name="trash" size={15} /> Delete user</button>}
      </div>
      {policy.IsDisabled && <div className="banner warn"><Icon name="info" size={15} /> This user is currently disabled. Turn off "Disable this user" to let them sign in again.</div>}
      {tab === "profile" && (
        <>
          <Group title="Profile">
            <Field label="Name"><input value={name} onChange={(e) => setName(e.target.value)} /></Field>
            {(authProviders?.length ?? 0) > 1 && <Field label="Authentication provider" hint="Checks this user's password."><select value={policy.AuthenticationProviderId ?? ""} onChange={(e) => P("AuthenticationProviderId", e.target.value)}>{authProviders!.map((a) => <option key={a.Id} value={a.Id}>{a.Name}</option>)}</select></Field>}
            {(resetProviders?.length ?? 0) > 1 && <Field label="Password reset provider" hint="Used when this user asks to reset their password."><select value={policy.PasswordResetProviderId ?? ""} onChange={(e) => P("PasswordResetProviderId", e.target.value)}>{resetProviders!.map((a) => <option key={a.Id} value={a.Id}>{a.Name}</option>)}</select></Field>}
            <Toggle label="Allow remote connections to this server" detail="Off blocks this user's connections from outside your network." checked={policy.EnableRemoteAccess} onChange={(v) => P("EnableRemoteAccess", v)} />
            <Toggle label="Allow this user to manage the server" checked={policy.IsAdministrator} onChange={(v) => P("IsAdministrator", v)} />
            <Toggle label="Allow this user to manage collections" checked={policy.EnableCollectionManagement} onChange={(v) => P("EnableCollectionManagement", v)} />
            <Toggle label="Allow this user to edit subtitles" checked={policy.EnableSubtitleManagement} onChange={(v) => P("EnableSubtitleManagement", v)} />
            {"EnableLyricManagement" in policy && <Toggle label="Allow this user to edit lyrics" checked={!!policy.EnableLyricManagement} onChange={(v) => P("EnableLyricManagement", v)} />}
          </Group>
          <Group title="Feature access">
            <Toggle label="Allow Live TV access" checked={policy.EnableLiveTvAccess} onChange={(v) => P("EnableLiveTvAccess", v)} />
            <Toggle label="Allow Live TV recording management" checked={policy.EnableLiveTvManagement} onChange={(v) => P("EnableLiveTvManagement", v)} />
          </Group>
          <Group title="Playback">
            <Toggle label="Allow media playback" checked={policy.EnableMediaPlayback} onChange={(v) => P("EnableMediaPlayback", v)} />
            <Toggle label="Allow audio playback that requires transcoding" checked={policy.EnableAudioPlaybackTranscoding} onChange={(v) => P("EnableAudioPlaybackTranscoding", v)} />
            <Toggle label="Allow video playback that requires transcoding" checked={policy.EnableVideoPlaybackTranscoding} onChange={(v) => P("EnableVideoPlaybackTranscoding", v)} />
            <Toggle label="Allow video playback that requires conversion without re-encoding" detail="Turning transcoding off may make some files fail to play on some apps." checked={policy.EnablePlaybackRemuxing} onChange={(v) => P("EnablePlaybackRemuxing", v)} />
            <Toggle label="Force transcoding of remote media sources such as Live TV" checked={policy.ForceRemoteSourceTranscoding} onChange={(v) => P("ForceRemoteSourceTranscoding", v)} />
            <Field label="Internet streaming bitrate limit (Mbps)" hint="Overrides the server's limit (Dashboard → Playback → Streaming). 0 = no limit."><input type="number" min={0} step={0.25} value={policy.RemoteClientBitrateLimit ? policy.RemoteClientBitrateLimit / 1e6 : 0} onChange={(e) => P("RemoteClientBitrateLimit", Math.trunc(Math.max(0, Number(e.target.value) || 0) * 1e6))} /></Field>
            <Field label="SyncPlay access" hint="Watching together in sync with other devices.">
              <select value={policy.SyncPlayAccess} onChange={(e) => P("SyncPlayAccess", e.target.value)}>
                <option value="CreateAndJoinGroups">Allow creating and joining groups</option>
                <option value="JoinGroups">Allow joining groups</option>
                <option value="None">No access</option>
              </select>
            </Field>
          </Group>
          <Group title="Allow media deletion from">
            <Toggle label="All libraries" checked={policy.EnableContentDeletion} onChange={(v) => P("EnableContentDeletion", v)} />
            {!policy.EnableContentDeletion && <div className="switch-grid">{views?.Items.map((v) => <Toggle key={v.Id} label={v.Name} checked={inList("EnableContentDeletionFromFolders", v.Id)} onChange={(on) => listToggle("EnableContentDeletionFromFolders", v.Id, on)} />)}</div>}
          </Group>
          <Group title="Remote control">
            <Toggle label="Allow remote control of other users" checked={policy.EnableRemoteControlOfOtherUsers} onChange={(v) => P("EnableRemoteControlOfOtherUsers", v)} />
            <Toggle label="Allow remote control of shared devices" detail="DLNA devices count as shared until a user starts controlling them." checked={policy.EnableSharedDeviceControl} onChange={(v) => P("EnableSharedDeviceControl", v)} />
          </Group>
          <Group title="Other">
            <Toggle label="Allow media downloading" detail="Save media on their devices (not the same as sync). Book libraries need this." checked={policy.EnableContentDownloading} onChange={(v) => P("EnableContentDownloading", v)} />
            <Toggle label="Disable this user" detail="The server refuses their connections and ends the open ones." checked={policy.IsDisabled} onChange={(v) => P("IsDisabled", v)} />
            <Toggle label="Hide this user from login screens" detail="For private or admin accounts: they sign in by typing their name and password." checked={policy.IsHidden} onChange={(v) => P("IsHidden", v)} />
            <Field label="Failed login tries before the user is locked out" hint="0 = the default (3 tries, 5 for administrators); -1 = never lock out."><input type="number" min={-1} value={policy.LoginAttemptsBeforeLockout} onChange={(e) => P("LoginAttemptsBeforeLockout", Math.max(-1, Math.trunc(Number(e.target.value) || 0)))} /></Field>
            <Field label="Maximum simultaneous sessions" hint="0 = no limit."><input type="number" min={0} value={policy.MaxActiveSessions} onChange={(e) => P("MaxActiveSessions", Math.max(0, Math.trunc(Number(e.target.value) || 0)))} /></Field>
          </Group>
          <SaveBar />
        </>
      )}
      {tab === "access" && (
        <>
          <Group title="Library access">
            <p className="group-help">The libraries this user can see. Administrators can edit every folder with the metadata manager.</p>
            <Toggle label="Enable access to all libraries" checked={policy.EnableAllFolders} onChange={(v) => P("EnableAllFolders", v)} />
            {!policy.EnableAllFolders && <div className="switch-grid">{views?.Items.map((v) => <Toggle key={v.Id} label={v.Name} checked={inList("EnabledFolders", v.Id)} onChange={(on) => listToggle("EnabledFolders", v.Id, on)} />)}</div>}
          </Group>
          {!!channels?.Items.length && (
            <Group title="Channel access">
              <Toggle label="Enable access to all channels" checked={policy.EnableAllChannels} onChange={(v) => P("EnableAllChannels", v)} />
              {!policy.EnableAllChannels && <div className="switch-grid">{channels.Items.map((c) => <Toggle key={c.Id} label={c.Name} checked={inList("EnabledChannels", c.Id)} onChange={(on) => listToggle("EnabledChannels", c.Id, on)} />)}</div>}
            </Group>
          )}
          {!policy.IsAdministrator && (
            <Group title="Device access">
              <p className="group-help">Only for devices that can be told apart; doesn't block browsers. With a list, new devices need approval here first.</p>
              <Toggle label="Enable access from all devices" checked={policy.EnableAllDevices} onChange={(v) => P("EnableAllDevices", v)} />
              {!policy.EnableAllDevices && <div className="switch-grid">{devices?.Items.map((d) => <Toggle key={d.Id} label={`${d.CustomName || d.Name} (${d.AppName})`} checked={inList("EnabledDevices", d.Id ?? "")} onChange={(on) => listToggle("EnabledDevices", d.Id ?? "", on)} />)}</div>}
            </Group>
          )}
          <SaveBar />
        </>
      )}
      {tab === "parental" && (
        <>
          <Group title="Maximum allowed parental rating">
            <Field label="Highest allowed rating" hint="Titles rated higher are hidden from this user.">
              <select value={ratingIdx < 0 ? "" : String(ratingIdx)} onChange={(e) => {
                const g = e.target.value === "" ? null : grouped[Number(e.target.value)];
                setPolicy({ ...policy, MaxParentalRating: g ? g.score : null, MaxParentalSubRating: g ? g.sub : null });
              }}>
                <option value="">No limit</option>
                {grouped.map((g, i) => <option key={i} value={i}>{g.label}</option>)}
              </select>
            </Field>
          </Group>
          <Group title="Block items with no or unrecognized rating">
            <div className="switch-grid">{UNRATED.map((t) => <Toggle key={t.value} label={t.label} checked={inList("BlockUnratedItems", t.value)} onChange={(on) => listToggle("BlockUnratedItems", t.value, on)} />)}</div>
          </Group>
          <Group title="Allow items with tags">
            <Field label="Tags" hint="Only show media with at least one of these tags. Empty = no limit."><TagInput value={policy.AllowedTags ?? []} onChange={(v) => P("AllowedTags", v.map(String))} placeholder="Add a tag" /></Field>
          </Group>
          <Group title="Block items with tags">
            <Field label="Tags" hint="Hide media with at least one of these tags."><TagInput value={policy.BlockedTags ?? []} onChange={(v) => P("BlockedTags", v.map(String))} placeholder="Add a tag" /></Field>
          </Group>
          {!policy.IsAdministrator && (
            <Group title="Access schedule" actions={<button className="glass-button" onClick={() => setSchedules([...schedules, { DayOfWeek: "Sunday", StartHour: 0, EndHour: 24 }])}><Icon name="plus" size={15} /> Add</button>}>
              <p className="group-help">Limit sign-ins to certain hours. With no schedule, the user can sign in any time.</p>
              {schedules.map((sc, i) => {
                const put = (patch: Partial<Schedule>) => setSchedules(schedules.map((x, j) => (j === i ? { ...x, ...patch } : x)));
                return (
                  <div key={i} className="schedule-row">
                    <select value={sc.DayOfWeek} onChange={(e) => put({ DayOfWeek: e.target.value })}>{DAYS.map((d) => <option key={d} value={d}>{dayLabel(d)}</option>)}</select>
                    <select value={sc.StartHour} onChange={(e) => put({ StartHour: Number(e.target.value) })}>{Array.from({ length: 48 }, (_, h) => h / 2).filter((h) => h < sc.EndHour).map((h) => <option key={h} value={h}>{hourLabel(h)}</option>)}</select>
                    <span className="muted">to</span>
                    <select value={sc.EndHour} onChange={(e) => put({ EndHour: Number(e.target.value) })}>{Array.from({ length: 48 }, (_, h) => (h + 1) / 2).filter((h) => h > sc.StartHour).map((h) => <option key={h} value={h}>{h === 24 ? "24:00" : hourLabel(h)}</option>)}</select>
                    <button className="round-button" title="Remove" onClick={() => setSchedules(schedules.filter((_, j) => j !== i))}><Icon name="trash" size={14} /></button>
                  </div>
                );
              })}
            </Group>
          )}
          <SaveBar />
        </>
      )}
      {tab === "password" && (
        <Group title="Password">
          <Field label="New password"><input type="password" value={pw} onChange={(e) => setPw(e.target.value)} autoComplete="new-password" /></Field>
          <Field label="Confirm new password"><input type="password" value={pw2} onChange={(e) => setPw2(e.target.value)} autoComplete="new-password" /></Field>
          {pw2 && pw !== pw2 && <small className="score-low">The passwords don't match.</small>}
          <div className="row-line">
            <button className="glass-button prominent" disabled={busy || !pw || pw !== pw2} onClick={() => void run(async () => { await api.post("/Users/Password", { NewPw: pw }, { userId: id }); setPw(""); setPw2(""); }, "Password changed")}>Save password</button>
            <button className="glass-button danger" disabled={busy} onClick={() => ui.openSheet({ kind: "confirm", danger: true, title: "Reset this user's password?", text: "They can then sign in without a password until they set one.", confirmLabel: "Reset", run: () => api.post("/Users/Password", { ResetPassword: true }, { userId: id }) })}>Reset password</button>
          </div>
        </Group>
      )}
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
          <div className="row-text"><div className="row-title">{d.CustomName || d.Name}{d.Id === api.deviceId ? " (this computer)" : ""}</div><div className="row-sub">{d.AppName} {d.AppVersion} · {d.LastUserName} · {relativeTime(d.DateLastActivity)}</div></div>
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
      <p className="muted small">Recording options are under <button className="link-button" onClick={() => choose("dvr")}>DVR</button>.</p>
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
      <PluginConfig id={id} />
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
