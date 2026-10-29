// Details page (port of MediaDetailView.swift + EpisodesSection.swift), laid out for a wide window.

import { useEffect, useState } from "react";
import { openUrl } from "@tauri-apps/plugin-opener";
import { isCancellation } from "../core/anilist";
import { EpisodePage, EpisodeService } from "../core/kitsu";
import {
  coverURL, displayTitle, EntryLite, formatLabel, isLaterSeason, isMovie, Media, MediaDetail, plainDescription, relationLabel,
  scoreValue, seasonLabel, Seasons, statusIcon, statusLabel, statusName,
} from "../core/models";
import { SeasonChain, SeasonRoots } from "../core/seasons";
import { AgeBadge, AgeLine, Chip, Cover, Dropdown, Empty, MatchBadge, MediaCard, ScoreBadge, Shelf, Spinner } from "./components";
import { EntryEditor } from "./sheets";
import { airing, hexColor, myScore, outOfTen } from "./fmt";
import { Icon } from "./icons";
import { useModel, useOpenDetail } from "./state";

export function DetailPage({ id }: { id: number }) {
  const model = useModel();
  const [detail, setDetail] = useState<MediaDetail | undefined>(() => model.cachedDetail(id));
  const [error, setError] = useState<string | null>(null);
  const [recs, setRecs] = useState<Media[]>([]);
  const [editing, setEditing] = useState(false);

  useEffect(() => {
    let live = true;
    setError(null);
    setDetail(model.cachedDetail(id));
    setRecs([]);
    (async () => {
      try {
        const loaded = await model.detail(id);
        if (!live) return;
        setDetail(loaded);
        const raw = (loaded.recommendations?.nodes ?? []).map((n) => n.mediaRecommendation).filter((m): m is Media => !!m);
        const collapsed = await SeasonRoots.collapse(raw, model.client);
        if (live) setRecs(collapsed);
      } catch (e) {
        if (live && !isCancellation(e)) setError((e as Error).message);
      }
    })();
    return () => { live = false; };
  }, [id, model]);

  if (!detail) return error ? <Empty icon="info" title="Couldn't load" text={error} /> : <Spinner />;
  const media = detail;
  const entry = model.entry(media.id);
  // The entry AniList sent with the page, unless it's a "Not for me" marker or you removed it since.
  const lite: EntryLite | null = detail.mediaListEntry && !model.isNotForMeEntry(detail.mediaListEntry) && !model.deletedEntryIds.has(detail.mediaListEntry.id)
    ? detail.mediaListEntry : null;
  const status = entry?.status ?? lite?.status ?? null;
  const score = entry ? scoreValue(entry) : scoreValue(lite ?? {});
  const lang = model.settings.titleLanguage;
  const accent = hexColor(media.coverImage?.color);

  const related = (media.relations?.edges ?? []).filter((e) => {
    const node = e.node;
    if (!node || node.type !== "ANIME") return false;
    const isSeasonLink = (e.relationType === "PREQUEL" || e.relationType === "SEQUEL")
      && Seasons.isSeason(node.format, node.episodes) && Seasons.sameShow(media.title, node.title);
    return !isSeasonLink;
  });

  const moreLikeThis = recs
    .filter((m) => m.id !== media.id && m.isAdult !== true && !isMovie(m) && !isLaterSeason(m))
    .filter((m) => !(model.settings.hideChinese && m.countryOfOrigin === "CN"))
    .filter((m) => !model.entry(m.id) && !model.franchises.contains(m) && !model.settings.dismissedPicks.has(m.id))
    .sort((a, b) => (model.matcher.match(b) ?? 0) - (model.matcher.match(a) ?? 0));

  return (
    <div className="detail" style={accent ? ({ "--show-tint": accent } as React.CSSProperties) : undefined}>
      <div className="detail-banner" style={media.bannerImage ? { backgroundImage: `url("${media.bannerImage}")` } : undefined} />
      <div className="detail-top">
        <div className="detail-cover">
          <Cover url={coverURL(media)} color={media.coverImage?.color} width={210} height={300} radius={14} />
          <div className="card-age"><AgeBadge media={media} /></div>
        </div>
        <div className="detail-heading">
          <h1>{displayTitle(media, lang)}</h1>
          {media.title.native && lang !== "native" && <div className="muted">{media.title.native}</div>}
          <div className="detail-badges">
            <ScoreBadge score={media.averageScore} />
            <MatchBadge media={media} word />
            <AgeLine media={media} />
          </div>
          <div className="detail-actions">
            {model.canEdit ? (
              <button className="glass-button prominent big" onClick={() => setEditing(true)}>
                <Icon name={status ? statusIcon[status] : "plus"} size={18} />
                {status ? statusName[status] : "Add to list"}
              </button>
            ) : status ? (
              <span className="status-label"><Icon name={statusIcon[status]} size={18} />{statusName[status]}</span>
            ) : null}
            {media.siteUrl && (
              <button className="glass-button big" onClick={() => void openUrl(media.siteUrl!)}>
                <Icon name="external" size={17} /> Open on AniList
              </button>
            )}
          </div>
          <div className="detail-meta">
            {score > 0 && <span>Your score ★ {myScore(score)}</span>}
            {airing(media.nextAiringEpisode) && <span><Icon name="clock" size={15} /> {airing(media.nextAiringEpisode)}</span>}
          </div>
        </div>
      </div>

      <div className="detail-columns">
        <div className="detail-main">
          <InfoGrid media={media} studio={detail.studios?.nodes?.[0]?.name} />
          {!!media.genres?.length && <div className="chips-wrap">{media.genres.map((g) => <Chip key={g} text={g} />)}</div>}
          <Synopsis text={plainDescription(media)} />
          <Episodes media={media} />
        </div>
        <aside className="detail-side">
          <Tags media={media} />
        </aside>
      </div>

      {related.length > 0 && (
        <Shelf title="Related">
          {related.map((e) => <RelatedCard key={e.node!.id} edge={e} />)}
        </Shelf>
      )}
      {moreLikeThis.length > 0 && (
        <Shelf title="More like this · best match first">
          {moreLikeThis.map((m) => <MediaCard key={m.id} media={m} />)}
        </Shelf>
      )}
      {editing && <EntryEditor media={media} lite={lite} onClose={() => setEditing(false)} />}
    </div>
  );
}

