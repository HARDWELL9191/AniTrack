// For You (the same screen as the iPhone app's): one pick at a time from TMDB, never anything
// already on your server. First dropdown: the library it learns from (Anime by default, or All);
// second: a category. My List / Not for me / Already seen are saved in your account (shared with
// the iPhone).

import { useEffect, useState } from "react";
import { type ExternalPick, kindOf } from "../core/discovery";
import type { AppModel } from "../core/model";
import { ALL, currentSourceId, sourcesOf } from "../core/reco";
import { AccountStorage, setNotForMe } from "../core/storage";
import { type ExternalTitle, metaLine, resized, titleId } from "../core/titles";
import { Tmdb } from "../core/tmdb";
import type { Item } from "../core/types";
import { Chip, Cover, Dropdown, Empty, Field, PageHeader, Shelf } from "./components";
import { relativeTime } from "./fmt";
import { Icon } from "./icons";
import { ui, useModel, useNavigate } from "./state";

/** The library For You uses right now (saved choice, else the one named Anime). */
export function useSourceId(model: AppModel) {
  return currentSourceId(sourcesOf(model.views), model.settings.forYouLibrary);
}

/** Picks for a library (Home's "Picked for you" row uses this too). */
export function useForYou(genre: string | null = null) {
  const model = useModel();
  const sourceId = useSourceId(model);
  const configured = model.tmdb.configured;
  useEffect(() => {
    const c = model.discoveryContext();
    if (c && configured && model.views.length) void model.discovery.ensureBuilt(c, sourceId);
  }, [model, sourceId, configured, model.views.length, model.storage?.loaded]); // eslint-disable-line react-hooks/exhaustive-deps
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
  const { sourceId, picks, building, status, error } = useForYou(genre);
  const [index, setIndex] = useState(0);
  const [handled, setHandled] = useState(0);
  const sources = sourcesOf(model.views);
  const source = sources.find((s) => s.id === sourceId);
  const configured = model.tmdb.configured;

  const rebuild = (g: string | null = null) => {
    const c = model.discoveryContext();
    if (c) void model.discovery.build(c, sourceId, g);
  };
  useEffect(() => { setIndex(0); setHandled(0); setGenre(null); }, [sourceId]);
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
  if (!configured) content = <TmdbKeySetup />;
  else if (!picks.length && building) content = <Building text={status ?? `Comparing what you finished on your server with what's out there${model.settings.useOnDeviceAI ? ", with on-device AI" : ""}.`} />;
  else if (!picks.length && error) content = <Empty icon="info" title="No picks right now" text={error}><button className="glass-button" onClick={() => rebuild()}><Icon name="refresh" size={15} /> Try again</button></Empty>;
  else if (!picks.length) content = <Empty icon="wand" title="No picks right now" text={genre ? `Nothing new in ${genre} right now.` : "Press Try again to look for picks."}><button className="glass-button" onClick={() => rebuild(genre)}><Icon name="refresh" size={15} /> Try again</button></Empty>;
  else {
    const safe = Math.min(index, picks.length - 1);
    const pick = picks[safe];
    content = (
      <>
        <PickCard key={titleId(pick.title)} pick={pick} position={safe + 1 + handled} total={picks.length + handled} noun={noun}
          onNext={() => setIndex(safe + 1 >= picks.length ? 0 : safe + 1)} onHandled={() => setHandled((h) => h + 1)} />
        {picks.length > 1 && (
          <Shelf title="More picks">
            {picks.map((p, i) => <TitleCard key={titleId(p.title)} t={p.title} match={p.match} highlighted={i === safe} onClick={() => setIndex(i)} />)}
            {building && <div className="shelf-spinner"><span className="spinner" /></div>}
          </Shelf>
        )}
        <p className="footnote center-text">{footer(model, sourceId, source?.name ?? "All")}</p>
      </>
    );
  }

  return (
    <div className="page">
      <PageHeader title="For You" subtitle={`New ${what} you don't have yet, picked from what you watch`}>
        <Dropdown label={source?.name ?? "All"} icon={sourceIcon(source)} items={libraryItems} onPick={(v) => model.updateSettings({ forYouLibrary: v })} />
        <Dropdown label={genre ?? "Any category"} icon="filter" items={categoryItems} onPick={(v) => pickGenre(v || null)} />
        <button className="round-button" title="Fresh picks (F5)" aria-label="Fresh picks" disabled={building} onClick={() => { setIndex(0); setHandled(0); rebuild(); }}><Icon name="refresh" size={16} /></button>
        <button className="round-button" title="My List" aria-label="My List" onClick={() => navigate({ kind: "myList" })}><Icon name="bookmark" size={16} /></button>
      </PageHeader>
      {content}
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

/** A poster for a title you don't have (opens its details). */
export function TitleCard({ t, match, onClick, width = 140, highlighted }: { t: ExternalTitle; match?: number; onClick?: () => void; width?: number; highlighted?: boolean }) {
  const open = onClick ?? (() => ui.openSheet({ kind: "tmdb", item: t }));
  return (
    <div className={`card ${highlighted ? "highlighted" : ""}`} style={{ width, ["--ar" as string]: "2 / 3" }}>
      <button className="card-cover" onClick={open} title={t.title}>
        <Cover url={resized(t.posterURL, "w342")} width={width} height={Math.round(width * 1.5)} radius={14} icon="film" />
        {match !== undefined && <div className="card-age"><span className="bubble bubble-match">{match}%</span></div>}
        <div className="card-status ext" title="Not on your server"><Icon name="cloud" size={13} /></div>
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
  const onList = !!model.storage?.hasTitle(t);
  const details = () => ui.openSheet({ kind: "tmdb", item: t });
  const meta = [metaLine(t), t.score ? `★ ${t.score.toFixed(1)}${t.voteCount ? ` (${t.voteCount.toLocaleString()})` : ""}` : null].filter(Boolean).join(" · ");
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
        <button className="glass-button" onClick={() => ui.openSheet({ kind: "why", item: { Id: titleId(t), Name: t.title, Type: t.source === "tmdbTV" ? "Series" : "Movie" }, because: pick.because, highlights: pick.highlights })}><Icon name="sparkles" size={16} /> Why would I like this?</button>
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
