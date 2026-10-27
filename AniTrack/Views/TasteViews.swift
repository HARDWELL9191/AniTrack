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
            dismiss()
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }
}

/// Fan recommendations for one show, re-ordered by *your* match.
struct MoreLikeThisSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Namespace private var zoom
    let media: Media

    @State private var items: [Media] = []
    @State private var isLoading = true
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if isLoading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if items.isEmpty {
                    ContentUnavailableView("Nothing similar found", systemImage: "square.stack.3d.up.slash",
                                           description: Text(error ?? "Fans haven't linked shows to this one yet."))
                }
                ForEach(items) { item in
                    NavigationLink(value: MediaLink(id: item.id)) { MediaRow(media: item) }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Like \(media.displayTitle(model.settings.titleLanguage))")
            .navigationBarTitleDisplayMode(.inline)
            .mediaDestination(zoom: zoom)
            .environment(\.zoomNamespace, zoom)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .task { await load() }
        }
    }

    private func load() async {
        guard items.isEmpty else { return }
        defer { isLoading = false }
        do {
            let detail = try await model.detail(id: media.id)
            items = (detail.recommendations?.nodes ?? [])
                .compactMap(\.mediaRecommendation)
                .filter { model.entry(for: $0.id) == nil && $0.isAdult != true && !$0.isLaterSeason }
                .filter { !$0.nextSeasonIds.contains { model.entry(for: $0) != nil } }
                .filter { !(model.settings.hideChinese && $0.countryOfOrigin == "CN") }
                .sorted { (model.matcher.match(for: $0) ?? 0) > (model.matcher.match(for: $1) ?? 0) }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
