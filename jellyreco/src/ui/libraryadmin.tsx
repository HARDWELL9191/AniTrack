// Library management, as in Jellyfin's web client:
// - on every library (its page's "⋯" button, or right-click it in the sidebar): scan library
//   files, refresh metadata, edit images, manage library, rename, remove
// - the full library options editor (also used when adding a library): real-time monitoring,
//   metadata language and country, automatic refresh, embedded titles and episode info,
//   subtitles, chapter and trickplay images, saving metadata/subtitles/lyrics next to the media,
//   metadata savers, local metadata readers, and per item type the metadata downloaders, image
//   downloaders, similar-item providers and image limits, plus subtitle and lyric downloaders and
//   media segment providers, each with on/off and priority order.
// The names and the way options are saved follow jellyfin-web's libraryoptionseditor.

import { type ReactNode, useEffect, useState } from "react";
import type { AppModel } from "../core/model";
import type { Item } from "../core/types";
import { type DropItem, Field, Spinner, useLoad } from "./components";
import { Icon } from "./icons";
import { ui, useModel } from "./state";

type Action = () => void;

export interface LibraryOptionInfo { Name: string; DefaultEnabled: boolean }
interface TypeAvailable { Type: string; MetadataFetchers?: LibraryOptionInfo[]; ImageFetchers?: LibraryOptionInfo[]; SimilarItemProviders?: LibraryOptionInfo[]; SupportedImageTypes?: string[]; DefaultImageOptions?: ImageOption[] }
export interface AvailableOptions {
  MetadataSavers?: LibraryOptionInfo[]; MetadataReaders?: LibraryOptionInfo[]; SubtitleFetchers?: LibraryOptionInfo[]; LyricFetchers?: LibraryOptionInfo[];
  MediaSegmentProviders?: LibraryOptionInfo[]; TypeOptions?: TypeAvailable[];
}
interface ImageOption { Type: string; Limit: number; MinWidth: number }
interface TypeOptions { Type: string; MetadataFetchers?: string[]; MetadataFetcherOrder?: string[]; ImageFetchers?: string[]; ImageFetcherOrder?: string[]; SimilarItemProviders?: string[]; SimilarItemProviderOrder?: string[]; ImageOptions?: ImageOption[] }
export type LibraryOptions = Record<string, unknown> & { TypeOptions?: TypeOptions[] };

interface Culture { DisplayName: string; TwoLetterISOLanguageName: string; ThreeLetterISOLanguageName?: string }
interface Country { DisplayName: string; TwoLetterISORegionName: string }

// MARK: The library menu

/** What an administrator can do with a library (jellyfin-web's library card menu). */
export function libraryAdminItems(model: AppModel, view: Item): DropItem<Action>[] {
  if (!model.isAdmin) return [];
  const api = model.api!;
  const name = view.Name ?? "";
  const run = async (f: () => Promise<unknown>, done: string) => { try { await f(); model.toast(done, "success"); } catch (e) { model.fail(e); } };
  return [
    { section: "Library" },
    { value: () => void run(() => api.refreshItem(view.Id, { metadata: "Default", images: "Default", replaceMetadata: false, replaceImages: false }), `Scanning ${name}`), label: "Scan library files", icon: "refresh" },
    { value: () => ui.openSheet({ kind: "refresh", item: { ...view, Type: "CollectionFolder" } }), label: "Refresh metadata…", icon: "sparkles" },
    { value: () => ui.openSheet({ kind: "editImages", item: { ...view, Type: "CollectionFolder" } }), label: "Edit images…", icon: "image" },
    { value: () => { ui.push(model.tab, { kind: "dashboard", page: "library", arg: name }); }, label: "Manage library", icon: "settings" },
    { value: () => ui.openSheet({ kind: "prompt", title: `Rename ${name}`, label: "New name", initial: name, confirmLabel: "Rename", run: async (n) => { await api.post("/Library/VirtualFolders/Name", undefined, { name, newName: n, refreshLibrary: true }); await model.loadViews(); model.toast("Renamed", "success"); } }), label: "Rename…", icon: "edit" },
    { value: () => ui.openSheet({ kind: "confirm", danger: true, title: `Remove ${name}?`, text: "The library is removed from Jellyfin. Your files on disk are not deleted.", confirmLabel: "Remove", run: async () => { await api.del("/Library/VirtualFolders", { name, refreshLibrary: true }); await model.loadViews(); model.tab = "home"; model.notify(); } }), label: "Remove library…", icon: "trash", danger: true },
  ];
}

