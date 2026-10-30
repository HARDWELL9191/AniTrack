// For You (AniReco's tab, for discovering what to get next): one personal pick at a time from
// TMDB, never anything already on your server. First dropdown: which of your libraries the picks
// are for (Anime by default, or All); second: a category (genre).

import { useEffect, useState } from "react";
import { ReadOnlyJellyfin } from "../core/api";
import { type ListEntry, type ListName, setNotForMe } from "../core/lists";
import type { AppModel } from "../core/model";
import { defaultLibrary, type Feed, loadLibrary, type Pick, recommend } from "../core/recommender";
import { poster, Tmdb, type TmdbItem, tmdbKey } from "../core/tmdb";
import { Chip, Cover, Dropdown, Empty, Field, PageHeader, Shelf } from "./components";
import { relativeTime } from "./fmt";
import { Icon } from "./icons";
import { ui, useModel, useNavigate } from "./state";

const LIBRARY_TTL = 10 * 60_000;
const loading = new Map<string, Promise<void>>();
const feedKey = (lib: string, cat: string) => `${lib}|${cat}`;

/** Set from main.tsx: battery saver pauses the on-device AI. */
export const powerSaver = { on: false };

let tmdbClient: { key: string; client: Tmdb } | null = null;
export function getTmdb(model: AppModel): Tmdb {
  const key = model.settings.tmdbKey;
  if (!tmdbClient || tmdbClient.key !== key) tmdbClient = { key, client: new Tmdb(key) };
  return tmdbClient.client;
}

export function currentLibraryChoice(model: AppModel): string {
  const lib = model.forYouLibrary;
  const chosen = model.settings.forYouLibrary;
  if (chosen === "all") return "all";
  if (chosen && lib?.libraries.some((l) => l.id === chosen)) return chosen;
  return lib ? defaultLibrary(lib) : "";
}

/** Your library and watch history, read with a read-only handle. */
export async function ensureLibrary(model: AppModel, force = false) {
  const api = model.api;
  if (!api) return;
  if (!force && model.forYouLibrary && Date.now() - model.forYouLibrary.loadedAt < LIBRARY_TTL) return;
  model.forYouLibrary = await loadLibrary(new ReadOnlyJellyfin(api), model.views);
  model.feeds.clear();
  // Watched titles leave Watch later on their own (like AniReco's Completed).
  const watched = model.forYouLibrary.items.filter((i) => i.UserData?.Played && model.lists?.has(i.Id)).map((i) => i.Id);
  if (watched.length) await model.lists?.remove(watched).catch(() => {});
  // A Watch later title you've since added to the server leaves the outside list.
  const lib = model.forYouLibrary;
  const nowOwned = (model.lists?.watchLater ?? []).filter((e) => e.id.startsWith("tmdb:") && lib.owned.tmdb.has(e.id)).map((e) => e.id);
  if (nowOwned.length) await model.lists?.remove(nowOwned).catch(() => {});
}

/** Builds (or extends, with `more`) the feed for a library and category. */
export function buildFeed(model: AppModel, libraryId: string, category: string, opts: { force?: boolean; more?: boolean } = {}): Promise<void> {
  const key = feedKey(libraryId, category) + (opts.more ? "+" : "");
  const running = loading.get(key);
  if (running) return running;
  const job = (async () => {
    try {
      const tmdb = getTmdb(model);
      if (!tmdb.configured) return;
      await ensureLibrary(model, opts.force);
      const lib = model.forYouLibrary!;
      const lid = libraryId || defaultLibrary(lib);
      const k = feedKey(lid, category);
      const existing = model.feeds.get(k);
      if (existing && !opts.force && !opts.more) return;
      if (opts.more && existing?.exhausted) return;
      const round = opts.more && existing ? Math.floor(existing.picks.length / 40) + 1 : 1;
      const lists = model.lists?.lists ?? { watchLater: [], notForMe: [], seen: [] };
      const feed = await recommend(new ReadOnlyJellyfin(model.api!), tmdb, lib, {
        libraryId: lid, category, minRating: model.settings.forYouMinRating, dismissed: model.dismissed,
        watchLater: lists.watchLater, notForMe: lists.notForMe, seen: lists.seen,
        useAI: model.settings.useOnDeviceAI && !powerSaver.on, exclude: new Set(opts.more && existing ? existing.picks.map((p) => p.key) : []),
      }, round);
      model.feeds.set(k, opts.more && existing ? { ...feed, picks: [...existing.picks, ...feed.picks], categories: existing.categories } : feed);
    } catch (e) {
      model.fail(e, "Couldn't build your picks");
    } finally {
      loading.delete(key);
      model.notify();
    }
  })();
  loading.set(key, job);
  model.notify();
  return job;
}

