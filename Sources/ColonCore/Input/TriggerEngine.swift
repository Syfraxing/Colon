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
///
/// Privacy: the only state derived from typing is `atBoundary` (one bit about the last
/// character), how many characters of the trigger have been typed, and the active query.
/// Nothing typed outside an active `:query` is retained.
/// OWNER: input worker.
public struct TriggerEngine: Sendable {
    /// Longest query tracked; typing past it ends tracking (no shortcode is that long).
    public static let maxQueryLength = 32

    public var trigger: String {
        didSet { if trigger != oldValue { reset() } }
    }
    public var minQueryLength: Int
    public var autoReplaceOnClosingTrigger: Bool
    /// Returns true if a shortcode exists (used for closing-trigger auto replace).
    public var shortcodeExists: @Sendable (String) -> Bool

    /// Whether the picker is currently shown (input layer reports back what the UI did).
    public private(set) var isShowing = false
    /// Current query (after the trigger), nil when not tracking.
    public private(set) var query: String?

    /// True when the character before the caret is a word boundary (or unknown, e.g. after a
    /// focus change), i.e. a trigger typed now would start a query.
    private var atBoundary = true
    /// Characters of the opening trigger typed so far (only < trigger.count while not tracking).
    private var triggerProgress = 0
    /// Characters of the closing trigger typed after the query (multi-char triggers only;
    /// they reached the app, so they count towards deletion).
    private var closingProgress = 0

    public init(trigger: String = ":", minQueryLength: Int = 2, autoReplaceOnClosingTrigger: Bool = true,
                shortcodeExists: @escaping @Sendable (String) -> Bool = { _ in false }) {
        self.trigger = trigger.isEmpty ? ":" : trigger
        self.minQueryLength = max(0, minQueryLength)
        self.autoReplaceOnClosingTrigger = autoReplaceOnClosingTrigger
        self.shortcodeExists = shortcodeExists
    }

    /// True while a trigger has been typed and a query is being captured.
    public var isTracking: Bool { query != nil }

    /// Characters of the active capture currently in the target app (trigger + query + any partial
    /// closing trigger), nil when not tracking. Used when the user picks with the mouse.
    public var typedLength: Int? {
        guard let query else { return nil }
        return trigger.count + query.count + closingProgress
    }

    /// Feeds one keystroke.
    /// - Parameter pickerVisible: the picker is on screen with a selectable row. Picker keys
    ///   (↑ ↓ Enter Tab Esc) are swallowed only when this is true and the engine is showing;
    ///   otherwise they pass through to the app.
    public mutating func handle(_ input: KeyInput, pickerVisible: Bool) -> TriggerResult {
        let wasShowing = isShowing
        let ownsPickerKeys = pickerVisible && isShowing
        switch input {
        case .text(let text):
            let characters = Array(text)
            for (index, character) in characters.enumerated() {
                // A commit is only honoured for a single typed character: with composed multi-char
                // input we cannot swallow part of the event.
                if let commit = consume(character, isOnlyCharacter: characters.count == 1 && index == 0) {
                    return commit
                }
            }
            return visibilityResult(wasShowing: wasShowing)

        case .backspace:
            backspace()
            return visibilityResult(wasShowing: wasShowing)

        case .up, .down:
            if ownsPickerKeys {
                return TriggerResult(.moveSelection(input == .down ? 1 : -1), swallow: true)
            }
            caretMoved()
            return visibilityResult(wasShowing: wasShowing)

        case .left, .right:
            caretMoved()
            return visibilityResult(wasShowing: wasShowing)

        case .enter, .tab:
            if ownsPickerKeys, let query {
                let count = trigger.count + query.count
                endTracking(boundary: true)
                return TriggerResult(.commitSelection(deleteCount: count), swallow: true)
            }
            endTracking(boundary: true)
            return visibilityResult(wasShowing: wasShowing)

        case .escape:
            if ownsPickerKeys {
                // Text stays; the caret now follows a query character.
                endTracking(boundary: false)
                return TriggerResult(.hide, swallow: true)
            }
            if isTracking { endTracking(boundary: false) }
            triggerProgress = 0
            return visibilityResult(wasShowing: wasShowing)

        case .interrupt:
            reset()
            return visibilityResult(wasShowing: wasShowing)
        }
    }

