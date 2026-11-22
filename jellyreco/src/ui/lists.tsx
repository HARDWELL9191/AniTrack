// Anime lists, Movie list and TV Show list (the iPhone's, AniReco's design): rows with the cover,
// one line of facts, then score · match · age. Anime lists are your AniList lists (AniReco's
// Watching / Planning / … dropdown on the right, a Filter on the left for "On your server" and
// AniReco's categories, sorting top right). Movie list and TV Show list are My List's movies and
// shows, saved in your account's JellyReco storage on the server: "On your server" on the left, a
// genre on the right. Not for me: For You picks you turned down.

import { type MouseEvent as RMouseEvent, type ReactNode, useEffect, useState } from "react";
import { LIST_FIELDS } from "../core/api";
import { ageLabel, type AnimeCategory, aniListLibrary, categoryId, categoryMatches, FEATURED, formatLabel, LIST_STATUSES, type ListEntry, type ListStatus, type Media, seasonLabel, type ShowRow, thumbURL } from "../core/anilist";
import { ageBucket } from "../core/age";
import { type ExternalListName } from "../core/storage";
import { type ExternalTitle, entryId, isAniList, isMovie, metaLine, type MyListEntry, resized, titleId } from "../core/titles";
import type { Item } from "../core/types";
import { cardImage, Cover, Dropdown, type DropItem, Empty, Grid, MatchBubble, Modal, PageHeader, SearchField, useLoad } from "./components";
import { AniListAgeBubble, TitleCard, titleAction } from "./foryou";
import { Icon } from "./icons";
import { type MenuAction, routeFor, ui, useModel, useNavigate } from "./state";

type Model = ReturnType<typeof useModel>;

// MARK: Pieces shared by the three lists

type ServerFilter = "all" | "server" | "outside";
const SERVER_FILTERS: { value: ServerFilter; label: string; icon: string }[] = [
  { value: "all", label: "All", icon: "bookmark" },
  { value: "server", label: "On your server", icon: "server" },
  { value: "outside", label: "Not on server yet", icon: "cloudDown" },
];
const keeps = (f: ServerFilter, onServer: boolean) => f === "all" || (f === "server") === onServer;
const serverLabel = (f: ServerFilter) => SERVER_FILTERS.find((x) => x.value === f)!;

/** Age labels, strictest first (for "Age rating" sorting). */
function ageRank(label: string | null | undefined) {
  return ({ "18+": 4, "17+": 3, "13+": 2, PG: 1 } as Record<string, number>)[label ?? ""] ?? 0;
}
const byName = (a: string, b: string) => a.localeCompare(b, undefined, { sensitivity: "base" });
const textMatches = (text: string, names: (string | null | undefined)[]) => {
  const t = text.trim().toLowerCase();
  return !t || names.some((n) => !!n && n.toLowerCase().includes(t));
};

/** AniReco's score: a face and x/10, green from 7.5, orange from 6, red below. */
export function ScoreBadge({ score }: { score?: number | null }) {
  if (!score || score <= 0) return null;
  const tone = score >= 75 ? "good" : score >= 60 ? "ok" : "low";
  return <span className={`score score-${tone}`}><Icon name={score >= 75 ? "smileHappy" : score >= 60 ? "smile" : "smileDashed"} size={16} />{(score / 10).toFixed(1)}/10</span>;
}

/** The wand and the pink match bubble of a list row. */
function MatchBadge({ value }: { value: number | null | undefined }) {
  return value == null ? null : <span className="row-match"><Icon name="wand" size={15} /><MatchBubble value={value} /></span>;
}

/** AniReco's list row: cover, title, one line of facts, then score · match · age. Click opens it;
 *  right-click or … opens its actions (the iPhone's swipes and long-press menu). */
