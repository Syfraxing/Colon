import ColonCore
import Foundation

/// One titled block of the search-mode grid.
struct EmojiSection: Identifiable, Equatable {
    let id: String
    let title: String
    let symbol: String
    let emoji: [Emoji]

    static let frequentID = "frequent"

    func cellID(_ index: Int) -> String { "\(id)/\(emoji[index].id)" }
}

/// Builds the browsable grid from the dataset: categories in dataset order, plus "Frequently used".
enum EmojiCatalog {
    static func categorySections(from store: EmojiStore) -> [EmojiSection] {
        var order: [String] = []
        var groups: [String: [Emoji]] = [:]
        for emoji in store.all where emoji.category != "Component" {
            if groups[emoji.category] == nil { order.append(emoji.category) }
            groups[emoji.category, default: []].append(emoji)
        }
        return order.map { EmojiSection(id: $0, title: $0, symbol: symbol(for: $0), emoji: groups[$0] ?? []) }
    }

    static func frequentSection(store: EmojiStore, usage: UsageStore, limit: Int = 18) -> EmojiSection? {
        let emoji = usage.top(limit).compactMap { store.emoji(id: $0) }
        guard !emoji.isEmpty else { return nil }
        return EmojiSection(id: EmojiSection.frequentID, title: "Frequently Used", symbol: "clock", emoji: emoji)
    }

    static func symbol(for category: String) -> String {
        switch category {
        case "Smileys & Emotion": "face.smiling"
        case "People & Body": "hand.wave"
        case "Animals & Nature": "pawprint"
        case "Food & Drink": "fork.knife"
        case "Travel & Places": "car"
        case "Activities": "soccerball"
        case "Objects": "lightbulb"
        case "Symbols": "heart"
        case "Flags": "flag"
        default: "circle.grid.2x2"
        }
    }
}

/// A cell in the sectioned grid.
struct GridPosition: Hashable {
    var section: Int
    var item: Int
}

/// Arrow-key movement through sections whose last rows may be partial.
enum GridNavigator {
    static func move(_ pos: GridPosition, dx: Int, dy: Int, counts: [Int], columns: Int) -> GridPosition {
        guard !counts.isEmpty, counts.indices.contains(pos.section), counts[pos.section] > 0 else { return pos }
        var p = pos
        if dx != 0 { p = step(p, by: dx, counts: counts) }
        if dy > 0 { p = down(p, counts: counts, columns: columns) }
        if dy < 0 { p = up(p, counts: counts, columns: columns) }
        return p
    }

    private static func step(_ pos: GridPosition, by delta: Int, counts: [Int]) -> GridPosition {
        var p = pos
        p.item += delta
        while p.item < 0 {
            guard let prev = previousSection(before: p.section, counts: counts) else { return GridPosition(section: pos.section, item: 0) }
            p = GridPosition(section: prev, item: counts[prev] + p.item)
        }
        while p.item >= counts[p.section] {
            guard let next = nextSection(after: p.section, counts: counts) else {
                return GridPosition(section: pos.section, item: counts[pos.section] - 1)
            }
            p = GridPosition(section: next, item: p.item - counts[p.section])
        }
        return p
    }

    private static func down(_ pos: GridPosition, counts: [Int], columns: Int) -> GridPosition {
        let count = counts[pos.section]
        let column = pos.item % columns
        let lastRow = (count - 1) / columns
        if pos.item / columns < lastRow {
            return GridPosition(section: pos.section, item: min(pos.item + columns, count - 1))
        }
        guard let next = nextSection(after: pos.section, counts: counts) else { return pos }
        return GridPosition(section: next, item: min(column, counts[next] - 1))
    }

    private static func up(_ pos: GridPosition, counts: [Int], columns: Int) -> GridPosition {
        if pos.item >= columns { return GridPosition(section: pos.section, item: pos.item - columns) }
        guard let prev = previousSection(before: pos.section, counts: counts) else { return pos }
        let count = counts[prev]
        let lastRowStart = ((count - 1) / columns) * columns
        return GridPosition(section: prev, item: min(lastRowStart + pos.item % columns, count - 1))
    }

    private static func nextSection(after section: Int, counts: [Int]) -> Int? {
        counts.indices.first { $0 > section && counts[$0] > 0 }
    }

    private static func previousSection(before section: Int, counts: [Int]) -> Int? {
        counts.indices.last { $0 < section && counts[$0] > 0 }
    }
}

/// Picks which alias to show for a query and which characters of it matched.
enum ShortcodeMatcher {
    static func displayShortcode(for emoji: Emoji, query: String) -> String {
        let q = query.lowercased()
        guard !q.isEmpty else { return emoji.id }
        let codes = [emoji.id] + emoji.shortcodes.filter { $0 != emoji.id }
        return codes.first { $0 == q }
            ?? codes.first { $0.hasPrefix(q) }
            ?? codes.first { $0.contains(q) }
            ?? codes.first { matchedOffsets(in: $0, query: q) != nil }
            ?? emoji.id
    }

    /// Character offsets of `query` inside `code`: a contiguous match if there is one, else a subsequence.
    static func matchedOffsets(in code: String, query: String) -> [Int]? {
        let q = query.lowercased()
        guard !q.isEmpty else { return nil }
        let chars = Array(code.lowercased())
        let needle = Array(q)
        if let range = code.lowercased().range(of: q) {
            let start = code.lowercased().distance(from: code.lowercased().startIndex, to: range.lowerBound)
            return Array(start..<(start + needle.count))
        }
        var offsets: [Int] = []
        var j = 0
        for (i, c) in chars.enumerated() where j < needle.count && c == needle[j] {
            offsets.append(i)
            j += 1
        }
        return j == needle.count ? offsets : nil
    }
}
