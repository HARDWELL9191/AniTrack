// TMDB (The Movie Database), the For You tab's outside source: recommendations, similar titles
// and discover lists for shows (including anime) and movies. Read only: every call is a GET.
// Needs your free TMDB API key (v3 key) or API read access token (v4), set in Settings → For You.

type FetchFn = (url: string, init?: RequestInit) => Promise<Response>;
let fetchImpl: FetchFn = (url, init) => fetch(url, init);
export const setTmdbFetch = (f: FetchFn) => (fetchImpl = f);

export type TmdbKind = "tv" | "movie";

export interface TmdbItem {
  id: number;
  kind: TmdbKind;
  title: string;
  originalTitle?: string;
  overview: string;
  posterPath?: string | null;
  backdropPath?: string | null;
  genreIds: number[];
  originalLanguage?: string;
  originCountry?: string[];
  date?: string; // first air / release date
  voteAverage: number;
  voteCount: number;
  popularity: number;
}

interface RawItem {
  id: number;
  name?: string;
  title?: string;
  original_name?: string;
  original_title?: string;
  overview?: string;
  poster_path?: string | null;
  backdrop_path?: string | null;
  genre_ids?: number[];
  genres?: { id: number; name: string }[];
  original_language?: string;
  origin_country?: string[];
  first_air_date?: string;
  release_date?: string;
  vote_average?: number;
  vote_count?: number;
  popularity?: number;
  media_type?: string;
}

export interface TmdbDetails extends TmdbItem {
  genres: string[];
  runtime?: number | null;
  seasons?: number | null;
  episodes?: number | null;
  status?: string;
  tagline?: string;
  homepage?: string;
  trailer?: string | null; // YouTube URL
  cast: { name: string; character?: string; profilePath?: string | null }[];
  networks: string[];
  imdbId?: string | null;
  tvdbId?: number | null;
}

export class TmdbError extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

export function poster(path?: string | null, size = "w342") {
  return path ? `https://image.tmdb.org/t/p/${size}${path}` : undefined;
}

export function tmdbUrl(i: { id: number; kind: TmdbKind }) {
  return `https://www.themoviedb.org/${i.kind}/${i.id}`;
}

export class Tmdb {
  private cache = new Map<string, Promise<unknown>>();
  private key: string;
  private language: string;
  constructor(key: string, language = "en-US") {
    this.key = key;
    this.language = language;
  }

  get configured() { return !!this.key.trim(); }

  private async get<T>(path: string, query: Record<string, string | number | boolean | undefined> = {}): Promise<T> {
    const key = this.key.trim();
    if (!key) throw new TmdbError(401, "Add your TMDB API key in Settings → For You.");
    const q = new URLSearchParams();
    // A v4 read access token is a JWT ("eyJ..."); a v3 key is 32 hex characters.
    const bearer = key.startsWith("eyJ");
    if (!bearer) q.set("api_key", key);
    q.set("language", this.language);
    for (const [k, v] of Object.entries(query)) if (v !== undefined && v !== "") q.set(k, String(v));
    const url = `https://api.themoviedb.org/3${path}?${q}`;
    const hit = this.cache.get(url);
    if (hit) return hit as Promise<T>;
    const job = (async () => {
      for (let attempt = 1; ; attempt++) {
        let res: Response;
        try {
          // Never wait forever on one request (a stalled connection would hold up For You).
          res = await fetchImpl(url, { method: "GET", signal: AbortSignal.timeout(20_000), headers: { Accept: "application/json", ...(bearer ? { Authorization: `Bearer ${key}` } : {}) } });
        } catch {
          if (attempt < 3) { await sleep(800 * attempt); continue; }
          throw new TmdbError(0, "Couldn't reach TMDB. Check your connection.");
        }
        if (res.status === 429 && attempt < 4) { await sleep((Number(res.headers.get("Retry-After")) || 2) * 1000); continue; }
        if (res.status === 401) throw new TmdbError(401, "TMDB didn't accept the API key. Check it in Settings → For You.");
        if (!res.ok) throw new TmdbError(res.status, `TMDB answered ${res.status}.`);
        return (await res.json()) as T;
      }
    })();
    this.cache.set(url, job);
    job.catch(() => this.cache.delete(url));
    return job;
  }

  /** Checks the key (Settings shows the result). */
  async check(): Promise<boolean> {
    await this.get("/configuration");
    return true;
  }

  async genres(kind: TmdbKind): Promise<Map<number, string>> {
    const r = await this.get<{ genres: { id: number; name: string }[] }>(`/genre/${kind}/list`);
    return new Map(r.genres.map((g) => [g.id, g.name]));
  }

  async recommendations(kind: TmdbKind, id: number, page = 1): Promise<TmdbItem[]> {
    const r = await this.get<{ results: RawItem[] }>(`/${kind}/${id}/recommendations`, { page });
    return r.results.map((x) => toItem(x, kind));
  }