// MARK: The options editor

const CHAPTER_TYPES = ["homevideos", "movies", "musicvideos", "tvshows"];
const REFRESH_DAYS = [0, 30, 60, 90];

/** Plugins in the configured order (unknown names first, as jellyfin-web sorts them). */
function ordered(plugins: LibraryOptionInfo[] = [], order: string[] = []) {
  return [...plugins].sort((a, b) => order.indexOf(a.Name) - order.indexOf(b.Name));
}

const TYPE_LABELS: Record<string, string> = {
  Series: "Shows", Season: "Seasons", Episode: "Episodes", Movie: "Movies", MusicVideo: "Music videos", MusicAlbum: "Albums", MusicArtist: "Artists",
  Audio: "Songs", BoxSet: "Collections", Book: "Books", AudioBook: "Audiobooks", Person: "People", Video: "Videos", Photo: "Photos", PhotoAlbum: "Photo albums", Trailer: "Trailers",
};

export function LibraryOptionsEditor({ contentType, isNew, value, onChange }: { contentType: string | null | undefined; isNew: boolean; value: LibraryOptions; onChange: (v: LibraryOptions) => void }) {
  const model = useModel();
  const api = model.api!;
  const type = contentType && contentType !== "mixed" ? contentType : "";
  const { data: avail } = useLoad(() => api.get<AvailableOptions>("/Libraries/AvailableOptions", { libraryContentType: type || undefined, isNewLibrary: isNew }), [type, isNew]);
  const { data: cultures } = useLoad(() => api.get<Culture[]>("/Localization/Cultures").catch(() => [] as Culture[]), []);
  const { data: countries } = useLoad(() => api.get<Country[]>("/Localization/Countries").catch(() => [] as Country[]), []);
  const [imageType, setImageType] = useState<string | null>(null);

  // Fill in explicit lists (as jellyfin-web saves them) once the available plugins are known.
  useEffect(() => {
    if (!avail) return;
    const o: LibraryOptions = { ...value };
    const pick = (plugins: LibraryOptionInfo[] = [], enabled?: string[]) => plugins.filter((p) => (enabled ? enabled.includes(p.Name) : p.DefaultEnabled)).map((p) => p.Name);
    const disabled = (plugins: LibraryOptionInfo[] = [], dis?: string[]) => (dis ? dis : plugins.filter((p) => !p.DefaultEnabled).map((p) => p.Name));
    o.MetadataSavers = pick(avail.MetadataSavers, value.MetadataSavers as string[] | undefined);
    o.LocalMetadataReaderOrder = ordered(avail.MetadataReaders, (value.LocalMetadataReaderOrder as string[]) ?? []).map((p) => p.Name);
    o.DisabledSubtitleFetchers = disabled(avail.SubtitleFetchers, value.DisabledSubtitleFetchers as string[] | undefined);
    o.SubtitleFetcherOrder = ordered(avail.SubtitleFetchers, (value.SubtitleFetcherOrder as string[]) ?? []).map((p) => p.Name);
    o.DisabledLyricFetchers = disabled(avail.LyricFetchers, value.DisabledLyricFetchers as string[] | undefined);
    o.LyricFetcherOrder = ordered(avail.LyricFetchers, (value.LyricFetcherOrder as string[]) ?? []).map((p) => p.Name);
    o.DisabledMediaSegmentProviders = disabled(avail.MediaSegmentProviders, value.DisabledMediaSegmentProviders as string[] | undefined);
    o.MediaSegmentProviderOrder = ordered(avail.MediaSegmentProviders, (value.MediaSegmentProviderOrder as string[]) ?? []).map((p) => p.Name);
    const types: TypeOptions[] = [...(value.TypeOptions ?? [])];
    for (const t of avail.TypeOptions ?? []) {
      const i = types.findIndex((x) => x.Type === t.Type);
      const cur: TypeOptions = i >= 0 ? { ...types[i] } : { Type: t.Type };
      cur.MetadataFetchers = pick(t.MetadataFetchers, cur.MetadataFetchers);
      cur.MetadataFetcherOrder = ordered(t.MetadataFetchers, cur.MetadataFetcherOrder ?? []).map((p) => p.Name);
      cur.ImageFetchers = pick(t.ImageFetchers, cur.ImageFetchers);
      cur.ImageFetcherOrder = ordered(t.ImageFetchers, cur.ImageFetcherOrder ?? []).map((p) => p.Name);
      if (t.SimilarItemProviders?.length) {
        cur.SimilarItemProviders = pick(t.SimilarItemProviders, cur.SimilarItemProviders);
        cur.SimilarItemProviderOrder = ordered(t.SimilarItemProviders, cur.SimilarItemProviderOrder ?? []).map((p) => p.Name);
      }
      if (i >= 0) types[i] = cur; else types.push(cur);
    }
    o.TypeOptions = types;
    if (JSON.stringify(o) !== JSON.stringify(value)) onChange(o);
  }, [avail]); // eslint-disable-line react-hooks/exhaustive-deps

  if (!avail) return <Spinner />;
  const set = (patch: Record<string, unknown>) => onChange({ ...value, ...patch });
  const bool = (k: string) => value[k] === true;
  const str = (k: string) => (typeof value[k] === "string" ? (value[k] as string) : "");
  const arr = (k: string) => (Array.isArray(value[k]) ? (value[k] as string[]) : []);
  const typeOpts = (t: string) => value.TypeOptions?.find((x) => x.Type === t) ?? { Type: t };
  const setType = (t: string, patch: Partial<TypeOptions>) => {
    const list = [...(value.TypeOptions ?? [])];
    const i = list.findIndex((x) => x.Type === t);
    if (i >= 0) list[i] = { ...list[i], ...patch }; else list.push({ Type: t, ...patch });
    onChange({ ...value, TypeOptions: list });
  };
  const hasChapters = !type || CHAPTER_TYPES.includes(type);
  const isTv = type === "tvshows", isMusic = type === "music";
  const embedded = !["books", "boxsets", "playlists", "music"].includes(type);
  const subtitles = !type || ["tvshows", "movies", "musicvideos", "mixed"].includes(type);

  return (
    <div className="lib-options">
      <OptionGroup title="General">
        <Check label="Enabled" detail="Include this library in scans and on your home screen" value={value.Enabled !== false} onChange={(v) => set({ Enabled: v })} />
        <Check label="Real-time monitoring" detail="Changes to files are picked up straight away on supported file systems" value={bool("EnableRealtimeMonitor")} onChange={(v) => set({ EnableRealtimeMonitor: v })} />
        {(type === "homevideos" || type === "photos") && <Check label="Display photos" value={bool("EnablePhotos")} onChange={(v) => set({ EnablePhotos: v })} />}
        {isMusic && <Check label="Audio normalization (LUFS scan)" detail="Analyses loudness so tracks play at a similar volume" value={bool("EnableLUFSScan")} onChange={(v) => set({ EnableLUFSScan: v })} />}
        {isTv && <Check label="Automatically merge series spread across multiple folders" value={bool("EnableAutomaticSeriesGrouping")} onChange={(v) => set({ EnableAutomaticSeriesGrouping: v })} />}
        {(type === "movies" || !type) && <Check label="Automatically add to collection" detail="Movies of the same collection (from TMDB) are grouped" value={bool("AutomaticallyAddToCollection")} onChange={(v) => set({ AutomaticallyAddToCollection: v })} />}
        {isTv && <Field label="Season zero display name"><input value={str("SeasonZeroDisplayName") || "Specials"} onChange={(e) => set({ SeasonZeroDisplayName: e.target.value })} /></Field>}
      </OptionGroup>

      <OptionGroup title="Metadata">
        <div className="form grid-2">
          <Field label="Preferred download language">
            <select value={str("PreferredMetadataLanguage")} onChange={(e) => set({ PreferredMetadataLanguage: e.target.value })}>
              <option value="">Server default</option>
              {(cultures ?? []).map((c) => <option key={c.TwoLetterISOLanguageName + c.DisplayName} value={c.TwoLetterISOLanguageName}>{c.DisplayName}</option>)}
            </select>
          </Field>
          <Field label="Country/region">
            <select value={str("MetadataCountryCode")} onChange={(e) => set({ MetadataCountryCode: e.target.value })}>
              <option value="">Server default</option>
              {(countries ?? []).map((c) => <option key={c.TwoLetterISORegionName} value={c.TwoLetterISORegionName}>{c.DisplayName}</option>)}
            </select>
          </Field>
          <Field label="Automatically refresh metadata from the internet">
            <select value={String(value.AutomaticRefreshIntervalDays ?? 0)} onChange={(e) => set({ AutomaticRefreshIntervalDays: Number(e.target.value) })}>
              {REFRESH_DAYS.map((d) => <option key={d} value={d}>{d ? `Every ${d} days` : "Never"}</option>)}
            </select>
          </Field>
        </div>
        {embedded && <Check label="Prefer embedded titles over filenames" detail="Uses the title stored inside the file, if there is one" value={bool("EnableEmbeddedTitles")} onChange={(v) => set({ EnableEmbeddedTitles: v })} />}
        {embedded && bool("EnableEmbeddedTitles") && <Check label="Prefer embedded titles for extras" value={bool("EnableEmbeddedExtrasTitles")} onChange={(v) => set({ EnableEmbeddedExtrasTitles: v })} />}
        {isTv && <Check label="Prefer embedded episode information over filenames" value={bool("EnableEmbeddedEpisodeInfos")} onChange={(v) => set({ EnableEmbeddedEpisodeInfos: v })} />}
        <Check label="Save artwork into media folders" detail="Images and metadata are kept next to your media, where other apps can use them" value={bool("SaveLocalMetadata")} onChange={(v) => set({ SaveLocalMetadata: v })} />
        <PluginChecks title="Metadata savers" help="File formats to save your metadata to." plugins={avail.MetadataSavers ?? []} enabled={arr("MetadataSavers")} onChange={(names) => set({ MetadataSavers: names })} />
        {(avail.MetadataReaders?.length ?? 0) > 1 && (
          <PluginOrder title="Metadata readers" help="Local metadata sources in order of priority. The first file found is read." plugins={ordered(avail.MetadataReaders, arr("LocalMetadataReaderOrder"))} onOrder={(names) => set({ LocalMetadataReaderOrder: names })} />
        )}
      </OptionGroup>

      {(avail.TypeOptions ?? []).map((t) => {
        const o = typeOpts(t.Type);
        const label = TYPE_LABELS[t.Type] ?? t.Type;
        return (
          <OptionGroup key={t.Type} title={`${label}: downloaders`}>
            {!!t.MetadataFetchers?.length && (
              <PluginList title="Metadata downloaders" help="Enable and rank your preferred metadata downloaders. Lower priority downloaders are only used to fill in missing information."
                plugins={ordered(t.MetadataFetchers, o.MetadataFetcherOrder)} enabled={o.MetadataFetchers ?? []}
                onChange={(enabled, order) => setType(t.Type, { MetadataFetchers: enabled, MetadataFetcherOrder: order })} />
            )}
            {!!t.ImageFetchers?.length && (
              <PluginList title="Image downloaders" help="Enable and rank your preferred image fetchers in order of priority."
                plugins={ordered(t.ImageFetchers, o.ImageFetcherOrder)} enabled={o.ImageFetchers ?? []}
                onChange={(enabled, order) => setType(t.Type, { ImageFetchers: enabled, ImageFetcherOrder: order })}
                extra={<button className="glass-button" onClick={() => setImageType(imageType === t.Type ? null : t.Type)}><Icon name="image" size={14} /> Fetcher settings</button>} />
            )}
            {imageType === t.Type && <ImageOptions avail={t} options={o} onChange={(ImageOptions) => setType(t.Type, { ImageOptions })} />}
            {!!t.SimilarItemProviders?.length && (
              <PluginList title="Similar item providers" help="Enable and rank the sources used for similar items."
                plugins={ordered(t.SimilarItemProviders, o.SimilarItemProviderOrder)} enabled={o.SimilarItemProviders ?? []}
                onChange={(enabled, order) => setType(t.Type, { SimilarItemProviders: enabled, SimilarItemProviderOrder: order })} />
            )}
          </OptionGroup>
        );
      })}

      {subtitles && (
        <OptionGroup title="Subtitles">
          <Field label="Allow embedded subtitles">
            <select value={str("AllowEmbeddedSubtitles") || "AllowAll"} onChange={(e) => set({ AllowEmbeddedSubtitles: e.target.value })}>
              <option value="AllowAll">Allow all</option>
              <option value="AllowText">Allow text</option>
              <option value="AllowImage">Allow image</option>
              <option value="AllowNone">Allow none</option>
            </select>
          </Field>
          {!!avail.SubtitleFetchers?.length && (
            <PluginList title="Subtitle downloaders" help="Enable and rank your preferred subtitle downloaders in order of priority."
              plugins={ordered(avail.SubtitleFetchers, arr("SubtitleFetcherOrder"))} enabled={(avail.SubtitleFetchers ?? []).map((p) => p.Name).filter((n) => !arr("DisabledSubtitleFetchers").includes(n))}
              onChange={(enabled, order) => set({ DisabledSubtitleFetchers: order.filter((n) => !enabled.includes(n)), SubtitleFetcherOrder: order })} />
          )}
          <LanguageChecks cultures={cultures ?? []} value={arr("SubtitleDownloadLanguages")} onChange={(v) => set({ SubtitleDownloadLanguages: v })} />
          <Check label="Only download subtitles that are a perfect match for my video files" value={value.RequirePerfectSubtitleMatch !== false} onChange={(v) => set({ RequirePerfectSubtitleMatch: v })} />
          <Check label="Skip if the video already has embedded subtitles" value={bool("SkipSubtitlesIfEmbeddedSubtitlesPresent")} onChange={(v) => set({ SkipSubtitlesIfEmbeddedSubtitlesPresent: v })} />
          <Check label="Skip if the default audio track matches the download language" value={bool("SkipSubtitlesIfAudioTrackMatches")} onChange={(v) => set({ SkipSubtitlesIfAudioTrackMatches: v })} />
          <Check label="Save subtitles into media folders" value={value.SaveSubtitlesWithMedia !== false} onChange={(v) => set({ SaveSubtitlesWithMedia: v })} />
        </OptionGroup>
      )}

      {isMusic && (
        <OptionGroup title="Lyrics and tags">
          {!!avail.LyricFetchers?.length && (
            <PluginList title="Lyric downloaders" help="Enable and rank your preferred lyric downloaders in order of priority."
              plugins={ordered(avail.LyricFetchers, arr("LyricFetcherOrder"))} enabled={(avail.LyricFetchers ?? []).map((p) => p.Name).filter((n) => !arr("DisabledLyricFetchers").includes(n))}
              onChange={(enabled, order) => set({ DisabledLyricFetchers: order.filter((n) => !enabled.includes(n)), LyricFetcherOrder: order })} />
          )}
          <Check label="Save lyrics into media folders" value={bool("SaveLyricsWithMedia")} onChange={(v) => set({ SaveLyricsWithMedia: v })} />
          <Check label="Prefer the non-standard artists tag" detail="Use the ARTISTS tag instead of ARTIST when available" value={bool("PreferNonstandardArtistsTag")} onChange={(v) => set({ PreferNonstandardArtistsTag: v })} />
          <Check label="Use custom tag delimiters" value={bool("UseCustomTagDelimiters")} onChange={(v) => set({ UseCustomTagDelimiters: v })} />
          {bool("UseCustomTagDelimiters") && (
            <div className="form grid-2">
              <Field label="Custom tag delimiters" hint="Each character splits a tag"><input value={arr("CustomTagDelimiters").join("")} onChange={(e) => set({ CustomTagDelimiters: e.target.value.split("") })} /></Field>
              <Field label="Delimiter whitelist" hint="One per line: names that contain a delimiter but shouldn't be split"><textarea rows={3} value={arr("DelimiterWhitelist").join("\n")} onChange={(e) => set({ DelimiterWhitelist: e.target.value.split("\n").filter((x) => x.trim()) })} /></Field>
            </div>
          )}
        </OptionGroup>
      )}

      {!!avail.MediaSegmentProviders?.length && (
        <OptionGroup title="Media segments">
          <PluginList title="Media segment providers" help="Enable and rank the providers that find intros, credits and other segments."
            plugins={ordered(avail.MediaSegmentProviders, arr("MediaSegmentProviderOrder"))} enabled={(avail.MediaSegmentProviders ?? []).map((p) => p.Name).filter((n) => !arr("DisabledMediaSegmentProviders").includes(n))}
            onChange={(enabled, order) => set({ DisabledMediaSegmentProviders: order.filter((n) => !enabled.includes(n)), MediaSegmentProviderOrder: order })} />
        </OptionGroup>
      )}

      {hasChapters && (
        <OptionGroup title="Trickplay and chapter images">
          <Check label="Enable trickplay image extraction" detail="Preview pictures while you scrub through a video" value={bool("EnableTrickplayImageExtraction")} onChange={(v) => set({ EnableTrickplayImageExtraction: v })} />
          <Check label="Extract trickplay images during the library scan" detail="Otherwise they're made by the scheduled task" value={bool("ExtractTrickplayImagesDuringLibraryScan")} onChange={(v) => set({ ExtractTrickplayImagesDuringLibraryScan: v })} />
          <Check label="Save trickplay images into media folders" value={bool("SaveTrickplayWithMedia")} onChange={(v) => set({ SaveTrickplayWithMedia: v })} />
          <Check label="Enable chapter image extraction" value={bool("EnableChapterImageExtraction")} onChange={(v) => set({ EnableChapterImageExtraction: v })} />
          <Check label="Extract chapter images during the library scan" value={bool("ExtractChapterImagesDuringLibraryScan")} onChange={(v) => set({ ExtractChapterImagesDuringLibraryScan: v })} />
        </OptionGroup>
      )}
    </div>
  );
}

