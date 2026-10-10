import Foundation
import os

/// State-transition logging for the input layer, enabled only with `EMOJIFY_DEBUG=1`.
/// Callers must never pass typed text other than the active query.
enum InputLog {
    static let isEnabled = ProcessInfo.processInfo.environment["EMOJIFY_DEBUG"] == "1"
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Emojify", category: "input")

    static func debug(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let text = message()
        logger.debug("\(text, privacy: .private)")
    }
}
