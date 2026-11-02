import MPVUI
import SwiftUI

/// Chapter thumbnails in a row above the timeline (like Apple's chapter browser).
struct ChaptersStrip: View {
    let controller: PlaybackController
    let close: () -> Void

    var body: some View {
        let now = controller.currentSeconds
        let chapters = controller.chapters
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(Array(chapters.enumerated()), id: \.offset) { i, ch in
                        let next = i + 1 < chapters.count ? chapters[i + 1].start : controller.durationSeconds
                        let current = now >= ch.start && now < next
                        Button {
                            controller.seek(to: ch.start)
                            close()
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Group {
                                    if let url = ch.imageURL {
                                        RemoteImage(url: url)
                                    } else if let tp = controller.trickplay, let img = tp.thumbnail(at: ch.start + 2) {
                                        Image(uiImage: img).resizable().scaledToFill()
                                    } else {
                                        Rectangle().fill(.white.opacity(0.1)).overlay(Text("\(i + 1)").font(.headline))
                                    }
                                }
                                .frame(width: 160, height: 90)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay {
                                    if current {
                                        RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white, lineWidth: 2)
                                    }
                                }
                                Text(ch.title).font(.caption.weight(.semibold)).lineLimit(1)
                                Text(Fmt.clock(ch.start)).font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.7))
                            }
                            .frame(width: 160, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .id(i)
                    }
                }
                .padding(.horizontal, 4)
            }
            .scrollClipDisabled()
            .onAppear {
                if let i = chapters.lastIndex(where: { $0.start <= now }) { proxy.scrollTo(i, anchor: .center) }
            }
        }
        .frame(height: 130)
    }
}

