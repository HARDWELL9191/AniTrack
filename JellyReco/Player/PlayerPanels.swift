import MPVUI
import SwiftUI

/// Glass side panel over the video (better than sheets in landscape: the video keeps playing in view).
struct PanelHost: View {
    let panel: PlayerPanel
    let controller: PlaybackController
    let close: () -> Void

    var body: some View {
        ZStack(alignment: .trailing) {
            Color.black.opacity(0.001)
                .ignoresSafeArea()
                .onTapGesture(perform: close)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(title).font(.title3.bold())
                    Spacer()
                    Button(action: close) { Image(systemName: "xmark").font(.body.weight(.bold)).frame(width: 36, height: 36) }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                }
                .padding([.horizontal, .top], 18)
                .padding(.bottom, 8)
                ScrollView {
                    content.padding(.horizontal, 18).padding(.bottom, 18)
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: 400)
            .frame(maxHeight: .infinity)
            .glassEffect(.regular.tint(.black.opacity(0.45)), in: RoundedRectangle(cornerRadius: 30, style: .continuous))
            .padding(12)
        }
    }

    private var title: String {
        switch panel {
        case .audio: return "Audio"
        case .subtitles: return "Subtitles"
        case .speed: return "Playback speed"
        case .chapters: return "Chapters"
        case .episodes: return "Episodes"
        case .info: return "Playback info"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch panel {
        case .audio: AudioPanel(controller: controller)
        case .subtitles: SubtitlePanel(controller: controller)
        case .speed: SpeedPanel(controller: controller)
        case .chapters: ChaptersPanel(controller: controller, close: close)
        case .episodes: EpisodesPanel(controller: controller, close: close)
        case .info: InfoPanel(controller: controller)
        }
    }
}

private struct OptionRow: View {
    let title: String
    let detail: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Theme.accent : .white.opacity(0.4))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold)).lineLimit(2)
                    if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.white.opacity(0.65)) }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(selected ? Color.white.opacity(0.14) : Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct DelayControl: View {
    let label: String
    let value: Double
    let set: (Double) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(label).font(.subheadline.weight(.semibold))
                Spacer()
                Text(String(format: "%+.2f s", value)).font(.subheadline.monospacedDigit()).foregroundStyle(.white.opacity(0.8))
            }
            HStack(spacing: 8) {
                ForEach([-0.5, -0.1, 0.1, 0.5], id: \.self) { step in
                    Button(String(format: "%+.1f", step)) { set(((value + step) * 100).rounded() / 100) }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                }
                Spacer()
                Button("Reset") { set(0) }.buttonStyle(.glass).controlSize(.small).disabled(value == 0)
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct AudioPanel: View {
    let controller: PlaybackController
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(controller.audioOptions) { t in
                OptionRow(title: t.title, detail: t.detail, selected: t.isSelected) { controller.selectAudio(t.id) }
            }
            if controller.audioOptions.isEmpty { Text("No audio tracks").foregroundStyle(.white.opacity(0.6)) }
            DelayControl(label: "Audio sync", value: controller.audioDelay) { controller.setAudioDelay($0) }
                .padding(.top, 6)
        }
    }
}

private struct SubtitlePanel: View {
    @Environment(AppModel.self) private var model
    let controller: PlaybackController
    @State private var tab = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $tab) {
                Text("Main").tag(0)
                Text("Second line").tag(1)
                Text("Style").tag(2)
            }
            .pickerStyle(.segmented)
            switch tab {
            case 0:
                let anySelected = controller.subtitleOptions.contains(where: \.isSelected)
                OptionRow(title: "Off", detail: "", selected: !anySelected) { controller.selectSubtitle(nil) }
                ForEach(controller.subtitleOptions) { t in
                    OptionRow(title: t.title, detail: t.detail, selected: t.isSelected) { controller.selectSubtitle(t.id) }
                }
                DelayControl(label: "Subtitle sync", value: controller.subtitleDelay) { controller.setSubtitleDelay($0) }
                    .padding(.top, 6)
            case 1:
                Text("Show a second subtitle at the same time, e.g. Japanese and English for learning.")
                    .font(.caption).foregroundStyle(.white.opacity(0.7))
                let secondary = controller.secondarySubtitle
                OptionRow(title: "Off", detail: "", selected: secondary == nil) { controller.selectSubtitle(nil, secondary: true) }
                ForEach(controller.player.subtitleTracks, id: \.id) { t in
                    let opt = controller.subtitleOptions.first { $0.id == t.id }
                    OptionRow(title: opt?.title ?? "Track \(t.mpvID)", detail: opt?.detail ?? "",
                              selected: t.subtitleRole == .secondary) { controller.selectSubtitle(t.id, secondary: true) }
                }
            default:
                SubtitleStyleControls(controller: controller)
            }
        }
    }
}

