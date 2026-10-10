import AppKit
import Combine
import ColonCore
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
    let updater = Updater()
    private lazy var settingsWindow = SettingsWindowController(settings: settings, engine: engine, updater: updater)
    private var statusItem: StatusItemController?
    private var cancellables: Set<AnyCancellable> = []

    /// App that was frontmost when search mode opened; receives the picked emoji.
    private var searchTargetApp: NSRunningApplication?

    func start() {
        // Load the dataset now: the tap callback must never pay for the first JSON load.
        _ = EmojiStore.shared.all.count

        let statusItem = StatusItemController(settings: settings, engine: engine, updater: updater)
        self.statusItem = statusItem
        statusItem.onOpenSettings = { [weak self] in self?.openSettingsOrOnboarding() }
        statusItem.onOpenPicker = { [weak self] in self?.toggleSearch() }
        statusItem.onQuit = { NSApp.terminate(nil) }

        input.delegate = self
        input.$status
            .receive(on: RunLoop.main)
            .sink { [weak statusItem] status in statusItem?.update(inputStatus: status) }
            .store(in: &cancellables)

        picker.onPick = { [weak self] item in self?.handleMousePick(item) }
        picker.onDismiss = { [weak self] in
            self?.input.cancelTracking()
            self?.engine.reset()
            self?.searchTargetApp = nil
        }

        settingsWindow.onAccessibilityGranted = { [weak self] in self?.input.start() }
        settingsWindow.onAPIKeyChanged = { [weak self] in self?.engine.reloadAPIKey() }
        KeyboardShortcuts.onKeyUp(for: .openPicker) { [weak self] in self?.toggleSearch() }

        // Build the insert click before the first insert whenever the sound is (or turns) on.
        settings.$playsInsertSound
            .removeDuplicates()
            .sink { isOn in if isOn { Feedback.warmUp() } }
            .store(in: &cancellables)

        input.start()
        settingsWindow.showOnboardingIfNeeded()
        updater.start()
    }

    /// Re-opening the app from Finder/Spotlight while it runs shows Settings.
    func handleReopen() {
        openSettingsOrOnboarding()
    }

    func willTerminate() {
        input.stop()
        UsageStore.shared.flush()
    }

    private func openSettingsOrOnboarding() {
        if input.status == .noPermission {
            settingsWindow.showOnboardingIfNeeded()
        } else {
            settingsWindow.show()
        }
    }

    private func toggleSearch() {
        if picker.isVisible, searchTargetApp != nil {
            picker.hide()
            engine.reset()
            searchTargetApp = nil
            return
        }
        guard settings.isEnabled else { return }
        input.cancelTracking()
        picker.hide()
        searchTargetApp = NSWorkspace.shared.frontmostApplication
        engine.reset()
        picker.showSearch()
    }

    private func handleMousePick(_ item: Suggestion.Item) {
        let text = engine.output(for: item)
        engine.recordUse(item)
        Feedback.inserted(settings)
        // Take the search target before hiding, so nothing the hide triggers (resign key) can clear it.
        let searchTarget = searchTargetApp
        searchTargetApp = nil
        picker.hide()
        if let target = searchTarget {
            if target.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                // Searching from our own Settings window: there is no other app to type into.
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } else {
                // The panel is ordered out by now, so typing reaches the target app.
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
        // Delta 0 is the input layer engaging the bare-trigger strip: highlight the first recent.
        if delta == 0 {
            picker.engage()
        } else {
            picker.moveSelection(by: delta)
        }
    }

    func inputCommitSelection() -> String? {
        defer { inputHide() }
        guard let item = picker.selectedSuggestion?.item else { return nil }
        engine.recordUse(item)
        Feedback.inserted(settings)
        return engine.output(for: item)
    }

    func inputCommit(shortcode: String) -> String? {
        defer { inputHide() }
        guard let emoji = EmojiStore.shared.emoji(forShortcode: shortcode) else { return nil }
        engine.recordUse(emoji)
        Feedback.inserted(settings)
        return engine.output(for: emoji)
    }

    func inputIsPointInPicker(_ point: CGPoint) -> Bool {
        picker.contains(screenPoint: point)
    }

    func inputPickerIsVisible() -> Bool {
        picker.isVisible && picker.selectedSuggestion != nil
    }

    // MARK: v0.4 input

    /// ⌘↩: insert the selection but leave the picker (and the capture) open.
    func inputCommitSelectionKeepOpen() -> String? {
        guard let item = picker.selectedSuggestion?.item else { return nil }
        engine.recordUse(item)
        Feedback.inserted(settings)
        picker.noteInserted()
        return engine.output(for: item)
    }
}
