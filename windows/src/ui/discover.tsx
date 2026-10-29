// Discover (port of DiscoverView.swift + CategoryViews.swift): search, the category dropdown,
// four shelves saved for instant opening, and a page per category with sorting and endless scrolling.

import { useEffect, useRef, useState } from "react";
import { isCancellation } from "../core/anilist";
import { DiskCache } from "../core/cache";
import { AnimeCategory, categoryId, currentSeason, Media } from "../core/models";
import { Dropdown, Empty, LoadMore, MediaCard, MediaRow, PageHeader, SearchField, Shelf, Spinner } from "./components";
import { capitalized } from "./fmt";
import { ui, useModel } from "./state";

/** The one category dropdown (For You, Discover, search). Picking one calls `onPick`. */
export function CategoryMenu({ selected, onPick, showAny, label }: { selected: AnimeCategory | null; onPick: (c: AnimeCategory | null) => void; showAny?: boolean; label?: string }) {
  const model = useModel();
  useEffect(() => { void model.loadCategories(); }, [model]);
  const featured = model.featuredCategories;
  type V = AnimeCategory | null | "all";
  const items: Parameters<typeof Dropdown<V>>[0]["items"] = [];
  if (showAny) items.push({ value: null, label: "Any category", selected: selected === null }, "divider");
  items.push({ section: "Genres" });
  for (const c of featured.filter((c) => c.kind === "genre")) items.push({ value: c, label: c.name, selected: !!selected && categoryId(selected) === categoryId(c) });
  items.push({ section: "Tags" });
  for (const c of featured.filter((c) => c.kind === "tag")) items.push({ value: c, label: c.name, selected: !!selected && categoryId(selected) === categoryId(c) });
  items.push("divider", { value: "all", label: "All categories…", icon: "search" });
  return (
    <Dropdown<V> icon="filter" label={label ?? selected?.name ?? "Any category"} items={items}
      onPick={(v) => (v === "all" ? ui.openSheet({ kind: "allCategories", onPick: (c) => onPick(c) }) : onPick(v))} />
  );
}

interface SavedShelves { trending: Media[]; thisSeason: Media[]; nextSeason: Media[]; topRated: Media[]; savedAt: number; seasonKey: string }
const SHELVES_FILE = "discover-shelves-v1";
const SHELVES_MAX_AGE = 6 * 3_600_000;
const seasonKey = () => { const s = currentSeason(); return `${s.season}-${s.year}`; };

