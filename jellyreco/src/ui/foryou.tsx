// For You (AniReco's tab, for your Jellyfin library): one personal pick at a time from what's on
// your server and you haven't watched. First dropdown: which library (Anime by default, or All);
// second: a category (genre) within it.

import { useEffect, useState } from "react";
import type { AppModel } from "../core/model";
import { saveSet } from "../core/model";
import { defaultLibrary, type Feed, loadLibrary, type Pick, recommend } from "../core/recommender";
import { backdropUrl, cardImage, Chip, Cover, Dropdown, Empty, ItemCard, PageHeader, Rating, Shelf, Spinner } from "./components";
import { itemSubtitle, relativeTime, runtime } from "./fmt";
import { Icon } from "./icons";
import { routeFor, ui, useModel, useNavigate } from "./state";

const LIBRARY_TTL = 10 * 60_000;
const loading = new Map<string, Promise<void>>();

function feedKey(lib: string, cat: string) { return `${lib}|${cat}`; }

export function currentLibraryChoice(model: AppModel): string {
  const lib = model.forYouLibrary;
  const chosen = model.settings.forYouLibrary;
  if (chosen === "all") return "all";
  if (chosen && lib?.libraries.some((l) => l.id === chosen)) return chosen;
  return lib ? defaultLibrary(lib) : "";
}

async function ensureLibrary(model: AppModel, force = false) {
  const api = model.api;
  if (!api) return;
  if (!force && model.forYouLibrary && Date.now() - model.forYouLibrary.loadedAt < LIBRARY_TTL) return;
  model.forYouLibrary = await loadLibrary(api, model.views);
  model.feeds.clear();
}

