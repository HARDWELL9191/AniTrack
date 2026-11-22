import SwiftUI

/// Not for me / Already seen: For You picks you turned down (saved on your server; anime on
/// AniList's private "Not for me" list). Undo puts a title back in the running for For You.
struct NotForMeView: View {
    @Environment(AppModel.self) private var model
    @State private var tab = 0
    @State private var detail: ExternalTitle?
    @State private var confirmClear = false

    private var notForMe: [ExternalTitle] {
        model.externalNotForMe + model.anilist.notForMeTitles.map { model.anilist.title(for: $0) }
    }
    private var list: [ExternalTitle] { tab == 0 ? notForMe : model.externalSeen }

    var body: some View {
        // The same look as My List: the dropdown on the right, then a grid of covers.
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                filterBar
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12, alignment: .top)], spacing: 16) {
                    ForEach(list) { t in
                        Button { detail = t } label: { ExternalPosterCard(title: t, width: 104) }
                            .buttonStyle(PressStyle())
                            .cardContextMenu {
                                Button("Details", systemImage: "info.circle") { detail = t }
                                Button(tab == 0 ? "Undo Not for me" : "Undo Already seen", systemImage: "arrow.uturn.backward") {
                                    Task { tab == 0 ? await model.markExternalNotForMe(t, false) : await model.unmarkSeen(t) }
                                }
                                Button(model.isOnMyList(t) ? "Remove from My List" : "Add to My List",
                                       systemImage: model.isOnMyList(t) ? "bookmark.slash" : "bookmark") {
                                    Task { await model.toggleMyList(t) }
                                }
                            }
                    }
                }
                .padding(.horizontal)
            }
            .padding(.vertical)
        }
        .overlay {
            if list.isEmpty {
                ContentUnavailableView("Nothing here",
                                       systemImage: tab == 0 ? "hand.thumbsdown" : "eye",
                                       description: Text(tab == 0 ? "Titles you mark \"Not for me\" in For You show up here. Long-press one to undo."
                                                                  : "Titles you mark \"Already seen\" in For You show up here. Long-press one to undo."))
            }
        }
        .navigationTitle("Not for me")
        .toolbar {
            // "Clear all" clears what's saved on the server; AniList titles are undone one by one.
            if tab == 0 ? !model.externalNotForMe.isEmpty : !model.externalSeen.isEmpty {
                Button("Clear all") { confirmClear = true }
            }
        }
        .confirmationDialog(tab == 0 ? "Clear Not for me?" : "Clear Already seen?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear all", role: .destructive) {
                Task { await model.clearExternal(tab == 0 ? .notforme : .seenelsewhere) }
            }
        } message: {
            Text(tab == 0 && !model.anilist.notForMeTitles.isEmpty
                 ? "These titles can be suggested on For You again. Anime on your AniList \"Not for me\" list stay: long-press one to undo it."
                 : "These titles can be suggested on For You again.")
        }
        .sheet(item: $detail) { ExternalDetailSheet(title: $0) }
    }

    /// The same dropdown as My List.
    private var filterBar: some View {
        HStack {
            Spacer()
            Menu {
                Button { tab = 0 } label: {
                    Label("Not for me (\(notForMe.count))", systemImage: tab == 0 ? "checkmark" : "hand.thumbsdown")
                }
                Button { tab = 1 } label: {
                    Label("Already seen (\(model.externalSeen.count))", systemImage: tab == 1 ? "checkmark" : "eye")
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: tab == 0 ? "hand.thumbsdown" : "eye").frame(height: 0)
                    Text(tab == 0 ? "Not for me (\(notForMe.count))" : "Already seen (\(model.externalSeen.count))")
                    Image(systemName: "chevron.down").font(.caption.weight(.semibold)).frame(height: 0)
                }
                .menuButtonHeight()
                .font(.subheadline.weight(.semibold))
            }
            .menuStyle(.button)
            .buttonStyle(.glass)
        }
        .padding(.horizontal)
    }
}
