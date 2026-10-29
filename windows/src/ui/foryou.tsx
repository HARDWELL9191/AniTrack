// For You (port of ForYouView.swift): one personal pick at a time; the feed digs deeper near the end.

import { useEffect, useState } from "react";
import { AnimeCategory, coverURL, displayTitle, formatLabel, plainDescription, seasonLabel } from "../core/models";
import { AppModel } from "../core/model";
import { Recommendation, RecommendationResult } from "../core/recommender";
import { AgeBadge, Chip, Cover, Empty, MediaCard, PageHeader, ScoreBadge, Shelf, Spinner } from "./components";
import { CategoryMenu } from "./discover";
import { hexColor, relativeTime } from "./fmt";
import { Icon } from "./icons";
import { ui, useModel, useOpenDetail } from "./state";

export function ForYouPage({ refreshKey }: { refreshKey: number }) {
  const model = useModel();
  const [category, setCategory] = useState<AnimeCategory | null>(null);
  const [index, setIndex] = useState(0);
  const [handled, setHandled] = useState(0);
  const feed = model.feed(category);
  const picks = model.picks(category);

  useEffect(() => { setIndex(0); setHandled(0); }, [category]);

  useEffect(() => {
    void (async () => {
      if (!model.entries.length && model.listLoadedOnce && !model.isLoadingList) await model.refreshList();
      await model.generateRecommendations(category);
    })();
  }, [model, category, model.entries.length === 0]); // eslint-disable-line react-hooks/exhaustive-deps

  // F5: fresh picks (the iPhone's pull to refresh).
  const [lastRefresh, setLastRefresh] = useState(refreshKey);
  useEffect(() => {
    if (refreshKey === lastRefresh) return;
    setLastRefresh(refreshKey);
    setIndex(0);
    setHandled(0);
    void model.generateRecommendations(category, true);
  }, [refreshKey, lastRefresh, model, category]);

  const preload = (position: number) => {
    if (feed && !feed.exhausted && position >= picks.length - 5) void model.loadMorePicks(category);
  };
  useEffect(() => preload(index), [index, picks.length, feed?.exhausted]); // eslint-disable-line react-hooks/exhaustive-deps

  const next = (current: number) => {
    const isLast = current >= picks.length - 1;
    if (isLast && model.isLoadingMore(category)) return;
    if (isLast && (feed?.exhausted ?? true)) { setIndex(0); setHandled(0); }
    else setIndex(Math.min(current + 1, picks.length - 1));
  };

  let content;
  if (!picks.length && !model.entries.length && !model.listLoadedOnce) content = <Spinner label="Loading your list…" />;
  else if (model.isLoadingFeed(category) && !picks.length) {
    content = (
      <div className="building">
        <span className="spinner" />
        <h3>{category ? `Finding ${category.name} picks for you…` : "Hoshi is reading your list…"}</h3>
        <p className="muted">{model.settings.useOnDeviceAI ? "Comparing your favorites with on-device AI. This only runs when your list changes." : "Comparing your favorites with what fans recommend."}</p>
      </div>
    );
  } else if (model.recommendationError(category) && !picks.length) content = <Empty icon="info" title="Couldn't build picks" text={model.recommendationError(category)} />;
  else if (!picks.length) content = <Empty icon="wand" title="No picks yet" text={category ? `Nothing new in ${category.name} right now. Try another category.` : "Rate a few shows on your list, then press F5."} />;
  else {
    const safe = Math.min(index, picks.length - 1);
    const shown = picks[safe];
    content = (
      <>
        <PickCard key={shown.id} rec={shown} position={safe + 1 + handled} total={picks.length + handled} moreComing={!(feed?.exhausted ?? true)}
          onNext={() => next(safe)}
          onDismiss={() => { setHandled((h) => h + 1); model.dismissPick(shown.id, shown.media); preload(safe); }}
          onHandled={() => { setHandled((h) => h + 1); preload(safe); }} />
        {picks.length > 1 && (
          <Shelf title="More picks">
            {picks.map((p, i) => <MediaCard key={p.id} media={p.media} width={128} onClick={() => setIndex(i)} />)}
            {model.isLoadingMore(category) && <div className="shelf-spinner"><span className="spinner" /></div>}
          </Shelf>
        )}
        {feed && <p className="footnote center-text">{footer(feed)}</p>}
      </>
    );
  }

  return (
    <div className="page">
      <PageHeader title="For You"><CategoryMenu selected={category} onPick={setCategory} showAny /></PageHeader>
      {content}
    </div>
  );
}