function RelatedCard({ edge }: { edge: NonNullable<MediaDetail["relations"]>["edges"] extends (infer E)[] | null | undefined ? E : never }) {
  const open = useOpenDetail();
  const node = edge.node!;
  return (
    <button className="card related" style={{ width: 130 }} onClick={() => open(node.id)}>
      <Cover url={node.coverImage?.large ?? undefined} color={node.coverImage?.color} width={130} height={188} radius={11} />
      <div className="related-kind">{relationLabel(edge)}</div>
      <div className="card-title">{node.title?.english ?? node.title?.romaji ?? node.title?.userPreferred ?? ""}</div>
    </button>
  );
}

function InfoGrid({ media, studio }: { media: Media; studio?: string }) {
  const rows: [string, string][] = [
    ["Format", formatLabel(media)],
    ["Episodes", media.episodes ? String(media.episodes) : "?"],
    ["Length", media.duration ? `${media.duration} min` : "?"],
    ["Status", statusLabel(media)],
    ["Season", seasonLabel(media) ?? "?"],
    ["Studio", studio ?? "?"],
    ["Popularity", media.popularity ? media.popularity.toLocaleString() : "?"],
    ["Mean score", media.meanScore ? outOfTen(media.meanScore) : "?"],
  ];
  return (
    <div className="info-grid">
      {rows.map(([k, v]) => <div key={k}><span>{k}</span><strong>{v}</strong></div>)}
    </div>
  );
}

function Synopsis({ text }: { text: string }) {
  const [expanded, setExpanded] = useState(false);
  return (
    <section className="synopsis">
      <h3>Synopsis</h3>
      <p className={expanded ? "" : "clamp-6"}>{text}</p>
      <button className="link-button" onClick={() => setExpanded(!expanded)}>{expanded ? "Show less" : "Read more"}</button>
    </section>
  );
}

function Tags({ media }: { media: Media }) {
  const [spoilers, setSpoilers] = useState(false);
  const all = [...(media.tags ?? [])].sort((a, b) => (b.rank ?? 0) - (a.rank ?? 0));
  if (!all.length) return null;
  const visible = all.filter((t) => spoilers || t.isMediaSpoiler !== true).slice(0, 18);
  return (
    <section className="tags">
      <div className="section-head">
        <h3>Tags</h3>
        {all.some((t) => t.isMediaSpoiler) && <button className="link-button small" onClick={() => setSpoilers(!spoilers)}>{spoilers ? "Hide spoilers" : "Show spoilers"}</button>}
      </div>
      <div className="chips-wrap">
        {visible.map((t) => <Chip key={t.name} text={`${t.name} ${t.rank ?? 0}%`} tone={t.isMediaSpoiler ? "danger" : "muted"} />)}
      </div>
    </section>
  );
}

