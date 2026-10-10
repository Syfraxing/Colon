import Foundation

/// Local, synchronous fuzzy search. Must answer in well under 1 ms for typical queries. OWNER: core worker.
public struct EmojiSearch: Sendable {
    public let store: EmojiStore

    public init(store: EmojiStore = .shared) {
        self.store = store
    }

    /// Ranked local matches for `query` (no trigger char). Empty query returns nothing.
    public func search(_ query: String, limit: Int) -> [Suggestion] {
        // SCAFFOLD
        []
    }
}
