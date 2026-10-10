import XCTest
@testable import ColonCore

final class SnippetTriggerTests: XCTestCase {
    private let email = Snippet(trigger: "Email", text: "me@example.com")

    func testValidTriggers() {
        for trigger in ["sig", "email", "addr2", "my_name", "+1x", "a-b", "café", String(repeating: "a", count: 32)] {
            XCTAssertNil(Snippet.problem(with: trigger, among: []), trigger)
        }
    }

    func testInvalidTriggers() {
        XCTAssertEqual(Snippet.problem(with: "", among: []), .empty)
        XCTAssertEqual(Snippet.problem(with: "my sig", among: []), .containsWhitespace)
        XCTAssertEqual(Snippet.problem(with: "sig\n", among: []), .containsWhitespace)
        XCTAssertEqual(Snippet.problem(with: "\tsig", among: []), .containsWhitespace)
        // The input layer ends a query on these, so such a trigger could never be typed.
        XCTAssertEqual(Snippet.problem(with: ":sig", among: []), .invalidCharacter(":"))
        XCTAssertEqual(Snippet.problem(with: "e.mail", among: []), .invalidCharacter("."))
        XCTAssertEqual(Snippet.problem(with: String(repeating: "a", count: 33), among: []), .tooLong)
    }

    func testTriggersAreUniqueIgnoringCaseAndAccents() {
        XCTAssertEqual(Snippet.problem(with: "email", among: [email]), .duplicate)
        XCTAssertEqual(Snippet.problem(with: "EMAIL", among: [email]), .duplicate)
        XCTAssertEqual(Snippet.problem(with: "cafe", among: [Snippet(trigger: "Café", text: "x")]), .duplicate)
        // Editing a snippet does not collide with itself.
        XCTAssertNil(Snippet.problem(with: "email", among: [email], excluding: email.id))
        XCTAssertNil(Snippet.problem(with: "emails", among: [email]))
    }
}

final class SnippetSearchTests: XCTestCase {
    private func snippet(_ trigger: String, _ text: String = "text") -> Snippet {
        Snippet(trigger: trigger, text: text)
    }

    private func triggers(_ query: String, _ snippets: [Snippet]) -> [String] {
        SnippetSearch.search(query, in: snippets).map(\.snippet.trigger)
    }

    func testMatchKinds() {
        XCTAssertEqual(SnippetSearch.match(query: "email", trigger: "Email"), .exact)
        XCTAssertEqual(SnippetSearch.match(query: "ema", trigger: "EMAIL"), .prefix)
        XCTAssertEqual(SnippetSearch.match(query: "ail", trigger: "email"), .contains)
        // Single characters only match as a prefix.
        XCTAssertNil(SnippetSearch.match(query: "m", trigger: "email"))
        XCTAssertNil(SnippetSearch.match(query: "phone", trigger: "email"))
        XCTAssertNil(SnippetSearch.match(query: "", trigger: "email"))
    }

    func testQueryIsNormalisedLikeEmojiSearch() {
        let snippets = [snippet("email")]
        XCTAssertEqual(triggers("EMA", snippets), ["email"])
        XCTAssertEqual(triggers(":ema", snippets), ["email"])
        XCTAssertEqual(triggers("email:", snippets), ["email"])
    }

    /// Folded like emoji search (`TextFolding`): accents never matter, either way round.
    func testMatchingIgnoresAccents() {
        XCTAssertEqual(triggers("cafe", [snippet("café")]), ["café"])
        XCTAssertEqual(triggers("CAFÉ", [snippet("cafe")]), ["cafe"])
        XCTAssertEqual(triggers("semn", [snippet("semnătură")]), ["semnătură"])
    }

    func testOrderingExactThenPrefixThenContains() {
        let snippets = [snippet("signature"), snippet("mysig"), snippet("sig"), snippet("sign")]
        XCTAssertEqual(triggers("sig", snippets), ["sig", "sign", "signature", "mysig"])
    }

    func testTiesKeepTheUsersOrder() {
        let snippets = [snippet("addr2"), snippet("addr1")]
        XCTAssertEqual(triggers("add", snippets), ["addr2", "addr1"])
    }

    func testEmptyTextAndUnusableTriggersNeverMatch() {
        let snippets = [snippet("email", ""), snippet("e mail"), snippet("email2")]
        XCTAssertEqual(triggers("email", snippets), ["email2"])
    }

    func testMergePutsPrefixMatchesAboveEmojiAndContainsBelow() throws {
        let store = EmojiStore.shared
        let emoji = ["e-mail", "email", "envelope"].compactMap { store.emoji(id: $0) }
            .map { Suggestion(emoji: $0, score: 500) }
        XCTAssertFalse(emoji.isEmpty)
        let hits = SnippetSearch.search("ema", in: [snippet("work_email"), snippet("email")])
        let merged = SnippetSearch.merge(hits, into: emoji, limit: 8)
        XCTAssertEqual(merged.first?.snippet?.trigger, "email")
        XCTAssertEqual(merged.last?.snippet?.trigger, "work_email")
        XCTAssertEqual(merged.dropFirst().dropLast().map(\.id), emoji.map(\.id))
        XCTAssertTrue(merged.allSatisfy { $0.jevProbability == nil })
    }

    func testMergeKeepsEverySnippetWithinTheLimit() {
        let emoji = (EmojiStore.shared.all.prefix(8)).map { Suggestion(emoji: $0, score: 1) }
        let hits = SnippetSearch.search("ad", in: [snippet("addr"), snippet("bad_idea")])
        let merged = SnippetSearch.merge(hits, into: emoji, limit: 4)
        XCTAssertEqual(merged.count, 4)
        XCTAssertEqual(merged.first?.snippet?.trigger, "addr")
        XCTAssertEqual(merged.last?.snippet?.trigger, "bad_idea")
        XCTAssertEqual(merged.filter { $0.emoji != nil }.count, 2)
    }

