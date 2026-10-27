import SwiftUI

@main
struct AniTrackApp: App {
    @State private var model = AppModel()

    init() {
        // Bigger shared cache so cover art loads instantly the second time.
        URLCache.shared = URLCache(memoryCapacity: 64 * 1024 * 1024,
                                   diskCapacity: 512 * 1024 * 1024)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(Theme.accent)
                .task { await model.bootstrap() }
        }
    }
}

enum Theme {
    static let accent = Color(red: 0.24, green: 0.60, blue: 1.0)
    static let pink = Color(red: 0.98, green: 0.45, blue: 0.62)
}
