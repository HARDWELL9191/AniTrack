// Details for anything: movies, shows (seasons + episodes), seasons, episodes, albums, artists,
// collections, playlists, channels, programs, books and photos.

import { useEffect, useMemo, useState } from "react";
import { LIST_FIELDS } from "../core/api";
import { toggleMyList } from "./foryou";
import { AccountStorage } from "../core/storage";
import type { Item, MediaStream } from "../core/types";
import { ticksToSeconds } from "../core/types";
import {
  backdropUrl, cardImage, Chip, Cover, Dropdown, Empty, ErrorNote, isPlayable, ItemCard, ItemRow, logoUrl, Rating, Shelf, Spinner, useLoad,
} from "./components";
import { audioBadge, clock, dateOnly, endsAt, episodeCode, itemSubtitle, languageName, playedPercent, runtime, streamLabel, videoBadges } from "./fmt";
import { Icon } from "./icons";
import { ExternalLinks } from "./library";
import { itemMenuItems } from "./menu";
import { routeFor, ui, useModel, useNavigate } from "./state";

export function DetailPage({ id, hint, back, refreshKey }: { id: string; hint?: Item; back: () => void; refreshKey: number }) {
  const model = useModel();
  const { data: item, error, reload, setData } = useLoad(() => model.api!.itemFull(id), [id, refreshKey, model.dataVersion]);
  const shown = item ?? hint;
  if (error && !shown) return <div className="page"><button className="glass-button back-float" onClick={back}><Icon name="chevronLeft" size={16} /> Back</button><ErrorNote text={error} retry={reload} /></div>;
  if (!shown) return <div className="page"><Spinner /></div>;
  return (
    <div className="page wide">
      <button className="glass-button back-float" onClick={back}><Icon name="chevronLeft" size={16} /> Back</button>
      <Detail item={shown} full={!!item} onChange={(i) => setData(i)} />
    </div>
  );
}