export function DiscoverPage({ refreshKey }: { refreshKey: number }) {
  const model = useModel();
  const [query, setQuery] = useState("");
  const [shelves, setShelves] = useState<SavedShelves | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const busy = useRef(false);
  const cur = currentSeason();
  const next = currentSeason(1);

  const fetchShelves = async (behind: boolean) => {
    if (busy.current) return;
    busy.current = true;
    setLoading(true);
    try {
      const results = await model.browseShelves([
        { sort: ["TRENDING_DESC", "POPULARITY_DESC"] },
        { sort: ["POPULARITY_DESC"], season: cur.season, seasonYear: cur.year },
        { sort: ["POPULARITY_DESC"], season: next.season, seasonYear: next.year },
        { sort: ["SCORE_DESC"] },
      ], !behind);
      setShelves((old) => {
        const pick = (i: number, prev?: Media[]) => { const r = results[i]; return r.ok ? r.media : prev ?? []; };
        const fresh: SavedShelves = {
          trending: pick(0, old?.trending), thisSeason: pick(1, old?.thisSeason), nextSeason: pick(2, old?.nextSeason),
          topRated: pick(3, old?.topRated), savedAt: Date.now(), seasonKey: seasonKey(),
        };
        const failures = results.filter((r) => !r.ok);
        const complete = fresh.trending.length && fresh.thisSeason.length && fresh.nextSeason.length && fresh.topRated.length;
        if (complete && failures.length < results.length) void DiskCache.save(SHELVES_FILE, failures.length ? { ...fresh, savedAt: 0 } : fresh);
        const real = failures.map((f) => (f as { error: unknown }).error).filter((e) => !isCancellation(e));
        setError(real.length === results.length && !old?.trending.length ? (real[0] as Error)?.message ?? null : null);
        return fresh;
      });
    } finally {
      busy.current = false;
      setLoading(false);
    }
  };

  useEffect(() => {
    let live = true;
    (async () => {
      const saved = await DiskCache.load<SavedShelves>(SHELVES_FILE);
      if (!live) return;
      if (saved && saved.seasonKey === seasonKey()) setShelves(saved);
      const stale = !saved || Date.now() - saved.savedAt > SHELVES_MAX_AGE;
      if (stale) await fetchShelves(!!saved);
    })();
    return () => { live = false; };
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

  const [lastRefresh, setLastRefresh] = useState(refreshKey);
  useEffect(() => {
    if (refreshKey === lastRefresh) return;
    setLastRefresh(refreshKey);
    void fetchShelves(false);
  }, [refreshKey, lastRefresh]); // eslint-disable-line react-hooks/exhaustive-deps

  // Saved shelves were filtered when saved: hide what you've dismissed or Chinese animation now.
  const visible = (items: Media[]) => items.filter((m) => !model.settings.dismissedPicks.has(m.id) && !(model.settings.hideChinese && m.countryOfOrigin === "CN"));
  const searching = query.trim().length > 0;

  return (
    <div className="page">
      <PageHeader title="Discover" />
      <div className="toolbar-row">
        <SearchField value={query} onChange={setQuery} placeholder="Search anime or a category" />
        {!searching && <CategoryMenu selected={null} label="Categories" onPick={(c) => c && ui.push(model.selectedTab, { kind: "category", category: c })} />}
      </div>
      {searching ? <SearchResults query={query} /> : (
        <>
          {error && <p className="muted pad">{error}</p>}
          {shelves && visible(shelves.trending).length > 0 && <Shelf title="Trending now">{visible(shelves.trending).map((m) => <MediaCard key={m.id} media={m} />)}</Shelf>}
          {shelves && visible(shelves.thisSeason).length > 0 && (
            <Shelf title={`Popular this season · ${capitalized(cur.season)} ${cur.year}`}>{visible(shelves.thisSeason).map((m) => <MediaCard key={m.id} media={m} />)}</Shelf>
          )}
          {shelves && visible(shelves.nextSeason).length > 0 && (
            <Shelf title={`Coming next season · ${capitalized(next.season)} ${next.year}`}>{visible(shelves.nextSeason).map((m) => <MediaCard key={m.id} media={m} />)}</Shelf>
          )}
          {shelves && visible(shelves.topRated).length > 0 && <Shelf title="All-time top rated">{visible(shelves.topRated).map((m) => <MediaCard key={m.id} media={m} />)}</Shelf>}
          {loading && !shelves?.trending.length && <Spinner />}
        </>
      )}
    </div>
  );
}

function SearchResults({ query }: { query: string }) {
  const model = useModel();
  const [category, setCategory] = useState<AnimeCategory | null>(null);
  const [results, setResults] = useState<Media[]>([]);
  const [searching, setSearching] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    const text = query.trim();
    let live = true;
    // Debounce typing so AniList isn't hammered.
    const t = setTimeout(async () => {
      setSearching(true);
      try {
        const found = await model.browse({ search: text, sort: ["SEARCH_MATCH"], category, perPage: 30 });
        if (live) { setResults(found); setError(null); }
      } catch (e) {
        if (live && !isCancellation(e)) { setResults([]); setError(`Check your connection and try again. (${(e as Error).message})`); }
      } finally {
        if (live) setSearching(false);
      }
    }, 450);
    return () => { live = false; clearTimeout(t); };
  }, [query, category, model]);

  const needle = query.trim().toLowerCase();
  const source = model.allCategories.length ? model.allCategories : model.featuredCategories;
  const matching = needle.length >= 3 ? source.filter((c) => c.name.toLowerCase().includes(needle)).slice(0, 4) : [];

  return (
    <div className="search-results">
      <div className="toolbar-row end"><CategoryMenu selected={category} onPick={setCategory} showAny /></div>
      {matching.length > 0 && (
        <div className="group">
          <div className="group-title">Categories</div>
          <div className="chips-wrap">
            {matching.map((c) => (
              <button key={categoryId(c)} className="chip chip-button" onClick={() => ui.push(model.selectedTab, { kind: "category", category: c })}>
                Browse {c.name}
              </button>
            ))}
          </div>
        </div>
      )}
      {searching && !results.length ? <Spinner /> : !results.length ? (
        error ? <Empty icon="info" title="Couldn't search" text={error} /> : <Empty icon="search" title={`No results for “${query.trim()}”`} text="Check the spelling or try a new search." />
      ) : (
        <div className="rows">{results.map((m) => <MediaRow key={m.id} media={m} />)}</div>
      )}
    </div>
  );
}

