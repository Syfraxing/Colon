import Combine
import Foundation

/// How the chosen emoji is put into the target app.
public enum InsertionMethod: String, CaseIterable, Codable, Sendable {
    /// Synthesize unicode keystrokes. Clipboard untouched. Default.
    case typing
    /// Put the emoji on the pasteboard, send ⌘V, restore the previous pasteboard.
    case paste
}

/// Single source of truth for user preferences, persisted in `UserDefaults`.
/// The Jev API key is NOT stored here; see `KeychainStore`.
@MainActor
public final class AppSettings: ObservableObject {
    public static let shared = AppSettings()

    public enum Key {
        public static let isEnabled = "isEnabled"
        public static let triggerString = "triggerString"
        public static let minQueryLength = "minQueryLength"
        public static let maxResults = "maxResults"
        public static let useJev = "useJev"
        public static let sendTextContext = "sendTextContext"
        public static let excludedBundleIDs = "excludedBundleIDs"
        public static let autoReplaceOnClosingTrigger = "autoReplaceOnClosingTrigger"
        public static let skinTone = "skinTone"
        public static let insertionMethod = "insertionMethod"
        public static let hasCompletedOnboarding = "hasCompletedOnboarding"
    }

    /// Apps that ship their own `:shortcode:` picker; excluded on first launch.
    public static let defaultExcludedBundleIDs: [String] = [
        "com.tinyspeck.slackmacgap", // Slack
        "com.hnc.Discord",           // Discord
        "com.microsoft.teams2",      // Microsoft Teams
        "com.linear",                // Linear
        "notion.id",                 // Notion
        "com.github.GitHubClient",   // GitHub Desktop
    ]

    private let defaults: UserDefaults

    @Published public var isEnabled: Bool { didSet { defaults.set(isEnabled, forKey: Key.isEnabled) } }
    /// Characters that start a query. Default `:` (Slack-style). Non-empty, no whitespace.
    @Published public var triggerString: String { didSet { defaults.set(triggerString, forKey: Key.triggerString) } }
    /// Query characters required after the trigger before the picker shows.
    @Published public var minQueryLength: Int { didSet { defaults.set(minQueryLength, forKey: Key.minQueryLength) } }
    /// Number of suggestions in the picker.
    @Published public var maxResults: Int { didSet { defaults.set(maxResults, forKey: Key.maxResults) } }
    /// Rerank with Jev when an API key is present.
    @Published public var useJev: Bool { didSet { defaults.set(useJev, forKey: Key.useJev) } }
    /// Send the text typed before the trigger to Jev for context.
    @Published public var sendTextContext: Bool { didSet { defaults.set(sendTextContext, forKey: Key.sendTextContext) } }
    /// Bundle identifiers where Emojify stays silent.
    @Published public var excludedBundleIDs: [String] { didSet { defaults.set(excludedBundleIDs, forKey: Key.excludedBundleIDs) } }
    /// Typing the trigger again after an exact shortcode (`:joy:`) inserts immediately.
    @Published public var autoReplaceOnClosingTrigger: Bool { didSet { defaults.set(autoReplaceOnClosingTrigger, forKey: Key.autoReplaceOnClosingTrigger) } }
    @Published public var skinTone: SkinTone { didSet { defaults.set(skinTone.rawValue, forKey: Key.skinTone) } }
    @Published public var insertionMethod: InsertionMethod { didSet { defaults.set(insertionMethod.rawValue, forKey: Key.insertionMethod) } }
    @Published public var hasCompletedOnboarding: Bool { didSet { defaults.set(hasCompletedOnboarding, forKey: Key.hasCompletedOnboarding) } }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.isEnabled: true,
            Key.triggerString: ":",
            Key.minQueryLength: 1,
            Key.maxResults: 8,
            Key.useJev: true,
            Key.sendTextContext: true,
            Key.excludedBundleIDs: Self.defaultExcludedBundleIDs,
            Key.autoReplaceOnClosingTrigger: true,
            Key.skinTone: SkinTone.none.rawValue,
            Key.insertionMethod: InsertionMethod.typing.rawValue,
            Key.hasCompletedOnboarding: false,
        ])
        isEnabled = defaults.bool(forKey: Key.isEnabled)
        let trigger = defaults.string(forKey: Key.triggerString) ?? ":"
        triggerString = trigger.isEmpty ? ":" : trigger
        minQueryLength = max(0, defaults.integer(forKey: Key.minQueryLength))
        maxResults = min(max(defaults.integer(forKey: Key.maxResults), 3), 12)
        useJev = defaults.bool(forKey: Key.useJev)
        sendTextContext = defaults.bool(forKey: Key.sendTextContext)
        excludedBundleIDs = defaults.stringArray(forKey: Key.excludedBundleIDs) ?? Self.defaultExcludedBundleIDs
        autoReplaceOnClosingTrigger = defaults.bool(forKey: Key.autoReplaceOnClosingTrigger)
        skinTone = SkinTone(rawValue: defaults.integer(forKey: Key.skinTone)) ?? .none
        insertionMethod = InsertionMethod(rawValue: defaults.string(forKey: Key.insertionMethod) ?? "") ?? .typing
        hasCompletedOnboarding = defaults.bool(forKey: Key.hasCompletedOnboarding)
    }

    public func isExcluded(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return excludedBundleIDs.contains(bundleID)
    }
}
