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
    @State private var pinch: CGFloat?          // live pinch scale (nil when not pinching)
    @State private var volume = SystemVolume()
    @State private var menuOpen = false

    enum HUD: Equatable {
        case jump(Double), text(String)
    }

    private var player: MPVPlayer { controller.player }
    private var isLoading: Bool { controller.phase == .loading || player.state == .buffering || player.state == .loading }
    private var settings: AppSettings { model.settings }

    var body: some View {
        ZStack {
            VideoSurface(controller: controller, pinch: pinch)
                .ignoresSafeArea()

            TouchLayer(
                onTap: { toggleControls() },
                onDoubleTap: { side in doubleTap(side) },
                onPinch: { scale, ended in pinchChanged(scale, ended: ended) },
                onSwipeDown: { close() },
                isLocked: locked
            )
            .ignoresSafeArea()

            if case .failed(let message) = controller.phase {
                ErrorCard(message: message, controller: controller, close: close)
            } else if isLoading && !(showControls || panel != nil || menuOpen) {
                // Controls hidden: just Apple's spinner, no box.
                ProgressView().controlSize(.large).tint(.white).allowsHitTesting(false)
            }

            if locked {
                lockedOverlay
            } else if showControls || panel != nil || menuOpen {
                controls.transition(.opacity)
                if panel == nil {
                    // Centred on the screen itself (not between the bars), like Apple's player.
                    transport.transition(.opacity)
                }
            }

            if !locked { cornerCards }
            if let hud { HUDView(hud: hud).allowsHitTesting(false).transition(.opacity) }
            if controller.askStillWatching { StillWatchingCard(controller: controller, close: close) }
            VolumeViewHost(volume: volume).frame(width: 1, height: 1).opacity(0.01).allowsHitTesting(false)
        }
        .tint(.white)
        .animation(.easeInOut(duration: 0.25), value: showControls)
        .animation(.easeOut(duration: 0.2), value: hud)
        .animation(.snappy, value: panel)
        .onAppear { scheduleHide() }
        .onChange(of: player.isPaused) { _, paused in if paused { hideTask?.cancel() } else { scheduleHide() } }
        .onChange(of: menuOpen) { _, open in if open { hideTask?.cancel() } else { scheduleHide() } }
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
                if let panel { panelView(panel).padding(.bottom, 12) }
                bottomBar
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .foregroundStyle(.white)
        .tint(.white)
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
        HStack(spacing: 44) {
            transportButton("gobackward.\(settings.jumpBackward)", glyph: 28, size: 60) {
                controller.jump(-Double(settings.jumpBackward))
                scheduleHide()
            }
            if isLoading {
                // Like Apple: while loading, the spinner takes the play button's place.
                ProgressView().controlSize(.large).tint(.white).frame(width: 84, height: 84)
            } else {
                transportButton(player.isPaused ? "play.fill" : "pause.fill", glyph: 36, size: 84,
                                // The play triangle's visual centre sits left of its box (Apple nudges it).
                                nudge: player.isPaused ? 3 : 0) {
                    controller.togglePlay()
                    scheduleHide()
                }
            }
            transportButton("goforward.\(settings.jumpForward)", glyph: 28, size: 60) {
                controller.jump(Double(settings.jumpForward))
                scheduleHide()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.white)
    }

    /// One transport button: white glyph, exactly centred in its glass circle.
    private func transportButton(_ symbol: String, glyph: CGFloat, size: CGFloat, nudge: CGFloat = 0,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: glyph, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .offset(x: nudge)
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .glassEffect(.regular.interactive(), in: .circle)
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
                        audioMenu
                        subtitleMenu
                        moreMenu
                    }
                }
            }
            AppleTimeline(controller: controller, scrubbing: $scrubbing, onInteract: scheduleHide)
        }
    }

    // MARK: Menus (native iOS menus, like Apple's player; the controls stay up while one is open)

    private var speedMenu: some View {
        PlayerMenuButton(symbol: "gauge.with.dots.needle.67percent", onOpenChange: { menuOpen = $0 }) {
            let current = player.playbackRate
            let rates = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
            return UIMenu(title: "Playback Speed", options: .singleSelection, children: rates.map { rate in
                UIAction(title: rate == 1 ? "1× (Normal)" : String(format: "%g×", rate),
                         state: abs(current - rate) < 0.01 ? .on : .off) { _ in controller.setSpeed(rate) }
            })
        }
        .frame(width: 44, height: 44)
    }

    private var audioMenu: some View {
        PlayerMenuButton(symbol: "waveform", onOpenChange: { menuOpen = $0 }) {
            let tracks = UIMenu(title: "Audio", options: [.displayInline, .singleSelection], children:
                controller.audioOptions.map { t in
                    UIAction(title: t.title, subtitle: t.detail.isEmpty ? nil : t.detail, state: t.isSelected ? .on : .off) { _ in
                        controller.selectAudio(t.id)
                    }
                })
            let extras = UIMenu(title: "", options: .displayInline, children: [
                delayMenu("Audio Timing", symbol: "waveform.badge.plus", value: controller.audioDelay) { controller.setAudioDelay($0) },
            ])
            return UIMenu(children: [tracks, extras])
        }
        .frame(width: 44, height: 44)
    }

    private var subtitleMenu: some View {
        PlayerMenuButton(symbol: "captions.bubble", onOpenChange: { menuOpen = $0 }) {
            let subtitleOptions = controller.subtitleOptions
            let anySelected = subtitleOptions.contains(where: \.isSelected)
            let subs = UIMenu(title: "Subtitles", options: [.displayInline, .singleSelection], children:
                [UIAction(title: "Off", state: anySelected ? .off : .on) { _ in controller.selectSubtitle(nil) }] +
                subtitleOptions.map { t in
                    UIAction(title: t.title, subtitle: t.detail.isEmpty ? nil : t.detail, state: t.isSelected ? .on : .off) { _ in
                        controller.selectSubtitle(t.id)
                    }
                })
            let sizes: [(String, Double)] = [("Small", 0.8), ("Medium", 1.0), ("Large", 1.25), ("Extra Large", 1.5)]
            let size = UIMenu(title: "Subtitle Size", image: UIImage(systemName: "textformat.size"), options: .singleSelection, children:
                sizes.map { name, value in
                    UIAction(title: name, state: abs(settings.subtitleSize - value) < 0.01 ? .on : .off) { _ in
                        settings.subtitleSize = value
                        controller.applySubtitleScale()
                    }
                })
            let extras = UIMenu(title: "", options: .displayInline, children: [
                delayMenu("Subtitle Timing", symbol: "text.badge.checkmark", value: controller.subtitleDelay) { controller.setSubtitleDelay($0) },
                size,
            ])
            return UIMenu(children: [subs, extras])
        }
        .frame(width: 44, height: 44)
    }

    /// Timing submenu; it stays open so you can tap several steps in a row.
    private func delayMenu(_ title: String, symbol: String, value: Double, set: @escaping (Double) -> Void) -> UIMenu {
        func step(_ label: String, _ delta: Double) -> UIAction {
            UIAction(title: label, attributes: .keepsMenuPresented) { _ in set(value + delta) }
        }
        return UIMenu(title: title, subtitle: String(format: "%+.1f s", value), image: UIImage(systemName: symbol), children: [
            step("Earlier by 0.5 s", -0.5), step("Earlier by 0.1 s", -0.1),
            step("Later by 0.1 s", 0.1), step("Later by 0.5 s", 0.5),
            UIAction(title: "Reset", attributes: value == 0 ? .disabled : []) { _ in set(0) },
        ])
    }

    private var moreMenu: some View {
        PlayerMenuButton(symbol: "ellipsis", onOpenChange: { menuOpen = $0 }) {
            var top: [UIMenuElement] = []
            if !controller.chapters.isEmpty {
                top.append(UIAction(title: "Chapters", image: UIImage(systemName: "list.bullet.rectangle")) { _ in openPanel(.chapters) })
            }
            if controller.item.kind == .episode {
                top.append(UIAction(title: "Episodes", image: UIImage(systemName: "rectangle.stack")) { _ in openPanel(.episodes) })
                if controller.upNext != nil {
                    top.append(UIAction(title: "Next Episode", image: UIImage(systemName: "forward.end.fill")) { _ in
                        Task { await controller.playNext(auto: false) }
                    })
                }
            }
            let current = controller.aspectMode
            let modes: [(PlaybackController.AspectMode, String, String)] = [
                (.fit, "Fit", "arrow.down.right.and.arrow.up.left"),
                (.fill, "Fill", "arrow.up.left.and.arrow.down.right"),
                (.stretch, "Stretch", "arrow.left.and.right"),
            ]
            let aspect = UIMenu(title: "Aspect Ratio", subtitle: modes.first { $0.0 == current }?.1,
                                image: UIImage(systemName: "aspectratio"), options: .singleSelection, children: modes.map { mode, title, symbol in
                UIAction(title: title, image: UIImage(systemName: symbol), state: mode == current ? .on : .off) { _ in
                    withAnimation(.smooth(duration: 0.35)) { controller.setAspect(mode) }
                }
            })
            let view = UIMenu(title: "", options: .displayInline, children: [
                aspect,
                UIAction(title: "Lock Controls", image: UIImage(systemName: "lock")) { _ in withAnimation { locked = true } },
            ])
            let info = UIAction(title: "Playback Info", image: UIImage(systemName: "info.circle")) { _ in openPanel(.info) }
            return UIMenu(children: [UIMenu(title: "", options: .displayInline, children: top), view,
                                     UIMenu(title: "", options: .displayInline, children: [info])])
        }
        .frame(width: 44, height: 44)
    }

    private func glassCircle(_ symbol: String, size: CGFloat, font: Font = .body, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(font.weight(.semibold))
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
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
        // Apple's player: double-tap a side to skip, the middle to zoom.
        switch side {
        case .left:
            controller.jump(-Double(settings.jumpBackward)); showHUD(.jump(-Double(settings.jumpBackward)))
        case .right:
            controller.jump(Double(settings.jumpForward)); showHUD(.jump(Double(settings.jumpForward)))
        case .center:
            withAnimation(.smooth(duration: 0.35)) { controller.toggleFill() }
        }
    }

    private func pinchChanged(_ scale: CGFloat, ended: Bool) {
        guard !locked else { return }
        if ended {
            // One transaction: the live pinch size eases into fit or fill (no jump back first).
            let fill = controller.isFilled ? scale > 0.92 : scale > 1.08
            withAnimation(.smooth(duration: 0.3)) {
                pinch = nil
                controller.setFill(fill)
            }
        } else {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { pinch = scale }
        }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, panel == nil, !menuOpen, !player.isPaused, scrubbing == nil else { return }
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

/// Fit and fill change the video view's real size (centred, clipped), the way MPVUI's surface
/// is built to animate: during the animation it keeps the current picture and stretches it
/// smoothly, then renders sharp at the final size. Subtitles are moved up and scaled back while
/// filled so they stay on screen at their normal size.
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
            let mode = controller.aspectMode
            let base: CGFloat = mode == .fill ? fillScale : 1
            let scale = min(max(base * (pinch ?? 1), 1), fillScale * 1.25)
            // Stretch: the fitted picture pulled to the screen's shape (non-uniform scale).
            let stretchX: CGFloat = mode == .stretch && pinch == nil ? container.width / max(fitted.width, 1) : 1
            let stretchY: CGFloat = mode == .stretch && pinch == nil ? container.height / max(fitted.height, 1) : 1
            MPVVideoPlayer(player: controller.player)
                .frame(width: fitted.width * (mode == .stretch ? 1 : scale), height: fitted.height * (mode == .stretch ? 1 : scale))
                .scaleEffect(x: stretchX, y: stretchY)
                .frame(width: container.width, height: container.height)
                .clipped()
                .allowsHitTesting(false)
                .onChange(of: mode, initial: true) { _, mode in
                    // Part of the picture hidden above and below while filled (fraction of its height).
                    let filled = mode == .fill
                    let hidden = filled ? max(0, 1 - container.height / max(fitted.height * fillScale, 1)) / 2 : 0
                    controller.applyFill(hiddenFraction: hidden, scale: filled ? fillScale : 1)
                }
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
    let onSwipeDown: () -> Void
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
        for g in [double, single, pinch, pan] as [UIGestureRecognizer] {
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
        private var dismissing = false

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

        /// Swipe down to close, like Apple's player.
        @objc func pan(_ g: UIPanGestureRecognizer) {
            guard let v = g.view, !parent.isLocked else { return }
            let t = g.translation(in: v)
            switch g.state {
            case .began:
                let vel = g.velocity(in: v)
                dismissing = vel.y > 0 && abs(vel.y) > abs(vel.x)
            case .ended:
                if dismissing && t.y > v.bounds.height * 0.22 { parent.onSwipeDown() }
                dismissing = false
            default:
                if g.state != .changed { dismissing = false }
            }
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            g is UIPinchGestureRecognizer || other is UIPinchGestureRecognizer
        }
    }
}