  async similar(kind: TmdbKind, id: number, page = 1): Promise<TmdbItem[]> {
    const r = await this.get<{ results: RawItem[] }>(`/${kind}/${id}/similar`, { page });
    return r.results.map((x) => toItem(x, kind));
  }

  async discover(kind: TmdbKind, query: Record<string, string | number | boolean | undefined>, page = 1): Promise<TmdbItem[]> {
    const r = await this.get<{ results: RawItem[] }>(`/discover/${kind}`, { include_adult: false, page, ...query });
    return r.results.map((x) => toItem(x, kind));
  }

  /** TMDB id for an IMDb or TVDB id (titles Jellyfin matched with another source). */
  async find(externalId: string, source: "imdb_id" | "tvdb_id"): Promise<{ id: number; kind: TmdbKind } | null> {
    const r = await this.get<{ movie_results: RawItem[]; tv_results: RawItem[] }>(`/find/${encodeURIComponent(externalId)}`, { external_source: source });
    if (r.tv_results[0]) return { id: r.tv_results[0].id, kind: "tv" };
    if (r.movie_results[0]) return { id: r.movie_results[0].id, kind: "movie" };
    return null;
  }

  async details(kind: TmdbKind, id: number): Promise<TmdbDetails> {
    type Raw = RawItem & {
      genres?: { id: number; name: string }[]; runtime?: number; episode_run_time?: number[]; number_of_seasons?: number; number_of_episodes?: number;
      status?: string; tagline?: string; homepage?: string; networks?: { name: string }[]; production_companies?: { name: string }[];
      videos?: { results: { site: string; type: string; key: string; official?: boolean }[] };
      credits?: { cast: { name: string; character?: string; profile_path?: string | null }[] };
      aggregate_credits?: { cast: { name: string; roles?: { character: string }[]; profile_path?: string | null }[] };
      external_ids?: { imdb_id?: string | null; tvdb_id?: number | null };
    };
    const r = await this.get<Raw>(`/${kind}/${id}`, { append_to_response: kind === "tv" ? "videos,aggregate_credits,external_ids" : "videos,credits,external_ids" });
    const base = toItem(r, kind);
    const vids = r.videos?.results ?? [];
    const trailer = vids.find((v) => v.site === "YouTube" && v.type === "Trailer" && v.official) ?? vids.find((v) => v.site === "YouTube" && v.type === "Trailer") ?? vids.find((v) => v.site === "YouTube");
    const cast = kind === "tv"
      ? (r.aggregate_credits?.cast ?? []).slice(0, 16).map((c) => ({ name: c.name, character: c.roles?.[0]?.character, profilePath: c.profile_path }))
      : (r.credits?.cast ?? []).slice(0, 16).map((c) => ({ name: c.name, character: c.character, profilePath: c.profile_path }));
    return {
      ...base,
      genres: (r.genres ?? []).map((g) => g.name),
      runtime: r.runtime ?? r.episode_run_time?.[0] ?? null,
      seasons: r.number_of_seasons ?? null,
      episodes: r.number_of_episodes ?? null,
      status: r.status,
      tagline: r.tagline,
      homepage: r.homepage,
      trailer: trailer ? `https://www.youtube.com/watch?v=${trailer.key}` : null,
      cast,
      networks: (r.networks ?? r.production_companies ?? []).map((n) => n.name).slice(0, 4),
      imdbId: r.external_ids?.imdb_id ?? null,
      tvdbId: r.external_ids?.tvdb_id ?? null,
    };
  }
}

function toItem(x: RawItem, kind: TmdbKind): TmdbItem {
  return {
    id: x.id,
    kind,
    title: x.name ?? x.title ?? "Untitled",
    originalTitle: x.original_name ?? x.original_title,
    overview: x.overview ?? "",
    posterPath: x.poster_path,
    backdropPath: x.backdrop_path,
    genreIds: x.genre_ids ?? x.genres?.map((g) => g.id) ?? [],
    originalLanguage: x.original_language,
    originCountry: x.origin_country,
    date: x.first_air_date ?? x.release_date,
    voteAverage: x.vote_average ?? 0,
    voteCount: x.vote_count ?? 0,
    popularity: x.popularity ?? 0,
  };
}

/** A stable key for lists ("tmdb:tv:1429"). */
export const tmdbKey = (i: { id: number; kind: TmdbKind }) => `tmdb:${i.kind}:${i.id}`;

/** Numeric id for the on-device AI's vector store: negative, so it never meets a Jellyfin-derived
 * id (those are 0 … 2^52). */
export const tmdbVectorId = (i: { id: number; kind: TmdbKind }) => -((i.kind === "tv" ? 1e10 : 2e10) + i.id);
