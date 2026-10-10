import XCTest
@testable import EmojifyCore

/// Scriptable `JevRanking`: answers per query after an optional delay, records every call.
final class FakeJev: JevRanking, @unchecked Sendable {
    struct Call {
        let query: String
        let context: PredictionContext
        let candidates: [String]
    }

    private let lock = NSLock()
    private var answers: [String: [String: Double]] = [:]
    private var delays: [String: Duration] = [:]
    private var failure: Error?
    private var recorded: [Call] = []

    var calls: [Call] { lock.withLock { recorded } }

    func answer(_ query: String, _ probabilities: [String: Double], after delay: Duration = .zero) {
        lock.withLock {
            answers[query] = probabilities
            delays[query] = delay
        }
    }

    func fail(with error: Error) {
        lock.withLock { failure = error }
    }

    func rank(query: String, context: PredictionContext, candidates: [Emoji]) async throws -> [String: Double] {
        let (answer, delay, failure) = lock.withLock {
            recorded.append(Call(query: query, context: context, candidates: candidates.map(\.id)))
            return (answers[query], delays[query] ?? .zero, self.failure)
        }
        try await Task.sleep(for: delay)
        if let failure { throw failure }
        return answer ?? [:]
    }
}

@MainActor
final class SuggestionEngineTests: XCTestCase {
    private var usageURL: URL!
    private var settings: AppSettings!
    private var jev: FakeJev!

