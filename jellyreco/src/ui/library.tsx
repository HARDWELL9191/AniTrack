// Libraries: a tab bar per library type (like jellyfin-web, rearranged), a grid or list with sort,
// filters and A–Z, plus the pages for a person, genre, studio, "see all" lists and the TV guide.

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { LIST_FIELDS, type Query } from "../core/api";
import type { Item, ItemsResult } from "../core/types";
import { ticksToSeconds } from "../core/types";
import {
  backdropUrl, cardImage, Cover, Dropdown, Empty, ErrorNote, Grid, isPlayable, ItemCard, ItemRow, LoadMore, PageHeader, Segmented, Shelf, Spinner, useLoad,
} from "./components";
import { clock, dateOnly } from "./fmt";
import { Icon } from "./icons";
import { routeFor, ui, useModel, useNavigate } from "./state";

type TabDef = { id: string; label: string; query?: Query; kind?: "items" | "genres" | "studios" | "artists" | "albumArtists" | "persons" | "guide" | "recordings" | "timers" | "channels" | "suggestions" | "upcoming" | "folders"; types?: string[] };

function tabsFor(collectionType?: string | null): TabDef[] {
  switch (collectionType) {
    case "movies": return [
      { id: "movies", label: "Movies", types: ["Movie"] },
      { id: "suggestions", label: "Suggestions", kind: "suggestions" },
      { id: "collections", label: "Collections", types: ["BoxSet"] },
      { id: "favorites", label: "Favorites", types: ["Movie"], query: { filters: ["IsFavorite"] } },
      { id: "genres", label: "Genres", kind: "genres", types: ["Movie"] },
      { id: "studios", label: "Studios", kind: "studios", types: ["Movie"] },
    ];
    case "tvshows": return [
      { id: "shows", label: "Shows", types: ["Series"] },
      { id: "suggestions", label: "Suggestions", kind: "suggestions" },
      { id: "upcoming", label: "Upcoming", kind: "upcoming" },
      { id: "episodes", label: "Episodes", types: ["Episode"] },
      { id: "favorites", label: "Favorites", types: ["Series"], query: { filters: ["IsFavorite"] } },
      { id: "genres", label: "Genres", kind: "genres", types: ["Series"] },
      { id: "studios", label: "Networks", kind: "studios", types: ["Series"] },
    ];
    case "music": return [
      { id: "albums", label: "Albums", types: ["MusicAlbum"] },
      { id: "albumArtists", label: "Album artists", kind: "albumArtists" },
      { id: "artists", label: "Artists", kind: "artists" },
      { id: "songs", label: "Songs", types: ["Audio"] },
      { id: "playlists", label: "Playlists", types: ["Playlist"], query: { mediaTypes: ["Audio"] } },
      { id: "genres", label: "Genres", kind: "genres", types: ["MusicAlbum"] },
    ];
    case "musicvideos": return [{ id: "videos", label: "Music videos", types: ["MusicVideo"] }, { id: "folders", label: "Folders", kind: "folders" }];
    case "livetv": return [
      { id: "channels", label: "Channels", kind: "channels" },
      { id: "guide", label: "Guide", kind: "guide" },
      { id: "recordings", label: "Recordings", kind: "recordings" },
      { id: "schedule", label: "Schedule", kind: "timers" },
    ];
    case "boxsets": return [{ id: "collections", label: "Collections", types: ["BoxSet"] }];
    case "playlists": return [{ id: "playlists", label: "Playlists", types: ["Playlist"] }];
    case "books": return [{ id: "books", label: "Books", types: ["Book", "AudioBook"] }, { id: "folders", label: "Folders", kind: "folders" }];
    case "photos":
    case "homevideos": return [{ id: "folders", label: "Folders", kind: "folders" }, { id: "photos", label: "Photos", types: ["Photo"] }, { id: "videos", label: "Videos", types: ["Video"] }];
    default: return [{ id: "folders", label: "Folders", kind: "folders" }, { id: "all", label: "All items" }];
  }
}

const SORTS: { value: string; label: string; types?: string[] }[] = [
  { value: "SortName", label: "Name" },
  { value: "CommunityRating", label: "Community rating" },
  { value: "CriticRating", label: "Critic rating" },
  { value: "DateCreated", label: "Date added" },
  { value: "DatePlayed", label: "Date played" },
  { value: "PremiereDate", label: "Release date" },
  { value: "ProductionYear", label: "Year" },
  { value: "OfficialRating", label: "Parental rating" },
  { value: "PlayCount", label: "Play count" },
  { value: "Runtime", label: "Runtime" },
  { value: "Random", label: "Random" },
  { value: "SeriesDatePlayed", label: "Last episode watched", types: ["Series"] },
  { value: "DateLastContentAdded", label: "Last episode added", types: ["Series"] },
  { value: "AlbumArtist", label: "Album artist", types: ["MusicAlbum", "Audio"] },
  { value: "Album", label: "Album", types: ["Audio"] },
];

