import Foundation

/// Loads the bundled emoji dataset once. OWNER: core worker.
public final class EmojiStore: @unchecked Sendable {
    public static let shared = EmojiStore()

    /// Every emoji in dataset order (Unicode category order).
    public let all: [Emoji]

    public init(emoji: [Emoji]? = nil) {
        // SCAFFOLD: core worker loads Bundle.module "emoji.json" and builds lookup indexes.
        all = emoji ?? []
    }

    /// Exact lookup by any shortcode (without colons), case-insensitive.
    public func emoji(forShortcode shortcode: String) -> Emoji? {
        // SCAFFOLD
        all.first { $0.shortcodes.contains(shortcode.lowercased()) }
    }
}