function footer(feed: RecommendationResult) {
  const engine = feed.usedOnDeviceAI ? "fan recommendations, your tags and on-device AI" : "fan recommendations and your tags";
  return `Built ${relativeTime(feed.generatedAt)} from ${engine}.` + (feed.exhausted
    ? " You've seen everything for now. Rate more shows for new picks." : " More picks load automatically as you go. F5 builds fresh picks.");
}

function PickCard({ rec, position, total, moreComing, onNext, onDismiss, onHandled }: {
  rec: Recommendation; position: number; total: number; moreComing: boolean; onNext: () => void; onDismiss: () => void; onHandled: () => void;
}) {
  const model = useModel();
  const open = useOpenDetail();
  const [adding, setAdding] = useState(false);
  const m = rec.media;
  const meta = [formatLabel(m), m.episodes ? `${m.episodes} eps` : null, seasonLabel(m)].filter(Boolean).join(" · ");
  const tint = hexColor(m.coverImage?.color) ?? "#3d99ff";

  const plan = async () => {
    setAdding(true);
    const ok = await model.planToWatch(m);
    setAdding(false);
    if (ok) { model.removeFromFeeds(rec.id); onHandled(); }
  };

  return (
    <article className="pick panel" style={{ "--show-tint": tint } as React.CSSProperties}>
      <div className="pick-cover" onClick={() => open(m.id)} onContextMenu={(e) => { e.preventDefault(); ui.showMenu({ x: e.clientX, y: e.clientY, media: m }); }}>
        <Cover url={coverURL(m)} color={m.coverImage?.color} width={230} height={330} radius={16} />
        <div className="card-age"><AgeBadge media={m} /></div>
      </div>
      <div className="pick-body">
        <div className="muted small">{moreComing ? `Pick ${position}` : `Pick ${position} of ${total}`}</div>
        <h2>{displayTitle(m, model.settings.titleLanguage)}</h2>
        <div className="pick-match">{model.matcher.match(m) ?? rec.match}% match</div>
        <div className="muted small">{meta}</div>
        <ScoreBadge score={m.averageScore} />
        {rec.because.length > 0 && (
          <div className="because"><Icon name="heart" size={16} /> Because you liked <strong>{rec.because.join(", ")}</strong></div>
        )}
        {rec.sharedHighlights.length > 0 && <div className="chips-wrap">{rec.sharedHighlights.map((h) => <Chip key={h} text={h} />)}</div>}
        <p className="pick-synopsis clamp-6">{plainDescription(m)}</p>
        <button className="glass-button" onClick={() => ui.openSheet({ kind: "why", media: m })}><Icon name="sparkles" size={16} /> Why would I like this?</button>
        <div className="pick-actions">
          {model.canEdit && !model.entry(rec.id) && (
            <button className="glass-button prominent" disabled={adding} onClick={plan}><Icon name="bookmark" size={16} /> Plan to watch</button>
          )}
          <button className="glass-button" onClick={() => open(m.id)}><Icon name="info" size={16} /> Details</button>
          <button className="glass-button danger" onClick={onDismiss}><Icon name="thumbsDown" size={16} /> Not for me</button>
          {model.canEdit && (
            <button className="glass-button" onClick={async () => { if (await model.markCompleted(m)) onHandled(); }}><Icon name="eye" size={16} /> Already watched</button>
          )}
          <button className="glass-button" onClick={() => ui.openSheet({ kind: "moreLikeThis", media: m })}><Icon name="layers" size={16} /> More like this</button>
          <button className="glass-button" onClick={onNext}><Icon name="shuffle" size={16} /> Another pick</button>
        </div>
      </div>
    </article>
  );
}

export type { AppModel };