interface ViewState {
  sort: string;
  order: "Ascending" | "Descending";
  filters: string[];
  genres: string[];
  years: number[];
  ratings: string[];
  tags: string[];
  letter: string;
  layout: "grid" | "list";
  hasSubs?: boolean;
  is4K?: boolean;
  isHD?: boolean;
  hdr?: boolean;
  seriesStatus?: string;
}

const defaultView = (): ViewState => ({ sort: "SortName", order: "Ascending", filters: [], genres: [], years: [], ratings: [], tags: [], letter: "", layout: "grid" });

function useViewState(key: string): [ViewState, (p: Partial<ViewState>) => void] {
  const [v, setV] = useState<ViewState>(() => {
    try { return { ...defaultView(), ...JSON.parse(localStorage.getItem(`view-${key}`) ?? "{}"), letter: "" }; } catch { return defaultView(); }
  });
  const update = (p: Partial<ViewState>) => setV((old) => {
    const n = { ...old, ...p };
    try { localStorage.setItem(`view-${key}`, JSON.stringify({ ...n, letter: "" })); } catch { /* full */ }
    return n;
  });
  return [v, update];
}

export function LibraryPage({ view, back, refreshKey }: { view: Item; back?: () => void; refreshKey: number }) {
  const tabs = useMemo(() => tabsFor(view.CollectionType), [view.CollectionType]);
  const [tab, setTab] = useState(() => localStorage.getItem(`tab-${view.Id}`) ?? tabs[0].id);
  const active = tabs.find((t) => t.id === tab) ?? tabs[0];
  const choose = (id: string) => { setTab(id); try { localStorage.setItem(`tab-${view.Id}`, id); } catch { /* */ } };
  return (
    <div className="page">
      <PageHeader title={view.Name} back={back}>
        {tabs.length > 1 && (
          <div className="tabbar">
            {tabs.map((t) => <button key={t.id} className={t.id === active.id ? "on" : ""} onClick={() => choose(t.id)}>{t.label}</button>)}
          </div>
        )}
      </PageHeader>
      <TabContent key={active.id} view={view} tab={active} refreshKey={refreshKey} />
    </div>
  );
}

function TabContent({ view, tab, refreshKey }: { view: Item; tab: TabDef; refreshKey: number }) {
  switch (tab.kind) {
    case "genres": return <NamedGrid view={view} kind="genres" types={tab.types} />;
    case "studios": return <NamedGrid view={view} kind="studios" types={tab.types} />;
    case "artists": return <NamedGrid view={view} kind="artists" />;
    case "albumArtists": return <NamedGrid view={view} kind="albumArtists" />;
    case "suggestions": return <Suggestions view={view} refreshKey={refreshKey} />;
    case "upcoming": return <Upcoming view={view} />;
    case "channels": return <Channels />;
    case "guide": return <Guide />;
    case "recordings": return <Recordings />;
    case "timers": return <Timers />;
    case "folders": return <ItemBrowser key="folders" scopeKey={`${view.Id}-folders`} base={{ parentId: view.Id }} folders refreshKey={refreshKey} />;
    default: return <ItemBrowser scopeKey={`${view.Id}-${tab.id}`} base={{ parentId: view.Id, recursive: true, includeItemTypes: tab.types, ...tab.query }} types={tab.types} refreshKey={refreshKey} />;
  }
}