// MARK: Episodes

function Episodes({ media }: { media: Media }) {
  const model = useModel();
  const [seasons, setSeasons] = useState<Media[]>([media]);
  const [selectedId, setSelectedId] = useState(media.id);
  const [page, setPage] = useState<EpisodePage | null>(null);
  const [loading, setLoading] = useState(false);
  const [loadingMore, setLoadingMore] = useState(false);
  const [shown, setShown] = useState(20);
  const [expanded, setExpanded] = useState<Set<number>>(new Set());
  const applies = media.format !== "MOVIE" && media.format !== "MUSIC" && media.episodes !== 1;
  const selected = seasons.find((s) => s.id === selectedId) ?? media;

  useEffect(() => {
    setSeasons([media]);
    setSelectedId(media.id);
    if (!applies) return;
    let live = true;
    void SeasonChain.seasons(media, model.client).then((chain) => { if (live && chain.length > 1) setSeasons(chain); });
    return () => { live = false; };
  }, [media, model, applies]);

  useEffect(() => {
    if (!applies) return;
    let live = true;
    setShown(20);
    setExpanded(new Set());
    setLoading(true);
    (async () => {
      const season = seasons.find((s) => s.id === selectedId) ?? media;
      const saved = await EpisodeService.saved(season.id);
      if (!live) return;
      if (saved) {
        setPage(saved);
        if (!EpisodeService.isStale(saved)) { setLoading(false); return; }
      } else setPage(null);
      const fresh = await EpisodeService.firstPage(season, model.client);
      if (live) { setPage(fresh); setLoading(false); }
    })();
    return () => { live = false; };
  }, [selectedId, applies, model, media, seasons]);

  if (!applies) return null;
  const index = Math.max(0, seasons.findIndex((s) => s.id === selectedId));
  const hasThumbs = !!page?.episodes.some((e) => e.thumbnail);

  const showMore = async () => {
    setLoadingMore(true);
    const updated = await EpisodeService.loadMore(selectedId);
    if (updated) setPage(updated);
    setShown((n) => n + 20);
    setLoadingMore(false);
  };

  return (
    <section className="episodes">
      <div className="section-head">
        <h3>Episodes</h3>
        {seasons.length > 1 && (
          <Dropdown label={`Season ${index + 1}`} onPick={(id: number) => setSelectedId(id)}
            items={seasons.map((s, i) => ({
              value: s.id, label: `Season ${i + 1}`, selected: s.id === selectedId,
              detail: [displayTitle(s, model.settings.titleLanguage), s.seasonYear, s.episodes ? `${s.episodes} eps` : null].filter(Boolean).join(" · "),
            }))} />
        )}
      </div>
      {page && page.total > 0 ? (
        <>
          <div className={hasThumbs ? "episode-list" : "episode-list compact"}>
            {page.episodes.slice(0, shown).map((ep) => (
              <button key={ep.number} className={`episode ${expanded.has(ep.number) ? "open" : ""}`} onClick={() => {
                if (!ep.description) return;
                const s = new Set(expanded);
                if (s.has(ep.number)) s.delete(ep.number); else s.add(ep.number);
                setExpanded(s);
              }}>
                {hasThumbs && (
                  <div className="episode-thumb">
                    {ep.thumbnail ? <img src={ep.thumbnail} alt="" loading="lazy" /> : <span>EP {ep.number}</span>}
                  </div>
                )}
                <div className="episode-text">
                  <small>Episode {ep.number}</small>
                  {ep.title && <strong>{ep.title}</strong>}
                  {ep.description && <p className={expanded.has(ep.number) ? "" : "clamp-3"}>{ep.description}</p>}
                </div>
              </button>
            ))}
          </div>
          {page.episodes.length > shown && (
            <button className="glass-button wide" disabled={loadingMore} onClick={showMore}>
              {loadingMore ? <span className="spinner small" /> : `Show more episodes (${page.episodes.length - shown} left)`}
            </button>
          )}
        </>
      ) : loading ? (
        <Spinner label="Loading episodes…" />
      ) : selected.status === "NOT_YET_RELEASED" ? (
        <p className="muted">Not aired yet.</p>
      ) : (
        <p className="muted">No episode details available for this season.</p>
      )}
    </section>
  );
}
