// For You (the same screen as the iPhone app's): one pick at a time from TMDB, never anything
// already on your server. First dropdown: the library it learns from (Anime by default, or All);
// second: a category. My List / Not for me / Already seen are saved in your account (shared with
// the iPhone). The libraries named Anime and Anime Movies run on your AniList account instead, as in
// AniReco and on the iPhone: picks from your AniList list, My List = AniList Planning, Not for me on
// AniList, Already seen = Completed.

import { type MouseEvent as RMouseEvent, useEffect, useState } from "react";
import { type AniListLibrary, type AnimeCategory, ageLabel, aniListLibrary, categoryId, FEATURED } from "../core/anilist";
import { feedKey } from "../core/anilistService";
import { type ExternalPick, kindOf } from "../core/discovery";
import type { AppModel } from "../core/model";
import { ALL, currentSourceId, sourcesOf } from "../core/reco";
import { AccountStorage, setNotForMe } from "../core/storage";
import { type ExternalTitle, isAniList, isMovie, metaLine, resized, siteName, titleId } from "../core/titles";
import { Tmdb } from "../core/tmdb";
import type { Item } from "../core/types";
import { Chip, Cover, Dropdown, Empty, Field, MatchBubble, PageHeader, Shelf } from "./components";
import { ageBucket } from "../core/age";
import { relativeTime } from "./fmt";
import { Icon } from "./icons";
import { type MenuAction, ui, useModel, useNavigate } from "./state";

/** The library For You uses right now (saved choice, else the one named Anime). */
export function useSourceId(model: AppModel) {
  return currentSourceId(sourcesOf(model.views), model.settings.forYouLibrary);
}

/** Set when the library For You uses is Anime or Anime Movies: For You runs on AniList. */
export function useAniListLibrary(model: AppModel, sourceId: string): AniListLibrary | null {
  return aniListLibrary(sourcesOf(model.views).find((s) => s.id === sourceId)?.name);
}

/** Picks for a library (Home's "Picked for you" row uses this too). */
export function useForYou(genre: string | null = null, category: AnimeCategory | null = null) {
  const model = useModel();
  const sourceId = useSourceId(model);
  const anime = useAniListLibrary(model, sourceId);
  const configured = model.tmdb.configured;
  const ani = model.anilist;
  useEffect(() => {
    if (anime) {
      if (ani.loggedIn) { void ani.generate(anime, category); void ani.loadCategories(); }
      return;
    }
    const c = model.discoveryContext();
    if (c && configured && model.views.length) void model.discovery.ensureBuilt(c, sourceId);
  }, [model, sourceId, anime, configured, model.views.length, model.storage?.loaded, ani.loggedIn, ani.viewer?.id, category ? categoryId(category) : ""]); // eslint-disable-line react-hooks/exhaustive-deps
  if (anime) {
    const key = feedKey(anime, category);
    return {
      sourceId,
      picks: ani.externalPicks(anime, category),
      building: ani.building.has(key) || ani.loggingIn || (ani.loggedIn && !ani.listLoadedOnce),
      status: undefined as string | undefined,
      error: ani.errors.get(key),
    };
  }
  const c = model.discoveryContext();
  return {
    sourceId,
    picks: c ? model.discovery.visible(c, sourceId, genre) : [],
    building: model.discovery.building.has(sourceId),
    status: model.discovery.status.get(sourceId),
    error: model.discovery.errors.get(sourceId),
  };
}

// MARK: Lists (shared with the iPhone)

/** Adds or removes a title on your server from My List (episodes and seasons go on as their show). */
export async function toggleMyList(model: AppModel, item: Item) {
  const st = model.storage;
  if (!st) return;
  const on = !st.hasServer(AccountStorage.listId(item));
  try {
    await st.toggleServer(item);
    model.toast(on ? "Added to My List" : "Removed from My List", "success");
    model.tasteChanged();
  } catch (e) { model.fail(e, "Couldn't save My List"); }
}

