import Foundation
import Observation

enum AccountMode: Equatable {
    case none
    case loggedIn
    case username(String)
}

/// User-facing preferences, persisted in UserDefaults.
@Observable
final class AppSettings {
    private let defaults = UserDefaults.standard

    var titleLanguage: TitleLanguage {
        didSet { defaults.set(titleLanguage.rawValue, forKey: "titleLanguage") }
    }
    var hideChinese: Bool {
        didSet { defaults.set(hideChinese, forKey: "hideChinese") }
    }
    var includeUnreleased: Bool {
        didSet { defaults.set(includeUnreleased, forKey: "includeUnreleased") }
    }
    var clientId: String {
        didSet { defaults.set(clientId, forKey: "clientId") }
    }
    var dismissedPicks: Set<Int> {
        didSet { defaults.set(Array(dismissedPicks), forKey: "dismissedPicks") }
    }
    /// On-device semantic re-ranking with Natural Language embeddings.
    var useOnDeviceAI: Bool {
        didSet { defaults.set(useOnDeviceAI, forKey: "useOnDeviceAI") }
    }

    init() {
        titleLanguage = TitleLanguage(rawValue: defaults.string(forKey: "titleLanguage") ?? "") ?? .english
        hideChinese = defaults.object(forKey: "hideChinese") as? Bool ?? true
        includeUnreleased = defaults.object(forKey: "includeUnreleased") as? Bool ?? false
        clientId = defaults.string(forKey: "clientId") ?? ""
        dismissedPicks = Set(defaults.array(forKey: "dismissedPicks") as? [Int] ?? [])
        useOnDeviceAI = defaults.object(forKey: "useOnDeviceAI") as? Bool ?? true
    }
}
