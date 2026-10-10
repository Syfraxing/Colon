import CoreGraphics
import XCTest
@testable import ColonCore

final class TriggerEngineTests: XCTestCase {
    private let shortcodes: Set<String> = ["joy", "smile", "+1", "100", "t-rex"]

    private func makeEngine(trigger: String = ":", minQueryLength: Int = 1, autoReplace: Bool = true) -> TriggerEngine {
        let known = shortcodes
        return TriggerEngine(trigger: trigger, minQueryLength: minQueryLength, autoReplaceOnClosingTrigger: autoReplace,
                             shortcodeExists: { known.contains($0) })
    }

    /// Types each character as its own key event; returns the result of the last one.
    @discardableResult
    private func type(_ text: String, into engine: inout TriggerEngine) -> TriggerResult {
        var last = TriggerResult(.none)
        for character in text { last = engine.feed(.text(String(character))) }
        return last
    }

    private func show(_ query: String) -> TriggerResult { TriggerResult(.show(query: query)) }

    // MARK: Boundaries

    func testTriggerAtStartOpensQuery() {
        var engine = makeEngine()
        XCTAssertEqual(type(":", into: &engine), TriggerResult(.none))
        XCTAssertEqual(engine.query, "")
        XCTAssertEqual(type("h", into: &engine), show("h"))
        XCTAssertEqual(type("aha", into: &engine), show("haha"))
        XCTAssertTrue(engine.isShowing)
    }

    func testTriggerAfterSpaceOpensQuery() {
        var engine = makeEngine()
        type("hello :jo", into: &engine)
        XCTAssertEqual(engine.query, "jo")
        XCTAssertTrue(engine.isShowing)
    }

    func testTriggerAfterOpeningParenthesisAndOtherPunctuation() {
        for prefix in ["(", "\"", "[", ".", ",", "!", "\n", "\t", "😂"] {
            var engine = makeEngine()
            type("x\(prefix):jo", into: &engine)
            XCTAssertEqual(engine.query, "jo", "after \(prefix.debugDescription)")
        }
    }

    func testURLSchemeDoesNotTrigger() {
        var engine = makeEngine()
        XCTAssertEqual(type("http://example", into: &engine), TriggerResult(.none))
        XCTAssertNil(engine.query)
        XCTAssertFalse(engine.isShowing)
    }

    func testTimeDoesNotTrigger() {
        var engine = makeEngine()
        XCTAssertEqual(type("12:30", into: &engine), TriggerResult(.none))
        XCTAssertNil(engine.query)
    }

    func testWordColonWordDoesNotTrigger() {
        var engine = makeEngine()
        type("a:b", into: &engine)
        XCTAssertNil(engine.query)
        type(" foo:bar", into: &engine)
        XCTAssertNil(engine.query)
    }

    func testDoubleColonAfterWordDoesNotTrigger() {
        var engine = makeEngine()
        type("std::vector", into: &engine)
        XCTAssertNil(engine.query)
    }

    func testQueryCharactersBeforeTriggerAreNotBoundaries() {
        for prefix in ["_", "+", "-", "9", "é"] {
            var engine = makeEngine()
            type("\(prefix):jo", into: &engine)
            XCTAssertNil(engine.query, "after \(prefix)")
        }
    }

    func testNothingIsSwallowedWhileNotTracking() {
        var engine = makeEngine()
        type("plain text", into: &engine)
        for input: KeyInput in [.up, .down, .left, .right, .enter, .tab, .escape, .backspace, .interrupt] {
            XCTAssertFalse(engine.feed(input).swallow, "\(input)")
        }
    }

    private static let everyKeyInput: [KeyInput] = [
        .text("a"), .text(":"), .text(" "), .text("😂"), .text("é:"), .backspace,
        .up, .down, .left, .right, .enter, .tab, .escape, .interrupt,
    ]

    func testIdleNeverSwallowsAnyKey() {
        for pickerVisible in [false, true] {
            for input in Self.everyKeyInput {
                var engine = makeEngine()
                type("idle text ", into: &engine)
                engine.reset()
                let result = engine.handle(input, pickerVisible: pickerVisible)
                XCTAssertFalse(result.swallow, "\(input) visible=\(pickerVisible)")
                if case .commitSelection = result.action { XCTFail("commit while idle: \(input)") }
                if case .moveSelection = result.action { XCTFail("move while idle: \(input)") }
            }
        }
    }

    func testTrackingWithoutVisiblePickerNeverSwallowsPickerKeys() {
        for input: KeyInput in [.up, .down, .enter, .tab, .escape] {
            var engine = makeEngine()
            type(":jo", into: &engine)
            XCTAssertTrue(engine.isShowing)
            // The UI has no row to select (empty list or not yet on screen).
            let result = engine.handle(input, pickerVisible: false)
            XCTAssertFalse(result.swallow, "\(input)")
            XCTAssertEqual(result.action, .hide, "\(input)")
            XCTAssertNil(engine.query, "\(input)")
        }
    }

    func testTrackingBelowMinimumIgnoresStalePickerVisibility() {
        var engine = makeEngine(minQueryLength: 3)
        type(":jo", into: &engine)
        for input: KeyInput in [.up, .down, .enter, .tab, .escape] {
            var copy = engine
            XCTAssertFalse(copy.handle(input, pickerVisible: true).swallow, "\(input)")
        }
    }

    // MARK: Minimum length

    func testMinimumQueryLength() {
        var engine = makeEngine(minQueryLength: 2)
        XCTAssertEqual(type(":j", into: &engine), TriggerResult(.none))
        XCTAssertFalse(engine.isShowing)
        XCTAssertEqual(engine.query, "j")
        XCTAssertEqual(type("o", into: &engine), show("jo"))
        XCTAssertTrue(engine.isShowing)
    }

