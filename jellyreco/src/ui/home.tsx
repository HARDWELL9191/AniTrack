// Home: continue watching, next up, picked for you, my media, latest per library, favorites and
// what's on Live TV. Sections and their order are set in Settings → Home.

import { LIST_FIELDS } from "../core/api";
import type { HomeSection } from "../core/settings";
import type { Item } from "../core/types";
import { viewIcon } from "./app";
import { Cover, Empty, ItemCard, Shelf, useLoad } from "./components";
import { Icon } from "./icons";
import { ui, useModel, useNavigate } from "./state";
import { TitleCard, useForYou } from "./foryou";
import { entryId, titleId } from "../core/titles";

export function HomePage({ refreshKey }: { refreshKey: number }) {
  const model = useModel();
  const sections = model.settings.homeSections.filter((s) => s !== "none");
  return (
    <div className="page">
      <header className="page-head home-head">
        <div className="page-title">
          <h1>{greeting()}, {model.user?.Name}</h1>
          <div className="muted small">{model.server?.name}</div>
        </div>
      </header>
      {!model.views.length && <Empty icon="folder" title="No libraries" text="This account can't see any libraries yet." />}
      {sections.map((s) => <Section key={s} section={s} refreshKey={refreshKey + model.dataVersion} />)}
    </div>
  );
}

function greeting() {
  const h = new Date().getHours();
  return h < 5 ? "Good night" : h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening";
}

function Section({ section, refreshKey }: { section: HomeSection; refreshKey: number }) {
  switch (section) {
    case "resume": return <ResumeShelf refreshKey={refreshKey} />;
    case "nextUp": return <NextUpShelf refreshKey={refreshKey} />;
    case "forYouRow": return <ForYouShelf />;
    case "watchLater": return <MyListShelf refreshKey={refreshKey} />;
    case "libraries": return <MyMedia />;
    case "latest": return <LatestShelves refreshKey={refreshKey} />;
    case "favorites": return <FavoritesShelf refreshKey={refreshKey} />;
    case "liveTv": return <OnNowShelf refreshKey={refreshKey} />;
    default: return null;
  }
}

function ResumeShelf({ refreshKey }: { refreshKey: number }) {
  const model = useModel();
  const { data } = useLoad(async () => {
    const [video, audio] = await Promise.all([
      model.api!.resume({ mediaTypes: ["Video"], limit: 24, enableImageTypes: ["Primary", "Backdrop", "Thumb"] }),
      model.api!.resume({ mediaTypes: ["Audio"], limit: 12 }).catch(() => null),
    ]);
    return { video: video.Items, audio: audio?.Items ?? [] };
  }, [refreshKey]);
  if (!data) return null;
  return (
    <>
      {data.video.length > 0 && (
        <Shelf title="Continue watching" icon="play">
          {data.video.map((i) => <ItemCard key={i.Id} item={i} shape="landscape" width={300} context="resume" onClick={() => void model.player?.playItem(i, { resume: true })} />)}
        </Shelf>
      )}
      {data.audio.length > 0 && (
        <Shelf title="Continue listening" icon="music">
          {data.audio.map((i) => <ItemCard key={i.Id} item={i} context="resume" />)}
        </Shelf>
      )}
    </>
  );
}

function NextUpShelf({ refreshKey }: { refreshKey: number }) {
  const model = useModel();
  const navigate = useNavigate();
  const { data } = useLoad(() => model.api!.nextUp({ limit: 24, enableImageTypes: ["Primary", "Backdrop", "Thumb"], enableRewatching: false, enableResumable: false }), [refreshKey]);
  if (!data?.Items.length) return null;
  return (
    <Shelf title="Next up" icon="tv" action={{ label: "See all", run: () => navigate({ kind: "browse", title: "Next up", query: { nextUp: true } }) }}>
      {data.Items.map((i) => <ItemCard key={i.Id} item={i} shape="landscape" width={300} />)}
    </Shelf>
  );
}

function ForYouShelf() {
  const model = useModel();
  const { picks, building } = useForYou();
  if (!model.tmdb.configured) return null;
  if (!picks.length) return building ? <Shelf title="Picked for you" icon="wand"><div className="shelf-spinner"><span className="spinner" /></div></Shelf> : null;
  return (
    <Shelf title="Picked for you" icon="wand" action={{ label: "For You", run: () => { model.tab = "forYou"; model.notify(); } }}>
      {picks.slice(0, 20).map((p) => <TitleCard key={titleId(p.title)} t={p.title} match={p.match} width={model.settings.libraryCardSize} />)}
    </Shelf>
  );
}

