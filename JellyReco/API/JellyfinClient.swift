import Foundation
import UIKit

enum JellyfinError: LocalizedError {
    case badURL
    case http(Int, String?)
    case notLoggedIn
    case decoding(String)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .badURL: return "That server address doesn't look right."
        case .http(401, _): return "Your session has expired. Sign in again."
        case .http(403, _): return "Your account isn't allowed to do that on this server."
        case .http(404, _): return "Not found on the server."
        case .http(let code, let body):
            if let body, !body.isEmpty, body.count < 300 { return "Server error \(code): \(body)" }
            return "Server error \(code)."
        case .notLoggedIn: return "Not signed in."
        case .decoding(let what): return "Unexpected server response (\(what))."
        case .message(let m): return m
        }
    }
}

/// Talks to one Jellyfin server as one user. Hand-written on URLSession; routes follow the
/// current Jellyfin API (10.10/10.11: user-scoped routes take `userId` as a query parameter).
final class JellyfinClient: @unchecked Sendable {
    static let clientName = "JellyReco"
    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    /// One id per install, kept in UserDefaults so the server sees one device.
    static let deviceId: String = {
        let key = "jellyreco.deviceId"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }()

    static var deviceName: String {
        UIDevice.current.name.isEmpty ? "iPhone" : UIDevice.current.name
    }

    let baseURL: URL
    var token: String?
    var userId: String?

    private let session: URLSession