function ListRow({ cover, icon, title, subtitle, badges, notOnServer, onOpen, onMenu }: {
  cover?: string | null; icon: string; title: string; subtitle: string; badges: ReactNode; notOnServer?: boolean;
  onOpen: () => void; onMenu?: (e: RMouseEvent) => void;
}) {
  return (
    <div className="row list-row" role="button" tabIndex={0} onClick={onOpen} onContextMenu={onMenu}
      onKeyDown={(e) => { if (e.key === "Enter") onOpen(); }} title={title}>
      <Cover url={cover ?? undefined} width={58} height={84} radius={8} icon={icon} />
      <div className="row-text">
        <div className="row-title">{title}</div>
        <div className="row-sub">{subtitle}</div>
        <div className="row-badges">{badges}</div>
      </div>
      {notOnServer && <span className="list-row-cloud" title="Not on your server yet"><Icon name="cloudDown" size={18} /></span>}
      {onMenu && <button className="round-button list-row-more" aria-label="More" title="More" onClick={(e) => { e.stopPropagation(); onMenu(e); }}><Icon name="more" size={16} /></button>}
      <Icon name="chevronRight" size={16} className="row-chevron" />
    </div>
  );
}

const menuAt = (e: RMouseEvent, title: string, movie: boolean, actions: MenuAction[]) => {
  e.preventDefault();
  e.stopPropagation();
  ui.showMenu({ x: e.clientX, y: e.clientY, item: { Id: `list:${title}`, Name: title, Type: movie ? "Movie" : "Series" }, actions });
};

/** A movie or show on your server, as a list row (its usual right-click menu, or `actions`). */
function ServerRow({ item, actions }: { item: Item; actions?: MenuAction[] }) {
  const model = useModel();
  const navigate = useNavigate();
  const series = item.Type === "Series";
  const facts = [series ? "TV show" : "Movie", item.ProductionYear ? String(item.ProductionYear) : null,
    series && item.ChildCount ? (item.ChildCount === 1 ? "1 season" : `${item.ChildCount} seasons`) : null,
    !series && item.RunTimeTicks ? runtime(item.RunTimeTicks / 10_000_000) : null].filter(Boolean).join(" · ");
  const age = ageBucket(item.OfficialRating);
  return (
    <ListRow cover={cardImage(model.api!, item, "poster", 58)} icon={series ? "tv" : "film"} title={item.Name ?? ""} subtitle={facts}
      onOpen={() => navigate(routeFor(item))}
      onMenu={(e) => { if (actions) { menuAt(e, item.Name ?? "", !series, actions); return; } e.preventDefault(); e.stopPropagation(); ui.showMenu({ x: e.clientX, y: e.clientY, item }); }}
      badges={<>
        <ScoreBadge score={item.CommunityRating ? Math.round(item.CommunityRating * 10) : null} />
        <MatchBadge value={model.reco.match(item)} />
        {age && <span className="bubble bubble-age">{age}</span>}
      </>} />
  );
}

function runtime(seconds: number) {
  const m = Math.round(seconds / 60);
  return m >= 60 ? `${Math.floor(m / 60)}h ${m % 60}m` : `${m}m`;
}

/** Is this server title in a library named Anime / Anime Movies (those live on Anime lists)? */
function inAnimeLibrary(model: Model, itemId: string) {
  const lib = model.reco.itemLibrary.get(itemId);
  return !!lib && !!aniListLibrary(model.views.find((v) => v.Id === lib)?.Name);
}

/** My List's server titles, read in batches (the library index first, the server for the rest). */
function useServerItems(entries: MyListEntry[]) {
  const model = useModel();
  const ids = entries.flatMap((e) => (e.serverId ? [e.serverId] : []));
  const key = ids.join(",");
  const { data } = useLoad(async () => {
    const out = new Map<string, Item>();
    for (let i = 0; i < ids.length; i += 100) {
      const r = await model.api!.items({ ids: ids.slice(i, i + 100), fields: LIST_FIELDS, enableUserData: true });
      for (const it of r.Items) out.set(it.Id, it);
    }
    return out;
  }, [key, model.dataVersion]);
  return data;
}

function SortMenu<T extends string>({ value, options, onPick }: { value: T; options: readonly T[]; onPick: (v: T) => void }) {
  return <Dropdown compact icon="sort" title={`Sort: ${value}`} label={null} items={options.map((o) => ({ value: o, label: o, selected: o === value }))} onPick={onPick} />;
}

/** The library index (what's on your server) loads once for these pages. */
function useLibraryIndex() {
  const model = useModel();
  useEffect(() => { void model.reco.ensure().then(() => model.notify()).catch(() => {}); }, [model]);
}

// MARK: Anime lists

const ANIME_SORTS = ["Best match", "Recently added", "Last updated", "Title", "My score", "Average score", "Age rating"] as const;
type AnimeSort = (typeof ANIME_SORTS)[number];

