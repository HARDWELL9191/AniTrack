import SwiftUI
import UIKit

/// Draws the Face ID lock in a window of its own above everything the app shows (sheets,
/// full-screen covers such as the player, alerts), so nothing stays visible over it — also in
/// the app-switcher snapshot. RootView decides when the app locks; this only decides where the
/// lock is drawn.
@Observable
@MainActor
final class LockWindowController {
    static let shared = LockWindowController()

    /// The scene's phase, handed on to LockView: a view in a separate UIKit window doesn't get
    /// the WindowGroup's phase by itself. RootView keeps it up to date.
    var scenePhase: ScenePhase = .active

    @ObservationIgnored private var window: UIWindow?
    @ObservationIgnored private var generation = 0

    /// The scene the lock window goes on. nil before the app has a window; RootView then draws
    /// the lock in its own view tree instead.
    var windowScene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }

    /// Shows or removes the lock window to match `model.isLocked`.
    func update(model: AppModel, phase: ScenePhase) {
        scenePhase = phase
        if model.isLocked { show(model: model) } else { hide() }
    }

    private func show(model: AppModel) {
        generation += 1
        if let window {
            // Still there (fading out after an unlock): bring it back.
            window.layer.removeAllAnimations()
            window.alpha = 1
            window.isHidden = false
            return
        }
        guard let scene = windowScene else { return }
        // The keyboard has its own window above every app window.
        Keyboard.dismiss()
        let host = UIHostingController(rootView: LockHost(model: model, controller: self))
        host.view.backgroundColor = .systemBackground   // opaque: nothing shows through
        let window = UIWindow(windowScene: scene)
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)
        window.overrideUserInterfaceStyle = Self.style(model.settings.appearance.scheme)
        window.backgroundColor = .systemBackground
        window.rootViewController = host
        // Visible but not key: the app's own window keeps key status (rotation, keyboard focus).
        window.isHidden = false
        window.layoutIfNeeded()
        self.window = window
    }

    private func hide() {
        guard let window else { return }
        generation += 1
        let current = generation
        UIView.animate(withDuration: 0.25, animations: {
            window.alpha = 0
        }, completion: { _ in
            MainActor.assumeIsolated {
                // Locked again while fading out: keep the window.
                guard current == self.generation, let window = self.window else { return }
                window.isHidden = true
                window.rootViewController = nil
                self.window = nil
            }
        })
    }

    private static func style(_ scheme: ColorScheme?) -> UIUserInterfaceStyle {
        switch scheme {
        case .dark?: return .dark
        case .light?: return .light
        default: return .unspecified
        }
    }
}

/// The lock window's content: LockView with what it would get from the app's scene.
private struct LockHost: View {
    let model: AppModel
    let controller: LockWindowController

    var body: some View {
        LockView()
            .environment(model)
            .environment(\.scenePhase, controller.scenePhase)
            .tint(Theme.accent)
            .preferredColorScheme(model.settings.appearance.scheme)
    }
}