    func testDefaultMinimumIsTwo() {
        XCTAssertEqual(TriggerEngine().minQueryLength, 2)
    }

    func testMinimumZeroShowsOnBareTrigger() {
        var engine = makeEngine(minQueryLength: 0)
        XCTAssertEqual(type(":", into: &engine), show(""))
    }

    func testEmoticonBelowMinimumNeverShows() {
        var engine = makeEngine(minQueryLength: 2)
        XCTAssertEqual(type(":D", into: &engine), TriggerResult(.none))
        XCTAssertEqual(type(" ", into: &engine), TriggerResult(.none))
        XCTAssertEqual(type(":)", into: &engine), TriggerResult(.none))
        XCTAssertNil(engine.query)
    }

    // MARK: Backspace

    func testBackspaceEditsQuery() {
        var engine = makeEngine()
        type(":joy", into: &engine)
        let result = engine.feed(.backspace)
        XCTAssertEqual(result, show("jo"))
        XCTAssertFalse(result.swallow)
    }

    func testBackspaceBelowMinimumHides() {
        var engine = makeEngine(minQueryLength: 2)
        type(":jo", into: &engine)
        XCTAssertEqual(engine.feed(.backspace), TriggerResult(.hide))
        XCTAssertEqual(engine.query, "j")
        XCTAssertEqual(type("o", into: &engine), show("jo"))
    }

    func testBackspacePastTriggerStopsTracking() {
        var engine = makeEngine()
        type(":j", into: &engine)
        XCTAssertEqual(engine.feed(.backspace), TriggerResult(.hide))
        XCTAssertEqual(engine.query, "")
        XCTAssertEqual(engine.feed(.backspace), TriggerResult(.none))
        XCTAssertNil(engine.query)
        // Retyping the trigger at the same (boundary) spot starts again.
        type(":jo", into: &engine)
        XCTAssertEqual(engine.query, "jo")
    }

    func testBackspaceOutsideQueryAssumesBoundary() {
        var engine = makeEngine()
        type("ab", into: &engine)
        _ = engine.feed(.backspace)
        type(":jo", into: &engine)
        XCTAssertEqual(engine.query, "jo")
    }

    // MARK: Picker keys

    func testArrowsMoveSelectionOnlyWhileShowing() {
        var engine = makeEngine()
        type(":jo", into: &engine)
        XCTAssertEqual(engine.feed(.down), TriggerResult(.moveSelection(1), swallow: true))
        XCTAssertEqual(engine.feed(.up), TriggerResult(.moveSelection(-1), swallow: true))
        XCTAssertTrue(engine.isShowing)
        XCTAssertEqual(engine.query, "jo")
    }

    func testArrowsWhileTrackingBelowMinimumStopTracking() {
        var engine = makeEngine(minQueryLength: 3)
        type(":jo", into: &engine)
        XCTAssertEqual(engine.feed(.down), TriggerResult(.none))
        XCTAssertNil(engine.query)
    }

    func testLeftRightHideAndPassThrough() {
        for key: KeyInput in [.left, .right] {
            var engine = makeEngine()
            type(":jo", into: &engine)
            XCTAssertEqual(engine.feed(key), TriggerResult(.hide))
            XCTAssertNil(engine.query)
            XCTAssertFalse(engine.isShowing)
        }
    }

    func testEscapeHidesSwallowsAndKeepsText() {
        var engine = makeEngine()
        type(":jo", into: &engine)
        XCTAssertEqual(engine.feed(.escape), TriggerResult(.hide, swallow: true))
        XCTAssertNil(engine.query)
        // The caret follows "jo": a trigger now is not at a boundary.
        type(":x", into: &engine)
        XCTAssertNil(engine.query)
    }

    func testEscapeNotShowingPassesThrough() {
        var engine = makeEngine(minQueryLength: 3)
        type(":jo", into: &engine)
        XCTAssertEqual(engine.feed(.escape), TriggerResult(.none))
        XCTAssertNil(engine.query)
    }

    func testEnterCommitsSelection() {
        var engine = makeEngine()
        type(":haha", into: &engine)
        XCTAssertEqual(engine.feed(.enter), TriggerResult(.commitSelection(deleteCount: 5), swallow: true))
        XCTAssertNil(engine.query)
        XCTAssertFalse(engine.isShowing)
        // After an insertion the next trigger works immediately.
        type(":jo", into: &engine)
        XCTAssertEqual(engine.query, "jo")
    }

    func testTabCommitsSelection() {
        var engine = makeEngine()
        type(":jo", into: &engine)
        XCTAssertEqual(engine.feed(.tab), TriggerResult(.commitSelection(deleteCount: 3), swallow: true))
    }

    func testEnterNotShowingPassesThroughAndIsBoundary() {
        var engine = makeEngine(minQueryLength: 3)
        type(":jo", into: &engine)
        XCTAssertEqual(engine.feed(.enter), TriggerResult(.none))
        XCTAssertNil(engine.query)
        type(":jo", into: &engine)
        XCTAssertEqual(engine.query, "jo")
    }

    // MARK: Ending a query

    func testSpaceHidesAndPassesThrough() {
        var engine = makeEngine()
        type(":jo", into: &engine)
        let result = type(" ", into: &engine)
        XCTAssertEqual(result, TriggerResult(.hide))
        XCTAssertFalse(result.swallow)
        XCTAssertNil(engine.query)
        // Space is a boundary.
        type(":sm", into: &engine)
        XCTAssertEqual(engine.query, "sm")
    }

    func testPunctuationHides() {
        for terminator in [".", ",", ")", "!", "?", "'", "/"] {
            var engine = makeEngine()
            type(":jo", into: &engine)
            XCTAssertEqual(type(terminator, into: &engine), TriggerResult(.hide), terminator)
            XCTAssertNil(engine.query)
        }
    }

