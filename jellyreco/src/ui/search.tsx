// Search across everything (movies, shows, episodes, people, music, collections, channels),
// grouped by type, plus genre suggestions when the field is empty.

import { useEffect, useState } from "react";
import { LIST_FIELDS } from "../core/api";
import type { Item } from "../core/types";
import { Empty, ErrorNote, Grid, ItemCard, PageHeader, SearchField, Segmented, Shelf, Spinner, useLoad } from "./components";
import { routeFor, useModel, useNavigate } from "./state";

const GROUPS: { types: string[]; title: string; landscape?: boolean }[] = [
  { types: ["Movie"], title: "Movies" },
  { types: ["Series"], title: "Shows" },
  { types: ["Episode"], title: "Episodes", landscape: true },
  { types: ["Person"], title: "People" },
  { types: ["BoxSet"], title: "Collections" },
  { types: ["MusicArtist"], title: "Artists" },
  { types: ["MusicAlbum"], title: "Albums" },
  { types: ["Audio"], title: "Songs" },
  { types: ["MusicVideo"], title: "Music videos" },
  { types: ["Playlist"], title: "Playlists" },
  { types: ["TvChannel", "LiveTvChannel"], title: "Channels", landscape: true },
  { types: ["Program", "TvProgram", "LiveTvProgram"], title: "On TV", landscape: true },
  { types: ["Book", "AudioBook"], title: "Books" },
  { types: ["Video", "Photo"], title: "Videos & photos", landscape: true },
];

export function SearchPage() {
  const model = useModel();
  const navigate = useNavigate();
  const [query, setQuery] = useState("");
  const [debounced, setDebounced] = useState("");
  const [scope, setScope] = useState<"all" | "movies" | "shows" | "music" | "people">("all");
  useEffect(() => { const t = setTimeout(() => setDebounced(query.trim()), 300); return () => clearTimeout(t); }, [query]);

  const types = scope === "movies" ? ["Movie", "BoxSet"] : scope === "shows" ? ["Series", "Episode"] : scope === "music" ? ["MusicArtist", "MusicAlbum", "Audio", "MusicVideo", "Playlist"] : scope === "people" ? ["Person"] : undefined;
  const { data, error, loading } = useLoad(async (signal): Promise<Item[]> => {
    if (!debounced) return [];
    const api = model.api!;
    const wantPeople = !types || types.includes("Person");
    const [items, people] = await Promise.all([
      types?.length === 1 && types[0] === "Person" ? Promise.resolve({ Items: [] as Item[] }) : api.items({ searchTerm: debounced, recursive: true, includeItemTypes: types?.filter((t) => t !== "Person"), limit: 150, fields: LIST_FIELDS, enableImageTypes: ["Primary", "Backdrop", "Thumb"], imageTypeLimit: 1 }, signal),
      wantPeople ? api.persons({ searchTerm: debounced, limit: 30 }) : Promise.resolve({ Items: [] as Item[] }),
    ]);
    return [...items.Items, ...people.Items];
  }, [debounced, scope]);

  const { data: genres } = useLoad(() => model.api!.genres({ includeItemTypes: ["Movie", "Series"], sortBy: ["SortName"], limit: 60 }), []);

  return (
    <div className="page">
      <PageHeader title="Search" />
      <SearchField value={query} onChange={setQuery} placeholder="Movies, shows, episodes, people, music…" autoFocus />
      <Segmented value={scope} options={[{ value: "all", label: "Everything" }, { value: "movies", label: "Movies" }, { value: "shows", label: "Shows" }, { value: "music", label: "Music" }, { value: "people", label: "People" }]} onChange={setScope} />
      {!debounced ? (
        genres?.Items.length ? (
          <section>
            <h3 className="muted">Browse by genre</h3>
            <div className="chips-wrap big">{genres.Items.map((g) => <button key={g.Id} className="chip chip-button" onClick={() => navigate({ kind: "genre", name: g.Name ?? "", id: g.Id })}>{g.Name}</button>)}</div>
          </section>
        ) : null
      ) : error ? <ErrorNote text={error} /> : loading && !data?.length ? <Spinner /> : !data?.length ? <Empty icon="search" title={`Nothing for "${debounced}"`} text="Try another spelling or fewer words." /> : (
        <>
          {GROUPS.map((g) => {
            const items = data.filter((i) => g.types.includes(i.Type));
            if (!items.length) return null;
            if (items.length <= 8 || scope !== "all") return (
              <section key={g.title}>
                <h2 className="section-title">{g.title} <span className="muted small">{items.length}</span></h2>
                <Grid min={g.landscape ? 260 : g.types[0] === "Person" || g.types[0] === "MusicArtist" ? 150 : model.settings.libraryCardSize}>
                  {items.map((i) => <ItemCard key={i.Id} item={i} width={undefined} onClick={() => navigate(routeFor(i))} />)}
                </Grid>
              </section>
            );
            return <Shelf key={g.title} title={g.title} subtitle={`${items.length}`}>{items.map((i) => <ItemCard key={i.Id} item={i} />)}</Shelf>;
          })}
        </>
      )}
    </div>
  );
}
