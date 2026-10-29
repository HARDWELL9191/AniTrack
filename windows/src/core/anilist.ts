// Minimal GraphQL client for https://graphql.anilist.co (port of AniListClient.swift).

export type FetchLike = (url: string, init: { method?: string; headers?: Record<string, string>; body?: string; signal?: AbortSignal }) =>
  Promise<{ status: number; headers: { get(name: string): string | null }; text(): Promise<string> }>;

let httpFetch: FetchLike = (url, init) => fetch(url, init) as never;

/** The app swaps in Tauri's HTTP plugin (no browser CORS limits); tests use Node's fetch. */
export function setFetch(f: FetchLike) {
  httpFetch = f;
}
export const getFetch = () => httpFetch;

export class APIError extends Error {
  constructor(message: string, readonly kind: "graphql" | "http" | "empty" | "rateLimited", readonly status = 0) {
    super(message);
  }
}

export const isCancellation = (e: unknown) => e instanceof DOMException && e.name === "AbortError";

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

export class AniListClient {
  static endpoint = "https://graphql.anilist.co";
  token: string | null = null;

  /** `waitOnRateLimit: false`: when AniList says "too many requests", fail right away. */
  async run<T>(query: string, variables: Record<string, unknown> = {}, opts: { waitOnRateLimit?: boolean; signal?: AbortSignal } = {}): Promise<T> {
    const waitOnRateLimit = opts.waitOnRateLimit ?? true;
    const isMutation = query.trim().startsWith("mutation");
    let attempt = 0;
    for (;;) {
      attempt += 1;
      const headers: Record<string, string> = { "Content-Type": "application/json", Accept: "application/json" };
      if (this.token) headers.Authorization = `Bearer ${this.token}`;
      let res;
      try {
        res = await httpFetch(AniListClient.endpoint, {
          method: "POST",
          headers,
          body: JSON.stringify({ query, variables }),
          signal: opts.signal,
        });
      } catch (e) {
        if (isCancellation(e)) throw e;
        // One quiet retry for a dropped connection. Reads only: a change is never sent twice.
        if (attempt < 2 && !isMutation) {
          await sleep(1000);
          continue;
        }
        throw new APIError("Couldn't reach AniList. Check your connection.", "http");
      }
      const status = res.status;
      if (status === 429) {
        if (!waitOnRateLimit || attempt >= 4) throw new APIError("AniList rate limit reached. Try again in a minute.", "rateLimited", 429);
        const retryAfter = Number(res.headers.get("Retry-After")) || 5;
        await sleep(Math.min(retryAfter, 65) * 1000);
        continue;
      }
      const text = await res.text();
      let decoded: { data?: T | null; errors?: { message: string }[] };
      try {
        decoded = JSON.parse(text);
      } catch {
        if (status >= 400) throw new APIError(`AniList returned HTTP ${status}.`, "http", status);
        throw new APIError("AniList returned no data.", "empty", status);
      }
      if (decoded.data) return decoded.data;
      if (decoded.errors?.length) throw new APIError(decoded.errors.map((e) => e.message).join("\n"), "graphql", status);
      if (status >= 400) throw new APIError(`AniList returned HTTP ${status}.`, "http", status);
      throw new APIError("AniList returned no data.", "empty", status);
    }
  }
}

export function isAuthError(e: unknown): boolean {
  if (!(e instanceof APIError)) return false;
  if (e.kind === "http" && e.status === 401) return true;
  if (e.kind === "graphql") {
    const m = e.message.toLowerCase();
    return m.includes("invalid token") || m.includes("unauthorized");
  }
  return false;
}

// MARK: Queries

const mediaFragment = `
fragment media on Media {
  id
  idMal
  title { romaji english native userPreferred }
  coverImage { large extraLarge color }
  bannerImage
  format
  status
  episodes
  duration
  season
  seasonYear
  averageScore
  meanScore
  popularity
  genres
  countryOfOrigin
  isAdult
  siteUrl
  nextAiringEpisode { episode airingAt timeUntilAiring }
  description(asHtml: false)
  tags { name rank isMediaSpoiler category }
}
`;

const relFragment = `
fragment rel on Media {
  relations { edges { relationType node { id type format episodes title { romaji english } } } }
}
`;

const pageArgs = `($page: Int, $perPage: Int, $search: String, $sort: [MediaSort], $season: MediaSeason,
  $seasonYear: Int, $status: MediaStatus, $genres: [String], $tags: [String],
  $excludeIds: [Int], $isAdult: Boolean, $genresNot: [String],
  $popularityLesser: Int, $popularityGreater: Int, $scoreGreater: Int, $formatNot: [MediaFormat])`;

