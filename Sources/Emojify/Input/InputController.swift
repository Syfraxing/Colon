import AppKit
import EmojifyCore

/// Receives trigger events from the keyboard tap. Implemented by `AppCoordinator`.
@MainActor
protocol InputControllerDelegate: AnyObject {
    /// Picker should appear/update. `caret` is in Cocoa screen coordinates (bottom-left origin), nil if unknown.
    func inputShow(query: String, caret: CGRect?, context: PredictionContext)
    func inputHide()
    func inputMoveSelection(by delta: Int)
    /// Return the emoji string to insert for the current selection, or nil to just close.
    func inputCommitSelection() -> String?
    /// Return the emoji string for an exact shortcode (closing-trigger auto replace), nil if unknown.
    func inputCommit(shortcode: String) -> String?
}

/// Owns the CGEventTap, runs `TriggerEngine`, honours exclusions/secure input,
/// and performs the deletion + insertion. OWNER: input worker.
@MainActor
final class InputController {
    weak var delegate: InputControllerDelegate?
    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    /// True once the tap is installed (requires Accessibility permission).
    private(set) var isRunning = false

    /// Install the event tap. Returns false if Accessibility permission is missing.
    @discardableResult
    func start() -> Bool {
        // SCAFFOLD
        false
    }

    func stop() {
        // SCAFFOLD
    }

    /// The UI dismissed the picker (click outside, Esc in panel). Reset tracking.
    func cancelTracking() {
        // SCAFFOLD
    }

    /// The user clicked a suggestion with the mouse: delete the typed `:query` and insert `text`.
    func commitFromMouse(_ text: String) {
        // SCAFFOLD
    }
}

/// Puts text into the frontmost app. OWNER: input worker.
@MainActor
enum Inserter {
    /// Delete `deleteCount` characters before the caret, then insert `text`.
    static func replace(deleteCount: Int, with text: String, method: InsertionMethod) {
        // SCAFFOLD
    }
}

/// Finds the text caret on screen via Accessibility. OWNER: input worker.
@MainActor
enum CaretLocator {
    /// Caret rect in Cocoa screen coordinates (bottom-left origin), nil when unavailable.
    static func caretRect() -> CGRect? {
        // SCAFFOLD
        nil
    }
}
