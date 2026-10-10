import Foundation

/// Local, synchronous fuzzy search. Must answer in well under 1 ms for typical queries. OWNER: core worker.
///
/// Tiers, best first: exact shortcode > shortcode prefix > keyword exact > keyword prefix >
/// name-word prefix > fuzzy subsequence. Within a tier, the closer match wins, then personal
/// frecency, then dataset (Unicode) order. Frecency never lifts an emoji into a better tier.
/// Matching is case- and accent-insensitive (`TextFolding`). Keywords and name words of the extra
/// search `languages` (CLDR) rank in the same keyword / name-word tiers as English ones.
public struct EmojiSearch: Sendable {
    public let store: EmojiStore
    /// Source of frecency boosts; nil disables personalization.
    public let usage: UsageStore?
    /// `SearchLanguages` codes searched besides English (codes without a bundled file are ignored).
    public let languages: [String]
    private let loadedLanguages: [EmojiStore.Language]

    /// Loads each language's terms on first use (`EmojiStore.language`), so build searches
    /// with new languages off the main thread.
    public init(store: EmojiStore = .shared, usage: UsageStore? = .shared, languages: [String] = []) {
        self.store = store
        self.usage = usage
        self.languages = languages
        loadedLanguages = languages.compactMap { store.language($0) }
    }

    /// The emoji's CLDR names in the search languages (folded, e.g. `fata de caine` for 🐶 in
    /// Romanian), skipping repeats. Lets Jev read candidates in the language the user typed.
    public func localizedNames(of emoji: Emoji) -> [String] {
        guard let index = store.index(ofID: emoji.id) else { return [] }
        var names: [String] = []
        for language in loadedLanguages {
            if let name = language.names[index], !names.contains(name) { names.append(name) }
        }
        return names
    }

    /// Ranked local matches for `query` (no trigger char). Empty query returns nothing.
    public func search(_ query: String, limit: Int) -> [Suggestion] {
        let normalized = Self.normalize(query)
        guard !normalized.isEmpty, limit > 0 else { return [] }
        let snapshot = usage?.snapshot(query: normalized) ?? .empty
        return search(normalized: normalized, limit: limit, boosts: snapshot)
    }

    /// Same as `search(_:limit:)` with an explicit usage snapshot (lets callers reuse one).
    public func search(_ query: String, limit: Int, boosts: UsageStore.Snapshot) -> [Suggestion] {
        let normalized = Self.normalize(query)
        guard !normalized.isEmpty, limit > 0 else { return [] }
        return search(normalized: normalized, limit: limit, boosts: boosts)
    }

    // MARK: - Scoring

    enum Tier: Double {
        case fuzzy = 1, nameWordPrefix, keywordPrefix, keywordExact, shortcodePrefix, exactShortcode
    }

    /// Points per tier. In-tier quality (≤ 45) + popularity (≤ 14) + personal boost (≤ 39) stay
    /// below one tier, so neither popularity nor history can lift an emoji past a better match.
    static let tierWidth = 100.0
    static let popularityWeight = 14.0
    static let boostWeight = 39.0
    /// Fuzzy matches below this per-character quality are noise (`yeet` -> 🐞 via "lady beetle").
    static let fuzzyFloor = 0.6
    /// A shortcode prefix covering less than this share of the shortcode (`lol` -> `lollipop`) ranks
    /// with keyword prefixes, below exact keyword hits such as 😂 for `lol`.
    static let shortcodePrefixCoverage = 0.65

    /// Lowest score of an exact shortcode match.
    public static let exactShortcodeScore = Tier.exactShortcode.rawValue * tierWidth
    /// Highest possible score; callers may use it to normalize.
    public static let maximumScore = Tier.exactShortcode.rawValue * tierWidth + 45 + popularityWeight + boostWeight

    static func normalize(_ query: String) -> String {
        var text = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasPrefix(":") { text.removeFirst() }
        while text.hasSuffix(":") { text.removeLast() }
        return text.replacingOccurrences(of: " ", with: "_")
    }

