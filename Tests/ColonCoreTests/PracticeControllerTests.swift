import XCTest
@testable import ColonCore

/// The onboarding "Try it" field (`PracticeController`), typed key by key like `PracticeNSTextView` does.
@MainActor
final class PracticeControllerTests: XCTestCase {
    private var usageURL: URL!
    private var settings: AppSettings!
    private var controller: PracticeController!
    /// What the text view was asked to do: (deleteCount, text).
    private var replacements: [(Int, String)] = []

    override func setUp() async throws {
        usageURL = FileManager.default.temporaryDirectory.appendingPathComponent("usage-\(UUID().uuidString).json")
        settings = AppSettings(defaults: UserDefaults(suiteName: "ColonTests-\(UUID().uuidString)")!,
                               preferredLanguages: ["en-US"])
        settings.useJev = false
        let engine = SuggestionEngine(settings: settings, store: .shared,
                                      usage: UsageStore(fileURL: usageURL, halfLife: 86_400, writeDelay: 60),
                                      jev: FakeJev())
        controller = PracticeController(settings: settings, engine: engine)
        replacements = []
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: usageURL)
    }

    /// Feeds `text` one character at a time; returns whether the last key was swallowed.
    @discardableResult
    private func type(_ text: String) -> Bool {
        var swallowed = false
        for character in text {
            swallowed = press(.text(String(character)))
        }
        return swallowed
    }

    @discardableResult
    private func press(_ input: KeyInput) -> Bool {
        controller.handle(input) { replacements.append(($0, $1)) }
    }

    /// Defaults (recents strip on, two-letter minimum): the strip that opens on `:` closes on the first
    /// letter, and that must not end the capture. It did, so `:haha` and `:ema` never showed anything.
    func testQueryContinuesAfterTheRecentsStripCloses() {
        XCTAssertTrue(settings.showRecentsOnTrigger)
        XCTAssertEqual(settings.minQueryLength, 2)

        type(":")
        XCTAssertTrue(controller.isShowing, "bare trigger shows the recents strip")
        type("h")
        XCTAssertFalse(controller.isShowing, "one letter is below the minimum")
        type("aha")
        XCTAssertTrue(controller.isShowing)
        XCTAssertEqual(controller.engine.query, "haha")
        XCTAssertEqual(controller.visibleSuggestions.first?.id, "joy")

        controller.interrupt()
        type(" :ema")
        XCTAssertTrue(controller.isShowing)
        XCTAssertEqual(controller.engine.query, "ema")
        XCTAssertFalse(controller.visibleSuggestions.isEmpty)
    }

    func testEnterInsertsTheSelectionInPlaceOfTheQuery() {
        type(":haha")
        XCTAssertTrue(press(.enter), "Enter belongs to the list")
        XCTAssertEqual(replacements.map(\.0), [5])
        XCTAssertEqual(replacements.map(\.1), ["😂"])
        XCTAssertEqual(controller.lastInserted, "😂")
        XCTAssertFalse(controller.isShowing)
        XCTAssertFalse(press(.enter), "after the insert Enter is the field's again")
    }

    func testClosingTriggerReplacesTheShortcode() {
        XCTAssertTrue(type(":joy:"), "the closing trigger is swallowed")
        XCTAssertEqual(replacements.map(\.0), [4])
        XCTAssertEqual(replacements.map(\.1), ["😂"])
        XCTAssertFalse(controller.isShowing)
    }

    func testClickEndsTheCapture() {
        type(":ha")
        XCTAssertTrue(controller.isShowing)
        controller.interrupt()
        XCTAssertFalse(controller.isShowing)
        type("ha")
        XCTAssertFalse(controller.isShowing)
        XCTAssertFalse(press(.enter))
        XCTAssertTrue(replacements.isEmpty)
    }
}