/** My List / Not for me / Already seen for a title you don't have. */
export async function titleAction(model: AppModel, t: ExternalTitle, action: "myList" | "notForMe" | "seen" | "undoNotForMe" | "undoSeen") {
  // AniList titles: your AniList account (Planning, the private Not for me list, Completed).
  if (isAniList(t)) {
    const ani = model.anilist;
    if (action === "undoNotForMe") { await ani.undoNotForMe(t.sourceId); return; }
    if (action === "myList" && ani.isPlanned(t.sourceId)) { await ani.removeFromPlanning(t.sourceId); model.toast("Removed from your AniList Planning list", "success"); return; }
    const media = await ani.media(t.sourceId);
    if (!media) { model.toast("Couldn't reach AniList. Try again in a moment.", "error"); return; }
    if (action === "myList") { if (await ani.planToWatch(media)) model.toast("Added to your AniList Planning list", "success"); }
    else if (action === "notForMe") { ani.dismiss(media); model.toast("Won't be suggested again (saved on AniList)", "success"); }
    else if (action === "seen") { if (await ani.markCompleted(media)) { model.toast("Marked Completed on AniList", "success"); if (ani.ratePrompt) ui.openSheet({ kind: "anilistRate", media: ani.ratePrompt }); } }
    return;
  }
  const st = model.storage;
  if (!st) return;
  try {
    if (action === "myList") {
      const adding = !st.hasTitle(t);
      await st.toggleTitle(t);
      model.toast(adding ? "Added to My List" : "Removed from My List", "success");
    } else if (action === "notForMe") { await st.markNotForMe(t, true); model.toast("Won't be suggested again", "success"); }
    else if (action === "seen") { await st.markSeen(t, true); model.toast("Marked as already seen", "success"); }
    else if (action === "undoNotForMe") await st.markNotForMe(t, false);
    else await st.markSeen(t, false);
    model.tasteChanged();
  } catch (e) { model.fail(e, "Couldn't save"); }
}

/** "Not for me" on a title on your server: Jellyfin's thumbs-down (seen by every app). */
export async function dismiss(model: AppModel, item: Item) {
  model.dismissed.add(item.Id);
  item.UserData = { ...(item.UserData ?? {}), Likes: false };
  const known = model.reco.byId.get(item.Id);
  if (known) known.UserData = { ...(known.UserData ?? {}), Likes: false };
  model.tasteChanged();
  try { await setNotForMe(model.api!, item.Id, true); } catch (e) { model.fail(e, "Couldn't save Not for me"); }
}

export async function undismiss(model: AppModel, item: Item) {
  model.dismissed.delete(item.Id);
  item.UserData = { ...(item.UserData ?? {}), Likes: null };
  const known = model.reco.byId.get(item.Id);
  if (known) known.UserData = { ...(known.UserData ?? {}), Likes: null };
  model.tasteChanged();
  try { await setNotForMe(model.api!, item.Id, false); } catch (e) { model.fail(e); }
}

// MARK: The page

