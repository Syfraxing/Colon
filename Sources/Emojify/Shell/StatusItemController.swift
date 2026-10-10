import AppKit
import EmojifyCore

/// Menu bar icon + menu. OWNER: shell worker.
@MainActor
final class StatusItemController {
    var onOpenSettings: (() -> Void)?
    var onQuit: (() -> Void)?

    private let settings: AppSettings
    private let engine: SuggestionEngine

    init(settings: AppSettings, engine: SuggestionEngine) {
        self.settings = settings
        self.engine = engine
        // SCAFFOLD
    }
}