function Detail({ item, full, onChange }: { item: Item; full: boolean; onChange: (i: Item) => void }) {
  const model = useModel();
  const navigate = useNavigate();
  const api = model.api!;
  const back = model.settings.showBackdrops ? backdropUrl(api, item, 1920) : undefined;
  const logo = logoUrl(api, item);
  const sources = item.MediaSources ?? [];
  const [sourceId, setSourceId] = useState<string | null>(null);
  const source = sources.find((s) => s.Id === sourceId) ?? sources[0];
  const streams = source?.MediaStreams ?? item.MediaStreams ?? [];
  const audios = streams.filter((s) => s.Type === "Audio");
  const subs = streams.filter((s) => s.Type === "Subtitle");
  const video = streams.find((s) => s.Type === "Video");
  const [audioIndex, setAudioIndex] = useState<number | undefined>();
  const [subIndex, setSubIndex] = useState<number | undefined>();
  useEffect(() => { setAudioIndex(undefined); setSubIndex(undefined); }, [source?.Id]);

  const resumeAt = ticksToSeconds(item.UserData?.PlaybackPositionTicks);
  const playable = isPlayable(item) && item.Type !== "Person";
  const isFolderish = ["Series", "Season", "BoxSet", "Playlist", "MusicAlbum", "MusicArtist", "PhotoAlbum", "Folder"].includes(item.Type);
  const play = (fromStart = false) => model.player?.playItem(item, {
    resume: !fromStart, startSeconds: fromStart ? 0 : undefined, mediaSourceId: source?.Id ?? undefined, audioIndex, subtitleIndex: subIndex,
  });

  // Your match % (the same taste profile as the iPhone; the library is read in the background).
  useEffect(() => { void model.reco.ensure().then(() => model.notify()).catch(() => {}); }, [model]);
  const match = useMemo(() => {
    if (!model.reco.ready || item.UserData?.Played || !["Series", "Movie"].includes(item.Type)) return null;
    return model.reco.match(item);
  }, [item, model.reco.ready, model.version]); // eslint-disable-line react-hooks/exhaustive-deps

  const director = item.People?.filter((p) => p.Type === "Director") ?? [];
  const writers = item.People?.filter((p) => p.Type === "Writer") ?? [];
  const cast = item.People?.filter((p) => p.Type === "Actor" || p.Type === "GuestStar") ?? [];
  const crew = item.People?.filter((p) => p.Type !== "Actor" && p.Type !== "GuestStar") ?? [];
  const meta = [
    item.Type === "Episode" ? episodeCode(item) : null,
    item.ProductionYear && item.Type !== "Episode" ? itemSubtitle(item) || item.ProductionYear : null,
    item.PremiereDate && item.Type === "Episode" ? dateOnly(item.PremiereDate) : null,
    item.OfficialRating,
    item.RunTimeTicks && !isFolderish ? runtime(item.RunTimeTicks) : null,
    item.Type === "Series" && item.Status ? item.Status : null,
    item.Type === "Series" && item.ChildCount ? `${item.ChildCount} ${item.ChildCount === 1 ? "season" : "seasons"}` : null,
    item.RunTimeTicks && !isFolderish ? endsAt(item.RunTimeTicks, item.UserData?.PlaybackPositionTicks ?? 0) : null,
  ].filter(Boolean);

  return (
    <div className="detail">
      <div className="detail-banner" style={back ? { backgroundImage: `url("${back}")` } : undefined} />
      <div className="detail-top">
        <div className="detail-cover">
          <Cover url={cardImage(api, item, ["Episode", "TvChannel", "Video", "Photo"].includes(item.Type) ? "landscape" : ["MusicAlbum", "Audio", "MusicArtist", "Playlist"].includes(item.Type) ? "square" : "poster", 300)}
            width={["Episode", "TvChannel", "Video", "Photo"].includes(item.Type) ? 360 : 240} height={["Episode", "TvChannel", "Video", "Photo"].includes(item.Type) ? 202 : ["MusicAlbum", "Audio", "MusicArtist", "Playlist"].includes(item.Type) ? 240 : 360} radius={16} />
        </div>
        <div className="detail-heading">
          {item.Type === "Episode" && item.SeriesId && <button className="link-button" onClick={() => navigate({ kind: "item", id: item.SeriesId! })}>{item.SeriesName}</button>}
          {(item.Type === "Season") && item.SeriesId && <button className="link-button" onClick={() => navigate({ kind: "item", id: item.SeriesId! })}>{item.SeriesName}</button>}
          {item.Type === "Audio" && item.AlbumId && <button className="link-button" onClick={() => navigate({ kind: "item", id: item.AlbumId! })}>{item.Album}</button>}
          {logo && item.Type !== "Episode" ? <img className="detail-logo" src={logo} alt={item.Name ?? ""} /> : <h1>{item.Name}</h1>}
          {item.OriginalTitle && item.OriginalTitle !== item.Name && <div className="muted">{item.OriginalTitle}</div>}
          <div className="detail-badges">
            {meta.map((m, i) => <span key={i} className="muted">{m}</span>)}
            <Rating value={item.CommunityRating} />
            {item.CriticRating ? <span className={`score ${item.CriticRating >= 60 ? "score-good" : "score-low"}`}><Icon name="star" size={13} />{item.CriticRating}%</span> : null}
            {match !== null && <span className="match"><Icon name="wand" size={14} />{match}% match</span>}
          </div>
          {video && <div className="chips-wrap">{videoBadges(video).map((b) => <Chip key={b} text={b} tone="muted" />)}{audioBadge(audios.find((a) => a.IsDefault) ?? audios[0]) && <Chip text={audioBadge(audios.find((a) => a.IsDefault) ?? audios[0])!} tone="muted" />}{subs.length > 0 && <Chip text={`${subs.length} subtitles`} tone="muted" />}</div>}
          <div className="detail-actions">
            {playable && (
              <>
                <button className="glass-button prominent big" onClick={() => void play()}>
                  <Icon name="playFill" size={16} /> {resumeAt > 5 && !isFolderish ? `Resume ${clock(resumeAt)}` : item.Type === "Series" ? "Play next episode" : "Play"}
                </button>
                {resumeAt > 5 && !isFolderish && <button className="glass-button big" onClick={() => void play(true)}><Icon name="repeat" size={16} /> From start</button>}
                {isFolderish && <button className="glass-button big icon-only" title="Shuffle" onClick={() => void model.player?.playItem(item, { shuffle: true })}><Icon name="shuffle" size={17} /></button>}
              </>
            )}
            {(item.LocalTrailerCount || item.RemoteTrailers?.length) ? <TrailerButton item={item} /> : null}
            <button className={`glass-button big icon-only ${item.UserData?.Played ? "on" : ""}`} title={item.UserData?.Played ? "Mark unwatched" : "Mark watched"} onClick={async () => { await model.togglePlayed(item); onChange({ ...item }); }}>
              <Icon name={item.UserData?.Played ? "checkCircleFill" : "checkCircle"} size={19} />
            </button>
            <button className={`glass-button big icon-only ${item.UserData?.IsFavorite ? "on fav" : ""}`} title="Favorite" onClick={async () => { await model.toggleFavorite(item); onChange({ ...item }); }}>
              <Icon name={item.UserData?.IsFavorite ? "heartFill" : "heart"} size={19} />
            </button>
            <LikeButtons item={item} onChange={onChange} />
            {["Series", "Movie", "Season", "Episode"].includes(item.Type) && (
              <button className={`glass-button big icon-only ${model.storage?.hasServer(AccountStorage.listId(item)) ? "on" : ""}`} title={model.storage?.hasServer(AccountStorage.listId(item)) ? "Remove from My List" : "Add to My List"} onClick={() => void toggleMyList(model, item)}>
                <Icon name="bookmark" size={18} />
              </button>
            )}
            <Dropdown label="" compact icon="more" title="More" align="left" items={itemMenuItems(model, item)} onPick={(fn) => fn()} />
          </div>
          {playable && !isFolderish && full && (sources.length > 1 || audios.length > 1 || subs.length > 0) && (
            <div className="track-pickers">
              {sources.length > 1 && (
                <label><span>Version</span>
                  <select value={source?.Id ?? ""} onChange={(e) => setSourceId(e.target.value)}>{sources.map((s) => <option key={s.Id} value={s.Id ?? ""}>{s.Name ?? s.Container}</option>)}</select>
                </label>
              )}
              {audios.length > 1 && (
                <label><span>Audio</span>
                  <select value={audioIndex ?? source?.DefaultAudioStreamIndex ?? ""} onChange={(e) => setAudioIndex(Number(e.target.value))}>{audios.map((a) => <option key={a.Index} value={a.Index}>{streamLabel(a)}</option>)}</select>
                </label>
              )}
              {subs.length > 0 && (
                <label><span>Subtitles</span>
                  <select value={subIndex ?? source?.DefaultSubtitleStreamIndex ?? -1} onChange={(e) => setSubIndex(Number(e.target.value))}>
                    <option value={-1}>Off</option>{subs.map((s) => <option key={s.Index} value={s.Index}>{streamLabel(s)}</option>)}
                  </select>
                </label>
              )}
            </div>
          )}
        </div>
      </div>

      {playedPercent(item) > 0 && playedPercent(item) < 100 && !isFolderish && <div className="detail-progress"><div style={{ width: `${playedPercent(item)}%` }} /></div>}

      <div className="detail-columns">
        <div className="detail-main">
          {item.Taglines?.[0] && <p className="tagline">{item.Taglines[0]}</p>}
          {item.Overview && <section className="synopsis"><p>{item.Overview}</p></section>}
          {item.Type === "Series" && <SeriesBody series={item} />}
          {item.Type === "Season" && <SeasonEpisodes seriesId={item.SeriesId ?? item.ParentId ?? ""} seasonId={item.Id} />}
          {item.Type === "Episode" && item.SeriesId && <SeasonEpisodes seriesId={item.SeriesId} seasonId={item.SeasonId ?? undefined} currentId={item.Id} compact />}
          {item.Type === "MusicAlbum" && <AlbumTracks album={item} />}
          {item.Type === "MusicArtist" && <ArtistBody artist={item} />}
          {(item.Type === "BoxSet" || item.Type === "Folder" || item.Type === "PhotoAlbum") && <Children parent={item} />}
          {item.Type === "Playlist" && <PlaylistItems playlist={item} />}
          {(item.Type === "TvChannel" || item.Type === "LiveTvChannel") && <ChannelPrograms channel={item} />}
          {cast.length > 0 && (
            <Shelf title="Cast & crew">
              {[...cast, ...crew].map((p, i) => (
                <button key={`${p.Id}-${i}`} className="person-card" onClick={() => navigate({ kind: "person", id: p.Id })}>
                  <Cover url={p.PrimaryImageTag ? api.image(p.Id, "Primary", { tag: p.PrimaryImageTag, maxWidth: 200 }) : undefined} width={110} height={110} radius={55} icon="person" />
                  <strong>{p.Name}</strong>
                  <small className="muted">{p.Role || p.Type}</small>
                </button>
              ))}
            </Shelf>
          )}
          {full && <Extras item={item} />}
          {full && ["Movie", "Series", "MusicAlbum", "MusicArtist", "Episode", "BoxSet"].includes(item.Type) && <Similar item={item} />}
        </div>
        <aside className="detail-side">
          <div className="info-panel">
            {item.Genres?.length ? <InfoRow label="Genres">{item.Genres.map((g) => <Chip key={g} text={g} onClick={() => navigate({ kind: "genre", name: g, types: [item.Type === "Episode" || item.Type === "Season" ? "Series" : item.Type] })} />)}</InfoRow> : null}
            {director.length ? <InfoRow label={director.length > 1 ? "Directors" : "Director"}>{director.map((d) => <button key={d.Id} className="link-button" onClick={() => navigate({ kind: "person", id: d.Id })}>{d.Name}</button>)}</InfoRow> : null}
            {writers.length ? <InfoRow label="Writers">{writers.map((d) => <button key={d.Id} className="link-button" onClick={() => navigate({ kind: "person", id: d.Id })}>{d.Name}</button>)}</InfoRow> : null}
            {item.Studios?.length ? <InfoRow label={item.Type === "Series" ? "Network" : "Studio"}>{item.Studios.map((s) => <button key={s.Id} className="link-button" onClick={() => navigate({ kind: "studio", name: s.Name ?? "", id: s.Id })}>{s.Name}</button>)}</InfoRow> : null}
            {item.PremiereDate && item.Type !== "Episode" && <InfoRow label="Released">{dateOnly(item.PremiereDate)}</InfoRow>}
            {item.Type === "Series" && item.AirDays?.length ? <InfoRow label="Airs">{item.AirDays.join(", ")}{item.AirTime ? ` at ${item.AirTime}` : ""}</InfoRow> : null}
            {item.ProductionLocations?.length ? <InfoRow label="Country">{item.ProductionLocations.join(", ")}</InfoRow> : null}
            {item.Artists?.length ? <InfoRow label="Artists">{item.ArtistItems?.map((a) => <button key={a.Id} className="link-button" onClick={() => navigate({ kind: "item", id: a.Id })}>{a.Name}</button>) ?? item.Artists.join(", ")}</InfoRow> : null}
            {item.Tags?.length ? <InfoRow label="Tags"><div className="chips-wrap">{item.Tags.slice(0, 30).map((t) => <Chip key={t} text={t} tone="muted" />)}</div></InfoRow> : null}
            {source && !isFolderish && <InfoRow label="File">{source.Container?.toUpperCase()} · {source.Size ? `${(source.Size / 1024 ** 3).toFixed(2)} GB` : "?"}<button className="link-button small" onClick={() => ui.openSheet({ kind: "mediaInfo", item })}>Media info</button></InfoRow>}
            {audios.length > 0 && <InfoRow label="Audio">{audios.map((a) => <div key={a.Index} className="small">{streamLabel(a)}</div>)}</InfoRow>}
            {subs.length > 0 && <InfoRow label="Subtitles"><div className="small">{[...new Set(subs.map((s: MediaStream) => languageName(s.Language)))].join(", ")}</div></InfoRow>}
            <ExternalLinks item={item} />
          </div>
        </aside>
      </div>
    </div>
  );
}

