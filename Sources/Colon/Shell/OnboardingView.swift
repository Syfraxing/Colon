import AppKit
import ColonCore
import IOKit.hid
import SwiftUI

@MainActor
final class OnboardingModel: ObservableObject {
    enum Step: Int, CaseIterable {
        case accessibility, jev, practice
    }

    static let accessibilitySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    static let inputMonitoringSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!

    let steps: [Step]
    @Published var step: Step
    @Published var isTrusted: Bool
    @Published var hasInputMonitoring: Bool
    @Published var hasRequestedAccess = false

    var onFinish: (() -> Void)?

    init(steps: [Step], isTrusted: Bool, hasInputMonitoring: Bool) {
        self.steps = steps
        self.step = steps.first ?? .accessibility
        self.isTrusted = isTrusted
        self.hasInputMonitoring = hasInputMonitoring
    }

    var isLastStep: Bool { step == steps.last }

    func requestAccess() {
        hasRequestedAccess = true
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            NSWorkspace.shared.open(Self.accessibilitySettingsURL)
        }
    }

    func requestInputMonitoring() {
        hasRequestedAccess = true
        if !IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) {
            NSWorkspace.shared.open(Self.inputMonitoringSettingsURL)
        }
    }

    func advance() {
        guard let index = steps.firstIndex(of: step), index + 1 < steps.count else {
            onFinish?()
            return
        }
        withAnimation(ShellTheme.ease) { step = steps[index + 1] }
    }

    func back() {
        guard let index = steps.firstIndex(of: step), index > 0 else { return }
        withAnimation(ShellTheme.ease) { step = steps[index - 1] }
    }
}

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var jevKey: JevKeyModel
    let practiceEngine: SuggestionEngine

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, 34)
            ZStack {
                switch model.step {
                case .accessibility: accessibilityStep.transition(stepTransition)
                case .jev: jevStep.transition(stepTransition)
                case .practice: practiceStep.transition(stepTransition)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 36)
            .padding(.top, 20)
            footer
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
        }
        .frame(width: 560, height: 540)
        .background(OnboardingBackground())
        .tint(ShellTheme.accent)
    }

    private var stepTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(x: 24)),
            removal: .opacity.combined(with: .offset(x: -24))
        )
    }

    // MARK: Header / footer

    private var header: some View {
        VStack(spacing: 12) {
            Image(nsImage: AppInfo.icon)
                .resizable()
                .frame(width: 72, height: 72)
                .shadow(color: ShellTheme.accent.opacity(0.35), radius: 22, y: 8)
            Text(title)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 40)
        }
        .animation(ShellTheme.ease, value: model.step)
    }

    private var title: String {
        switch model.step {
        case .accessibility: "Welcome to Colon"
        case .jev: "Make it smarter"
        case .practice: "Try it"
        }
    }

    private var subtitle: String {
        switch model.step {
        case .accessibility: "Type \(settings.triggerString)haha in any app and pick 😂 without leaving the keyboard. First, two quick permissions."
        case .jev: "Optional. A Jev API key lets Colon understand what you mean, not just what you type."
        case .practice: "Type \(settings.triggerString)haha below, then press ⏎ or ⇥. It works the same in every app."
        }
    }

    private var footer: some View {
        HStack {
            if model.steps.count > 1 {
                HStack(spacing: 6) {
                    ForEach(model.steps, id: \.self) { step in
                        Capsule()
                            .fill(step == model.step ? ShellTheme.accent : Color.primary.opacity(0.18))
                            .frame(width: step == model.step ? 18 : 6, height: 6)
                    }
                }
                .animation(ShellTheme.ease, value: model.step)
                .accessibilityElement()
                .accessibilityLabel("Step \((model.steps.firstIndex(of: model.step) ?? 0) + 1) of \(model.steps.count)")
            }
            Spacer()
            if model.step != model.steps.first {
                Button("Back", action: model.back)
                    .controlSize(.large)
            }
            primaryButton
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch model.step {
        case .accessibility:
            Button(model.isLastStep ? "Done" : "Continue", action: model.advance)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!model.isTrusted)
                .keyboardShortcut(.defaultAction)
        case .jev:
            Button(jevKey.hasKey ? "Continue" : "Skip", action: model.advance)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        case .practice:
            Button("Done", action: model.advance)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }

    // MARK: Steps

    private var accessibilityStep: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                PermissionPoint(symbol: "keyboard", text: "Notices \(settings.triggerString)shortcodes as you type and shows the picker at your cursor.")
                PermissionPoint(symbol: "text.cursor", text: "Replaces \(settings.triggerString)haha with the emoji you choose.")
                PermissionPoint(symbol: "lock.shield", text: "Keeps no record of your typing and stays silent in password fields.")
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard()

            VStack(spacing: 0) {
                PermissionRow(
                    title: "Accessibility",
                    detail: "Required: see the trigger and insert emoji.",
                    isGranted: model.isTrusted,
                    action: model.requestAccess
                )
                Divider().padding(.leading, 44).opacity(0.6)
                PermissionRow(
                    title: "Input Monitoring",
                    detail: "Lets macOS deliver your keystrokes to Colon.",
                    isGranted: model.hasInputMonitoring,
                    action: model.requestInputMonitoring
                )
            }
            .padding(.vertical, 4)
            .glassCard()

            if model.hasRequestedAccess, !(model.isTrusted && model.hasInputMonitoring) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Turn on Colon in System Settings. This updates automatically.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .transition(.opacity)
            }
        }
        .animation(ShellTheme.ease, value: model.isTrusted)
        .animation(ShellTheme.ease, value: model.hasInputMonitoring)
    }

    private var jevStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            JevKeyEditor(model: jevKey)
            Divider().opacity(0.6)
            TextContextConsent(isOn: Binding(
                get: { jevKey.hasKey && settings.sendTextContext },
                set: { settings.sendTextContext = $0 }
            ))
            .disabled(!jevKey.hasKey)
        }
        .padding(16)
        .glassCard()
    }

    private var practiceStep: some View {
        PracticeField(settings: settings, engine: practiceEngine)
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let isGranted: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isGranted ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(isGranted ? ShellTheme.success : Color.secondary)
                .frame(width: 20)
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if isGranted {
                Text("Granted")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(ShellTheme.success)
            } else {
                Button("Allow…", action: action)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }
}

private struct PermissionPoint: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ShellTheme.accent)
                .frame(width: 20)
            Text(text)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Soft accent glow over the window's behind-window blur.
private struct OnboardingBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            VisualEffectBackground(material: .underWindowBackground)
            RadialGradient(
                colors: [ShellTheme.accent.opacity(colorScheme == .dark ? 0.22 : 0.14), .clear],
                center: UnitPoint(x: 0.5, y: 0.0),
                startRadius: 10,
                endRadius: 340
            )
        }
        .ignoresSafeArea()
    }
}