/** AniReco's category items: Any category, its popular genres and tags, then "All categories…". */
export function aniCategoryItems(model: Model, selected: AnimeCategory | null): DropItem<string>[] {
  const known = model.anilist.categories.length ? new Set(model.anilist.categories.map(categoryId)) : null;
  const featured = FEATURED.filter((c) => !known || known.has(categoryId(c)));
  const item = (c: AnimeCategory) => ({ value: categoryId(c), label: c.name, selected: !!selected && categoryId(c) === categoryId(selected) });
  const picked = selected && !featured.some((c) => categoryId(c) === categoryId(selected)) ? [item(selected)] : [];
  return [
    { value: "", label: "Any category", selected: !selected },
    ...picked,
    "divider",
    { section: "Genres" },
    ...featured.filter((c) => c.kind === "genre").map(item),
    { section: "Tags" },
    ...featured.filter((c) => c.kind === "tag").map(item),
    "divider",
    { value: "all", label: "All categories…", icon: "grid" },
  ];
}

/** Every AniList genre and tag, searchable (AniReco's "All categories"). */
export function AniCategoriesModal({ onPick, close }: { onPick: (c: AnimeCategory) => void; close: () => void }) {
  const model = useModel();
  const [text, setText] = useState("");
  useEffect(() => { void model.anilist.loadCategories(); }, [model]);
  const all = model.anilist.categories.length ? model.anilist.categories : FEATURED;
  const shown = all.filter((c) => textMatches(text, [c.name]));
  const section = (title: string, list: AnimeCategory[]) => list.length > 0 && (
    <section key={title}>
      <div className="menu-section">{title}</div>
      <div className="category-grid">{list.map((c) => <button key={categoryId(c)} className="chip chip-button" onClick={() => { onPick(c); close(); }}>{c.name}</button>)}</div>
    </section>
  );
  return (
    <Modal title="All categories" onClose={close} width={620}>
      <SearchField value={text} onChange={setText} placeholder="Isekai, Romance, Ecchi…" autoFocus />
      <div className="category-sheet">
        {section("Genres", [...shown.filter((c) => c.kind === "genre")].sort((a, b) => byName(a.name, b.name)))}
        {section("Tags", [...shown.filter((c) => c.kind === "tag")].sort((a, b) => byName(a.name, b.name)))}
        {!shown.length && <p className="muted">No category called "{text}".</p>}
      </div>
    </Modal>
  );
}

type AnimeRow = { kind: "show"; row: ShowRow } | { kind: "server"; entry: MyListEntry; item: Item };

