import XCTest
@testable import EmojifyCore

@MainActor
final class SettingsTests: XCTestCase {
    func testDefaultsExcludeAppsWithNativePickers() {
        let defaults = UserDefaults(suiteName: "EmojifyTests-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.triggerString, ":")
        XCTAssertTrue(settings.isExcluded(bundleID: "com.tinyspeck.slackmacgap"))
        XCTAssertFalse(settings.isExcluded(bundleID: "com.apple.TextEdit"))
    }
}
