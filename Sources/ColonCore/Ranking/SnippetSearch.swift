import Foundation

/// Matches the typed query against the user's snippet triggers and merges the hits into the emoji
/// results. Pure and local: snippets never reach Jev.
public enum SnippetSearch {
    public enum Match: Int, Comparable, Sendable {
        /// The trigger contains the query (queries of 2+ characters): shown below the emoji.
        case contains = 1
        /// The trigger starts with the query: shown above every emoji.
        case prefix
        /// The query is the trigger: shown first.
        case exact

        public static func < (lhs: Match, rhs: Match) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public struct Hit: Hashable, Sendable {
        public let snippet: Snippet
        public let match: Match
    }

    /// Shorter queries would make "contains" match almost every trigger.
    static let minimumContainsLength = 2

    /// How `query` (already normalised and folded like the emoji search: `TextFolding.fold`, colons
    /// stripped) relates to `trigger`.
    public static func match(query: String, trigger: String) -> Match? {
        guard !query.isEmpty else { return nil }
        let key = Snippet.normalizedTrigger(trigger)
        if key == query { return .exact }
        if key.hasPrefix(query) { return .prefix }
        if query.count >= minimumContainsLength, key.contains(query) { return .contains }
        return nil
    }

    /// Snippets matching `query`, best first (exact > prefix > contains, then shorter trigger, then
    /// the user's order). Snippets with no text or an unusable trigger never match.
    public static func search(_ query: String, in snippets: [Snippet]) -> [Hit] {
        let normalized = TextFolding.fold(EmojiSearch.normalize(query))
        guard !normalized.isEmpty else { return [] }
        let hits = snippets.enumerated().compactMap { offset, snippet -> (hit: Hit, order: Int)? in
            guard !snippet.text.isEmpty,
                  Snippet.problem(with: snippet.trigger, among: []) == nil,
                  let match = match(query: normalized, trigger: snippet.trigger) else { return nil }
            return (Hit(snippet: snippet, match: match), offset)
        }
        return hits.sorted {
            if $0.hit.match != $1.hit.match { return $0.hit.match > $1.hit.match }
            let lhs = $0.hit.snippet.trigger.count, rhs = $1.hit.snippet.trigger.count
            return lhs != rhs ? lhs < rhs : $0.order < $1.order
        }.map(\.hit)
    }

    /// Exact and prefix hits above the emoji, contains hits below them; every hit keeps a row
    /// (emoji give way), at most `limit` rows.
    public static func merge(_ hits: [Hit], into emoji: [Suggestion], limit: Int) -> [Suggestion] {
        let shown = hits.prefix(limit)
        func rows(_ hits: [Hit]) -> [Suggestion] {
            hits.map { Suggestion(snippet: $0.snippet, score: Double($0.match.rawValue)) }
        }
        let above = rows(shown.filter { $0.match >= .prefix })
        let below = rows(shown.filter { $0.match < .prefix })
        return above + emoji.prefix(max(0, limit - shown.count)) + below
    }
}
