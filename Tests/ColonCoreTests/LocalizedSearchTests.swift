import XCTest
@testable import ColonCore

final class LocalizedSearchTests: XCTestCase {
    private func chars(_ query: String, languages: [String], limit: Int = 8) -> [String] {
        EmojiSearch(store: .shared, usage: nil, languages: languages)
            .search(query, limit: limit)
            .compactMap(\.emoji?.char)
    }

    // MARK: - Folding

    func testFoldingIgnoresCaseAndAccents() {
        XCTAssertEqual(TextFolding.fold("Inimă"), "inima")
        XCTAssertEqual(TextFolding.fold("ȘȚĂÎÂ"), "staia")
        XCTAssertEqual(TextFolding.fold("şţ"), "st") // cedilla forms, common on older Romanian keyboards
        XCTAssertEqual(TextFolding.fold("Corazón"), "corazon")
        XCTAssertEqual(TextFolding.fold("Straße"), "strasse")
        XCTAssertEqual(TextFolding.fold("Łódź"), "lodz")
        XCTAssertEqual(TextFolding.fold("smørrebrød"), "smorrebrod")
        XCTAssertEqual(TextFolding.fold("Ёлка"), "елка")
        XCTAssertEqual(TextFolding.fold("ÇAĞRI"), "cagri")
        XCTAssertEqual(TextFolding.fold("heart"), "heart")
        // Marks outside Combining Diacritical Marks are letters in their script and stay.
        XCTAssertEqual(TextFolding.fold("ハート"), "ハート")
        XCTAssertEqual(TextFolding.fold("ガ"), "ガ")
    }

    func testFoldingIsIdempotent() {
        for text in ["Inimă roșie", "Ñandú", "Ελληνικά", "Ærø", "zażółć gęślą jaźń"] {
            let once = TextFolding.fold(text)
            XCTAssertEqual(TextFolding.fold(once), once, text)
        }
    }

    // MARK: - Localized matching

    func testRomanian() {
        XCTAssertEqual(chars("inima", languages: ["ro"]).first, "❤️")
        XCTAssertEqual(chars("inimă", languages: ["ro"]).first, "❤️")
        XCTAssertEqual(chars("INIMĂ", languages: ["ro"]).first, "❤️")
        XCTAssertEqual(chars("caine", languages: ["ro"]).first, "🐶")
        XCTAssertEqual(chars("câine", languages: ["ro"]).first, "🐶")
        XCTAssertTrue(chars("pisica", languages: ["ro"]).contains("🐱"))
    }

    func testSpanish() {
        XCTAssertEqual(chars("corazon", languages: ["es"]).first, "❤️")
        XCTAssertEqual(chars("corazón", languages: ["es"]).first, "❤️")
        XCTAssertTrue(chars("perro", languages: ["es"]).contains("🐶"))
    }

    func testPrefixesOfLocalizedWordsMatch() {
        XCTAssertTrue(chars("inim", languages: ["ro"]).contains("❤️"))
        XCTAssertTrue(chars("coraz", languages: ["es"]).contains("❤️"))
    }

    func testNonLatinScripts() {
        XCTAssertTrue(chars("сердце", languages: ["ru"]).contains("❤️"))
        XCTAssertTrue(chars("собака", languages: ["ru"]).contains("🐶"))
        XCTAssertTrue(chars("καρδια", languages: ["el"]).contains("❤️")) // typed without the tonos
    }

    func testLanguagesAreOnlySearchedWhenEnabled() {
        XCTAssertFalse(chars("inima", languages: []).contains("❤️"))
        XCTAssertFalse(chars("corazon", languages: ["ro"]).contains("❤️"))
        XCTAssertEqual(chars("corazon", languages: ["ro", "es"]).first, "❤️")
    }

    func testEnglishKeepsWorkingWithOtherLanguages() {
        let languages = ["ro", "es", "de"]
        XCTAssertEqual(chars("heart", languages: languages).first, "❤️")
        XCTAssertEqual(chars("joy", languages: languages).first, "😂")
        XCTAssertEqual(chars("fire", languages: languages).first, "🔥")
        XCTAssertEqual(chars("+1", languages: languages).first, "👍")
        XCTAssertEqual(chars("dog", languages: languages).first, "🐶")
        XCTAssertTrue(chars("haha", languages: languages, limit: 5).contains("😂"))
    }

