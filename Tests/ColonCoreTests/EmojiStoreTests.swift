import XCTest
@testable import ColonCore

final class EmojiStoreTests: XCTestCase {
    func testBundledDatasetLoads() {
        let store = EmojiStore.shared
        XCTAssertGreaterThan(store.all.count, 1800)
        XCTAssertEqual(Set(store.all.map(\.id)).count, store.all.count, "ids must be unique")
        XCTAssertFalse(store.all.contains { $0.category == "Component" })
        XCTAssertFalse(store.all.contains { $0.name.hasPrefix("regional indicator") })
        XCTAssertEqual(store.all.first?.char, "😀", "dataset keeps Unicode order")
    }

    func testShortcodeLookup() {
        let store = EmojiStore.shared
        XCTAssertEqual(store.emoji(forShortcode: "joy")?.char, "😂")
        XCTAssertEqual(store.emoji(forShortcode: ":THUMBSUP:")?.char, "👍")
        XCTAssertEqual(store.emoji(forShortcode: "+1")?.char, "👍")
        XCTAssertEqual(store.emoji(forShortcode: "heart")?.char, "❤️")
        XCTAssertNil(store.emoji(forShortcode: "definitely_not_an_emoji"))
        XCTAssertEqual(store.emoji(id: "fire")?.char, "🔥")
    }

    func testSlackAliasesComeFirst() throws {
        let thumbsUp = try XCTUnwrap(EmojiStore.shared.emoji(forShortcode: "thumbsup"))
        XCTAssertEqual(thumbsUp.id, "+1")
        XCTAssertTrue(thumbsUp.supportsSkinTone)
        XCTAssertTrue(thumbsUp.keywords.contains("like"))
    }

    func testVersionFilterDropsGlyphsTheOSCannotRender() throws {
        let json = """
        [{"id":"old","char":"😀","name":"grinning face","category":"Smileys & Emotion","shortcodes":["old"],"keywords":[],"supportsSkinTone":false},
         {"id":"new","char":"🫩","name":"face with bags under eyes","category":"Smileys & Emotion","shortcodes":["new"],"keywords":[],"supportsSkinTone":false,"v":16}]
        """
        XCTAssertEqual(try EmojiStore.decode(Data(json.utf8), maxVersion: 15.1).map(\.id), ["old"])
        XCTAssertEqual(try EmojiStore.decode(Data(json.utf8), maxVersion: 16).map(\.id), ["old", "new"])
        XCTAssertEqual(EmojiStore.supportedEmojiVersion(for: OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0)), 15.0)
        XCTAssertEqual(EmojiStore.supportedEmojiVersion(for: OperatingSystemVersion(majorVersion: 15, minorVersion: 4, patchVersion: 0)), 16.0)
        XCTAssertEqual(EmojiStore.supportedEmojiVersion(for: OperatingSystemVersion(majorVersion: 26, minorVersion: 4, patchVersion: 0)), 17.0)
    }

    func testPopularPoolIdsExist() {
        let missing = PopularEmoji.ids.filter { EmojiStore.shared.emoji(id: $0) == nil }
        XCTAssertEqual(missing, [])
        XCTAssertEqual(Set(PopularEmoji.ids).count, PopularEmoji.ids.count)
    }

    func testSkinToneApplication() throws {
        let store = EmojiStore.shared
        let thumbsUp = try XCTUnwrap(store.emoji(id: "+1"))
        XCTAssertEqual(SuggestionEngine.applying(.medium, to: thumbsUp), "👍🏽")
        XCTAssertEqual(SuggestionEngine.applying(.none, to: thumbsUp), "👍")
        let pointUp = try XCTUnwrap(store.emoji(id: "point_up"))
        XCTAssertEqual(SuggestionEngine.applying(.dark, to: pointUp), "☝🏿")
        let technologist = try XCTUnwrap(store.emoji(id: "technologist"))
        XCTAssertEqual(SuggestionEngine.applying(.light, to: technologist), "🧑🏻‍💻")
        let fire = try XCTUnwrap(store.emoji(id: "fire"))
        XCTAssertEqual(SuggestionEngine.applying(.dark, to: fire), "🔥")
    }
}
