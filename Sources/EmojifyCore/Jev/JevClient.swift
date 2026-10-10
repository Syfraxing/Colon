import Foundation

/// Anything that can turn candidates into probabilities. Lets tests inject fakes.
public protocol JevRanking: Sendable {
    /// Returns emoji id -> probability for the given candidates (ids are `Emoji.id`).
    func rank(query: String, context: PredictionContext, candidates: [Emoji]) async throws -> [String: Double]
}

public enum JevError: Error, Equatable, Sendable {
    case missingKey
    case unauthorized          // 401
    case validation(String)    // 422
    case rateLimited           // 429
    case overloaded            // 529
    case http(Int)
    case decoding
}

/// Client for TypeSafe's Jev System One API.
/// POST https://api.typesafe.ai/v1/systemone, `Authorization: Bearer <key>`, model `jev-latest`.
/// Uses one `choice` question over the candidates (max 255 options). OWNER: core worker.
public struct JevClient: JevRanking {
    public static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    public static let model = "jev-latest"

    private let apiKey: String
    private let session: URLSession

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    public func rank(query: String, context: PredictionContext, candidates: [Emoji]) async throws -> [String: Double] {
        // SCAFFOLD
        throw JevError.missingKey
    }

    /// Cheap request used by Settings "Test key". Returns round-trip latency.
    public func ping() async throws -> Duration {
        // SCAFFOLD
        throw JevError.missingKey
    }
}
