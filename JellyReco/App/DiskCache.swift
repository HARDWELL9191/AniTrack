import Foundation

/// Small JSON cache in the app's Caches folder (iOS may clear it when storage is low; that's fine).
enum DiskCache {
    private static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }

    /// Serial background queue so big writes (a 1,000-show list is several MB) never block scrolling.
    private static let queue = DispatchQueue(label: "JellyReco.DiskCache", qos: .utility)

    static func save<T: Encodable>(_ value: T, name: String) {
        let url = directory.appendingPathComponent("\(name).json")
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Encodes and writes off the main thread.
    static func saveInBackground<T: Encodable>(_ value: T, name: String) {
        queue.async { save(value, name: name) }
    }

    static func load<T: Decodable>(_ type: T.Type, name: String) -> T? {
        let url = directory.appendingPathComponent("\(name).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// Reads and decodes off the main thread.
    static func loadInBackground<T: Decodable>(_ type: T.Type, name: String) async -> T? {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: load(type, name: name)) }
        }
    }

    /// Log-out: removes only what belongs to an account (your list, picks, fan signals, profile).
    /// Show data that's the same for everyone (AI analysis, age ratings, episodes, categories)
    /// stays, so logging back in doesn't redo that work.
    static func clearPersonal() {
        queue.async {
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
            let personal = ["home-", "reco-", "lib-"]
            for file in files where file.pathExtension == "json" {
                let name = file.deletingPathExtension().lastPathComponent
                if personal.contains(where: { name.hasPrefix($0) }) { try? fm.removeItem(at: file) }
            }
        }
    }

    static func clearAll() {
        queue.async {
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
            for file in files where ["json", "bin"].contains(file.pathExtension) { try? fm.removeItem(at: file) }
        }
    }
}
