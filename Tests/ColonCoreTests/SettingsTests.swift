import XCTest
@testable import ColonCore

@MainActor
final class SettingsTests: XCTestCase {
    func testDefaultsExcludeAppsWithNativePickers() {
        let defaults = UserDefaults(suiteName: "ColonTests-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.triggerString, ":")
        XCTAssertTrue(settings.isExcluded(bundleID: "com.tinyspeck.slackmacgap"))
        XCTAssertFalse(settings.isExcluded(bundleID: "com.apple.TextEdit"))
    }

    func testSearchLanguagesDefaultToSupportedSystemLanguages() {
        func settings(_ preferred: [String]) -> AppSettings {
            AppSettings(defaults: UserDefaults(suiteName: "ColonTests-\(UUID().uuidString)")!, preferredLanguages: preferred)
        }
        XCTAssertEqual(settings(["ro-RO", "en-US"]).searchLanguages, ["ro"])
        XCTAssertEqual(settings(["en-US", "es-ES"]).searchLanguages, ["es"])
        XCTAssertEqual(settings(["en-US"]).searchLanguages, [])
        XCTAssertEqual(settings(["tlh"]).searchLanguages, [])
    }

    func testSearchLanguagesPersistAndDropUnknownCodes() {
        let defaults = UserDefaults(suiteName: "ColonTests-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults, preferredLanguages: ["ro-RO"])
        settings.searchLanguages = ["es", "de"]
        XCTAssertEqual(AppSettings(defaults: defaults, preferredLanguages: ["ro-RO"]).searchLanguages, ["es", "de"])

        // Turning every extra language off sticks (the system default does not come back).
        settings.searchLanguages = []
        XCTAssertEqual(AppSettings(defaults: defaults, preferredLanguages: ["ro-RO"]).searchLanguages, [])

        defaults.set(["xx", "ro", "ro"], forKey: AppSettings.Key.searchLanguages)
        XCTAssertEqual(AppSettings(defaults: defaults).searchLanguages, ["ro"])
    }
}
