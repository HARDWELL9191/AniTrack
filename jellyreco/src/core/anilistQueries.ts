// AniList GraphQL queries (the iPhone app's / AniReco's, JellyReco/AniList/AniListClient.swift).

const mediaFragment = `fragment media on Media {
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
}`;
const relFragment = `fragment rel on Media {
  relations { edges { relationType node { id type format episodes title { romaji english } } } }
}`;
const browseWithRelations = `query ($page: Int, $perPage: Int, $search: String, $sort: [MediaSort], $season: MediaSeason,
       $seasonYear: Int, $status: MediaStatus, $genres: [String], $tags: [String],
       $excludeIds: [Int], $isAdult: Boolean, $genresNot: [String],
       $popularityLesser: Int, $popularityGreater: Int, $scoreGreater: Int, $formatNot: [MediaFormat],
       $formatIn: [MediaFormat]) {
  Page(page: $page, perPage: $perPage) {
    pageInfo { hasNextPage }
    media(type: ANIME, search: $search, sort: $sort, season: $season, seasonYear: $seasonYear,
          status: $status, genre_in: $genres, tag_in: $tags, id_not_in: $excludeIds,
          isAdult: $isAdult, genre_not_in: $genresNot, popularity_lesser: $popularityLesser,
          popularity_greater: $popularityGreater, averageScore_greater: $scoreGreater,
          format_not_in: $formatNot, format_in: $formatIn) {
      ...media
      ...rel
    }
  }
}` + mediaFragment + relFragment;
const mediaByIds = `query ($ids: [Int], $perPage: Int) {
  Page(page: 1, perPage: $perPage) {
    media(id_in: $ids, type: ANIME) {
      ...media
      ...rel
    }
  }
}` + mediaFragment + relFragment;
const viewer = `query {
  Viewer {
    id
    name
    avatar { large }
    bannerImage
    options { titleLanguage displayAdultContent }
    statistics { anime { count episodesWatched meanScore minutesWatched } }
  }
}`;
const userByName = `query ($name: String) {
  User(name: $name) {
    id
    name
    avatar { large }
    bannerImage
    options { titleLanguage displayAdultContent }
    statistics { anime { count episodesWatched meanScore minutesWatched } }
  }
}`;
const listCollection = `query ($userId: Int) {
  MediaListCollection(userId: $userId, type: ANIME) {
    lists {
      name
      status
      isCustomList
      entries {
        id
        mediaId
        status
        score(format: POINT_100)
        progress
        updatedAt
        createdAt
        media { ...media ...rel }
      }
    }
  }
}` + mediaFragment + relFragment;
const browse = `query ($page: Int, $perPage: Int, $search: String, $sort: [MediaSort], $season: MediaSeason,
       $seasonYear: Int, $status: MediaStatus, $genres: [String], $tags: [String],
       $excludeIds: [Int], $isAdult: Boolean, $genresNot: [String],
       $popularityLesser: Int, $popularityGreater: Int, $scoreGreater: Int, $formatNot: [MediaFormat]) {
  Page(page: $page, perPage: $perPage) {
    pageInfo { hasNextPage }
    media(type: ANIME, search: $search, sort: $sort, season: $season, seasonYear: $seasonYear,
          status: $status, genre_in: $genres, tag_in: $tags, id_not_in: $excludeIds,
          isAdult: $isAdult, genre_not_in: $genresNot, popularity_lesser: $popularityLesser,
          popularity_greater: $popularityGreater, averageScore_greater: $scoreGreater,
          format_not_in: $formatNot) {
      ...media
    }
  }
}` + mediaFragment;
const seedRecommendations = `query ($ids: [Int], $perPage: Int, $recsPage: Int, $recsPerMedia: Int) {
  Page(page: 1, perPage: $perPage) {
    media(id_in: $ids, type: ANIME) {
      id
      recommendations(sort: RATING_DESC, page: $recsPage, perPage: $recsPerMedia) {
        nodes {
          rating
          mediaRecommendation { ...media ...rel }
        }
      }
    }
  }
}` + mediaFragment + relFragment;
const detail = `query ($id: Int) {
  Media(id: $id) {
    ...media
    studios(isMain: true) { nodes { name } }
    relations {
      edges {
        relationType
        node {
          id
          type
          format
          episodes
          title { romaji english native userPreferred }
          coverImage { large extraLarge color }
        }
      }
    }
    recommendations(sort: RATING_DESC, page: 1, perPage: 15) {
      nodes {
        rating
        mediaRecommendation { ...media ...rel }
      }
    }
    mediaListEntry { id mediaId status score(format: POINT_100) progress updatedAt }
  }
}` + mediaFragment + relFragment;
const categories = `query {
  GenreCollection
  MediaTagCollection { name category isAdult isGeneralSpoiler }
}`;
const saveEntry = `mutation ($mediaId: Int, $status: MediaListStatus, $progress: Int, $scoreRaw: Int,
          $private: Boolean, $hiddenFromStatusLists: Boolean, $customLists: [String]) {
  SaveMediaListEntry(mediaId: $mediaId, status: $status, progress: $progress, scoreRaw: $scoreRaw,
                     private: $private, hiddenFromStatusLists: $hiddenFromStatusLists,
                     customLists: $customLists) {
    id
    mediaId
    status
    score(format: POINT_100)
    progress
    updatedAt
  }
}`;
const listOptions = `query {
  Viewer {
    id
    mediaListOptions { animeList { customLists } }
  }
}`;
const updateCustomLists = `mutation ($lists: [String]) {
  UpdateUser(animeListOptions: { customLists: $lists }) {
    id
    mediaListOptions { animeList { customLists } }
  }
}`;
const saveNotForMe = `mutation ($mediaId: Int, $lists: [String]) {
  SaveMediaListEntry(mediaId: $mediaId, status: PLANNING, private: true,
                     hiddenFromStatusLists: true, customLists: $lists) {
    id
    mediaId
  }
}`;
const deleteEntry = `mutation ($id: Int) {
  DeleteMediaListEntry(id: $id) { deleted }
}`;

export const Queries = { browseWithRelations, mediaByIds, viewer, userByName, listCollection, browse, seedRecommendations, detail, categories, saveEntry, listOptions, updateCustomLists, saveNotForMe, deleteEntry };