/** My List: what you plan to watch (titles you've finished drop off). */
function MyListShelf({ refreshKey }: { refreshKey: number }) {
  const model = useModel();
  const entries = model.storage?.myList ?? [];
  const serverIds = entries.flatMap((e) => (e.serverId ? [e.serverId] : []));
  const key = entries.map(entryId).join(",");
  const { data } = useLoad(async () => {
    const r = serverIds.length ? await model.api!.items({ ids: serverIds.slice(0, 150), fields: LIST_FIELDS, enableUserData: true }) : { Items: [] as Item[] };
    return entries.slice(0, 40).map((e) => (e.serverId ? { e, item: r.Items.find((i) => i.Id === e.serverId) } : { e, item: undefined }))
      .filter((x) => (x.e.external ? true : x.item && !x.item.UserData?.Played));
  }, [key, refreshKey]);
  if (!data?.length) return null;
  return (
    <Shelf title="My List" icon="bookmark" action={{ label: "See all", run: () => { model.tab = "myList"; model.notify(); } }}>
      {data.map((x) => (x.item ? <ItemCard key={entryId(x.e)} item={x.item} /> : x.e.external ? <TitleCard key={entryId(x.e)} t={x.e.external} width={model.settings.libraryCardSize} notOnServer /> : null))}
    </Shelf>
  );
}

function MyMedia() {
  const model = useModel();
  if (!model.views.length) return null;
  return (
    <Shelf title="My media" icon="folder">
      {model.views.map((v) => (
        <button key={v.Id} className="library-tile" onClick={() => { ui.popToRoot("library"); model.tab = "library"; model.libraryId = v.Id; model.notify(); }}
          onContextMenu={(e) => { e.preventDefault(); ui.showMenu({ x: e.clientX, y: e.clientY, item: v }); }}>
          <Cover url={v.ImageTags?.Primary ? model.api!.image(v.Id, "Primary", { tag: v.ImageTags.Primary, maxWidth: 520 }) : undefined} width={260} height={146} radius={14} icon={viewIcon(v.CollectionType)} />
          <span className="library-tile-name"><Icon name={viewIcon(v.CollectionType)} size={16} /> {v.Name}</span>
        </button>
      ))}
    </Shelf>
  );
}

function LatestShelves({ refreshKey }: { refreshKey: number }) {
  const model = useModel();
  const excludes = new Set(model.user?.Configuration?.LatestItemsExcludes ?? []);
  const views = model.views.filter((v) => !excludes.has(v.Id) && v.CollectionType !== "livetv" && v.CollectionType !== "playlists" && v.CollectionType !== "boxsets");
  return <>{views.map((v) => <LatestShelf key={v.Id} view={v} refreshKey={refreshKey} />)}</>;
}

function LatestShelf({ view, refreshKey }: { view: Item; refreshKey: number }) {
  const model = useModel();
  const { data } = useLoad(async () => {
    const items = await model.api!.latest(view.Id, 24);
    return model.settings.hideWatchedInLatest || model.user?.Configuration?.HidePlayedInLatest ? items.filter((i) => !i.UserData?.Played) : items;
  }, [view.Id, refreshKey]);
  if (!data?.length) return null;
  return (
    <Shelf title={`Latest in ${view.Name}`} action={{ label: "Library", run: () => { ui.popToRoot("library"); model.tab = "library"; model.libraryId = view.Id; model.notify(); } }}>
      {data.map((i) => <ItemCard key={i.Id} item={i} />)}
    </Shelf>
  );
}

function FavoritesShelf({ refreshKey }: { refreshKey: number }) {
  const model = useModel();
  const { data } = useLoad(() => model.api!.items({ filters: ["IsFavorite"], recursive: true, includeItemTypes: ["Movie", "Series", "MusicAlbum", "BoxSet"], sortBy: ["DatePlayed", "SortName"], sortOrder: ["Descending", "Ascending"], limit: 24, fields: LIST_FIELDS }), [refreshKey]);
  if (!data?.Items.length) return null;
  return (
    <Shelf title="Favorites" icon="heart" action={{ label: "See all", run: () => { model.tab = "favorites"; model.notify(); } }}>
      {data.Items.map((i) => <ItemCard key={i.Id} item={i} />)}
    </Shelf>
  );
}

function OnNowShelf({ refreshKey }: { refreshKey: number }) {
  const model = useModel();
  const hasLive = model.views.some((v) => v.CollectionType === "livetv");
  const { data } = useLoad(async () => (hasLive ? model.api!.get<{ Items: Item[] }>("/LiveTv/Programs/Recommended", { userId: model.api!.userId, isAiring: true, limit: 24, fields: ["ChannelInfo", "PrimaryImageAspectRatio"], enableImageTypes: ["Primary", "Thumb", "Backdrop"] }) : { Items: [] }), [refreshKey, hasLive]);
  if (!data?.Items.length) return null;
  return (
    <Shelf title="On now" icon="live">
      {data.Items.map((i) => <ItemCard key={i.Id} item={i} shape="landscape" width={280} onClick={() => void model.player?.playItem({ Id: i.ChannelId!, Type: "TvChannel", Name: i.ChannelName })} />)}
    </Shelf>
  );
}
