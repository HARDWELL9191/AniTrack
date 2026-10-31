import SwiftUI

/// Only used by the UI tests (launched with JELLYRECO_UITEST set): shows one real screen
/// without a Jellyfin server, so taps can be reproduced in the simulator.
/// mode "tmdb-old" = the build before the tap fix (tap-outside keyboard dismissal and
/// interactive glass on), "tmdb-new" = current.
struct UITestHost: View {
    @Environment(AppModel.self) private var model
    let mode: String

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    TMDBKeyCard().padding(.horizontal)
                    Text(model.discovery.hasKey ? "STATE: key saved" : "STATE: no key")
                        .accessibilityIdentifier("tmdb-state")
                }
            }
            .navigationTitle("For You")
        }
        .background { if mode == "tmdb-old" { KeyboardDismissOnTapOutside() } }
        .onAppear {
            TintedGlassButtonStyle.interactiveForTesting = mode == "tmdb-old"
            model.discovery.attach(model: model)
            model.settings.tmdbKey = ""
        }
    }
}
