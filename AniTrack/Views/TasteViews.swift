import SwiftUI

/// Quick "how did you like it?" after marking a show watched. One tap = a score,
/// which is the strongest signal for both For You and match %.
struct RatePromptView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let media: Media
    @State private var isSaving = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 5)

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                CoverImageView(url: media.thumbURL, color: media.coverImage?.color, width: 46, height: 66, cornerRadius: 6)
                VStack(alignment: .leading, spacing: 4) {
                    Text("How did you like it?").font(.headline)
                    Text(media.displayTitle(model.settings.titleLanguage))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }

            GlassEffectContainer(spacing: 8) {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(1...10, id: \.self) { value in
                        Button {
                            Task { await rate(value) }
                        } label: {
                            Text("\(value)")
                                .font(.title3.weight(.semibold))
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.glass)
                        .tint(value >= 8 ? .green : (value >= 5 ? .orange : .red))
                        .disabled(isSaving)
                    }
                }
            }

            Button("Skip") { dismiss() }
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }

    private func rate(_ value: Int) async {
        isSaving = true
        defer { isSaving = false }
        do {
            let status = model.entry(for: media.id)?.status ?? .COMPLETED
            try await model.save(media: media, status: status, progress: nil, scoreRaw: value * 10)
            model.updateOtherSeasons(of: media, .scored(value * 10))
            dismiss()
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }
}

/// Fan recommendations for one show, re-ordered by *your* match.
struct MoreLikeThisSheet: View {
    @State private var path = NavigationPath()
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let media: Media

    @State private var items: [Media] = []
    @State private var isLoading = true
    @State private var error: String?

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if isLoading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if items.isEmpty {
                    ContentUnavailableView("Nothing similar found", systemImage: "square.stack.3d.up.slash",
                                           description: Text(error ?? "Fans haven't linked shows to this one yet."))
                }
                // A show you plan, watch or dismiss here leaves the list right away.
                ForEach(items.filter { model.entry(for: $0.id) == nil && !model.settings.dismissedPicks.contains($0.id) }) { item in
                    MediaRowLink(media: item)
                }
            }
            .listStyle(.plain)
            .navigationTitle("Like \(media.displayTitle(model.settings.titleLanguage))")
            .navigationBarTitleDisplayMode(.inline)
            .plainMediaDestination()
            // No zoom namespace in here: covers aren't zoom sources inside a sheet.
            .environment(\.zoomNamespace, nil)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .task { await load() }
        }
        .pushDetailAction($path)
        .environment(\.cardSheetsAllowed, false)
        // "Already watched" from a menu in here: the rating prompt opens over this sheet.
        .sheet(item: Binding(get: { model.sheetRatePrompt }, set: { model.sheetRatePrompt = $0 })) { media in
            RatePromptView(media: media)
                .presentationDetents([.height(360)])
        }
    }

    private func load() async {
        guard items.isEmpty else { return }
        do {
            let detail = try await model.detail(id: media.id)
            let recs = (detail.recommendations?.nodes ?? []).compactMap(\.mediaRecommendation)
            // A recommended Season 2 is shown as its first season.
            items = await SeasonRoots.collapse(recs, client: model.client)
                .filter { $0.id != media.id }
                .filter { model.entry(for: $0.id) == nil && $0.isAdult != true && !$0.isMovie }
                .filter { !model.franchises.contains($0) && !model.settings.dismissedPicks.contains($0.id) }
                .filter { !(model.settings.hideChinese && $0.countryOfOrigin == "CN") }
                .sorted { (model.matcher.match(for: $0) ?? 0) > (model.matcher.match(for: $1) ?? 0) }
            isLoading = false
        } catch {
            // Cancelled: keep the spinner; it loads again when the sheet reappears.
            if AppModel.isCancellation(error) { return }
            self.error = error.localizedDescription
            isLoading = false
        }
    }
}
