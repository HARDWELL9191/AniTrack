// Sheets (dialogs) that can open from anywhere: media info, metadata/image editors, identify,
// subtitle search, refresh, playlists and collections, Quick Connect, SyncPlay, remote control,
// "why would I like this", confirm/prompt, and the resume question.

import { useEffect, useState } from "react";
import { Select } from "./select";
import { LIST_FIELDS } from "../core/api";
import { getSocket } from "../core/socket";
import type { Item, ItemsResult, MediaStream, RemoteImage, RemoteSearchResult, RemoteSubtitle, SessionInfo, SyncPlayGroup } from "../core/types";
import { bitrate, bytes, dateOnly, languageName, streamLabel } from "./fmt";
import { cardImage, Cover, Dropdown, Empty, Field, Modal, Segmented, Spinner, Toggle, useAction, useLoad } from "./components";
import { type ExternalTitle, isMovie, metaLine, resized, titleId, tmdbWebUrl } from "../core/titles";
import { TitleCard, titleAction, WhyText } from "./foryou";
import { Icon } from "./icons";
import { ResumePrompt } from "./player";
import { type Sheet, ui, useModel, useUI } from "./state";

export function Sheets() {
  const state = useUI();
  return (
    <>
      {state.sheets.map((s, i) => <SheetView key={i} sheet={s} />)}
      <ResumeHost />
    </>
  );
}

function SheetView({ sheet }: { sheet: Sheet }) {
  const close = () => ui.closeSheet();
  switch (sheet.kind) {
    case "mediaInfo": return <MediaInfo item={sheet.item} close={close} />;
    case "editMetadata": return <EditMetadata item={sheet.item} close={close} />;
    case "editImages": return <EditImages item={sheet.item} close={close} />;
    case "identify": return <Identify item={sheet.item} close={close} />;
    case "subtitles": return <Subtitles item={sheet.item} close={close} />;
    case "refresh": return <Refresh item={sheet.item} close={close} />;
    case "addToPlaylist": return <AddToPlaylist items={sheet.items} close={close} />;
    case "addToCollection": return <AddToCollection items={sheet.items} close={close} />;
    case "quickConnectApprove": return <QuickConnectApprove close={close} />;
    case "syncPlay": return <SyncPlay close={close} />;
    case "remoteControl": return <RemoteControl close={close} />;
    case "why": return <Modal title="Why would I like this?" onClose={close} width={520}><div className="why-text"><Icon name="sparkles" size={18} /><WhyText because={sheet.because} highlights={sheet.highlights} name={sheet.item.Name ?? "This"} /></div></Modal>;
    case "versions": return <Modal title="Choose a version" onClose={close} width={460}><div className="rows">{(sheet.item.MediaSources ?? []).map((m) => <button key={m.Id} className="row" onClick={() => { close(); sheet.onPick(m.Id!); }}><Icon name="film" size={18} /><div className="row-text"><div className="row-title">{m.Name}</div><div className="row-sub">{m.Container} · {bytes(m.Size)} · {bitrate(m.Bitrate)}</div></div></button>)}</div></Modal>;
    case "confirm": return <Confirm sheet={sheet} close={close} />;
    case "prompt": return <Prompt sheet={sheet} close={close} />;
    case "tmdb": return <TmdbSheet key={titleId(sheet.item)} item={sheet.item} close={close} />;
    case "share": return null;
  }
}

function Confirm({ sheet, close }: { sheet: Extract<Sheet, { kind: "confirm" }>; close: () => void }) {
  const { busy, run } = useAction();
  return (
    <Modal title={sheet.title} onClose={close} width={440}>
      <p>{sheet.text}</p>
      <div className="row-line end">
        <button className="glass-button" onClick={close}>Cancel</button>
        <button className={`glass-button ${sheet.danger ? "danger-fill" : "prominent"}`} disabled={busy} onClick={async () => { if (await run(async () => sheet.run())) close(); }}>{busy ? <span className="spinner small" /> : sheet.confirmLabel ?? "OK"}</button>
      </div>
    </Modal>
  );
}

function Prompt({ sheet, close }: { sheet: Extract<Sheet, { kind: "prompt" }>; close: () => void }) {
  const [value, setValue] = useState(sheet.initial ?? "");
  const { busy, run } = useAction();
  return (
    <Modal title={sheet.title} onClose={close} width={440}>
      <form className="form" onSubmit={async (e) => { e.preventDefault(); if (await run(async () => sheet.run(value))) close(); }}>
        <Field label={sheet.label}><input autoFocus value={value} onChange={(e) => setValue(e.target.value)} /></Field>
        <div className="row-line end"><button type="button" className="glass-button" onClick={close}>Cancel</button><button className="glass-button prominent" disabled={busy || !value.trim()}>{sheet.confirmLabel ?? "OK"}</button></div>
      </form>
    </Modal>
  );
}