export function ForYouPage({ refreshKey }: { refreshKey: number }) {
  const model = useModel();
  const navigate = useNavigate();
  const [genre, setGenre] = useState<string | null>(null);
  const [category, setCategory] = useState<AnimeCategory | null>(null);
  const { sourceId, picks, building, status, error } = useForYou(genre, category);
  const [index, setIndex] = useState(0);
  const [handled, setHandled] = useState(0);
  const sources = sourcesOf(model.views);
  const source = sources.find((s) => s.id === sourceId);
  const configured = model.tmdb.configured;
  const anime = useAniListLibrary(model, sourceId);
  const ani = model.anilist;

  const rebuild = (g: string | null = null) => {
    if (anime) {
      void (async () => { await ani.refreshList(); await ani.generate(anime, category, true); })();
      return;
    }
    const c = model.discoveryContext();
    if (c) void model.discovery.build(c, sourceId, g);
  };
  useEffect(() => { setIndex(0); setHandled(0); setGenre(null); setCategory(null); }, [sourceId]);
  // Near the end of an AniList feed: dig one round deeper (AniReco's endless feed).
  const nearEnd = (i: number) => { if (anime && i >= picks.length - 5) void ani.loadMore(anime, category); };
  const [lastRefresh, setLastRefresh] = useState(refreshKey);
  useEffect(() => {
    if (refreshKey === lastRefresh) return;
    setLastRefresh(refreshKey);
    setIndex(0); setHandled(0);
    rebuild();
  }, [refreshKey]); // eslint-disable-line react-hooks/exhaustive-deps
  const pickGenre = (g: string | null) => {
    setGenre(g); setIndex(0); setHandled(0);
    // Few picks in this category yet: dig deeper into it.
    const c = model.discoveryContext();
    if (g && c && model.discovery.visible(c, sourceId, g).length < 12) rebuild(g);
  };

  const genres = model.discovery.genres(sourceId);
  // AniList categories (AniReco's): the popular ones first, then every genre and tag.
  const allCategories = ani.categories.length ? ani.categories : FEATURED;
  const featuredIds = new Set(FEATURED.map(categoryId));
  const aniCategoryItems = [
    { value: "", label: "Any category", selected: !category },
    "divider" as const,
    { section: "Popular" },
    ...allCategories.filter((c) => featuredIds.has(categoryId(c))).map((c) => ({ value: categoryId(c), label: c.name, selected: !!category && categoryId(c) === categoryId(category) })),
    ...(allCategories.some((c) => c.kind === "genre" && !featuredIds.has(categoryId(c))) ? [{ section: "More genres" }] : []),
    ...allCategories.filter((c) => c.kind === "genre" && !featuredIds.has(categoryId(c))).map((c) => ({ value: categoryId(c), label: c.name, selected: !!category && categoryId(c) === categoryId(category) })),
    ...(allCategories.some((c) => c.kind === "tag" && !featuredIds.has(categoryId(c))) ? [{ section: "Tags" }] : []),
    ...allCategories.filter((c) => c.kind === "tag" && !featuredIds.has(categoryId(c))).map((c) => ({ value: categoryId(c), label: c.name, selected: !!category && categoryId(c) === categoryId(category) })),
  ];
  const pickCategory = (id: string) => {
    setCategory(allCategories.find((c) => categoryId(c) === id) ?? null);
    setIndex(0); setHandled(0);
  };
  const kind = kindOf(source);
  const noun = ({ animeShows: "anime", animeMovies: "anime movie", movies: "movie", shows: "TV show" } as Record<string, string>)[kind] ?? "title";
  const what = ({ animeShows: "anime", animeMovies: "anime movies", movies: "movies", shows: "shows" } as Record<string, string>)[kind] ?? "shows and movies";
  const sourceIcon = (s: typeof source) => (!s || s.id === ALL ? "grid" : /anime/i.test(s.name) ? "sparkles" : s.collectionType === "movies" ? "film" : s.collectionType === "tvshows" ? "tv" : "layers");
  const libraryItems = sources.map((s) => ({ value: s.id, label: s.name, selected: s.id === sourceId, icon: sourceIcon(s) }));
  const categoryItems = [
    { value: "", label: "Any category", selected: !genre },
    ...(genres.length ? ["divider" as const] : []),
    ...genres.map((g) => ({ value: g, label: g, selected: g === genre })),
  ];

  let content;
  if (anime && !ani.loggedIn) content = <AniListConnect library={anime} />;
  else if (anime && !picks.length && building) content = <Building text={category ? `Finding ${category.name} picks: comparing your AniList favourites with what fans recommend.` : `Comparing your AniList favourites with what fans recommend${model.settings.useOnDeviceAI ? ", with on-device AI" : ""}. This only runs when your list changes.`} />;
  else if (anime && !picks.length && error) content = <Empty icon="info" title="Couldn't build picks" text={error}><button className="glass-button" onClick={() => rebuild()}><Icon name="refresh" size={15} /> Try again</button></Empty>;
  else if (anime && !picks.length) content = <Empty icon="wand" title="No picks yet" text={category ? `Nothing new in ${category.name} right now. Try another category.` : "Rate a few shows on your AniList, then try again."}><button className="glass-button" onClick={() => rebuild()}><Icon name="refresh" size={15} /> Try again</button></Empty>;
  else if (!anime && !configured) content = <TmdbKeySetup />;
  else if (!picks.length && building) content = <Building text={status ?? `Comparing what you finished on your server with what's out there${model.settings.useOnDeviceAI ? ", with on-device AI" : ""}.`} />;
  else if (!picks.length && error) content = <Empty icon="info" title="No picks right now" text={error}><button className="glass-button" onClick={() => rebuild()}><Icon name="refresh" size={15} /> Try again</button></Empty>;
  else if (!picks.length) content = <Empty icon="wand" title="No picks right now" text={genre ? `Nothing new in ${genre} right now.` : "Press Try again to look for picks."}><button className="glass-button" onClick={() => rebuild(genre)}><Icon name="refresh" size={15} /> Try again</button></Empty>;
  else {
    const safe = Math.min(index, picks.length - 1);
    const pick = picks[safe];
    content = (
      <>
        <PickCard key={titleId(pick.title)} pick={pick} position={safe + 1 + handled} total={picks.length + handled} noun={noun}
          onNext={() => { const next = safe + 1 >= picks.length ? 0 : safe + 1; setIndex(next); nearEnd(next); }} onHandled={() => { setHandled((h) => h + 1); nearEnd(safe); }} />
        {picks.length > 1 && (
          <Shelf title="More picks">
            {picks.map((p, i) => <TitleCard key={titleId(p.title)} t={p.title} match={p.match} highlighted={i === safe} onClick={() => { setIndex(i); nearEnd(i); }} />)}
            {(building || (anime && ani.loadingMore.has(feedKey(anime, category)))) && <div className="shelf-spinner"><span className="spinner" /></div>}
          </Shelf>
        )}
        <p className="footnote center-text">{anime ? aniFooter(model, anime, category) : footer(model, sourceId, source?.name ?? "All")}</p>
      </>
    );
  }

  return (
    <div className="page">
      <PageHeader title="For You" subtitle={`New ${what} you don't have yet, picked from what you watch`}>
        <Dropdown label={source?.name ?? "All"} icon={sourceIcon(source)} items={libraryItems} onPick={(v) => model.updateSettings({ forYouLibrary: v })} />
        {anime
          ? <Dropdown label={category?.name ?? "Any category"} icon="filter" items={aniCategoryItems} onPick={(v: string) => pickCategory(v)} />
          : <Dropdown label={genre ?? "Any category"} icon="filter" items={categoryItems} onPick={(v) => pickGenre(v || null)} />}
        <button className="round-button" title="Fresh picks (F5)" aria-label="Fresh picks" disabled={building} onClick={() => { setIndex(0); setHandled(0); rebuild(); }}><Icon name="refresh" size={16} /></button>
        <button className="round-button" title="My List" aria-label="My List" onClick={() => navigate({ kind: "myList" })}><Icon name="bookmark" size={16} /></button>
      </PageHeader>
      {content}
    </div>
  );
}