private struct SubtitleStyleControls: View {
    @Environment(AppModel.self) private var model
    let controller: PlaybackController
    var body: some View {
        @Bindable var s = model.settings
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading) {
                Text("Size \(Int(s.subtitleSize * 100))%").font(.subheadline.weight(.semibold))
                Slider(value: $s.subtitleSize, in: 0.6...2.0, step: 0.05)
                    .onChange(of: s.subtitleSize) { _, v in controller.player.setProperty("sub-scale", to: String(format: "%.2f", v)) }
            }
            VStack(alignment: .leading) {
                Text("Position \(s.subtitlePosition)%").font(.subheadline.weight(.semibold))
                Slider(value: Binding(get: { Double(s.subtitlePosition) }, set: { s.subtitlePosition = Int($0) }), in: 50...100, step: 1)
                    .onChange(of: s.subtitlePosition) { _, v in controller.player.setProperty("sub-pos", to: "\(v)") }
            }
            Picker("Colour", selection: $s.subtitleColor) { ForEach(SubtitleColor.allCases) { Text($0.label).tag($0) } }
                .pickerStyle(.segmented)
                .onChange(of: s.subtitleColor) { _, v in controller.player.setProperty("sub-color", to: v.mpvHex) }
            Toggle("Bold", isOn: $s.subtitleBold)
                .onChange(of: s.subtitleBold) { _, v in controller.player.setProperty("sub-bold", to: v ? "yes" : "no") }
            Toggle("Override styled (ASS) subtitles", isOn: $s.overrideASSStyles)
                .onChange(of: s.overrideASSStyles) { _, v in controller.player.setProperty("sub-ass-override", to: v ? "force" : "scale") }
        }
        .tint(Theme.accent)
    }
}

private struct SpeedPanel: View {
    let controller: PlaybackController
    private let speeds: [Double] = [0.5, 0.75, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]
    var body: some View {
        let current = controller.player.playbackRate
        VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 70), spacing: 8)], spacing: 8) {
                ForEach(speeds, id: \.self) { v in
                    Button {
                        controller.setSpeed(v)
                    } label: {
                        Text(String(format: "%g×", v)).font(.subheadline.weight(.bold)).frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    .background(abs(current - v) < 0.01 ? Theme.accent : Color.white.opacity(0.1), in: Capsule())
                }
            }
            VStack(alignment: .leading) {
                Text(String(format: "Custom: %.2f×", current)).font(.subheadline.weight(.semibold))
                Slider(value: Binding(get: { current }, set: { controller.setSpeed(($0 * 20).rounded() / 20) }), in: 0.25...4.0)
                    .tint(Theme.accent)
            }
            Text("Pitch stays natural at every speed.").font(.caption).foregroundStyle(.white.opacity(0.6))
        }
    }
}

