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
}