function OptionGroup({ title, children }: { title: string; children: ReactNode }) {
  return <section className="lib-group"><h3>{title}</h3>{children}</section>;
}

function Check({ label, detail, value, onChange }: { label: string; detail?: string; value: boolean; onChange: (v: boolean) => void }) {
  return (
    <label className="toggle-row">
      <span className="toggle-text"><span>{label}</span>{detail && <small className="muted">{detail}</small>}</span>
      <input type="checkbox" className="switch" checked={value} onChange={(e) => onChange(e.target.checked)} />
    </label>
  );
}

function PluginChecks({ title, help, plugins, enabled, onChange }: { title: string; help: string; plugins: LibraryOptionInfo[]; enabled: string[]; onChange: (names: string[]) => void }) {
  if (!plugins.length) return null;
  return (
    <div className="plugin-list">
      <div className="plugin-head"><strong>{title}</strong><small className="muted">{help}</small></div>
      {plugins.map((p) => (
        <label key={p.Name} className="plugin-row">
          <input type="checkbox" checked={enabled.includes(p.Name)} onChange={(e) => onChange(e.target.checked ? [...enabled, p.Name] : enabled.filter((n) => n !== p.Name))} />
          <span>{p.Name}</span>
        </label>
      ))}
    </div>
  );
}

