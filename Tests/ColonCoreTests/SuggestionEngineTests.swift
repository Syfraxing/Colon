import XCTest
@testable import ColonCore

/// Scriptable `JevRanking`: answers per query after an optional delay, records every call.
final class FakeJev: JevRanking, @unchecked Sendable {
    struct Call {
        let query: String
        let context: PredictionContext
        let candidates: [String]
        /// Option text Jev would get per candidate id (`JevClient.criterion`).
        let criteria: [String: String]
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
            recorded.append(Call(query: query, context: context, candidates: candidates.map(\.id),
                                 criteria: Dictionary(candidates.map { ($0.id, JevClient.criterion(for: $0)) },
                                                      uniquingKeysWith: { first, _ in first })))
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
        // English-only regardless of the machine's languages; language tests opt in.
        settings = AppSettings(defaults: UserDefaults(suiteName: "ColonTests-\(UUID().uuidString)")!,
                               preferredLanguages: ["en-US"])
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
        XCTAssertEqual(engine.suggestions.first?.emoji?.char, "🔥")
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

    // MARK: Recents strip (empty query)

    private var popularIDs: [String] {
        PopularEmoji.ids.filter { EmojiStore.shared.emoji(id: $0) != nil }
    }

    func testEmptyQueryWithoutHistoryShowsPopular() async {
        let engine = makeEngine()
        engine.update(query: "", context: PredictionContext(appName: "Notes"))
        XCTAssertEqual(engine.suggestions.map(\.id), Array(popularIDs.prefix(SuggestionEngine.recentsLimit)))
        XCTAssertFalse(engine.isRefining)
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(jev.calls.isEmpty, "recents never ask Jev")
    }

    func testEmptyQueryPrefersMostUsedThenTopsUpWithPopular() {
        let engine = makeEngine()
        let store = EmojiStore.shared
        let rocket = store.emoji(id: "rocket")!
        let fire = store.emoji(id: "fire")!
        for _ in 0..<3 { engine.recordUse(rocket) }
        engine.recordUse(fire)
        engine.update(query: "", context: PredictionContext())
        let ids = engine.suggestions.map(\.id)
        XCTAssertEqual(ids.count, SuggestionEngine.recentsLimit)
        XCTAssertEqual(Array(ids.prefix(2)), ["rocket", "fire"])
        XCTAssertEqual(Set(ids).count, ids.count, "no duplicates")
        XCTAssertEqual(Array(ids.dropFirst(2)), Array(popularIDs.filter { $0 != "rocket" && $0 != "fire" }.prefix(6)))
        // Scores descend in display order.
        let scores = engine.suggestions.map(\.score)
        XCTAssertEqual(scores, scores.sorted(by: >))
    }

    func testRecentsShowAtMostEightMostUsed() {
        let engine = makeEngine()
        let ids = Array(popularIDs.suffix(12))
        for (index, id) in ids.enumerated() {
            for _ in 0...index { engine.recordUse(EmojiStore.shared.emoji(id: id)!) }
        }
        engine.update(query: "", context: PredictionContext())
        XCTAssertEqual(engine.suggestions.map(\.id), Array(ids.reversed().prefix(8)))
    }

    func testRecentsRespectMaxResults() {
        settings.maxResults = 5
        let engine = makeEngine()
        engine.update(query: "", context: PredictionContext())
        XCTAssertEqual(engine.suggestions.count, 5)
    }

    func testEmptyQueryAfterQueryShowsRecentsAndCancelsJev() async {
        jev.answer("fire", ["fire": 0.9], after: .milliseconds(80))
        let engine = makeEngine()
        engine.update(query: "fire", context: PredictionContext())
        engine.update(query: "", context: PredictionContext())
        XCTAssertEqual(engine.query, "")
        XCTAssertFalse(engine.isRefining)
        let recents = engine.suggestions
        XCTAssertEqual(recents.map(\.id), Array(popularIDs.prefix(SuggestionEngine.recentsLimit)))
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(engine.suggestions, recents, "a stale answer must not replace the strip")
    }

