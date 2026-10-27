import SwiftUI

/// Horizontal glass chips: "Any" (optional), featured categories, and "More…".
struct CategoryChipsBar: View {
    @Environment(AppModel.self) private var model
    @Binding var selected: AnimeCategory?
    var showAny = true
    @State private var showAll = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        if showAny {
                            chip(title: "Any category", systemImage: "sparkles", isSelected: selected == nil) {
                                selected = nil
                            }
                            .id("any")
                        }
                        // Keep a category picked from the full list visible as a chip.
                        if let selected, !model.featuredCategories.contains(selected) {
                            chip(title: selected.name, systemImage: nil, isSelected: true) {}
                                .id(selected.id)
                        }
                        ForEach(model.featuredCategories) { category in
                            chip(title: category.name, systemImage: nil, isSelected: selected == category) {
                                selected = category
                            }
                            .id(category.id)
                        }
                        chip(title: "More…", systemImage: "square.grid.2x2", isSelected: false) {
                            showAll = true
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                }
            }
            .onChange(of: selected) { _, newValue in
                withAnimation { proxy.scrollTo(newValue?.id ?? "any", anchor: .center) }
            }
        }
        .sheet(isPresented: $showAll) {
            AllCategoriesSheet { picked in
                selected = picked
                showAll = false
            }
            .presentationDetents([.medium, .large])
        }
    }

    private func chip(title: String, systemImage: String?, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.bouncy) { action() }
        } label: {
            Group {
                if let systemImage {
                    Label(title, systemImage: systemImage)
                } else {
                    Text(title)
                }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .glassEffect(isSelected ? .regular.tint(Theme.accent).interactive() : .regular.interactive(),
                         in: .capsule)
        }
        .buttonStyle(.plain)
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
            if !search.isEmpty { try? await Task.sleep(nanoseconds: 450_000_000) }
            guard !Task.isCancelled else { return }
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
            self.error = error.localizedDescription
            canLoadMore = false
        }
    }
}
