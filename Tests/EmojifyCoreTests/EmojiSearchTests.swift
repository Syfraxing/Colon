import XCTest
@testable import EmojifyCore

final class EmojiSearchTests: XCTestCase {
    private let search = EmojiSearch(store: .shared, usage: nil)

    private func chars(_ query: String, _ limit: Int = 8) -> [String] {
        search.search(query, limit: limit).map(\.emoji.char)
    }

    func testExactShortcodeWins() {
        XCTAssertEqual(chars("joy").first, "😂")
        XCTAssertEqual(chars("fire").first, "🔥")
        XCTAssertEqual(chars(":fire:").first, "🔥")
        XCTAssertEqual(chars("FIRE").first, "🔥")
        XCTAssertEqual(chars("+1").first, "👍")
        XCTAssertEqual(chars("100").first, "💯")
        XCTAssertEqual(chars("rocket").first, "🚀")
    }

    func testPrefixRanksThumbsUpHigh() {
        let results = chars("thu", 5)
        XCTAssertTrue(results.prefix(3).contains("👍"), "\(results)")
    }

    func testKeywordMatches() {
        let haha = chars("haha", 5)
        XCTAssertTrue(haha.contains("😆"), "\(haha)")
        XCTAssertTrue(haha.contains("😂"), "\(haha)")
        XCTAssertTrue(chars("lol", 5).contains("😂"))
        XCTAssertTrue(chars("dead", 5).contains("💀"))
    }

    func testChatShorthandBeatsCountryCodes() {
        XCTAssertNotEqual(chars("sm").first, "🇸🇲")
        XCTAssertEqual(chars("gm").first, "☀️")
        XCTAssertTrue(chars("us", 20).contains("🇺🇸"))
        XCTAssertEqual(chars("sus").first, "👀")
        XCTAssertEqual(chars("ty").first, "🙏")
        XCTAssertEqual(chars("lol", 3).prefix(2).sorted(), ["😂", "😆"].sorted())
    }

    func testTierOrdering() {
        let results = search.search("heart", limit: 30)
        XCTAssertEqual(results.first?.emoji.char, "❤️")
        XCTAssertEqual(results.map(\.score), results.map(\.score).sorted(by: >))
    }

    func testEmptyQueryReturnsNothing() {
        XCTAssertTrue(chars("").isEmpty)
        XCTAssertTrue(chars(":").isEmpty)
        XCTAssertTrue(search.search("joy", limit: 0).isEmpty)
    }

    func testSingleCharacterOnlySearchesShortcodes() {
        let results = search.search("x", limit: 50)
        XCTAssertFalse(results.isEmpty)
        for suggestion in results {
            XCTAssertTrue(suggestion.emoji.shortcodes.contains { $0.hasPrefix("x") }, suggestion.emoji.id)
        }
    }

    func testFuzzyFindsTyposButNotNoise() {
        XCTAssertTrue(chars("roket", 3).contains("🚀"), "\(chars("roket", 3))")
        XCTAssertTrue(chars("thmbsup", 3).contains("👍"), "\(chars("thmbsup", 3))")
        XCTAssertFalse(chars("yeet", 8).contains("🐞"))
        XCTAssertTrue(chars("zzqqxx").isEmpty)
    }

    func testStemming() {
        XCTAssertTrue(chars("parties", 5).contains("🥳") || chars("parties", 5).contains("🎉"), "\(chars("parties", 5))")
        XCTAssertTrue(chars("ghosted", 5).contains("👻"), "\(chars("ghosted", 5))")
        XCTAssertEqual(EmojiSearch.stems(of: "parties").first, "party")
    }

    func testFrecencyBreaksTiesButNeverBeatsABetterTier() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("usage-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let usage = UsageStore(fileURL: url, halfLife: UsageStore.defaultHalfLife, writeDelay: 60)
        let personalized = EmojiSearch(store: .shared, usage: usage)

        // 😂 and 😆 both have the keyword "haha"; popularity puts 😂 first until the user prefers 😆.
        let before = personalized.search("haha", limit: 5).map(\.emoji.id)
        XCTAssertLessThan(try XCTUnwrap(before.firstIndex(of: "joy")), try XCTUnwrap(before.firstIndex(of: "laughing")))
        for _ in 0..<3 { usage.recordUse(of: "laughing", query: "haha") }
        XCTAssertEqual(personalized.search("haha", limit: 5).first?.emoji.id, "laughing")

        // Heavy use of 😂 must not push it above the exact shortcode match for "fire".
        for _ in 0..<20 { usage.recordUse(of: "laughing", query: "fire") }
        XCTAssertEqual(personalized.search("fire", limit: 5).first?.emoji.id, "fire")
    }

    func testPerformance() {
        let queries = ["j", "jo", "joy", "th", "thu", "thumbsup", "haha", "s", "sm", "smile", "fire", "heart",
                       "roket", "parties", "xyzzy", "face", "cat", "lol", "sus", "100"]
        _ = search.search("warm", limit: 8)
        let clock = ContinuousClock()
        let rounds = 20
        let elapsed = clock.measure {
            for _ in 0..<rounds {
                for query in queries { _ = search.search(query, limit: 40) }
            }
        }
        let average = elapsed / (rounds * queries.count)
        print("EmojiSearch average per query: \(average)")
        #if DEBUG
        let budget = Duration.milliseconds(5) // unoptimized builds are several times slower
        #else
        let budget = Duration.milliseconds(1)
        #endif
        XCTAssertLessThan(average, budget)
    }
}