    func testEnglishMatchingIsAccentInsensitive() {
        // English names with accents: `flag: Côte d’Ivoire`, `piñata`.
        XCTAssertTrue(chars("cote", languages: []).contains("🇨🇮"))
        XCTAssertTrue(chars("piñata", languages: []).contains("🪅"))
        XCTAssertTrue(chars("pinata", languages: []).contains("🪅"))
    }

    func testUnknownLanguageIsIgnored() {
        let search = EmojiSearch(store: .shared, usage: nil, languages: ["xx", "ro"])
        XCTAssertEqual(search.search("inima", limit: 3).first?.emoji?.char, "❤️")
    }

    // MARK: - Bundled files

    func testEverySupportedLanguageHasAFile() throws {
        for code in SearchLanguages.supported {
            let url = try XCTUnwrap(EmojiStore.bundledResourceURL("i18n/\(code).json.deflate"), code)
            let index = try EmojiStore.shared.language(deflatedJSON: Data(contentsOf: url)).index
            XCTAssertGreaterThan(index.terms.count, 5000, code)
        }
        let directory = try XCTUnwrap(EmojiStore.bundledResourceURL("i18n"))
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".json.deflate") }
            .map { String($0.dropLast(".json.deflate".count)) }
        XCTAssertEqual(Set(files), Set(SearchLanguages.supported))
        XCTAssertEqual(SearchLanguages.supported, SearchLanguages.supported.sorted())
    }

    func testLanguageIndexIsCached() throws {
        let store = EmojiStore.shared
        let first = try XCTUnwrap(store.language("ro")?.index)
        let second = try XCTUnwrap(store.language("ro")?.index)
        XCTAssertEqual(first.terms.count, second.terms.count)
        XCTAssertNil(store.language("xx"))
    }

    // MARK: - Language selection

    func testLanguageCodes() {
        XCTAssertEqual(SearchLanguages.code(for: "ro-RO"), "ro")
        XCTAssertEqual(SearchLanguages.code(for: "ro"), "ro")
        XCTAssertEqual(SearchLanguages.code(for: "es-419"), "es")
        XCTAssertEqual(SearchLanguages.code(for: "pt-BR"), "pt")
        XCTAssertEqual(SearchLanguages.code(for: "pt-PT"), "pt-PT")
        XCTAssertEqual(SearchLanguages.code(for: "zh-Hans-CN"), "zh")
        XCTAssertEqual(SearchLanguages.code(for: "zh-Hant-TW"), "zh-Hant")
        XCTAssertEqual(SearchLanguages.code(for: "zh-HK"), "zh-Hant")
        XCTAssertEqual(SearchLanguages.code(for: "nb-NO"), "no")
        XCTAssertNil(SearchLanguages.code(for: "en-US"))
        XCTAssertNil(SearchLanguages.code(for: "en"))
        XCTAssertNil(SearchLanguages.code(for: "tlh"))
    }

    func testDefaultSelectionFollowsPreferredLanguages() {
        XCTAssertEqual(SearchLanguages.defaultSelection(preferredLanguages: ["ro-RO"]), ["ro"])
        XCTAssertEqual(SearchLanguages.defaultSelection(preferredLanguages: ["en-US"]), [])
        XCTAssertEqual(SearchLanguages.defaultSelection(preferredLanguages: ["en-GB", "es-ES", "ro-RO", "es-MX"]), ["es", "ro"])
        XCTAssertEqual(SearchLanguages.defaultSelection(preferredLanguages: ["tlh", "en"]), [])
    }

    func testSanitizedDropsUnknownAndDuplicates() {
        XCTAssertEqual(SearchLanguages.sanitized(["ro", "xx", "ro", "es", "en"]), ["ro", "es"])
    }

    func testDisplayName() {
        let english = Locale(identifier: "en")
        XCTAssertEqual(SearchLanguages.displayName(for: "ro", in: english), "Română (Romanian)")
        XCTAssertEqual(SearchLanguages.displayName(for: "es", in: english), "Español (Spanish)")
        XCTAssertEqual(SearchLanguages.displayName(for: "ro", in: Locale(identifier: "ro")), "Română")
    }
}
