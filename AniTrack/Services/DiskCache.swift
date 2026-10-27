import Foundation

/// Small JSON cache in the app's Caches folder (iOS may clear it when storage is low; that's fine).
enum DiskCache {
    private static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }

    static func save<T: Encodable>(_ value: T, name: String) {
        let url = directory.appendingPathComponent("\(name).json")
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func load<T: Decodable>(_ type: T.Type, name: String) -> T? {
        let url = directory.appendingPathComponent("\(name).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func clearAll() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "json" { try? fm.removeItem(at: file) }
    }
}