export function AnimeListsPage({ back }: { back?: () => void }) {
  const model = useModel();
  const navigate = useNavigate();
  const ani = model.anilist;
  const [status, setStatus] = useState<ListStatus>("CURRENT");
  const [notForMe, setNotForMe] = useState(false);
  const [picked, setPicked] = useState(false);
  const [sort, setSort] = useState<AnimeSort>("Last updated");
  const [text, setText] = useState("");
  const [server, setServer] = useState<ServerFilter>("all");
  const [category, setCategory] = useState<AnimeCategory | null>(null);
  const [allCategories, setAllCategories] = useState(false);
  useLibraryIndex();
  useEffect(() => { ani.syncAccount(); void ani.loadCategories(); }, [ani]);

  const owned = (m: Media) => (model.reco.ready ? ani.ownedIndex().find(m) : undefined);
  // Anime-library titles saved to My List on your server that aren't on your AniList list (Planning).
  const myList = model.storage?.myList ?? [];
  const serverItems = useServerItems(myList.filter((e) => e.serverId && inAnimeLibrary(model, e.serverId)));
  const onAniList = new Set(ani.entries.flatMap((e) => { const o = owned(e.media); return o ? [o.Id] : []; }));
  const serverAnime = myList.flatMap((entry) => {
    const item = entry.serverId ? serverItems?.get(entry.serverId) : undefined;
    return item && inAnimeLibrary(model, item.Id) && !onAniList.has(item.Id) ? [{ entry, item }] : [];
  });
  const count = (s: ListStatus) => ani.showCount(s) + (s === "PLANNING" ? serverAnime.length : 0);

  // Opens on the first list that has shows, unless you picked one (AniReco).
  useEffect(() => {
    if (picked || notForMe || count(status) > 0) return;
    const first = (["CURRENT", "REPEATING", "PLANNING", "COMPLETED", "PAUSED", "DROPPED"] as ListStatus[]).find((s) => count(s) > 0);
    if (first) setStatus(first);
  }); // eslint-disable-line react-hooks/exhaustive-deps

  const showTitles = (r: ShowRow) => [r.entry.media.title, ...r.foldedTitles].flatMap((t) => [t.english, t.romaji, t.native]);
  const shows = ani.shows([status]).filter((r) => keeps(server, !!owned(r.entry.media)) && (!category || categoryMatches(category, r.entry.media)) && textMatches(text, showTitles(r)));
  const title = (m: Media) => ani.titleOf(m);
  const age = (e: ListEntry) => ageRank(ageLabel(ani.ages.get(e.mediaId)));
  const sorted = [...shows];
  const by = (f: (r: ShowRow) => number) => sorted.sort((a, b) => f(b) - f(a));
  switch (sort) {
    case "Last updated": by((r) => r.entry.updatedAt ?? 0); break;
    case "Recently added": by((r) => r.entry.createdAt ?? r.entry.updatedAt ?? 0); break;
    case "Title": sorted.sort((a, b) => byName(title(a.entry.media), title(b.entry.media))); break;
    case "My score": by((r) => r.entry.score ?? 0); break;
    case "Average score": by((r) => r.entry.media.averageScore ?? 0); break;
    case "Age rating": sorted.sort((a, b) => age(b.entry) - age(a.entry) || byName(title(a.entry.media), title(b.entry.media))); break;
    case "Best match": by((r) => ani.match(r.entry.media) ?? r.entry.score ?? 0); break; // rated shows fall back to your score
  }
  const rows: AnimeRow[] = sorted.map((row) => ({ kind: "show", row }));
  if (status === "PLANNING" && server !== "outside" && !category)
    rows.push(...serverAnime.filter((x) => textMatches(text, [x.item.Name, x.item.OriginalTitle])).map((x) => ({ kind: "server" as const, ...x })));
  // "Age rating" needs Kitsu's ratings for the whole list.
  useEffect(() => { if (sort === "Age rating") for (const r of ani.shows([status])) ani.requestAge(r.entry.mediaId, r.entry.media.idMal); }, [sort, status, ani.entries]); // eslint-disable-line react-hooks/exhaustive-deps
  const outRows = ani.notForMeTitles.filter((m) => keeps(server, !!owned(m)) && (!category || categoryMatches(category, m)) && textMatches(text, [m.title.english, m.title.romaji, m.title.native]))
    .sort((a, b) => byName(title(a), title(b)));

  const open = (m: Media) => { const o = owned(m); if (o) navigate(routeFor(o)); else ui.openSheet({ kind: "tmdb", item: ani.title(m) }); };
  const completed = async (m: Media) => {
    if (await ani.markCompleted(m)) { model.toast("Marked Completed on AniList", "success"); if (ani.ratePrompt) ui.openSheet({ kind: "anilistRate", media: ani.ratePrompt }); }
  };
  const showActions = (r: ShowRow): MenuAction[] => {
    const o = owned(r.entry.media);
    return [
      ...(o ? [{ label: "Open on your server", icon: "play", run: () => navigate(routeFor(o)) }] : []),
      { label: "Details", icon: "info", run: () => ui.openSheet({ kind: "tmdb", item: ani.title(r.entry.media) }) },
      ...(r.entry.status !== "COMPLETED" ? [{ label: "Completed", icon: "checkCircle", run: () => void completed(r.entry.media) }] : []),
      { label: "Remove from your AniList list", icon: "trash", danger: true, run: () => void ani.removeFromPlanning(r.entry.mediaId).then(() => model.toast("Removed from your AniList list", "success")) },
    ];
  };
  const animeRow = (m: Media, subtitle: string, actions: MenuAction[], key: string) => (
    <ListRow key={key} cover={thumbURL(m)} icon="tv" title={title(m)} subtitle={subtitle} notOnServer={model.reco.ready && !owned(m)}
      onOpen={() => open(m)} onMenu={(e) => menuAt(e, title(m), m.format === "MOVIE", actions)}
      badges={<><ScoreBadge score={m.averageScore} /><MatchBadge value={ani.match(m)} /><AniListAgeBubble id={m.id} /></>} />
  );

  const filterLabel = [server === "all" ? null : serverLabel(server).label, category?.name].filter(Boolean).join(" · ") || "All";
  const filterItems: DropItem<string>[] = [
    { section: "Show" },
    ...SERVER_FILTERS.map((f) => ({ value: `server:${f.value}`, label: f.label, icon: f.icon, selected: server === f.value })),
    "divider",
    ...aniCategoryItems(model, category),
  ];
  const pickFilter = (v: string) => {
    if (v.startsWith("server:")) setServer(v.slice(7) as ServerFilter);
    else if (v === "all") setAllCategories(true);
    else setCategory(v ? (ani.categories.length ? ani.categories : FEATURED).find((c) => categoryId(c) === v) ?? category : null);
  };
  const current = LIST_STATUSES.find((s) => s.status === status)!;
  const listItems: DropItem<string>[] = [
    ...LIST_STATUSES.map((s) => ({ value: s.status as string, label: `${s.label} (${count(s.status)})`, icon: s.icon, selected: !notForMe && s.status === status })),
    "divider",
    { value: "notForMe", label: `Not for me (${ani.dismissed.size})`, icon: "thumbsDown", selected: notForMe },
  ];
  const pickList = (v: string) => { setPicked(true); if (v === "notForMe") setNotForMe(true); else { setNotForMe(false); setStatus(v as ListStatus); } };

  let body: ReactNode;
  if (!ani.loggedIn) body = <Empty icon="sparkles" title="Connect AniList" text="Anime lists are your AniList lists, as in AniReco. Connect your AniList account in For You (pick the Anime library) or in Settings." />;
  else if (notForMe) body = (
    <>
      {outRows.length > 0 && <p className="footnote">Hidden from your picks. Right-click a show to bring it back.</p>}
      {!outRows.length && <p className="muted">{!ani.dismissed.size ? 'Nothing here. Shows you mark "Not for me" in For You appear here.' : text || server !== "all" || category ? "No matches." : "Loading…"}</p>}
      <div className="rows columns">{outRows.map((m) => animeRow(m, [formatLabel(m), seasonLabel(m)].filter(Boolean).join(" · "), [
        { label: "Undo Not for me", icon: "undo", run: () => void ani.undoNotForMe(m.id) },
        { label: "Details", icon: "info", run: () => ui.openSheet({ kind: "tmdb", item: ani.title(m) }) },
      ], `o${m.id}`))}</div>
    </>
  );
  else body = (
    <>
      {!rows.length && <p className="muted">{ani.loadingList || !ani.listLoadedOnce ? "Loading…" : text || server !== "all" || category ? "No matches." : `No shows marked ${current.label.toLowerCase()}.`}</p>}
      <div className="rows columns">{rows.map((r) => r.kind === "show"
        ? animeRow(r.row.entry.media, animeSubtitle(r.row), showActions(r.row), `a${r.row.entry.id}`)
        : <ServerRow key={`s${entryId(r.entry)}`} item={r.item} />)}</div>
    </>
  );

  return (
    <div className="page">
      <PageHeader title="Anime lists" back={back} subtitle={ani.viewer ? `Your AniList lists (${ani.viewer.name})` : "Your AniList lists"}>
        <SortMenu value={sort} options={ANIME_SORTS} onPick={setSort} />
      </PageHeader>
      <div className="toolbar-row list-controls">
        <Dropdown label={filterLabel} icon="filter" align="left" title="Filter" items={filterItems} onPick={pickFilter} />
        <SearchField value={text} onChange={setText} placeholder="Filter this list" />
        <Dropdown label={notForMe ? `Not for me (${ani.dismissed.size})` : `${current.label} (${count(status)})`} icon={notForMe ? "thumbsDown" : current.icon} title="Lists" items={listItems} onPick={pickList} />
      </div>
      {body}
      {allCategories && <AniCategoriesModal onPick={setCategory} close={() => setAllCategories(false)} />}
    </div>
  );
}