function aniFooter(model: AppModel, library: AniListLibrary, category: AnimeCategory | null) {
  const feed = model.anilist.feeds.get(feedKey(library, category));
  const viewer = model.anilist.viewer;
  return `Built ${feed ? relativeTime(feed.generatedAt) : "just now"} from your AniList list${viewer ? ` (${viewer.name})` : ""} and what fans recommend${feed?.usedAI ? ", with on-device AI" : ""}. Nothing here is on your server or your AniList list yet.`;
}

/** Shown on For You (Anime / Anime Movies) until an AniList account is connected. */
function AniListConnect({ library }: { library: AniListLibrary }) {
  return (
    <div className="panel setup-card">
      <Icon name="sparkles" size={34} />
      <h3>Connect AniList</h3>
      <p className="muted">{library === "movies" ? "Anime Movies" : "Anime"} picks come from your AniList list, the same way as in AniReco and on the iPhone, and never include anything already on your server. Add to My List puts a show on your AniList Planning list, Not for me goes to a private "Not for me" list on AniList, Already seen marks it Completed.</p>
      <AniListLogin />
    </div>
  );
}

/** Client ID + "Log in with AniList" (AniList's own login page in a small window), or a token. */
export function AniListLogin() {
  const model = useModel();
  const [clientId, setClientId] = useState(model.settings.anilistClientId);
  const [token, setToken] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => { if (!clientId && model.settings.anilistClientId) setClientId(model.settings.anilistClientId); }, [model.settings.anilistClientId]); // eslint-disable-line react-hooks/exhaustive-deps
  const open = async (url: string) => { const { openUrl } = await import("@tauri-apps/plugin-opener"); await openUrl(url); };
  const logIn = async () => {
    const id = clientId.trim();
    if (!/^\d+$/.test(id)) { setError("That isn't an AniList client ID (it's a number)."); return; }
    model.updateSettings({ anilistClientId: id });
    setError(null); setBusy(true);
    try {
      const { invoke } = await import("@tauri-apps/api/core");
      const got = await invoke<string>("anilist_login", { clientId: id });
      await model.anilist.logIn(got);
    } catch (e) {
      const msg = String((e as Error)?.message ?? e);
      if (msg !== "cancelled") setError(msg);
    } finally { setBusy(false); }
  };
  return (
    <div className="anilist-login">
      <ol className="muted small">
        <li>On AniList: Settings → Developer → Create New Client (the same one as on the iPhone works).</li>
        <li>Redirect URL: <code>jellyreco://auth</code></li>
        <li>Paste its client ID here and log in. (The iPhone's client ID fills in on its own.)</li>
      </ol>
      <button className="link-button" onClick={() => void open("https://anilist.co/settings/developer")}><Icon name="external" size={14} /> Open AniList developer settings</button>
      <form className="row-line" onSubmit={(e) => { e.preventDefault(); void logIn(); }}>
        <Field label="AniList client ID"><input value={clientId} inputMode="numeric" onChange={(e) => setClientId(e.target.value.replace(/\D/g, ""))} spellCheck={false} /></Field>
        <button className="glass-button prominent" disabled={busy || model.anilist.loggingIn || !clientId}>{busy || model.anilist.loggingIn ? <span className="spinner small" /> : "Log in with AniList"}</button>
      </form>
      <form className="row-line" onSubmit={(e) => { e.preventDefault(); const t = token; setToken(""); void model.anilist.logIn(t); }}>
        <Field label="Or paste an AniList access token"><input type="password" value={token} onChange={(e) => setToken(e.target.value)} spellCheck={false} autoComplete="off" /></Field>
        <button className="glass-button" disabled={!token.trim()}>Use token</button>
      </form>
      {error && <p className="footnote error">{error}</p>}
      <p className="footnote">The login is kept with this PC's sign-ins, for this Jellyfin account only.</p>
    </div>
  );
}