function InfoRow({ label, children }: { label: string; children: React.ReactNode }) {
  return <div className="info-row"><span>{label}</span><div>{children}</div></div>;
}

function LikeButtons({ item, onChange }: { item: Item; onChange: (i: Item) => void }) {
  const model = useModel();
  const likes = item.UserData?.Likes;
  const set = async (v: boolean | null) => {
    try {
      await model.api!.setLikes(item.Id, v);
      item.UserData = { ...(item.UserData ?? {}), Likes: v };
      onChange({ ...item });
      model.dataChanged();
    } catch (e) { model.fail(e); }
  };
  return (
    <>
      <button className={`glass-button big icon-only ${likes === true ? "on" : ""}`} title="I like this" onClick={() => void set(likes === true ? null : true)}><Icon name="thumbsUp" size={18} /></button>
      <button className={`glass-button big icon-only ${likes === false ? "on danger" : ""}`} title="Not for me" onClick={() => void set(likes === false ? null : false)}><Icon name="thumbsDown" size={18} /></button>
    </>
  );
}

function TrailerButton({ item }: { item: Item }) {
  const model = useModel();
  const play = async () => {
    try {
      if (item.LocalTrailerCount) {
        const t = await model.api!.localTrailers(item.Id);
        if (t.length) return model.player?.playNow(t, 0);
      }
      const url = item.RemoteTrailers?.[0]?.Url;
      if (url) {
        const { openUrl } = await import("@tauri-apps/plugin-opener");
        await openUrl(url);
      }
    } catch (e) { model.fail(e); }
  };
  return <button className="glass-button big" onClick={() => void play()}><Icon name="film" size={16} /> Trailer</button>;
}