/** A paged grid/list of items with sort, filters and A–Z. */
export function ItemBrowser({ base, scopeKey, types, folders, refreshKey = 0, showControls = true }: { base: Query; scopeKey: string; types?: string[]; folders?: boolean; refreshKey?: number; showControls?: boolean }) {
  const model = useModel();
  const [v, setV] = useViewState(scopeKey);
  const [items, setItems] = useState<Item[]>([]);
  const [total, setTotal] = useState<number | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const loadingRef = useRef(false);
  const genFilters = useLoad(() => model.api!.filters(base.parentId as string | undefined, types), [base.parentId, types?.join()]);

  const query = useMemo((): Query => {
    const q: Query = { ...base, fields: [...LIST_FIELDS, "SeasonUserData"], enableUserData: true, imageTypeLimit: 1, enableImageTypes: ["Primary", "Backdrop", "Thumb"] };
    q.sortBy = v.sort === "SortName" ? ["SortName"] : [v.sort, "SortName"];
    q.sortOrder = v.sort === "SortName" ? [v.order] : [v.order, "Ascending"];
    const filters = [...((base.filters as string[] | undefined) ?? []), ...v.filters];
    if (filters.length) q.filters = filters;
    if (v.genres.length) q.genres = v.genres.join("|");
    if (v.years.length) q.years = v.years;
    if (v.ratings.length) q.officialRatings = v.ratings.join("|");
    if (v.tags.length) q.tags = v.tags.join("|");
    if (v.letter === "#") q.nameLessThan = "A";
    else if (v.letter) q.nameStartsWith = v.letter;
    if (v.hasSubs) q.hasSubtitles = true;
    if (v.is4K) q.is4K = true;
    if (v.isHD) q.isHd = true;
    if (v.hdr) q.videoTypes = undefined;
    if (v.seriesStatus) q.seriesStatus = v.seriesStatus;
    if (folders) { delete q.recursive; q.sortBy = ["IsFolder", ...(q.sortBy as string[])]; q.sortOrder = ["Descending", ...(q.sortOrder as string[])]; }
    return q;
  }, [base, v, folders]);
  const qKey = JSON.stringify(query);

  useEffect(() => {
    setItems([]);
    setTotal(null);
    setError(null);
  }, [qKey, refreshKey, model.dataVersion]);

  const loadMore = useCallback(async () => {
    if (loadingRef.current) return;
    if (total !== null && items.length >= total) return;
    loadingRef.current = true;
    setBusy(true);
    try {
      const r = await model.api!.items({ ...query, startIndex: items.length, limit: 120 });
      setItems((old) => (old.length === items.length ? [...old, ...r.Items] : old));
      setTotal(r.TotalRecordCount);
    } catch (e) {
      setError((e as Error).message);
    } finally {
      loadingRef.current = false;
      setBusy(false);
    }
  }, [model, query, items.length, total]);

  useEffect(() => { if (total === null && !error) void loadMore(); }, [total, error, loadMore]);

  const sorts = SORTS.filter((s) => !s.types || s.types.some((t) => types?.includes(t)));
  const filterItems = [
    { section: "Show" },
    { value: "IsUnplayed", label: "Unwatched", selected: v.filters.includes("IsUnplayed") },
    { value: "IsPlayed", label: "Watched", selected: v.filters.includes("IsPlayed") },
    { value: "IsResumable", label: "In progress", selected: v.filters.includes("IsResumable") },
    { value: "IsFavorite", label: "Favorites", selected: v.filters.includes("IsFavorite") },
    { value: "Likes", label: "Liked", selected: v.filters.includes("Likes") },
    { value: "Dislikes", label: "Disliked", selected: v.filters.includes("Dislikes") },
    "divider" as const,
    { section: "Features" },
    { value: "subs", label: "Has subtitles", selected: !!v.hasSubs },
    { value: "4k", label: "4K", selected: !!v.is4K },
    { value: "hd", label: "HD", selected: !!v.isHD },
    ...(types?.includes("Series") ? [{ section: "Status" }, { value: "Continuing", label: "Continuing", selected: v.seriesStatus === "Continuing" }, { value: "Ended", label: "Ended", selected: v.seriesStatus === "Ended" }] : []),
    ...(v.filters.length || v.genres.length || v.years.length || v.ratings.length || v.tags.length || v.hasSubs || v.is4K || v.isHD || v.seriesStatus ? ["divider" as const, { value: "clear", label: "Clear all filters", icon: "x" }] : []),
  ];
  const pickFilter = (val: string) => {
    if (val === "clear") return setV({ filters: [], genres: [], years: [], ratings: [], tags: [], hasSubs: false, is4K: false, isHD: false, seriesStatus: undefined });
    if (val === "subs") return setV({ hasSubs: !v.hasSubs });
    if (val === "4k") return setV({ is4K: !v.is4K });
    if (val === "hd") return setV({ isHD: !v.isHD });
    if (val === "Continuing" || val === "Ended") return setV({ seriesStatus: v.seriesStatus === val ? undefined : val });
    setV({ filters: v.filters.includes(val) ? v.filters.filter((f) => f !== val) : [...v.filters.filter((f) => !(val === "IsPlayed" && f === "IsUnplayed") && !(val === "IsUnplayed" && f === "IsPlayed")), val] });
  };
  const toggle = <T,>(list: T[], x: T) => (list.includes(x) ? list.filter((y) => y !== x) : [...list, x]);
  const f = genFilters.data;
  const activeCount = v.filters.length + v.genres.length + v.years.length + v.ratings.length + v.tags.length + (v.hasSubs ? 1 : 0) + (v.is4K ? 1 : 0) + (v.isHD ? 1 : 0) + (v.seriesStatus ? 1 : 0);

  return (
    <>
      {showControls && (
        <div className="toolbar-row wrap">
          <span className="muted small tabular">{total === null ? "" : `${total.toLocaleString()} ${total === 1 ? "item" : "items"}`}</span>
          <div className="toolbar-spacer" />
          {items.some(isPlayable) && !folders && (
            <>
              <button className="glass-button" onClick={() => void playAll(model, query, false)}><Icon name="playFill" size={14} /> Play all</button>
              <button className="glass-button" onClick={() => void playAll(model, query, true)}><Icon name="shuffle" size={15} /> Shuffle</button>
            </>
          )}
          <Dropdown label={sorts.find((s) => s.value === v.sort)?.label ?? "Sort"} icon="sort"
            items={[...sorts.map((s) => ({ value: s.value, label: s.label, selected: s.value === v.sort })), "divider", { value: "__order", label: v.order === "Ascending" ? "Ascending ↑" : "Descending ↓", icon: v.order === "Ascending" ? "arrowUp" : "arrowDown" }]}
            onPick={(val) => (val === "__order" ? setV({ order: v.order === "Ascending" ? "Descending" : "Ascending" }) : setV({ sort: val, order: ["DateCreated", "DatePlayed", "CommunityRating", "CriticRating", "PremiereDate", "ProductionYear", "PlayCount", "SeriesDatePlayed", "DateLastContentAdded"].includes(val) ? "Descending" : "Ascending" }))} />
          <Dropdown label={activeCount ? `Filters (${activeCount})` : "Filters"} icon="filter" items={filterItems} onPick={pickFilter} />
          {!!f?.Genres?.length && <Dropdown label={v.genres.length ? `Genres (${v.genres.length})` : "Genres"} icon="tag" items={f.Genres.map((g) => ({ value: g.Name, label: g.Name, selected: v.genres.includes(g.Name) }))} onPick={(g) => setV({ genres: toggle(v.genres, g) })} />}
          {!!f?.Years?.length && <Dropdown label={v.years.length ? `Years (${v.years.length})` : "Years"} icon="calendar" items={[...f.Years].sort((a, b) => b - a).map((y) => ({ value: y, label: String(y), selected: v.years.includes(y) }))} onPick={(y) => setV({ years: toggle(v.years, y) })} />}
          {!!f?.OfficialRatings?.length && <Dropdown label="Rating" icon="shield" items={f.OfficialRatings.map((r) => ({ value: r, label: r, selected: v.ratings.includes(r) }))} onPick={(r) => setV({ ratings: toggle(v.ratings, r) })} />}
          {!!f?.Tags?.length && <Dropdown label="Tags" icon="hash" items={f.Tags.slice(0, 300).map((t) => ({ value: t, label: t, selected: v.tags.includes(t) }))} onPick={(t) => setV({ tags: toggle(v.tags, t) })} />}
          <Segmented value={v.layout} options={[{ value: "grid", label: "", icon: "grid" }, { value: "list", label: "", icon: "list" }]} onChange={(layout) => setV({ layout })} />
        </div>
      )}
      {showControls && v.sort === "SortName" && !folders && (
        <div className="letters">
          {["", "#", ..."ABCDEFGHIJKLMNOPQRSTUVWXYZ"].map((l) => <button key={l || "all"} className={v.letter === l ? "on" : ""} onClick={() => setV({ letter: l })}>{l || "All"}</button>)}
        </div>
      )}
      {error && !items.length ? <ErrorNote text={error} retry={() => { setError(null); setTotal(null); }} />
        : total === 0 ? <Empty icon="search" title="Nothing here" text={activeCount ? "No items match these filters." : undefined} />
        : v.layout === "list" ? <div className="rows columns">{items.map((i) => <ItemRow key={i.Id} item={i} />)}</div>
        : <Grid min={gridMin(items[0], model.settings.libraryCardSize)}>{items.map((i) => <ItemCard key={i.Id} item={i} width={undefined} />)}</Grid>}
      <LoadMore onVisible={() => void loadMore()} active={!busy && total !== null && items.length < total} />
      {busy && <Spinner />}
    </>
  );
}

