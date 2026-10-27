import SwiftUI

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @Namespace private var zoom

    enum SortOrder: String, CaseIterable, Identifiable {
        case match = "Best match"
        case updated = "Last updated"
        case title = "Title"
        case score = "My score"
        case average = "Average score"
        var id: String { rawValue }
    }

    @State private var status: ListStatus = .CURRENT
    @State private var userPickedStatus = false
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
        case .match:
            // Rated/finished shows have no match; fall back to your score for those.
            let key: (ListEntry) -> Int = { model.matcher.match(for: $0.media) ?? Int($0.scoreValue) }
            list.sort { key($0) > key($1) }
        }
        return list
    }

    var body: some View {
        NavigationStack {
            List {
                // Status picker lives inside the list (a top safe-area inset was hidden
                // behind the large navigation title on iOS 27).
                statusBar
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                Group {
                    if items.isEmpty {
                        Text(model.isLoadingList ? "Loading…" : "No shows marked \(status.label.lowercased()).")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(items) { entry in
                        NavigationLink(value: MediaLink(id: entry.mediaId)) {
                            MediaRow(media: entry.media, subtitle: subtitle(for: entry))
                        }
                        .removeFromListSwipe(entry)
                    }
                }
            }
            // Flat rows with thin separators (no rounded card behind every show).
            .listStyle(.plain)
            .navigationTitle("Lists")
            .mediaDestination(zoom: zoom)
            .environment(\.zoomNamespace, zoom)
            .searchable(text: $filter, prompt: "Filter this list")
            .refreshable { await model.refreshList() }
            .onAppear { pickDefaultStatus() }
            .onChange(of: model.entries.count) { _, _ in pickDefaultStatus() }
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

    /// Status dropdown: one glass button showing the current list and its count.
    private var statusBar: some View {
        HStack {
            Menu {
                ForEach(ListStatus.allCases) { s in
                    Button {
                        userPickedStatus = true
                        status = s
                    } label: {
                        if s == status {
                            Label("\(s.label) (\(model.count(of: s)))", systemImage: "checkmark")
                        } else {
                            Label("\(s.label) (\(model.count(of: s)))", systemImage: s.symbol)
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: status.symbol)
                    Text("\(status.label) (\(model.count(of: status)))")
                    Image(systemName: "chevron.down").font(.caption.weight(.semibold))
                }
                .font(.subheadline.weight(.semibold))
            }
            .menuStyle(.button)
            .buttonStyle(.glass)
            Spacer()
        }
    }

    /// Opens on the first status that actually has shows, unless you already picked one.
    private func pickDefaultStatus() {
        guard !userPickedStatus, model.count(of: status) == 0 else { return }
        let order: [ListStatus] = [.CURRENT, .REPEATING, .PLANNING, .COMPLETED, .PAUSED, .DROPPED]
        if let first = order.first(where: { model.count(of: $0) > 0 }) { status = first }
    }

    private func subtitle(for entry: ListEntry) -> String {
        var parts: [String] = []
        if entry.scoreValue > 0 { parts.append("Your score ★ \(Fmt.score(entry.score))") }
        parts.append(entry.media.formatLabel)
        if let season = entry.media.seasonLabel { parts.append(season) }
        return parts.joined(separator: " · ")
    }
}