    /// Forget everything (focus change, picker dismissed by mouse, etc.).
    public mutating func reset() {
        isShowing = false
        query = nil
        triggerProgress = 0
        closingProgress = 0
        atBoundary = true
    }

    // MARK: - Transitions

    /// Feeds one typed character. Returns a result only for a closing-trigger commit.
    private mutating func consume(_ character: Character, isOnlyCharacter: Bool) -> TriggerResult? {
        let triggerChars = Array(trigger)

        if let current = query {
            if closingProgress > 0 || (autoReplaceOnClosingTrigger && !current.isEmpty && character == triggerChars[0]) {
                return typeClosing(character, query: current, triggerChars: triggerChars, isOnlyCharacter: isOnlyCharacter)
            }
            if Self.isQueryCharacter(character), current.count < Self.maxQueryLength {
                query = current + String(character)
            } else {
                endTracking(boundary: isBoundary(character))
            }
            return nil
        }

        if triggerProgress > 0 {
            if character == triggerChars[triggerProgress] {
                triggerProgress += 1
                if triggerProgress == triggerChars.count { beginTracking() }
                return nil
            }
            // The prefix was not a trigger after all; it ends with a trigger character (no boundary).
            triggerProgress = 0
            atBoundary = false
        }

        if atBoundary, character == triggerChars[0] {
            triggerProgress = 1
            if triggerChars.count == 1 { beginTracking() }
            return nil
        }
        atBoundary = isBoundary(character)
        return nil
    }

    private mutating func typeClosing(_ character: Character, query current: String, triggerChars: [Character],
                                      isOnlyCharacter: Bool) -> TriggerResult? {
        guard character == triggerChars[closingProgress], shortcodeExists(current) else {
            // Not a (known) closing trigger: the capture ends and `:xyz:` stays literal.
            closingProgress = 0
            endTracking(boundary: isBoundary(character))
            return nil
        }
        if closingProgress + 1 < triggerChars.count {
            // Partial multi-char closing trigger reaches the app; picker hides until resolved.
            closingProgress += 1
            return nil
        }
        guard isOnlyCharacter else {
            closingProgress = 0
            endTracking(boundary: false)
            return nil
        }
        // Everything typed except the final (swallowed) closing character must be deleted.
        let deleteCount = triggerChars.count * 2 + current.count - 1
        endTracking(boundary: false)
        return TriggerResult(.commitShortcode(current, deleteCount: deleteCount), swallow: true)
    }

    private mutating func backspace() {
        if let current = query {
            if closingProgress > 0 {
                closingProgress -= 1
            } else if !current.isEmpty {
                query = String(current.dropLast())
            } else {
                // Deleted the last trigger character: back to a partial trigger at a boundary.
                query = nil
                isShowing = false
                triggerProgress = trigger.count - 1
                atBoundary = true
            }
            return
        }
        if triggerProgress > 0 {
            triggerProgress -= 1
        } else {
            // We keep no text, so we cannot know what is now before the caret; assume a boundary
            // (docs/RESEARCH.md §9.1).
            atBoundary = true
        }
    }

    /// The caret moved to an unknown position (arrow keys).
    private mutating func caretMoved() {
        query = nil
        isShowing = false
        triggerProgress = 0
        closingProgress = 0
        atBoundary = true
    }

    private mutating func beginTracking() {
        query = ""
        triggerProgress = 0
        closingProgress = 0
    }

    private mutating func endTracking(boundary: Bool) {
        query = nil
        isShowing = false
        triggerProgress = 0
        closingProgress = 0
        atBoundary = boundary
    }

    /// Converts the post-transition state into show/hide/none.
    private mutating func visibilityResult(wasShowing: Bool) -> TriggerResult {
        if let query, closingProgress == 0, query.count >= minQueryLength {
            isShowing = true
            return TriggerResult(.show(query: query))
        }
        isShowing = false
        return TriggerResult(wasShowing ? .hide : .none)
    }

    // MARK: - Character classes

    /// Letters, digits, `_`, `+`, `-`.
    public static func isQueryCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "+" || character == "-"
    }

    /// Whitespace and punctuation (other than query and trigger characters) are word boundaries.
    /// Trigger characters are not, so `std::vector` or `a::b` never open a query.
    private func isBoundary(_ character: Character) -> Bool {
        !Self.isQueryCharacter(character) && !trigger.contains(character)
    }
}