/** A list of plugins with on/off and up/down (priority). */
function PluginList({ title, help, plugins, enabled, onChange, extra }: { title: string; help: string; plugins: LibraryOptionInfo[]; enabled: string[]; onChange: (enabled: string[], order: string[]) => void; extra?: ReactNode }) {
  const order = plugins.map((p) => p.Name);
  const move = (i: number, d: number) => { const o = [...order]; [o[i], o[i + d]] = [o[i + d], o[i]]; onChange(enabled, o); };
  return (
    <div className="plugin-list">
      <div className="plugin-head"><strong>{title}</strong><small className="muted">{help}</small>{extra}</div>
      {plugins.map((p, i) => (
        <div key={p.Name} className="plugin-row">
          <input type="checkbox" aria-label={`Use ${p.Name}`} checked={enabled.includes(p.Name)} onChange={(e) => onChange(e.target.checked ? [...enabled, p.Name] : enabled.filter((n) => n !== p.Name), order)} />
          <span>{p.Name}</span>
          <span className="plugin-order">
            <button className="round-button" disabled={i === 0} onClick={() => move(i, -1)} aria-label="Higher priority"><Icon name="arrowUp" size={14} /></button>
            <button className="round-button" disabled={i === plugins.length - 1} onClick={() => move(i, 1)} aria-label="Lower priority"><Icon name="arrowDown" size={14} /></button>
          </span>
        </div>
      ))}
    </div>
  );
}

