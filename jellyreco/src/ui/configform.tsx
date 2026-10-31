// Typed settings forms for the admin Dashboard, laid out like jellyfin-web's pages: each page is a
// list of titled sections, each option has the right control (switch, dropdown, number with its
// limits, folder picker, list of tags, set of switches for a list like "hardware decoding for"),
// and options only show when they apply (like jellyfin-web: the QSV device only with QSV, and so on).
// A page can edit several server configs at once (e.g. Display = the server config + "metadata").

import { type ReactNode, useEffect, useMemo, useState } from "react";
import type { FileSystemEntry } from "../core/types";
import { ErrorNote, Field, Group, Modal, Spinner, Toggle, useAction, useLoad } from "./components";
import { Icon } from "./icons";
import { useModel } from "./state";

export type Draft = Record<string, Record<string, unknown>>;
type Api = NonNullable<ReturnType<typeof useModel>["api"]>;

/** One config the page edits: loaded and saved as a whole (jellyfin-web does the same). */
export interface Source {
  id: string;
  load: (api: Api) => Promise<Record<string, unknown>>;
  save: (api: Api, value: Record<string, unknown>) => Promise<unknown>;
}

export const serverConfig: Source = { id: "server", load: (api) => api.get("/System/Configuration"), save: (api, v) => api.post("/System/Configuration", v) };
export function namedConfig(name: string, id = name): Source {
  return { id, load: (api) => api.get(`/System/Configuration/${name}`), save: (api, v) => api.post(`/System/Configuration/${name}`, v) };
}

export interface Opt { value: string | number | boolean | null; label: string }
/** A switch in a "switches" set: a value in the list, or (with `flag`) its own true/false option. */
export interface SwitchOpt extends Opt { flag?: string; show?: When }
type When = (d: Draft, ctx: Ctx) => boolean;
export type Ctx = Record<string, unknown>;

interface Base { key: string; label: ReactNode; help?: ReactNode; show?: When }
export type FieldDef =
  | (Base & { kind: "toggle"; invert?: boolean })
  | (Base & { kind: "number"; min?: number; max?: number; step?: number; scale?: number; nullable?: boolean; placeholder?: string; integer?: boolean })
  | (Base & { kind: "text"; placeholder?: string; password?: boolean; rows?: number; mono?: boolean; readOnly?: boolean })
  | (Base & { kind: "select"; options: Opt[] | ((d: Draft, ctx: Ctx) => Opt[]); normalize?: (v: unknown) => unknown })
  | (Omit<Base, "label"> & { kind: "switches"; label?: ReactNode; options: SwitchOpt[] | ((d: Draft, ctx: Ctx) => SwitchOpt[]); columns?: boolean })
  | (Base & { kind: "tags"; placeholder?: string; numeric?: boolean })
  | (Base & { kind: "path"; files?: boolean })
  | { kind: "note"; key?: string; text: ReactNode; warn?: boolean; show?: When }
  | { kind: "custom"; key: string; show?: When; render: (d: Draft, set: (key: string, v: unknown) => void, ctx: Ctx) => ReactNode };

export interface SectionDef { title?: ReactNode; help?: ReactNode; show?: When; fields: FieldDef[] }

// MARK: Paths into the draft ("encoding.HardwareAccelerationType", "server.TrickplayOptions.Interval")

export function get(d: Draft, key: string): unknown {
  let cur: unknown = d;
  for (const part of key.split(".")) {
    if (cur === null || typeof cur !== "object") return undefined;
    cur = (cur as Record<string, unknown>)[part];
  }
  return cur;
}

function setIn(obj: Record<string, unknown>, parts: string[], v: unknown): Record<string, unknown> {
  const [head, ...rest] = parts;
  if (!rest.length) return { ...obj, [head]: v };
  const child = obj[head];
  return { ...obj, [head]: setIn(child && typeof child === "object" ? (child as Record<string, unknown>) : {}, rest, v) };
}

export function set(d: Draft, key: string, v: unknown): Draft {
  return setIn(d, key.split("."), v) as Draft;
}

// MARK: The page

