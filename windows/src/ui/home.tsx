// Home (port of HomeView.swift): your picks, the best matches this season, what to start next
// from Planning, trending, hidden gems, outside your usual, surprise me, currently watching.

import { useCallback, useEffect, useMemo, useState } from "react";
import { AppModel } from "../core/model";
import { currentSeason, FEATURED_CATEGORIES, type Media } from "../core/models";
import { MediaCard, PageHeader, Shelf, Spinner } from "./components";
import { capitalized } from "./fmt";
import { Icon } from "./icons";
import { useModel } from "./state";

const shuffle = <T,>(a: T[]) => {
  const b = [...a];
  for (let i = b.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [b[i], b[j]] = [b[j], b[i]];
  }
  return b;
};
const randomInt = (lo: number, hi: number) => lo + Math.floor(Math.random() * (hi - lo + 1));

export function ProfileHeader() {
  const model = useModel();
  const v = model.viewer;
  if (!v) return null;
  const stats = model.listStats;
  return (
    <div className="profile-header panel">
      {v.avatar?.large ? <img className="avatar" src={v.avatar.large} alt="" /> : <div className="avatar" />}
      <div>
        <div className="profile-name">{v.name}</div>
        <div className="muted small">{model.showCount("COMPLETED")} seen · {model.showCount("PLANNING")} planned · {model.showCount("DROPPED")} dropped</div>
        <div className="muted small">{stats.meanScore !== undefined ? `Your average score ${stats.meanScore.toFixed(1)}/10` : "Rate shows to sharpen your picks"}</div>
      </div>
    </div>
  );
}

