import AVKit
import MediaPlayer
import MPVUI
import SwiftUI
import UIKit

/// The full-screen player: mpv video, Liquid Glass controls, gestures, side panels.
struct PlayerScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let request: PlaybackRequest

    @State private var controller: PlaybackController?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let controller {
                PlayerContent(controller: controller, close: close)
            } else {
                ProgressView().tint(.white)
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
        .task {
            guard controller == nil else { return }
            let c = PlaybackController(request: request, model: model)
            c.player.pictureInPicture.allowsAutomaticStartFromInline = model.settings.pipAutomatically
            controller = c
            OrientationLock.enterPlayer(landscape: model.settings.startInLandscape)
            UIApplication.shared.isIdleTimerDisabled = true
            await c.start()
        }
        .onChange(of: scenePhase) { _, phase in
            guard let c = controller else { return }
            if phase == .background && !model.settings.backgroundAudio && !c.player.pictureInPicture.isActive
                && !model.settings.pipAutomatically {
                c.player.pause()
            }
        }
    }

    private func close() {
        Task {
            await controller?.stop()
            UIApplication.shared.isIdleTimerDisabled = false
            OrientationLock.exitPlayer()
            dismiss()
        }
    }
}

// MARK: - Orientation

/// The app is portrait; the player unlocks landscape while it's open.
enum OrientationLock {
    @MainActor static var mask: UIInterfaceOrientationMask = .portrait

    @MainActor static func enterPlayer(landscape: Bool) {
        mask = .allButUpsideDown
        if landscape { request(.landscape) }
    }

    @MainActor static func exitPlayer() {
        mask = .portrait
        request(.portrait)
    }

    @MainActor static func request(_ orientations: UIInterfaceOrientationMask) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientations)) { _ in }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }

    @MainActor static var isLandscape: Bool {
        (UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.effectiveGeometry.interfaceOrientation.isLandscape) ?? false
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        MainActor.assumeIsolated { OrientationLock.mask }
    }
}

// MARK: - Content

enum PlayerPanel: String, Identifiable {
    case audio, subtitles, speed, chapters, episodes, info
    var id: String { rawValue }
}

private struct PlayerContent: View {
    @Environment(AppModel.self) private var model
    let controller: PlaybackController
    let close: () -> Void

    @State private var showControls = true
    @State private var hideTask: Task<Void, Never>?
    @State private var panel: PlayerPanel?
    @State private var locked = false
    @State private var scrubbing: Double?            // seconds being previewed
    @State private var hud: HUD?
    @State private var hudTask: Task<Void, Never>?
    @State private var holdSpeed = false
    @State private var showRemaining = true

    enum HUD: Equatable {
        case brightness(Double), volume(Double), jump(Double), speed(Double), info(String)
    }

    private var player: MPVPlayer { controller.player }
    private var settings: AppSettings { model.settings }

