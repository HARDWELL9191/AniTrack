import SwiftUI

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @Namespace private var zoom

    enum SortOrder: String, CaseIterable, Identifiable {
        case updated = "Last updated"
        case title = "Title"
        case score = "My score"
        case average = "Average score"
        var id: String { rawValue }
    }

    @State private var status: ListStatus = .CURRENT
    @State private var sort: SortOrder = .updated
    @State private var filter = ""

    private var items: [ListEntry] {
        var list = model.entries.filter { $0.status == status }
        let text = filter.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty {
            list = list.filter { entry in
                let t = entry.media.title
                return [t.english, t.romaji, t.native].compactMap { $0 }
                    .contains { $0.localizedCaseInsensitiveContains(text) }
            }
        }
        let lang = model.settings.titleLanguage
        switch sort {
        case .updated: list.sort { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }
        case .title: list.sort { $0.media.displayTitle(lang).localizedCompare($1.media.displayTitle(lang)) == .orderedAscending }
        case .score: list.sort { $0.scoreValue > $1.scoreValue }
        case .average: list.sort { ($0.media.averageScore ?? 0) > ($1.media.averageScore ?? 0) }
        }
        return list
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if items.isEmpty {
                        Text(model.isLoadingList ? "Loading…" : "Nothing here yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(items) { entry in
                        NavigationLink(value: MediaLink(id: entry.mediaId)) {
                            MediaRow(media: entry.media, subtitle: subtitle(for: entry))
                        }
                    }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) { statusBar }
            .navigationTitle("Lists")
            .mediaDestination(zoom: zoom)
            .environment(\.zoomNamespace, zoom)
            .searchable(text: $filter, prompt: "Filter this list")
            .refreshable { await model.refreshList() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Sort", selection: $sort) {
                            ForEach(SortOrder.allCases) { Text($0.rawValue).tag($0) }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                }
            }
        }
    }

    /// Floating glass status filter; the selected status morphs between chips.
    private var statusBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(ListStatus.allCases) { s in
                        let selected = status == s
                        Button {
                            withAnimation(.bouncy) { status = s }
                        } label: {
                            Label("\(s.label) \(model.count(of: s))", systemImage: s.symbol)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(selected ? Color.white : Color.primary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .glassEffect(selected ? .regular.tint(Theme.accent).interactive()
                                                      : .regular.interactive(),
                                             in: .capsule)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
    }

    private func subtitle(for entry: ListEntry) -> String {
        var parts: [String] = []
        let total = entry.media.episodes.map(String.init) ?? "?"
        parts.append("\(entry.progressValue)/\(total) eps")
        if entry.scoreValue > 0 { parts.append("★ \(Fmt.score(entry.score))") }
        if let airing = Fmt.airing(entry.media.nextAiringEpisode) { parts.append(airing) }
        return parts.joined(separator: " · ")
    }
}