function gridMin(sample: Item | undefined, poster: number) {
  if (!sample) return poster;
  const t = sample.Type;
  if (t === "Episode" || t === "Video" || t === "Photo" || t === "TvChannel" || t === "Folder" || t === "CollectionFolder") return 260;
  if (t === "MusicAlbum" || t === "Audio" || t === "MusicArtist" || t === "Playlist") return 170;
  return poster;
}

async function playAll(model: ReturnType<typeof useModel>, query: Query, shuffle: boolean) {
  try {
    const r = await model.api!.items({ ...query, isFolder: false, recursive: true, includeItemTypes: (query.includeItemTypes as string[] | undefined)?.flatMap((t) => (t === "Series" ? ["Episode"] : t === "MusicAlbum" ? ["Audio"] : t === "BoxSet" ? ["Movie"] : [t])), sortBy: shuffle ? ["Random"] : query.sortBy, limit: 500, fields: ["MediaSources", "Chapters", "Trickplay"] });
    if (!r.Items.length) return model.toast("Nothing to play here.");
    await model.player?.playNow(r.Items, 0);
  } catch (e) {
    model.fail(e);
  }
}

/** Genres, studios and artists as tiles. */
function NamedGrid({ view, kind, types }: { view: Item; kind: "genres" | "studios" | "artists" | "albumArtists"; types?: string[] }) {
  const model = useModel();
  const navigate = useNavigate();
  const isMusic = view.CollectionType === "music";
  const { data, error, reload } = useLoad(() => {
    const q: Query = { parentId: view.Id, includeItemTypes: types, fields: ["PrimaryImageAspectRatio", "ItemCounts"], sortBy: ["SortName"], enableImageTypes: ["Primary", "Backdrop", "Thumb"], limit: 2000 };
    if (kind === "genres") return isMusic ? model.api!.musicGenres(q) : model.api!.genres(q);
    if (kind === "studios") return model.api!.studios(q);
    if (kind === "artists") return model.api!.artists({ ...q, includeItemTypes: undefined });
    return model.api!.albumArtists({ ...q, includeItemTypes: undefined });
  }, [view.Id, kind]);
  if (error) return <ErrorNote text={error} retry={reload} />;
  if (!data) return <Spinner />;
  if (!data.Items.length) return <Empty icon="tag" title="Nothing here" />;
  if (kind === "artists" || kind === "albumArtists") return <Grid min={170}>{data.Items.map((i) => <ItemCard key={i.Id} item={i} />)}</Grid>;
  return (
    <div className="genre-grid">
      {data.Items.map((g) => (
        <button key={g.Id} className="genre-tile" onClick={() => navigate(kind === "genres" ? { kind: "genre", name: g.Name ?? "", id: g.Id, parentId: view.Id, types } : { kind: "studio", name: g.Name ?? "", id: g.Id })}>
          {g.ImageTags?.Primary || g.BackdropImageTags?.length ? <Cover url={g.ImageTags?.Primary ? model.api!.image(g.Id, "Primary", { tag: g.ImageTags.Primary, maxWidth: 400 }) : model.api!.image(g.Id, "Backdrop", { tag: g.BackdropImageTags![0], maxWidth: 400 })} width="100%" height={110} radius={14} /> : <div className="genre-fill" />}
          <span>{g.Name}</span>
        </button>
      ))}
    </div>
  );
}