    var body: some View {
        ZStack {
            MPVVideoPlayer(player: player)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            GestureLayer(controller: controller, settings: settings, locked: locked,
                         onTap: toggleControls,
                         onHUD: showHUD,
                         onScrub: { scrubbing = $0 },
                         onHoldSpeed: { holding in
                             holdSpeed = holding
                             controller.setSpeed(holding ? 2.0 : settings.defaultSpeed)
                         })
                .ignoresSafeArea()

            if case .failed(let message) = controller.phase {
                ErrorCard(message: message, controller: controller, close: close)
            } else if controller.phase == .loading || player.state == .buffering || player.state == .loading {
                LoadingBadge(note: controller.statusNote)
                    .allowsHitTesting(false)
            }

            if locked {
                lockedOverlay
            } else if showControls && controller.phase != .loading || panel != nil {
                controls
                    .transition(.opacity)
            }

            if let hud { HUDView(hud: hud).allowsHitTesting(false).transition(.opacity.combined(with: .scale(scale: 0.9))) }
            if holdSpeed { SpeedBadge().frame(maxHeight: .infinity, alignment: .top).padding(.top, 24).allowsHitTesting(false) }
            if let s = scrubbing, !showControls { ScrubPreview(controller: controller, seconds: s).allowsHitTesting(false) }

            if !locked { cornerCards }

            if let panel {
                PanelHost(panel: panel, controller: controller, close: { withAnimation(.snappy) { self.panel = nil } })
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            if controller.askStillWatching { StillWatchingCard(controller: controller, close: close) }
        }
        .animation(.easeOut(duration: 0.2), value: showControls)
        .animation(.easeOut(duration: 0.2), value: hud)
        .onAppear { scheduleHide() }
        .onChange(of: player.isPaused) { _, paused in if paused { hideTask?.cancel() } else { scheduleHide() } }
    }

    // MARK: Controls

    private var controls: some View {
        ZStack {
            LinearGradient(colors: [.black.opacity(0.65), .clear, .clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            VStack(spacing: 0) {
                topBar
                Spacer()
                transport
                Spacer()
                bottomBar
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            Button(action: close) { Image(systemName: "chevron.down").font(.title3.weight(.semibold)).frame(width: 44, height: 44) }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(controller.item.kind == .episode ? (controller.item.seriesName ?? "") : controller.item.displayName)
                    .font(.headline).lineLimit(1)
                if controller.item.kind == .episode {
                    Text([controller.item.episodeLabel, controller.item.name].compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                }
            }
            .foregroundStyle(.white)
            Spacer()
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    MPVRoutePicker(player: player)
                        .frame(width: 44, height: 44)
                        .glassEffect(.regular, in: .circle)
                    if player.pictureInPicture.isSupported {
                        circleButton(player.pictureInPicture.isActive ? "pip.exit" : "pip.enter") {
                            player.pictureInPicture.toggle()
                        }
                        .disabled(!player.pictureInPicture.isPossible)
                    }
                    circleButton("info.circle") { openPanel(.info) }
                    circleButton("lock.fill") { withAnimation { locked = true } }
                }
            }
        }
    }

    private var transport: some View {
        GlassEffectContainer(spacing: 28) {
            HStack(spacing: 28) {
                if controller.hasPrevious {
                    smallTransport("backward.end.fill") { Task { await controller.playPrevious() } }
                }
                smallTransport("gobackward.\(settings.jumpBackward)") { controller.jump(-Double(settings.jumpBackward)); scheduleHide() }
                Button {
                    controller.togglePlay()
                    scheduleHide()
                } label: {
                    Image(systemName: player.isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 34, weight: .bold))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 84, height: 84)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                smallTransport("goforward.\(settings.jumpForward)") { controller.jump(Double(settings.jumpForward)); scheduleHide() }
                if controller.upNext != nil {
                    smallTransport("forward.end.fill") { Task { await controller.playNext(auto: false) } }
                }
            }
        }
        .foregroundStyle(.white)
    }

    private func smallTransport(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 24, weight: .semibold)).frame(width: 58, height: 58)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
    }

    private func circleButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.body.weight(.semibold)).frame(width: 44, height: 44) }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            Timeline(controller: controller, showRemaining: $showRemaining, scrubbing: $scrubbing, onInteract: scheduleHide)
            ScrollView(.horizontal, showsIndicators: false) {
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        pill("Audio", "waveform", panel: .audio)
                        pill("Subtitles", "captions.bubble", panel: .subtitles)
                        pill(String(format: "%g×", player.playbackRate), "gauge.with.dots.needle.67percent", panel: .speed)
                        if !controller.chapters.isEmpty { pill("Chapters", "list.bullet.rectangle", panel: .chapters) }
                        if controller.item.kind == .episode { pill("Episodes", "rectangle.stack", panel: .episodes) }
                        Button {
                            controller.toggleFill()
                            showHUD(.info(controller.isFilled ? "Fill screen" : "Fit to screen"))
                        } label: {
                            Label(controller.isFilled ? "Fill" : "Fit",
                                  systemImage: controller.isFilled ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 6)
                        }
                        .buttonStyle(.glass)
                        Button {
                            OrientationLock.request(OrientationLock.isLandscape ? .portrait : .landscape)
                        } label: {
                            Image(systemName: "rotate.right").font(.subheadline.weight(.semibold))
                        }
                        .buttonStyle(.glass)
                    }
                }
            }
            .scrollClipDisabled()
        }
        .foregroundStyle(.white)
    }

    private func pill(_ title: String, _ symbol: String, panel: PlayerPanel) -> some View {
        Button { openPanel(panel) } label: {
            Label(title, systemImage: symbol).font(.subheadline.weight(.semibold)).padding(.horizontal, 6)
        }
        .buttonStyle(.glass)
    }

    // MARK: Cards that live outside the controls

    @ViewBuilder
    private var cornerCards: some View {
        VStack(alignment: .trailing, spacing: 12) {
            Spacer()
            if let segment = controller.activeSegment, controller.upNextCountdown == nil {
                Button {
                    controller.skip(segment)
                } label: {
                    Label(controller.skipLabel(segment), systemImage: "forward.fill")
                        .font(.headline)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                }
                .buttonStyle(.glassProminent)
                .tint(.white.opacity(0.25))
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            if let next = controller.upNext, let left = controller.upNextCountdown {
                UpNextCard(controller: controller, next: next, secondsLeft: left)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(.trailing, 24)
        .padding(.bottom, showControls ? 128 : 36)
        .animation(.snappy, value: controller.activeSegment)
        .animation(.snappy, value: controller.upNextCountdown)
    }

    private var lockedOverlay: some View {
        VStack {
            HStack {
                Spacer()
                Button {
                    withAnimation { locked = false }
                    scheduleHide()
                } label: {
                    Label("Unlock", systemImage: "lock.open.fill").font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.glass)
                .opacity(showControls ? 1 : 0.35)
            }
            Spacer()
        }
        .padding(24)
    }

    // MARK: Helpers

    private func toggleControls() {
        withAnimation(.easeOut(duration: 0.2)) { showControls.toggle() }
        if showControls { scheduleHide() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, panel == nil, !player.isPaused, scrubbing == nil else { return }
            withAnimation(.easeOut(duration: 0.3)) { showControls = false }
        }
    }

    private func openPanel(_ p: PlayerPanel) {
        hideTask?.cancel()
        withAnimation(.snappy) { panel = p }
    }

    private func showHUD(_ h: HUD) {
        hud = h
        hudTask?.cancel()
        hudTask = Task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            hud = nil
        }
    }
}

// MARK: - Timeline

private struct Timeline: View {
    let controller: PlaybackController
    @Binding var showRemaining: Bool
    @Binding var scrubbing: Double?
    let onInteract: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        let duration = max(controller.durationSeconds, 0.001)
        let position = scrubbing ?? controller.currentSeconds
        let buffered = controller.player.bufferStatus.bufferedEnd.map { controller.seconds($0) } ?? position
        VStack(spacing: 6) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.22))
                    Capsule().fill(.white.opacity(0.35)).frame(width: w * min(1, max(0, buffered / duration)))
                    Capsule().fill(LinearGradient(colors: [Theme.accent, Theme.pink], startPoint: .leading, endPoint: .trailing))
                        .frame(width: w * min(1, max(0, position / duration)))
                    if model.settings.showChaptersOnSlider {
                        ForEach(Array(controller.chapters.enumerated()), id: \.offset) { _, ch in
                            if ch.start > 1 {
                                Rectangle().fill(.black.opacity(0.6)).frame(width: 2, height: scrubbing != nil ? 10 : 6)
                                    .offset(x: w * ch.start / duration - 1)
                            }
                        }
                    }
                    Circle().fill(.white)
                        .frame(width: scrubbing != nil ? 22 : 14, height: scrubbing != nil ? 22 : 14)
                        .shadow(radius: 3)
                        .offset(x: w * min(1, max(0, position / duration)) - (scrubbing != nil ? 11 : 7))
                }
                .frame(height: scrubbing != nil ? 10 : 6)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            scrubbing = min(duration, max(0, g.location.x / w * duration))
                            onInteract()
                        }
                        .onEnded { _ in
                            if let s = scrubbing { controller.seek(to: s) }
                            scrubbing = nil
                            onInteract()
                        }
                )
                .overlay(alignment: .bottomLeading) {
                    if let s = scrubbing {
                        ScrubPreview(controller: controller, seconds: s, compact: true)
                            .offset(x: min(max(0, w * s / duration - 90), w - 180), y: -34)
                            .allowsHitTesting(false)
                    }
                }
            }
            .frame(height: 30)
            .animation(.snappy(duration: 0.15), value: scrubbing != nil)
            HStack {
                Text(Fmt.clock(position)).monospacedDigit()
                if let chapter = chapterTitle(at: position) {
                    Text("· \(chapter)").lineLimit(1).foregroundStyle(.white.opacity(0.7))
                }
                Spacer()
                Button {
                    showRemaining.toggle()
                } label: {
                    Text(showRemaining ? "−\(Fmt.clock(max(0, duration - position)))" : Fmt.clock(duration)).monospacedDigit()
                }
                .buttonStyle(.plain)
                if model.settings.timestampStyle == .remaining || !showRemaining {
                    Text("ends \(Date().addingTimeInterval((duration - position) / max(controller.player.playbackRate, 0.1)).formatted(date: .omitted, time: .shortened))")
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .font(.caption.weight(.semibold))
        }
        .onAppear { showRemaining = model.settings.timestampStyle == .remaining }
    }

    private func chapterTitle(at s: Double) -> String? {
        controller.chapters.last { $0.start <= s }?.title
    }
}