function footer(model: AppModel, sourceId: string, name: string) {
  const at = model.discovery.builtAt.get(sourceId);
  return `Built ${at ? relativeTime(at) : "just now"} from what you watched in ${name}, TMDB's also-liked lists${model.discovery.usedAI ? " and on-device AI" : ""}. Nothing here is on your server yet.`;
}

function Building({ text }: { text: string }) {
  return (
    <div className="building">
      <span className="spinner" />
      <h3>Finding picks for you</h3>
      <p className="muted">{text}</p>
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
      await model.setTmdbKey(key);
      model.toast("TMDB connected", "success");
    } catch (e) { model.fail(e, "TMDB"); } finally { setBusy(false); }
  };
  return (
    <div className="panel setup-card">
      <Icon name="wand" size={34} />
      <h3>Connect TMDB for picks</h3>
      <p className="muted">For You suggests shows, anime and movies you don't have yet, using The Movie Database (TMDB). It needs your own free TMDB key, entered once: it's saved to your Jellyfin account, so the iPhone app gets it too.</p>
      <ol className="muted small">
        <li>Sign in at themoviedb.org and open Settings → API.</li>
        <li>Request an API key (choose "Personal use").</li>
        <li>Paste the "API Read Access Token" (the long one) or the "API Key" here.</li>
      </ol>
      <button className="link-button" onClick={async () => { const { openUrl } = await import("@tauri-apps/plugin-opener"); await openUrl("https://www.themoviedb.org/settings/api"); }}><Icon name="external" size={14} /> Open TMDB API settings</button>
      <form className="row-line" onSubmit={(e) => { e.preventDefault(); void save(); }}>
        <Field label="TMDB API Read Access Token or API key"><input value={key} onChange={(e) => setKey(e.target.value)} spellCheck={false} /></Field>
        <button className="glass-button prominent" disabled={busy || key.trim().length < 20}>{busy ? <span className="spinner small" /> : "Connect"}</button>
      </form>
    </div>
  );
}