/** "2 seasons · Your score ★ 8.5 · TV · Fall 2023" (AniReco). */
function animeSubtitle(r: ShowRow) {
  const e = r.entry;
  const parts: string[] = [];
  if (r.extraSeasons > 0) parts.push(`${r.extraSeasons + 1} seasons`);
  if ((e.score ?? 0) > 0) { const ten = (e.score ?? 0) / 10; parts.push(`Your score ★ ${Number.isInteger(ten) ? ten : ten.toFixed(1)}`); }
  parts.push(formatLabel(e.media));
  const season = seasonLabel(e.media);
  if (season) parts.push(season);
  return parts.join(" · ");
}

// MARK: Movie list / TV Show list

const TITLE_SORTS = ["Best match", "Recently added", "Title", "Average score", "Age rating", "Year"] as const;
type TitleSort = (typeof TITLE_SORTS)[number];

interface TitleRow { entry: MyListEntry; item?: Item; external?: ExternalTitle }

export function TitleListPage({ kind, back }: { kind: "movies" | "shows"; back?: () => void }) {
  const model = useModel();
  const navigate = useNavigate();
  const st = model.storage;
  const [server, setServer] = useState<ServerFilter>("all");
  const [genre, setGenre] = useState<string | null>(null);
  const [sort, setSort] = useState<TitleSort>("Recently added");
  const [text, setText] = useState("");
  useLibraryIndex();
  const myList = st?.myList ?? [];
  const items = useServerItems(myList);
  const c = model.discoveryContext();
  const owned = (t: ExternalTitle) => (c && model.reco.ready ? model.discovery.ownedItem(c, t) : undefined);

  const all: TitleRow[] = myList.flatMap((entry): TitleRow[] => {
    if (entry.serverId) {
      const item = items?.get(entry.serverId) ?? model.reco.byId.get(entry.serverId);
      if (!item || inAnimeLibrary(model, item.Id)) return [];
      if (item.Type !== (kind === "movies" ? "Movie" : "Series")) return [];
      return [{ entry, item }];
    }
    const t = entry.external;
    if (!t || isAniList(t) || isMovie(t) !== (kind === "movies")) return [];
    return [{ entry, item: owned(t), external: t }];
  });
  const name = (r: TitleRow) => r.item?.Name ?? r.external?.title ?? r.entry.name ?? "";
  const genresOf = (r: TitleRow) => r.item?.Genres ?? r.external?.genres ?? [];
  const yearOf = (r: TitleRow) => r.item?.ProductionYear ?? r.external?.year ?? 0;
  const scoreOf = (r: TitleRow) => { const s = r.item?.CommunityRating ?? r.external?.score; return s ? Math.round(s * 10) : 0; };
  const ageOf = (r: TitleRow) => ageBucket(r.item?.OfficialRating ?? r.external?.ageRating);
  const genres = [...new Set(all.flatMap(genresOf))].sort(byName);
  const count = (f: ServerFilter) => all.filter((r) => keeps(f, !!r.item)).length;

  const rows = all.filter((r) => keeps(server, !!r.item) && (!genre || genresOf(r).includes(genre)) && textMatches(text, [name(r), r.item?.OriginalTitle, r.external?.originalTitle]));
  const by = (f: (r: TitleRow) => number) => rows.sort((a, b) => f(b) - f(a) || byName(name(a), name(b)));
  switch (sort) {
    case "Recently added": rows.sort((a, b) => b.entry.addedAt - a.entry.addedAt); break;
    case "Title": rows.sort((a, b) => byName(name(a), name(b))); break;
    case "Average score": by(scoreOf); break;
    case "Year": by(yearOf); break;
    case "Age rating": by((r) => ageRank(ageOf(r))); break;
    case "Best match": by((r) => (r.item ? model.reco.match(r.item) ?? -1 : -1)); break;
  }

  const remove = (r: TitleRow) => void st?.removeEntries(new Set([entryId(r.entry)]), entryId).then(() => { model.toast("Removed from My List", "success"); model.tasteChanged(); });
  const noun = kind === "movies" ? "movies" : "shows";
  return (
    <div className="page">
      <PageHeader title={kind === "movies" ? "Movie list" : "TV Show list"} back={back} subtitle={`My List's ${noun}, saved on your Jellyfin server`}>
        <SortMenu value={sort} options={TITLE_SORTS} onPick={setSort} />
      </PageHeader>
      <div className="toolbar-row list-controls">
        <Dropdown label={`${serverLabel(server).label} (${count(server)})`} icon={serverLabel(server).icon} align="left" title="On your server"
          items={SERVER_FILTERS.map((f) => ({ value: f.value, label: `${f.label} (${count(f.value)})`, icon: f.icon, selected: f.value === server }))} onPick={setServer} />
        <SearchField value={text} onChange={setText} placeholder="Filter this list" />
        <Dropdown label={genre ?? "Any genre"} icon="filter" title="Genre"
          items={[{ value: "", label: "Any genre", selected: !genre }, ...(genres.length ? ["divider" as const] : []), ...genres.map((g) => ({ value: g, label: g, selected: g === genre }))]}
          onPick={(v: string) => setGenre(v || null)} />
      </div>
      {!st?.loaded ? <div className="spinner-wrap"><span className="spinner" /></div>
        : !rows.length ? <p className="muted">{all.length ? "No matches." : `No ${noun} on My List yet. Add them with "Add to My List" on a title's page, on For You picks, or by right-clicking a poster.`}</p>
        : (
          <div className="rows columns">{rows.map((r) => {
            // A pick you've since added to the server: that title, its menu removes the saved pick.
            if (r.item) return <ServerRow key={entryId(r.entry)} item={r.item} actions={r.external ? [
              { label: "Open", icon: "play", run: () => navigate(routeFor(r.item!)) },
              { label: "Remove from My List", icon: "bookmark", danger: true, run: () => remove(r) },
            ] : undefined} />;
            const t = r.external!;
            const age = ageOf(r);
            return (
              <ListRow key={entryId(r.entry)} cover={resized(t.posterURL, "w185")} icon={isMovie(t) ? "film" : "tv"} title={t.title} subtitle={metaLine(t)} notOnServer
                onOpen={() => ui.openSheet({ kind: "tmdb", item: t })}
                onMenu={(e) => menuAt(e, t.title, isMovie(t), [
                  { label: "Details", icon: "info", run: () => ui.openSheet({ kind: "tmdb", item: t }) },
                  { label: "Already seen", icon: "eye", run: () => void titleAction(model, t, "seen") },
                  { label: "Not for me", icon: "thumbsDown", run: () => void titleAction(model, t, "notForMe") },
                  { label: "Remove from My List", icon: "bookmark", danger: true, run: () => remove(r) },
                ])}
                badges={<><ScoreBadge score={scoreOf(r)} />{age && <span className="bubble bubble-age">{age}</span>}</>} />
            );
          })}</div>
        )}
    </div>
  );
}

