import Foundation

/// One My List entry: a title on your server (by id) or a For You pick that isn't on it yet.
struct MyListEntry: Codable, Hashable, Identifiable {
    var serverId: String?
    var name: String?
    var external: ExternalTitle?
    var addedAt = Date()

    /// Stable: an entry with neither a server id nor a TMDB title (written by another app) used to
    /// get a new random id on every read, so it couldn't be found again to remove it.
    var id: String { serverId.map { "server:\($0)" } ?? external?.id ?? "entry:\(name ?? ""):\(addedAt.timeIntervalSinceReferenceDate)" }

    init(serverId: String, name: String?) {
        self.serverId = serverId
        self.name = name
    }

    init(external: ExternalTitle) {
        self.external = external
        self.name = external.title
    }
}

// Lenient reading: a field another app (or an older version) left out takes its default instead of
// making the entry unreadable. (In an extension, so the initializers above stay as they are.)
extension MyListEntry {
    private enum Keys: String, CodingKey { case serverId, name, external, addedAt }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        serverId = try c.decodeIfPresent(String.self, forKey: .serverId)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        external = try? c.decodeIfPresent(ExternalTitle.self, forKey: .external)
        addedAt = (try? c.decodeIfPresent(Date.self, forKey: .addedAt)) ?? Date(timeIntervalSinceReferenceDate: 0)
        if serverId == nil && external == nil && name == nil {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Empty My List entry"))
        }
    }
}
