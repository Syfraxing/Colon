import Foundation

/// One emoji from the bundled dataset (`Resources/emoji.json`).
public struct Emoji: Hashable, Codable, Sendable, Identifiable {
    /// Primary Slack-style shortcode without colons, e.g. `joy`. Unique.
    public let id: String
    /// The emoji itself, e.g. `😂` (base form, no skin tone applied).
    public let char: String
    /// Human readable name, e.g. `face with tears of joy`.
    public let name: String
    /// Unicode category, e.g. `Smileys & Emotion`.
    public let category: String
    /// All shortcodes including `id`, e.g. `["joy"]`.
    public let shortcodes: [String]
    /// Search keywords / tags, lowercased, e.g. `["laugh", "lol", "haha"]`.
    public let keywords: [String]
    /// Whether a Fitzpatrick skin-tone modifier can be applied.
    public let supportsSkinTone: Bool

    public init(id: String, char: String, name: String, category: String,
                shortcodes: [String], keywords: [String], supportsSkinTone: Bool) {
        self.id = id
        self.char = char
        self.name = name
        self.category = category
        self.shortcodes = shortcodes
        self.keywords = keywords
        self.supportsSkinTone = supportsSkinTone
    }
}

/// Fitzpatrick skin tone preference.
public enum SkinTone: Int, CaseIterable, Codable, Sendable {
    case none = 0, light, mediumLight, medium, mediumDark, dark

    /// The modifier scalar appended to skin-tone capable emoji, nil for `.none`.
    public var modifier: String? {
        switch self {
        case .none: nil
        case .light: "\u{1F3FB}"
        case .mediumLight: "\u{1F3FC}"
        case .medium: "\u{1F3FD}"
        case .mediumDark: "\u{1F3FE}"
        case .dark: "\u{1F3FF}"
        }
    }

    public var swatch: String {
        switch self {
        case .none: "✋"
        case .light: "✋🏻"
        case .mediumLight: "✋🏼"
        case .medium: "✋🏽"
        case .mediumDark: "✋🏾"
        case .dark: "✋🏿"
        }
    }
}

/// A ranked candidate shown in the picker.
public struct Suggestion: Hashable, Sendable, Identifiable {
    public var id: String { emoji.id }
    public let emoji: Emoji
    /// Final blended score used for ordering (higher is better).
    public var score: Double
    /// Probability Jev assigned to this emoji, nil until Jev has answered.
    public var jevProbability: Double?

    public init(emoji: Emoji, score: Double, jevProbability: Double? = nil) {
        self.emoji = emoji
        self.score = score
        self.jevProbability = jevProbability
    }
}

/// What Jev gets to know about where the user is typing.
public struct PredictionContext: Hashable, Sendable {
    public var appName: String?
    public var bundleID: String?
    /// Up to ~300 characters before the trigger, only when the user allows sending context.
    public var textBeforeTrigger: String?

    public init(appName: String? = nil, bundleID: String? = nil, textBeforeTrigger: String? = nil) {
        self.appName = appName
        self.bundleID = bundleID
        self.textBeforeTrigger = textBeforeTrigger
    }
}