    override func setUp() async throws {
        usageURL = FileManager.default.temporaryDirectory.appendingPathComponent("usage-\(UUID().uuidString).json")
        settings = AppSettings(defaults: UserDefaults(suiteName: "EmojifyTests-\(UUID().uuidString)")!)
        settings.maxResults = 8
        settings.useJev = true
        settings.sendTextContext = true
        jev = FakeJev()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: usageURL)
    }

    private func makeEngine(jev: JevRanking? = nil) -> SuggestionEngine {
        let engine = SuggestionEngine(settings: settings, store: .shared,
                                      usage: UsageStore(fileURL: usageURL, halfLife: 86_400, writeDelay: 60),
                                      jev: jev ?? self.jev)
        engine.debounce = .milliseconds(5)
        return engine
    }

    /// Polls the main actor until `condition` holds.
    private func waitUntil(timeout: Duration = .seconds(2), _ condition: () -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline {
                XCTFail("timed out", file: file, line: line)
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func ids(_ engine: SuggestionEngine) -> [String] { engine.suggestions.map(\.id) }

    func testLocalResultsArePublishedSynchronously() {
        let engine = makeEngine()
        engine.update(query: "fire", context: PredictionContext())
        XCTAssertEqual(engine.query, "fire")
        XCTAssertEqual(engine.suggestions.first?.emoji.char, "🔥")
        XCTAssertLessThanOrEqual(engine.suggestions.count, 8)
        XCTAssertTrue(engine.isRefining)
    }

    func testJevRerankBlendsOrder() async {
        jev.answer("haha", ["rofl": 0.7, "joy": 0.2, "laughing": 0.05])
        let engine = makeEngine()
        engine.update(query: "haha", context: PredictionContext(appName: "Messages"))
        let local = ids(engine)
        XCTAssertEqual(local.first, "joy")
        await waitUntil { !engine.isRefining }
        XCTAssertEqual(ids(engine).first, "rofl")
        XCTAssertEqual(engine.suggestions.first?.jevProbability, 0.7)
        if case .ok = engine.jevStatus {} else { XCTFail("status \(engine.jevStatus)") }
        XCTAssertEqual(engine.suggestions.map(\.score), engine.suggestions.map(\.score).sorted(by: >))
    }

    func testCandidatePoolIncludesLocalAndPopular() async {
        let engine = makeEngine()
        engine.update(query: "sus", context: PredictionContext())
        await waitUntil { !engine.isRefining }
        let candidates = jev.calls.last?.candidates ?? []
        XCTAssertTrue(candidates.contains("eyes"))
        XCTAssertTrue(candidates.contains("joy"), "popular pool is always offered")
        XCTAssertTrue(candidates.contains("goat"))
        XCTAssertLessThanOrEqual(candidates.count, JevClient.maxOptions)
        XCTAssertEqual(Set(candidates).count, candidates.count)
    }

    func testJevOnlyResultsAppearWhenLocalHasNothing() async {
        jev.answer("zqxv", ["skull": 0.6, "joy": 0.3, "fire": 0.005])
        let engine = makeEngine()
        engine.update(query: "zqxv", context: PredictionContext())
        XCTAssertEqual(engine.suggestions, [])
        await waitUntil { !engine.isRefining }
        XCTAssertEqual(ids(engine), ["skull", "joy"])
    }

    /// Measured live: gibberish spreads Jev's mass (`zzqx` top ≈ 0.21), so with no local match
    /// nothing is shown and Enter stays native.
    func testLowConfidenceJevOnlyResultsAreSuppressed() async {
        jev.answer("zqxv", ["sleeping": 0.21, "zany_face": 0.06, "x": 0.04])
        let engine = makeEngine()
        engine.update(query: "zqxv", context: PredictionContext())
        await waitUntil { !engine.isRefining }
        XCTAssertEqual(engine.suggestions, [])
    }

    func testExactShortcodeStaysPinnedWhenJevAgrees() async {
        jev.answer("fire", ["heart_on_fire": 0.6, "fire": 0.3])
        let engine = makeEngine()
        engine.update(query: "fire", context: PredictionContext())
        await waitUntil { !engine.isRefining }
        XCTAssertEqual(ids(engine).first, "fire")
    }

    func testExactShortcodeYieldsWhenJevDisagrees() async {
        jev.answer("cool", ["sunglasses": 0.8, "cool": 0.01])
        let engine = makeEngine()
        engine.update(query: "cool", context: PredictionContext())
        XCTAssertEqual(ids(engine).first, "cool")
        await waitUntil { !engine.isRefining }
        XCTAssertEqual(ids(engine).first, "sunglasses")
    }

    func testStaleResponsesAreIgnored() async {
        jev.answer("hah", ["skull": 0.9], after: .milliseconds(150))
        jev.answer("haha", ["rofl": 0.9])
        let engine = makeEngine()
        engine.update(query: "hah", context: PredictionContext())
        try? await Task.sleep(for: .milliseconds(30)) // the "hah" request is in flight
        engine.update(query: "haha", context: PredictionContext())
        await waitUntil { !engine.isRefining }
        XCTAssertEqual(ids(engine).first, "rofl")
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(ids(engine).first, "rofl", "late answer for an old query must not apply")
        XCTAssertFalse(ids(engine).contains("skull"))
    }

    func testDebounceSendsOneRequestForFastTyping() async {
        let engine = makeEngine()
        engine.debounce = .milliseconds(40)
        for query in ["h", "ha", "hah", "haha"] { engine.update(query: query, context: PredictionContext()) }
        await waitUntil { !engine.isRefining }
        XCTAssertEqual(jev.calls.map(\.query), ["haha"])
    }

    func testResetCancels() async {
        jev.answer("haha", ["rofl": 0.9], after: .milliseconds(50))
        let engine = makeEngine()
        engine.update(query: "haha", context: PredictionContext())
        engine.reset()
        XCTAssertEqual(engine.query, "")
        XCTAssertEqual(engine.suggestions, [])
        XCTAssertFalse(engine.isRefining)
        try? await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(engine.suggestions, [])
    }

    func testErrorKeepsLocalResults() async {
        jev.fail(with: JevError.overloaded)
        let engine = makeEngine()
        engine.update(query: "joy", context: PredictionContext())
        let local = ids(engine)
        await waitUntil { !engine.isRefining }
        XCTAssertEqual(ids(engine), local)
        XCTAssertEqual(engine.jevStatus, .error("Jev is overloaded"))
    }

    func testCacheAvoidsRepeatRequests() async {
        jev.answer("haha", ["rofl": 0.9])
        let engine = makeEngine()
        let context = PredictionContext(appName: "Notes", bundleID: "com.apple.Notes")
        engine.update(query: "haha", context: context)
        await waitUntil { !engine.isRefining }
        engine.reset()
        engine.update(query: "haha", context: context)
        XCTAssertFalse(engine.isRefining)
        XCTAssertEqual(ids(engine).first, "rofl", "cached answer applies immediately")
        XCTAssertEqual(jev.calls.count, 1)

        engine.update(query: "haha", context: PredictionContext(appName: "Mail", bundleID: "com.apple.mail"))
        await waitUntil { !engine.isRefining }
        XCTAssertEqual(jev.calls.count, 2, "another app is another cache entry")
    }

    func testSameQueryNewContextOnlyReschedulesJev() async {
        jev.answer("haha", ["rofl": 0.9], after: .milliseconds(30))
        let engine = makeEngine()
        engine.update(query: "haha", context: PredictionContext())
        let first = engine.suggestions
        engine.freezeOrder()
        engine.update(query: "haha", context: PredictionContext(appName: "Messages", textBeforeTrigger: "so funny"))
        XCTAssertEqual(engine.suggestions, first)
        await waitUntil { !engine.isRefining }
        XCTAssertEqual(jev.calls.last?.context.textBeforeTrigger, "so funny")
        XCTAssertEqual(ids(engine), first.map(\.id), "order stays frozen for the same query")
        XCTAssertEqual(engine.suggestions.first { $0.id == "rofl" }?.jevProbability, 0.9)
    }

    func testFrozenOrderIsNotReorderedByLateAnswer() async {
        jev.answer("haha", ["rofl": 0.9], after: .milliseconds(20))
        let engine = makeEngine()
        engine.update(query: "haha", context: PredictionContext())
        let local = ids(engine)
        engine.freezeOrder()
        await waitUntil { !engine.isRefining }
        XCTAssertEqual(ids(engine), local)
        engine.update(query: "hahah", context: PredictionContext())
        XCTAssertNotEqual(engine.suggestions.count, 0)
    }

    func testShortQueriesSkipJev() async {
        let engine = makeEngine()
        engine.update(query: "j", context: PredictionContext())
        XCTAssertFalse(engine.isRefining)
        XCTAssertFalse(engine.suggestions.isEmpty)
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(jev.calls.isEmpty)
    }

    func testDisabledJevIsLocalOnly() async {
        settings.useJev = false
        let engine = makeEngine()
        engine.update(query: "haha", context: PredictionContext())
        XCTAssertEqual(engine.jevStatus, .disabled)
        XCTAssertFalse(engine.isRefining)
        XCTAssertFalse(engine.suggestions.isEmpty)
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(jev.calls.isEmpty)
    }

    func testTextContextOnlySentWhenOptedIn() async {
        settings.sendTextContext = false
        let engine = makeEngine()
        engine.update(query: "haha", context: PredictionContext(appName: "Messages", textBeforeTrigger: "private"))
        await waitUntil { !engine.isRefining }
        XCTAssertNil(jev.calls.last?.context.textBeforeTrigger)
        XCTAssertEqual(jev.calls.last?.context.appName, "Messages")
    }

    func testRecordUseFeedsFrecency() {
        let engine = makeEngine()
        settings.useJev = false
        engine.update(query: "haha", context: PredictionContext())
        let laughing = EmojiStore.shared.emoji(id: "laughing")!
        XCTAssertNotEqual(ids(engine).first, "laughing")
        for _ in 0..<3 { engine.recordUse(laughing) }
        engine.reset()
        engine.update(query: "haha", context: PredictionContext())
        XCTAssertEqual(ids(engine).first, "laughing")
    }

    func testOutputAppliesSkinTone() {
        let engine = makeEngine()
        let store = EmojiStore.shared
        settings.skinTone = .mediumDark
        XCTAssertEqual(engine.output(for: store.emoji(id: "wave")!), "👋🏾")
        XCTAssertEqual(engine.output(for: store.emoji(id: "point_up")!), "☝🏾")
        XCTAssertEqual(engine.output(for: store.emoji(id: "technologist")!), "🧑🏾‍💻")
        XCTAssertEqual(engine.output(for: store.emoji(id: "joy")!), "😂")
        settings.skinTone = .none
        XCTAssertEqual(engine.output(for: store.emoji(id: "wave")!), "👋")
    }

    func testEmptyQueryClears() {
        let engine = makeEngine()
        engine.update(query: "fire", context: PredictionContext())
        engine.update(query: "", context: PredictionContext())
        XCTAssertEqual(engine.suggestions, [])
        XCTAssertFalse(engine.isRefining)
    }

    func testLRUCacheEvictsOldest() {
        var cache = LRUCache<String, Int>(capacity: 2)
        cache["a"] = 1
        cache["b"] = 2
        _ = cache["a"]
        cache["c"] = 3
        XCTAssertEqual(cache["a"], 1)
        XCTAssertNil(cache["b"])
        XCTAssertEqual(cache["c"], 3)
        XCTAssertEqual(cache.count, 2)
    }
}