function SeriesBody({ series }: { series: Item }) {
  const model = useModel();
  const navigate = useNavigate();
  const { data: seasons } = useLoad(() => model.api!.seasons(series.Id), [series.Id, model.dataVersion]);
  const { data: next } = useLoad(() => model.api!.nextUp({ seriesId: series.Id, limit: 1, enableResumable: true }), [series.Id, model.dataVersion]);
  const [seasonId, setSeasonId] = useState<string | null>(null);
  const list = seasons?.Items ?? [];
  const nextEp = next?.Items[0];
  const chosen = seasonId ?? nextEp?.SeasonId ?? list.find((s) => !s.UserData?.Played)?.Id ?? list[0]?.Id;
  return (
    <>
      {nextEp && (
        <button className="next-up-card panel" onClick={() => void model.player?.playItem(nextEp, { resume: true })}>
          <Cover url={cardImage(model.api!, nextEp, "landscape", 280)} width={220} height={124} radius={10} icon="tv" />
          <div>
            <small className="muted">{(nextEp.UserData?.PlaybackPositionTicks ?? 0) > 0 ? "Continue" : "Next up"}</small>
            <strong>{episodeCode(nextEp)} · {nextEp.Name}</strong>
            <p className="muted small clamp-3">{nextEp.Overview}</p>
          </div>
          <span className="next-up-play"><Icon name="playFill" size={22} /></span>
        </button>
      )}
      {list.length > 0 && (
        <section className="seasons">
          <div className="section-head">
            <h3>Seasons</h3>
            <div className="season-tabs">
              {list.map((s) => (
                <button key={s.Id} className={s.Id === chosen ? "on" : ""} onClick={() => setSeasonId(s.Id)} onDoubleClick={() => navigate(routeFor(s))}>
                  {s.Name}{s.UserData?.Played ? " ✓" : s.UserData?.UnplayedItemCount ? ` · ${s.UserData.UnplayedItemCount}` : ""}
                </button>
              ))}
            </div>
          </div>
          {chosen && <SeasonEpisodes seriesId={series.Id} seasonId={chosen} />}
        </section>
      )}
    </>
  );
}