export function HomePage({ refreshKey }: { refreshKey: number }) {
  const model = useModel();
  const [trending, setTrending] = useState<Media[]>([]);
  const [season, setSeason] = useState<Media[]>([]);
  const [gems, setGems] = useState<Media[]>([]);
  const [outside, setOutside] = useState<Media[]>([]);
  const [outsideGenres, setOutsideGenres] = useState<string[]>([]);
  const [surprise, setSurprise] = useState<Media[]>([]);
  const notOnList = useCallback((items: Media[]) => items.filter((m) => !model.entry(m.id)), [model]);

  const loadSurprise = useCallback(async () => {
    try {
      const items = await model.browse({ sort: ["SCORE_DESC"], minScore: 70, minPopularity: 15_000, firstSeasonsOnly: true, page: randomInt(1, 30), perPage: 25 });
      setSurprise(shuffle(notOnList(items)));
    } catch { /* keep what's there */ }
  }, [model, notOnList]);

  useEffect(() => {
    let live = true;
    (async () => {
      const cur = currentSeason();
      const [seasonal, hot] = await Promise.allSettled([
        model.browse({ sort: ["POPULARITY_DESC"], season: cur.season, seasonYear: cur.year, firstSeasonsOnly: true, perPage: 50 }),
        model.browse({ sort: ["TRENDING_DESC", "POPULARITY_DESC"], firstSeasonsOnly: true, perPage: 20 }),
      ]);
      if (!live) return;
      if (seasonal.status === "fulfilled") setSeason(seasonal.value);
      if (hot.status === "fulfilled") setTrending(hot.value.filter((m) => !model.entry(m.id)));
      // Hidden gems, a couple of genres you rarely watch, and a random well-rated mix.
      const usual = usualGenres(model);
      const all = model.allCategories.filter((c) => c.kind === "genre").map((c) => c.name);
      const pool = (all.length ? all : FEATURED_CATEGORIES.filter((c) => c.kind === "genre").map((c) => c.name))
        .filter((g) => !usual.includes(g) && g !== "Hentai");
      const picked = shuffle(pool).slice(0, 2);
      const [g, o] = await Promise.allSettled([
        model.browse({ sort: ["SCORE_DESC"], minScore: 78, maxPopularity: 45_000, minPopularity: 4_000, firstSeasonsOnly: true, page: randomInt(1, 3), perPage: 25 }),
        model.browse({ sort: ["SCORE_DESC", "POPULARITY_DESC"], genres: picked.length ? picked : undefined, excludeGenres: usual.length ? usual.slice(0, 3) : undefined,
          minScore: 72, minPopularity: 8_000, firstSeasonsOnly: true, perPage: 25 }),
      ]);
      if (!live) return;
      if (g.status === "fulfilled") setGems(shuffle(notOnList(g.value)));
      if (o.status === "fulfilled") { setOutside(notOnList(o.value)); setOutsideGenres(picked); }
      await loadSurprise();
    })();
    return () => { live = false; };
    // Re-runs on refresh (F5).
  }, [model, refreshKey, loadSurprise, notOnList]);

  useEffect(() => {
    if (model.entries.length) void model.generateRecommendations();
  }, [model, model.entries.length]);

  const picks = model.picks(null);
  const cur = currentSeason();
  const best = useMemo(() => season
    .filter((m) => !model.entry(m.id))
    .map((m) => [m, model.matcher.match(m)] as const)
    .filter((x): x is readonly [Media, number] => x[1] !== undefined)
    .sort((a, b) => b[1] - a[1]).slice(0, 15).map((x) => x[0]),
  // eslint-disable-next-line react-hooks/exhaustive-deps
  [season, model.version]);
  const planning = model.shows(["PLANNING"]).map((r) => r.entry.media)
    .map((m) => [m, model.matcher.match(m) ?? 0] as const).sort((a, b) => b[1] - a[1]).slice(0, 15).map((x) => x[0]);
  const watching = model.shows(["CURRENT", "REPEATING"]).map((r) => r.entry).sort((a, b) => (b.updatedAt ?? 0) - (a.updatedAt ?? 0)).map((e) => e.media);

  const suggestions = (items: Media[]) => items.filter((m) => !model.entry(m.id) && !model.settings.dismissedPicks.has(m.id)
    && !(model.settings.hideChinese && m.countryOfOrigin === "CN"));

  return (
    <div className="page">
      <PageHeader title="Home" />
      <ProfileHeader />
      {(picks.length > 0 || model.isLoadingFeed(null)) && (
        <Shelf title="Picked for you" icon="wand" action={{ label: "See all", run: () => { model.selectedTab = "forYou"; model.notify(); } }}>
          {picks.length ? suggestions(picks.slice(0, 20).map((p) => p.media)).map((m) => <MediaCard key={m.id} media={m} width={176} />)
            : <Spinner label="Hoshi is picking shows for you…" />}
        </Shelf>
      )}
      {suggestions(best).length > 0 && (
        <Shelf title={`Best matches · ${capitalized(cur.season)} ${cur.year}`} icon="sparkles">
          {suggestions(best).map((m) => <MediaCard key={m.id} media={m} />)}
        </Shelf>
      )}
      {planning.length > 0 && (
        <Shelf title="Start next · best fit from Planning" action={{ label: "All", run: () => { model.selectedTab = "lists"; model.notify(); } }}>
          {planning.map((m) => <MediaCard key={m.id} media={m} />)}
        </Shelf>
      )}
      {suggestions(trending).length > 0 && <Shelf title="Trending now" icon="flame">{suggestions(trending).map((m) => <MediaCard key={m.id} media={m} />)}</Shelf>}
      {suggestions(gems).length > 0 && <Shelf title="Hidden gems" icon="diamond">{suggestions(gems).map((m) => <MediaCard key={m.id} media={m} />)}</Shelf>}
      {suggestions(outside).length > 0 && (
        <Shelf title={`Outside your usual · ${outsideGenres.join(" & ")}`} icon="compass">{suggestions(outside).map((m) => <MediaCard key={m.id} media={m} />)}</Shelf>
      )}
      {suggestions(surprise).length > 0 && (
        <Shelf title="Surprise me" icon="dice" action={{ label: "Shuffle", run: () => void loadSurprise() }}>
          {suggestions(surprise).map((m) => <MediaCard key={m.id} media={m} />)}
        </Shelf>
      )}
      {watching.length > 0 && <Shelf title="Currently watching" icon="play">{watching.map((m) => <MediaCard key={m.id} media={m} />)}</Shelf>}
      {!model.entries.length && model.listLoadedOnce && !model.isLoadingList && (
        <p className="muted pad">Add a few shows you liked (Discover → search), and Home fills up with suggestions.</p>
      )}
      {!model.entries.length && (model.isLoadingList || !model.listLoadedOnce) && <Spinner label="Loading your list…" />}
      <p className="footnote pad"><Icon name="refresh" size={13} /> Press F5 to refresh.</p>
    </div>
  );
}

function usualGenres(model: AppModel): string[] {
  const counts = new Map<string, number>();
  for (const e of model.entries) {
    if (e.status === "DROPPED") continue;
    for (const g of e.media.genres ?? []) counts.set(g, (counts.get(g) ?? 0) + 1);
  }
  return [...counts].sort((a, b) => b[1] - a[1]).slice(0, 4).map((x) => x[0]);
}
