import SwiftUI

@main
struct JellyRecoApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    init() {
        // Posters and backdrops load instantly the second time.
        URLCache.shared = URLCache(memoryCapacity: 96 * 1024 * 1024, diskCapacity: 768 * 1024 * 1024)
    }

    var body: some Scene {
        WindowGroup {
            if let mode = ProcessInfo.processInfo.environment["JELLYRECO_UITEST"] {
                UITestHost(mode: mode).environment(model)
                    .tint(Theme.accent)
                    .toggleStyle(GreenSwitchToggleStyle())
                    .preferredColorScheme(.dark)
            } else {
            RootView()
                .environment(model)
                .tint(Theme.accent)
                .toggleStyle(GreenSwitchToggleStyle())
                .preferredColorScheme(model.settings.appearance.scheme)
                .task { await model.bootstrap() }
            }
        }
    }
}
