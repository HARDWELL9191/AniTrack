import SwiftUI

/// Only used by the UI tests (launched with JELLYRECO_UITEST set): the real For You screen
/// without a Jellyfin server, so the TMDB key flow can be reproduced in the simulator.
/// "foryou" = the app as shipped; "foryou-unattached" = the old bug (engine not connected).
struct UITestHost: View {
    @Environment(AppModel.self) private var model
    let mode: String
    @State private var ready = false

    var body: some View {
        ZStack {
            Color.clear
            if ready {
                ForYouView()
                    .overlay(alignment: .bottom) {
                        Text(model.discovery.hasKey ? "STATE: For You sees the key" : "STATE: For You sees no key")
                            .font(.caption).accessibilityIdentifier("tmdb-state").padding(.bottom, 90)
                    }
            }
        }
        .onAppear {
            model.settings.tmdbKey = ""
            #if DEBUG
            if mode == "foryou-unattached" { model.discovery.detachForTesting() }
            #endif
            ready = true
        }
    }
}
