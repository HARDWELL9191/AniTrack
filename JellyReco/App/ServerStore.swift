import Foundation
import Security

/// Access tokens live in the Keychain; everything else about saved servers in UserDefaults.
enum Keychain {
    private static let service = "com.tim.jellyreco.tokens"

    static func set(_ value: String?, for account: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard let value, let data = value.data(using: .utf8) else { return }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

struct SavedUser: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var imageTag: String?
    var isAdmin: Bool
    var tokenAccount: String { "user-\(id)" }
}

struct SavedServer: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var urls: [String]          // first = current; others are alternates (LAN / remote)
    var version: String?
    var users: [SavedUser]

    var url: URL? { urls.first.flatMap(URL.init(string:)) }
}

/// Every server and user signed in on this iPhone (switch between them without signing in again).
@Observable
final class ServerStore {
    private(set) var servers: [SavedServer] = []
    var currentServerId: String? { didSet { persist() } }
    var currentUserId: String? { didSet { persist() } }

    private let key = "jellyreco.servers"

    init() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: key), let list = try? JSONDecoder().decode([SavedServer].self, from: data) {
            servers = list
        }
        currentServerId = d.string(forKey: key + ".server")
        currentUserId = d.string(forKey: key + ".user")
    }

    private func persist() {
        let d = UserDefaults.standard
        if let data = try? JSONEncoder().encode(servers) { d.set(data, forKey: key) }
        d.set(currentServerId, forKey: key + ".server")
        d.set(currentUserId, forKey: key + ".user")
    }

    var currentServer: SavedServer? { servers.first { $0.id == currentServerId } }
    var currentUser: SavedUser? { currentServer?.users.first { $0.id == currentUserId } }

    func token(for user: SavedUser) -> String? { Keychain.get(user.tokenAccount) }

    func upsert(server info: PublicSystemInfo, url: URL) -> SavedServer {
        let id = info.id ?? url.absoluteString
        if let index = servers.firstIndex(where: { $0.id == id }) {
            var s = servers[index]
            s.name = info.serverName ?? s.name
            s.version = info.version
            let u = url.absoluteString
            s.urls.removeAll { $0 == u }
            s.urls.insert(u, at: 0)
            servers[index] = s
            persist()
            return s
        }
        let s = SavedServer(id: id, name: info.serverName ?? url.host ?? "Jellyfin", urls: [url.absoluteString],
                            version: info.version, users: [])
        servers.append(s)
        persist()
        return s
    }

    func addUser(_ user: UserDto, token: String, to serverId: String) {
        guard let index = servers.firstIndex(where: { $0.id == serverId }) else { return }
        let saved = SavedUser(id: user.id, name: user.name ?? "User", imageTag: user.primaryImageTag,
                              isAdmin: user.policy?.isAdministrator ?? false)
        servers[index].users.removeAll { $0.id == user.id }
        servers[index].users.append(saved)
        Keychain.set(token, for: saved.tokenAccount)
        currentServerId = serverId
        currentUserId = user.id
        persist()
    }

    func updateUser(_ user: UserDto, on serverId: String) {
        guard let s = servers.firstIndex(where: { $0.id == serverId }),
              let u = servers[s].users.firstIndex(where: { $0.id == user.id }) else { return }
        servers[s].users[u].name = user.name ?? servers[s].users[u].name
        servers[s].users[u].imageTag = user.primaryImageTag
        servers[s].users[u].isAdmin = user.policy?.isAdministrator ?? false
        persist()
    }

    func removeUser(_ userId: String, from serverId: String) {
        guard let index = servers.firstIndex(where: { $0.id == serverId }) else { return }
        if let user = servers[index].users.first(where: { $0.id == userId }) { Keychain.set(nil, for: user.tokenAccount) }
        servers[index].users.removeAll { $0.id == userId }
        if currentUserId == userId { currentUserId = nil }
        persist()
    }

    func removeServer(_ serverId: String) {
        guard let server = servers.first(where: { $0.id == serverId }) else { return }
        for u in server.users { Keychain.set(nil, for: u.tokenAccount) }
        servers.removeAll { $0.id == serverId }
        if currentServerId == serverId { currentServerId = nil; currentUserId = nil }
        persist()
    }

    func setURLs(_ urls: [String], for serverId: String) {
        guard let index = servers.firstIndex(where: { $0.id == serverId }), !urls.isEmpty else { return }
        servers[index].urls = urls
        persist()
    }
}
