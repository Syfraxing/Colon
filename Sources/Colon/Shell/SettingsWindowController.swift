import AppKit
import ApplicationServices
import IOKit.hid
import ColonCore
import SwiftUI

/// Settings window (General, Jev, Shortcuts, Excluded Apps, About) and first-run onboarding
/// (Accessibility permission + optional Jev key). OWNER: shell worker.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    /// Called when Accessibility permission becomes granted so the coordinator can start input.
    var onAccessibilityGranted: (() -> Void)?
    /// Called after the user saves or removes the Jev key; the coordinator wires this to
    /// `engine.reloadAPIKey()` so the engine never reads the Keychain per query.
    var onAPIKeyChanged: (() -> Void)?

    private let settings: AppSettings
    private let engine: SuggestionEngine?
    private let updater: Updater
    private let navigation = SettingsNavigation()
    private lazy var jevKey = JevKeyModel { [weak self] in self?.onAPIKeyChanged?() }
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var onboardingModel: OnboardingModel?
    private var trustTimer: Timer?
    /// Whether `onAccessibilityGranted` already reflects the current grant.
    private var accessibilityReported = false

    init(settings: AppSettings, engine: SuggestionEngine? = nil, updater: Updater) {
        self.settings = settings
        self.engine = engine
        self.updater = updater
        super.init()
    }

    func show() {
        show(tab: nil)
    }

    /// Opens Settings, optionally on a specific tab. Reuses the single window.
    func show(tab: SettingsTab?) {
        if let tab { navigation.tab = tab }
        let window = settingsWindow ?? makeSettingsWindow()
        settingsWindow = window
        let wasVisible = window.isVisible
        ShellActivation.windowDidOpen(window)
        if !wasVisible {
            // Don't land in the trigger field with a focus ring; let the user choose.
            window.makeFirstResponder(nil)
        }
    }

    /// Show onboarding if not completed or Accessibility permission is missing.
    func showOnboardingIfNeeded() {
        let trusted = Permissions.accessibilityGranted
        accessibilityReported = trusted
        if !trusted { startTrustPolling() }
        guard !settings.hasCompletedOnboarding || !trusted else { return }

        if let window = onboardingWindow {
            ShellActivation.windowDidOpen(window)
            return
        }
        // Returning users who lost the permission only need the Accessibility step.
        let steps: [OnboardingModel.Step] = settings.hasCompletedOnboarding
            ? [.accessibility]
            : OnboardingModel.Step.allCases
        let model = OnboardingModel(steps: steps, isTrusted: trusted, hasInputMonitoring: Permissions.inputMonitoringGranted)
        if !model.hasInputMonitoring { startTrustPolling() }
        model.onFinish = { [weak self] in self?.finishOnboarding() }
        onboardingModel = model

        let view = OnboardingView(model: model, settings: settings, jevKey: jevKey, practiceEngine: SuggestionEngine(settings: settings))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 540),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = NSHostingController(rootView: view)
        window.title = "Welcome to Colon"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        onboardingWindow = window
        ShellActivation.windowDidOpen(window)
    }

    // MARK: Accessibility polling

    private func startTrustPolling() {
        guard trustTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkTrust() }
        }
        RunLoop.main.add(timer, forMode: .common)
        trustTimer = timer
    }

    /// Probes only (never creates an event tap, which would trigger a system prompt).
    private func checkTrust() {
        let trusted = Permissions.accessibilityGranted
        let monitoring = Permissions.inputMonitoringGranted
        if trusted, !accessibilityReported {
            accessibilityReported = true
            onAccessibilityGranted?()
        }
        if let model = onboardingModel {
            let completedNow = trusted && monitoring && !(model.isTrusted && model.hasInputMonitoring)
            withAnimation(ShellTheme.ease) {
                model.isTrusted = trusted
                model.hasInputMonitoring = monitoring
            }
            if completedNow {
                // Let the "granted" state register before moving on, and bring the window back
                // in front of System Settings.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    guard let self, let window = onboardingWindow, model.step == .accessibility else { return }
                    ShellActivation.windowDidOpen(window)
                    if !model.isLastStep { model.advance() }
                }
            }
        }
        if trusted, onboardingModel == nil || monitoring {
            trustTimer?.invalidate()
            trustTimer = nil
        }
    }

    private func finishOnboarding() {
        settings.hasCompletedOnboarding = true
        onboardingWindow?.close()
    }

    // MARK: Windows

    private func makeSettingsWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: SettingsView(settings: settings, navigation: navigation, jevKey: jevKey, engine: engine, updater: updater))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hosting
        window.title = "Colon Settings"
        // An empty unified toolbar gives the taller titlebar, so the traffic lights sit
        // inside the sidebar panel like other macOS settings windows.
        window.toolbar = NSToolbar(identifier: "ColonSettings")
        window.toolbarStyle = .unified
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.setContentSize(NSSize(width: 760, height: 600))
        window.contentMinSize = NSSize(width: 720, height: 520)
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("ColonSettings")
        window.delegate = self
        return window
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === onboardingWindow {
            // Closing after granting access counts as done; otherwise ask again next launch.
            if Permissions.accessibilityGranted { settings.hasCompletedOnboarding = true }
            onboardingWindow = nil
            onboardingModel = nil
        }
        ShellActivation.windowWillClose(window)
    }
}

/// Side-effect-free permission probes.
enum Permissions {
    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    static var inputMonitoringGranted: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }
}
