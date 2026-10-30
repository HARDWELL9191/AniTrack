// Favorites: everything you hearted, by type (movies, shows, episodes, people, music, collections).

import { LIST_FIELDS } from "../core/api";
import { Empty, ErrorNote, ItemCard, PageHeader, Shelf, Spinner, useLoad } from "./components";
import { useModel } from "./state";

const SECTIONS: { types: string[]; title: string; landscape?: boolean; persons?: boolean }[] = [
  { types: ["Movie"], title: "Movies" },
  { types: ["Series"], title: "Shows" },
  { types: ["Episode"], title: "Episodes", landscape: true },
  { types: ["BoxSet"], title: "Collections" },
  { types: [], title: "People", persons: true },
  { types: ["MusicArtist"], title: "Artists" },
  { types: ["MusicAlbum"], title: "Albums" },
  { types: ["Audio"], title: "Songs" },
  { types: ["MusicVideo"], title: "Music videos" },
  { types: ["Playlist"], title: "Playlists" },
  { types: ["TvChannel"], title: "Channels", landscape: true },
  { types: ["Book", "AudioBook"], title: "Books" },
  { types: ["Video", "Photo"], title: "Videos & photos", landscape: true },
];

export function FavoritesPage({ refreshKey }: { refreshKey: number }) {
  const model = useModel();
  const { data, error, loading, reload } = useLoad(async () => {
    const api = model.api!;
    const [items, people, artists] = await Promise.all([
      api.items({ filters: ["IsFavorite"], recursive: true, sortBy: ["SortName"], fields: LIST_FIELDS, limit: 1000, enableImageTypes: ["Primary", "Backdrop", "Thumb"], imageTypeLimit: 1 }),
      api.persons({ isFavorite: true, limit: 200 }),
      api.artists({ isFavorite: true, limit: 200 }),
    ]);
    return [...items.Items, ...people.Items, ...artists.Items.filter((a) => !items.Items.some((i) => i.Id === a.Id))];
  }, [refreshKey, model.dataVersion]);
  return (
    <div className="page">
      <PageHeader title="Favorites" />
      {error ? <ErrorNote text={error} retry={reload} /> : !data && loading ? <Spinner /> : !data?.length ? <Empty icon="heart" title="No favorites yet" text="Tap the heart on anything to keep it here." /> : (
        SECTIONS.map((s) => {
          const items = data.filter((i) => (s.persons ? i.Type === "Person" : s.types.includes(i.Type)));
          if (!items.length) return null;
          return <Shelf key={s.title} title={s.title} subtitle={String(items.length)}>{items.map((i) => <ItemCard key={i.Id} item={i} shape={s.landscape ? "landscape" : undefined} width={s.landscape ? 280 : undefined} />)}</Shelf>;
        })
      )}
    </div>
  );
}