    func testQueryCharacters() {
        var engine = makeEngine()
        type(":t-rex_2+", into: &engine)
        XCTAssertEqual(engine.query, "t-rex_2+")
        XCTAssertTrue(engine.isShowing)
    }

    func testQueryMaxLength() {
        var engine = makeEngine()
        let longest = String(repeating: "a", count: TriggerEngine.maxQueryLength)
        XCTAssertEqual(type(":" + longest, into: &engine), show(longest))
        XCTAssertEqual(type("a", into: &engine), TriggerResult(.hide))
        XCTAssertNil(engine.query)
    }

    func testInterruptResetsSilently() {
        var engine = makeEngine()
        type(":jo", into: &engine)
        let result = engine.feed(.interrupt)
        XCTAssertEqual(result, TriggerResult(.hide))
        XCTAssertFalse(result.swallow)
        XCTAssertNil(engine.query)
        // A focus change counts as a fresh start (boundary).
        type(":jo", into: &engine)
        XCTAssertEqual(engine.query, "jo")
    }

    func testInterruptWhileNotShowingIsSilent() {
        var engine = makeEngine(minQueryLength: 3)
        type(":j", into: &engine)
        XCTAssertEqual(engine.feed(.interrupt), TriggerResult(.none))
        XCTAssertNil(engine.query)
    }

    func testInterruptRestoresBoundaryAfterWord() {
        var engine = makeEngine()
        type("word", into: &engine)
        _ = engine.feed(.interrupt)
        type(":jo", into: &engine)
        XCTAssertEqual(engine.query, "jo")
    }

    func testResetForgetsEverything() {
        var engine = makeEngine()
        type(":jo", into: &engine)
        engine.reset()
        XCTAssertNil(engine.query)
        XCTAssertFalse(engine.isShowing)
        XCTAssertNil(engine.typedLength)
    }

    func testTypedLengthForMousePick() {
        var engine = makeEngine()
        XCTAssertNil(engine.typedLength)
        type(":smi", into: &engine)
        XCTAssertEqual(engine.typedLength, 4)
    }

    func testMultiCharacterTextEvent() {
        var engine = makeEngine()
        XCTAssertEqual(engine.feed(.text(" :jo")), show("jo"))
        XCTAssertEqual(engine.feed(.text("y ")), TriggerResult(.hide))
    }

    func testComposedLetterExtendsQuery() {
        var engine = makeEngine()
        type(":caf", into: &engine)
        XCTAssertEqual(engine.feed(.text("é")), show("café"))
    }

    // MARK: Multi-character triggers

    func testDoubleColonTrigger() {
        var engine = makeEngine(trigger: "::")
        XCTAssertEqual(type(":", into: &engine), TriggerResult(.none))
        XCTAssertNil(engine.query)
        XCTAssertEqual(type(":", into: &engine), TriggerResult(.none))
        XCTAssertEqual(engine.query, "")
        XCTAssertEqual(type("jo", into: &engine), show("jo"))
        XCTAssertEqual(engine.feed(.enter), TriggerResult(.commitSelection(deleteCount: 4), swallow: true))
    }

    func testDoubleColonTriggerSingleColonDoesNotTrigger() {
        var engine = makeEngine(trigger: "::")
        type(" :jo", into: &engine)
        XCTAssertNil(engine.query)
    }

    func testDoubleColonTriggerRequiresBoundary() {
        var engine = makeEngine(trigger: "::")
        type("std::vector", into: &engine)
        XCTAssertNil(engine.query)
    }

    func testSemicolonTrigger() {
        var engine = makeEngine(trigger: ";;")
        type("hi ;;sm", into: &engine)
        XCTAssertEqual(engine.query, "sm")
        type(" a;;b", into: &engine)
        XCTAssertNil(engine.query)
    }

    func testColonDoesNothingWithSemicolonTrigger() {
        var engine = makeEngine(trigger: ";")
        type(":jo", into: &engine)
        XCTAssertNil(engine.query)
        type(" ;jo", into: &engine)
        XCTAssertEqual(engine.query, "jo")
    }

    func testBackspaceIntoMultiCharTrigger() {
        var engine = makeEngine(trigger: "::")
        type("::j", into: &engine)
        _ = engine.feed(.backspace)   // removes "j"
        XCTAssertEqual(engine.query, "")
        _ = engine.feed(.backspace)   // removes second ":", leaving a partial trigger
        XCTAssertNil(engine.query)
        type(":jo", into: &engine)  // completes "::" again
        XCTAssertEqual(engine.query, "jo")
    }

    func testChangingTriggerResets() {
        var engine = makeEngine()
        type(":jo", into: &engine)
        engine.trigger = ";"
        XCTAssertNil(engine.query)
        XCTAssertFalse(engine.isShowing)
    }

    // MARK: Closing trigger

    func testClosingTriggerCommitsExactShortcode() {
        var engine = makeEngine()
        type(":joy", into: &engine)
        // ":joy" reached the app (4 chars); the closing ":" is swallowed.
        XCTAssertEqual(type(":", into: &engine), TriggerResult(.commitShortcode("joy", deleteCount: 4), swallow: true))
        XCTAssertNil(engine.query)
        XCTAssertFalse(engine.isShowing)
    }

    func testClosingTriggerWorksBelowMinimumLength() {
        var engine = makeEngine(minQueryLength: 5)
        type(":+1", into: &engine)
        XCTAssertFalse(engine.isShowing)
        XCTAssertEqual(type(":", into: &engine), TriggerResult(.commitShortcode("+1", deleteCount: 3), swallow: true))
    }

    func testClosingTriggerUnknownShortcodeStaysLiteral() {
        var engine = makeEngine()
        type(":xyz", into: &engine)
        let result = type(":", into: &engine)
        XCTAssertEqual(result, TriggerResult(.hide))
        XCTAssertFalse(result.swallow)
        XCTAssertNil(engine.query)
        // ":xyz:" ends with a trigger char, not a boundary: ":xyz:abc" does not re-trigger.
        type("abc", into: &engine)
        XCTAssertNil(engine.query)
    }