function Suggestions({ view, refreshKey }: { view: Item; refreshKey: number }) {
  const model = useModel();
  const isMovies = view.CollectionType === "movies";
  const { data: resume } = useLoad(() => model.api!.resume({ parentId: view.Id, limit: 20, enableImageTypes: ["Primary", "Backdrop", "Thumb"] }), [view.Id, refreshKey]);
  const { data: latest } = useLoad(() => model.api!.latest(view.Id, 24), [view.Id, refreshKey]);
  const { data: nextUp } = useLoad(async () => (isMovies ? null : model.api!.nextUp({ parentId: view.Id, limit: 20 })), [view.Id, refreshKey]);
  const { data: recs } = useLoad(async () => (isMovies ? model.api!.get<{ BaselineItemName?: string; RecommendationType?: string; Items: Item[] }[]>("/Movies/Recommendations", { userId: model.api!.userId, parentId: view.Id, categoryLimit: 6, itemLimit: 12, fields: LIST_FIELDS }) : null), [view.Id, refreshKey]);
  const recLabel = (r: { BaselineItemName?: string; RecommendationType?: string }) =>
    r.RecommendationType === "SimilarToRecentlyPlayed" ? `Because you watched ${r.BaselineItemName}` : r.RecommendationType === "SimilarToLikedItem" ? `Because you like ${r.BaselineItemName}` : r.RecommendationType === "HasDirectorFromRecentlyPlayed" ? `Directed by ${r.BaselineItemName}` : r.RecommendationType?.startsWith("HasActor") ? `Starring ${r.BaselineItemName}` : r.BaselineItemName ?? "Recommended";
  return (
    <>
      {!!resume?.Items.length && <Shelf title="Continue watching">{resume.Items.map((i) => <ItemCard key={i.Id} item={i} shape="landscape" width={280} context="resume" />)}</Shelf>}
      {!!nextUp?.Items.length && <Shelf title="Next up">{nextUp.Items.map((i) => <ItemCard key={i.Id} item={i} shape="landscape" width={280} />)}</Shelf>}
      {!!latest?.length && <Shelf title="Latest">{latest.map((i) => <ItemCard key={i.Id} item={i} />)}</Shelf>}
      {recs?.map((r, k) => !!r.Items.length && <Shelf key={k} title={recLabel(r)}>{r.Items.map((i) => <ItemCard key={i.Id} item={i} />)}</Shelf>)}
    </>
  );
}

