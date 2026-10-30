import AVKit
import MediaPlayer
import MPVUI
import SwiftUI
import UIKit

/// The full-screen player. Same layout and controls as Apple's iOS 26 player (glass circles,
/// thin timeline, Speed / Audio & Subtitles / More menus), with mpv underneath so every file
/// plays directly, plus a few extras: two subtitles at once, sync, skip intro, next episode.
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
                && !(model.settings.pipAutomatically && c.usesNativeOutput) {
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

enum PlayerPanel: String, Identifiable {
    case chapters, episodes, info
    var id: String { rawValue }
}

// MARK: - Content

private struct PlayerContent: View {
    @Environment(AppModel.self) private var model
    let controller: PlaybackController
    let close: () -> Void

    @State private var showControls = true
    @State private var hideTask: Task<Void, Never>?
    @State private var panel: PlayerPanel?
    @State private var locked = false
    @State private var scrubbing: Double?
    @State private var hud: HUD?
    @State private var hudTask: Task<Void, Never>?
    @State private var holdSpeed = false
    @State private var pinch: CGFloat?          // live pinch scale (nil when not pinching)
    @State private var volume = SystemVolume()

    enum HUD: Equatable {
        case brightness(Double), volume(Double), jump(Double), text(String)
    }

    private var player: MPVPlayer { controller.player }
    private var settings: AppSettings { model.settings }

    var body: some View {
        ZStack {
            VideoSurface(controller: controller, pinch: pinch)
                .ignoresSafeArea()

            TouchLayer(
                onTap: { toggleControls() },
                onDoubleTap: { side in doubleTap(side) },
                onPinch: { scale, ended in pinchChanged(scale, ended: ended) },
                onVerticalPan: { side, delta, ended in verticalPan(side: side, delta: delta, ended: ended) },
                onSwipeDown: { close() },
                onHold: { holding in hold(holding) },
                isLocked: locked
            )
            .ignoresSafeArea()

            if case .failed(let message) = controller.phase {
                ErrorCard(message: message, controller: controller, close: close)
            } else if controller.phase == .loading || player.state == .buffering || player.state == .loading {
                LoadingBadge(note: controller.statusNote).allowsHitTesting(false)
            }

            if locked {
                lockedOverlay
            } else if showControls || panel != nil {
                controls.transition(.opacity)
            }

            if !locked { cornerCards }
            if let hud { HUDView(hud: hud).allowsHitTesting(false).transition(.opacity) }
            if holdSpeed {
                Label("2×", systemImage: "forward.fill")
                    .font(.subheadline.weight(.bold)).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .glassEffect(.regular, in: .capsule)
                    .frame(maxHeight: .infinity, alignment: .top).padding(.top, 20)
                    .allowsHitTesting(false)
            }
            if controller.askStillWatching { StillWatchingCard(controller: controller, close: close) }
            VolumeViewHost(volume: volume).frame(width: 1, height: 1).opacity(0.01).allowsHitTesting(false)
        }
        .animation(.easeInOut(duration: 0.25), value: showControls)
        .animation(.easeOut(duration: 0.2), value: hud)
        .animation(.snappy, value: panel)
        .onAppear { scheduleHide() }
        .onChange(of: player.isPaused) { _, paused in if paused { hideTask?.cancel() } else { scheduleHide() } }
    }

    // MARK: Apple-style controls

    private var controls: some View {
        ZStack {
            // Apple's soft top and bottom shading, only where the controls are.
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom).frame(height: 140)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom).frame(height: 200)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar
                Spacer()
                transport
                Spacer()
                if let panel { panelView(panel).padding(.bottom, 12) }
                bottomBar
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .foregroundStyle(.white)
    }

    private var topBar: some View {
        HStack(alignment: .top) {
            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) {
                    glassCircle("xmark", size: 44, action: close)
                    if player.pictureInPicture.isSupported {
                        glassCircle(player.pictureInPicture.isActive ? "pip.exit" : "pip.enter", size: 44) {
                            player.pictureInPicture.toggle()
                        }
                        .disabled(!player.pictureInPicture.isPossible)
                    }
                }
            }
            Spacer()
            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) {
                    VolumeCapsule(volume: volume)
                    MPVRoutePicker(player: player)
                        .frame(width: 44, height: 44)
                        .glassEffect(.regular.interactive(), in: .circle)
                }
            }
        }
    }

    private var transport: some View {
        GlassEffectContainer(spacing: 40) {
            HStack(spacing: 40) {
                glassCircle("gobackward.\(settings.jumpBackward)", size: 58, font: .title2) {
                    controller.jump(-Double(settings.jumpBackward))
                    scheduleHide()
                }
                Button {
                    controller.togglePlay()
                    scheduleHide()
                } label: {
                    Image(systemName: player.isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 34, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 78, height: 78)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                glassCircle("goforward.\(settings.jumpForward)", size: 58, font: .title2) {
                    controller.jump(Double(settings.jumpForward))
                    scheduleHide()
                }
            }
        }
    }

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    if controller.item.kind == .episode {
                        Text([controller.item.seriesName, controller.item.episodeLabel].compactMap { $0 }.joined(separator: " · "))
                            .font(.subheadline).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    }
                    Text(controller.item.displayName).font(.headline).lineLimit(1)
                }
                Spacer()
                GlassEffectContainer(spacing: 10) {
                    HStack(spacing: 10) {
                        speedMenu
                        audioSubtitleMenu
                        moreMenu
                    }
                }
            }
            AppleTimeline(controller: controller, scrubbing: $scrubbing, onInteract: scheduleHide)
        }
    }

    // MARK: Menus (native iOS menus, like Apple's player)

    private var speedMenu: some View {
        Menu {
            Picker("Playback Speed", selection: Binding(get: { player.playbackRate }, set: { controller.setSpeed($0) })) {
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0], id: \.self) { rate in
                    Text(rate == 1 ? "1× (Normal)" : String(format: "%g×", rate)).tag(rate)
                }
            }
        } label: {
            menuCircle("gauge.with.dots.needle.67percent")
        }
        .menuOrder(.fixed)
    }

    private var audioSubtitleMenu: some View {
        Menu {
            Section("Audio") {
                Picker("Audio", selection: Binding(
                    get: { controller.audioOptions.first(where: \.isSelected)?.id },
                    set: { if let id = $0 { controller.selectAudio(id) } })) {
                    ForEach(controller.audioOptions) { t in
                        Text(t.title).tag(Optional(t.id))
                    }
                }
                .pickerStyle(.inline)
            }
            Section("Subtitles") {
                Picker("Subtitles", selection: Binding(
                    get: { controller.subtitleOptions.first(where: \.isSelected)?.id },
                    set: { controller.selectSubtitle($0) })) {
                    Text("Off").tag(MPVMediaTrackIdentifier?.none)
                    ForEach(controller.subtitleOptions) { t in
                        Text(t.detail.isEmpty ? t.title : "\(t.title) (\(t.detail))").tag(Optional(t.id))
                    }
                }
                .pickerStyle(.inline)
            }
            Section {
                Menu("Second subtitle line") {
                    Picker("Second subtitle", selection: Binding(
                        get: { controller.secondarySubtitle?.id },
                        set: { controller.selectSubtitle($0, secondary: true) })) {
                        Text("Off").tag(MPVMediaTrackIdentifier?.none)
                        ForEach(controller.subtitleOptions) { t in Text(t.title).tag(Optional(t.id)) }
                    }
                }
                delayMenu("Subtitle timing", value: controller.subtitleDelay) { controller.setSubtitleDelay($0) }
                delayMenu("Audio timing", value: controller.audioDelay) { controller.setAudioDelay($0) }
                Menu("Subtitle size") {
                    Picker("Size", selection: Binding(get: { settings.subtitleSize }, set: { v in
                        settings.subtitleSize = v
                        player.setProperty("sub-scale", to: String(format: "%.2f", v))
                    })) {
                        Text("Small").tag(0.8)
                        Text("Medium").tag(1.0)
                        Text("Large").tag(1.25)
                        Text("Extra large").tag(1.5)
                    }
                }
            }
        } label: {
            menuCircle("text.bubble")
        }
    }

    private func delayMenu(_ title: String, value: Double, set: @escaping (Double) -> Void) -> some View {
        Menu("\(title) (\(String(format: "%+.1f s", value)))") {
            Button("Earlier by 0.5 s") { set(value - 0.5) }
            Button("Earlier by 0.1 s") { set(value - 0.1) }
            Button("Later by 0.1 s") { set(value + 0.1) }
            Button("Later by 0.5 s") { set(value + 0.5) }
            Button("Reset") { set(0) }.disabled(value == 0)
        }
    }

    private var moreMenu: some View {
        Menu {
            if !controller.chapters.isEmpty {
                Button("Chapters", systemImage: "list.bullet.rectangle") { openPanel(.chapters) }
            }
            if controller.item.kind == .episode {
                Button("Episodes", systemImage: "rectangle.stack") { openPanel(.episodes) }
                if controller.upNext != nil {
                    Button("Next episode", systemImage: "forward.end.fill") { Task { await controller.playNext(auto: false) } }
                }
            }
            Button(controller.isFilled ? "Fit to screen" : "Fill screen",
                   systemImage: controller.isFilled ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") {
                withAnimation(.snappy) { controller.toggleFill() }
            }
            Button("Lock controls", systemImage: "lock") { withAnimation { locked = true } }
            Divider()
            Picker("Renderer", selection: Binding(get: { controller.usesNativeOutput },
                                                 set: { native in Task { await controller.switchRenderer(toMetal: !native) } })) {
                Text("Native (PiP, Dolby Vision)").tag(true)
                Text("High quality (Metal)").tag(false)
            }
            Button("Playback info", systemImage: "info.circle") { openPanel(.info) }
        } label: {
            menuCircle("ellipsis")
        }
    }

    private func menuCircle(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.body.weight(.semibold))
            .frame(width: 44, height: 44)
            .glassEffect(.regular.interactive(), in: .circle)
    }

    private func glassCircle(_ symbol: String, size: CGFloat, font: Font = .body, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(font.weight(.semibold))
                .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
    }

    @ViewBuilder
    private func panelView(_ p: PlayerPanel) -> some View {
        switch p {
        case .chapters: ChaptersStrip(controller: controller) { panel = nil }
        case .episodes: EpisodesStrip(controller: controller) { panel = nil }
        case .info: InfoCard(controller: controller) { panel = nil }
        }
    }

    // MARK: Cards outside the controls

    private var cornerCards: some View {
        VStack(alignment: .trailing, spacing: 12) {
            Spacer()
            if let segment = controller.activeSegment, controller.upNextCountdown == nil {
                Button { controller.skip(segment) } label: {
                    Text(controller.skipLabel(segment)).font(.headline).padding(.horizontal, 18).padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .glassEffect(.regular.interactive(), in: .capsule)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            if let next = controller.upNext, let left = controller.upNextCountdown {
                UpNextCard(controller: controller, next: next, secondsLeft: left)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(.trailing, 24)
        .padding(.bottom, showControls ? 150 : 36)
        .animation(.snappy, value: controller.activeSegment)
        .animation(.snappy, value: controller.upNextCountdown)
    }

    private var lockedOverlay: some View {
        VStack {
            if showControls {
                Button {
                    withAnimation { locked = false }
                    scheduleHide()
                } label: {
                    Label("Unlock", systemImage: "lock.open.fill").font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16).padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .glassEffect(.regular.interactive(), in: .capsule)
            }
            Spacer()
        }
        .padding(24)
    }

    // MARK: Gestures

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.25)) { showControls.toggle() }
        if showControls { scheduleHide() } else if panel != nil { panel = nil }
    }

    private func doubleTap(_ side: TouchLayer.Side) {
        guard !locked else { return }
        switch settings.doubleTap {
        case .jump:
            switch side {
            case .left:
                controller.jump(-Double(settings.jumpBackward)); showHUD(.jump(-Double(settings.jumpBackward)))
            case .right:
                controller.jump(Double(settings.jumpForward)); showHUD(.jump(Double(settings.jumpForward)))
            case .center:
                withAnimation(.snappy) { controller.toggleFill() }   // like Apple: double-tap the middle to zoom
            }
        case .playPause:
            controller.togglePlay()
        case .none:
            break
        }
    }

    private func pinchChanged(_ scale: CGFloat, ended: Bool) {
        guard !locked, settings.pinchToFill else { return }
        if ended {
            pinch = nil
            withAnimation(.snappy) { controller.setFill(scale > 1.0) }
        } else {
            pinch = scale
        }
    }

    @State private var panStart: Double = 0

    private func verticalPan(side: TouchLayer.Side, delta: CGFloat?, ended: Bool) {
        guard !locked else { return }
        let action = side == .left ? settings.gestureLeftVertical : settings.gestureRightVertical
        guard let delta else {   // began
            panStart = action == .brightness ? Double(Screen.brightness) : Double(volume.value)
            return
        }
        guard !ended else { return }
        let v = min(1, max(0, panStart + Double(delta)))
        switch action {
        case .brightness:
            Screen.brightness = CGFloat(v)
            showHUD(.brightness(v))
        case .volume:
            volume.value = Float(v)
            showHUD(.volume(v))
        default:
            break
        }
    }

    private func hold(_ holding: Bool) {
        guard !locked, settings.longPress == .speed2x else { return }
        if holding && player.isPaused { return }
        holdSpeed = holding
        controller.setSpeed(holding ? 2.0 : settings.defaultSpeed)
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, panel == nil, !player.isPaused, scrubbing == nil else { return }
            withAnimation(.easeInOut(duration: 0.3)) { showControls = false }
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

// MARK: - Video surface (fit / fill / pinch)

/// The video is laid out at its exact fitted size, then scaled up to fill (the method Swiftfin
/// uses with this engine; mpv's own zoom options don't apply to the native video layer).
private struct VideoSurface: View {
    let controller: PlaybackController
    let pinch: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let container = geo.size
            let dims = controller.player.mediaInformation.dimensions
            let video = (dims?.width ?? 0) > 0 && (dims?.height ?? 0) > 0
                ? CGSize(width: CGFloat(dims!.width), height: CGFloat(dims!.height))
                : CGSize(width: 16, height: 9)
            let fit = min(container.width / video.width, container.height / video.height)
            let fitted = CGSize(width: video.width * fit, height: video.height * fit)
            let fillScale = max(container.width / max(fitted.width, 1), container.height / max(fitted.height, 1))
            let base: CGFloat = controller.isFilled ? fillScale : 1
            let scale = min(max(base * (pinch ?? 1), 1), fillScale * 1.5)
            MPVVideoPlayer(player: controller.player)
                .frame(width: fitted.width, height: fitted.height)
                .scaleEffect(scale)
                .frame(width: container.width, height: container.height)
                .clipped()
                .allowsHitTesting(false)
        }
    }
}