/** Loads every source, shows the sections and saves what changed (with a Save bar like jellyfin-web's Save button). */
export function ConfigForm({ sources, sections, ctx = {}, banner, onSaved }: { sources: Source[]; sections: SectionDef[]; ctx?: Ctx; banner?: ReactNode; onSaved?: () => void }) {
  const model = useModel();
  const api = model.api!;
  const { data, error, reload } = useLoad(async () => {
    const out: Draft = {};
    await Promise.all(sources.map(async (s) => { out[s.id] = await s.load(api); }));
    return out;
  }, [sources.map((s) => s.id).join(",")]);
  const [draft, setDraft] = useState<Draft | null>(null);
  useEffect(() => { if (data) setDraft(structuredClone(data)); }, [data]);
  const { busy, run } = useAction();
  const changed = useMemo(() => (draft && data ? sources.filter((s) => JSON.stringify(draft[s.id]) !== JSON.stringify(data[s.id])) : []), [draft, data, sources]);
  if (error) return <ErrorNote text={error} retry={reload} />;
  if (!draft) return <Spinner />;
  const put = (key: string, v: unknown) => setDraft((d) => (d ? set(d, key, v) : d));
  const save = () => run(async () => {
    for (const s of changed) await s.save(api, draft[s.id]);
    reload();
    onSaved?.();
  }, "Saved");
  return (
    <div className="config-form">
      {banner}
      {sections.filter((s) => !s.show || s.show(draft, ctx)).map((s, i) => {
        const fields = s.fields.filter((f) => !f.show || f.show(draft, ctx));
        if (!fields.length) return null;
        return (
          <Group key={i} title={s.title}>
            {s.help && <p className="group-help">{s.help}</p>}
            <div className="form">{fields.map((f, j) => <FieldView key={`${f.key ?? "f"}-${j}`} f={f} d={draft} put={put} ctx={ctx} />)}</div>
          </Group>
        );
      })}
      <div className={`form-actions ${changed.length ? "sticky-save" : ""}`}>
        {changed.length > 0 && <span>Unsaved changes</span>}
        {changed.length > 0 && <button className="glass-button" onClick={() => setDraft(structuredClone(data!))}>Discard</button>}
        <button className="glass-button prominent" disabled={busy || !changed.length} onClick={() => void save()}>Save</button>
      </div>
    </div>
  );
}