    func testClosingTriggerDisabled() {
        var engine = makeEngine(autoReplace: false)
        type(":joy", into: &engine)
        XCTAssertEqual(type(":", into: &engine), TriggerResult(.hide))
        XCTAssertNil(engine.query)
    }

    func testDoubleTriggerWithEmptyQueryEndsTracking() {
        var engine = makeEngine(minQueryLength: 0)
        type(":", into: &engine)
        XCTAssertEqual(type(":", into: &engine), TriggerResult(.hide))
        XCTAssertNil(engine.query)
    }

    func testMultiCharClosingTrigger() {
        var engine = makeEngine(trigger: "::")
        type("::joy", into: &engine)
        // First closing ":" reaches the app; picker hides while it could still be a closing trigger.
        XCTAssertEqual(type(":", into: &engine), TriggerResult(.hide))
        XCTAssertEqual(engine.typedLength, 6)
        // "::joy:" (6 chars) reached the app; the final ":" is swallowed.
        XCTAssertEqual(type(":", into: &engine), TriggerResult(.commitShortcode("joy", deleteCount: 6), swallow: true))
        XCTAssertNil(engine.query)
    }

    func testMultiCharClosingTriggerBackspaceReturnsToQuery() {
        var engine = makeEngine(trigger: "::")
        type("::joy:", into: &engine)
        XCTAssertEqual(engine.feed(.backspace), show("joy"))
    }

    func testMultiCharClosingTriggerAbandoned() {
        var engine = makeEngine(trigger: "::")
        type("::joy:", into: &engine)
        XCTAssertEqual(type("x", into: &engine), TriggerResult(.none))
        XCTAssertNil(engine.query)
    }

    func testClosingTriggerIgnoredInsideComposedMultiCharEvent() {
        var engine = makeEngine()
        type(":joy", into: &engine)
        let result = engine.feed(.text(":a"))
        XCTAssertFalse(result.swallow)
        XCTAssertNil(engine.query)
    }
}

final class TriggerEngineV04Tests: XCTestCase {
    private let shortcodes: Set<String> = ["joy", "smile", "-1", "+1"]

    private func makeEngine(trigger: String = ":", minQueryLength: Int = 2, recents: Bool = true,
                            horizontal: Bool = false) -> TriggerEngine {
        let known = shortcodes
        return TriggerEngine(trigger: trigger, minQueryLength: minQueryLength, autoReplaceOnClosingTrigger: true,
                             showsRecentsOnTrigger: recents, horizontalLayout: horizontal,
                             shortcodeExists: { known.contains($0) })
    }

    @discardableResult
    private func type(_ text: String, into engine: inout TriggerEngine) -> TriggerResult {
        var last = TriggerResult(.none)
        for character in text { last = engine.feed(.text(String(character))) }
        return last
    }

    // MARK: Recents strip

    func testBareTriggerShowsRecents() {
        var engine = makeEngine()
        XCTAssertEqual(type(":", into: &engine), TriggerResult(.show(query: "")))
        XCTAssertTrue(engine.isShowing)
        XCTAssertEqual(engine.query, "")
    }

    func testBareTriggerWithRecentsOffWaitsForMinimum() {
        var engine = makeEngine(recents: false)
        XCTAssertEqual(type(":", into: &engine), TriggerResult(.none))
        XCTAssertEqual(type("j", into: &engine), TriggerResult(.none))
        XCTAssertEqual(type("o", into: &engine), TriggerResult(.show(query: "jo")))
    }

    func testRecentsOnlyAtBoundary() {
        for text in ["Time:", "http:", "12:", "std:"] {
            var engine = makeEngine()
            XCTAssertEqual(type(text, into: &engine), TriggerResult(.none), text)
            XCTAssertFalse(engine.isShowing, text)
        }
    }

    func testTimeColonEnterPassesThrough() {
        var engine = makeEngine()
        type("Time:", into: &engine)
        let result = engine.handle(.enter, pickerVisible: true)
        XCTAssertFalse(result.swallow)
        XCTAssertEqual(result.action, .none)
    }

    func testSpaceColonEnterNeverSwallowed() {
        for key: KeyInput in [.enter, .tab, .escape, .commandEnter] {
            var engine = makeEngine()
            type("a :", into: &engine)
            XCTAssertTrue(engine.isShowing)
            let result = engine.handle(key, pickerVisible: true)
            XCTAssertFalse(result.swallow, "\(key)")
            XCTAssertEqual(result.action, .hide, "\(key)")
            XCTAssertNil(engine.query, "\(key)")
        }
    }

    func testBareTriggerThenSpaceHidesAndPassesSpace() {
        var engine = makeEngine()
        type("a :", into: &engine)
        let result = engine.feed(.text(" "))
        XCTAssertEqual(result, TriggerResult(.hide))
        XCTAssertFalse(result.swallow)
        XCTAssertNil(engine.query)
        // The space is a boundary: a new trigger opens again.
        XCTAssertEqual(type(":", into: &engine), TriggerResult(.show(query: "")))
    }

    func testBareTriggerThenPunctuationHides() {
        for text in [")", "(", "/", "."] {
            var engine = makeEngine()
            type(":", into: &engine)
            let result = engine.feed(.text(text))
            XCTAssertEqual(result, TriggerResult(.hide), text)
            XCTAssertFalse(result.swallow, text)
        }
    }