// MARK: - Timeline (Apple style)

private struct AppleTimeline: View {
    let controller: PlaybackController
    @Binding var scrubbing: Double?
    let onInteract: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        let duration = max(controller.durationSeconds, 0.001)
        let position = scrubbing ?? controller.currentSeconds
        let buffered = controller.player.bufferStatus.bufferedEnd.map { controller.seconds($0) } ?? position
        let active = scrubbing != nil
        VStack(spacing: 6) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25))
                    Capsule().fill(.white.opacity(0.35)).frame(width: w * min(1, max(0, buffered / duration)))
                    Capsule().fill(.white).frame(width: w * min(1, max(0, position / duration)))
                    if model.settings.showChaptersOnSlider {
                        ForEach(Array(controller.chapters.enumerated()), id: \.offset) { _, ch in
                            if ch.start > 1 && ch.start < duration - 1 {
                                Rectangle().fill(.black.opacity(0.7)).frame(width: 2)
                                    .offset(x: w * ch.start / duration - 1)
                            }
                        }
                    }
                }
                .frame(height: active ? 12 : 6)
                .clipShape(Capsule())
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            scrubbing = min(duration, max(0, g.location.x / max(w, 1) * duration))
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
                        ScrubPreview(controller: controller, seconds: s)
                            .offset(x: min(max(0, w * s / duration - 90), max(0, w - 180)), y: -30)
                            .allowsHitTesting(false)
                    }
                }
            }
            .frame(height: 28)
            .animation(.snappy(duration: 0.15), value: active)
            HStack {
                Text(Fmt.clock(position)).monospacedDigit()
                if let chapter = controller.chapters.last(where: { $0.start <= position })?.title, controller.chapters.count > 1 {
                    Text(chapter).lineLimit(1).foregroundStyle(.white.opacity(0.7))
                }
                Spacer()
                Text("−\(Fmt.clock(max(0, duration - position)))").monospacedDigit()
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white.opacity(0.85))
        }
    }
}