private struct ScrubPreview: View {
    let controller: PlaybackController
    let seconds: Double
    var compact = false

    var body: some View {
        VStack(spacing: 6) {
            if let tp = controller.trickplay {
                Group {
                    if let image = tp.thumbnail(at: seconds) {
                        Image(uiImage: image).resizable().aspectRatio(tp.aspect, contentMode: .fill)
                    } else {
                        Rectangle().fill(.black.opacity(0.5))
                    }
                }
                .frame(width: 180, height: 180 / tp.aspect)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.5), lineWidth: 1))
            }
            Text(Fmt.clock(seconds))
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .glassEffect(.regular.tint(.black.opacity(0.3)), in: .capsule)
        }
        .frame(maxHeight: compact ? nil : .infinity, alignment: compact ? .bottom : .center)
    }
}

// MARK: - Gestures

private struct GestureLayer: View {
    let controller: PlaybackController
    let settings: AppSettings
    let locked: Bool
    let onTap: () -> Void
    let onHUD: (PlayerContent.HUD) -> Void
    let onScrub: (Double?) -> Void
    let onHoldSpeed: (Bool) -> Void

    @State private var dragKind: DragKind?
    @State private var dragStartValue: Double = 0
    @State private var volume = SystemVolume()
    @State private var holding = false