    func testBareTriggerContinuesIntoQuery() {
        var engine = makeEngine()
        type(":", into: &engine)
        // Below the minimum the strip hides until the query is long enough.
        XCTAssertEqual(type("j", into: &engine), TriggerResult(.hide))
        XCTAssertEqual(type("o", into: &engine), TriggerResult(.show(query: "jo")))
        // Backspacing back to the bare trigger brings the strip back.
        XCTAssertEqual(engine.feed(.backspace), TriggerResult(.hide))
        XCTAssertEqual(engine.feed(.backspace), TriggerResult(.show(query: "")))
    }

    func testBareTriggerContinuesIntoQueryWithMinimumOne() {
        var engine = makeEngine(minQueryLength: 1)
        type(":", into: &engine)
        XCTAssertEqual(type("j", into: &engine), TriggerResult(.show(query: "j")))
        // Enter on a real query commits as before.
        XCTAssertEqual(engine.feed(.enter), TriggerResult(.commitSelection(deleteCount: 2), swallow: true))
    }

    func testArrowThenEnterInsertsRecent() {
        var engine = makeEngine()
        type(":", into: &engine)
        // The first ↓ engages the strip on its first item; the next one moves.
        XCTAssertEqual(engine.feed(.down), TriggerResult(.moveSelection(0), swallow: true))
        XCTAssertTrue(engine.selectionMoved)
        XCTAssertEqual(engine.feed(.down), TriggerResult(.moveSelection(1), swallow: true))
        XCTAssertEqual(engine.feed(.up), TriggerResult(.moveSelection(-1), swallow: true))
        XCTAssertEqual(engine.feed(.enter), TriggerResult(.commitSelection(deleteCount: 1), swallow: true))
        XCTAssertNil(engine.query)
    }

    func testArrowThenTabEscAndCommandEnterBelongToPicker() {
        var engine = makeEngine()
        type(":", into: &engine)
        _ = engine.feed(.down)
        XCTAssertEqual(engine.feed(.tab), TriggerResult(.commitSelection(deleteCount: 1), swallow: true))

        engine = makeEngine()
        type(":", into: &engine)
        _ = engine.feed(.down)
        XCTAssertEqual(engine.feed(.escape), TriggerResult(.hide, swallow: true))

        engine = makeEngine()
        type(":", into: &engine)
        _ = engine.feed(.down)
        XCTAssertEqual(engine.feed(.commandEnter), TriggerResult(.commitSelectionKeepOpen(deleteCount: 1), swallow: true))
    }

    func testMultiCharTriggerRecentsDeleteCount() {
        var engine = makeEngine(trigger: "::")
        XCTAssertEqual(type(":", into: &engine), TriggerResult(.none))
        XCTAssertEqual(type(":", into: &engine), TriggerResult(.show(query: "")))
        _ = engine.feed(.down)
        XCTAssertEqual(engine.feed(.enter), TriggerResult(.commitSelection(deleteCount: 2), swallow: true))
    }

    func testTypingAfterArrowResetsSelectionMoved() {
        var engine = makeEngine(minQueryLength: 1)
        type(":", into: &engine)
        _ = engine.feed(.down)
        type("j", into: &engine)
        XCTAssertFalse(engine.selectionMoved)
        XCTAssertEqual(engine.feed(.backspace), TriggerResult(.show(query: "")))
        // Back on the bare trigger, Enter belongs to the app again until the user arrows.
        XCTAssertFalse(engine.feed(.enter).swallow)
    }

    func testBareTriggerArrowsPassThroughWhenPickerNotVisible() {
        var engine = makeEngine()
        type(":", into: &engine)
        let result = engine.handle(.down, pickerVisible: false)
        XCTAssertFalse(result.swallow)
        XCTAssertEqual(result.action, .hide)
    }

    // MARK: Multi-insert

    func testCommandEnterThreeTimesThenEnterInsertsFour() {
        var engine = makeEngine()
        type(" :joy", into: &engine)
        XCTAssertEqual(engine.feed(.commandEnter), TriggerResult(.commitSelectionKeepOpen(deleteCount: 4), swallow: true))
        XCTAssertTrue(engine.isMultiInserting)
        XCTAssertTrue(engine.isShowing)
        XCTAssertEqual(engine.typedLength, 0)
        XCTAssertEqual(engine.feed(.commandEnter), TriggerResult(.commitSelectionKeepOpen(deleteCount: 0), swallow: true))
        XCTAssertEqual(engine.feed(.commandEnter), TriggerResult(.commitSelectionKeepOpen(deleteCount: 0), swallow: true))
        XCTAssertEqual(engine.feed(.enter), TriggerResult(.commitSelection(deleteCount: 0), swallow: true))
        XCTAssertFalse(engine.isMultiInserting)
        XCTAssertFalse(engine.isShowing)
        XCTAssertNil(engine.query)
    }

    func testTabAfterKeepOpenInsertsOneMoreAndCloses() {
        var engine = makeEngine()
        type(":joy", into: &engine)
        _ = engine.feed(.commandEnter)
        XCTAssertEqual(engine.feed(.tab), TriggerResult(.commitSelection(deleteCount: 0), swallow: true))
        XCTAssertNil(engine.query)
    }

    func testEscapeAfterKeepOpenCloses() {
        var engine = makeEngine()
        type(":joy", into: &engine)
        _ = engine.feed(.commandEnter)
        XCTAssertEqual(engine.feed(.escape), TriggerResult(.hide, swallow: true))
        XCTAssertNil(engine.query)
        XCTAssertFalse(engine.isMultiInserting)
    }

    func testArrowsStillMoveDuringMultiInsert() {
        var engine = makeEngine()
        type(":joy", into: &engine)
        _ = engine.feed(.commandEnter)
        XCTAssertEqual(engine.feed(.down), TriggerResult(.moveSelection(1), swallow: true))
        XCTAssertEqual(engine.feed(.up), TriggerResult(.moveSelection(-1), swallow: true))
        XCTAssertTrue(engine.isMultiInserting)
        // ←/→ only move in the compact layout.
        let result = engine.feed(.left)
        XCTAssertEqual(result, TriggerResult(.hide))
        XCTAssertFalse(engine.isMultiInserting)
    }

