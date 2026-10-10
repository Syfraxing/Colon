import AppKit
import EmojifyCore

/// The floating glass picker. A non-activating `NSPanel` hosting SwiftUI that never steals focus
/// from the app being typed in. OWNER: picker worker.
@MainActor
final class PickerPanelController {
    /// Called when the user clicks a suggestion.
    var onPick: ((Emoji) -> Void)?
    /// Called when the panel dismisses itself (e.g. click outside).
    var onDismiss: (() -> Void)?

    private let engine: SuggestionEngine
    private let settings: AppSettings

    init(engine: SuggestionEngine, settings: AppSettings) {
        self.engine = engine
        self.settings = settings
    }

    var isVisible: Bool {
        // SCAFFOLD
        false
    }

    /// Currently highlighted suggestion.
    var selectedSuggestion: Suggestion? {
        // SCAFFOLD
        engine.suggestions.first
    }

    /// Show (or reposition) near `caret` (Cocoa screen coords). nil caret: near the mouse.
    func show(near caret: CGRect?) {
        // SCAFFOLD
    }

    func hide() {
        // SCAFFOLD
    }

    /// Search mode (global hotkey): the panel becomes key and shows its own search field
    /// so the user can browse/search without typing into the target app. Picking calls `onPick`.
    func showSearch() {
        // SCAFFOLD
    }

    func moveSelection(by delta: Int) {
        // SCAFFOLD
    }
}