    enum DragKind { case left(GestureAction), right(GestureAction), horizontal }

    var body: some View {
        GeometryReader { geo in
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { location in
                    guard !locked else { return }
                    switch settings.doubleTap {
                    case .jump:
                        let back = location.x < geo.size.width / 2
                        let amount = Double(back ? -settings.jumpBackward : settings.jumpForward)
                        controller.jump(amount)
                        onHUD(.jump(amount))
                    case .playPause:
                        controller.togglePlay()
                    case .none:
                        break
                    }
                }
                .onTapGesture(count: 1) { onTap() }
                .onLongPressGesture(minimumDuration: 0.4, maximumDistance: 20) {
                    // Fires once the press has lasted long enough: start 2× until released.
                    guard !locked, settings.longPress == .speed2x, !controller.player.isPaused else { return }
                    holding = true
                    onHoldSpeed(true)
                } onPressingChanged: { pressing in
                    if !pressing && holding {
                        holding = false
                        onHoldSpeed(false)
                    }
                }
                .simultaneousGesture(locked ? nil : drag(in: geo.size))
                .simultaneousGesture(locked || !settings.pinchToFill ? nil : MagnifyGesture()
                    .onEnded { value in
                        let fill = value.magnification > 1.05
                        if fill != controller.isFilled {
                            controller.setFill(fill)
                            onHUD(.info(fill ? "Fill screen" : "Fit to screen"))
                        }
                    })
                .background(VolumeViewHost(volume: volume).frame(width: 1, height: 1).opacity(0.01))
        }
    }