function SeasonEpisodes({ seriesId, seasonId, currentId, compact }: { seriesId: string; seasonId?: string; currentId?: string; compact?: boolean }) {
  const model = useModel();
  const navigate = useNavigate();
  const { data, error } = useLoad(() => model.api!.episodes(seriesId, seasonId ? { seasonId } : {}), [seriesId, seasonId, model.dataVersion]);
  if (error) return <ErrorNote text={error} />;
  if (!data) return <Spinner />;
  const eps = data.Items;
  if (!eps.length) return <Empty icon="tv" title="No episodes" />;
  return (
    <div className={`episode-list ${compact ? "compact" : ""}`}>
      {compact && <h3>{eps[0]?.SeasonName ?? "Episodes"}</h3>}
      {eps.map((e) => (
        <div key={e.Id} className={`episode ${e.Id === currentId ? "on" : ""} ${e.LocationType === "Virtual" ? "missing" : ""}`} onContextMenu={(ev) => { ev.preventDefault(); ui.showMenu({ x: ev.clientX, y: ev.clientY, item: e }); }}>
          <button className="episode-thumb" onClick={() => e.LocationType !== "Virtual" && void model.player?.playItem(e, { resume: true })} title="Play">
            <Cover url={cardImage(model.api!, e, "landscape", 260)} width={compact ? 150 : 220} height={compact ? 84 : 124} radius={10} icon="tv" style={model.settings.blurUnwatched && !e.UserData?.Played ? { filter: "blur(10px)" } : undefined} />
            {e.LocationType !== "Virtual" && <span className="episode-play"><Icon name="playFill" size={20} /></span>}
            {e.UserData?.Played && <span className="episode-watched"><Icon name="check" size={12} strokeWidth={3} /></span>}
            {playedPercent(e) > 0 && playedPercent(e) < 100 && <div className="card-progress"><div style={{ width: `${playedPercent(e)}%` }} /></div>}
          </button>
          <button className="episode-text" onClick={() => navigate({ kind: "item", id: e.Id, hint: e })}>
            <small>{episodeCode(e)}{e.RunTimeTicks ? ` · ${runtime(e.RunTimeTicks)}` : ""}{e.PremiereDate ? ` · ${dateOnly(e.PremiereDate)}` : ""}{e.LocationType === "Virtual" ? " · Missing" : ""}</small>
            <strong>{e.Name}</strong>
            {!compact && <p className="clamp-3">{e.Overview}</p>}
          </button>
          <button className="row-more" onClick={(ev) => ui.showMenu({ x: ev.clientX, y: ev.clientY, item: e })} aria-label="More"><Icon name="more" size={18} /></button>
        </div>
      ))}
    </div>
  );
}

