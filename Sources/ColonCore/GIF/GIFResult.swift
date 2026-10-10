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

    /// A file name for the inserted GIF, derived from the title (never from the user's query).
    public var suggestedFileName: String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let cleaned = String(displayTitle.unicodeScalars.filter { allowed.contains($0) })
            .trimmingCharacters(in: .whitespaces)
        let base = cleaned.isEmpty ? "GIF" : String(cleaned.prefix(60))
        return base + ".gif"
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