export function NotForMePage({ back }: { back?: () => void }) {
  const model = useModel();
  const st = model.storage;
  const [tab, setTab] = useState<ExternalListName>("notforme");
  // Anime turned down on For You are on AniList's private "Not for me" list.
  const aniOut = model.anilist.notForMeTitles.map((m) => model.anilist.title(m));
  const notForMe = [...(st?.notForMe ?? []), ...aniOut];
  const list = tab === "notforme" ? notForMe : st?.seenElsewhere ?? [];
  const serverList = (tab === "notforme" ? st?.notForMe : st?.seenElsewhere) ?? [];
  const label = (t: ExternalListName) => (t === "notforme" ? `Not for me (${notForMe.length})` : `Already seen (${st?.seenElsewhere.length ?? 0})`);
  return (
    <div className="page">
      <PageHeader title="Not for me" back={back} subtitle="For You picks you turned down, saved on your Jellyfin server">
        <Dropdown label={label(tab)} icon={tab === "notforme" ? "thumbsDown" : "eye"}
          items={(["notforme", "seenelsewhere"] as ExternalListName[]).map((t) => ({ value: t, label: label(t), selected: t === tab, icon: t === "notforme" ? "thumbsDown" : "eye" }))} onPick={setTab} />
        {serverList.length > 0 && <button className="glass-button" onClick={() => ui.openSheet({ kind: "confirm", title: tab === "notforme" ? "Clear Not for me?" : "Clear Already seen?", text: tab === "notforme" && aniOut.length ? 'These titles can be suggested by For You again. Anime on your AniList "Not for me" list stay: right-click one to undo it.' : "These titles can be suggested by For You again.", confirmLabel: "Clear all", danger: true, run: async () => { await st?.clear(tab); model.tasteChanged(); } })}>Clear all</button>}
      </PageHeader>
      {!st?.loaded && !list.length ? <div className="spinner-wrap"><span className="spinner" /></div>
        : !list.length ? <Empty icon={tab === "notforme" ? "thumbsDown" : "eye"} title="Nothing here" text={tab === "notforme" ? 'Titles you mark "Not for me" in For You show up here.' : 'Titles you mark "Already seen" in For You show up here.'} />
        : (
          // The same poster grid as My List (age bubbles; right-click or … to undo or add to My List).
          <Grid min={model.settings.libraryCardSize}>
            {list.map((t) => <TitleCard key={titleId(t)} t={t} width={model.settings.libraryCardSize} actions={turnedDownActions(model, t, tab)} />)}
          </Grid>
        )}
      <p className="footnote">For titles on your server, Not for me is Jellyfin's own thumbs-down: undo it on the title's page.</p>
    </div>
  );
}

