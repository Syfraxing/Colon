import Foundation

/// A keystroke, already translated by the event tap using the active keyboard layout.
public enum KeyInput: Equatable, Sendable {
    /// Printable text produced by the key (may be more than one character with dead keys).
    case text(String)
    case backspace
    case up, down, left, right
    case enter, tab, escape
    /// ⌘↩: insert the selection and keep the picker open (multi-insert).
    case commandEnter
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
        /// Insert the selected suggestion and keep the picker open for another pick (⌘↩).
        /// The first one deletes trigger + query; later ones delete nothing.
        case commitSelectionKeepOpen(deleteCount: Int)
        /// `<trigger>gif` + space: delete the `deleteCount` typed characters (the space was
        /// swallowed) and open GIF search.
        case openGIFSearch(deleteCount: Int)
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
    /// The bare trigger shows the picker with recents (`.show(query: "")`). Picker keys that would
    /// also be meaningful to the app (Enter, Tab, Esc, ⌘↩) stay with the app on an empty query
    /// until the user moves the selection, so `a :⏎` is still a newline.
    public var showsRecentsOnTrigger: Bool
    /// Compact (horizontal) picker: ←/→ move the selection while it is visible instead of hiding it.
    public var horizontalLayout: Bool
    /// `<trigger>gif` + space opens GIF search.
    public var gifSearchEnabled: Bool

    /// Whether the picker is currently shown (input layer reports back what the UI did).
    public private(set) var isShowing = false
    /// Current query (after the trigger), nil when not tracking. While multi-inserting it keeps
    /// the query the picker was opened for, although that text is no longer in the app.
    public private(set) var query: String?
    /// True after a ⌘↩ insert while the picker stays open; the `:query` has been replaced, so
    /// nothing typed is pending in the app.
    public private(set) var isMultiInserting = false
    /// The user moved the highlight for the current query (arrow keys).
    public private(set) var selectionMoved = false

    /// True when the character before the caret is a word boundary (or unknown, e.g. after a
    /// focus change), i.e. a trigger typed now would start a query.
    private var atBoundary = true
    /// Characters of the opening trigger typed so far (only < trigger.count while not tracking).
    private var triggerProgress = 0
    /// Characters of the closing trigger typed after the query (multi-char triggers only;
    /// they reached the app, so they count towards deletion).
    private var closingProgress = 0

    /// Keyword typed after the trigger that, followed by a space, opens GIF search.
    public static let gifKeyword = "gif"

    public init(trigger: String = ":", minQueryLength: Int = 2, autoReplaceOnClosingTrigger: Bool = true,
                showsRecentsOnTrigger: Bool = false, horizontalLayout: Bool = false, gifSearchEnabled: Bool = false,
                shortcodeExists: @escaping @Sendable (String) -> Bool = { _ in false }) {
        self.trigger = trigger.isEmpty ? ":" : trigger
        self.minQueryLength = max(0, minQueryLength)
        self.autoReplaceOnClosingTrigger = autoReplaceOnClosingTrigger
        self.showsRecentsOnTrigger = showsRecentsOnTrigger
        self.horizontalLayout = horizontalLayout
        self.gifSearchEnabled = gifSearchEnabled
        self.shortcodeExists = shortcodeExists
    }

    /// True while a trigger has been typed and a query is being captured.
    public var isTracking: Bool { query != nil }

    /// Characters of the active capture currently in the target app (trigger + query + any partial
    /// closing trigger), nil when not tracking. Used when the user picks with the mouse.
    public var typedLength: Int? {
        guard let query else { return nil }
        if isMultiInserting { return 0 }
        return trigger.count + query.count + closingProgress
    }