// MARK: - Volume

/// System volume: read live from the audio session (so the hardware buttons move the slider)
/// and set through a hidden MPVolumeView slider (the supported way; it also keeps the system
/// volume HUD from covering the video).
@Observable
@MainActor
final class SystemVolume {
    @ObservationIgnored weak var slider: UISlider?
    @ObservationIgnored private var observation: NSKeyValueObservation?
    var shown: Float = AVAudioSession.sharedInstance().outputVolume

    init() {
        observation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { [weak self] session, _ in
            let v = session.outputVolume
            Task { @MainActor in self?.shown = v }
        }
    }

    var value: Float {
        get { shown }
        set {
            let v = min(1, max(0, newValue))
            shown = v
            slider?.value = v
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
        }
        return view
    }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

/// Apple's volume control: a glass capsule with the speaker icon and a thin white track that
/// thickens while you drag it, following the hardware buttons live.
private struct VolumeCapsule: View {
    let volume: SystemVolume
    @State private var dragging = false
    @State private var dragStart: Float = 0
    private let trackWidth: CGFloat = 92

    private var symbol: String {
        switch volume.shown {
        case 0: return "speaker.slash.fill"
        case ..<0.34: return "speaker.wave.1.fill"
        case ..<0.67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 24, alignment: .leading)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25))
                Capsule().fill(.white).frame(width: trackWidth * CGFloat(volume.shown))
            }
            .frame(width: trackWidth, height: dragging ? 9 : 5)
            .frame(height: 44)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if !dragging { dragging = true; dragStart = volume.shown }
                        volume.value = dragStart + Float(g.translation.width / trackWidth)
                    }
                    .onEnded { _ in dragging = false }
            )
            .animation(.easeOut(duration: 0.15), value: dragging)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .frame(height: 44)
        .glassEffect(.regular.interactive(), in: .capsule)
    }
}

