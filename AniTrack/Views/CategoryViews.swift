import SwiftUI

/// Minimal category dropdown: "Any category" plus the popular categories, grouped into
/// Genres and Tags, and "All categories…" for the full searchable list.
struct CategoryChipsBar: View {
    @Environment(AppModel.self) private var model
    @Binding var selected: AnimeCategory?
    var showAny = true
    @State private var showAll = false

    private var genres: [AnimeCategory] { model.featuredCategories.filter { $0.kind == .genre } }
    private var tags: [AnimeCategory] { model.featuredCategories.filter { $0.kind == .tag } }

    var body: some View {
        HStack {
            Menu {
                if showAny {
                    Button { selected = nil } label: {
                        if selected == nil { Label("Any category", systemImage: "checkmark") } else { Text("Any category") }
                    }
                    Divider()
                }
                Section("Genres") {
                    ForEach(genres) { item(for: $0) }
                }
                Section("Tags") {
                    ForEach(tags) { item(for: $0) }
                }
                Divider()
                Button { showAll = true } label: {
                    Label("All categories…", systemImage: "magnifyingglass")
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease")
                    Text(selected?.name ?? "Any category")
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                }
                .font(.subheadline.weight(.semibold))
            }
            .menuStyle(.button)
            .buttonStyle(.glass)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .sheet(isPresented: $showAll) {
            AllCategoriesSheet { picked in
                selected = picked
                showAll = false
            }
            .presentationDetents([.medium, .large])
        }
    }

    @ViewBuilder
    private func item(for category: AnimeCategory) -> some View {
        Button { selected = category } label: {
            if selected == category { Label(category.name, systemImage: "checkmark") } else { Text(category.name) }
        }
    }
}

/// Every AniList genre and (non-adult, non-spoiler) tag, searchable.
struct AllCategoriesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let onSelect: (AnimeCategory) -> Void
    @State private var search = ""

    private func filtered(_ kind: AnimeCategory.Kind) -> [AnimeCategory] {
        let source = model.allCategories.isEmpty ? AnimeCategory.featured : model.allCategories
        return source
            .filter { $0.kind == kind }
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List {
                let genres = filtered(.genre)
                let tags = filtered(.tag)
                if !genres.isEmpty {
                    Section("Genres") {
                        ForEach(genres) { category in
                            Button(category.name) { onSelect(category) }
                                .foregroundStyle(.primary)
                        }
                    }
                }
                if !tags.isEmpty {
                    Section("Tags") {
                        ForEach(tags) { category in
                            Button(category.name) { onSelect(category) }
                                .foregroundStyle(.primary)
                        }
                    }
                }
            }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Isekai, Romance, Ecchi…")
            .navigationTitle("Categories")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .task { await model.loadCategories() }
        }
    }
}

/// Browse one category with sorting, endless scrolling, and search inside the category.
struct CategoryBrowseView: View {
    @Environment(AppModel.self) private var model
    let category: AnimeCategory

    enum Sort: String, CaseIterable, Identifiable {
        case popular = "Most popular"
        case top = "Top rated"
        case trending = "Trending"
        case newest = "Newest"
        var id: String { rawValue }
        var apiSort: [String] {
            switch self {
            case .popular: return ["POPULARITY_DESC"]
            case .top: return ["SCORE_DESC"]
            case .trending: return ["TRENDING_DESC", "POPULARITY_DESC"]
            case .newest: return ["START_DATE_DESC"]
            }
        }
    }

    @State private var sort: Sort = .popular
    @State private var search = ""
    @State private var items: [Media] = []
    @State private var page = 1
    @State private var canLoadMore = true
    @State private var isLoading = false
    @State private var error: String?
    @State private var loadedKey: String?

    var body: some View {
        List {
            ForEach(items) { media in
                NavigationLink(value: MediaLink(id: media.id)) { MediaRow(media: media) }
                    .onAppear {
                        if media.id == items.last?.id { Task { await loadPage() } }
                    }
            }
            if isLoading {
                HStack { Spacer(); ProgressView(); Spacer() }
            } else if items.isEmpty {
                ContentUnavailableView(error == nil ? "Nothing found" : "Couldn't load",
                                       systemImage: "magnifyingglass",
                                       description: Text(error ?? "Try another sort or search."))
            }
        }
        .listStyle(.plain)
        .navigationTitle(category.name)
        .searchable(text: $search, prompt: "Search in \(category.name)")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort", selection: $sort) {
                        ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
            }
        }
        .task(id: "\(sort.rawValue)|\(search)") {
            let key = "\(sort.rawValue)|\(search)"
            guard loadedKey != key else { return }   // coming back from a detail page: keep results
            if !search.isEmpty { try? await Task.sleep(nanoseconds: 450_000_000) }
            guard !Task.isCancelled else { return }
            loadedKey = key
            items = []
            page = 1
            canLoadMore = true
            await loadPage()
        }
    }

    private func loadPage() async {
        guard canLoadMore, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let text = search.trimmingCharacters(in: .whitespaces)
            let result = try await model.browse(search: text.isEmpty ? nil : text,
                                                sort: text.isEmpty ? sort.apiSort : ["SEARCH_MATCH"],
                                                category: category,
                                                page: page,
                                                perPage: 30)
            let known = Set(items.map(\.id))
            items += result.filter { !known.contains($0.id) }
            canLoadMore = result.count >= 20
            page += 1
            error = nil
        } catch {
            // Cancelled (screen left mid-load): not an error, the next appearance loads it.
            if AppModel.isCancellation(error) { return }
            self.error = error.localizedDescription
            canLoadMore = false
        }
    }
}