function Upcoming({ view }: { view: Item }) {
  const model = useModel();
  const { data, error } = useLoad(() => model.api!.get<ItemsResult>("/Shows/Upcoming", { userId: model.api!.userId, parentId: view.Id, limit: 60, fields: LIST_FIELDS, enableImageTypes: ["Primary", "Backdrop", "Thumb"] }), [view.Id]);
  if (error) return <ErrorNote text={error} />;
  if (!data) return <Spinner />;
  if (!data.Items.length) return <Empty icon="calendar" title="Nothing coming up" text="Episodes with a future air date show here (missing episodes need to be enabled in metadata)." />;
  const groups = new Map<string, Item[]>();
  for (const i of data.Items) {
    const d = dateOnly(i.PremiereDate) || "Unknown date";
    groups.set(d, [...(groups.get(d) ?? []), i]);
  }
  return <>{[...groups].map(([d, items]) => <Shelf key={d} title={d}>{items.map((i) => <ItemCard key={i.Id} item={i} shape="landscape" width={280} />)}</Shelf>)}</>;
}

// MARK: Live TV

function Channels() {
  const model = useModel();
  const [fav, setFav] = useState(false);
  const { data, error } = useLoad(() => model.api!.get<ItemsResult>("/LiveTv/Channels", { userId: model.api!.userId, addCurrentProgram: true, enableFavoriteSorting: true, isFavorite: fav || undefined, limit: 500, fields: ["PrimaryImageAspectRatio", "ChannelInfo"] }), [fav]);
  if (error) return <ErrorNote text={error} />;
  if (!data) return <Spinner />;
  return (
    <>
      <div className="toolbar-row"><Segmented value={fav ? "fav" : "all"} options={[{ value: "all", label: "All channels" }, { value: "fav", label: "Favorites" }]} onChange={(x) => setFav(x === "fav")} /></div>
      <Grid min={240}>
        {data.Items.map((c) => (
          <ItemCard key={c.Id} item={c} shape="landscape" width={undefined} subtitle={c.CurrentProgram ? `${c.CurrentProgram.Name} · until ${c.CurrentProgram.EndDate ? new Date(c.CurrentProgram.EndDate).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" }) : ""}` : c.ChannelNumber ?? ""} onClick={() => void model.player?.playItem(c)} />
        ))}
      </Grid>
    </>
  );
}

function Guide() {
  const model = useModel();
  const start = useMemo(() => { const d = new Date(); d.setMinutes(d.getMinutes() < 30 ? 0 : 30, 0, 0); return d; }, []);
  const hours = 6;
  const end = new Date(start.getTime() + hours * 3600_000);
  const { data, error } = useLoad(async () => {
    const channels = await model.api!.get<ItemsResult>("/LiveTv/Channels", { userId: model.api!.userId, enableFavoriteSorting: true, limit: 200, fields: ["PrimaryImageAspectRatio"] });
    const programs = await model.api!.post<ItemsResult>("/LiveTv/Programs", {
      UserId: model.api!.userId, ChannelIds: channels.Items.map((c) => c.Id), MinEndDate: start.toISOString(), MaxStartDate: end.toISOString(),
      SortBy: ["StartDate"], EnableImages: false, EnableUserData: false, Fields: ["Overview"],
    });
    return { channels: channels.Items, programs: programs.Items };
  }, []);
  if (error) return <ErrorNote text={error} />;
  if (!data) return <Spinner label="Loading the guide…" />;
  const span = end.getTime() - start.getTime();
  const pct = (t: number) => Math.max(0, Math.min(100, ((t - start.getTime()) / span) * 100));
  const now = pct(Date.now());
  return (
    <div className="guide panel">
      <div className="guide-times">
        <div className="guide-channel-col" />
        <div className="guide-track">{Array.from({ length: hours * 2 }, (_, k) => <span key={k} style={{ left: `${(k / (hours * 2)) * 100}%` }}>{new Date(start.getTime() + k * 1800_000).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })}</span>)}</div>
      </div>
      {data.channels.map((c) => (
        <div key={c.Id} className="guide-row">
          <button className="guide-channel-col" onClick={() => void model.player?.playItem(c)} title={`Watch ${c.Name}`}>
            <Cover url={c.ImageTags?.Primary ? model.api!.image(c.Id, "Primary", { tag: c.ImageTags.Primary, maxWidth: 120 }) : undefined} width={44} height={30} radius={6} icon="live" />
            <span>{c.ChannelNumber} {c.Name}</span>
          </button>
          <div className="guide-track">
            {data.programs.filter((p) => p.ChannelId === c.Id).map((p) => {
              const s = Date.parse(p.StartDate ?? ""), e = Date.parse(p.EndDate ?? "");
              const left = pct(s), width = pct(e) - left;
              if (width <= 0) return null;
              return (
                <button key={p.Id} className={`guide-program ${s <= Date.now() && e > Date.now() ? "live" : ""}`} style={{ left: `${left}%`, width: `${width}%` }} title={`${p.Name}\n${p.Overview ?? ""}`}
                  onClick={(ev) => ui.showMenu({ x: ev.clientX, y: ev.clientY, item: p })}>
                  <strong>{p.Name}</strong><small>{new Date(s).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })}</small>
                </button>
              );
            })}
          </div>
        </div>
      ))}
      <div className="guide-now" style={{ left: `calc(180px + (100% - 180px) * ${now / 100})` }} />
    </div>
  );
}