function PluginOrder({ title, help, plugins, onOrder }: { title: string; help: string; plugins: LibraryOptionInfo[]; onOrder: (names: string[]) => void }) {
  const order = plugins.map((p) => p.Name);
  const move = (i: number, d: number) => { const o = [...order]; [o[i], o[i + d]] = [o[i + d], o[i]]; onOrder(o); };
  return (
    <div className="plugin-list">
      <div className="plugin-head"><strong>{title}</strong><small className="muted">{help}</small></div>
      {plugins.map((p, i) => (
        <div key={p.Name} className="plugin-row">
          <Icon name="layers" size={15} />
          <span>{p.Name}</span>
          <span className="plugin-order">
            <button className="round-button" disabled={i === 0} onClick={() => move(i, -1)} aria-label="Higher priority"><Icon name="arrowUp" size={14} /></button>
            <button className="round-button" disabled={i === plugins.length - 1} onClick={() => move(i, 1)} aria-label="Lower priority"><Icon name="arrowDown" size={14} /></button>
          </span>
        </div>
      ))}
    </div>
  );
}

const IMAGE_LABELS: Record<string, string> = { Primary: "Primary", Art: "Art", Banner: "Banner", Disc: "Disc", Logo: "Logo", Thumb: "Thumb", Box: "Box", BoxRear: "Box (rear)", Menu: "Menu", Screenshot: "Screenshot", Chapter: "Chapter", Profile: "Profile" };

