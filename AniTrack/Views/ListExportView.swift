import SwiftUI
import UniformTypeIdentifiers

/// Profile → "Export lists to Excel": pick any of your lists, get one .xlsx with a sheet per list
/// and save it to Files.
struct ListExportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// One exportable list.
    struct Choice: Identifiable, Hashable {
        let id: String
        let label: String
        let symbol: String
        let status: ListStatus?   // nil = "Not for me"
    }

    private static let choices: [Choice] =
        [ListStatus.CURRENT, .REPEATING, .COMPLETED, .PAUSED, .DROPPED, .PLANNING].map {
            Choice(id: $0.rawValue, label: $0.label, symbol: $0.symbol, status: $0)
        } + [Choice(id: "NOT_FOR_ME", label: "Not for me", symbol: "hand.thumbsdown.fill", status: nil)]

    @State private var selected: Set<String> = []
    @State private var didSetDefaults = false
    @State private var document: XLSXDocument?
    @State private var isExporting = false
    @State private var isBuilding = false
    @State private var failure: String?
    @State private var saved: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(Self.choices) { choice in
                        Toggle(isOn: binding(for: choice)) {
                            HStack {
                                Label(choice.label, systemImage: choice.symbol)
                                Spacer()
                                Text("\(count(choice))")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button(allSelected ? "Deselect all" : "Select all") {
                        selected = allSelected ? [] : Set(Self.choices.map(\.id))
                    }
                } header: {
                    Text("Lists to include")
                } footer: {
                    Text("Each list becomes its own sheet with titles, your score, progress, episodes, format, season, average score, match %, genres, dates and an AniList link. Opens in Excel, Numbers and Google Sheets.")
                }

                Section {
                    // One button: builds the file and opens the Save dialog (Files, iCloud Drive…).
                    Button {
                        Task { await build() }
                    } label: {
                        Text("Save Excel file")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .opacity(isBuilding ? 0 : 1)
                            .overlay { if isBuilding { ProgressView().tint(.white) } }
                            .padding(.horizontal, 22)
                            .frame(height: 44)   // same height as the Close button
                            .glassEffect(.regular.tint(.accentColor).interactive(), in: .capsule)
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .disabled(selected.isEmpty || isBuilding)
                    .opacity(selected.isEmpty ? 0.45 : 1)
                    .frame(maxWidth: .infinity)   // centered, width follows the text
                } footer: {
                    if let failure {
                        Text(failure).foregroundStyle(.red)
                    } else if let saved {
                        Text(saved)
                    }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            .navigationTitle("Export to Excel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .fileExporter(isPresented: $isExporting, document: document,
                          contentType: XLSXDocument.contentType, defaultFilename: fileName()) { result in
                switch result {
                case .success(let url): saved = "Saved \(url.lastPathComponent)."
                case .failure(let error):
                    // Closing the Save dialog isn't an error.
                    if (error as? CocoaError)?.code != .userCancelled {
                        failure = "Couldn't save the file: \(error.localizedDescription)"
                    }
                }
            }
            .task {
                if !didSetDefaults {
                    didSetDefaults = true
                    // Every list that has something in it.
                    selected = Set(Self.choices.filter { count($0) > 0 }.map(\.id))
                }
                await model.loadNotForMeMedia()   // titles for "Not for me" shows not loaded yet
            }
        }
    }

    private var allSelected: Bool { selected.count == Self.choices.count }

    private func binding(for choice: Choice) -> Binding<Bool> {
        Binding(get: { selected.contains(choice.id) },
                set: { on in if on { selected.insert(choice.id) } else { selected.remove(choice.id) } })
    }

    private func count(_ choice: Choice) -> Int {
        if let status = choice.status { return model.entries.filter { $0.status == status }.count }
        return model.settings.dismissedPicks.count
    }

    // MARK: Building

    private func build() async {
        isBuilding = true
        failure = nil
        saved = nil
        defer { isBuilding = false }
        let sheets = Self.choices.filter { selected.contains($0.id) }.map(sheet(for:))
        // XML + ZIP work happens off the main thread (a big list is a few MB of text).
        let data = await Task.detached(priority: .userInitiated) { XLSXWriter.data(sheets: sheets) }.value
        document = XLSXDocument(data: data)
        isExporting = true
    }

    private func fileName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let user = (model.viewer?.name ?? "")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        let who = user.isEmpty ? "" : " \(user)"
        return "AniTrack\(who) lists \(formatter.string(from: Date()))"   // ".xlsx" is added by the Save dialog
    }

    private func sheet(for choice: Choice) -> XLSXWriter.Sheet {
        let lang = model.settings.titleLanguage
        if let status = choice.status {
            let entries = model.entries.filter { $0.status == status }
                .sorted { $0.media.displayTitle(lang).localizedCompare($1.media.displayTitle(lang)) == .orderedAscending }
            let columns: [XLSXWriter.Column] = [
                .init(title: "Title", width: 42), .init(title: "Other title", width: 36),
                .init(title: "My score (/10)", width: 14), .init(title: "Episodes watched", width: 16),
                .init(title: "Episodes", width: 10), .init(title: "Format", width: 10),
                .init(title: "Season", width: 13), .init(title: "Show status", width: 12),
                .init(title: "Average score (/10)", width: 18), .init(title: "Match %", width: 10),
                .init(title: "Genres", width: 34), .init(title: "Added", width: 12),
                .init(title: "Last updated", width: 13), .init(title: "AniList", width: 36)
            ]
            let rows: [[XLSXWriter.Cell]] = entries.map { e -> [XLSXWriter.Cell] in
                let m = e.media
                return [
                    .text(m.displayTitle(lang)), .text(otherTitle(m, lang)),
                    Self.number(e.scoreValue > 0 ? e.scoreValue / 10 : nil),
                    Self.number(Double(e.progressValue)),
                    Self.number(m.episodes.map { Double($0) }),
                    .text(m.formatLabel), .text(m.seasonLabel ?? ""), .text(m.statusLabel),
                    Self.number(m.averageScore.map { Double($0) / 10 }),
                    Self.number(model.matcher.match(for: m).map { Double($0) }),
                    .text((m.genres ?? []).joined(separator: ", ")),
                    Self.date(e.createdAt), Self.date(e.updatedAt),
                    .link(m.siteUrl ?? "https://anilist.co/anime/\(m.id)")
                ]
            }
            return XLSXWriter.Sheet(name: choice.label, columns: columns, rows: rows)
        }

        // "Not for me": shows only (no score or progress); details may still be loading for a few.
        let ids = model.settings.dismissedPicks
        let known = ids.compactMap { model.notForMeMedia[$0] }
            .sorted { $0.displayTitle(lang).localizedCompare($1.displayTitle(lang)) == .orderedAscending }
        let unknown = ids.filter { model.notForMeMedia[$0] == nil }.sorted()
        let columns: [XLSXWriter.Column] = [
            .init(title: "Title", width: 42), .init(title: "Other title", width: 36),
            .init(title: "Episodes", width: 10), .init(title: "Format", width: 10),
            .init(title: "Season", width: 13), .init(title: "Show status", width: 12),
            .init(title: "Average score (/10)", width: 18), .init(title: "Match %", width: 10),
            .init(title: "Genres", width: 34), .init(title: "AniList", width: 36)
        ]
        var rows: [[XLSXWriter.Cell]] = known.map { m -> [XLSXWriter.Cell] in
            [
                .text(m.displayTitle(lang)), .text(otherTitle(m, lang)),
                Self.number(m.episodes.map { Double($0) }),
                .text(m.formatLabel), .text(m.seasonLabel ?? ""), .text(m.statusLabel),
                Self.number(m.averageScore.map { Double($0) / 10 }),
                Self.number(model.matcher.match(for: m).map { Double($0) }),
                .text((m.genres ?? []).joined(separator: ", ")),
                .link(m.siteUrl ?? "https://anilist.co/anime/\(m.id)")
            ]
        }
        rows += unknown.map { id -> [XLSXWriter.Cell] in
            [.text("AniList #\(id)"), .empty, .empty, .empty, .empty, .empty, .empty, .empty, .empty,
             .link("https://anilist.co/anime/\(id)")]
        }
        return XLSXWriter.Sheet(name: choice.label, columns: columns, rows: rows)
    }

    private static func number(_ value: Double?) -> XLSXWriter.Cell {
        value.map { XLSXWriter.Cell.number($0) } ?? .empty
    }

    private static func date(_ unix: Int?) -> XLSXWriter.Cell {
        guard let unix, unix > 0 else { return .empty }
        return .date(Date(timeIntervalSince1970: TimeInterval(unix)))
    }

    /// The romaji title when titles are shown in English (and the other way round).
    private func otherTitle(_ m: Media, _ lang: TitleLanguage) -> String {
        let main = m.displayTitle(lang)
        let other = lang == .romaji ? (m.title.english ?? m.title.native) : (m.title.romaji ?? m.title.native)
        guard let other, other != main else { return "" }
        return other
    }
}

/// The workbook handed to the Save dialog.
struct XLSXDocument: FileDocument {
    static let contentType = UTType("org.openxmlformats.spreadsheetml.sheet")
        ?? UTType(filenameExtension: "xlsx") ?? .data
    static var readableContentTypes: [UTType] { [contentType] }

    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