const SORTS = [
  { id: "popular", label: "Most popular", api: ["POPULARITY_DESC"] },
  { id: "top", label: "Top rated", api: ["SCORE_DESC"] },
  { id: "trending", label: "Trending", api: ["TRENDING_DESC", "POPULARITY_DESC"] },
  { id: "newest", label: "Newest", api: ["START_DATE_DESC"] },
] as const;

/** One category with sorting, endless scrolling, and search inside the category. */
export function CategoryPage({ category, back }: { category: AnimeCategory; back: () => void }) {
  const model = useModel();
  const [sort, setSort] = useState<(typeof SORTS)[number]["id"]>("popular");
  const [search, setSearch] = useState("");
  const [items, setItems] = useState<Media[]>([]);
  const [page, setPage] = useState(1);
  const [canLoadMore, setCanLoadMore] = useState(true);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const key = `${sort}|${search}`;
  const keyRef = useRef(key);
  keyRef.current = key;
  const loadingKey = useRef<string | null>(null);

  const loadPage = async (pageNumber: number, reset: boolean) => {
    const k = keyRef.current;
    if (loadingKey.current === k) return;
    loadingKey.current = k;
    setLoading(true);
    try {
      const text = search.trim();
      const result = await model.browsePage({ search: text || undefined, sort: text ? ["SEARCH_MATCH"] : [...SORTS.find((s) => s.id === sort)!.api], category, page: pageNumber, perPage: 30 });
      if (k !== keyRef.current) return;
      setItems((old) => {
        const base = reset ? [] : old;
        const known = new Set(base.map((m) => m.id));
        return [...base, ...result.media.filter((m) => !known.has(m.id))];
      });
      setCanLoadMore(result.hasNextPage);
      setPage(pageNumber + 1);
      setError(null);
    } catch (e) {
      if (isCancellation(e) || k !== keyRef.current) return;
      setError((e as Error).message);
      setCanLoadMore(false);
    } finally {
      if (loadingKey.current === k) loadingKey.current = null;
      setLoading(false);
    }
  };

  useEffect(() => {
    setItems([]);
    setPage(1);
    setCanLoadMore(true);
    setError(null);
    const t = setTimeout(() => void loadPage(1, true), search ? 450 : 0);
    return () => clearTimeout(t);
  }, [key]); // eslint-disable-line react-hooks/exhaustive-deps

  const visible = search ? items : items.filter((m) => !model.settings.dismissedPicks.has(m.id));
  return (
    <div className="page">
      <PageHeader title={category.name} back={back}>
        <Dropdown icon="sort" label={SORTS.find((s) => s.id === sort)!.label} onPick={(v: (typeof SORTS)[number]["id"]) => setSort(v)}
          items={SORTS.map((s) => ({ value: s.id, label: s.label, selected: s.id === sort }))} />
      </PageHeader>
      <div className="toolbar-row"><SearchField value={search} onChange={setSearch} placeholder={`Search in ${category.name}`} /></div>
      <div className="rows">{visible.map((m) => <MediaRow key={m.id} media={m} />)}</div>
      {loading && <Spinner />}
      {!loading && !items.length && <Empty icon="search" title={error ? "Couldn't load" : "Nothing found"} text={error ?? "Try another sort or search."} />}
      <LoadMore active={canLoadMore && !loading && !error && items.length > 0} onVisible={() => void loadPage(page, false)} />
    </div>
  );
}