/** Asks "Resume or start over?" for the player. */
function ResumeHost() {
  const model = useModel();
  const [ask, setAsk] = useState<{ seconds: number; item: Item; resolve: (v: boolean | null) => void } | null>(null);
  useEffect(() => {
    if (!model.player) return;
    model.player.askResume = (seconds, item) => new Promise((resolve) => setAsk({ seconds, item, resolve }));
    return () => { if (model.player) model.player.askResume = null; };
  }, [model.player]);
  if (!ask) return null;
  return <ResumePrompt seconds={ask.seconds} item={ask.item} answer={(v) => { ask.resolve(v); setAsk(null); }} />;
}

// MARK: A title you don't have (TMDB)

function TmdbSheet({ item, close }: { item: ExternalTitle; close: () => void }) {
  const model = useModel();
  const tmdb = model.tmdb;
  const { data: d, error } = useLoad(() => tmdb.extras(item), [titleId(item)]);
  const { data: more } = useLoad(async () => {
    const c = model.discoveryContext();
    return c ? model.discovery.moreLike(c, item) : [];
  }, [titleId(item)]);
  const t = d?.title ?? item;
  const st = model.storage;
  const onList = !!st?.hasTitle(t);
  const out = !!st?.notForMe.some((x) => titleId(x) === titleId(t));
  const seen = !!st?.seenElsewhere.some((x) => titleId(x) === titleId(t));
  const openUrl = async (url: string) => { const { openUrl: o } = await import("@tauri-apps/plugin-opener"); await o(url); };
  const meta = [metaLine(t), t.episodes && !isMovie(t) ? `${t.episodes} episodes` : null, t.status, t.score ? `★ ${t.score.toFixed(1)}` : null].filter(Boolean).join(" · ");
  return (
    <Modal title={t.title} onClose={close} width={900}>
      <div className="tmdb-sheet">
        {t.backdropURL && <div className="tmdb-banner" style={{ backgroundImage: `url("${resized(t.backdropURL, "w1280")}")` }} />}
        <div className="tmdb-top">
          <Cover url={resized(t.posterURL, "w500")} width={200} height={300} radius={16} icon="film" />
          <div className="tmdb-text">
            <span className="chip chip-muted"><Icon name="cloud" size={12} /> Not on your server</span>
            <h2>{t.title}{t.year ? <span className="muted"> ({t.year})</span> : null}</h2>
            {d?.tagline && <p className="tagline">{d.tagline}</p>}
            <div className="muted small">{meta}</div>
            {t.genres.length > 0 && <div className="chips-wrap">{t.genres.map((x) => <span key={x} className="chip chip-accent">{x}</span>)}</div>}
            <p>{t.overview}</p>
            {d?.networks.length ? <p className="muted small">{d.networks.join(", ")}</p> : null}
            <div className="row-line wrap">
              <button className={`glass-button ${onList ? "" : "prominent"}`} onClick={() => void titleAction(model, t, "myList")}><Icon name="bookmark" size={15} /> {onList ? "On My List" : "Add to My List"}</button>
              <button className="glass-button" onClick={() => void titleAction(model, t, seen ? "undoSeen" : "seen")}><Icon name="eye" size={15} /> {seen ? "Seen ✓" : "Already seen"}</button>
              <button className="glass-button danger" onClick={() => void titleAction(model, t, out ? "undoNotForMe" : "notForMe")}><Icon name="thumbsDown" size={15} /> {out ? "Undo Not for me" : "Not for me"}</button>
              {d?.trailer && <button className="glass-button" onClick={() => void openUrl(d.trailer!)}><Icon name="film" size={15} /> Trailer</button>}
              <button className="glass-button" onClick={() => void openUrl(tmdbWebUrl(t))}><Icon name="external" size={15} /> TMDB</button>
              {t.imdbId && <button className="glass-button" onClick={() => void openUrl(`https://www.imdb.com/title/${t.imdbId}/`)}><Icon name="external" size={15} /> IMDb</button>}
            </div>
          </div>
        </div>
        {error && <p className="footnote error">{error}</p>}
        {!!d?.cast.length && (
          <section><h3>Cast</h3>
            <div className="cast-row">{d.cast.map((c, i) => (
              <div key={i} className="person-card"><Cover url={c.profile ?? undefined} width={84} height={84} radius={42} icon="person" /><strong>{c.name}</strong><small className="muted">{c.character}</small></div>
            ))}</div>
          </section>
        )}
        {!!more?.length && (
          <section><h3>More like this <span className="muted small">(not on your server)</span></h3>
            <div className="cast-row">{more.map((m) => <TitleCard key={titleId(m)} t={m} width={130} />)}</div>
          </section>
        )}
      </div>
    </Modal>
  );
}

// MARK: Media info

