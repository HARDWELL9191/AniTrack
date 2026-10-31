// TMDB (themoviedb.org API v3), read only, the same client as the iPhone app's TMDBClient:
// "people who liked this also liked" lists, discover by genre (anime = Animation + Japanese),
// details (keywords, IMDb/TVDB ids), and finding your library's titles by IMDb/TVDB id or title.
// Accepts the long "API Read Access Token" (Bearer header) or the short "API key" (api_key).

import { type ExternalTitle, IMAGE_BASE, titleId, titleKey } from "./titles";
import { deviceRegion, pickCertification } from "./age";

type FetchFn = (url: string, init?: RequestInit) => Promise<Response>;
let fetchImpl: FetchFn = (url, init) => fetch(url, init);
export const setTmdbFetch = (f: FetchFn) => (fetchImpl = f);

export class TmdbError extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

interface Raw {
  id: number; title?: string; name?: string; original_title?: string; original_name?: string; original_language?: string;
  overview?: string; poster_path?: string | null; backdrop_path?: string | null; genre_ids?: number[]; release_date?: string;
  first_air_date?: string; vote_average?: number; vote_count?: number; popularity?: number; adult?: boolean;
}

/** Extra details for the title sheet (cast, trailer, networks). */
export interface TitleExtras {
  title: ExternalTitle;
  tagline?: string;
  homepage?: string;
  trailer?: string | null;
  cast: { name: string; character?: string; profile?: string | null }[];
  networks: string[];
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

export class Tmdb {
  private key: string;
  private genreNames = new Map<number, string>();
  private genresLoaded: Promise<void> | null = null;
  private detailCache = new Map<string, ExternalTitle>();
  succeeded = 0;
  failed = 0;
  lastFailure: string | null = null;