function Recordings() {
  const model = useModel();
  const { data, error } = useLoad(() => model.api!.get<ItemsResult>("/LiveTv/Recordings", { userId: model.api!.userId, limit: 200, fields: LIST_FIELDS, enableImageTypes: ["Primary", "Thumb", "Backdrop"] }), [model.dataVersion]);
  if (error) return <ErrorNote text={error} />;
  if (!data) return <Spinner />;
  if (!data.Items.length) return <Empty icon="live" title="No recordings" text="Record a program from the guide." />;
  return <Grid min={260}>{data.Items.map((i) => <ItemCard key={i.Id} item={i} shape="landscape" width={undefined} />)}</Grid>;
}

function Timers() {
  const model = useModel();
  const { data, error, reload } = useLoad(async () => {
    const [timers, series] = await Promise.all([
      model.api!.get<{ Items: { Id: string; Name: string; StartDate: string; EndDate: string; ChannelName?: string; Status?: string }[] }>("/LiveTv/Timers", { isActive: undefined }),
      model.api!.get<{ Items: { Id: string; Name: string; ChannelName?: string; RecordAnyChannel?: boolean; RecordNewOnly?: boolean }[] }>("/LiveTv/SeriesTimers"),
    ]);
    return { timers: timers.Items, series: series.Items };
  }, []);
  if (error) return <ErrorNote text={error} />;
  if (!data) return <Spinner />;
  const cancel = async (path: string) => { try { await model.api!.del(path); reload(); } catch (e) { model.fail(e); } };
  return (
    <div className="stack">
      <h3>Scheduled recordings</h3>
      {!data.timers.length && <p className="muted">Nothing scheduled.</p>}
      <div className="rows">{data.timers.map((t) => (
        <div key={t.Id} className="row static"><Icon name="calendar" size={18} /><div className="row-text"><div className="row-title">{t.Name}</div><div className="row-sub">{new Date(t.StartDate).toLocaleString()} · {t.ChannelName} · {t.Status}</div></div>
          <button className="glass-button danger" onClick={() => void cancel(`/LiveTv/Timers/${t.Id}`)}>Cancel</button></div>
      ))}</div>
      <h3>Series recordings</h3>
      {!data.series.length && <p className="muted">No series recordings.</p>}
      <div className="rows">{data.series.map((t) => (
        <div key={t.Id} className="row static"><Icon name="repeat" size={18} /><div className="row-text"><div className="row-title">{t.Name}</div><div className="row-sub">{t.RecordAnyChannel ? "Any channel" : t.ChannelName} · {t.RecordNewOnly ? "New episodes only" : "All episodes"}</div></div>
          <button className="glass-button danger" onClick={() => void cancel(`/LiveTv/SeriesTimers/${t.Id}`)}>Cancel</button></div>
      ))}</div>
    </div>
  );
}

export function LiveGuidePage({ back }: { back: () => void }) {
  return <div className="page"><PageHeader title="TV guide" back={back} /><Guide /></div>;
}

// MARK: Other pages