/** The age bubble on a TMDB cover. Titles that came without full details (rows, "More like this",
 *  saved picks) look theirs up once when they appear, and the bubble fades in (as on the iPhone). */
export function ExternalAgeBubble({ t }: { t: ExternalTitle }) {
  return isAniList(t) ? <AniListAgeBubble id={t.sourceId} /> : <TmdbAgeBubble t={t} />;
}

/** Kitsu's age rating on an AniList cover (as in AniReco), looked up in batches as covers appear. */
function AniListAgeBubble({ id }: { id: number }) {
  const model = useModel();
  useEffect(() => { model.anilist.requestAge(id); }, [id]); // eslint-disable-line react-hooks/exhaustive-deps
  const label = ageLabel(model.anilist.ages.get(id));
  return label ? <span className="bubble bubble-age bubble-in">{label}</span> : null;
}

function TmdbAgeBubble({ t }: { t: ExternalTitle }) {
  const model = useModel();
  const id = titleId(t);
  const [looked, setLooked] = useState<ExternalTitle | null>(null);
  useEffect(() => {
    if (t.ageRating || !model.tmdb.configured) return;
    let alive = true;
    void model.tmdb.details(t).then((d) => { if (alive) setLooked(d); }).catch(() => {});
    return () => { alive = false; };
  }, [id]); // eslint-disable-line react-hooks/exhaustive-deps
  const label = ageBucket((looked && titleId(looked) === id ? looked : t).ageRating);
  return label ? <span className="bubble bubble-age bubble-in">{label}</span> : null;
}

