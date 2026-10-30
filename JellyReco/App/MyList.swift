import Foundation

/// One My List entry: a title on your server (by id) or a For You pick that isn't on it yet.
struct MyListEntry: Codable, Hashable, Identifiable {
    var serverId: String?
    var name: String?
    var external: ExternalTitle?
    var addedAt = Date()

    var id: String { serverId.map { "server:\($0)" } ?? external?.id ?? UUID().uuidString }

    init(serverId: String, name: String?) {
        self.serverId = serverId
        self.name = name
    }

    init(external: ExternalTitle) {
        self.external = external
        self.name = external.title
    }
}
