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