    func testMergeWithoutHitsIsTheEmojiList() {
        let emoji = EmojiStore.shared.all.prefix(5).map { Suggestion(emoji: $0, score: 1) }
        XCTAssertEqual(SnippetSearch.merge([], into: emoji, limit: 3), Array(emoji.prefix(3)))
    }

    func testSnippetIDsNeverCollideWithEmojiIDs() {
        let suggestion = Suggestion(snippet: snippet("joy"), score: 3)
        XCTAssertNotEqual(suggestion.id, "joy")
        XCTAssertNil(EmojiStore.shared.emoji(id: suggestion.id))
    }
}

@MainActor
final class SnippetEngineTests: XCTestCase {
    private var settings: AppSettings!
    private var jev: FakeJev!
    private var usageURL: URL!

    override func setUp() async throws {
        usageURL = FileManager.default.temporaryDirectory.appendingPathComponent("usage-\(UUID().uuidString).json")
        settings = AppSettings(defaults: UserDefaults(suiteName: "ColonTests-\(UUID().uuidString)")!)
        settings.maxResults = 8
        settings.useJev = true
        jev = FakeJev()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: usageURL)
    }

    private func makeEngine(usage: UsageStore? = nil) -> SuggestionEngine {
        let engine = SuggestionEngine(settings: settings, store: .shared,
                                      usage: usage ?? UsageStore(fileURL: usageURL, halfLife: 86_400, writeDelay: 60),
                                      jev: jev)
        engine.debounce = .milliseconds(1)
        return engine
    }

    func testSnippetRanksAboveEmojiAndInsertsItsText() throws {
        settings.snippets = [Snippet(trigger: "email", text: "me@example.com")]
        let engine = makeEngine()
        engine.update(query: "ema", context: PredictionContext())
        let first = try XCTUnwrap(engine.suggestions.first)
        XCTAssertEqual(first.snippet?.trigger, "email")
        XCTAssertEqual(engine.output(for: first.item), "me@example.com")
        XCTAssertNotNil(engine.suggestions.dropFirst().first?.emoji, "emoji still follow")
        XCTAssertLessThanOrEqual(engine.suggestions.count, 8)
    }

    func testMultiLineTextIsOutputVerbatim() throws {
        let signature = "Best,\nHunter\n\n+1 555 0100"
        settings.snippets = [Snippet(trigger: "sig", text: signature)]
        let engine = makeEngine()
        engine.update(query: "sig", context: PredictionContext())
        let first = try XCTUnwrap(engine.suggestions.first)
        XCTAssertEqual(engine.output(for: first.item), signature)
    }

    func testJevIsNeverAskedWhileASnippetMatches() async throws {
        settings.snippets = [Snippet(trigger: "email", text: "me@example.com")]
        let engine = makeEngine()
        engine.update(query: "email", context: PredictionContext(appName: "TextEdit"))
        XCTAssertFalse(engine.isRefining)
        // Same query, new context: still no request.
        engine.update(query: "email", context: PredictionContext(appName: "TextEdit", bundleID: "com.apple.TextEdit"))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(jev.calls.isEmpty)

        // A query no snippet matches goes to Jev as usual, without any snippet in the candidates.
        engine.update(query: "fire", context: PredictionContext())
        let deadline = ContinuousClock.now + .seconds(2)
        while jev.calls.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(jev.calls.map(\.query), ["fire"])
        XCTAssertFalse(jev.calls[0].candidates.contains { $0.hasPrefix("snippet:") })
    }

    func testSnippetPicksAreNotRecordedAsUsage() throws {
        let usage = UsageStore(fileURL: usageURL, halfLife: 86_400, writeDelay: 60)
        settings.snippets = [Snippet(trigger: "email", text: "me@example.com")]
        let engine = makeEngine(usage: usage)
        engine.update(query: "email", context: PredictionContext())
        let first = try XCTUnwrap(engine.suggestions.first)
        engine.recordUse(first.item)
        XCTAssertEqual(usage.top(10), [])
    }

    func testRecentsStripHasNoSnippets() {
        settings.snippets = [Snippet(trigger: "email", text: "me@example.com")]
        let engine = makeEngine()
        engine.update(query: "", context: PredictionContext())
        XCTAssertFalse(engine.suggestions.isEmpty)
        XCTAssertTrue(engine.suggestions.allSatisfy { $0.snippet == nil })
    }

    func testSnippetStaysFirstWhenSearchLanguagesLoad() async throws {
        settings.snippets = [Snippet(trigger: "inima2", text: "<3")]
        let engine = makeEngine()
        engine.update(query: "inima", context: PredictionContext())
        XCTAssertEqual(engine.suggestions.first?.snippet?.trigger, "inima2")
        await engine.reloadLanguages(["ro"]).value
        XCTAssertEqual(engine.suggestions.first?.snippet?.trigger, "inima2")
        XCTAssertEqual(engine.suggestions.dropFirst().first?.emoji?.char, "❤️", "Romanian names now match too")
    }

    func testSnippetsPersistInDefaults() {
        let suite = "ColonTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let snippet = Snippet(trigger: "addr", text: "1 Infinite Loop\nCupertino")
        AppSettings(defaults: defaults).snippets = [snippet]
        XCTAssertEqual(AppSettings(defaults: defaults).snippets, [snippet])
        defaults.removePersistentDomain(forName: suite)
    }
}
