import AppKit
import SwiftUI

/// Visual language shared by the menu, Settings and onboarding: monocode glass,
/// neutral greys, one blue accent. Mirrors the picker's palette (ARCHITECTURE.md "Picker UI").
enum ShellTheme {
    /// hsl(211 92% 62%)
    static let accent = Color(red: 0.270, green: 0.608, blue: 0.970)
    static let accentNS = NSColor(srgbRed: 0.270, green: 0.608, blue: 0.970, alpha: 1)

    static let success = Color(red: 0.25, green: 0.78, blue: 0.47)
    static let warning = Color(red: 0.98, green: 0.69, blue: 0.23)
    static let danger = Color(red: 0.96, green: 0.36, blue: 0.36)

    /// 1px hairline stroke: content at 7%.
    static let hairline = Color.primary.opacity(0.07)
    /// Selection / pressed fill: content at ~12%.
    static let fill = Color.primary.opacity(0.06)

    static let cornerRadius: CGFloat = 14
    static let ease = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.2)

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// Behind-window blur for window backgrounds and sidebars.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.state = .followsWindowActiveState
        view.material = material
        view.blendingMode = blending
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}

/// A rounded glass card: Liquid Glass on macOS 26+, a translucent fill with hairline otherwise.
struct ShellGlassCard: ViewModifier {
    var cornerRadius: CGFloat = ShellTheme.cornerRadius

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular, in: shape)
        } else {
            content
                .background(.thinMaterial, in: shape)
                .overlay(shape.strokeBorder(ShellTheme.hairline))
        }
    }
}

extension View {
    func glassCard(cornerRadius: CGFloat = ShellTheme.cornerRadius) -> some View {
        modifier(ShellGlassCard(cornerRadius: cornerRadius))
    }
}

/// Small rounded key cap, e.g. ⏎ or ⇥, used to document in-picker keys.
struct KeyCap: View {
    let label: String

    init(_ label: String) { self.label = label }

    var body: some View {
        Text(label)
            .font(ShellTheme.mono(11, weight: .medium))
            .padding(.horizontal, 6)
            .frame(minWidth: 22, minHeight: 20)
            .background(ShellTheme.fill, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
    }
}

/// Inline code chip in the monocode style, e.g. `:haha`.
struct CodeChip: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(ShellTheme.mono(12, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(ShellTheme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .foregroundStyle(ShellTheme.accent)
    }
}

/// The app is an `.accessory` (menu bar only) app. While one of our windows is open it
/// temporarily becomes `.regular` so the window can take focus and show in ⌘⇥; it reverts
/// once every shell window is closed.
@MainActor
enum ShellActivation {
    private static var openWindows = Set<ObjectIdentifier>()

    static func windowDidOpen(_ window: NSWindow) {
        openWindows.insert(ObjectIdentifier(window))
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    static func windowWillClose(_ window: NSWindow) {
        openWindows.remove(ObjectIdentifier(window))
        guard openWindows.isEmpty else { return }
        // Defer so AppKit finishes closing before the Dock icon disappears.
        DispatchQueue.main.async {
            guard openWindows.isEmpty else { return }
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