function AlbumTracks({ album }: { album: Item }) {
  const model = useModel();
  const { data } = useLoad(() => model.api!.items({ parentId: album.Id, includeItemTypes: ["Audio"], sortBy: ["ParentIndexNumber", "IndexNumber", "SortName"], fields: [...LIST_FIELDS, "MediaSources"] }), [album.Id, model.dataVersion]);
  if (!data) return <Spinner />;
  const discs = new Set(data.Items.map((t) => t.ParentIndexNumber ?? 1));
  return (
    <div className="tracks">
      {data.Items.map((t, i) => (
        <div key={t.Id}>
          {discs.size > 1 && (i === 0 || data.Items[i - 1].ParentIndexNumber !== t.ParentIndexNumber) && <h4 className="disc">Disc {t.ParentIndexNumber ?? 1}</h4>}
          <ItemRow item={t} index={t.IndexNumber ?? i + 1} subtitle={t.Artists?.join(", ")} trailing={<span className="muted small tabular">{clock(ticksToSeconds(t.RunTimeTicks))}</span>}
            onClick={() => void model.player?.playNow(data.Items, i)} />
        </div>
      ))}
    </div>
  );
}

function ArtistBody({ artist }: { artist: Item }) {
  const model = useModel();
  const { data: albums } = useLoad(() => model.api!.items({ artistIds: [artist.Id], recursive: true, includeItemTypes: ["MusicAlbum"], sortBy: ["PremiereDate", "ProductionYear", "SortName"], sortOrder: ["Descending"], fields: LIST_FIELDS }), [artist.Id]);
  const { data: top } = useLoad(() => model.api!.items({ artistIds: [artist.Id], recursive: true, includeItemTypes: ["Audio"], sortBy: ["PlayCount", "CommunityRating"], sortOrder: ["Descending"], limit: 10, fields: LIST_FIELDS }), [artist.Id]);
  return (
    <>
      {!!top?.Items.length && <section><h3>Popular</h3><div className="tracks">{top.Items.map((t, i) => <ItemRow key={t.Id} item={t} index={i + 1} subtitle={t.Album} onClick={() => void model.player?.playNow(top.Items, i)} />)}</div></section>}
      {!!albums?.Items.length && <Shelf title="Albums">{albums.Items.map((a) => <ItemCard key={a.Id} item={a} />)}</Shelf>}
    </>
  );
}

function Children({ parent }: { parent: Item }) {
  const model = useModel();
  const { data } = useLoad(() => model.api!.items({ parentId: parent.Id, fields: LIST_FIELDS, sortBy: parent.Type === "BoxSet" ? ["PremiereDate", "ProductionYear", "SortName"] : ["IsFolder", "SortName"], sortOrder: parent.Type === "BoxSet" ? ["Ascending"] : ["Descending", "Ascending"], enableImageTypes: ["Primary", "Backdrop", "Thumb"] }), [parent.Id, model.dataVersion]);
  if (!data) return <Spinner />;
  return <div className="grid" style={{ gridTemplateColumns: `repeat(auto-fill, minmax(${model.settings.libraryCardSize}px, 1fr))` }}>{data.Items.map((i) => <ItemCard key={i.Id} item={i} width={undefined} />)}</div>;
}