function MediaInfo({ item, close }: { item: Item; close: () => void }) {
  const model = useModel();
  const { data } = useLoad(() => model.api!.itemFull(item.Id), [item.Id]);
  const sources = data?.MediaSources ?? item.MediaSources ?? [];
  return (
    <Modal title="Media info" onClose={close} width={760}>
      {!data && !sources.length ? <Spinner /> : sources.map((src) => (
        <div key={src.Id} className="media-info">
          <h3>{src.Name ?? item.Name}</h3>
          <div className="kv">
            <Kv k="Container" v={src.Container?.toUpperCase()} /><Kv k="Size" v={bytes(src.Size)} /><Kv k="Bitrate" v={bitrate(src.Bitrate)} />
            <Kv k="Path" v={src.Path} wide /><Kv k="Direct play" v={src.SupportsDirectPlay ? "Yes" : "No"} />
          </div>
          {(src.MediaStreams ?? []).map((s) => <StreamInfo key={s.Index} s={s} />)}
          {!!src.MediaAttachments?.length && <p className="muted small">{src.MediaAttachments.length} attachments (fonts): {src.MediaAttachments.map((a) => a.FileName).slice(0, 8).join(", ")}{src.MediaAttachments.length > 8 ? "…" : ""}</p>}
        </div>
      ))}
    </Modal>
  );
}

function StreamInfo({ s }: { s: MediaStream }) {
  const rows: [string, unknown][] = s.Type === "Video" ? [
    ["Codec", `${s.Codec?.toUpperCase()}${s.Profile ? ` (${s.Profile})` : ""}${s.Level ? ` L${s.Level}` : ""}`], ["Resolution", `${s.Width}×${s.Height}`], ["Aspect", s.AspectRatio],
    ["Frame rate", s.RealFrameRate?.toFixed(3)], ["Bitrate", bitrate(s.BitRate)], ["Bit depth", s.BitDepth], ["Range", `${s.VideoRange ?? ""} ${s.VideoRangeType ?? ""}`],
    ["Dolby Vision", s.VideoDoViTitle ?? (s.DvProfile ? `Profile ${s.DvProfile}` : null)], ["Color", [s.ColorPrimaries, s.ColorTransfer, s.ColorSpace].filter(Boolean).join(" / ")],
    ["Pixel format", s.PixelFormat], ["Interlaced", s.IsInterlaced ? "Yes" : "No"], ["Ref frames", s.RefFrames],
  ] : s.Type === "Audio" ? [
    ["Language", languageName(s.Language)], ["Codec", `${s.Codec?.toUpperCase()}${s.Profile ? ` (${s.Profile})` : ""}`], ["Layout", s.ChannelLayout], ["Channels", s.Channels],
    ["Bitrate", bitrate(s.BitRate)], ["Sample rate", s.SampleRate ? `${s.SampleRate} Hz` : null], ["Bit depth", s.BitDepth], ["Spatial", s.AudioSpatialFormat !== "None" ? s.AudioSpatialFormat : null],
    ["Default", s.IsDefault ? "Yes" : "No"],
  ] : [
    ["Language", languageName(s.Language)], ["Codec", s.Codec?.toUpperCase()], ["Title", s.Title], ["Forced", s.IsForced ? "Yes" : "No"], ["SDH", s.IsHearingImpaired ? "Yes" : "No"],
    ["External", s.IsExternal ? "Yes" : "No"], ["Default", s.IsDefault ? "Yes" : "No"],
  ];
  return (
    <div className="stream-info">
      <div className="stream-head"><Icon name={s.Type === "Video" ? "film" : s.Type === "Audio" ? "audio" : "subtitles"} size={16} /> <strong>{s.Type} #{s.Index}</strong> <span className="muted">{streamLabel(s)}</span></div>
      <div className="kv">{rows.filter(([, v]) => v !== null && v !== undefined && v !== "" && v !== " ").map(([k, v]) => <Kv key={k} k={k} v={String(v)} />)}</div>
    </div>
  );
}

function Kv({ k, v, wide }: { k: string; v?: string | null; wide?: boolean }) {
  if (!v) return null;
  return <div className={`kv-item ${wide ? "wide" : ""}`}><span>{k}</span><strong>{v}</strong></div>;
}

// MARK: Metadata editor

const EDITABLE: { key: keyof Item; label: string; type?: "number" | "date" | "text" | "list" | "area" }[] = [
  { key: "Name", label: "Title" }, { key: "OriginalTitle", label: "Original title" }, { key: "SortName", label: "Sort title" },
  { key: "Overview", label: "Overview", type: "area" }, { key: "Taglines", label: "Tagline", type: "list" },
  { key: "ProductionYear", label: "Year", type: "number" }, { key: "PremiereDate", label: "Release date", type: "date" }, { key: "EndDate", label: "End date", type: "date" },
  { key: "CommunityRating", label: "Community rating", type: "number" }, { key: "CriticRating", label: "Critic rating", type: "number" },
  { key: "OfficialRating", label: "Parental rating" }, { key: "CustomRating", label: "Custom rating" },
  { key: "IndexNumber", label: "Number", type: "number" }, { key: "ParentIndexNumber", label: "Season number", type: "number" },
  { key: "Genres", label: "Genres", type: "list" }, { key: "Tags", label: "Tags", type: "list" }, { key: "ProductionLocations", label: "Countries", type: "list" },
];

