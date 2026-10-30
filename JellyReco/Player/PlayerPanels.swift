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

/// The season's episodes in a row above the timeline.
struct EpisodesStrip: View {
    @Environment(AppModel.self) private var model
    let controller: PlaybackController
    let close: () -> Void
    @State private var episodes: [BaseItem] = []

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(episodes) { ep in
                        let current = ep.id == controller.item.id
                        Button {
                            guard !current else { return }
                            close()
                            Task { await controller.switchTo(ep) }
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                RemoteImage(url: model.client?.landscapeURL(ep, width: 400))
                                    .frame(width: 176, height: 99)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .overlay(alignment: .bottom) {
                                        if let p = model.userData(for: ep)?.playedPercentage, p > 0, p < 100 {
                                            ProgressBar(value: p / 100).padding(6)
                                        }
                                    }
                                    .overlay {
                                        if current {
                                            RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white, lineWidth: 2)
                                        }
                                    }
                                    .overlay(alignment: .topTrailing) {
                                        if model.isPlayed(ep) {
                                            Image(systemName: "checkmark.circle.fill").padding(6).foregroundStyle(.white)
                                        }
                                    }
                                Text("\(ep.episodeLabel ?? "") \(ep.displayName)").font(.caption.weight(.semibold)).lineLimit(1)
                                if let rt = ep.runtimeSeconds {
                                    Text(Fmt.runtime(rt)).font(.caption2).foregroundStyle(.white.opacity(0.7))
                                }
                            }
                            .frame(width: 176, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .id(ep.id)
                    }
                }
                .padding(.horizontal, 4)
            }
            .scrollClipDisabled()
            .onChange(of: episodes) { _, _ in proxy.scrollTo(controller.item.id, anchor: .center) }
        }
        .frame(height: 140)
        .task {
            guard let client = model.client, let sid = controller.item.seriesId else { return }
            episodes = (try? await client.episodes(seriesId: sid, seasonId: controller.item.seasonId)) ?? []
        }
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
