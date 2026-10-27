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
                guard attempt < 3 else { throw APIError.rateLimited }
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
            media { ...media }
          }
        }
      }
    }
    """ + mediaFragment

    static let browse = """
    query ($page: Int, $perPage: Int, $search: String, $sort: [MediaSort], $season: MediaSeason,
           $seasonYear: Int, $status: MediaStatus, $genres: [String], $tags: [String],
           $excludeIds: [Int], $isAdult: Boolean) {
      Page(page: $page, perPage: $perPage) {
        pageInfo { hasNextPage }
        media(type: ANIME, search: $search, sort: $sort, season: $season, seasonYear: $seasonYear,
              status: $status, genre_in: $genres, tag_in: $tags, id_not_in: $excludeIds,
              isAdult: $isAdult) {
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
              mediaRecommendation { ...media }
            }
          }
        }
      }
    }
    """ + mediaFragment

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
            mediaRecommendation { ...media }
          }
        }
        mediaListEntry { id mediaId status score(format: POINT_100) progress updatedAt }
      }
    }
    """ + mediaFragment

    static let categories = """
    query {
      GenreCollection
      MediaTagCollection { name category isAdult isGeneralSpoiler }
    }
    """

    static let saveEntry = """
    mutation ($mediaId: Int, $status: MediaListStatus, $progress: Int, $scoreRaw: Int) {
      SaveMediaListEntry(mediaId: $mediaId, status: $status, progress: $progress, scoreRaw: $scoreRaw) {
        id
        mediaId
        status
        score(format: POINT_100)
        progress
        updatedAt
      }
    }
    """

    static let deleteEntry = """
    mutation ($id: Int) {
      DeleteMediaListEntry(id: $id) { deleted }
    }
    """
}
