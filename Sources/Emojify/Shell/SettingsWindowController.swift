import AppKit
import EmojifyCore

/// Settings window (General, Jev, Shortcuts, Excluded Apps, About) and first-run onboarding
/// (Accessibility permission + optional Jev key). OWNER: shell worker.
@MainActor
final class SettingsWindowController {
    /// Called when Accessibility permission becomes granted so the coordinator can start input.
    var onAccessibilityGranted: (() -> Void)?

    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    func show() {
        // SCAFFOLD
    }

    /// Show onboarding if not completed or Accessibility permission is missing.
    func showOnboardingIfNeeded() {
        // SCAFFOLD
    }
}