/** The feed for the current dropdown choices (used by Home's "Picked for you" too). */
export function useForYouFeed() {
  const model = useModel();
  const libId = currentLibraryChoice(model);
  const cat = model.settings.forYouCategory;
  const key = feedKey(libId, cat);
  useEffect(() => { void buildFeed(model, libId, cat); }, [model, key, model.views.length, model.settings.tmdbKey]); // eslint-disable-line react-hooks/exhaustive-deps
  return { feed: model.feeds.get(key), loading: [...loading.keys()].some((k) => k.startsWith(key) || k.startsWith(feedKey("", cat))) };
}

export function removeFromFeeds(model: AppModel, key: string) {
  for (const [k, f] of model.feeds) model.feeds.set(k, { ...f, picks: f.picks.filter((p) => p.key !== key) });
  model.notify();
}

export function snapshot(t: TmdbItem, genres: string[]): Omit<ListEntry, "added"> {
  return { id: tmdbKey(t), title: t.title, poster: t.posterPath, year: t.date ? Number(t.date.slice(0, 4)) : null, genres, overview: t.overview.slice(0, 300) };
}

/** Adds an outside title to one of your server-side lists (Watch later, Not for me, Already watched). */
export async function addExternal(model: AppModel, t: TmdbItem, genres: string[], list: ListName) {
  try {
    await model.lists?.add(snapshot(t, genres), list);
    removeFromFeeds(model, tmdbKey(t));
    model.toast(list === "watchLater" ? "Added to Watch later" : list === "notForMe" ? "Won't be suggested again" : "Marked as watched", "success");
    model.dataChanged();
  } catch (e) { model.fail(e, "Couldn't save"); }
}

// MARK: Library titles: Not for me and Watch later

/** "Not for me" on a title on your server: thumbs-down on the server. */
export async function dismiss(model: AppModel, id: string) {
  model.dismissed.add(id);
  const item = model.forYouLibrary?.items.find((i) => i.Id === id);
  if (item) item.UserData = { ...(item.UserData ?? {}), Likes: false };
  model.feeds.clear();
  try { await setNotForMe(model.api!, id, true); } catch (e) { model.fail(e, "Couldn't save Not for me"); }
  model.notify();
}

export async function undismiss(model: AppModel, id: string) {
  model.dismissed.delete(id);
  const item = model.forYouLibrary?.items.find((i) => i.Id === id);
  if (item) item.UserData = { ...(item.UserData ?? {}), Likes: null };
  model.feeds.clear();
  try { await setNotForMe(model.api!, id, false); } catch (e) { model.fail(e); }
  model.notify();
}

/** Watch later for a title on your server, saved on the server. */
export async function toggleWatchLater(model: AppModel, id: string) {
  const lists = model.lists;
  if (!lists) return;
  try {
    if (lists.has(id)) { await lists.remove([id]); model.toast("Removed from Watch later", "success"); }
    else { await lists.add(id); model.toast("Added to Watch later", "success"); }
    model.feeds.clear();
    model.dataChanged();
  } catch (e) { model.fail(e, "Couldn't save Watch later"); }
}

// MARK: The page