function FieldView({ f, d, put, ctx }: { f: FieldDef; d: Draft; put: (k: string, v: unknown) => void; ctx: Ctx }) {
  const [browse, setBrowse] = useState(false);
  switch (f.kind) {
    case "note":
      return <div className={`banner ${f.warn ? "warn" : ""}`}><Icon name="info" size={15} /> <span>{f.text}</span></div>;
    case "custom":
      return <>{f.render(d, put, ctx)}</>;
    case "toggle": {
      const v = !!get(d, f.key);
      return <Toggle label={f.label} detail={f.help} checked={f.invert ? !v : v} onChange={(on) => put(f.key, f.invert ? !on : on)} />;
    }
    case "number":
      return <Field label={f.label} hint={f.help}><NumberInput f={f} value={get(d, f.key)} onChange={(v) => put(f.key, v)} /></Field>;
    case "text": {
      const v = get(d, f.key);
      const text = v === null || v === undefined ? "" : String(v);
      return (
        <Field label={f.label} hint={f.help}>
          {f.rows ? <textarea className={f.mono ? "mono" : ""} rows={f.rows} value={text} placeholder={f.placeholder} readOnly={f.readOnly} onChange={(e) => put(f.key, e.target.value)} spellCheck={!f.mono} />
            : <input type={f.password ? "password" : "text"} value={text} placeholder={f.placeholder} readOnly={f.readOnly} disabled={f.readOnly} onChange={(e) => put(f.key, e.target.value)} autoComplete="off" spellCheck={false} />}
        </Field>
      );
    }
    case "select": {
      const raw = get(d, f.key);
      const v = f.normalize ? f.normalize(raw) : raw;
      const opts = typeof f.options === "function" ? f.options(d, ctx) : f.options;
      let idx = opts.findIndex((o) => o.value === v || (o.value !== null && v !== null && v !== undefined && String(o.value) === String(v)));
      const list = idx < 0 && v !== undefined && v !== null && v !== "" ? [...opts, { value: v as Opt["value"], label: String(v) }] : opts;
      if (idx < 0) idx = list.length > opts.length ? list.length - 1 : list.findIndex((o) => o.value === null || o.value === "");
      return (
        <Field label={f.label} hint={f.help}>
          <select value={idx < 0 ? "" : String(idx)} onChange={(e) => put(f.key, list[Number(e.target.value)].value)}>
            {idx < 0 && <option value="" disabled>Choose…</option>}
            {list.map((o, i) => <option key={i} value={i}>{o.label}</option>)}
          </select>
        </Field>
      );
    }
    case "switches": {
      const cur = (get(d, f.key) as (string | number)[] | null | undefined) ?? [];
      const opts = (typeof f.options === "function" ? f.options(d, ctx) : f.options).filter((o) => !o.show || o.show(d, ctx));
      const flip = (val: Opt["value"], on: boolean) => {
        const next = cur.filter((x) => String(x) !== String(val));
        put(f.key, on ? [...next, val] : next);
      };
      return (
        <div className="switch-set">
          {f.label && <div className="switch-set-title">{f.label}</div>}
          {f.help && <small className="muted">{f.help}</small>}
          <div className={`switch-grid ${f.columns === false ? "single" : ""}`}>
            {opts.map((o) => o.flag
              ? <Toggle key={o.flag} label={o.label} checked={!!get(d, o.flag)} onChange={(on) => put(o.flag!, on)} />
              : <Toggle key={String(o.value)} label={o.label} checked={cur.some((x) => String(x) === String(o.value))} onChange={(on) => flip(o.value, on)} />)}
          </div>
        </div>
      );
    }
    case "tags":
      return <Field label={f.label} hint={f.help}><TagInput value={(get(d, f.key) as (string | number)[] | null) ?? []} numeric={f.numeric} placeholder={f.placeholder} onChange={(v) => put(f.key, v)} /></Field>;
    case "path": {
      const v = get(d, f.key);
      return (
        <Field label={f.label} hint={f.help}>
          <div className="input-with-button">
            <input value={v === null || v === undefined ? "" : String(v)} onChange={(e) => put(f.key, e.target.value)} spellCheck={false} />
            <button type="button" className="glass-button" onClick={(e) => { e.preventDefault(); setBrowse(true); }} title="Browse the server's folders"><Icon name="folder" size={15} /> Browse</button>
          </div>
          {browse && <FolderPicker files={f.files} initial={v ? String(v) : undefined} onPick={(p) => { put(f.key, p); setBrowse(false); }} close={() => setBrowse(false)} />}
        </Field>
      );
    }
  }
}

/** A number box that keeps what you type while you type it, and applies the limits when you leave it. */
function NumberInput({ f, value, onChange }: { f: Extract<FieldDef, { kind: "number" }>; value: unknown; onChange: (v: number | null) => void }) {
  const scale = f.scale ?? 1;
  const shown = typeof value === "number" ? String(+(value / scale).toFixed(6)) : "";
  const [text, setText] = useState(shown);
  useEffect(() => setText(shown), [shown]);
  const commit = (t: string) => {
    if (t.trim() === "") { onChange(f.nullable ? null : f.min ?? 0); return; }
    let n = Number(t);
    if (!Number.isFinite(n)) { setText(shown); return; }
    if (f.min !== undefined) n = Math.max(f.min, n);
    if (f.max !== undefined) n = Math.min(f.max, n);
    let raw = n * scale;
    if (f.integer !== false && (f.step === undefined || Number.isInteger(f.step)) && scale === 1) raw = Math.round(raw);
    if (scale !== 1) raw = Math.trunc(raw);
    onChange(raw);
    setText(String(+(raw / scale).toFixed(6)));
  };
  return <input type="number" inputMode="decimal" value={text} min={f.min} max={f.max} step={f.step ?? 1} placeholder={f.placeholder}
    onChange={(e) => { setText(e.target.value); if (e.target.value !== "" && Number.isFinite(Number(e.target.value))) { const n = Number(e.target.value) * scale; onChange(scale !== 1 ? Math.trunc(n) : n); } }}
    onBlur={(e) => commit(e.target.value)} />;
}