/** What a turned-down pick offers (the iPhone's long-press menu): undo, My List, details. */
function turnedDownActions(model: ReturnType<typeof useModel>, t: ExternalTitle, tab: ExternalListName): MenuAction[] {
  const onList = isAniList(t) ? model.anilist.isPlanned(t.sourceId) : !!model.storage?.hasTitle(t);
  return [
    { label: tab === "notforme" ? "Undo Not for me" : "Undo Already seen", icon: "undo", run: () => void titleAction(model, t, tab === "notforme" ? "undoNotForMe" : "undoSeen") },
    { label: onList ? "Remove from My List" : "Add to My List", icon: "bookmark", run: () => void titleAction(model, t, "myList") },
    { label: "Details", icon: "info", run: () => ui.openSheet({ kind: "tmdb", item: t }) },
  ];
}

/** A My List pick's menu (as on the iPhone): remove it, or mark it seen / not for me. */
export function myListActions(model: ReturnType<typeof useModel>, t: ExternalTitle): MenuAction[] {
  return [
    { label: "Details", icon: "info", run: () => ui.openSheet({ kind: "tmdb", item: t }) },
    { label: isAniList(t) ? "Remove from AniList Planning" : "Remove from My List", icon: "bookmark", danger: true, run: () => void titleAction(model, t, "myList") },
    { label: "Already seen", icon: "eye", run: () => void titleAction(model, t, "seen") },
    { label: "Not for me", icon: "thumbsDown", run: () => void titleAction(model, t, "notForMe") },
  ];
}