private struct ScrubPreview: View {
    let controller: PlaybackController
    let seconds: Double

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
            }
            Text(Fmt.clock(seconds))
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .glassEffect(.regular, in: .capsule)
        }
    }
}

// MARK: - Touch handling (UIKit recognizers, like Apple's player)

private struct TouchLayer: UIViewRepresentable {
    enum Side { case left, center, right }

    let onTap: () -> Void
    let onDoubleTap: (Side) -> Void
    let onPinch: (CGFloat, Bool) -> Void
    /// delta nil = began; values are fractions of the screen height (up = positive).
    let onVerticalPan: (Side, CGFloat?, Bool) -> Void
    let onSwipeDown: () -> Void
    let onHold: (Bool) -> Void
    let isLocked: Bool

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let c = context.coordinator

        let double = UITapGestureRecognizer(target: c, action: #selector(Coordinator.doubleTap(_:)))
        double.numberOfTapsRequired = 2
        let single = UITapGestureRecognizer(target: c, action: #selector(Coordinator.tap(_:)))
        single.require(toFail: double)
        let pinch = UIPinchGestureRecognizer(target: c, action: #selector(Coordinator.pinch(_:)))
        let pan = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.pan(_:)))
        pan.maximumNumberOfTouches = 1
        let hold = UILongPressGestureRecognizer(target: c, action: #selector(Coordinator.hold(_:)))
        hold.minimumPressDuration = 0.45
        for g in [double, single, pinch, pan, hold] as [UIGestureRecognizer] {
            g.delegate = c
            view.addGestureRecognizer(g)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: TouchLayer
        private var panSide: Side = .center
        private var panMode: PanMode = .none
        enum PanMode { case none, vertical, dismiss }

        init(parent: TouchLayer) { self.parent = parent }

        private func side(_ g: UIGestureRecognizer) -> Side {
            guard let v = g.view else { return .center }
            let x = g.location(in: v).x / max(v.bounds.width, 1)
            return x < 0.35 ? .left : (x > 0.65 ? .right : .center)
        }

        @objc func tap(_ g: UITapGestureRecognizer) { parent.onTap() }

        @objc func doubleTap(_ g: UITapGestureRecognizer) {
            guard !parent.isLocked else { parent.onTap(); return }
            parent.onDoubleTap(side(g))
        }

        @objc func pinch(_ g: UIPinchGestureRecognizer) {
            switch g.state {
            case .changed: parent.onPinch(g.scale, false)
            case .ended, .cancelled, .failed: parent.onPinch(g.scale, true)
            default: break
            }
        }

        @objc func pan(_ g: UIPanGestureRecognizer) {
            guard let v = g.view, !parent.isLocked else { return }
            let t = g.translation(in: v)
            switch g.state {
            case .began:
                let vel = g.velocity(in: v)
                panSide = side(g)
                if panSide == .center && vel.y > 0 && abs(vel.y) > abs(vel.x) {
                    panMode = .dismiss
                } else if abs(vel.y) > abs(vel.x) && panSide != .center {
                    panMode = .vertical
                    parent.onVerticalPan(panSide, nil, false)
                } else {
                    panMode = .none
                }
            case .changed:
                if panMode == .vertical {
                    parent.onVerticalPan(panSide, -t.y / max(v.bounds.height * 0.75, 1), false)
                }
            case .ended:
                if panMode == .dismiss && t.y > v.bounds.height * 0.22 { parent.onSwipeDown() }
                if panMode == .vertical { parent.onVerticalPan(panSide, 0, true) }
                panMode = .none
            default:
                panMode = .none
            }
        }

        @objc func hold(_ g: UILongPressGestureRecognizer) {
            switch g.state {
            case .began: parent.onHold(true)
            case .ended, .cancelled, .failed: parent.onHold(false)
            default: break
            }
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            g is UIPinchGestureRecognizer || other is UIPinchGestureRecognizer
        }
    }
}

// MARK: - Brightness & volume

enum Screen {
    @MainActor static var brightness: CGFloat {
        get { UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first?.brightness ?? 0.5 }
        set { UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first?.brightness = newValue }
    }
}

/// System volume through a hidden MPVolumeView slider (the supported way to change it; also
/// keeps the system volume HUD from covering the video).
@Observable
@MainActor
final class SystemVolume {
    @ObservationIgnored weak var slider: UISlider?
    var shown: Float = AVAudioSession.sharedInstance().outputVolume
    var value: Float {
        get { slider?.value ?? shown }
        set {
            shown = newValue
            slider?.value = newValue
            slider?.sendActions(for: .valueChanged)
        }
    }
}

private struct VolumeViewHost: UIViewRepresentable {
    let volume: SystemVolume
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        DispatchQueue.main.async {
            volume.slider = view.subviews.compactMap { $0 as? UISlider }.first
            if let v = volume.slider?.value { volume.shown = v }
        }
        return view
    }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

/// Apple's top-right volume capsule: speaker icon + slider.
private struct VolumeCapsule: View {
    let volume: SystemVolume
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: volume.shown == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.subheadline.weight(.semibold))
                .frame(width: 22)
            Slider(value: Binding(get: { Double(volume.shown) }, set: { volume.value = Float($0) }), in: 0...1)
                .tint(.white)
                .frame(width: 96)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .glassEffect(.regular.interactive(), in: .capsule)
    }
}