export function ForYouPage({ refreshKey }: { refreshKey: number }) {
  const model = useModel();
  const navigate = useNavigate();
  const { feed, loading: busy } = useForYouFeed();
  const [index, setIndex] = useState(0);
  const lib = model.forYouLibrary;
  const libId = currentLibraryChoice(model);
  const cat = model.settings.forYouCategory;
  const tmdb = getTmdb(model);

  useEffect(() => setIndex(0), [libId, cat]);
  const [lastRefresh, setLastRefresh] = useState(refreshKey);
  useEffect(() => {
    if (refreshKey === lastRefresh) return;
    setLastRefresh(refreshKey);
    setIndex(0);
    void buildFeed(model, libId, cat, { force: true });
  }, [refreshKey, lastRefresh, model, libId, cat]);

  const picks = feed?.picks ?? [];
  useEffect(() => {
    if (feed && !feed.exhausted && index >= picks.length - 5) void buildFeed(model, libId, cat, { more: true });
  }, [index, picks.length, feed?.exhausted]); // eslint-disable-line react-hooks/exhaustive-deps

  const libInfo = lib?.libraries.find((l) => l.id === libId);
  const libraryName = libId === "all" ? "All libraries" : libInfo?.name ?? "Library";
  const libraryItems = [
    { value: "all", label: "All libraries", selected: libId === "all", icon: "grid" },
    "divider" as const,
    ...(lib?.libraries ?? []).map((l) => ({ value: l.id, label: l.name, detail: `${l.kind === "movie" ? "Movies" : l.kind === "tv" ? "Shows" : "Shows & movies"}${l.anime ? " · anime" : ""}`, selected: l.id === libId })),
  ];
  const categoryItems = [
    { value: "", label: "All categories", selected: !cat, icon: "grid" },
    "divider" as const,
    ...(feed?.categories ?? []).map((c) => ({ value: c.name, label: c.name, selected: c.name === cat })),
  ];
  const next = () => setIndex((i) => (i >= picks.length - 1 ? 0 : i + 1));

  let content;
  if (!tmdb.configured) content = <TmdbKeySetup />;
  else if (!lib && busy) content = <Building text="Reading your library and watch history…" />;
  else if (busy && !picks.length) content = <Building text={cat ? `Finding ${cat} picks for ${libraryName}…` : `Finding picks for ${libraryName}…`} />;
  else if (!picks.length) {
    content = (
      <Empty icon="wand" title="No picks right now"
        text={feed?.error ? feed.error : cat ? `Nothing new in ${cat}. Try another category.` : feed && feed.watchedCount < 3 ? "Watch, rate or favorite a few titles first. Picks come from your watch history." : "Nothing new to suggest here. Try another library or category."} />
    );
  } else {
    const safe = Math.min(index, picks.length - 1);
    const shown = picks[safe];
    content = (
      <>
        <PickCard key={shown.key} pick={shown} position={safe + 1} total={picks.length} moreComing={!feed?.exhausted} onNext={next} />
        {picks.length > 1 && (
          <Shelf title="More picks">
            {picks.map((p, i) => <TmdbCard key={p.key} t={p.tmdb} match={p.match} genres={p.genres} onClick={() => setIndex(i)} />)}
            {busy && <div className="shelf-spinner"><span className="spinner" /></div>}
          </Shelf>
        )}
        {feed && <p className="footnote center-text">{footer(feed)}</p>}
      </>
    );
  }

  return (
    <div className="page">
      <PageHeader title="For You" subtitle="Shows and movies you don't have yet, picked from what you watch">
        <Dropdown label={libraryName} icon={libId === "all" ? "grid" : "folder"} items={libraryItems} onPick={(v) => model.updateSettings({ forYouLibrary: v, forYouCategory: "" })} />
        <Dropdown label={cat || "All categories"} icon="tag" items={categoryItems} onPick={(v) => model.updateSettings({ forYouCategory: v })} />
        <button className="round-button" title="Fresh picks (F5)" onClick={() => void buildFeed(model, libId, cat, { force: true })}><Icon name="refresh" size={16} /></button>
      </PageHeader>
      {content}
      <div className="row-line">
        <button className="text-button small" onClick={() => navigate({ kind: "browse", title: "Watch later", query: { watchLater: true } })}><Icon name="bookmark" size={14} /> Watch later ({model.lists?.watchLater.length ?? 0})</button>
        <button className="text-button small" onClick={() => navigate({ kind: "browse", title: "Not for me", query: { dismissed: true } })}><Icon name="thumbsDown" size={14} /> Not for me</button>
        <button className="text-button small" onClick={() => navigate({ kind: "browse", title: "Watched elsewhere", query: { seen: true } })}><Icon name="eye" size={14} /> Watched elsewhere</button>
      </div>
    </div>
  );
}