    func testRecentsKeepOrderWhenFrozenAndContextArrives() {
        let engine = makeEngine()
        engine.update(query: "", context: PredictionContext())
        let before = engine.suggestions
        engine.freezeOrder()
        engine.recordUse(EmojiStore.shared.emoji(id: before.last!.id)!)
        engine.update(query: "", context: PredictionContext(appName: "Notes", bundleID: "com.apple.Notes"))
        XCTAssertEqual(engine.suggestions, before)
    }

    func testRecentsRebuiltAfterReset() {
        let engine = makeEngine()
        engine.update(query: "", context: PredictionContext())
        engine.freezeOrder()
        engine.reset()
        XCTAssertEqual(engine.suggestions, [])
        engine.recordUse(EmojiStore.shared.emoji(id: "rocket")!)
        engine.update(query: "", context: PredictionContext())
        XCTAssertEqual(engine.suggestions.first?.id, "rocket")
    }

    func testRecentsOnlyForRawEmptyQuery() async {
        let engine = makeEngine()
        for query in ["::", " ", ":", "  "] {
            engine.update(query: query, context: PredictionContext())
            XCTAssertEqual(engine.suggestions, [], query.debugDescription)
        }
        engine.update(query: "", context: PredictionContext())
        XCTAssertEqual(engine.suggestions.count, SuggestionEngine.recentsLimit)
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(jev.calls.isEmpty)
    }

    func testTypingAfterRecentsSearchesNormally() {
        let engine = makeEngine()
        engine.update(query: "", context: PredictionContext())
        engine.update(query: "fire", context: PredictionContext())
        XCTAssertEqual(engine.suggestions.first?.id, "fire")
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

    // MARK: - Search languages

    func testLocalizedQueryKeepsLocalResultsWhenJevDisagrees() async {
        settings.searchLanguages = ["ro"]
        let engine = makeEngine()
        await engine.reloadLanguages(["ro"]).value
        jev.answer("inima", ["joy": 0.9, "heart": 0.01])
        engine.update(query: "inima", context: PredictionContext())
        XCTAssertEqual(engine.suggestions.first?.emoji?.char, "❤️")
        await waitUntil { !engine.isRefining }
        XCTAssertTrue(ids(engine).contains("heart"), "local localized match survives the blend: \(ids(engine))")
        XCTAssertEqual(jev.calls.last?.query, "inima", "Jev gets the query as typed")
    }

    func testJevCandidatesCarryLocalizedNames() async throws {
        settings.searchLanguages = ["ro"]
        let engine = makeEngine()
        await engine.reloadLanguages(["ro"]).value
        engine.update(query: "caine", context: PredictionContext())
        await waitUntil { !engine.isRefining }
        let call = try XCTUnwrap(jev.calls.last)
        XCTAssertEqual(call.candidates.first, "dog")
        XCTAssertTrue(call.criteria["dog"]?.hasPrefix("🐶 dog face; fata de caine, ") == true, "\(call.criteria["dog"] ?? "")")
        // Popular candidates that matched nothing locally keep the plain English text.
        XCTAssertEqual(call.criteria["joy"], JevClient.criterion(for: EmojiStore.shared.emoji(id: "joy")!))
    }

    func testChangingSearchLanguagesReloadsSearch() async {
        let engine = makeEngine()
        await engine.reloadLanguages(settings.searchLanguages).value
        engine.update(query: "corazon", context: PredictionContext())
        XCTAssertFalse(ids(engine).contains("heart"))
        engine.reset()

        settings.searchLanguages = ["es"]
        await waitUntil {
            engine.reset()
            engine.update(query: "corazon", context: PredictionContext())
            return engine.suggestions.first?.id == "heart"
        }
        XCTAssertEqual(ids(engine).first, "heart")
    }
}