/** Which images to download for a type, and how many backdrops (jellyfin-web's "Fetcher settings"). */
function ImageOptions({ avail, options, onChange }: { avail: TypeAvailable; options: TypeOptions; onChange: (v: ImageOption[]) => void }) {
  const types = (avail.SupportedImageTypes ?? []).filter((t) => t !== "Backdrop");
  const config = (t: string): ImageOption => options.ImageOptions?.find((x) => x.Type === t) ?? avail.DefaultImageOptions?.find((x) => x.Type === t) ?? { Type: t, Limit: t === "Primary" ? 1 : 0, MinWidth: 0 };
  const all = (patch: ImageOption) => {
    const list = [...types.map(config), ...((avail.SupportedImageTypes ?? []).includes("Backdrop") ? [config("Backdrop")] : [])].map((o) => (o.Type === patch.Type ? patch : o));
    onChange(list);
  };
  const back = config("Backdrop");
  return (
    <div className="plugin-list">
      <div className="plugin-head"><strong>Images to download</strong></div>
      <div className="image-type-grid">
        {types.map((t) => (
          <label key={t} className="plugin-row"><input type="checkbox" checked={config(t).Limit > 0} onChange={(e) => all({ Type: t, Limit: e.target.checked ? 1 : 0, MinWidth: 0 })} /><span>{IMAGE_LABELS[t] ?? t}</span></label>
        ))}
      </div>
      {(avail.SupportedImageTypes ?? []).includes("Backdrop") && (
        <div className="form grid-2">
          <Field label="Maximum number of backdrops per item"><input type="number" min={0} value={back.Limit} onChange={(e) => all({ ...back, Limit: Number(e.target.value) || 0 })} /></Field>
          <Field label="Minimum backdrop download width"><input type="number" min={0} value={back.MinWidth} onChange={(e) => all({ ...back, MinWidth: Number(e.target.value) || 0 })} /></Field>
        </div>
      )}
    </div>
  );
}

function LanguageChecks({ cultures, value, onChange }: { cultures: Culture[]; value: string[]; onChange: (v: string[]) => void }) {
  const [open, setOpen] = useState(value.length > 0);
  const langs = cultures.filter((c) => c.ThreeLetterISOLanguageName);
  return (
    <div className="plugin-list">
      <button className="text-button" onClick={() => setOpen(!open)}><Icon name={open ? "chevronDown" : "chevronRight"} size={14} /> Download languages <span className="muted small">({value.length ? value.join(", ") : "none"})</span></button>
      {open && (
        <div className="language-grid">
          {langs.map((c) => (
            <label key={c.ThreeLetterISOLanguageName! + c.DisplayName} className="plugin-row">
              <input type="checkbox" checked={value.includes(c.ThreeLetterISOLanguageName!)} onChange={(e) => onChange(e.target.checked ? [...value, c.ThreeLetterISOLanguageName!] : value.filter((x) => x !== c.ThreeLetterISOLanguageName))} />
              <span>{c.DisplayName}</span>
            </label>
          ))}
        </div>
      )}
    </div>
  );
}