/** A poster for a title you don't have (opens its details). */
export function TitleCard({ t, match, onClick, width = 140, highlighted, notOnServer, actions }: { t: ExternalTitle; match?: number; onClick?: () => void; width?: number; highlighted?: boolean; notOnServer?: boolean; actions?: MenuAction[] }) {
  const open = onClick ?? (() => ui.openSheet({ kind: "tmdb", item: t }));
  // Right-click (or the … button) opens the card's own actions, as long-press does on the iPhone.
  const menu = actions?.length ? (e: RMouseEvent) => {
    e.preventDefault();
    e.stopPropagation();
    ui.showMenu({ x: e.clientX, y: e.clientY, item: { Id: titleId(t), Name: t.title, Type: isMovie(t) ? "Movie" : "Series" }, actions });
  } : undefined;
  return (
    <div className={`card ${highlighted ? "highlighted" : ""}`} style={{ width, ["--ar" as string]: "2 / 3" }} onContextMenu={menu}>
      <button className="card-cover" onClick={open} title={t.title}>
        <Cover url={resized(t.posterURL, "w342")} width={width} height={Math.round(width * 1.5)} radius={14} icon="film" />
        {/* As on the iPhone: age bubble top left, match % bottom left, and a My List title you don't
            have yet gets the cloud-with-arrow badge top right (so it never covers the age bubble). */}
        <div className="card-badges"><ExternalAgeBubble t={t} /></div>
        {match !== undefined && <div className="card-match"><MatchBubble value={match} /></div>}
        {notOnServer && <div className="card-badge-tr glass-icon" title="Not on your server yet"><Icon name="cloudDown" size={16} strokeWidth={2.1} /></div>}
        {menu && <span className="card-more" role="button" aria-label="More" onClick={menu}><Icon name="more" size={18} /></span>}
      </button>
      <div className="card-title">{t.title}</div>
      {t.year && <div className="card-sub">{t.year}</div>}
    </div>
  );
}

function PickCard({ pick, position, total, noun, onNext, onHandled }: { pick: ExternalPick; position: number; total: number; noun: string; onNext: () => void; onHandled: () => void }) {
  const model = useModel();
  const t = pick.title;
  const back = resized(t.backdropURL, "w1280");
  const onList = isAniList(t) ? model.anilist.isPlanned(t.sourceId) : !!model.storage?.hasTitle(t);
  const details = () => ui.openSheet({ kind: "tmdb", item: t });
  const meta = [metaLine(t), t.score ? `★ ${t.score.toFixed(1)} ${siteName(t)}${t.voteCount ? ` (${t.voteCount.toLocaleString()})` : ""}` : null].filter(Boolean).join(" · ");
  return (
    <article className="pick panel" style={back ? { backgroundImage: `linear-gradient(90deg, var(--pick-fade) 35%, transparent), url("${back}")`, backgroundSize: "cover", backgroundPosition: "center" } : undefined}>
      <div className="pick-cover" onClick={details}>
        <Cover url={resized(t.posterURL, "w500")} width={230} height={345} radius={18} icon="film" />
      </div>
      <div className="pick-body">
        <div className="muted small">Pick {position} of {total} · {noun === "anime" ? "an anime" : `a ${noun}`} you don't have</div>
        <h2>{t.title}</h2>
        <div className="pick-match">{pick.match}% match</div>
        <div className="muted small">{meta}</div>
        {pick.because.length > 0 && <div className="because"><Icon name="heart" size={16} /> Because you watched <strong>{pick.because.join(", ")}</strong></div>}
        {pick.highlights.length > 0 && <div className="chips-wrap">{pick.highlights.map((h) => <Chip key={h} text={h} />)}</div>}
        <p className="pick-synopsis clamp-6">{t.overview}</p>
        <button className="glass-button" onClick={() => ui.openSheet({ kind: "why", item: { Id: titleId(t), Name: t.title, Type: isMovie(t) ? "Movie" : "Series" }, because: pick.because, highlights: pick.highlights })}><Icon name="sparkles" size={16} /> Why would I like this?</button>
        <div className="pick-actions">
          <button className="glass-button prominent" onClick={() => { if (!onList) onHandled(); void titleAction(model, t, "myList"); }}><Icon name="bookmark" size={16} /> {onList ? "On My List" : "Add to My List"}</button>
          <button className="glass-button" onClick={details}><Icon name="info" size={16} /> Details</button>
          <button className="glass-button danger" onClick={() => { onHandled(); void titleAction(model, t, "notForMe"); }}><Icon name="thumbsDown" size={16} /> Not for me</button>
          <button className="glass-button" onClick={() => { onHandled(); void titleAction(model, t, "seen"); }}><Icon name="eye" size={16} /> Already seen</button>
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
