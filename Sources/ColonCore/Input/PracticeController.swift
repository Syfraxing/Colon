import Combine
import Foundation

/// Drives the onboarding practice field with the real `TriggerEngine` and a dedicated
/// `SuggestionEngine`, mirroring what `InputController` does in other apps. (The global
/// input layer stays silent while Colon itself is frontmost, so the field runs its own copy.)
/// The text view hands every key to `handle` first and performs the replacements it asks for.
@MainActor
public final class PracticeController: ObservableObject {
    @Published public private(set) var isShowing = false
    @Published public private(set) var selectedIndex = 0
    @Published public private(set) var lastInserted: String?

    public let engine: SuggestionEngine
    private let settings: AppSettings
    private let store: EmojiStore
    private var trigger: TriggerEngine

    public init(settings: AppSettings, engine: SuggestionEngine, store: EmojiStore = .shared) {
        self.settings = settings
        self.engine = engine
        self.store = store
        trigger = TriggerEngine(
            trigger: settings.triggerString,
            minQueryLength: settings.minQueryLength,
            autoReplaceOnClosingTrigger: settings.autoReplaceOnClosingTrigger,
            showsRecentsOnTrigger: settings.showRecentsOnTrigger,
            shortcodeExists: { store.emoji(forShortcode: $0) != nil }
        )
    }

    public var visibleSuggestions: [Suggestion] {
        Array(engine.suggestions.prefix(settings.maxResults))
    }

    /// Feeds one key. `replace(deleteCount, text)` must delete `deleteCount` characters before the
    /// caret and insert `text`, like `Inserter.replace`. Returns true when the key was consumed
    /// (it must not reach the text view).
    public func handle(_ input: KeyInput, replace: (_ deleteCount: Int, _ text: String) -> Void) -> Bool {
        trigger.trigger = settings.triggerString
        trigger.minQueryLength = settings.minQueryLength
        trigger.autoReplaceOnClosingTrigger = settings.autoReplaceOnClosingTrigger
        trigger.showsRecentsOnTrigger = settings.showRecentsOnTrigger
        // The practice list is always vertical.
        trigger.horizontalLayout = false

        let result = trigger.handle(input, pickerVisible: isShowing && !visibleSuggestions.isEmpty)
        // The engine has already updated (or ended) its capture for this key; only the list follows.
        // `.hide` keeps the capture when the query is below the minimum (the bare-trigger strip
        // closes on the first letter of `:haha`), so it must never reset the engine.
        switch result.action {
        case .none:
            break
        case .show(let query):
            if !isShowing { selectedIndex = 0 }
            let context = PredictionContext(appName: "Colon", bundleID: Bundle.main.bundleIdentifier)
            engine.update(query: query, context: context)
            isShowing = true
        case .hide:
            hideList()
        case .moveSelection(let delta):
            let count = visibleSuggestions.count
            if count > 0 {
                selectedIndex = (selectedIndex + delta + count) % count
            }
        case .commitSelection(let deleteCount):
            let suggestions = visibleSuggestions
            if suggestions.indices.contains(selectedIndex) {
                insert(engine.output(for: suggestions[selectedIndex].item), replacing: deleteCount, replace)
            }
            hideList()
        case .commitSelectionKeepOpen(let deleteCount):
            let suggestions = visibleSuggestions
            if suggestions.indices.contains(selectedIndex) {
                insert(engine.output(for: suggestions[selectedIndex].item), replacing: deleteCount, replace)
            } else {
                trigger.keepOpenInsertFailed()
            }
        case .commitShortcode(let shortcode, let deleteCount):
            if let emoji = store.emoji(forShortcode: shortcode) {
                insert(engine.output(for: emoji), replacing: deleteCount, replace)
            }
            hideList()
        }
        return result.swallow
    }

    /// A click in the field moved the caret: the capture ends.
    public func interrupt() {
        trigger.reset()
        hideList()
    }

    private func hideList() {
        engine.reset()
        isShowing = false
        selectedIndex = 0
    }

    private func insert(_ text: String, replacing count: Int, _ replace: (Int, String) -> Void) {
        replace(count, text)
        lastInserted = text
    }
}