    private func drag(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { g in
                if dragKind == nil {
                    let horizontal = abs(g.translation.width) > abs(g.translation.height)
                    if horizontal {
                        guard settings.gestureHorizontal == .scrub else { return }
                        dragKind = .horizontal
                        dragStartValue = controller.currentSeconds
                    } else {
                        let action = g.startLocation.x < size.width / 2 ? settings.gestureLeftVertical : settings.gestureRightVertical
                        guard action != .none else { return }
                        dragKind = g.startLocation.x < size.width / 2 ? .left(action) : .right(action)
                        dragStartValue = currentValue(action)
                    }
                }
                switch dragKind {
                case .horizontal:
                    let span = max(controller.durationSeconds, 1)
                    // Full width ≈ 3 minutes, finer near the start of the drag.
                    let delta = Double(g.translation.width / size.width) * min(span, 180)
                    onScrub(min(span, max(0, dragStartValue + delta)))
                case .left(let action), .right(let action):
                    let delta = -Double(g.translation.height / (size.height * 0.8))
                    apply(action, value: dragStartValue + delta * range(action))
                case .none:
                    break
                }
            }
            .onEnded { g in
                if case .horizontal = dragKind {
                    let span = max(controller.durationSeconds, 1)
                    let delta = Double(g.translation.width / size.width) * min(span, 180)
                    controller.seek(to: min(span, max(0, dragStartValue + delta)))
                    onScrub(nil)
                }
                dragKind = nil
            }
    }

    private func range(_ action: GestureAction) -> Double {
        switch action {
        case .speed: return 2
        case .audioOffset, .subtitleOffset: return 5
        default: return 1
        }
    }

    private func currentValue(_ action: GestureAction) -> Double {
        switch action {
        case .brightness: return Double(Screen.brightness)
        case .volume: return Double(volume.value)
        case .speed: return controller.player.playbackRate
        case .audioOffset: return controller.audioDelay
        case .subtitleOffset: return controller.subtitleDelay
        default: return 0
        }
    }

    private func apply(_ action: GestureAction, value: Double) {
        switch action {
        case .brightness:
            let v = min(1, max(0, value))
            Screen.brightness = CGFloat(v)
            onHUD(.brightness(v))
        case .volume:
            let v = min(1, max(0, value))
            volume.value = Float(v)
            onHUD(.volume(v))
        case .speed:
            let v = (min(3, max(0.25, value)) * 20).rounded() / 20
            controller.setSpeed(v)
            onHUD(.speed(v))
        case .audioOffset:
            let v = (value * 10).rounded() / 10
            controller.setAudioDelay(v)
            onHUD(.info(String(format: "Audio %+.1f s", v)))
        case .subtitleOffset:
            let v = (value * 10).rounded() / 10
            controller.setSubtitleDelay(v)
            onHUD(.info(String(format: "Subtitles %+.1f s", v)))
        default:
            break
        }
    }
}

enum Screen {
    @MainActor static var brightness: CGFloat {
        get { UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first?.brightness ?? 0.5 }
        set { UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first?.brightness = newValue }
    }
}

/// System volume through a hidden MPVolumeView slider (the supported way to change it).
@Observable
@MainActor
final class SystemVolume {
    @ObservationIgnored weak var slider: UISlider?
    var value: Float {
        get { slider?.value ?? AVAudioSession.sharedInstance().outputVolume }
        set {
            slider?.value = newValue
            slider?.sendActions(for: .valueChanged)
        }
    }
}

private struct VolumeViewHost: UIViewRepresentable {
    let volume: SystemVolume
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.showsLargeContentViewer = false
        DispatchQueue.main.async {
            volume.slider = view.subviews.compactMap { $0 as? UISlider }.first
        }
        return view
    }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

// MARK: - HUDs & cards