/** Builds (or extends, with `more`) the feed for a library and category. */
export function buildFeed(model: AppModel, libraryId: string, category: string, opts: { force?: boolean; more?: boolean } = {}): Promise<void> {
  const key = feedKey(libraryId, category) + (opts.more ? "+" : "");
  const running = loading.get(key);
  if (running) return running;
  const job = (async () => {
    try {
      await ensureLibrary(model, opts.force);
      const lib = model.forYouLibrary!;
      const lid = libraryId || defaultLibrary(lib);
      const k = feedKey(lid, category);
      const existing = model.feeds.get(k);
      if (existing && !opts.force && !opts.more) return;
      const exclude = new Set(opts.more && existing ? existing.picks.map((p) => p.item.Id) : []);
      const round = opts.more && existing ? Math.floor(existing.picks.length / 40) + 1 : 1;
      const feed = await recommend(model.api!, lib, {
        libraryId: lid, category, minRating: model.settings.forYouMinRating, dismissed: model.dismissed,
        useAI: model.settings.useOnDeviceAI && !powerSaver.on, exclude,
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

/** Set from main.tsx: battery saver pauses the on-device AI. */
export const powerSaver = { on: false };

/** The feed for the current dropdown choices (used by Home's "Picked for you" too). */
export function useForYouFeed() {
  const model = useModel();
  const libId = currentLibraryChoice(model);
  const cat = model.settings.forYouCategory;
  const key = feedKey(libId, cat);
  useEffect(() => { void buildFeed(model, libId, cat); }, [model, key, model.views.length]); // eslint-disable-line react-hooks/exhaustive-deps
  return { feed: model.feeds.get(key), loading: [...loading.keys()].some((k) => k.startsWith(key) || k.startsWith(feedKey("", cat))) };
}

export function dismiss(model: AppModel, id: string) {
  model.dismissed.add(id);
  saveSet(`dismissed-${model.server?.id}-${model.user?.Id}`, model.dismissed);
  removeFromFeeds(model, id);
}

export function removeFromFeeds(model: AppModel, id: string) {
  for (const [k, f] of model.feeds) model.feeds.set(k, { ...f, picks: f.picks.filter((p) => p.item.Id !== id) });
  model.notify();
}

export function ForYouPage({ refreshKey }: { refreshKey: number }) {
  const model = useModel();
  const navigate = useNavigate();
  const { feed, loading: busy } = useForYouFeed();
  const [index, setIndex] = useState(0);
  const lib = model.forYouLibrary;
  const libId = currentLibraryChoice(model);
  const cat = model.settings.forYouCategory;

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

  const libraryName = libId === "all" ? "All libraries" : lib?.libraries.find((l) => l.id === libId)?.name ?? "Library";
  const libraryItems = [
    { value: "all", label: "All libraries", selected: libId === "all", icon: "grid" },
    "divider" as const,
    ...(lib?.libraries ?? []).map((l) => ({ value: l.id, label: l.name, detail: `${l.count} titles`, selected: l.id === libId })),
  ];
  const categories = feed?.categories ?? [];
  const categoryItems = [
    { value: "", label: "All categories", selected: !cat, icon: "grid" },
    "divider" as const,
    ...categories.map((c) => ({ value: c.name, label: c.name, detail: `${c.count} to discover`, selected: c.name === cat })),
  ];

  const next = () => setIndex((i) => (i >= picks.length - 1 ? 0 : i + 1));

  let content;
  if (!lib && busy) content = <Building text="Reading your library and watch history…" />;
  else if (busy && !picks.length) content = <Building text={cat ? `Finding ${cat} picks in ${libraryName}…` : `Finding picks in ${libraryName}…`} />;
  else if (!picks.length) {
    content = (
      <Empty icon="wand" title="No picks right now" text={cat ? `Nothing new in ${cat} here. Try another category.` : feed && feed.watchedCount < 3 ? "Watch or favorite a few titles first. Picks come from your watch history." : "You've seen everything here. Try another library."} />
    );
  } else {
    const safe = Math.min(index, picks.length - 1);
    const shown = picks[safe];
    content = (
      <>
        <PickCard key={shown.item.Id} pick={shown} position={safe + 1} total={picks.length} moreComing={!feed?.exhausted} onNext={next}
          onDismiss={() => dismiss(model, shown.item.Id)} onHandled={() => removeFromFeeds(model, shown.item.Id)} />
        {picks.length > 1 && (
          <Shelf title="More picks">
            {picks.map((p, i) => <ItemCard key={p.item.Id} item={p.item} width={140} onClick={() => setIndex(i)} badge={<span className="bubble bubble-match">{p.match}%</span>} />)}
            {busy && <div className="shelf-spinner"><span className="spinner" /></div>}
          </Shelf>
        )}
        {feed && <p className="footnote center-text">{footer(feed)}</p>}
      </>
    );
  }

  return (
    <div className="page">
      <PageHeader title="For You">
        <Dropdown label={libraryName} icon={libId === "all" ? "grid" : "folder"} items={libraryItems}
          onPick={(v) => model.updateSettings({ forYouLibrary: v, forYouCategory: "" })} />
        <Dropdown label={cat || "All categories"} icon="tag" items={categoryItems} onPick={(v) => model.updateSettings({ forYouCategory: v })} />
        <button className="round-button" title="Fresh picks (F5)" onClick={() => void buildFeed(model, libId, cat, { force: true })}><Icon name="refresh" size={16} /></button>
      </PageHeader>
      {content}
      <button className="text-button small" onClick={() => navigate({ kind: "browse", title: "Not for me", query: { ids: [...model.dismissed].slice(-200), dismissed: true } })}>
        <Icon name="thumbsDown" size={14} /> Shows you marked "Not for me"
      </button>
    </div>
  );
}

function Building({ text }: { text: string }) {
  const model = useModel();
  return (
    <div className="building">
      <span className="spinner" />
      <h3>{text}</h3>
      <p className="muted">{model.settings.useOnDeviceAI ? "Comparing what you've watched with on-device AI. This only runs when your history changes." : "Comparing what you've watched with the rest of your library."}</p>
    </div>
  );
}

function footer(feed: Feed) {
  const engine = feed.usedAI ? "your watch history, similar titles and on-device AI" : "your watch history and similar titles";
  return `Built ${relativeTime(feed.generatedAt)} from ${engine} (${feed.watchedCount} titles).` + (feed.exhausted ? " That's everything for now." : " More picks load as you go. F5 builds fresh picks.");
}

function PickCard({ pick, position, total, moreComing, onNext, onDismiss, onHandled }: {
  pick: Pick; position: number; total: number; moreComing: boolean; onNext: () => void; onDismiss: () => void; onHandled: () => void;
}) {
  const model = useModel();
  const navigate = useNavigate();
  const api = model.api!;
  const i = pick.item;
  const back = backdropUrl(api, i, 1600);
  const meta = [itemSubtitle(i), i.Type === "Series" ? (i.RecursiveItemCount ? `${i.RecursiveItemCount} episodes` : null) : runtime(i.RunTimeTicks), i.OfficialRating].filter(Boolean).join(" · ");
  const open = () => navigate(routeFor(i));

  return (
    <article className="pick panel" style={back ? { backgroundImage: `linear-gradient(90deg, var(--pick-fade) 35%, transparent), url("${back}")` } : undefined}>
      <div className="pick-cover" onClick={open} onContextMenu={(e) => { e.preventDefault(); ui.showMenu({ x: e.clientX, y: e.clientY, item: i }); }}>
        <Cover url={cardImage(api, i, "poster", 230)} width={230} height={345} radius={16} icon="film" />
      </div>
      <div className="pick-body">
        <div className="muted small">{moreComing ? `Pick ${position}` : `Pick ${position} of ${total}`}</div>
        <h2>{i.Name}</h2>
        <div className="pick-match">{pick.match}% match</div>
        <div className="muted small">{meta}</div>
        <Rating value={i.CommunityRating} />
        {pick.because.length > 0 && <div className="because"><Icon name="heart" size={16} /> Because you watched <strong>{pick.because.join(", ")}</strong></div>}
        {pick.highlights.length > 0 && <div className="chips-wrap">{pick.highlights.map((h) => <Chip key={h} text={h} />)}</div>}
        <p className="pick-synopsis clamp-6">{i.Overview}</p>
        <button className="glass-button" onClick={() => ui.openSheet({ kind: "why", item: i, because: pick.because, highlights: pick.highlights })}><Icon name="sparkles" size={16} /> Why would I like this?</button>
        <div className="pick-actions">
          <button className="glass-button prominent" onClick={() => void model.player?.playItem(i, { resume: true })}><Icon name="playFill" size={16} /> Play</button>
          <button className="glass-button" onClick={async () => { await model.toggleFavorite(i); onHandled(); }}><Icon name="bookmark" size={16} /> Watch later</button>
          <button className="glass-button" onClick={open}><Icon name="info" size={16} /> Details</button>
          <button className="glass-button danger" onClick={onDismiss}><Icon name="thumbsDown" size={16} /> Not for me</button>
          <button className="glass-button" onClick={async () => { await model.togglePlayed(i); onHandled(); }}><Icon name="eye" size={16} /> Already watched</button>
          <button className="glass-button" onClick={() => navigate({ kind: "browse", title: `More like ${i.Name}`, query: { similarTo: i.Id } })}><Icon name="layers" size={16} /> More like this</button>
          <button className="glass-button" onClick={onNext}><Icon name="shuffle" size={16} /> Another pick</button>
        </div>
      </div>
    </article>
  );
}

export function WhyText({ because, highlights, name }: { because: string[]; highlights: string[]; name: string }) {
  const parts: string[] = [];
  if (because.length) parts.push(`${name} is close to ${because.slice(0, 2).join(" and ")}, which you watched${because.length > 2 ? ` (and ${because.length - 2} more)` : ""}.`);
  if (highlights.length) parts.push(`It shares what you keep coming back to: ${highlights.join(", ")}.`);
  if (!parts.length) parts.push(`It fits the overall shape of what you watch, by genre, studio and story.`);
  return <p>{parts.join(" ")}</p>;
}

export { Spinner };
