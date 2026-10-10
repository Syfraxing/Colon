import AppKit
import EmojifyCore
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Opens the picker in search mode from anywhere. Default ⌃⌥⌘E (Ctrl-Option-Cmd-E).
    static let openPicker = Self("openPicker", default: .init(.e, modifiers: [.control, .option, .command]))
}

/// Wires input, ranking and UI together. Integration point; keep logic out of here.
@MainActor
final class AppCoordinator: NSObject, InputControllerDelegate {
    let settings = AppSettings.shared
    private(set) lazy var engine = SuggestionEngine(settings: settings)
    private lazy var input = InputController(settings: settings)
    private lazy var picker = PickerPanelController(engine: engine, settings: settings)
    private lazy var settingsWindow = SettingsWindowController(settings: settings)
    private var statusItem: StatusItemController?

    /// App that was frontmost when search mode opened; receives the picked emoji.
    private var searchTargetApp: NSRunningApplication?

    func start() {
        statusItem = StatusItemController(settings: settings, engine: engine)
        statusItem?.onOpenSettings = { [weak self] in self?.settingsWindow.show() }
        statusItem?.onQuit = { NSApp.terminate(nil) }

        input.delegate = self
        picker.onPick = { [weak self] emoji in self?.handleMousePick(emoji) }
        picker.onDismiss = { [weak self] in
            self?.input.cancelTracking()
            self?.engine.reset()
            self?.searchTargetApp = nil
        }

        settingsWindow.onAccessibilityGranted = { [weak self] in self?.input.start() }
        KeyboardShortcuts.onKeyUp(for: .openPicker) { [weak self] in self?.openSearch() }

        input.start()
        settingsWindow.showOnboardingIfNeeded()
    }

    /// Re-opening the app from Finder/Spotlight while it runs shows Settings.
    func handleReopen() {
        settingsWindow.show()
    }

    private func openSearch() {
        guard settings.isEnabled else { return }
        input.cancelTracking()
        searchTargetApp = NSWorkspace.shared.frontmostApplication
        engine.reset()
        picker.showSearch()
    }

    private func handleMousePick(_ emoji: Emoji) {
        let text = engine.output(for: emoji)
        engine.recordUse(emoji)
        picker.hide()
        if let target = searchTargetApp {
            searchTargetApp = nil
            target.activate()
            // Give the target app a beat to become key before typing into it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [settings] in
                Inserter.replace(deleteCount: 0, with: text, method: settings.insertionMethod)
            }
        } else {
            input.commitFromMouse(text)
        }
        engine.reset()
    }

    // MARK: InputControllerDelegate

    func inputShow(query: String, caret: CGRect?, context: PredictionContext) {
        engine.update(query: query, context: context)
        picker.show(near: caret)
    }

    func inputHide() {
        picker.hide()
        engine.reset()
    }

    func inputMoveSelection(by delta: Int) {
        picker.moveSelection(by: delta)
    }

    func inputCommitSelection() -> String? {
        defer { inputHide() }
        guard let emoji = picker.selectedSuggestion?.emoji else { return nil }
        engine.recordUse(emoji)
        return engine.output(for: emoji)
    }

    func inputCommit(shortcode: String) -> String? {
        defer { inputHide() }
        guard let emoji = EmojiStore.shared.emoji(forShortcode: shortcode) else { return nil }
        engine.recordUse(emoji)
        return engine.output(for: emoji)
    }
}
