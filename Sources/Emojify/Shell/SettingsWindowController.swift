import AppKit
import ApplicationServices
import EmojifyCore
import SwiftUI

/// Settings window (General, Jev, Shortcuts, Excluded Apps, About) and first-run onboarding
/// (Accessibility permission + optional Jev key). OWNER: shell worker.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    /// Called when Accessibility permission becomes granted so the coordinator can start input.
    var onAccessibilityGranted: (() -> Void)?

    private let settings: AppSettings
    private let navigation = SettingsNavigation()
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var onboardingModel: OnboardingModel?
    private var trustTimer: Timer?

    init(settings: AppSettings) {
        self.settings = settings
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
        let trusted = AXIsProcessTrusted()
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
        let model = OnboardingModel(steps: steps, isTrusted: trusted)
        model.onFinish = { [weak self] in self?.finishOnboarding() }
        onboardingModel = model

        let view = OnboardingView(model: model, settings: settings, practiceEngine: SuggestionEngine(settings: settings))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 540),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = NSHostingController(rootView: view)
        window.title = "Welcome to Emojify"
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

    private func checkTrust() {
        guard AXIsProcessTrusted() else { return }
        trustTimer?.invalidate()
        trustTimer = nil
        onAccessibilityGranted?()
        guard let model = onboardingModel, !model.isTrusted else { return }
        withAnimation(ShellTheme.ease) { model.isTrusted = true }
        // Let the "granted" state register before moving on, and bring the window back
        // in front of System Settings.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, let window = onboardingWindow, model.step == .accessibility else { return }
            ShellActivation.windowDidOpen(window)
            if !model.isLastStep { model.advance() }
        }
    }

    private func finishOnboarding() {
        settings.hasCompletedOnboarding = true
        onboardingWindow?.close()
    }

    // MARK: Windows

    private func makeSettingsWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: SettingsView(settings: settings, navigation: navigation))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hosting
        window.title = "Emojify Settings"
        // An empty unified toolbar gives the taller titlebar, so the traffic lights sit
        // inside the sidebar panel like other macOS settings windows.
        window.toolbar = NSToolbar(identifier: "EmojifySettings")
        window.toolbarStyle = .unified
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.setContentSize(NSSize(width: 760, height: 600))
        window.contentMinSize = NSSize(width: 720, height: 520)
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("EmojifySettings")
        window.delegate = self
        return window
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === onboardingWindow {
            // Closing after granting access counts as done; otherwise ask again next launch.
            if AXIsProcessTrusted() { settings.hasCompletedOnboarding = true }
            onboardingWindow = nil
            onboardingModel = nil
        }
        ShellActivation.windowWillClose(window)
    }
}