    /// Feeds one keystroke.
    /// - Parameter pickerVisible: the picker is on screen with a selectable row. Picker keys
    ///   (↑ ↓ Enter Tab Esc) are swallowed only when this is true and the engine is showing;
    ///   otherwise they pass through to the app.
    public mutating func handle(_ input: KeyInput, pickerVisible: Bool) -> TriggerResult {
        if isMultiInserting {
            return handleMultiInsert(input, pickerVisible: pickerVisible)
        }
        let wasShowing = isShowing
        let ownsPickerKeys = pickerVisible && isShowing
        // On the bare trigger (recents), keys that also mean something to the app stay with the app
        // until the user has engaged with the picker by moving the selection.
        let ownsCommitKeys = ownsPickerKeys && (query?.isEmpty == false || selectionMoved)
        switch input {
        case .text(let text):
            let characters = Array(text)
            if characters.count == 1, let gif = gifTrigger(characters[0]) {
                return gif
            }
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
                selectionMoved = true
                return TriggerResult(.moveSelection(input == .down ? 1 : -1), swallow: true)
            }
            caretMoved()
            return visibilityResult(wasShowing: wasShowing)

        case .left, .right:
            if ownsPickerKeys && horizontalLayout {
                selectionMoved = true
                return TriggerResult(.moveSelection(input == .right ? 1 : -1), swallow: true)
            }
            caretMoved()
            return visibilityResult(wasShowing: wasShowing)

        case .enter, .tab:
            if ownsCommitKeys, let query {
                let count = trigger.count + query.count
                endTracking(boundary: true)
                return TriggerResult(.commitSelection(deleteCount: count), swallow: true)
            }
            endTracking(boundary: true)
            return visibilityResult(wasShowing: wasShowing)

        case .commandEnter:
            if ownsCommitKeys, let query {
                let count = trigger.count + query.count
                isMultiInserting = true
                closingProgress = 0
                triggerProgress = 0
                return TriggerResult(.commitSelectionKeepOpen(deleteCount: count), swallow: true)
            }
            // A ⌘ shortcut like any other: the capture ends silently.
            reset()
            return visibilityResult(wasShowing: wasShowing)

        case .escape:
            if ownsCommitKeys {
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

    /// After a ⌘↩ the picker stays open with nothing pending in the app: ⌘↩ inserts again, Enter/Tab
    /// insert one more and close, Esc closes, the selection keys still move, and any other key closes
    /// the picker and is handled as ordinary typing right after an emoji (a word boundary).
    private mutating func handleMultiInsert(_ input: KeyInput, pickerVisible: Bool) -> TriggerResult {
        if pickerVisible {
            switch input {
            case .commandEnter:
                return TriggerResult(.commitSelectionKeepOpen(deleteCount: 0), swallow: true)
            case .enter, .tab:
                endTracking(boundary: true)
                return TriggerResult(.commitSelection(deleteCount: 0), swallow: true)
            case .escape:
                endTracking(boundary: true)
                return TriggerResult(.hide, swallow: true)
            case .up, .down:
                return TriggerResult(.moveSelection(input == .down ? 1 : -1), swallow: true)
            case .left where horizontalLayout, .right where horizontalLayout:
                return TriggerResult(.moveSelection(input == .right ? 1 : -1), swallow: true)
            default:
                break
            }
        }
        // Close, then treat the key as if typed right after the inserted emoji.
        endTracking(boundary: true)
        var result = handle(input, pickerVisible: false)
        if result.action == .none { result.action = .hide }
        return result
    }

    /// Forget everything (focus change, picker dismissed by mouse, etc.).
    public mutating func reset() {
        isShowing = false
        query = nil
        isMultiInserting = false
        selectionMoved = false
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
                selectionMoved = false
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
                selectionMoved = false
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
        isMultiInserting = false
        selectionMoved = false
        isShowing = false
        triggerProgress = 0
        closingProgress = 0
        atBoundary = true
    }

    private mutating func beginTracking() {
        query = ""
        isMultiInserting = false
        selectionMoved = false
        triggerProgress = 0
        closingProgress = 0
    }

    private mutating func endTracking(boundary: Bool) {
        query = nil
        isMultiInserting = false
        selectionMoved = false
        isShowing = false
        triggerProgress = 0
        closingProgress = 0
        atBoundary = boundary
    }

    /// Converts the post-transition state into show/hide/none.
    private mutating func visibilityResult(wasShowing: Bool) -> TriggerResult {
        if let query, closingProgress == 0, query.count >= minQueryLength || (query.isEmpty && showsRecentsOnTrigger) {
            isShowing = true
            return TriggerResult(.show(query: query))
        }
        isShowing = false
        return TriggerResult(wasShowing ? .hide : .none)
    }

    /// `<trigger>gif` followed by a typed space opens GIF search. The space is swallowed, so only
    /// trigger + keyword reached the app. `:gifs` and `:gif:` stay ordinary.
    private mutating func gifTrigger(_ character: Character) -> TriggerResult? {
        guard gifSearchEnabled, character == " ", closingProgress == 0,
              let query, query.lowercased() == Self.gifKeyword else { return nil }
        let deleteCount = trigger.count + query.count
        endTracking(boundary: true)
        return TriggerResult(.openGIFSearch(deleteCount: deleteCount), swallow: true)
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