/** A list of short values (IP ranges, tags, widths) as removable chips: type and press Enter or a comma. */
export function TagInput({ value, onChange, numeric, placeholder }: { value: (string | number)[]; onChange: (v: (string | number)[]) => void; numeric?: boolean; placeholder?: string }) {
  const [text, setText] = useState("");
  const add = (t: string) => {
    const parts = t.split(/[,\n]/).map((x) => x.trim()).filter(Boolean);
    if (!parts.length) return;
    const vals = numeric ? parts.map(Number).filter((n) => Number.isFinite(n)) : parts;
    const next = [...value];
    for (const v of vals) if (!next.some((x) => String(x) === String(v))) next.push(v);
    onChange(next);
    setText("");
  };
  return (
    <div className="tag-input" onClick={(e) => (e.currentTarget.querySelector("input") as HTMLInputElement | null)?.focus()}>
      {value.map((v) => (
        <span key={String(v)} className="tag-chip">{v}<button type="button" aria-label={`Remove ${v}`} onClick={() => onChange(value.filter((x) => x !== v))}><Icon name="x" size={11} /></button></span>
      ))}
      <input value={text} placeholder={value.length ? "" : placeholder ?? "Type and press Enter"} inputMode={numeric ? "numeric" : undefined}
        onChange={(e) => { if (/[,\n]/.test(e.target.value)) add(e.target.value); else setText(e.target.value); }}
        onKeyDown={(e) => { if (e.key === "Enter") { e.preventDefault(); add(text); } else if (e.key === "Backspace" && !text && value.length) onChange(value.slice(0, -1)); }}
        onBlur={() => add(text)} onPaste={(e) => { const t = e.clipboardData.getData("text"); if (/[,\n]/.test(t)) { e.preventDefault(); add(text + t); } }} />
    </div>
  );
}

/** Browses folders (or files) on the server's disks, like jellyfin-web's directory browser. */
export function FolderPicker({ onPick, close, files, initial }: { onPick: (p: string) => void; close: () => void; files?: boolean; initial?: string }) {
  const model = useModel();
  const api = model.api!;
  const [path, setPath] = useState<string | null>(initial || null);
  const [typed, setTyped] = useState("");
  const { data, error } = useLoad(async (): Promise<FileSystemEntry[]> => {
    if (path === null) {
      const drives = await api.get<FileSystemEntry[]>("/Environment/Drives").catch(() => []);
      const def = await api.get<{ Path?: string }>("/Environment/DefaultDirectoryBrowser").catch(() => null);
      return [...(def?.Path ? [{ Name: def.Path, Path: def.Path, Type: "Directory" as const }] : []), ...drives];
    }
    return api.get<FileSystemEntry[]>("/Environment/DirectoryContents", { path, includeDirectories: true, includeFiles: !!files });
  }, [path]);
  const up = async () => {
    if (!path) return;
    const parent = await api.get<string>("/Environment/ParentPath", { path }).catch(() => null);
    setPath(parent || null);
  };
  return (
    <Modal title={files ? "Choose a file on the server" : "Choose a folder on the server"} onClose={close} width={560} actions={path && !files ? <button className="glass-button prominent" onClick={() => onPick(path)}>Use this folder</button> : undefined}>
      <div className="row-line"><button className="round-button" disabled={path === null} onClick={() => void up()}><Icon name="arrowUp" size={14} /></button><code className="path">{path ?? "Drives"}</code></div>
      <form className="row-line" onSubmit={(e) => { e.preventDefault(); if (typed) setPath(typed); }}><input placeholder="Or type a path" value={typed} onChange={(e) => setTyped(e.target.value)} /><button className="glass-button">Go</button></form>
      {error ? <ErrorNote text={error} /> : !data ? <Spinner /> : (
        <div className="rows">{data.map((e) => (
          <button key={e.Path} className="row" onClick={() => (e.Type === "File" ? onPick(e.Path) : setPath(e.Path))}><Icon name={e.Type === "File" ? "file" : "folder"} size={16} /><div className="row-text">{e.Name}</div></button>
        ))}</div>
      )}
    </Modal>
  );
}