// MARK: - HUD & cards

private struct HUDView: View {
    let hud: PlayerContent.HUD
    var body: some View {
        Group {
            switch hud {
            case .brightness(let v): bar("sun.max.fill", v)
            case .volume(let v): bar(v == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill", v)
            case .jump(let s):
                Image(systemName: s < 0 ? "gobackward.\(Int(abs(s)))" : "goforward.\(Int(s))")
                    .font(.system(size: 30, weight: .semibold))
                    .frame(width: 72, height: 72)
            case .text(let t):
                Text(t).font(.headline).padding(.horizontal, 18).padding(.vertical, 12)
            }
        }
        .foregroundStyle(.white)
        .glassEffect(.regular, in: hud.isJump ? AnyShape(Circle()) : AnyShape(Capsule()))
    }

    private func bar(_ symbol: String, _ v: Double) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.title3)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25))
                Capsule().fill(.white).frame(width: 150 * v)
            }
            .frame(width: 150, height: 6)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }
}

private extension PlayerContent.HUD {
    var isJump: Bool { if case .jump = self { return true } else { return false } }
}

private struct LoadingBadge: View {
    let note: String?
    var body: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large).tint(.white)
            if let note { Text(note).font(.subheadline.weight(.semibold)).foregroundStyle(.white) }
        }
        .padding(22)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