function EditMetadata({ item, close }: { item: Item; close: () => void }) {
  const model = useModel();
  const { data } = useLoad(() => model.api!.itemFull(item.Id), [item.Id]);
  const { data: editor } = useLoad(() => model.api!.metadataEditorInfo(item.Id), [item.Id]);
  const [draft, setDraft] = useState<Item | null>(null);
  useEffect(() => { if (data) setDraft(structuredClone(data)); }, [data]);
  const { busy, run } = useAction();
  if (!draft) return <Modal title="Edit metadata" onClose={close}><Spinner /></Modal>;
  const ratings = (editor?.ParentalRatingOptions as { Name: string }[] | undefined) ?? [];
  const set = (k: keyof Item, v: unknown) => setDraft({ ...draft, [k]: v } as Item);
  const save = () => run(async () => {
    await model.api!.updateItem(item.Id, draft);
    model.dataChanged();
    close();
  }, "Saved");
  return (
    <Modal title={`Edit ${item.Name}`} onClose={close} width={720} actions={<button className="glass-button prominent" disabled={busy} onClick={() => void save()}>Save</button>}>
      <div className="form grid-2">
        {EDITABLE.filter((f) => f.key in draft || ["Name", "Overview", "Genres", "Tags", "OfficialRating", "PremiereDate", "ProductionYear"].includes(f.key as string)).map((f) => {
          const v = draft[f.key] as unknown;
          if (f.key === "OfficialRating" && ratings.length) return (
            <Field key={f.key} label={f.label}><Select value={(v as string) ?? ""} onChange={(e) => set(f.key, e.target.value || null)}><option value="">None</option>{ratings.map((r) => <option key={r.Name} value={r.Name}>{r.Name}</option>)}</Select></Field>
          );
          if (f.type === "area") return <Field key={f.key} label={f.label}><textarea rows={6} value={(v as string) ?? ""} onChange={(e) => set(f.key, e.target.value)} /></Field>;
          if (f.type === "list") return <Field key={f.key} label={f.label} hint="Separate with commas"><input value={((v as string[]) ?? []).join(", ")} onChange={(e) => set(f.key, e.target.value.split(",").map((x) => x.trim()).filter(Boolean))} /></Field>;
          if (f.type === "date") return <Field key={f.key} label={f.label}><input type="date" value={v ? String(v).slice(0, 10) : ""} onChange={(e) => set(f.key, e.target.value ? new Date(e.target.value).toISOString() : null)} /></Field>;
          if (f.type === "number") return <Field key={f.key} label={f.label}><input type="number" step="any" value={(v as number) ?? ""} onChange={(e) => set(f.key, e.target.value === "" ? null : Number(e.target.value))} /></Field>;
          return <Field key={f.key} label={f.label}><input value={(v as string) ?? ""} onChange={(e) => set(f.key, e.target.value)} /></Field>;
        })}
        <Field label="Provider ids">
          <div className="provider-ids">
            {Object.entries(draft.ProviderIds ?? {}).map(([k, v]) => (
              <label key={k}><span>{k}</span><input value={v ?? ""} onChange={(e) => set("ProviderIds", { ...draft.ProviderIds, [k]: e.target.value })} /></label>
            ))}
          </div>
        </Field>
        <Toggle label="Lock this item's metadata" detail="Refreshes won't change it" checked={!!draft.LockData} onChange={(v) => set("LockData", v)} />
      </div>
    </Modal>
  );
}

// MARK: Images

const IMAGE_TYPES = ["Primary", "Backdrop", "Logo", "Thumb", "Banner", "Art", "Disc", "Box", "BoxRear", "Menu", "Screenshot"];

