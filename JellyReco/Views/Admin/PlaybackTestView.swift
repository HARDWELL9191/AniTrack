import MPVUI
import SwiftUI

/// Plays every video in your libraries in JellyReco's real player (on this iPhone, direct play)
/// and switches through every audio and subtitle track, listing anything that fails to decode.
///
/// Quick mode tests one file per unique combination of container, video, audio and subtitle
/// formats (a library of 3,000 episodes usually has a few dozen); Full mode tests every file.
struct PlaybackTestView: View {
    @Environment(AppModel.self) private var model
    @State private var tester = PlaybackTester()
    @State private var full = false
    @State private var libraryIds: Set<String> = []

    var body: some View {
        List {
            Section {
                Picker("Mode", selection: $full) {
                    Text("Quick (each format once)").tag(false)
                    Text("Every file").tag(true)
                }
                ForEach(model.videoLibraries.filter { !RecoSource.isExcluded($0.name) }) { lib in
                    Toggle(lib.displayName, isOn: Binding(get: { libraryIds.contains(lib.id) },
                                                          set: { if $0 { libraryIds.insert(lib.id) } else { libraryIds.remove(lib.id) } }))
                }
                Button(tester.isRunning ? "Stop" : "Start test", systemImage: tester.isRunning ? "stop.fill" : "play.fill") {
                    if tester.isRunning { tester.cancel() } else {
                        tester.start(model: model, libraries: model.videoLibraries.filter { libraryIds.contains($0.id) }, full: full)
                    }
                }
                .disabled(libraryIds.isEmpty && !tester.isRunning)
            } footer: {
                Text("Each file plays muted for a moment while every audio and subtitle track is switched on in turn. Direct play only: nothing is converted. Keep the app open; the screen stays on while testing.")
            }

            if tester.isRunning || tester.done > 0 {
                Section("Progress") {
                    ProgressView(value: Double(tester.done), total: Double(max(tester.total, 1)))
                        .tint(Theme.accent)
                    LabeledContent("Tested", value: "\(tester.done) of \(tester.total)")
                    LabeledContent("Passed", value: "\(tester.passed)")
                    LabeledContent("Problems", value: "\(tester.failures.count)")
                    if let now = tester.current { Text("Now: \(now)").font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                    if tester.isRunning {
                        MPVVideoPlayer(player: tester.player)
                            .frame(height: 120)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
            }

            if !tester.failures.isEmpty {
                Section {
                    ForEach(tester.failures) { f in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(f.title).font(.subheadline.weight(.semibold))
                            Text(f.format).font(.caption.monospaced()).foregroundStyle(.secondary)
                            ForEach(f.problems, id: \.self) { Text("• \($0)").font(.caption).foregroundStyle(.red) }
                        }
                    }
                } header: {
                    HStack {
                        Text("Problems")
                        Spacer()
                        ShareLink(item: tester.reportText) { Label("Share", systemImage: "square.and.arrow.up").font(.caption) }
                    }
                }
            } else if tester.done > 0 && !tester.isRunning {
                Section { Label("Every tested file played with all its audio and subtitle tracks.", systemImage: "checkmark.seal.fill").foregroundStyle(.green) }
            }
        }
        .navigationTitle("Playback test")
        .onAppear {
            if libraryIds.isEmpty { libraryIds = Set(model.videoLibraries.filter { !RecoSource.isExcluded($0.name) }.map(\.id)) }
        }
        .onDisappear { tester.cancel() }
    }
}

@Observable
@MainActor
final class PlaybackTester {
    struct Failure: Identifiable {
        let id = UUID()
        let title: String
        let format: String
        let problems: [String]
    }

    private(set) var isRunning = false
    private(set) var total = 0
    private(set) var done = 0
    private(set) var passed = 0
    private(set) var current: String?
    private(set) var failures: [Failure] = []
    let player: MPVPlayer

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var log: [String] = []

    init() {
        player = MPVPlayer(configuration: MPVPlayerConfiguration(
            additionalOptions: ["sub-auto": "no"],
            automaticallyPlays: true,
            logLevel: .warning,
            videoOutput: .sampleBuffer,
            volume: 0
        ))
        player.logHandler = { [weak self] msg in
            guard msg.level == .error || msg.level == .fatal || msg.message.localizedCaseInsensitiveContains("decod") else { return }
            self?.log.append("[\(msg.prefix)] \(msg.message.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    var reportText: String {
        failures.map { "\($0.title)\n  \($0.format)\n" + $0.problems.map { "  - \($0)" }.joined(separator: "\n") }
            .joined(separator: "\n\n")
    }

    func cancel() {
        task?.cancel()
        player.stop()
        isRunning = false
        current = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func start(model: AppModel, libraries: [BaseItem], full: Bool) {
        guard let client = model.client else { return }
        failures = []
        done = 0
        passed = 0
        isRunning = true
        UIApplication.shared.isIdleTimerDisabled = true
        task = Task {
            let items = await collect(client: client, libraries: libraries, full: full)
            total = items.count
            for item in items {
                if Task.isCancelled { break }
                await test(item, client: client)
                done += 1
            }
            player.stop()
            isRunning = false
            current = nil
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    /// Every playable video, or one per unique format combination in quick mode.
    private func collect(client: JellyfinClient, libraries: [BaseItem], full: Bool) async -> [BaseItem] {
        var all: [BaseItem] = []
        for lib in libraries {
            var q = JellyfinClient.ItemQuery()
            q.parentId = lib.id
            q.includeItemTypes = [.movie, .episode, .video, .musicVideo]
            q.fields = ["MediaSources", "MediaStreams", "Path"]
            q.limit = 300
            q.isMissing = false
            while !Task.isCancelled {
                guard let page = try? await client.items(q) else { break }
                let items = page.items ?? []
                all += items
                q.startIndex += items.count
                if items.isEmpty || q.startIndex >= (page.totalRecordCount ?? 0) { break }
            }
        }
        guard !full else { return all }
        var seen: Set<String> = []
        return all.filter { seen.insert(signature($0)).inserted }
    }

    private func signature(_ item: BaseItem) -> String {
        let src = item.mediaSources?.first
        let streams = src?.mediaStreams ?? item.mediaStreams ?? []
        let video = streams.filter(\.isVideo).map { "\($0.codec ?? "?")/\($0.profile ?? "")/\($0.bitDepth ?? 8)/\($0.videoRangeType ?? "")" }
        let audio = Set(streams.filter(\.isAudio).map { "\($0.codec ?? "?")/\($0.channels ?? 0)" }).sorted()
        let subs = Set(streams.filter(\.isSubtitle).map { "\($0.codec ?? "?")\($0.isExternal == true ? "+ext" : "")" }).sorted()
        return [src?.container ?? "?", video.joined(separator: ","), audio.joined(separator: ","), subs.joined(separator: ",")].joined(separator: "|")
    }

    private func test(_ item: BaseItem, client: JellyfinClient) async {
        let title = item.kind == .episode ? "\(item.seriesName ?? "") \(item.episodeLabel ?? "") \(item.displayName)" : item.displayName
        current = title
        log = []
        var problems: [String] = []
        guard let src = item.mediaSources?.first,
              let url = client.directStreamURL(itemId: item.id, source: src, playSessionId: nil) else {
            failures.append(Failure(title: title, format: signature(item), problems: ["No file on the server"]))
            return
        }
        let start = (item.runtimeSeconds ?? 0) > 120 ? 60.0 : 0
        player.load(url, playAutomatically: true, startTime: .seconds(start))
        // External subtitles, as the real player adds them.
        let external = (src.mediaStreams ?? []).filter { $0.isSubtitle && ($0.isExternal ?? false) }
        for sub in external {
            let format = (sub.codec ?? "srt").lowercased().replacingOccurrences(of: "subrip", with: "srt")
                .replacingOccurrences(of: "pgssub", with: "sup").replacingOccurrences(of: "webvtt", with: "vtt")
            if let u = client.subtitleURL(itemId: item.id, sourceId: src.id, stream: sub, format: format) {
                player.loadExternalSubtitle(u, selecting: nil)
            }
        }

        // Wait for the first frames (or a failure).
        guard await waitUntilPlaying(timeout: 20) else {
            let reason = player.state.error?.message ?? (log.last ?? "Didn't start within 20 s")
            failures.append(Failure(title: title, format: signature(item), problems: ["Won't play: \(reason)"] + log.suffix(3)))
            player.stop()
            return
        }

        for track in player.audioTracks {
            log = []
            player.selectTrack(track.id)
            if !(await advances(seconds: 1.5)) || failed() {
                problems.append("Audio \(track.mpvID) (\(track.codec ?? "?") \(track.language ?? "")): \(log.last ?? "no sound/stalled")")
            }
        }
        for track in player.subtitleTracks {
            log = []
            player.selectSubtitle(track.id)
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if failed() || player.lastError != nil {
                problems.append("Subtitle \(track.mpvID) (\(track.codec ?? "?") \(track.language ?? "")): \(player.lastError?.message ?? log.last ?? "failed")")
                player.clearLastError()
            }
        }
        player.stop()
        if problems.isEmpty { passed += 1 } else { failures.append(Failure(title: title, format: signature(item), problems: problems)) }
    }

    private func failed() -> Bool {
        if case .failed = player.state { return true }
        return log.contains { $0.localizedCaseInsensitiveContains("failed to initialize") || $0.localizedCaseInsensitiveContains("could not open codec") || $0.localizedCaseInsensitiveContains("no decoder") }
    }

    private func waitUntilPlaying(timeout: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline && !Task.isCancelled {
            if case .failed = player.state { return false }
            if player.state == .playing && player.hasVideoFrame || (player.state == .playing && player.videoTracks.isEmpty) { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }

    private func advances(seconds: Double) async -> Bool {
        let before = player.position
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        return player.position > before
    }
}