function TmdbKeySetup() {
  const model = useModel();
  const [key, setKey] = useState("");
  const [busy, setBusy] = useState(false);
  const save = async () => {
    setBusy(true);
    try {
      await new Tmdb(key).check();
      model.updateSettings({ tmdbKey: key.trim() });
      model.toast("TMDB connected", "success");
    } catch (e) { model.fail(e, "TMDB"); } finally { setBusy(false); }
  };
  return (
    <div className="panel setup-card">
      <Icon name="wand" size={34} />
      <h3>Connect TMDB for picks</h3>
      <p className="muted">For You suggests shows, anime and movies you don't have yet, using The Movie Database (TMDB). It needs your own free TMDB API key, entered once; it's saved to your Jellyfin account.</p>
      <ol className="muted small">
        <li>Sign in at themoviedb.org and open Settings → API.</li>
        <li>Request an API key (choose "Personal use").</li>
        <li>Paste the "API Key" or the "API Read Access Token" here.</li>
      </ol>
      <button className="link-button" onClick={async () => { const { openUrl } = await import("@tauri-apps/plugin-opener"); await openUrl("https://www.themoviedb.org/settings/api"); }}><Icon name="external" size={14} /> Open TMDB API settings</button>
      <form className="row-line" onSubmit={(e) => { e.preventDefault(); void save(); }}>
        <Field label="TMDB API key or read access token"><input value={key} onChange={(e) => setKey(e.target.value)} spellCheck={false} /></Field>
        <button className="glass-button prominent" disabled={busy || key.trim().length < 20}>{busy ? <span className="spinner small" /> : "Connect"}</button>
      </form>
    </div>
  );
}

function Building({ text }: { text: string }) {
  const model = useModel();
  return (
    <div className="building">
      <span className="spinner" />
      <h3>{text}</h3>
      <p className="muted">{model.settings.useOnDeviceAI ? "Comparing what you watched with TMDB's catalog using on-device AI. Nothing on your server is changed." : "Comparing what you watched with TMDB's catalog."}</p>
    </div>
  );
}

function footer(feed: Feed) {
  const engine = feed.usedAI ? "your watch history, TMDB and on-device AI" : "your watch history and TMDB";
  return `Built ${relativeTime(feed.generatedAt)} from ${engine} (${feed.watchedCount} titles). Nothing you already have is suggested.` + (feed.exhausted ? "" : " More picks load as you go; F5 builds fresh ones.");
}

/** A poster card for a title you don't have. */
export function TmdbCard({ t, match, genres, onClick, width = 140 }: { t: TmdbItem | ListEntry; match?: number; genres?: string[]; onClick?: () => void; width?: number }) {
  const isEntry = !("kind" in t);
  const title = isEntry ? (t as ListEntry).title ?? "" : (t as TmdbItem).title;
  const path = isEntry ? (t as ListEntry).poster : (t as TmdbItem).posterPath;
  const year = isEntry ? (t as ListEntry).year : (t as TmdbItem).date?.slice(0, 4);
  const open = onClick ?? (() => { const item = isEntry ? entryToTmdb(t as ListEntry) : (t as TmdbItem); if (item) ui.openSheet({ kind: "tmdb", item, genres: genres ?? (t as ListEntry).genres ?? [] }); });
  return (
    <div className="card" style={{ width }}>
      <button className="card-cover" onClick={open} title={title}>
        <Cover url={poster(path, "w342")} width={width} height={Math.round(width * 1.5)} radius={12} icon="film" />
        {match !== undefined && <div className="card-age"><span className="bubble bubble-match">{match}%</span></div>}
        <div className="card-status ext" title="Not on your server"><Icon name="cloud" size={13} /></div>
      </button>
      <div className="card-title">{title}</div>
      {year && <div className="card-sub">{year}</div>}
    </div>
  );
}

