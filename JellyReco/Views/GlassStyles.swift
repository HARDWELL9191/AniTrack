import SwiftUI
import UIKit

// MARK: - Tinted Liquid Glass button (instead of the flat blue .glassProminent)

/// A prominent button that is real Liquid Glass: refractive glass tinted with the accent colour
/// (the same recipe AniReco uses for its accent glass), white label, presses like glass.
struct TintedGlassButtonStyle: ButtonStyle {
    var tint: Color = Theme.accent

    func makeBody(configuration: Configuration) -> some View {
        TintedGlassBody(configuration: configuration, tint: tint)
    }

    private struct TintedGlassBody: View {
        let configuration: ButtonStyleConfiguration
        let tint: Color
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.controlSize) private var controlSize

        var body: some View {
            let vertical: CGFloat = controlSize == .large ? 14 : (controlSize == .small || controlSize == .mini ? 7 : 10)
            let horizontal: CGFloat = controlSize == .small || controlSize == .mini ? 12 : 18
            configuration.label
                .font((controlSize == .small || controlSize == .mini ? Font.subheadline : .body).weight(.semibold))
                .foregroundStyle(.white)
                .padding(.vertical, vertical)
                .padding(.horizontal, horizontal)
                .contentShape(Capsule())
                // Not .interactive(): interactive glass inside a button style can take the tap
                // away from the button.
                .glassEffect(.regular.tint(tint.opacity(isEnabled ? 0.65 : 0.25)), in: .capsule)
                .opacity(isEnabled ? 1 : 0.55)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.snappy(duration: 0.15), value: configuration.isPressed)
        }
    }
}

extension ButtonStyle where Self == TintedGlassButtonStyle {
    /// Accent-tinted Liquid Glass (use instead of `.glassProminent`).
    static var tintedGlass: TintedGlassButtonStyle { TintedGlassButtonStyle() }
    static func tintedGlass(_ tint: Color) -> TintedGlassButtonStyle { TintedGlassButtonStyle(tint: tint) }
}

// MARK: - Dropdowns (AniReco)

extension View {
    /// AniReco's one height for every glass dropdown button (category, season, status…):
    /// the height of a bookmark icon, whatever the label shows.
    func menuButtonHeight() -> some View {
        ZStack {
            Image(systemName: "bookmark.fill").hidden()
            self
        }
    }
}

/// AniReco's dropdown label: optional leading icon, text, chevron.
struct DropdownLabel: View {
    let text: String
    var symbol: String? = nil
    var body: some View {
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol) }
            Text(text).lineLimit(1)
            Image(systemName: "chevron.down").font(.caption.weight(.semibold))
        }
        .menuButtonHeight()
        .font(.subheadline.weight(.semibold))
    }
}

// MARK: - Keyboard (AniReco: a Done bar, Return closes it, scrolling closes it)

extension View {
    /// Adds AniReco's "Done" bar above the keyboard and lets scrolling dismiss it.
    /// Put it once per screen (inside its NavigationStack).
    func keyboardDoneBar() -> some View {
        self
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { Keyboard.dismiss() }.fontWeight(.semibold)
                }
            }
    }
}

enum Keyboard {
    @MainActor static func dismiss() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

/// Tapping anywhere outside a text field closes the keyboard (installed once on the window).
struct KeyboardDismissOnTapOutside: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = InstallerView()
        view.isUserInteractionEnabled = false
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {}

    final class InstallerView: UIView, UIGestureRecognizerDelegate {
        private weak var installedOn: UIWindow?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let window, installedOn !== window else { return }
            installedOn = window
            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
            tap.cancelsTouchesInView = false
            tap.requiresExclusiveTouchType = false
            tap.delegate = self
            window.addGestureRecognizer(tap)
        }
        @objc private func tapped() { window?.endEditing(true) }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            // Only while typing, and never for taps on a text field / text view itself.
            var v: UIView? = touch.view
            while let current = v {
                if current is UITextField || current is UITextView || current is UISearchBar { return false }
                v = current.superview
            }
            return true
        }
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}
