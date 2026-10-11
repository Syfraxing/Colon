import XCTest
@testable import ColonCore

/// Drives `PickerHighlight` the way `PickerModel` does: a sync per engine snapshot, and
/// `beginCapture` whenever the panel shows a new capture.
final class PickerHighlightTests: XCTestCase {
    private var highlight = PickerHighlight()
    private var query: String?

    /// One engine snapshot; returns whether the highlight state was reset.
    @discardableResult
    private func sync(_ newQuery: String) -> Bool {
        defer { query = newQuery }
        return highlight.sync(queryChanged: newQuery != query)
    }

    /// The panel shows a capture whose first snapshot is `query`.
    private func show(_ newQuery: String) {
        highlight.beginCapture()
        sync(newQuery)
    }

    private func assertFresh(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(highlight.isEngaged, "engaged", file: file, line: line)
        XCTAssertFalse(highlight.pointerHighlight, "pointer pill", file: file, line: line)
        XCTAssertFalse(highlight.userMovedHighlight, "order frozen", file: file, line: line)
    }

    func testEngagedStripDoesNotLeakIntoNextCapture() {
        show("")
        highlight.moveByKeyboard() // ↓ engages the strip
        XCTAssertTrue(highlight.isEngaged)
        sync("") // ↩ / Esc: hidden, engine reset; the query stays ""
        show("") // the trigger again
        assertFresh()
    }

    func testPointerPillDoesNotLeakIntoNextCapture() {
        show("")
        highlight.point(onUnengagedStrip: true)
        XCTAssertTrue(highlight.pointerHighlight)
        show("")
        assertFresh()
    }

    func testSameQueryInOneCaptureKeepsTheMovedHighlight() {
        show("joy")
        highlight.moveByKeyboard()
        XCTAssertFalse(sync("joy"), "a late Jev answer must not reset the user's highlight")
        XCTAssertTrue(highlight.userMovedHighlight)
        XCTAssertTrue(sync("joyf"))
        assertFresh()
    }
}