// MARK: - Menu button (UIKit menu, so the player knows while it's open)

/// A glass circle that opens a native iOS menu, like Apple's player. Unlike SwiftUI's Menu it
/// reports when the menu opens and closes, so the controls don't hide while you're choosing.
/// The menu is rebuilt each time it opens, so checkmarks are always current.
private struct PlayerMenuButton: UIViewRepresentable {
    let symbol: String
    let onOpenChange: (Bool) -> Void
    let makeMenu: () -> UIMenu

    init(symbol: String, onOpenChange: @escaping (Bool) -> Void, makeMenu: @escaping () -> UIMenu) {
        self.symbol = symbol
        self.onOpenChange = onOpenChange
        self.makeMenu = makeMenu
    }

    func makeUIView(context: Context) -> MenuButton {
        let button = MenuButton(type: .system)
        var config = UIButton.Configuration.glass()
        config.cornerStyle = .capsule
        config.baseForegroundColor = .white
        config.contentInsets = .zero
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        config.image = UIImage(systemName: symbol)
        button.configuration = config
        button.tintColor = .white
        button.showsMenuAsPrimaryAction = true
        button.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak button] completion in
            completion(button?.provider?().children ?? [])
        }])
        update(button)
        return button
    }

    func updateUIView(_ button: MenuButton, context: Context) { update(button) }

    private func update(_ button: MenuButton) {
        button.provider = makeMenu
        button.onOpenChange = onOpenChange
        if var config = button.configuration, config.image != UIImage(systemName: symbol) {
            config.image = UIImage(systemName: symbol)
            button.configuration = config
        }
    }

    final class MenuButton: UIButton {
        var provider: (() -> UIMenu)?
        var onOpenChange: ((Bool) -> Void)?

        override func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                             willDisplayMenuFor configuration: UIContextMenuConfiguration,
                                             animator: (any UIContextMenuInteractionAnimating)?) {
            super.contextMenuInteraction(interaction, willDisplayMenuFor: configuration, animator: animator)
            onOpenChange?(true)
        }

        override func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                             willEndFor configuration: UIContextMenuConfiguration,
                                             animator: (any UIContextMenuInteractionAnimating)?) {
            super.contextMenuInteraction(interaction, willEndFor: configuration, animator: animator)
            onOpenChange?(false)
        }
    }
}

// MARK: - HUD & cards

private struct HUDView: View {
    let hud: PlayerContent.HUD
    var body: some View {
        Group {
            switch hud {
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
                    Button("Convert on server") { Task { await controller.retryWithConversion() } }.buttonStyle(.tintedGlass)
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
                    Button("Play now") { Task { await controller.playNext(auto: false) } }.buttonStyle(.tintedGlass).controlSize(.small)
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
                Button("Keep watching") { controller.confirmStillWatching() }.buttonStyle(.tintedGlass)
            }
        }
        .foregroundStyle(.white)
        .padding(26)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }
}