function PlaylistItems({ playlist }: { playlist: Item }) {
  const model = useModel();
  const { data, reload } = useLoad(() => model.api!.get<{ Items: Item[] }>(`/Playlists/${playlist.Id}/Items`, { userId: model.api!.userId, fields: LIST_FIELDS }), [playlist.Id, model.dataVersion]);
  if (!data) return <Spinner />;
  const move = async (i: Item, to: number) => {
    try { await model.api!.post(`/Playlists/${playlist.Id}/Items/${i.PlaylistItemId}/Move/${to}`); reload(); } catch (e) { model.fail(e); }
  };
  return (
    <div className="tracks">
      {data.Items.map((t, i) => (
        <ItemRow key={t.PlaylistItemId ?? t.Id} item={t} index={i + 1} context="playlist" playlistId={playlist.Id} onClick={() => void model.player?.playNow(data.Items, i)}
          trailing={<span className="row-line">
            <span role="button" className="round-button" onClick={(e) => { e.stopPropagation(); if (i > 0) void move(t, i - 1); }} title="Move up"><Icon name="arrowUp" size={14} /></span>
            <span role="button" className="round-button" onClick={(e) => { e.stopPropagation(); if (i < data.Items.length - 1) void move(t, i + 1); }} title="Move down"><Icon name="arrowDown" size={14} /></span>
          </span>} />
      ))}
    </div>
  );
}

function ChannelPrograms({ channel }: { channel: Item }) {
  const model = useModel();
  const { data } = useLoad(() => model.api!.get<{ Items: Item[] }>("/LiveTv/Programs", { channelIds: [channel.Id], userId: model.api!.userId, minEndDate: new Date().toISOString(), limit: 30, sortBy: ["StartDate"], fields: ["Overview"] }), [channel.Id]);
  if (!data) return <Spinner />;
  return (
    <section><h3>Schedule</h3>
      <div className="rows">{data.Items.map((p) => (
        <button key={p.Id} className="row" onClick={(e) => ui.showMenu({ x: e.clientX, y: e.clientY, item: p })}>
          <span className="tabular muted">{p.StartDate ? new Date(p.StartDate).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" }) : ""}</span>
          <div className="row-text"><div className="row-title">{p.Name}{p.EpisodeTitle ? ` · ${p.EpisodeTitle}` : ""}</div><div className="row-sub">{p.Overview}</div></div>
          {p.TimerId && <Icon name="calendar" size={16} />}
        </button>
      ))}</div>
    </section>
  );
}

function Extras({ item }: { item: Item }) {
  const model = useModel();
  const { data } = useLoad(async () => {
    const [features, trailers] = await Promise.all([
      item.SpecialFeatureCount ? model.api!.specialFeatures(item.Id) : Promise.resolve([] as Item[]),
      item.LocalTrailerCount ? model.api!.localTrailers(item.Id) : Promise.resolve([] as Item[]),
    ]);
    return [...trailers, ...features];
  }, [item.Id]);
  if (!data?.length) return null;
  return <Shelf title="Extras">{data.map((x, i) => <ItemCard key={x.Id} item={x} shape="landscape" width={260} onClick={() => void model.player?.playNow(data, i)} />)}</Shelf>;
}

/** More like this: titles in your library, ranked by the on-device AI (overview meaning) with
 * genres/tags/studios and the server's own similarity list (the iPhone's logic). Read only. */
function Similar({ item }: { item: Item }) {
  const model = useModel();
  const { data } = useLoad(() => model.reco.moreLike(item, model.settings.useOnDeviceAI && !model.powerSaver, 25_000), [item.Id]);
  if (!data?.length) return null;
  return (
    <Shelf title="More like this" icon="layers" subtitle="from your library">
      {data.map((x) => <ItemCard key={x.item.Id} item={x.item} badge={<span className="bubble bubble-match">{x.match}%</span>} />)}
    </Shelf>
  );
}
