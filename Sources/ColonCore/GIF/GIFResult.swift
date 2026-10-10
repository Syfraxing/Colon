import Foundation

/// One rendition of a GIF (a URL plus its pixel size).
public struct GIFRendition: Hashable, Sendable {
    public let url: URL
    public let width: Int
    public let height: Int
    /// Bytes, when the provider reports it.
    public let byteCount: Int?

    public init(url: URL, width: Int, height: Int, byteCount: Int? = nil) {
        self.url = url
        self.width = width
        self.height = height
        self.byteCount = byteCount
    }

    /// Width / height, 1 when the provider did not report a size.
    public var aspectRatio: Double {
        guard width > 0, height > 0 else { return 1 }
        return Double(width) / Double(height)
    }
}

/// A GIF search result, independent of the provider.
public struct GIFResult: Identifiable, Hashable, Sendable {
    /// Provider id, unique within a result list.
    public let id: String
    /// Short human title, e.g. "Happy Dance GIF by Disney". May be empty.
    public let title: String
    /// Descriptive words (slug words, alt text keywords). Used for Jev criteria and accessibility.
    public let tags: [String]
    /// Small animated rendition for the grid.
    public let preview: GIFRendition
    /// The GIF that gets inserted.
    public let full: GIFRendition

    public init(id: String, title: String, tags: [String], preview: GIFRendition, full: GIFRendition) {
        self.id = id
        self.title = title
        self.tags = tags
        self.preview = preview
        self.full = full
    }

    /// Title without the provider's " GIF" / " GIF by <user>" suffix: "Happy Dance".
    public var displayTitle: String {
        var text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = text.range(of: " GIF by ", options: [.caseInsensitive, .backwards]) {
            text = String(text[..<range.lowerBound])
        } else if text.lowercased().hasSuffix(" gif") {
            text = String(text.dropLast(4))
        } else if text.caseInsensitiveCompare("gif") == .orderedSame {
            text = ""
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// File name for the inserted copy: `giphy-<id>.gif` (never derived from the user's query).
    public var fileName: String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let safeID = String(id.unicodeScalars.filter { allowed.contains($0) }.prefix(64))
        return "giphy-\(safeID.isEmpty ? "gif" : safeID).gif"
    }
}

/// Errors from a GIF provider. Server bodies are never surfaced.
public enum GIFError: Error, Equatable, Sendable {
    case missingKey
    case unauthorized          // 401 / 403
    case rateLimited           // 429
    case http(Int)
    case decoding
}

extension GIFError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingKey: "No GIPHY API key"
        case .unauthorized: "GIPHY rejected the API key"
        case .rateLimited: "GIPHY rate limit reached"
        case .http(let status): "GIPHY HTTP \(status)"
        case .decoding: "Unexpected GIPHY response"
        }
    }
}

/// Anything that can search GIFs. Lets the app and tests swap providers.
public protocol GIFSearching: Sendable {
    /// Results for `terms`, provider order.
    func search(_ terms: String, limit: Int) async throws -> [GIFResult]
    /// What is popular right now (shown before the user types).
    func trending(limit: Int) async throws -> [GIFResult]
}

/// GIPHY content rating, chosen in Settings → GIFs. Stored in `UserDefaults` under `defaultsKey`.
public enum GIFRating: String, CaseIterable, Sendable, Identifiable {
    case g
    case pg
    case pg13 = "pg-13"
    case r

    public static let defaultsKey = "gifRating"
    public static let `default` = GIFRating.pg13

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .g: "G"
        case .pg: "PG"
        case .pg13: "PG-13"
        case .r: "R"
        }
    }

    /// The saved rating, `.pg13` when unset or unknown.
    public static func current(_ defaults: UserDefaults = .standard) -> GIFRating {
        defaults.string(forKey: defaultsKey).flatMap(GIFRating.init(rawValue:)) ?? .default
    }
}

/// Keyboard movement in the GIF grid.
public enum GIFGrid {
    /// ←/→ step through results (wrapping across rows); ↑/↓ move by a row and stop at the edges,
    /// except ↓ from the row above a shorter last row lands on the last result.
    public static func index(after current: Int, dx: Int, dy: Int, count: Int, columns: Int) -> Int {
        guard count > 0, columns > 0 else { return 0 }
        let current = min(max(current, 0), count - 1)
        var next = current + dx
        if dy != 0 {
            let candidate = current + dy * columns
            if (0..<count).contains(candidate) {
                next = candidate
            } else if dy > 0, current / columns < (count - 1) / columns {
                next = count - 1
            } else {
                next = current
            }
        }
        return min(max(next, 0), count - 1)
    }
}