private struct ChaptersPanel: View {
    let controller: PlaybackController
    let close: () -> Void
    var body: some View {
        let now = controller.currentSeconds
        let chapters = controller.chapters
        VStack(spacing: 10) {
            ForEach(Array(chapters.enumerated()), id: \.offset) { i, ch in
                let next = i + 1 < chapters.count ? chapters[i + 1].start : controller.durationSeconds
                let current = now >= ch.start && now < next
                Button {
                    controller.seek(to: ch.start)
                    close()
                } label: {
                    HStack(spacing: 12) {
                        Group {
                            if let url = ch.imageURL {
                                RemoteImage(url: url)
                            } else if let tp = controller.trickplay, let img = tp.thumbnail(at: ch.start + 2) {
                                Image(uiImage: img).resizable().scaledToFill()
                            } else {
                                Rectangle().fill(.white.opacity(0.08)).overlay(Text("\(i + 1)").font(.headline))
                            }
                        }
                        .frame(width: 112, height: 63)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ch.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                            Text(Fmt.clock(ch.start)).font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.65))
                        }
                        Spacer(minLength: 0)
                        if current { Image(systemName: "play.fill").foregroundStyle(Theme.accent) }
                    }
                    .padding(8)
                    .background(current ? Color.white.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct EpisodesPanel: View {
    @Environment(AppModel.self) private var model
    let controller: PlaybackController
    let close: () -> Void
    @State private var episodes: [BaseItem] = []

    var body: some View {
        VStack(spacing: 10) {
            ForEach(episodes) { ep in
                let current = ep.id == controller.item.id
                Button {
                    guard !current else { return }
                    close()
                    Task { await controller.switchTo(ep) }
                } label: {
                    HStack(spacing: 12) {
                        RemoteImage(url: model.client?.landscapeURL(ep, width: 320))
                            .frame(width: 112, height: 63)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(alignment: .bottom) {
                                if let p = model.userData(for: ep)?.playedPercentage, p > 0, p < 100 { ProgressBar(value: p / 100).padding(5) }
                            }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(ep.episodeLabel ?? "") \(ep.displayName)").font(.subheadline.weight(.semibold)).lineLimit(2)
                            if let rt = ep.runtimeSeconds { Text(Fmt.runtime(rt)).font(.caption).foregroundStyle(.white.opacity(0.65)) }
                        }
                        Spacer(minLength: 0)
                        if current { Image(systemName: "speaker.wave.2.fill").foregroundStyle(Theme.accent) }
                        else if model.isPlayed(ep) { Image(systemName: "checkmark.circle.fill").foregroundStyle(.white.opacity(0.5)) }
                    }
                    .padding(8)
                    .background(current ? Color.white.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            if episodes.isEmpty { ProgressView().tint(.white) }
        }
        .task {
            guard let client = model.client, let sid = controller.item.seriesId else { return }
            episodes = (try? await client.episodes(seriesId: sid, seasonId: controller.item.seasonId)) ?? []
        }
    }
}

/// "Stats for nerds": what's playing and how.
private struct InfoPanel: View {
    let controller: PlaybackController
    var body: some View {
        let info = controller.player.mediaInformation
        let src = controller.source
        let video = (src?.mediaStreams ?? []).first(where: \.isVideo)
        VStack(alignment: .leading, spacing: 8) {
            row("Method", controller.method == .directPlay ? "Direct play" : "Converted by server")
            row("Renderer", controller.player.configuration.videoOutput == .sampleBuffer ? "Native (AVFoundation)" : "Metal (libplacebo)")
            row("Container", (info.container ?? src?.container)?.uppercased())
            row("Video", [info.videoCodec?.uppercased() ?? video?.codec?.uppercased(), video?.profile].compactMap { $0 }.joined(separator: " "))
            if let d = info.dimensions, d.width > 0 { row("Resolution", "\(d.width)×\(d.height)") }
            if let fps = info.framesPerSecond { row("Frame rate", String(format: "%.3f fps", fps)) }
            row("Range", video?.videoRangeType ?? (info.hdr.isHDRContent ? "HDR" : "SDR"))
            row("HDR output", info.hdr.isHDRActive ? "Active" : (info.hdr.isDisplayHDRCapable ? "Available" : "Not supported"))
            row("Decoder", info.hardwareDecoder.map { "Hardware (\($0))" } ?? "Software")
            row("Audio", info.audioCodec?.uppercased())
            if let b = src?.bitrate { row("Bitrate", Fmt.bitrate(b)) }
            if let size = src?.size { row("File size", Fmt.bytes(size)) }
            let buf = controller.player.bufferStatus
            row("Buffered ahead", String(format: "%.0f s", controller.seconds(buf.bufferedDurationAhead)))
            if buf.inputRate > 0 { row("Network", Fmt.bitrate(Int(buf.inputRate * 8))) }
        }
        .font(.subheadline)
    }

    @ViewBuilder
    private func row(_ title: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .top) {
                Text(title).foregroundStyle(.white.opacity(0.6)).frame(width: 120, alignment: .leading)
                Text(value).textSelection(.enabled)
                Spacer(minLength: 0)
            }
        }
    }
}