function EditImages({ item, close }: { item: Item; close: () => void }) {
  const model = useModel();
  const api = model.api!;
  const { data: current, reload } = useLoad(() => api.get<{ ImageType: string; ImageIndex?: number; ImageTag?: string; Width?: number; Height?: number }[]>(`/Items/${item.Id}/Images`), [item.Id]);
  const [type, setType] = useState("Primary");
  const [provider, setProvider] = useState("");
  const [allLangs, setAllLangs] = useState(false);
  const { data: providers } = useLoad(() => api.get<{ Name: string }[]>(`/Items/${item.Id}/RemoteImages/Providers`), [item.Id]);
  const { data: remote, loading } = useLoad(() => api.get<{ Images: RemoteImage[]; TotalRecordCount: number }>(`/Items/${item.Id}/RemoteImages`, { type, providerName: provider || undefined, includeAllLanguages: allLangs, limit: 60 }), [item.Id, type, provider, allLangs]);
  const { busy, run } = useAction();
  const download = (url: string) => run(async () => { await api.post(`/Items/${item.Id}/RemoteImages/Download`, undefined, { type, imageUrl: url }); reload(); model.dataChanged(); }, "Image saved");
  const remove = (t: string, index?: number) => run(async () => { await api.del(index !== undefined ? `/Items/${item.Id}/Images/${t}/${index}` : `/Items/${item.Id}/Images/${t}`); reload(); model.dataChanged(); }, "Image removed");
  const upload = async () => {
    try {
      const { open } = await import("@tauri-apps/plugin-dialog");
      const path = await open({ filters: [{ name: "Images", extensions: ["jpg", "jpeg", "png", "webp", "gif"] }] });
      if (typeof path !== "string") return;
      const { readFile } = await import("./native");
      const b64 = await readFile(path);
      const mime = /\.png$/i.test(path) ? "image/png" : /\.webp$/i.test(path) ? "image/webp" : /\.gif$/i.test(path) ? "image/gif" : "image/jpeg";
      await run(async () => { await api.request("POST", `/Items/${item.Id}/Images/${type}`, { body: b64, contentType: mime }); reload(); model.dataChanged(); }, "Image uploaded");
    } catch (e) { model.fail(e); }
  };
  return (
    <Modal title={`Images · ${item.Name}`} onClose={close} width={920}>
      <h3>On the server</h3>
      <div className="image-grid">
        {current?.map((c, i) => (
          <div key={i} className="image-tile">
            <img src={api.image(item.Id, c.ImageType, { tag: c.ImageTag, maxWidth: 300, index: c.ImageType === "Backdrop" || c.ImageType === "Screenshot" ? c.ImageIndex : undefined })} alt="" />
            <span>{c.ImageType}{c.Width ? ` · ${c.Width}×${c.Height}` : ""}</span>
            <button className="link-button small danger" disabled={busy} onClick={() => void remove(c.ImageType, c.ImageType === "Backdrop" ? c.ImageIndex : undefined)}>Delete</button>
          </div>
        ))}
        {!current?.length && <p className="muted">No images yet.</p>}
      </div>
      <div className="toolbar-row wrap">
        <h3>Find images</h3>
        <Select value={type} onChange={(e) => setType(e.target.value)}>{IMAGE_TYPES.map((t) => <option key={t}>{t}</option>)}</Select>
        <Select value={provider} onChange={(e) => setProvider(e.target.value)}><option value="">All providers</option>{providers?.map((p) => <option key={p.Name}>{p.Name}</option>)}</Select>
        <Toggle label="All languages" checked={allLangs} onChange={setAllLangs} />
        <button className="glass-button" onClick={() => void upload()}><Icon name="plus" size={15} /> Upload</button>
      </div>
      {loading ? <Spinner /> : !remote?.Images.length ? <p className="muted">Nothing found.</p> : (
        <div className="image-grid">
          {remote.Images.map((r, i) => (
            <button key={i} className="image-tile" disabled={busy} onClick={() => r.Url && void download(r.Url)}>
              <img src={r.ThumbnailUrl ?? r.Url ?? ""} alt="" loading="lazy" />
              <span>{r.ProviderName} · {r.Width}×{r.Height}{r.Language ? ` · ${r.Language}` : ""}{r.CommunityRating ? ` · ★${r.CommunityRating.toFixed(1)}` : ""}</span>
            </button>
          ))}
        </div>
      )}
    </Modal>
  );
}

// MARK: Identify

function Identify({ item, close }: { item: Item; close: () => void }) {
  const model = useModel();
  const [name, setName] = useState(item.Name ?? "");
  const [year, setYear] = useState(item.ProductionYear ? String(item.ProductionYear) : "");
  const [ids, setIds] = useState<Record<string, string>>(() => Object.fromEntries(Object.entries(item.ProviderIds ?? {}).map(([k, v]) => [k, v ?? ""])));
  const [results, setResults] = useState<RemoteSearchResult[] | null>(null);
  const [replaceImages, setReplaceImages] = useState(true);
  const { busy, run } = useAction();
  const kind = item.Type === "Episode" ? "Series" : item.Type;
  const search = () => run(async () => {
    const r = await model.api!.post<RemoteSearchResult[]>(`/Items/RemoteSearch/${kind}`, {
      SearchInfo: { Name: name, Year: year ? Number(year) : null, ProviderIds: Object.fromEntries(Object.entries(ids).filter(([, v]) => v)) },
      ItemId: item.Id, IncludeDisabledProviders: true,
    });
    setResults(r);
  });
  const apply = (r: RemoteSearchResult) => run(async () => {
    await model.api!.post(`/Items/RemoteSearch/Apply/${item.Id}`, r, { replaceAllImages: replaceImages });
    model.dataChanged();
    close();
  }, "Identified. Metadata is refreshing.");
  return (
    <Modal title={`Identify ${item.Name}`} onClose={close} width={760}>
      <form className="form grid-2" onSubmit={(e) => { e.preventDefault(); void search(); }}>
        <Field label="Name"><input value={name} onChange={(e) => setName(e.target.value)} /></Field>
        <Field label="Year"><input value={year} onChange={(e) => setYear(e.target.value)} /></Field>
        {Object.keys(ids).length > 0 && Object.keys(ids).map((k) => <Field key={k} label={`${k} id`}><input value={ids[k]} onChange={(e) => setIds({ ...ids, [k]: e.target.value })} /></Field>)}
        <Toggle label="Replace existing images" checked={replaceImages} onChange={setReplaceImages} />
        <button className="glass-button prominent" disabled={busy}>{busy ? <span className="spinner small" /> : "Search"}</button>
      </form>
      {results && (results.length ? (
        <div className="rows">
          {results.map((r, i) => (
            <button key={i} className="row" onClick={() => void apply(r)} disabled={busy}>
              <Cover url={r.ImageUrl ?? undefined} width={56} height={84} radius={8} />
              <div className="row-text">
                <div className="row-title">{r.Name}{r.ProductionYear ? ` (${r.ProductionYear})` : ""}</div>
                <div className="row-sub">{r.SearchProviderName} · {Object.entries(r.ProviderIds ?? {}).map(([k, v]) => `${k} ${v}`).join(" · ")}</div>
                {r.Overview && <div className="row-sub clamp-3">{r.Overview}</div>}
              </div>
            </button>
          ))}
        </div>
      ) : <Empty icon="search" title="No matches" />)}
    </Modal>
  );
}