export function entryToTmdb(e: ListEntry): TmdbItem | null {
  const m = /^tmdb:(tv|movie):(\d+)$/.exec(e.id);
  if (!m) return null;
  return { id: Number(m[2]), kind: m[1] as "tv" | "movie", title: e.title ?? "", overview: e.overview ?? "", posterPath: e.poster, genreIds: [], date: e.year ? `${e.year}-01-01` : undefined, voteAverage: 0, voteCount: 0, popularity: 0 };
}

function PickCard({ pick, position, total, moreComing, onNext }: { pick: Pick; position: number; total: number; moreComing: boolean; onNext: () => void }) {
  const model = useModel();
  const t = pick.tmdb;
  const back = poster(t.backdropPath, "w1280");
  const year = t.date?.slice(0, 4);
  const meta = [t.kind === "tv" ? "Show" : "Movie", year, t.voteAverage ? `★ ${t.voteAverage.toFixed(1)} (${t.voteCount.toLocaleString()})` : null].filter(Boolean).join(" · ");
  const details = () => ui.openSheet({ kind: "tmdb", item: t, genres: pick.genres });
  return (
    <article className="pick panel" style={back ? { backgroundImage: `linear-gradient(90deg, var(--pick-fade) 35%, transparent), url("${back}")`, backgroundSize: "cover", backgroundPosition: "center" } : undefined}>
      <div className="pick-cover" onClick={details}>
        <Cover url={poster(t.posterPath, "w500")} width={230} height={345} radius={16} icon="film" />
      </div>
      <div className="pick-body">
        <div className="muted small">{moreComing ? `Pick ${position}` : `Pick ${position} of ${total}`} · not on your server</div>
        <h2>{t.title}</h2>
        <div className="pick-match">{pick.match}% match</div>
        <div className="muted small">{meta}</div>
        {pick.because.length > 0 && <div className="because"><Icon name="heart" size={16} /> Because you watched <strong>{pick.because.join(", ")}</strong></div>}
        {(pick.highlights.length > 0 || pick.genres.length > 0) && <div className="chips-wrap">{(pick.highlights.length ? pick.highlights : pick.genres.slice(0, 4)).map((h) => <Chip key={h} text={h} />)}</div>}
        <p className="pick-synopsis clamp-6">{t.overview}</p>
        <button className="glass-button" onClick={() => ui.openSheet({ kind: "why", item: { Id: pick.key, Name: t.title, Type: t.kind === "tv" ? "Series" : "Movie" }, because: pick.because, highlights: pick.highlights })}><Icon name="sparkles" size={16} /> Why would I like this?</button>
        <div className="pick-actions">
          <button className="glass-button prominent" onClick={() => void addExternal(model, t, pick.genres, "watchLater")}><Icon name="bookmark" size={16} /> Watch later</button>
          <button className="glass-button" onClick={details}><Icon name="info" size={16} /> Details</button>
          <button className="glass-button danger" onClick={() => void addExternal(model, t, pick.genres, "notForMe")}><Icon name="thumbsDown" size={16} /> Not for me</button>
          <button className="glass-button" onClick={() => void addExternal(model, t, pick.genres, "seen")}><Icon name="eye" size={16} /> Already watched</button>
          <button className="glass-button" onClick={details}><Icon name="layers" size={16} /> More like this</button>
          <button className="glass-button" onClick={onNext}><Icon name="shuffle" size={16} /> Another pick</button>
        </div>
      </div>
    </article>
  );
}

export function WhyText({ because, highlights, name }: { because: string[]; highlights: string[]; name: string }) {
  const parts: string[] = [];
  if (because.length) parts.push(`${name} is what people who loved ${because.slice(0, 2).join(" and ")} go on to watch${because.length > 2 ? ` (and it ties to ${because.length - 2} more of yours)` : ""}.`);
  if (highlights.length) parts.push(`It has what you keep coming back to: ${highlights.join(", ")}.`);
  if (!parts.length) parts.push("It fits the overall shape of what you watch, by genre, language and story.");
  return <p>{parts.join(" ")}</p>;
}
