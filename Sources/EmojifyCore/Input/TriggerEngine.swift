import Foundation

/// A keystroke, already translated by the event tap using the active keyboard layout.
public enum KeyInput: Equatable, Sendable {
    /// Printable text produced by the key (may be more than one character with dead keys).
    case text(String)
    case backspace
    case up, down, left, right
    case enter, tab, escape
    /// Anything that should silently end tracking: ⌘/⌃ shortcuts, mouse click, app switch, unknown keys.
    case interrupt
}

/// What the input layer must do in response to a keystroke.
public struct TriggerResult: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case none
        /// Picker should be visible with this query (opening or updating).
        case show(query: String)
        case hide
        /// Move selection by delta (+1 next, -1 previous).
        case moveSelection(Int)
        /// Insert the currently selected suggestion, deleting `deleteCount` characters
        /// (trigger + query) already typed into the target app.
        case commitSelection(deleteCount: Int)
        /// Insert this exact shortcode's emoji (closing-trigger auto replace, e.g. `:joy:`).
        case commitShortcode(String, deleteCount: Int)
    }

    public var action: Action
    /// True if the original key event must be swallowed (not delivered to the app).
    public var swallow: Bool

    public init(_ action: Action, swallow: Bool = false) {
        self.action = action
        self.swallow = swallow
    }
}

/// Pure state machine for Slack-style `:query` tracking. No AppKit, fully unit-testable.
/// Rules (see docs/ARCHITECTURE.md): trigger only at a word boundary; query chars are
/// letters, digits, `_`, `+`, `-`; whitespace or other punctuation ends tracking.
/// OWNER: input worker.
public struct TriggerEngine: Sendable {
    public var trigger: String
    public var minQueryLength: Int
    public var autoReplaceOnClosingTrigger: Bool
    /// Returns true if a shortcode exists (used for closing-trigger auto replace).
    public var shortcodeExists: @Sendable (String) -> Bool

    /// Whether the picker is currently shown (input layer reports back what the UI did).
    public private(set) var isShowing = false
    /// Current query (after the trigger), nil when not tracking.
    public private(set) var query: String?

    public init(trigger: String = ":", minQueryLength: Int = 1, autoReplaceOnClosingTrigger: Bool = true,
                shortcodeExists: @escaping @Sendable (String) -> Bool = { _ in false }) {
        self.trigger = trigger
        self.minQueryLength = minQueryLength
        self.autoReplaceOnClosingTrigger = autoReplaceOnClosingTrigger
        self.shortcodeExists = shortcodeExists
    }

    public mutating func handle(_ input: KeyInput) -> TriggerResult {
        // SCAFFOLD
        TriggerResult(.none)
    }

    /// Forget everything (focus change, picker dismissed by mouse, etc.).
    public mutating func reset() {
        isShowing = false
        query = nil
    }
}