    private func search(normalized: String, limit: Int, boosts: UsageStore.Snapshot) -> [Suggestion] {
        let all = store.all
        var best = [Double](repeating: 0, count: all.count)
        var touched: [Int32] = []
        touched.reserveCapacity(64)

        func offer(_ emoji: Int32, _ score: Double) {
            let index = Int(emoji)
            if best[index] == 0 { touched.append(emoji) }
            if score > best[index] { best[index] = score }
        }

        let folded = TextFolding.fold(normalized)
        let needle = Array(folded.utf8)
        collectPrefixMatches(needle, in: store.baseIndex, demotion: 0, offer: offer)
        for stem in Self.stems(of: folded) {
            collectPrefixMatches(Array(stem.utf8), in: store.baseIndex, demotion: 1, offer: offer)
        }
        for language in loadedLanguages {
            collectPrefixMatches(needle, in: language.index, demotion: 0, offer: offer)
        }
        if touched.count < limit, needle.count >= 2 {
            collectFuzzyMatches(needle, offer: offer)
        }

        var ranked: [(index: Int32, score: Double)] = touched.map { index in
            let i = Int(index)
            let boost = boosts.boost(for: all[i].id)
            return (index, best[i] + store.popularity[i] * Self.popularityWeight + boost * Self.boostWeight)
        }
        ranked.sort { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
        return ranked.prefix(limit).map { Suggestion(emoji: all[Int($0.index)], score: $0.score) }
    }

    /// Walks every term of `index` starting with `needle` (binary search + linear scan).
    private func collectPrefixMatches(_ needle: [UInt8], in index: EmojiStore.TermIndex, demotion: Double,
                                      offer: (Int32, Double) -> Void) {
        let terms = index.terms
        let short = needle.count < 2
        var i = index.lowerBound(needle)
        while i < terms.count {
            let term = terms[i]
            i += 1
            guard Self.hasPrefix(term.key, needle) else { break }
            // A single character matches half the dataset's tags; only shortcodes count then.
            if short && term.kind != .shortcode { continue }

            let exact = term.key.count == needle.count
            let coverage = Double(needle.count) / Double(term.key.count)
            let tier: Tier
            let quality: Double
            switch term.kind {
            case .shortcode where exact:
                tier = .exactShortcode
                quality = term.isPrimary ? 45 : 38
            case .shortcode where coverage >= Self.shortcodePrefixCoverage:
                tier = .shortcodePrefix
                quality = 35 * coverage + (term.isPrimary ? 10 : 0)
            case .shortcode:
                tier = .keywordPrefix
                quality = 30 + 10 * coverage + (term.isPrimary ? 5 : 0)
            case .keyword:
                tier = exact ? .keywordExact : .keywordPrefix
                quality = exact ? 30 : 35 * coverage
            case .nameWord:
                tier = .nameWordPrefix
                quality = 35 * coverage + (exact ? 10 : 0)
            }
            let score = (tier.rawValue - demotion) * Self.tierWidth + quality
            if score > 0 { offer(term.emoji, score) }
        }
    }

    /// Subsequence match over shortcodes, starting at a word start, scored per matched character:
    /// consecutive or word-start characters count fully, scattered ones partially.
    private func collectFuzzyMatches(_ needle: [UInt8], offer: (Int32, Double) -> Void) {
        for (index, codes) in store.shortcodeBytes.enumerated() {
            var bestQuality = 0.0
            for code in codes where code.count >= needle.count {
                let quality = Self.fuzzyQuality(needle, in: code)
                if quality > bestQuality { bestQuality = quality }
            }
            if bestQuality >= Self.fuzzyFloor {
                offer(Int32(index), Tier.fuzzy.rawValue * Self.tierWidth + 45 * bestQuality)
            }
        }
    }

    /// 0...1 quality of `needle` as a subsequence of `haystack`, 0 when it doesn't match.
    static func fuzzyQuality(_ needle: [UInt8], in haystack: [UInt8]) -> Double {
        guard let first = needle.first else { return 0 }
        var bestScore = 0.0
        var start = 0
        while start < haystack.count {
            if haystack[start] == first, isWordStart(haystack, start) {
                var score = 1.0
                var previous = start
                var position = start + 1
                var matched = 1
                while matched < needle.count, position < haystack.count {
                    if haystack[position] == needle[matched] {
                        score += (position == previous + 1 || isWordStart(haystack, position)) ? 1 : 0.3
                        previous = position
                        matched += 1
                    }
                    position += 1
                }
                if matched == needle.count {
                    // Prefer haystacks that are mostly covered by the needle.
                    let coverage = Double(needle.count) / Double(haystack.count)
                    bestScore = max(bestScore, score / Double(needle.count) * (0.9 + 0.1 * coverage))
                }
            }
            start += 1
        }
        return bestScore
    }

    private static func isWordStart(_ bytes: [UInt8], _ index: Int) -> Bool {
        index == 0 || bytes[index - 1] == UInt8(ascii: "_") || bytes[index - 1] == UInt8(ascii: "-")
    }

    static func hasPrefix(_ bytes: [UInt8], _ prefix: [UInt8]) -> Bool {
        guard bytes.count >= prefix.count else { return false }
        var i = 0
        while i < prefix.count {
            if bytes[i] != prefix[i] { return false }
            i += 1
        }
        return true
    }

    /// Light English inflection stripping: `parties` -> `party`, `ghosted` -> `ghost`, `launching` -> `launch`.
    static func stems(of word: String) -> [String] {
        guard word.count >= 4, word.allSatisfy({ $0.isLetter }) else { return [] }
        var stems: [String] = []
        func add(_ stem: Substring, _ suffix: String = "") {
            let candidate = String(stem) + suffix
            if candidate.count >= 3, candidate != word, !stems.contains(candidate) { stems.append(candidate) }
        }
        if word.hasSuffix("ies") { add(word.dropLast(3), "y") }
        if word.hasSuffix("ing") {
            let base = word.dropLast(3)
            add(base)
            add(base, "e")
            if let last = base.last, base.dropLast().last == last { add(base.dropLast()) }
        }
        if word.hasSuffix("ed") {
            let base = word.dropLast(2)
            add(base)
            add(word.dropLast(1))
            if let last = base.last, base.dropLast().last == last { add(base.dropLast()) }
        }
        if word.hasSuffix("es") { add(word.dropLast(2)) }
        if word.hasSuffix("s"), !word.hasSuffix("ss") { add(word.dropLast(1)) }
        return stems
    }
}
