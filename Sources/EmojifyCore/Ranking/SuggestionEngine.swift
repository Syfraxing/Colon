import Combine
import Foundation

public enum JevStatus: Equatable, Sendable {
    case disabled          // user turned Jev off
    case noKey             // no API key saved
    case idle              // ready
    case ok(milliseconds: Int)
    case error(String)
}

/// Combines instant local search + frecency with an async Jev rerank.
/// The picker UI observes `suggestions`; the input layer calls `update`. OWNER: core worker.
@MainActor
public final class SuggestionEngine: ObservableObject {
    @Published public private(set) var query: String = ""
    /// Ordered best-first, at most `settings.maxResults`.
    @Published public private(set) var suggestions: [Suggestion] = []
    /// True while a Jev request for the current query is in flight.
    @Published public private(set) var isRefining = false
    @Published public private(set) var jevStatus: JevStatus = .idle

    private let settings: AppSettings

    /// `jev` nil means: build a `JevClient` from `KeychainStore.jevAPIKey` on demand.
    public init(settings: AppSettings, store: EmojiStore = .shared, usage: UsageStore = .shared, jev: JevRanking? = nil) {
        self.settings = settings
        // SCAFFOLD
    }

    /// Recompute local results synchronously, then (debounced) ask Jev to rerank.
    public func update(query: String, context: PredictionContext) {
        // SCAFFOLD
        self.query = query
    }

    /// Clear query/results and cancel any in-flight Jev request.
    public func reset() {
        // SCAFFOLD
        query = ""
        suggestions = []
    }

    /// Call after the user inserts an emoji.
    public func recordUse(_ emoji: Emoji) {
        // SCAFFOLD
    }

    /// The string to insert for `emoji`, with the preferred skin tone applied when supported.
    public func output(for emoji: Emoji) -> String {
        // SCAFFOLD
        emoji.char
    }
}