/// Episodes, as a panel that opens on the right of the screen: a vertical list (thumbnail, number,
/// title, length, progress, watched), the playing episode marked and scrolled into view, and a
/// season menu for the other seasons of the show.
struct EpisodesStrip: View {
    @Environment(AppModel.self) private var model
    let controller: PlaybackController
    let close: () -> Void
    @State private var episodes: [BaseItem] = []
    @State private var seasons: [BaseItem] = []
    @State private var seasonId: String?
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Episodes").font(.headline)
                    if let name = controller.item.seriesName { Text(name).font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1) }
                }
                Spacer(minLength: 4)
                if seasons.count > 1 {
                    Menu {
                        ForEach(seasons) { s in
                            Button { seasonId = s.id } label: {
                                if s.id == seasonId { Label(s.displayName, systemImage: "checkmark") } else { Text(s.displayName) }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(seasons.first { $0.id == seasonId }?.displayName ?? "Season").lineLimit(1)
                            Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                        }
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12).frame(height: 30)
                        .glassEffect(.regular.interactive(), in: .capsule)
                    }
                }
                Button(action: close) { Image(systemName: "xmark").font(.caption.weight(.bold)).frame(width: 30, height: 30) }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .accessibilityLabel("Close episodes")
            }
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 8) {
                        ForEach(episodes) { ep in row(ep).id(ep.id) }
                    }
                    .padding(.vertical, 2)
                }
                .overlay { if loading && episodes.isEmpty { ProgressView().tint(.white) } }
                .onChange(of: episodes) { _, _ in proxy.scrollTo(controller.item.id, anchor: .center) }
            }
        }
        .padding(14)
        .frame(maxWidth: 360)
        .frame(maxHeight: .infinity)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .task {
            guard let client = model.client, let sid = controller.item.seriesId else { loading = false; return }
            seasons = ((try? await client.seasons(seriesId: sid)) ?? []).filter { $0.locationType != "Virtual" }
        }
        .task(id: seasonId) {
            guard let client = model.client, let sid = controller.item.seriesId else { return }
            // First the playing episode's season (no season yet would load the whole series first).
            if seasonId == nil, let current = controller.item.seasonId {
                seasonId = current
                return
            }
            loading = true
            let list = (try? await client.episodes(seriesId: sid, seasonId: seasonId)) ?? []
            episodes = list.filter { $0.locationType != "Virtual" }
            loading = false
        }
    }

    private func row(_ ep: BaseItem) -> some View {
        let current = ep.id == controller.item.id
        return Button {
            guard !current else { return }
            close()
            Task { await controller.switchTo(ep) }
        } label: {
            HStack(spacing: 10) {
                RemoteImage(url: model.client?.landscapeURL(ep, width: 300))
                    .frame(width: 112, height: 63)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(alignment: .bottom) {
                        if let p = model.userData(for: ep)?.playedPercentage, p > 0, p < 100 {
                            ProgressBar(value: p / 100).padding(5)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if model.isPlayed(ep) {
                            Image(systemName: "checkmark.circle.fill").font(.caption).padding(4).foregroundStyle(.white)
                        }
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(ep.indexNumber.map { "Episode \($0)" } ?? (ep.episodeLabel ?? ""))
                        .font(.caption2.weight(.semibold)).foregroundStyle(current ? .white : .white.opacity(0.65))
                    Text(ep.displayName).font(.subheadline.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
                    if let rt = ep.runtimeSeconds {
                        Text(current ? "Now playing" : Fmt.runtime(rt)).font(.caption2).foregroundStyle(.white.opacity(0.65))
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(6)
            .background {
                if current { RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.16)) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// What's playing and how (also shows recent engine messages if something's wrong).
struct InfoCard: View {
    let controller: PlaybackController
    let close: () -> Void

    var body: some View {
        let info = controller.player.mediaInformation
        let src = controller.source
        let video = (src?.mediaStreams ?? []).first(where: \.isVideo)
        let sub = controller.player.selectedSubtitle()
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Playback info").font(.headline)
                Spacer()
                Button(action: close) { Image(systemName: "xmark").font(.caption.weight(.bold)).frame(width: 28, height: 28) }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    row("Method", controller.method == .directPlay ? "Direct play (original file)" : "Converted by server")
                    row("Renderer", controller.usesNativeOutput ? "Native (AVFoundation)" : "Metal (libplacebo)")
                    row("A/V sync", controller.audioVideoDrift.map { String(format: "%+.3f s", $0) })
                    row("Container", (info.container ?? src?.container)?.uppercased())
                    row("Video", [info.videoCodec?.uppercased() ?? video?.codec?.uppercased(), video?.profile].compactMap { $0 }.joined(separator: " "))
                    if let d = info.dimensions, d.width > 0 { row("Resolution", "\(d.width)×\(d.height)") }
                    if let fps = info.framesPerSecond { row("Frame rate", String(format: "%.3f fps", fps)) }
                    row("Range", video?.videoRangeType ?? (info.hdr.isHDRContent ? "HDR" : "SDR"))
                    row("Decoder", info.hardwareDecoder.map { "Hardware (\($0))" } ?? "Software")
                    row("Audio", info.audioCodec?.uppercased())
                    row("Subtitle", sub.map { "\($0.codec?.uppercased() ?? "?") \($0.language ?? "")" } ?? "Off")
                    if let b = src?.bitrate { row("Bitrate", Fmt.bitrate(b)) }
                    row("Buffered", String(format: "%.0f s ahead", controller.seconds(controller.player.bufferStatus.bufferedDurationAhead)))
                    if !controller.diagnostics.isEmpty {
                        Text("Engine messages").font(.caption.weight(.bold)).padding(.top, 6)
                        ForEach(Array(controller.diagnostics.suffix(12).enumerated()), id: \.offset) { _, line in
                            Text(line).font(.caption2.monospaced()).foregroundStyle(.white.opacity(0.75)).textSelection(.enabled)
                        }
                    }
                }
                .font(.caption)
            }
            .frame(maxHeight: 220)
        }
        .padding(16)
        .frame(maxWidth: 520)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    @ViewBuilder
    private func row(_ title: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .top) {
                Text(title).foregroundStyle(.white.opacity(0.6)).frame(width: 90, alignment: .leading)
                Text(value)
                Spacer(minLength: 0)
            }
        }
    }
}