/** "See all" lists: next up, similar titles, and plain queries. */
export function BrowsePage({ title, query, back }: { title: string; query: Record<string, unknown>; back: () => void }) {
  const model = useModel();
  const { data, error } = useLoad(async (): Promise<Item[]> => {
    if (query.nextUp) return (await model.api!.nextUp({ limit: 200, enableImageTypes: ["Primary", "Backdrop", "Thumb"] })).Items;
    if (query.similarTo) {
      const r = await model.api!.similar(String(query.similarTo), 60);
      return r.Items.filter((i) => !i.UserData?.Played);
    }
    if (query.dismissed) {
      return (await model.api!.items({ filters: ["Dislikes"], recursive: true, includeItemTypes: ["Series", "Movie"], sortBy: ["SortName"], fields: LIST_FIELDS, limit: 1000 })).Items;
    }
    if (query.watchLater) {
      const ids = model.lists?.watchLater.map((e) => e.id) ?? [];
      if (!ids.length) return [];
      const r = await model.api!.items({ ids, fields: LIST_FIELDS, enableUserData: true });
      return ids.map((id) => r.Items.find((i) => i.Id === id)).filter((x): x is Item => !!x);
    }
    return (await model.api!.items({ ...(query as Query), fields: LIST_FIELDS, limit: 300 })).Items;
  }, [JSON.stringify(query), model.dataVersion]);
  return (
    <div className="page">
      <PageHeader title={title} back={back} />
      {error ? <ErrorNote text={error} /> : !data ? <Spinner /> : !data.length ? <Empty icon="search" title="Nothing here" /> : (
        <>
          {query.dismissed && <p className="muted small">Saved on your server as a thumbs-down. Right-click a title and choose "Undo Not for me" to bring it back to For You.</p>}
          {query.watchLater && <p className="muted small">Saved on your server. Titles leave this list once you've watched them.</p>}
          <Grid min={query.nextUp ? 280 : model.settings.libraryCardSize}>{data.map((i) => <ItemCard key={i.Id} item={i} width={undefined} shape={query.nextUp ? "landscape" : undefined} />)}</Grid>
        </>
      )}
    </div>
  );
}

export function PersonPage({ id, back }: { id: string; back: () => void }) {
  const model = useModel();
  const api = model.api!;
  const { data: person, error } = useLoad(() => api.itemFull(id), [id]);
  const { data: works } = useLoad(() => api.items({ personIds: [id], recursive: true, includeItemTypes: ["Movie", "Series", "Episode", "MusicVideo"], sortBy: ["PremiereDate", "ProductionYear", "SortName"], sortOrder: ["Descending"], fields: LIST_FIELDS, limit: 400 }), [id]);
  if (error) return <div className="page"><PageHeader title="Person" back={back} /><ErrorNote text={error} /></div>;
  if (!person) return <div className="page"><Spinner /></div>;
  const byType = (t: string) => works?.Items.filter((i) => i.Type === t) ?? [];
  const born = person.PremiereDate ? dateOnly(person.PremiereDate) : null;
  return (
    <div className="page">
      <PageHeader title={person.Name} back={back}>
        <button className={`round-button ${person.UserData?.IsFavorite ? "on" : ""}`} onClick={() => void model.toggleFavorite(person)} title="Favorite"><Icon name={person.UserData?.IsFavorite ? "heartFill" : "heart"} size={16} /></button>
      </PageHeader>
      <div className="person-top">
        <Cover url={cardImage(api, person, "poster", 220)} width={200} height={300} radius={16} icon="person" />
        <div className="person-text">
          {born && <p className="muted">Born {born}{person.ProductionLocations?.length ? ` in ${person.ProductionLocations.join(", ")}` : ""}{person.EndDate ? ` · Died ${dateOnly(person.EndDate)}` : ""}</p>}
          {person.Overview && <p className="synopsis-text clamp-6">{person.Overview}</p>}
          <ExternalLinks item={person} />
        </div>
      </div>
      {byType("Movie").length > 0 && <Shelf title="Movies">{byType("Movie").map((i) => <ItemCard key={i.Id} item={i} />)}</Shelf>}
      {byType("Series").length > 0 && <Shelf title="Shows">{byType("Series").map((i) => <ItemCard key={i.Id} item={i} />)}</Shelf>}
      {byType("Episode").length > 0 && <Shelf title="Episodes">{byType("Episode").map((i) => <ItemCard key={i.Id} item={i} shape="landscape" width={260} />)}</Shelf>}
      {byType("MusicVideo").length > 0 && <Shelf title="Music videos">{byType("MusicVideo").map((i) => <ItemCard key={i.Id} item={i} />)}</Shelf>}
    </div>
  );
}

export function ExternalLinks({ item }: { item: Item }) {
  if (!item.ExternalUrls?.length) return null;
  return (
    <div className="chips-wrap">
      {item.ExternalUrls.map((u) => u.Url && <a key={u.Url} className="chip chip-muted" href={u.Url} target="_blank" rel="noreferrer"><Icon name="external" size={12} /> {u.Name}</a>)}
    </div>
  );
}

export function GenrePage({ name, id, parentId, types, back }: { name: string; id?: string; parentId?: string | null; types?: string[]; back: () => void }) {
  const t = types ?? ["Movie", "Series"];
  return (
    <div className="page">
      <PageHeader title={name} back={back} subtitle="Genre" />
      <ItemBrowser scopeKey={`genre-${t.join()}`} base={{ parentId: parentId ?? undefined, recursive: true, includeItemTypes: t, ...(id ? { genreIds: [id] } : { genres: name }) }} types={t} />
    </div>
  );
}

export function StudioPage({ name, id, back }: { name: string; id?: string; back: () => void }) {
  return (
    <div className="page">
      <PageHeader title={name} back={back} subtitle="Studio" />
      <ItemBrowser scopeKey="studio" base={{ recursive: true, includeItemTypes: ["Movie", "Series"], ...(id ? { studioIds: [id] } : { studios: name }) }} types={["Movie", "Series"]} />
    </div>
  );
}

export { backdropUrl, clock, routeFor, ticksToSeconds };