    init(baseURL: URL, token: String? = nil, userId: String? = nil) {
        self.baseURL = baseURL
        self.token = token
        self.userId = userId
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 120
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: config)
    }

    /// Normalizes what the user typed ("jelly.local:8096" → "http://jelly.local:8096").
    static func normalize(_ text: String) -> URL? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        if s.lowercased().hasSuffix("/web/index.html") { s = String(s.dropLast("/web/index.html".count)) }
        if s.lowercased().hasSuffix("/web") { s = String(s.dropLast(4)) }
        guard let url = URL(string: s), url.host != nil else { return nil }
        return url
    }

    // MARK: Headers

    var authorizationHeader: String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\"", with: "'")
                .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
        }
        var parts = [
            "Client=\"\(Self.clientName)\"",
            "Device=\"\(esc(Self.deviceName))\"",
            "DeviceId=\"\(Self.deviceId)\"",
            "Version=\"\(Self.appVersion)\"",
        ]
        if let token { parts.append("Token=\"\(token)\"") }
        return "MediaBrowser " + parts.joined(separator: ", ")
    }

    // MARK: URL building

    func url(_ path: String, _ query: [String: Any?] = [:]) -> URL? {
        var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        var items: [URLQueryItem] = []
        for (key, value) in query.sorted(by: { $0.key < $1.key }) {
            guard let value else { continue }
            switch value {
            case let array as [String]:
                guard !array.isEmpty else { continue }
                items.append(URLQueryItem(name: key, value: array.joined(separator: ",")))
            case let b as Bool:
                items.append(URLQueryItem(name: key, value: b ? "true" : "false"))
            default:
                items.append(URLQueryItem(name: key, value: "\(value)"))
            }
        }
        guard var built = comps else { return nil }
        if !items.isEmpty { built.queryItems = items }
        // "+" in values (e.g. search) must be encoded or servers read it as a space.
        let encoded = built.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        built.percentEncodedQuery = encoded
        return built.url
    }

    // MARK: Requests

    @discardableResult
    func send(_ method: String, _ path: String, query: [String: Any?] = [:], body: Data? = nil,
              timeout: TimeInterval? = nil) async throws -> Data {
        guard let url = url(path, query) else { throw JellyfinError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let timeout { request.timeoutInterval = timeout }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw JellyfinError.http(0, nil) }
        guard (200..<300).contains(http.statusCode) else {
            throw JellyfinError.http(http.statusCode, String(data: data, encoding: .utf8))
        }
        return data
    }

    func get<T: Decodable>(_ path: String, _ query: [String: Any?] = [:], as type: T.Type = T.self) async throws -> T {
        let data = try await send("GET", path, query: query)
        return try decode(data)
    }

    func post<T: Decodable>(_ path: String, query: [String: Any?] = [:], json: some Encodable,
                            as type: T.Type = T.self) async throws -> T {
        let body = try JSONCoding.encoder.encode(json)
        let data = try await send("POST", path, query: query, body: body)
        return try decode(data)
    }

    func postVoid<B: Encodable>(_ path: String, query: [String: Any?] = [:], json: B) async throws {
        let body = try JSONCoding.encoder.encode(json)
        try await send("POST", path, query: query, body: body)
    }

    func delete(_ path: String, query: [String: Any?] = [:]) async throws {
        try await send("DELETE", path, query: query)
    }

    struct Empty: Codable {}

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try JSONCoding.decoder.decode(T.self, from: data)
        } catch let DecodingError.keyNotFound(key, ctx) {
            throw JellyfinError.decoding("missing \(key.stringValue) at \(ctx.codingPath.map(\.stringValue).joined(separator: "."))")
        } catch let DecodingError.typeMismatch(_, ctx) {
            throw JellyfinError.decoding("type at \(ctx.codingPath.map(\.stringValue).joined(separator: "."))")
        } catch {
            throw JellyfinError.decoding(String(describing: T.self))
        }
    }

    private func requireUser() throws -> String {
        guard let userId else { throw JellyfinError.notLoggedIn }
        return userId
    }

    // MARK: Server & auth

    func publicInfo() async throws -> PublicSystemInfo {
        try await get("/System/Info/Public")
    }

    func publicUsers() async throws -> [UserDto] {
        try await get("/Users/Public")
    }

    func authenticate(username: String, password: String) async throws -> AuthenticationResult {
        struct Body: Encodable { let username: String; let pw: String }
        return try await post("/Users/AuthenticateByName", json: Body(username: username, pw: password))
    }

    func quickConnectEnabled() async -> Bool {
        (try? await get("/QuickConnect/Enabled", as: Bool.self)) ?? false
    }

    func quickConnectInitiate() async throws -> QuickConnectResult {
        let data = try await send("POST", "/QuickConnect/Initiate")
        return try decode(data)
    }

    func quickConnectState(secret: String) async throws -> QuickConnectResult {
        try await get("/QuickConnect/Connect", ["secret": secret])
    }

    func authenticateQuickConnect(secret: String) async throws -> AuthenticationResult {
        struct Body: Encodable { let secret: String }
        return try await post("/Users/AuthenticateWithQuickConnect", json: Body(secret: secret))
    }

    /// Approve a Quick Connect code shown on another device (signed-in users).
    func authorizeQuickConnect(code: String) async throws {
        try await send("POST", "/QuickConnect/Authorize", query: ["code": code, "userId": userId])
    }

    func logout() async {
        _ = try? await send("POST", "/Sessions/Logout", timeout: 5)
    }

    func me() async throws -> UserDto {
        try await get("/Users/Me")
    }

    func updateUserConfiguration(_ config: UserConfiguration) async throws {
        try await postVoid("/Users/Configuration", query: ["userId": try requireUser()], json: config)
    }

    /// Tell the server what this client can do (needed for remote control and the dashboard).
    func reportCapabilities() async {
        struct Caps: Encodable {
            var playableMediaTypes = ["Video", "Audio"]
            var supportedCommands = ["DisplayMessage", "SetAudioStreamIndex", "SetSubtitleStreamIndex"]
            var supportsMediaControl = false
            var supportsPersistentIdentifier = true
        }
        _ = try? await send("POST", "/Sessions/Capabilities/Full", body: try? JSONCoding.encoder.encode(Caps()))
    }

    // MARK: Fields

    static let listFields = [
        "PrimaryImageAspectRatio", "Overview", "Genres", "Tags", "ProductionYear", "PremiereDate",
        "OfficialRating", "CommunityRating", "RunTimeTicks", "ChildCount", "RecursiveItemCount",
        "SeriesPrimaryImageTag", "ParentId", "Status", "EndDate", "Studios", "DateCreated",
    ]
    static let detailFields = listFields + [
        "People", "Taglines", "ProviderIds", "ExternalUrls", "RemoteTrailers", "MediaSources",
        "MediaStreams", "Chapters", "Trickplay", "OriginalTitle", "AirTime", "ProductionLocations",
        "Path", "LocalTrailerCount", "Width", "Height", "CustomRating", "CriticRating",
    ]

    // MARK: Browsing

    func userViews() async throws -> [BaseItem] {
        let r: QueryResult<BaseItem> = try await get("/UserViews", ["userId": try requireUser()])
        return r.items ?? []
    }

    struct ItemQuery {
        var parentId: String?
        var includeItemTypes: [ItemKind] = []
        var excludeItemTypes: [ItemKind] = []
        var recursive = true
        var sortBy: [String] = ["SortName"]
        var sortOrder = "Ascending"
        var filters: [String] = []          // IsPlayed, IsUnplayed, IsFavorite, IsResumable
        var genres: [String] = []
        var tags: [String] = []
        var years: [Int] = []
        var officialRatings: [String] = []
        var studioIds: [String] = []
        var personIds: [String] = []
        var searchTerm: String?
        var nameStartsWith: String?
        var nameLessThan: String?
        var startIndex = 0
        var limit: Int? = 100
        var fields: [String] = JellyfinClient.listFields
        var ids: [String] = []
        var isMissing: Bool? = false
        var hasOverview: Bool?
        var enableUserData = true
        var imageTypeLimit = 1
    }

    func items(_ q: ItemQuery) async throws -> QueryResult<BaseItem> {
        var query: [String: Any?] = [
            "userId": try requireUser(),
            "parentId": q.parentId,
            "includeItemTypes": q.includeItemTypes.map(\.rawValue),
            "excludeItemTypes": q.excludeItemTypes.map(\.rawValue),
            "recursive": q.recursive,
            "sortBy": q.sortBy,
            "sortOrder": q.sortOrder,
            "filters": q.filters,
            "genres": q.genres.isEmpty ? nil : q.genres.joined(separator: "|"),
            "tags": q.tags.isEmpty ? nil : q.tags.joined(separator: "|"),
            "years": q.years.map(String.init),
            "officialRatings": q.officialRatings.isEmpty ? nil : q.officialRatings.joined(separator: "|"),
            "studioIds": q.studioIds.isEmpty ? nil : q.studioIds.joined(separator: "|"),
            "personIds": q.personIds.isEmpty ? nil : q.personIds.joined(separator: "|"),
            "searchTerm": q.searchTerm,
            "nameStartsWith": q.nameStartsWith,
            "nameLessThan": q.nameLessThan,
            "startIndex": q.startIndex,
            "limit": q.limit,
            "fields": q.fields,
            "ids": q.ids,
            "enableUserData": q.enableUserData,
            "imageTypeLimit": q.imageTypeLimit,
            "enableImageTypes": ["Primary", "Backdrop", "Thumb", "Logo"],
            "enableTotalRecordCount": true,
        ]
        if let missing = q.isMissing { query["isMissing"] = missing }
        if let hasOverview = q.hasOverview { query["hasOverview"] = hasOverview }
        return try await get("/Items", query)
    }

    func item(_ id: String) async throws -> BaseItem {
        try await get("/Items/\(id)", ["userId": try requireUser(), "fields": Self.detailFields])
    }

    func latest(parentId: String?, limit: Int = 20) async throws -> [BaseItem] {
        try await get("/Items/Latest", [
            "userId": try requireUser(), "parentId": parentId, "limit": limit,
            "fields": Self.listFields, "imageTypeLimit": 1, "enableImageTypes": ["Primary", "Backdrop", "Thumb"],
            "groupItems": true,
        ])
    }

    func resume(limit: Int = 24, mediaTypes: [String] = ["Video"]) async throws -> [BaseItem] {
        let r: QueryResult<BaseItem> = try await get("/UserItems/Resume", [
            "userId": try requireUser(), "limit": limit, "mediaTypes": mediaTypes,
            "fields": Self.listFields, "enableUserData": true, "imageTypeLimit": 1,
            "enableImageTypes": ["Primary", "Backdrop", "Thumb"],
        ])
        return r.items ?? []
    }

    func nextUp(seriesId: String? = nil, limit: Int = 24, enableRewatching: Bool = false,
                maxDaysOld: Int? = nil) async throws -> [BaseItem] {
        var query: [String: Any?] = [
            "userId": try requireUser(), "seriesId": seriesId, "limit": limit,
            "fields": Self.listFields, "enableUserData": true, "enableRewatching": enableRewatching,
            "imageTypeLimit": 1, "enableImageTypes": ["Primary", "Backdrop", "Thumb"],
            "enableResumable": false,
        ]
        if let maxDaysOld {
            query["nextUpDateCutoff"] = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-Double(maxDaysOld) * 86_400))
        }
        let r: QueryResult<BaseItem> = try await get("/Shows/NextUp", query)
        return r.items ?? []
    }

    func seasons(seriesId: String) async throws -> [BaseItem] {
        let r: QueryResult<BaseItem> = try await get("/Shows/\(seriesId)/Seasons", [
            "userId": try requireUser(), "fields": Self.listFields, "enableUserData": true,
        ])
        return r.items ?? []
    }

    func episodes(seriesId: String, seasonId: String? = nil) async throws -> [BaseItem] {
        let r: QueryResult<BaseItem> = try await get("/Shows/\(seriesId)/Episodes", [
            "userId": try requireUser(), "seasonId": seasonId,
            "fields": Self.listFields + ["MediaSources", "Chapters", "Trickplay"],
            "enableUserData": true,
        ])
        return r.items ?? []
    }

    func similar(_ id: String, limit: Int = 20) async throws -> [BaseItem] {
        let r: QueryResult<BaseItem> = try await get("/Items/\(id)/Similar", [
            "userId": try requireUser(), "limit": limit, "fields": Self.listFields,
        ])
        return r.items ?? []
    }

    func specialFeatures(_ id: String) async throws -> [BaseItem] {
        try await get("/Items/\(id)/SpecialFeatures", ["userId": try requireUser()])
    }

    func localTrailers(_ id: String) async throws -> [BaseItem] {
        try await get("/Items/\(id)/LocalTrailers", ["userId": try requireUser()])
    }

    func filters(parentId: String?, types: [ItemKind]) async throws -> QueryFiltersLegacy {
        try await get("/Items/Filters", [
            "userId": try requireUser(), "parentId": parentId, "includeItemTypes": types.map(\.rawValue),
        ])
    }

    func genres(parentId: String?, types: [ItemKind]) async throws -> [BaseItem] {
        let r: QueryResult<BaseItem> = try await get("/Genres", [
            "userId": try requireUser(), "parentId": parentId, "includeItemTypes": types.map(\.rawValue),
            "sortBy": ["SortName"], "recursive": true,
        ])
        return r.items ?? []
    }

    func setPlayed(_ id: String, _ played: Bool) async throws -> UserItemData {
        let path = "/UserPlayedItems/\(id)"
        let data = try await send(played ? "POST" : "DELETE", path, query: ["userId": try requireUser()])
        return (try? decode(data)) ?? UserItemData(played: played)
    }

    func setFavorite(_ id: String, _ favorite: Bool) async throws -> UserItemData {
        let path = "/UserFavoriteItems/\(id)"
        let data = try await send(favorite ? "POST" : "DELETE", path, query: ["userId": try requireUser()])
        return (try? decode(data)) ?? UserItemData(isFavorite: favorite)
    }

    /// Thumbs down (`false`), thumbs up (`true`), or cleared (`nil`): Jellyfin's own like/dislike.
    @discardableResult
    func setLikes(_ id: String, _ likes: Bool?) async throws -> UserItemData {
        let data: Data
        if let likes {
            data = try await send("POST", "/UserItems/\(id)/Rating", query: ["userId": try requireUser(), "likes": likes])
        } else {
            data = try await send("DELETE", "/UserItems/\(id)/Rating", query: ["userId": try requireUser()])
        }
        return (try? decode(data)) ?? UserItemData(likes: likes)
    }

    static let storageClient = "jellyreco"
    static let storageId = "jellyreco-lists"

    func loadAppStorage() async throws -> DisplayPreferencesDto {
        try await get("/DisplayPreferences/\(Self.storageId)", ["userId": try requireUser(), "client": Self.storageClient])
    }

    func saveAppStorage(_ prefs: DisplayPreferencesDto) async throws {
        var body = prefs
        body.client = Self.storageClient
        body.id = body.id ?? Self.storageId
        body.sortBy = body.sortBy ?? "SortName"
        body.sortOrder = body.sortOrder ?? "Ascending"
        body.scrollDirection = body.scrollDirection ?? "Horizontal"
        body.showBackdrop = body.showBackdrop ?? true
        body.showSidebar = body.showSidebar ?? false
        body.rememberIndexing = body.rememberIndexing ?? false
        body.rememberSorting = body.rememberSorting ?? false
        body.primaryImageWidth = body.primaryImageWidth ?? 0
        body.primaryImageHeight = body.primaryImageHeight ?? 0
        try await postVoid("/DisplayPreferences/\(Self.storageId)",
                           query: ["userId": try requireUser(), "client": Self.storageClient], json: body)
    }

    // MARK: Images

    func imageURL(itemId: String, type: String = "Primary", tag: String? = nil, index: Int? = nil,
                  maxWidth: Int, quality: Int = 90) -> URL? {
        let path = index.map { "/Items/\(itemId)/Images/\(type)/\($0)" } ?? "/Items/\(itemId)/Images/\(type)"
        return url(path, ["maxWidth": maxWidth, "quality": quality, "tag": tag])
    }

    func userImageURL(userId: String, tag: String?, maxWidth: Int = 200) -> URL? {
        url("/Users/\(userId)/Images/Primary", ["maxWidth": maxWidth, "tag": tag])
    }

    /// Poster: own Primary, an episode's series poster as a fallback.
    func posterURL(_ item: BaseItem, width: Int = 300) -> URL? {
        if item.kind == .episode, let sid = item.seriesId, let tag = item.seriesPrimaryImageTag {
            return imageURL(itemId: sid, tag: tag, maxWidth: width)
        }
        if let tag = item.primaryTag { return imageURL(itemId: item.id, tag: tag, maxWidth: width) }
        if let sid = item.seriesId { return imageURL(itemId: sid, maxWidth: width) }
        return nil
    }

    /// Landscape still: episode/movie thumb or backdrop, then the series' backdrop.
    func landscapeURL(_ item: BaseItem, width: Int = 640) -> URL? {
        if item.kind == .episode, let tag = item.primaryTag {
            return imageURL(itemId: item.id, tag: tag, maxWidth: width)
        }
        if let tag = item.imageTag("Thumb") { return imageURL(itemId: item.id, type: "Thumb", tag: tag, maxWidth: width) }
        if let tag = item.backdropImageTags?.first { return imageURL(itemId: item.id, type: "Backdrop", tag: tag, index: 0, maxWidth: width) }
        if let pid = item.parentThumbItemId, let tag = item.parentThumbImageTag {
            return imageURL(itemId: pid, type: "Thumb", tag: tag, maxWidth: width)
        }
        if let pid = item.parentBackdropItemId, let tag = item.parentBackdropImageTags?.first {
            return imageURL(itemId: pid, type: "Backdrop", tag: tag, index: 0, maxWidth: width)
        }
        return posterURL(item, width: width)
    }

    func backdropURL(_ item: BaseItem, width: Int = 1280) -> URL? {
        if let tag = item.backdropImageTags?.first {
            return imageURL(itemId: item.id, type: "Backdrop", tag: tag, index: 0, maxWidth: width)
        }
        if let pid = item.parentBackdropItemId, let tag = item.parentBackdropImageTags?.first {
            return imageURL(itemId: pid, type: "Backdrop", tag: tag, index: 0, maxWidth: width)
        }
        return nil
    }

    func logoURL(_ item: BaseItem, width: Int = 600) -> URL? {
        if let tag = item.imageTag("Logo") { return imageURL(itemId: item.id, type: "Logo", tag: tag, maxWidth: width) }
        if let pid = item.parentLogoItemId, let tag = item.parentLogoImageTag {
            return imageURL(itemId: pid, type: "Logo", tag: tag, maxWidth: width)
        }
        return nil
    }

    func personImageURL(_ person: PersonInfo, width: Int = 200) -> URL? {
        guard let tag = person.primaryImageTag else { return nil }
        return imageURL(itemId: person.id, tag: tag, maxWidth: width)
    }

    func chapterImageURL(itemId: String, index: Int, tag: String?, width: Int = 400) -> URL? {
        guard let tag else { return nil }
        return url("/Items/\(itemId)/Images/Chapter/\(index)", ["maxWidth": width, "tag": tag])
    }

    func trickplayTileURL(itemId: String, mediaSourceId: String, width: Int, index: Int) -> URL? {
        url("/Videos/\(itemId)/Trickplay/\(width)/\(index).jpg", ["mediaSourceId": mediaSourceId, "ApiKey": token])
    }

    // MARK: Playback

    struct PlaybackInfoRequest: Encodable {
        var userId: String
        var maxStreamingBitrate: Int?
        var startTimeTicks: Int64?
        var audioStreamIndex: Int?
        var subtitleStreamIndex: Int?
        var maxAudioChannels: Int?
        var mediaSourceId: String?
        var deviceProfile: DeviceProfile
        var enableDirectPlay: Bool
        var enableDirectStream: Bool
        var enableTranscoding: Bool
        var allowVideoStreamCopy: Bool
        var allowAudioStreamCopy: Bool
        var autoOpenLiveStream: Bool
        var alwaysBurnInSubtitleWhenTranscoding: Bool?
    }

    func playbackInfo(itemId: String, _ request: PlaybackInfoRequest) async throws -> PlaybackInfoResponse {
        try await post("/Items/\(itemId)/PlaybackInfo", query: ["userId": try requireUser()], json: request)
    }

    /// The original file, untouched (mpv and AVPlayer both read it straight off the server).
    func directStreamURL(itemId: String, source: MediaSourceInfo, playSessionId: String?) -> URL? {
        // Live TV and other remote sources: the server's own direct-stream URL when it gives one.
        if let direct = source.directStreamUrl, !direct.isEmpty, source.liveStreamId != nil || source.isRemote == true {
            return absolute(direct)
        }
        let container = source.container?.split(separator: ",").first.map(String.init)
        var query: [String: Any?] = [
            "static": true, "mediaSourceId": source.id, "deviceId": Self.deviceId,
            "playSessionId": playSessionId, "ApiKey": token, "Tag": source.eTag,
        ]
        if let live = source.liveStreamId { query["LiveStreamId"] = live }
        let ext = (container.map { ".\($0)" } ?? "")
        return url("/Videos/\(itemId)/stream" + (source.liveStreamId == nil ? ext : ""), query)
    }

    /// Server-relative URLs (TranscodingUrl, DeliveryUrl) made absolute, with the token attached.
    func absolute(_ relative: String) -> URL? {
        guard var comps = URLComponents(string: relative) else { return nil }
        var items = comps.queryItems ?? []
        if let token, !items.contains(where: { $0.name.lowercased() == "apikey" }) {
            items.append(URLQueryItem(name: "apikey", value: token))
        }
        comps.queryItems = items
        let rel = comps.string ?? relative
        if rel.lowercased().hasPrefix("http") { return URL(string: rel) }
        var base = baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: base + (rel.hasPrefix("/") ? rel : "/" + rel))
    }

    func subtitleURL(itemId: String, sourceId: String, stream: MediaStream, format: String) -> URL? {
        if let delivery = stream.deliveryUrl, !delivery.isEmpty { return absolute(delivery) }
        return url("/Videos/\(itemId)/\(sourceId)/Subtitles/\(stream.index)/0/Stream.\(format)", ["ApiKey": token])
    }

    struct PlaybackReport: Encodable {
        var itemId: String
        var mediaSourceId: String?
        var playSessionId: String?
        var positionTicks: Int64?
        var isPaused: Bool = false
        var isMuted: Bool = false
        var playMethod: String = "DirectPlay"
        var audioStreamIndex: Int?
        var subtitleStreamIndex: Int?
        var canSeek: Bool = true
        var playbackRate: Double?
        var eventName: String?
        var failed: Bool?
    }

    func reportStart(_ r: PlaybackReport) async { _ = try? await postVoid("/Sessions/Playing", json: r) }
    func reportProgress(_ r: PlaybackReport) async { _ = try? await postVoid("/Sessions/Playing/Progress", json: r) }
    func reportStopped(_ r: PlaybackReport) async { _ = try? await postVoid("/Sessions/Playing/Stopped", json: r) }
    func pingSession(_ playSessionId: String) async { _ = try? await send("POST", "/Sessions/Playing/Ping", query: ["playSessionId": playSessionId]) }

    func stopEncoding(playSessionId: String) async {
        _ = try? await send("DELETE", "/Videos/ActiveEncodings", query: ["deviceId": Self.deviceId, "playSessionId": playSessionId])
    }

    func mediaSegments(itemId: String) async -> [MediaSegment] {
        let r: QueryResult<MediaSegment>? = try? await get("/MediaSegments/\(itemId)")
        return r?.items ?? []
    }

    // MARK: Search

    func search(_ term: String, types: [ItemKind], limit: Int = 40) async throws -> [BaseItem] {
        var q = ItemQuery()
        q.searchTerm = term
        q.includeItemTypes = types
        q.sortBy = ["SortName"]
        q.limit = limit
        return try await items(q).items ?? []
    }

    func searchPeople(_ term: String, limit: Int = 20) async throws -> [BaseItem] {
        let r: QueryResult<BaseItem> = try await get("/Persons", [
            "userId": try requireUser(), "searchTerm": term, "limit": limit, "enableImageTypes": ["Primary"],
        ])
        return r.items ?? []
    }

    // MARK: Live TV

    func liveChannels() async throws -> [BaseItem] {
        let r: QueryResult<BaseItem> = try await get("/LiveTv/Channels", [
            "userId": try requireUser(), "addCurrentProgram": true, "enableImageTypes": ["Primary"],
            "sortBy": ["SortName"], "enableFavoriteSorting": true,
        ])
        return r.items ?? []
    }

    func liveTvInfoAvailable() async -> Bool {
        struct Info: Codable { var isEnabled: Bool? }
        let info: Info? = try? await get("/LiveTv/Info")
        return info?.isEnabled ?? false
    }

    func programs(channelIds: [String], hours: Double = 12) async throws -> [BaseItem] {
        let fmt = ISO8601DateFormatter()
        let r: QueryResult<BaseItem> = try await get("/LiveTv/Programs", [
            "userId": try requireUser(), "channelIds": channelIds,
            "maxStartDate": fmt.string(from: Date().addingTimeInterval(hours * 3600)),
            "minEndDate": fmt.string(from: Date()), "sortBy": ["StartDate"], "limit": 500,
        ])
        return r.items ?? []
    }
}

/// The only way the AI reaches your server: read requests (GET) only. The recommendation
/// engines hold this, never the full client, so they cannot change, move or delete anything.
struct LibraryReader {
    private let client: JellyfinClient
    init(_ client: JellyfinClient) { self.client = client }

    var userId: String? { client.userId }
    func items(_ q: JellyfinClient.ItemQuery) async throws -> QueryResult<BaseItem> { try await client.items(q) }
    func similar(_ id: String, limit: Int) async throws -> [BaseItem] { try await client.similar(id, limit: limit) }
    func item(_ id: String) async throws -> BaseItem { try await client.item(id) }
}