// MARK: Subtitles

function Subtitles({ item, close }: { item: Item; close: () => void }) {
  const model = useModel();
  const api = model.api!;
  const { data: full, reload } = useLoad(() => api.itemFull(item.Id), [item.Id]);
  const [lang, setLang] = useState(model.user?.Configuration?.SubtitleLanguagePreference || "eng");
  const [results, setResults] = useState<RemoteSubtitle[] | null>(null);
  const { data: cultures } = useLoad(() => api.get<{ DisplayName: string; ThreeLetterISOLanguageName?: string }[]>("/Localization/Cultures"), []);
  const { busy, run } = useAction();
  const subs = (full?.MediaStreams ?? []).filter((s) => s.Type === "Subtitle");
  const search = () => run(async () => setResults(await api.get<RemoteSubtitle[]>(`/Items/${item.Id}/RemoteSearch/Subtitles/${lang}`)));
  const download = (s: RemoteSubtitle) => run(async () => { await api.post(`/Items/${item.Id}/RemoteSearch/Subtitles/${encodeURIComponent(s.Id!)}`); setTimeout(reload, 1500); model.dataChanged(); }, "Downloaded");
  const remove = (s: MediaStream) => run(async () => { await api.del(`/Videos/${item.Id}/Subtitles/${s.Index}`); reload(); model.dataChanged(); }, "Deleted");
  return (
    <Modal title={`Subtitles · ${item.Name}`} onClose={close} width={760}>
      <h3>On the server</h3>
      {!full ? <Spinner /> : !subs.length ? <p className="muted">No subtitles yet.</p> : (
        <div className="rows">{subs.map((s) => (
          <div key={s.Index} className="row static"><Icon name="subtitles" size={18} /><div className="row-text"><div className="row-title">{streamLabel(s)}</div><div className="row-sub">{s.IsExternal ? `External · ${s.Path ?? ""}` : "Embedded in the file"}</div></div>
            {s.IsExternal && <button className="glass-button danger" disabled={busy} onClick={() => void remove(s)}>Delete</button>}</div>
        ))}</div>
      )}
      <div className="toolbar-row">
        <h3>Search online</h3>
        <Select value={lang} onChange={(e) => setLang(e.target.value)}>{(cultures ?? []).filter((c) => c.ThreeLetterISOLanguageName).map((c) => <option key={c.ThreeLetterISOLanguageName} value={c.ThreeLetterISOLanguageName!}>{c.DisplayName}</option>)}</Select>
        <button className="glass-button prominent" disabled={busy} onClick={() => void search()}>Search</button>
      </div>
      {results && (results.length ? (
        <div className="rows">{results.map((r) => (
          <button key={r.Id} className="row" disabled={busy} onClick={() => void download(r)}>
            <Icon name="download" size={18} />
            <div className="row-text">
              <div className="row-title">{r.Name}</div>
              <div className="row-sub">{[r.ProviderName, r.Format, r.Author, r.DownloadCount ? `${r.DownloadCount} downloads` : null, r.CommunityRating ? `★${r.CommunityRating}` : null, r.IsHashMatch ? "Exact match" : null, r.HearingImpaired ? "SDH" : null, r.Forced ? "Forced" : null, r.AiTranslated || r.MachineTranslated ? "Machine translated" : null, dateOnly(r.DateCreated)].filter(Boolean).join(" · ")}</div>
            </div>
          </button>
        ))}</div>
      ) : <Empty icon="subtitles" title="No subtitles found" text="Check that a subtitle provider plugin (like OpenSubtitles) is installed and set up." />)}
    </Modal>
  );
}

// MARK: Refresh

function Refresh({ item, close }: { item: Item; close: () => void }) {
  const model = useModel();
  const [mode, setMode] = useState<"missing" | "replaceMeta" | "scan">("missing");
  const [replaceImages, setReplaceImages] = useState(false);
  const [trickplay, setTrickplay] = useState(false);
  const { busy, run } = useAction();
  const go = () => run(async () => {
    await model.api!.refreshItem(item.Id, {
      metadata: mode === "scan" ? "Default" : "FullRefresh", images: mode === "scan" ? "Default" : "FullRefresh",
      replaceMetadata: mode === "replaceMeta", replaceImages, regenerateTrickplay: trickplay,
    });
    close();
  }, "Refresh started");
  return (
    <Modal title={`Refresh ${item.Name}`} onClose={close} width={500}>
      <div className="form">
        <Segmented value={mode} options={[{ value: "scan", label: "Scan for new files" }, { value: "missing", label: "Find missing metadata" }, { value: "replaceMeta", label: "Replace all metadata" }]} onChange={setMode} />
        <Toggle label="Replace existing images" checked={replaceImages} onChange={setReplaceImages} />
        <Toggle label="Regenerate trickplay images" checked={trickplay} onChange={setTrickplay} />
        <button className="glass-button prominent" disabled={busy} onClick={() => void go()}>Refresh</button>
      </div>
    </Modal>
  );
}