    func testCompactArrowsMoveDuringMultiInsert() {
        var engine = makeEngine(horizontal: true)
        type(":joy", into: &engine)
        _ = engine.feed(.commandEnter)
        XCTAssertEqual(engine.feed(.right), TriggerResult(.moveSelection(1), swallow: true))
        XCTAssertEqual(engine.feed(.left), TriggerResult(.moveSelection(-1), swallow: true))
        XCTAssertTrue(engine.isMultiInserting)
    }

    func testOtherKeyAfterKeepOpenClosesAndPassesThrough() {
        for key: KeyInput in [.text("a"), .text(" "), .backspace, .interrupt, .text("😂")] {
            var engine = makeEngine()
            type(":joy", into: &engine)
            _ = engine.feed(.commandEnter)
            let result = engine.feed(key)
            XCTAssertEqual(result, TriggerResult(.hide), "\(key)")
            XCTAssertFalse(result.swallow, "\(key)")
            XCTAssertFalse(engine.isMultiInserting, "\(key)")
            XCTAssertNil(engine.query, "\(key)")
        }
    }

    func testTriggerAfterKeepOpenStartsNewCapture() {
        var engine = makeEngine()
        type(":joy", into: &engine)
        _ = engine.feed(.commandEnter)
        // Right after an emoji is a boundary.
        XCTAssertEqual(engine.feed(.text(":")), TriggerResult(.show(query: "")))
        XCTAssertFalse(engine.isMultiInserting)
        XCTAssertEqual(engine.query, "")
        type("smile", into: &engine)
        XCTAssertEqual(engine.feed(.enter), TriggerResult(.commitSelection(deleteCount: 6), swallow: true))
    }

    func testKeepOpenWithoutVisiblePickerPassesThrough() {
        var engine = makeEngine()
        type(":joy", into: &engine)
        _ = engine.feed(.commandEnter)
        // The list emptied or the panel went away: keys belong to the app again.
        for key: KeyInput in [.enter, .commandEnter, .down] {
            var copy = engine
            let result = copy.handle(key, pickerVisible: false)
            XCTAssertFalse(result.swallow, "\(key)")
            XCTAssertEqual(result.action, .hide, "\(key)")
            XCTAssertNil(copy.query, "\(key)")
        }
    }

    func testCommandEnterNotTrackingPassesThrough() {
        var engine = makeEngine()
        type("hello", into: &engine)
        let result = engine.handle(.commandEnter, pickerVisible: true)
        XCTAssertEqual(result, TriggerResult(.none))
        XCTAssertFalse(result.swallow)
    }

    func testCommandEnterWithoutVisiblePickerEndsCapture() {
        var engine = makeEngine()
        type(":joy", into: &engine)
        let result = engine.handle(.commandEnter, pickerVisible: false)
        XCTAssertFalse(result.swallow)
        XCTAssertEqual(result.action, .hide)
        XCTAssertNil(engine.query)
    }

    func testMultiCharTriggerKeepOpenDeleteCounts() {
        var engine = makeEngine(trigger: ";;")
        type(";;smile", into: &engine)
        XCTAssertEqual(engine.feed(.commandEnter), TriggerResult(.commitSelectionKeepOpen(deleteCount: 7), swallow: true))
        XCTAssertEqual(engine.feed(.commandEnter), TriggerResult(.commitSelectionKeepOpen(deleteCount: 0), swallow: true))
        XCTAssertEqual(engine.feed(.enter), TriggerResult(.commitSelection(deleteCount: 0), swallow: true))
    }

    func testResetEndsMultiInsert() {
        var engine = makeEngine()
        type(":joy", into: &engine)
        _ = engine.feed(.commandEnter)
        engine.reset()
        XCTAssertFalse(engine.isMultiInserting)
        XCTAssertNil(engine.typedLength)
    }

    // MARK: Compact layout

    func testCompactArrowsMoveOnlyWhileVisible() {
        var engine = makeEngine(horizontal: true)
        type(":joy", into: &engine)
        XCTAssertEqual(engine.feed(.right), TriggerResult(.moveSelection(1), swallow: true))
        XCTAssertEqual(engine.feed(.left), TriggerResult(.moveSelection(-1), swallow: true))
        XCTAssertEqual(engine.feed(.down), TriggerResult(.moveSelection(1), swallow: true))
        XCTAssertEqual(engine.query, "joy")

        let hidden = engine.handle(.left, pickerVisible: false)
        XCTAssertFalse(hidden.swallow)
        XCTAssertEqual(hidden.action, .hide)
        XCTAssertNil(engine.query)
    }

    func testCompactArrowsBelowMinimumPassThrough() {
        var engine = makeEngine(minQueryLength: 3, recents: false, horizontal: true)
        type(":jo", into: &engine)
        // Stale "visible" from the UI does not matter while the engine is not showing.
        let result = engine.handle(.right, pickerVisible: true)
        XCTAssertFalse(result.swallow)
        XCTAssertNil(engine.query)
    }

    func testCompactArrowsNotTrackingPassThrough() {
        var engine = makeEngine(horizontal: true)
        type("hello", into: &engine)
        for key: KeyInput in [.left, .right] {
            XCTAssertFalse(engine.handle(key, pickerVisible: true).swallow)
        }
    }

    func testListLayoutArrowsHide() {
        var engine = makeEngine(horizontal: false)
        type(":joy", into: &engine)
        let result = engine.feed(.right)
        XCTAssertEqual(result, TriggerResult(.hide))
        XCTAssertFalse(result.swallow)
    }