/** Counts for the sidebar: Planning on Anime lists, and My List's movies and shows. */
export function listCounts(model: ReturnType<typeof useModel>) {
  const st = model.storage;
  let movies = 0, shows = 0;
  for (const e of st?.myList ?? []) {
    if (e.external) { if (!isAniList(e.external)) { if (isMovie(e.external)) movies++; else shows++; } continue; }
    const item = e.serverId ? model.reco.byId.get(e.serverId) : undefined;
    if (!item || inAnimeLibrary(model, item.Id)) continue;
    if (item.Type === "Movie") movies++; else if (item.Type === "Series") shows++;
  }
  return { anime: model.anilist.loggedIn ? model.anilist.showCount("PLANNING") + serverAnimeCount(model) : 0, movies, shows, notForMe: (st?.notForMe.length ?? 0) + (st?.seenElsewhere.length ?? 0) + model.anilist.notForMeTitles.length };
}

/** Anime-library titles on My List that aren't on your AniList list (they show under Planning). */
let animeCountCache: { entries: unknown; list: unknown; owned: unknown; count: number } | null = null;
function serverAnimeCount(model: ReturnType<typeof useModel>) {
  const ani = model.anilist, list = model.storage?.myList ?? [], owned = model.reco.owned;
  if (animeCountCache && animeCountCache.entries === ani.entries && animeCountCache.list === list && animeCountCache.owned === owned) return animeCountCache.count;
  const index = ani.ownedIndex();
  const onAniList = new Set(ani.entries.flatMap((e) => { const o = index.find(e.media); return o ? [o.Id] : []; }));
  const count = list.filter((e) => e.serverId && model.reco.byId.has(e.serverId) && inAnimeLibrary(model, e.serverId) && !onAniList.has(e.serverId)).length;
  animeCountCache = { entries: ani.entries, list, owned, count };
  return count;
}