// MARK: Playlists and collections

function AddToPlaylist({ items, close }: { items: Item[]; close: () => void }) {
  const model = useModel();
  const api = model.api!;
  const isAudio = items.every((i) => i.MediaType === "Audio" || i.Type === "Audio" || i.Type === "MusicAlbum");
  const { data } = useLoad(() => api.items({ includeItemTypes: ["Playlist"], recursive: true, sortBy: ["SortName"], fields: LIST_FIELDS }), []);
  const { busy, run } = useAction();
  const ids = items.map((i) => i.Id);
  const add = (p: Item) => run(async () => { await api.post(`/Playlists/${p.Id}/Items`, undefined, { ids, userId: api.userId }); close(); model.dataChanged(); }, `Added to ${p.Name}`);
  const create = () => ui.openSheet({
    kind: "prompt", title: "New playlist", label: "Name", confirmLabel: "Create",
    run: async (name) => { await api.post("/Playlists", { Name: name, Ids: ids, UserId: api.userId, MediaType: isAudio ? "Audio" : "Video", IsPublic: false }); model.toast(`Created ${name}`, "success"); close(); model.dataChanged(); },
  });
  return (
    <Modal title="Add to playlist" onClose={close} width={460}>
      <button className="glass-button wide" onClick={create}><Icon name="plus" size={15} /> New playlist</button>
      {!data ? <Spinner /> : <div className="rows">{data.Items.map((p) => (
        <button key={p.Id} className="row" disabled={busy} onClick={() => void add(p)}>
          <Cover url={cardImage(api, p, "square", 56)} width={44} height={44} radius={8} icon="playlist" />
          <div className="row-text"><div className="row-title">{p.Name}</div><div className="row-sub">{p.ChildCount ?? 0} items</div></div>
        </button>
      ))}</div>}
    </Modal>
  );
}

function AddToCollection({ items, close }: { items: Item[]; close: () => void }) {
  const model = useModel();
  const api = model.api!;
  const { data } = useLoad(() => api.items({ includeItemTypes: ["BoxSet"], recursive: true, sortBy: ["SortName"], fields: LIST_FIELDS }), []);
  const { busy, run } = useAction();
  const ids = items.map((i) => i.Id);
  const add = (c: Item) => run(async () => { await api.post(`/Collections/${c.Id}/Items`, undefined, { ids }); close(); model.dataChanged(); }, `Added to ${c.Name}`);
  const create = () => ui.openSheet({
    kind: "prompt", title: "New collection", label: "Name", confirmLabel: "Create",
    run: async (name) => { await api.post("/Collections", undefined, { name, ids }); model.toast(`Created ${name}`, "success"); close(); model.dataChanged(); },
  });
  return (
    <Modal title="Add to collection" onClose={close} width={460}>
      <button className="glass-button wide" onClick={create}><Icon name="plus" size={15} /> New collection</button>
      {!data ? <Spinner /> : <div className="rows">{data.Items.map((c) => (
        <button key={c.Id} className="row" disabled={busy} onClick={() => void add(c)}>
          <Cover url={cardImage(api, c, "poster", 56)} width={40} height={60} radius={6} icon="collection" />
          <div className="row-text"><div className="row-title">{c.Name}</div><div className="row-sub">{c.ChildCount ?? 0} items</div></div>
        </button>
      ))}</div>}
    </Modal>
  );
}

// MARK: Quick Connect, SyncPlay, remote control

function QuickConnectApprove({ close }: { close: () => void }) {
  const model = useModel();
  const [code, setCode] = useState("");
  const { busy, run } = useAction();
  return (
    <Modal title="Quick Connect" onClose={close} width={420}>
      <form className="form" onSubmit={async (e) => { e.preventDefault(); if (await run(() => model.api!.quickConnectAuthorize(code.trim()), "Device signed in")) close(); }}>
        <p className="muted">Enter the code shown on the device you want to sign in.</p>
        <Field label="Code"><input autoFocus className="code-input" value={code} onChange={(e) => setCode(e.target.value.replace(/\D/g, "").slice(0, 6))} inputMode="numeric" /></Field>
        <button className="glass-button prominent" disabled={busy || code.length < 6}>Authorize</button>
      </form>
    </Modal>
  );
}

