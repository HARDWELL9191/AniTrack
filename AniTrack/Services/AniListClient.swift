import Foundation

enum APIError: LocalizedError {
    case graphQL(String)
    case http(Int)
    case empty
    case rateLimited

    var errorDescription: String? {
        switch self {
        case .graphQL(let message): return message
        case .http(let code): return "AniList returned HTTP \(code)."
        case .empty: return "AniList returned no data."
        case .rateLimited: return "AniList rate limit reached. Try again in a minute."
        }
    }
}

private struct GQLError: Decodable { let message: String }

private struct GQLResponse<T: Decodable>: Decodable {
    let data: T?
    let errors: [GQLError]?
}

/// Minimal GraphQL client for https://graphql.anilist.co
final class AniListClient {
    static let endpoint = URL(string: "https://graphql.anilist.co")!

    var token: String?

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    func run<T: Decodable>(_ query: String,
                           variables: [String: Any] = [:],
                           as type: T.Type) async throws -> T {
        var attempt = 0
        while true {
            attempt += 1
            var request = URLRequest(url: Self.endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let token, !token.isEmpty {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "query": query,
                "variables": variables
            ])

            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0

            if status == 429 {
                guard attempt < 4 else { throw APIError.rateLimited }
                let retryAfter = (response as? HTTPURLResponse)?
                    .value(forHTTPHeaderField: "Retry-After")
                    .flatMap(Double.init) ?? 5
                try await Task.sleep(nanoseconds: UInt64(min(retryAfter, 65) * 1_000_000_000))
                continue
            }

            let decoded: GQLResponse<T>
            do {
                decoded = try JSONDecoder().decode(GQLResponse<T>.self, from: data)
            } catch {
                if status >= 400 { throw APIError.http(status) }
                throw error
            }

            if let result = decoded.data { return result }
            if let errors = decoded.errors, !errors.isEmpty {
                throw APIError.graphQL(errors.map(\.message).joined(separator: "\n"))
            }
            if status >= 400 { throw APIError.http(status) }
            throw APIError.empty
        }
    }
}

// MARK: - Queries

enum Queries {
    static let mediaFragment = """
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
    """

    /// Small extra fragment for suggestion queries only: linked shows' format and title,
    /// enough to tell a numbered season apart from a movie, OVA or renamed sequel.
    static let relFragment = """
    fragment rel on Media {
      relations { edges { relationType node { id type format title { romaji english } } } }
    }
    """

    /// Same as `browse`, plus relations, for suggestion shelves and the recommender.
    static let browseWithRelations = """
    query ($page: Int, $perPage: Int, $search: String, $sort: [MediaSort], $season: MediaSeason,
           $seasonYear: Int, $status: MediaStatus, $genres: [String], $tags: [String],
           $excludeIds: [Int], $isAdult: Boolean, $genresNot: [String],
           $popularityLesser: Int, $popularityGreater: Int, $scoreGreater: Int) {
      Page(page: $page, perPage: $perPage) {
        pageInfo { hasNextPage }
        media(type: ANIME, search: $search, sort: $sort, season: $season, seasonYear: $seasonYear,
              status: $status, genre_in: $genres, tag_in: $tags, id_not_in: $excludeIds,
              isAdult: $isAdult, genre_not_in: $genresNot, popularity_lesser: $popularityLesser,
              popularity_greater: $popularityGreater, averageScore_greater: $scoreGreater) {
          ...media
          ...rel
        }
      }
    }
    """ + mediaFragment + relFragment

    /// Full media + relations for a set of ids (used to walk back to a show's first season).
    static let mediaByIds = """
    query ($ids: [Int], $perPage: Int) {
      Page(page: 1, perPage: $perPage) {
        media(id_in: $ids, type: ANIME) {
          ...media
          ...rel
        }
      }
    }
    """ + mediaFragment + relFragment

    static let viewer = """
    query {
      Viewer {
        id
        name
        avatar { large }
        bannerImage
        options { titleLanguage displayAdultContent }
        statistics { anime { count episodesWatched meanScore minutesWatched } }
      }
    }
    """

    static let userByName = """
    query ($name: String) {
      User(name: $name) {
        id
        name
        avatar { large }
        bannerImage
        options { titleLanguage displayAdultContent }
        statistics { anime { count episodesWatched meanScore minutesWatched } }
      }
    }
    """

    static let listCollection = """
    query ($userId: Int) {
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
            media { ...media }
          }
        }
      }
    }
    """ + mediaFragment

    static let browse = """
    query ($page: Int, $perPage: Int, $search: String, $sort: [MediaSort], $season: MediaSeason,
           $seasonYear: Int, $status: MediaStatus, $genres: [String], $tags: [String],
           $excludeIds: [Int], $isAdult: Boolean, $genresNot: [String],
           $popularityLesser: Int, $popularityGreater: Int, $scoreGreater: Int) {
      Page(page: $page, perPage: $perPage) {
        pageInfo { hasNextPage }
        media(type: ANIME, search: $search, sort: $sort, season: $season, seasonYear: $seasonYear,
              status: $status, genre_in: $genres, tag_in: $tags, id_not_in: $excludeIds,
              isAdult: $isAdult, genre_not_in: $genresNot, popularity_lesser: $popularityLesser,
              popularity_greater: $popularityGreater, averageScore_greater: $scoreGreater) {
          ...media
        }
      }
    }
    """ + mediaFragment

    static let seedRecommendations = """
    query ($ids: [Int], $perPage: Int, $recsPage: Int, $recsPerMedia: Int) {
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
    }
    """ + mediaFragment + relFragment

    static let detail = """
    query ($id: Int) {
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
    }
    """ + mediaFragment + relFragment

    static let categories = """
    query {
      GenreCollection
      MediaTagCollection { name category isAdult isGeneralSpoiler }
    }
    """

    static let saveEntry = """
    mutation ($mediaId: Int, $status: MediaListStatus, $progress: Int, $scoreRaw: Int,
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
    }
    """

    /// Episode titles and thumbnails from official streaming sites (mostly Crunchyroll).
    static let streamingEpisodes = """
    query ($id: Int) {
      Media(id: $id) {
        id
        streamingEpisodes { title thumbnail url site }
      }
    }
    """

    /// Your anime custom list names (needed before adding "Not for me", so none are lost).
    static let listOptions = """
    query {
      Viewer {
        id
        mediaListOptions { animeList { customLists } }
      }
    }
    """

    static let updateCustomLists = """
    mutation ($lists: [String]) {
      UpdateUser(animeListOptions: { customLists: $lists }) {
        id
        mediaListOptions { animeList { customLists } }
      }
    }
    """

    /// "Not for me": a private entry (only you can see it, nothing on your followers' feed),
    /// hidden from your normal status lists, filed under the "Not for me" custom list.
    static let saveNotForMe = """
    mutation ($mediaId: Int, $lists: [String]) {
      SaveMediaListEntry(mediaId: $mediaId, status: PLANNING, private: true,
                         hiddenFromStatusLists: true, customLists: $lists) {
        id
        mediaId
      }
    }
    """

    static let deleteEntry = """
    mutation ($id: Int) {
      DeleteMediaListEntry(id: $id) { deleted }
    }
    """
}