const mediaFilter = `media(type: ANIME, search: $search, sort: $sort, season: $season, seasonYear: $seasonYear,
  status: $status, genre_in: $genres, tag_in: $tags, id_not_in: $excludeIds,
  isAdult: $isAdult, genre_not_in: $genresNot, popularity_lesser: $popularityLesser,
  popularity_greater: $popularityGreater, averageScore_greater: $scoreGreater,
  format_not_in: $formatNot)`;

export const Queries = {
  browseWithRelations: `query ${pageArgs} {
  Page(page: $page, perPage: $perPage) {
    pageInfo { hasNextPage }
    ${mediaFilter} { ...media ...rel }
  }
}` + mediaFragment + relFragment,

  mediaByIds: `query ($ids: [Int], $perPage: Int) {
  Page(page: 1, perPage: $perPage) {
    media(id_in: $ids, type: ANIME) { ...media ...rel }
  }
}` + mediaFragment + relFragment,

  viewer: `query {
  Viewer {
    id name avatar { large } bannerImage
    options { titleLanguage displayAdultContent }
    statistics { anime { count episodesWatched meanScore minutesWatched } }
  }
}`,

  userByName: `query ($name: String) {
  User(name: $name) {
    id name avatar { large } bannerImage
    options { titleLanguage displayAdultContent }
    statistics { anime { count episodesWatched meanScore minutesWatched } }
  }
}`,

  listCollection: `query ($userId: Int) {
  MediaListCollection(userId: $userId, type: ANIME) {
    lists {
      name status isCustomList
      entries {
        id mediaId status score(format: POINT_100) progress updatedAt createdAt
        media { ...media ...rel }
      }
    }
  }
}` + mediaFragment + relFragment,

  seedRecommendations: `query ($ids: [Int], $perPage: Int, $recsPage: Int, $recsPerMedia: Int) {
  Page(page: 1, perPage: $perPage) {
    media(id_in: $ids, type: ANIME) {
      id
      recommendations(sort: RATING_DESC, page: $recsPage, perPage: $recsPerMedia) {
        nodes { rating mediaRecommendation { ...media ...rel } }
      }
    }
  }
}` + mediaFragment + relFragment,

  detail: `query ($id: Int) {
  Media(id: $id) {
    ...media
    studios(isMain: true) { nodes { name } }
    relations {
      edges {
        relationType
        node { id type format episodes title { romaji english native userPreferred } coverImage { large extraLarge color } }
      }
    }
    recommendations(sort: RATING_DESC, page: 1, perPage: 15) {
      nodes { rating mediaRecommendation { ...media ...rel } }
    }
    mediaListEntry { id mediaId status score(format: POINT_100) progress updatedAt }
  }
}` + mediaFragment + relFragment,

  categories: `query {
  GenreCollection
  MediaTagCollection { name category isAdult isGeneralSpoiler }
}`,

  saveEntry: `mutation ($mediaId: Int, $status: MediaListStatus, $progress: Int, $scoreRaw: Int,
  $private: Boolean, $hiddenFromStatusLists: Boolean, $customLists: [String]) {
  SaveMediaListEntry(mediaId: $mediaId, status: $status, progress: $progress, scoreRaw: $scoreRaw,
    private: $private, hiddenFromStatusLists: $hiddenFromStatusLists, customLists: $customLists) {
    id mediaId status score(format: POINT_100) progress updatedAt
  }
}`,

  streamingEpisodes: `query ($id: Int) {
  Media(id: $id) { id streamingEpisodes { title thumbnail url site } }
}`,

  listOptions: `query {
  Viewer { id mediaListOptions { animeList { customLists } } }
}`,

  updateCustomLists: `mutation ($lists: [String]) {
  UpdateUser(animeListOptions: { customLists: $lists }) {
    id mediaListOptions { animeList { customLists } }
  }
}`,

  /** "Not for me": a private entry hidden from your status lists, in the "Not for me" custom list. */
  saveNotForMe: `mutation ($mediaId: Int, $lists: [String]) {
  SaveMediaListEntry(mediaId: $mediaId, status: PLANNING, private: true,
    hiddenFromStatusLists: true, customLists: $lists) { id mediaId }
}`,

  deleteEntry: `mutation ($id: Int) {
  DeleteMediaListEntry(id: $id) { deleted }
}`,
};
