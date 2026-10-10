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

    /// Excluded on first launch: apps with their own `:shortcode:` picker, plus terminals, IDEs and
    /// password managers (a `:` typed into a password prompt must never become a query).
    public static let defaultExcludedBundleIDs: [String] = [
        // Native emoji pickers
        "com.tinyspeck.slackmacgap",       // Slack
        "com.hnc.Discord",                 // Discord
        "com.microsoft.teams2",            // Microsoft Teams
        "com.linear",                      // Linear
        "notion.id",                       // Notion
        "com.github.GitHubClient",         // GitHub Desktop
        // Terminals and editors
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "com.microsoft.VSCode",
        "com.apple.dt.Xcode",
        "dev.zed.Zed",
        "com.todesktop.230313mzl4w4u92",   // Cursor
        // Password managers
        "com.1password.1password",
        "com.bitwarden.desktop",
        "com.apple.keychainaccess",
        "com.apple.Passwords",
    ]

    /// Characters a trigger may not contain: they are query characters or whitespace.
    private static let forbiddenTriggerCharacters = CharacterSet.alphanumerics
        .union(CharacterSet(charactersIn: "_+-"))
        .union(.whitespacesAndNewlines)

    /// A trigger is 1–3 ASCII punctuation/symbol characters that are not query characters.
    /// Shared by the Settings UI (validation) and the input layer (deleteCount math relies on it).
    public static func isValidTrigger(_ trigger: String) -> Bool {
        (1...3).contains(trigger.count) && trigger.unicodeScalars.allSatisfy {
            $0.isASCII && !forbiddenTriggerCharacters.contains($0)
        }
    }

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
    /// Bundle identifiers where Colon stays silent.
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
            Key.minQueryLength: 2,
            Key.maxResults: 8,
            Key.useJev: true,
            Key.sendTextContext: false,
            Key.excludedBundleIDs: Self.defaultExcludedBundleIDs,
            Key.autoReplaceOnClosingTrigger: true,
            Key.skinTone: SkinTone.none.rawValue,
            Key.insertionMethod: InsertionMethod.typing.rawValue,
            Key.hasCompletedOnboarding: false,
        ])
        isEnabled = defaults.bool(forKey: Key.isEnabled)
        let trigger = defaults.string(forKey: Key.triggerString) ?? ":"
        triggerString = Self.isValidTrigger(trigger) ? trigger : ":"
        minQueryLength = min(max(1, defaults.integer(forKey: Key.minQueryLength)), 5)
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

/// Health of the keyboard pipeline, shown in the menu bar.
public enum InputStatus: Equatable, Sendable {
    case running
    /// Accessibility (or Input Monitoring) permission not granted.
    case noPermission
    /// Secure keyboard entry is active (password field, terminal secure mode).
    case secureInput
    /// User turned Colon off.
    case disabled
}
