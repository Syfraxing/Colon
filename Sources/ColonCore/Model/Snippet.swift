import Foundation

/// A user-defined text expansion: typing the trigger after `:` (e.g. `:sig`) offers `text` in the
/// picker. Personal data: stored only in local `UserDefaults` (`AppSettings.snippets`), never sent
/// to Jev, never logged.
public struct Snippet: Hashable, Codable, Sendable, Identifiable {
    public let id: UUID
    /// Typed after the trigger string, without it (`sig`, not `:sig`). Matched case-insensitively.
    public var trigger: String
    /// Inserted verbatim; may span several lines.
    public var text: String

    public init(id: UUID = UUID(), trigger: String, text: String) {
        self.id = id
        self.trigger = trigger
        self.text = text
    }

    /// Why a trigger cannot be used, for the Settings UI.
    public enum TriggerProblem: Equatable, Sendable {
        case empty
        case containsWhitespace
        /// A character the input layer would not treat as part of a query (only letters, digits, `_`, `+`, `-`).
        case invalidCharacter(Character)
        case tooLong
        /// Another snippet already uses this trigger (ignoring case).
        case duplicate

        public var message: String {
            switch self {
            case .empty: "Enter a trigger."
            case .containsWhitespace: "Triggers can't contain spaces."
            case .invalidCharacter(let character): "“\(character)” can't be typed in a trigger. Use letters, digits, _ + or -."
            case .tooLong: "Triggers can be at most \(Snippet.maxTriggerLength) characters."
            case .duplicate: "Another snippet already uses this trigger."
            }
        }
    }

    /// Queries longer than this end tracking, so a longer trigger could never be typed.
    public static let maxTriggerLength = TriggerEngine.maxQueryLength

    /// The form triggers are compared in.
    public static func normalizedTrigger(_ trigger: String) -> String {
        trigger.lowercased()
    }

    /// Nil when `trigger` is usable for the snippet `id` given the other `snippets`.
    public static func problem(with trigger: String, among snippets: [Snippet], excluding id: UUID? = nil) -> TriggerProblem? {
        guard !trigger.isEmpty else { return .empty }
        if trigger.contains(where: { $0.isWhitespace || $0.isNewline }) { return .containsWhitespace }
        if let bad = trigger.first(where: { !TriggerEngine.isQueryCharacter($0) }) { return .invalidCharacter(bad) }
        guard trigger.count <= maxTriggerLength else { return .tooLong }
        let key = normalizedTrigger(trigger)
        if snippets.contains(where: { $0.id != id && normalizedTrigger($0.trigger) == key }) { return .duplicate }
        return nil
    }
}