function SyncPlay({ close }: { close: () => void }) {
  const model = useModel();
  const api = model.api!;
  const socket = getSocket();
  const { data, reload } = useLoad(() => api.get<SyncPlayGroup[]>("/SyncPlay/List"), []);
  const { busy, run } = useAction();
  const group = socket?.syncGroup;
  return (
    <Modal title="SyncPlay" onClose={close} width={480}>
      <p className="muted">Watch together: everyone in a group plays, pauses and seeks at the same time.</p>
      {group ? (
        <div className="stack">
          <div className="row static"><Icon name="syncplay" size={20} /><div className="row-text"><div className="row-title">{group.GroupName}</div><div className="row-sub">{group.Participants.join(", ")}</div></div></div>
          <button className="glass-button danger" disabled={busy} onClick={() => void run(async () => { await api.post("/SyncPlay/Leave"); socket?.leftGroup(); reload(); }, "Left the group")}>Leave group</button>
        </div>
      ) : (
        <>
          <button className="glass-button prominent wide" disabled={busy} onClick={() => void run(async () => { await api.post("/SyncPlay/New", { GroupName: `${model.user?.Name}'s group` }); reload(); }, "Group created")}><Icon name="plus" size={15} /> New group</button>
          {!data ? <Spinner /> : !data.length ? <p className="muted">No groups yet.</p> : (
            <div className="rows">{data.map((g) => (
              <button key={g.GroupId} className="row" disabled={busy} onClick={() => void run(async () => { await api.post("/SyncPlay/Join", { GroupId: g.GroupId }); reload(); }, `Joined ${g.GroupName}`)}>
                <Icon name="users" size={18} /><div className="row-text"><div className="row-title">{g.GroupName}</div><div className="row-sub">{g.Participants.join(", ")} · {g.State}</div></div>
              </button>
            ))}</div>
          )}
        </>
      )}
    </Modal>
  );
}

function RemoteControl({ close }: { close: () => void }) {
  const model = useModel();
  const api = model.api!;
  const { data, reload } = useLoad(() => api.get<SessionInfo[]>("/Sessions", { controllableByUserId: api.userId, activeWithinSeconds: 960 }), []);
  const [target, setTarget] = useState<string | null>(null);
  useEffect(() => { const t = setInterval(reload, 3000); return () => clearInterval(t); }, []); // eslint-disable-line react-hooks/exhaustive-deps
  const sessions = (data ?? []).filter((s) => s.DeviceId !== api.deviceId && s.SupportsRemoteControl);
  const s = sessions.find((x) => x.Id === target) ?? sessions[0];
  const cmd = (path: string, query?: Record<string, string | number>) => api.post(`/Sessions/${s!.Id}/${path}`, undefined, query).catch((e) => model.fail(e));
  return (
    <Modal title="Remote control" onClose={close} width={520}>
      {!data ? <Spinner /> : !sessions.length ? <Empty icon="remote" title="No other devices" text="Open Jellyfin on another device signed in as you, and it shows up here." /> : (
        <>
          <Dropdown label={s?.DeviceName ?? "Device"} icon="devices" items={sessions.map((x) => ({ value: x.Id!, label: `${x.DeviceName} (${x.Client})`, selected: x.Id === s?.Id }))} onPick={setTarget} align="left" />
          {s?.NowPlayingItem ? (
            <div className="remote-now">
              <Cover url={cardImage(api, s.NowPlayingItem, "landscape", 280)} width={240} height={135} radius={10} />
              <strong>{s.NowPlayingItem.Name}</strong>
              <div className="row-line">
                <button className="round-button" onClick={() => void cmd("Playing/PreviousTrack")}><Icon name="prev" size={16} /></button>
                <button className="round-button" onClick={() => void cmd("Playing/Rewind")}><Icon name="rewind10" size={16} /></button>
                <button className="round-button big" onClick={() => void cmd("Playing/PlayPause")}><Icon name={s.PlayState?.IsPaused ? "playFill" : "pauseFill"} size={20} /></button>
                <button className="round-button" onClick={() => void cmd("Playing/FastForward")}><Icon name="forward10" size={16} /></button>
                <button className="round-button" onClick={() => void cmd("Playing/NextTrack")}><Icon name="next" size={16} /></button>
                <button className="round-button" onClick={() => void cmd("Playing/Stop")}><Icon name="x" size={16} /></button>
              </div>
              <div className="row-line">
                <button className="glass-button" onClick={() => void cmd("Command/VolumeDown")}><Icon name="volumeLow" size={15} /></button>
                <button className="glass-button" onClick={() => void cmd("Command/ToggleMute")}><Icon name="mute" size={15} /></button>
                <button className="glass-button" onClick={() => void cmd("Command/VolumeUp")}><Icon name="volume" size={15} /></button>
              </div>
            </div>
          ) : <p className="muted">Nothing is playing on {s?.DeviceName}.</p>}
          <button className="glass-button" onClick={() => model.player?.state.item && void cmd("Playing", { playCommand: "PlayNow", itemIds: model.player.state.item.Id })} disabled={!model.player?.state.item}>
            <Icon name="external" size={15} /> Send what I'm playing there
          </button>
        </>
      )}
    </Modal>
  );
}

export type { ItemsResult };