    func testCompactArrowOnBareTriggerEngagesPicker() {
        var engine = makeEngine(horizontal: true)
        type("a :", into: &engine)
        XCTAssertEqual(engine.feed(.right), TriggerResult(.moveSelection(0), swallow: true))
        XCTAssertEqual(engine.feed(.right), TriggerResult(.moveSelection(1), swallow: true))
        XCTAssertEqual(engine.feed(.enter), TriggerResult(.commitSelection(deleteCount: 1), swallow: true))
    }

    func testLayoutCanChangeMidCapture() {
        var engine = makeEngine(horizontal: false)
        type(":joy", into: &engine)
        engine.horizontalLayout = true
        XCTAssertEqual(engine.feed(.right), TriggerResult(.moveSelection(1), swallow: true))
        XCTAssertEqual(engine.query, "joy")
    }

    // MARK: Strip engagement

    func testUpOnUnengagedStripPassesThrough() {
        var engine = makeEngine()
        type("a :", into: &engine)
        let result = engine.feed(.up)
        XCTAssertFalse(result.swallow)
        XCTAssertEqual(result.action, .hide)
        XCTAssertNil(engine.query)
    }

    func testListLeftRightOnStripPassThrough() {
        for key: KeyInput in [.left, .right] {
            var engine = makeEngine()
            type(":", into: &engine)
            let result = engine.feed(key)
            XCTAssertFalse(result.swallow, "\(key)")
            XCTAssertEqual(result.action, .hide, "\(key)")
        }
    }

    func testCompactStripEngagesOnlyWithRight() {
        for key: KeyInput in [.left, .up, .down] {
            var engine = makeEngine(horizontal: true)
            type(":", into: &engine)
            let result = engine.feed(key)
            XCTAssertFalse(result.swallow, "\(key)")
            XCTAssertEqual(result.action, .hide, "\(key)")
        }
        var engine = makeEngine(horizontal: true)
        type(":", into: &engine)
        XCTAssertEqual(engine.feed(.right), TriggerResult(.moveSelection(0), swallow: true))
        // Once engaged, every arrow moves.
        XCTAssertEqual(engine.feed(.left), TriggerResult(.moveSelection(-1), swallow: true))
        XCTAssertEqual(engine.feed(.down), TriggerResult(.moveSelection(1), swallow: true))
        XCTAssertEqual(engine.feed(.up), TriggerResult(.moveSelection(-1), swallow: true))
    }

    func testSpaceColonDownEnterInsertsFirstRecent() {
        var engine = makeEngine()
        type("a :", into: &engine)
        XCTAssertEqual(engine.feed(.down), TriggerResult(.moveSelection(0), swallow: true))
        XCTAssertEqual(engine.feed(.enter), TriggerResult(.commitSelection(deleteCount: 1), swallow: true))
    }

    func testQueryArrowsMoveImmediately() {
        var engine = makeEngine()
        type(":joy", into: &engine)
        XCTAssertEqual(engine.feed(.up), TriggerResult(.moveSelection(-1), swallow: true))
        XCTAssertEqual(engine.feed(.down), TriggerResult(.moveSelection(1), swallow: true))
    }

    // MARK: Emoticons

    func testEmoticonsKeepEnterNative() {
        for face in [":)", ":(", ":D", ":P", ":-)", ":-P", ":/", ":-D", ":-(", ":-/", ":+D"] {
            for key: KeyInput in [.enter, .tab] {
                var engine = makeEngine()
                type("hi \(face)", into: &engine)
                let result = engine.feed(key)
                XCTAssertFalse(result.swallow, "\(face) \(key)")
                if case .commitSelection = result.action { XCTFail("\(face) commits") }
            }
        }
    }

    func testEmoticonsKeepEnterNativeWithMinimumOne() {
        for face in [":)", ":(", ":-)", ":-P", ":/"] {
            var engine = makeEngine(minQueryLength: 1)
            type("hi \(face)", into: &engine)
            XCTAssertFalse(engine.feed(.enter).swallow, face)
        }
    }

    func testMinusOneStillWorks() {
        var engine = makeEngine()
        type("ok :-", into: &engine)
        XCTAssertEqual(type("1", into: &engine), TriggerResult(.show(query: "-1")))
        XCTAssertEqual(engine.feed(.enter), TriggerResult(.commitSelection(deleteCount: 3), swallow: true))

        engine = makeEngine()
        type(":-1", into: &engine)
        XCTAssertEqual(type(":", into: &engine), TriggerResult(.commitShortcode("-1", deleteCount: 3), swallow: true))

        engine = makeEngine()
        XCTAssertEqual(type(":+1", into: &engine), TriggerResult(.show(query: "+1")))
    }

    // MARK: Keep-open failure

    func testKeepOpenFailureRestoresCapture() {
        var engine = makeEngine()
        type(":joy", into: &engine)
        _ = engine.feed(.commandEnter)
        engine.keepOpenInsertFailed()
        XCTAssertFalse(engine.isMultiInserting)
        XCTAssertEqual(engine.typedLength, 4, ":joy is still in the app")
        XCTAssertEqual(engine.feed(.enter), TriggerResult(.commitSelection(deleteCount: 4), swallow: true))
    }

    func testKeepOpenFailureAfterSuccessfulInsertKeepsMultiInsert() {
        var engine = makeEngine()
        type(":joy", into: &engine)
        _ = engine.feed(.commandEnter)
        XCTAssertEqual(engine.feed(.commandEnter), TriggerResult(.commitSelectionKeepOpen(deleteCount: 0), swallow: true))
        engine.keepOpenInsertFailed()
        XCTAssertTrue(engine.isMultiInserting)
        XCTAssertEqual(engine.typedLength, 0)
    }
}

private extension TriggerEngine {
    /// Feeds a key with the picker visible exactly when the engine wants it shown (the UI kept up).
    mutating func feed(_ input: KeyInput) -> TriggerResult {
        handle(input, pickerVisible: isShowing)
    }
}