private struct ErrorCard: View {
    let message: String
    let controller: PlaybackController
    let close: () -> Void
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.yellow)
            Text("Couldn't play this").font(.title3.bold())
            Text(message).font(.subheadline).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.8))
            HStack(spacing: 10) {
                Button("Close", action: close).buttonStyle(.glass)
                Button("Try again") { Task { await controller.retry() } }.buttonStyle(.glass)
                if controller.method != .transcode {
                    Button("Convert on server") { Task { await controller.retryWithConversion() } }.buttonStyle(.glassProminent)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(26)
        .frame(maxWidth: 460)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
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
            VStack(alignment: .leading, spacing: 4) {
                Text("Next episode in \(secondsLeft)").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
                Text([next.episodeLabel, next.name].compactMap { $0 }.joined(separator: " · ")).font(.subheadline.weight(.semibold)).lineLimit(2)
                HStack(spacing: 8) {
                    Button("Play now") { Task { await controller.playNext(auto: false) } }.buttonStyle(.glassProminent).controlSize(.small)
                    Button("Cancel") { controller.cancelCountdown() }.buttonStyle(.glass).controlSize(.small)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(12)
        .frame(maxWidth: 380)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private struct StillWatchingCard: View {
    let controller: PlaybackController
    let close: () -> Void
    var body: some View {
        VStack(spacing: 14) {
            Text("Are you still watching?").font(.title2.bold())
            HStack(spacing: 10) {
                Button("Stop", action: close).buttonStyle(.glass)
                Button("Keep watching") { controller.confirmStillWatching() }.buttonStyle(.glassProminent)
            }
        }
        .foregroundStyle(.white)
        .padding(26)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }
}