private struct HUDView: View {
    let hud: PlayerContent.HUD
    var body: some View {
        Group {
            switch hud {
            case .brightness(let v): bar("sun.max.fill", v)
            case .volume(let v): bar(v == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill", v)
            case .jump(let s):
                Label(String(format: "%+.0f s", s), systemImage: s < 0 ? "gobackward" : "goforward").font(.title3.weight(.bold))
                    .padding(.horizontal, 18).padding(.vertical, 12)
            case .speed(let v):
                Label(String(format: "%.2g×", v), systemImage: "gauge.with.dots.needle.67percent").font(.title3.weight(.bold))
                    .padding(.horizontal, 18).padding(.vertical, 12)
            case .info(let t):
                Text(t).font(.headline).padding(.horizontal, 18).padding(.vertical, 12)
            }
        }
        .foregroundStyle(.white)
        .glassEffect(.regular.tint(.black.opacity(0.25)), in: .capsule)
    }

    private func bar(_ symbol: String, _ v: Double) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.title3)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25))
                Capsule().fill(.white).frame(width: 160 * v)
            }
            .frame(width: 160, height: 6)
            Text("\(Int(v * 100))").font(.subheadline.weight(.bold).monospacedDigit()).frame(width: 34)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }
}

private struct SpeedBadge: View {
    var body: some View {
        Label("2× speed", systemImage: "forward.fill")
            .font(.subheadline.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .glassEffect(.regular.tint(.black.opacity(0.25)), in: .capsule)
    }
}

private struct LoadingBadge: View {
    let note: String?
    var body: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large).tint(.white)
            if let note { Text(note).font(.subheadline.weight(.semibold)).foregroundStyle(.white) }
        }
        .padding(22)
        .glassEffect(.regular.tint(.black.opacity(0.2)), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

private struct ErrorCard: View {
    @Environment(AppModel.self) private var model
    let message: String
    let controller: PlaybackController
    let close: () -> Void
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.yellow)
            Text("Couldn't play this").font(.title3.bold())
            Text(message).font(.subheadline).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.8))
            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) {
                    Button("Close", action: close).buttonStyle(.glass)
                    Button("Try again") { Task { await controller.retry() } }.buttonStyle(.glass)
                    if controller.method != .transcode {
                        Button("Convert on server") { Task { await controller.retryWithConversion() } }.buttonStyle(.glassProminent)
                    }
                }
            }
        }
        .foregroundStyle(.white)
        .padding(26)
        .frame(maxWidth: 460)
        .glassEffect(.regular.tint(.black.opacity(0.35)), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .padding()
    }
}

private struct UpNextCard: View {
    @Environment(AppModel.self) private var model
    let controller: PlaybackController
    let next: BaseItem
    let secondsLeft: Int
    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(url: model.client?.landscapeURL(next, width: 400))
                .frame(width: 128, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    ZStack {
                        Circle().stroke(.white.opacity(0.3), lineWidth: 3)
                        Circle().trim(from: 0, to: CGFloat(secondsLeft) / CGFloat(max(1, model.settings.nextUpCountdown)))
                            .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 1), value: secondsLeft)
                        Text("\(secondsLeft)").font(.headline.monospacedDigit())
                    }
                    .frame(width: 40, height: 40)
                }
            VStack(alignment: .leading, spacing: 4) {
                Text("Up next").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
                Text([next.episodeLabel, next.name].compactMap { $0 }.joined(separator: " · ")).font(.subheadline.weight(.semibold)).lineLimit(2)
                HStack(spacing: 8) {
                    Button("Play now") { Task { await controller.playNext(auto: false) } }
                        .buttonStyle(.glassProminent).controlSize(.small)
                    Button("Cancel") { controller.cancelCountdown() }
                        .buttonStyle(.glass).controlSize(.small)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(12)
        .frame(maxWidth: 380)
        .glassEffect(.regular.tint(.black.opacity(0.3)), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private struct StillWatchingCard: View {
    let controller: PlaybackController
    let close: () -> Void
    var body: some View {
        VStack(spacing: 14) {
            Text("Still watching?").font(.title2.bold())
            Text("Playback paused so episodes don't play on with nobody watching.")
                .font(.subheadline).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.8))
            HStack(spacing: 10) {
                Button("I'm done", action: close).buttonStyle(.glass)
                Button("Keep watching") { controller.confirmStillWatching() }.buttonStyle(.glassProminent)
            }
        }
        .foregroundStyle(.white)
        .padding(26)
        .frame(maxWidth: 420)
        .glassEffect(.regular.tint(.black.opacity(0.35)), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }
}