final class InputSupportTests: XCTestCase {
    // MARK: Chunking

    func testShortTextIsOneChunk() {
        XCTAssertEqual(UnicodeChunker.chunks("😂"), [Array("😂".utf16)])
    }

    func testChunksNeverExceedLimitOrSplitGraphemes() {
        let family = "👨‍👩‍👧‍👦" // 11 UTF-16 units
        let text = String(repeating: family, count: 5) + "🇺🇸a"
        let chunks = UnicodeChunker.chunks(text)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 20 })
        for chunk in chunks {
            let decoded = String(utf16CodeUnits: chunk, count: chunk.count)
            XCTAssertEqual(Array(decoded.utf16), chunk, "chunk must be valid UTF-16")
        }
        XCTAssertEqual(chunks.map { String(utf16CodeUnits: $0, count: $0.count) }.joined(), text)
        XCTAssertEqual(chunks.first.map { String(utf16CodeUnits: $0, count: $0.count) }, family)
    }

    func testChunkPacksMultipleGraphemes() {
        let chunks = UnicodeChunker.chunks(String(repeating: "😂", count: 15)) // 30 units
        XCTAssertEqual(chunks.map(\.count), [20, 10])
    }

    func testOversizedGraphemeSplitsOnScalarBoundaries() {
        let base = "e" + String(repeating: "\u{0301}", count: 25)
        let chunks = UnicodeChunker.chunks(base, maxUTF16Units: 20)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 20 })
        XCTAssertEqual(chunks.flatMap { $0 }, Array(base.utf16))
    }

    func testEmptyTextHasNoChunks() {
        XCTAssertTrue(UnicodeChunker.chunks("").isEmpty)
    }

    // MARK: Geometry

    func testAXToCocoaOnPrimaryScreen() {
        let rect = AXGeometry.cocoaRect(fromAX: CGRect(x: 100, y: 50, width: 2, height: 20), primaryScreenHeight: 1000)
        XCTAssertEqual(rect, CGRect(x: 100, y: 930, width: 2, height: 20))
    }

    func testAXToCocoaOnSecondaryScreens() {
        // Secondary display above the primary: AX y is negative, Cocoa y exceeds the primary height.
        XCTAssertEqual(AXGeometry.cocoaRect(fromAX: CGRect(x: 10, y: -500, width: 0, height: 20), primaryScreenHeight: 1000),
                       CGRect(x: 10, y: 1480, width: 0, height: 20))
        // Secondary display below/left: AX y beyond the primary height, Cocoa y negative.
        XCTAssertEqual(AXGeometry.cocoaRect(fromAX: CGRect(x: -1500, y: 1200, width: 0, height: 20), primaryScreenHeight: 1000),
                       CGRect(x: -1500, y: -220, width: 0, height: 20))
    }

    func testQuartzPointToCocoa() {
        XCTAssertEqual(AXGeometry.cocoaPoint(fromQuartz: CGPoint(x: 5, y: 100), primaryScreenHeight: 900), CGPoint(x: 5, y: 800))
    }

    func testPlausibility() {
        let screens = [CGRect(x: 0, y: 0, width: 1000, height: 800)]
        let field = CGRect(x: 100, y: 100, width: 300, height: 30)
        XCTAssertTrue(AXGeometry.isPlausible(CGRect(x: 120, y: 105, width: 0, height: 18), screens: screens, elementFrame: field))
        XCTAssertFalse(AXGeometry.isPlausible(CGRect(x: 120, y: 105, width: 0, height: 0), screens: screens, elementFrame: field))
        XCTAssertFalse(AXGeometry.isPlausible(CGRect(x: 5000, y: 105, width: 0, height: 18), screens: screens, elementFrame: nil))
        XCTAssertFalse(AXGeometry.isPlausible(CGRect(x: 600, y: 500, width: 0, height: 18), screens: screens, elementFrame: field))
        XCTAssertTrue(AXGeometry.isPlausible(CGRect(x: 600, y: 500, width: 0, height: 18), screens: screens, elementFrame: nil))
    }

    // MARK: Trigger location / context

    func testLocateTrigger() {
        let match = TriggerLocator.locate(trigger: ":", in: "see you at 12:30 :ha")
        XCTAssertEqual(match?.utf16Distance, 3)
        XCTAssertEqual(match.map { String($0.textBefore) }, "see you at 12:30 ")
    }

    func testLocateMultiCharTrigger() {
        let match = TriggerLocator.locate(trigger: "::", in: "ok ::joy")
        XCTAssertEqual(match?.utf16Distance, 5)
        XCTAssertEqual(match.map { String($0.textBefore) }, "ok ")
    }

    func testLocateBareTrigger() {
        XCTAssertEqual(TriggerLocator.locate(trigger: ":", in: "hi :")?.utf16Distance, 1)
    }

    func testLocateFailsWithoutActiveQuery() {
        XCTAssertNil(TriggerLocator.locate(trigger: ":", in: "no trigger here"))
        XCTAssertNil(TriggerLocator.locate(trigger: ":", in: ":joy and more"))
        XCTAssertNil(TriggerLocator.locate(trigger: ":", in: ""))
    }

    func testLocateCountsUTF16ForNonASCIIQuery() {
        XCTAssertEqual(TriggerLocator.locate(trigger: ":", in: "😂 :café")?.utf16Distance, 5)
    }

    func testContextIsBoundedAndNilWhenBlank() {
        let long = String(repeating: "x", count: 400)
        let match = TriggerLocator.locate(trigger: ":", in: long + " :jo")!
        let context = TriggerLocator.context(before: match, limit: 300)
        XCTAssertEqual(context?.count, 300)
        XCTAssertEqual(context?.last, " ")
        XCTAssertNil(TriggerLocator.context(before: TriggerLocator.locate(trigger: ":", in: "  :jo")!))
    }
}
