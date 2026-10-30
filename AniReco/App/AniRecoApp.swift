import SwiftUI

@main
struct AniRecoApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Bigger shared cache so cover art loads instantly the second time.
        URLCache.shared = URLCache(memoryCapacity: 64 * 1024 * 1024,
                                   diskCapacity: 512 * 1024 * 1024)
        // Charging-time pre-analysis must be registered before launch finishes.
        BackgroundPrefetch.register()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(Theme.accent)
                .task { await model.bootstrap() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { BackgroundPrefetch.schedule() }
                }
        }
    }
}

enum Theme {
    static let accent = Color(red: 0.24, green: 0.60, blue: 1.0)
    static let pink = Color(red: 0.98, green: 0.45, blue: 0.62)
    /// Tint of the match % glass bubble: the same pink, a little darker so it stands out on
    /// bright covers (used at the same glass opacity as before).
    static let pinkGlass = Color(red: 0.86, green: 0.33, blue: 0.50)
}
