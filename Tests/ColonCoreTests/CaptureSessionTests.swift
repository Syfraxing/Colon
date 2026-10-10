import CoreGraphics
import XCTest
@testable import ColonCore

/// Drives `TriggerEngine` + `CaptureSession` the way `InputController` does after every key.
final class CaptureSessionTests: XCTestCase {
    private var engine = TriggerEngine(trigger: ":", minQueryLength: 2, autoReplaceOnClosingTrigger: true,
                                       showsRecentsOnTrigger: false, shortcodeExists: { $0 == "smile" })
    private var session = CaptureSession()
    /// Number of focus probes started.
    private var probes = 0
    private var lastProbeID: Int?

    private let oldAnchor = CGRect(x: 100, y: 100, width: 1, height: 18)
    private let newAnchor = CGRect(x: 400, y: 300, width: 1, height: 18)

    @discardableResult
    private func key(_ input: KeyInput) -> TriggerResult {
        let result = engine.handle(input, pickerVisible: engine.isShowing)
        if !session.follows(engine) { session.restart(for: engine) }
        if session.needsProbe {
            probes += 1
            lastProbeID = session.startProbe()
        }
        return result
    }

    private func type(_ text: String) {
        for character in text { key(.text(String(character))) }
    }

    private func finishProbe(anchor: CGRect, appName: String) {
        guard let id = lastProbeID else { return XCTFail("no probe started") }
        XCTAssertTrue(session.probeSucceeded(captureID: id, anchor: anchor,
                                             context: PredictionContext(appName: appName)))
    }

    func testTriggerStartsOneProbe() {
        type("hi :sm")
        XCTAssertEqual(probes, 1)
        XCTAssertNotNil(session.engineCapture)
        XCTAssertTrue(session.probeInFlight)
        finishProbe(anchor: oldAnchor, appName: "Notes")
        type("ile")
        XCTAssertEqual(probes, 1, "keys of the same capture never re-probe")
        XCTAssertEqual(session.anchor, oldAnchor)
    }

    func testSilentEndThenNewTriggerReprobesAndReanchors() {
        type(":D")
        finishProbe(anchor: oldAnchor, appName: "Old")
        XCTAssertTrue(session.focusUsable)
        // Below the minimum, so the engine ends tracking with `.none`, not `.hide`.
        XCTAssertEqual(key(.text(" ")).action, .none)
        XCTAssertFalse(engine.isTracking)
        XCTAssertNil(session.engineCapture)
        XCTAssertFalse(session.focusUsable)
        XCTAssertNil(session.anchor)
        XCTAssertEqual(session.context, PredictionContext())

        type(":smile")
        XCTAssertEqual(probes, 2, "the new capture probes again")
        XCTAssertFalse(session.focusUsable, "nothing shows before the new probe returns")
        XCTAssertNil(session.anchor)
        finishProbe(anchor: newAnchor, appName: "New")
        XCTAssertEqual(session.anchor, newAnchor)
        XCTAssertEqual(session.context.appName, "New")
    }

    func testEmoticonEndsCapture() {
        type(":-")
        finishProbe(anchor: oldAnchor, appName: "Old")
        type(")")
        XCTAssertFalse(engine.isTracking)
        XCTAssertNil(session.anchor)
        type(" :sm")
        XCTAssertEqual(probes, 2)
    }

    func testLateProbeFromOldCaptureIsIgnored() {
        type(":D")
        let oldID = lastProbeID
        key(.text(" "))
        type(":smile")
        XCTAssertNotEqual(lastProbeID, oldID)
        XCTAssertFalse(session.probeSucceeded(captureID: oldID!, anchor: oldAnchor,
                                              context: PredictionContext(appName: "Old")))
        XCTAssertFalse(session.focusUsable)
        XCTAssertNil(session.anchor)
        XCTAssertTrue(session.probeInFlight, "the current probe is still running")
        // An old probe giving up does not cancel the current one either.
        session.probeEnded(captureID: oldID!)
        XCTAssertTrue(session.probeInFlight)
        finishProbe(anchor: newAnchor, appName: "New")
        XCTAssertEqual(session.anchor, newAnchor)
    }

    func testProbeResultAfterCaptureEndedIsIgnored() {
        type(":sm")
        let id = lastProbeID!
        key(.escape)
        XCTAssertFalse(session.probeSucceeded(captureID: id, anchor: oldAnchor, context: PredictionContext()))
        XCTAssertNil(session.anchor)
        XCTAssertFalse(session.needsProbe)
    }

    func testBackspaceOverTriggerThenRetypeIsANewCapture() {
        type(":s")
        finishProbe(anchor: oldAnchor, appName: "Old")
        key(.backspace)
        key(.backspace)
        XCTAssertFalse(engine.isTracking)
        XCTAssertNil(session.anchor)
        type(":s")
        XCTAssertEqual(probes, 2)
    }

    func testTriggerRightAfterMultiInsertIsANewCapture() {
        type(":smile")
        finishProbe(anchor: oldAnchor, appName: "Old")
        XCTAssertEqual(key(.commandEnter).action, .commitSelectionKeepOpen(deleteCount: 6))
        XCTAssertTrue(session.follows(engine), "multi-insert keeps the capture")
        XCTAssertEqual(session.anchor, oldAnchor)
        // Typing a trigger closes multi-insert and opens a new capture in the same key.
        key(.text(":"))
        XCTAssertTrue(engine.isTracking)
        XCTAssertNil(session.anchor)
        XCTAssertEqual(probes, 2)
    }

    func testRestartChangesID() {
        let before = session.id
        session.restart(for: engine)
        XCTAssertNotEqual(session.id, before)
        XCTAssertFalse(session.isCurrent(before))
    }
}