  constructor(key: string) {
    // Pasted keys often carry spaces, line breaks or quotes: keep only the key itself.
    this.key = key.replace(/\s+/g, "").replace(/^["']+|["']+$/g, "");
  }

  get configured() { return !!this.key; }
  private get bearer() { return this.key.length > 40; }
  resetStats() { this.succeeded = 0; this.failed = 0; this.lastFailure = null; }

  private async get<T>(path: string, query: Record<string, string | number | boolean | undefined> = {}): Promise<T> {
    try {
      const v = await this.raw<T>(path, query);
      this.succeeded++;
      return v;
    } catch (e) {
      this.failed++;
      this.lastFailure = (e as Error).message;
      throw e;
    }
  }

  private async raw<T>(path: string, query: Record<string, string | number | boolean | undefined>): Promise<T> {
    if (!this.key) throw new TmdbError(401, "Add your free TMDB API key in Settings → For You.");
    const q = new URLSearchParams();
    for (const [k, v] of Object.entries(query)) if (v !== undefined && v !== "") q.set(k, String(v));
    q.set("language", "en-US");
    if (!this.bearer) q.set("api_key", this.key);
    const url = `https://api.themoviedb.org/3${path}?${q}`;
    for (let attempt = 0; attempt < 4; attempt++) {
      let res: Response;
      try {
        // Never wait forever on one request.
        res = await fetchImpl(url, { method: "GET", signal: AbortSignal.timeout(20_000), headers: { Accept: "application/json", ...(this.bearer ? { Authorization: `Bearer ${this.key}` } : {}) } });
      } catch (e) {
        if (attempt === 0) { await sleep(600); continue; }
        throw new TmdbError(0, `Couldn't reach TMDB: ${(e as Error).message}`);
      }
      if (res.status === 429) { await sleep(Math.min(Number(res.headers.get("Retry-After")) || attempt + 1, 10) * 1000); continue; }
      let message: string | undefined;
      if (!res.ok) { try { message = ((await res.json()) as { status_message?: string }).status_message; } catch { /* */ } }
      if (res.status === 401) throw new TmdbError(401, `TMDB didn't accept the key${message ? `: ${message}` : ""}. Paste the API Read Access Token (the long one) or the API key.`);
      if (!res.ok) throw new TmdbError(res.status, `TMDB error ${res.status}${message ? `: ${message}` : ""}.`);
      return (await res.json()) as T;
    }
    throw new TmdbError(429, "TMDB error 429: Too many requests, try again in a minute.");
  }

  /** Checks the key (Settings and the For You setup card). */
  async check() { await this.get("/configuration"); return true; }

  // MARK: Genres

  loadGenres(): Promise<void> {
    if (!this.genresLoaded) {
      this.genresLoaded = (async () => {
        for (const kind of ["movie", "tv"]) {
          const r = await this.get<{ genres: { id: number; name: string }[] }>(`/genre/${kind}/list`);
          for (const g of r.genres) this.genreNames.set(g.id, g.name);
        }
      })();
      this.genresLoaded.catch(() => { this.genresLoaded = null; });
    }
    return this.genresLoaded;
  }

  /** TV uses combined names ("Action & Adventure", "Sci-Fi & Fantasy"). */
  genreId(name: string): number | null {
    const lower = name.toLowerCase();
    for (const [id, n] of this.genreNames) if (n.toLowerCase() === lower) return id;
    for (const [id, n] of this.genreNames) { const l = n.toLowerCase(); if (l.includes(lower) || lower.includes(l)) return id; }
    return null;
  }

  private convert(r: Raw, tv: boolean): ExternalTitle {
    const date = (tv ? r.first_air_date : r.release_date) ?? "";
    const t: ExternalTitle = {
      source: tv ? "tmdbTV" : "tmdbMovie",
      sourceId: r.id,
      title: (tv ? r.name : r.title) ?? r.name ?? r.title ?? "Untitled",
      overview: r.overview ?? "",
      genres: (r.genre_ids ?? []).map((g) => this.genreNames.get(g)).filter((x): x is string => !!x),
      tags: [],
      isAdult: r.adult ?? false,
    };
    const original = tv ? r.original_name : r.original_title;
    if (original) t.originalTitle = original;
    if (r.original_language) t.originalLanguage = r.original_language;
    const year = Number(date.slice(0, 4));
    if (year) t.year = year;
    if (r.poster_path) t.posterURL = `${IMAGE_BASE}w500${r.poster_path}`;
    if (r.backdrop_path) t.backdropURL = `${IMAGE_BASE}w1280${r.backdrop_path}`;
    if (typeof r.vote_average === "number") t.score = r.vote_average;
    if (typeof r.vote_count === "number") t.voteCount = r.vote_count;
    if (typeof r.popularity === "number") t.popularity = r.popularity;
    return t;
  }

  /** "People who liked this also liked" for one title. */
  async recommendations(tmdbId: number, tv: boolean, page = 1): Promise<ExternalTitle[]> {
    await this.loadGenres();
    const r = await this.get<{ results: Raw[] }>(`/${tv ? "tv" : "movie"}/${tmdbId}/recommendations`, { page });
    return r.results.map((x) => this.convert(x, tv));
  }

  /** Well-rated titles in genres, optionally anime only (Animation + Japanese original language). */
  async discover(o: { tv: boolean; genreIds: number[]; anime: boolean | null; page: number; sort?: string; minVotes?: number }): Promise<ExternalTitle[]> {
    await this.loadGenres();
    const q: Record<string, string | number> = { page: o.page, sort_by: o.sort ?? "vote_average.desc", include_adult: "false", "vote_count.gte": o.minVotes ?? 200 };
    const genres = [...o.genreIds];
    if (o.anime === true) {
      if (!genres.includes(16)) genres.push(16);
      q.with_original_language = "ja";
    } else if (o.anime === false) {
      q.without_genres = "16"; // movie/TV libraries: anime is the anime library's
    }
    if (genres.length) q.with_genres = genres.join(",");
    const r = await this.get<{ results: Raw[] }>(`/discover/${o.tv ? "tv" : "movie"}`, q);
    return r.results.map((x) => this.convert(x, o.tv));
  }

  /** Full details: keywords (tags), IMDb/TVDB ids, seasons, runtime, status. */
  async details(t: ExternalTitle): Promise<ExternalTitle> {
    const key = titleId(t);
    const hit = this.detailCache.get(key);
    if (hit) return hit;
    const tv = t.source === "tmdbTV";
    let json: Record<string, unknown>;
    try { json = await this.get<Record<string, unknown>>(`/${tv ? "tv" : "movie"}/${t.sourceId}`, { append_to_response: tv ? "keywords,external_ids,content_ratings" : "keywords,external_ids,release_dates" }); } catch { return t; }
    const d = { ...t };
    const kw = json.keywords as { keywords?: { name: string }[]; results?: { name: string }[] } | undefined;
    d.tags = (kw?.keywords ?? kw?.results ?? []).map((k) => k.name).filter(Boolean);
    const ext = json.external_ids as { imdb_id?: string | null; tvdb_id?: number | null } | undefined;
    const imdb = ext?.imdb_id ?? (json.imdb_id as string | undefined);
    if (imdb) d.imdbId = imdb;
    if (typeof ext?.tvdb_id === "number") d.tvdbId = ext.tvdb_id;
    if (typeof json.number_of_seasons === "number") d.seasons = json.number_of_seasons;
    if (typeof json.number_of_episodes === "number") d.episodes = json.number_of_episodes;
    if (typeof json.runtime === "number") d.runtime = json.runtime;
    if (typeof json.status === "string") d.status = json.status;
    if (Array.isArray(json.genres)) d.genres = (json.genres as { name: string }[]).map((g) => g.name).filter(Boolean);
    // The age bubble (as on the iPhone): the certification for this device's country, else the US / UK.
    const cert = pickCertification(json, tv, deviceRegion());
    if (cert) { d.ageRating = cert[0]; d.ageRatingCountry = cert[1]; }
    if (this.detailCache.size > 3000) this.detailCache.clear();
    this.detailCache.set(key, d);
    return d;
  }

  /** Details plus cast, trailer and networks for the title sheet. */
  async extras(t: ExternalTitle): Promise<TitleExtras> {
    const tv = t.source === "tmdbTV";
    const json = await this.get<Record<string, unknown>>(`/${tv ? "tv" : "movie"}/${t.sourceId}`, { append_to_response: tv ? "videos,aggregate_credits,external_ids,keywords" : "videos,credits,external_ids,keywords" });
    const title = await this.details(t);
    const vids = ((json.videos as { results?: { site: string; type: string; key: string; official?: boolean }[] })?.results ?? []);
    const trailer = vids.find((v) => v.site === "YouTube" && v.type === "Trailer" && v.official) ?? vids.find((v) => v.site === "YouTube" && v.type === "Trailer") ?? vids.find((v) => v.site === "YouTube");
    type Cast = { name: string; character?: string; roles?: { character: string }[]; profile_path?: string | null };
    const cast = (tv ? (json.aggregate_credits as { cast?: Cast[] })?.cast : (json.credits as { cast?: Cast[] })?.cast) ?? [];
    const nets = ((json.networks ?? json.production_companies) as { name: string }[] | undefined) ?? [];
    return {
      title: { ...title, backdropURL: title.backdropURL ?? (json.backdrop_path ? `${IMAGE_BASE}w1280${json.backdrop_path}` : undefined) },
      tagline: (json.tagline as string) || undefined,
      homepage: (json.homepage as string) || undefined,
      trailer: trailer ? `https://www.youtube.com/watch?v=${trailer.key}` : null,
      cast: cast.slice(0, 16).map((c) => ({ name: c.name, character: c.character ?? c.roles?.[0]?.character, profile: c.profile_path ? `${IMAGE_BASE}w185${c.profile_path}` : null })),
      networks: nets.map((n) => n.name).slice(0, 4),
    };
  }

  // MARK: Finding your library's titles on TMDB

  /** TMDB id for an IMDb or TVDB id. */
  async find(externalId: string, source: "imdb_id" | "tvdb_id", tv: boolean): Promise<number | null> {
    try {
      const r = await this.get<{ tv_results?: { id: number }[]; movie_results?: { id: number }[] }>(`/find/${encodeURIComponent(externalId)}`, { external_source: source });
      return (tv ? r.tv_results : r.movie_results)?.[0]?.id ?? null;
    } catch { return null; }
  }

  /** Best TMDB match for a title and year. */
  async search(title: string, year: number | null | undefined, tv: boolean): Promise<number | null> {
    try {
      const q: Record<string, string | number> = { query: title, include_adult: "false" };
      if (year) q[tv ? "first_air_date_year" : "year"] = year;
      const r = await this.get<{ results: Raw[] }>(`/search/${tv ? "tv" : "movie"}`, q);
      const key = titleKey(title);
      const best = r.results.find((x) => titleKey((x.title ?? x.name) ?? "") === key) ?? r.results[0];
      return best?.id ?? null;
    } catch { return null; }
  }
}
