import Foundation

/// Anything that can turn candidates into probabilities. Lets tests inject fakes.
public protocol JevRanking: Sendable {
    /// Returns emoji id -> probability for the given candidates (ids are `Emoji.id`).
    func rank(query: String, context: PredictionContext, candidates: [Emoji]) async throws -> [String: Double]
    /// Opens (or keeps alive) the HTTPS connection so the next `rank` skips DNS/TCP/TLS setup.
    func warmUp() async
}

public extension JevRanking {
    func warmUp() async {}
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

extension JevError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingKey: "No Jev API key"
        case .unauthorized: "Invalid Jev API key"
        case .validation(let message): "Jev rejected the request: \(message)"
        case .rateLimited: "Jev rate limit reached"
        case .overloaded: "Jev is overloaded"
        case .http(let status): "Jev HTTP \(status)"
        case .decoding: "Unexpected Jev response"
        }
    }
}

/// Client for TypeSafe's Jev System One API.
/// POST https://api.typesafe.ai/v1/systemone, `Authorization: Bearer <key>`, model `jev-latest`.
/// Uses one `choice` question over the candidates (max 255 options). OWNER: core worker.
public struct JevClient: JevRanking {
    public static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    public static let model = "jev-latest"
    public static let maxOptions = 255
    public static let timeout: TimeInterval = 1.5

    /// The instruction for the emoji `choice` question. The query and typing context travel in `state`.
    public static let instructions = """
        The user typed an emoji shortcut (state.query, written after a colon, like Slack's :shortcode:) \
        while typing in state.app. Choose the emoji they most likely want to insert right now. \
        The query may be an exact shortcode, the beginning of a word, a typo, slang or an abbreviation \
        (lol, lmao, ty = thank you, gm = good morning, gn = good night, sus = suspicious, ded = dying of \
        laughter, bet = agreed, goat = greatest of all time, bday = birthday, rip = sorrow or a fail). \
        If state.text_before is present it is the message being written; use its tone to pick the fitting \
        emotion. Prefer the emoji people commonly send for this meaning over literal but rarely used ones.
        """

    /// One shared session: keep-alive connection reuse is what makes repeated calls ~150 ms.
    public static let sharedSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = 5
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldUsePipelining = true
        return URLSession(configuration: configuration)
    }()

    private let apiKey: String
    private let session: URLSession

    public init(apiKey: String, session: URLSession = JevClient.sharedSession) {
        self.apiKey = apiKey
        self.session = session
    }

    /// Client for the key in the Keychain / `JEV_API_KEY`, nil when there is none.
    public static func fromKeychain() -> JevClient? {
        KeychainStore.jevAPIKey.map { JevClient(apiKey: $0) }
    }

    public func rank(query: String, context: PredictionContext, candidates: [Emoji]) async throws -> [String: Double] {
        let options = Array(candidates.prefix(Self.maxOptions))
        guard !options.isEmpty else { return [:] }
        let body = Self.rankBody(query: query, context: context, candidates: options)
        let response = try await send(body)

        guard let answer = response.answers["emoji"] else { throw JevError.decoding }
        let allowed = Set(options.map(\.id))
        var probabilities = (answer.probabilities ?? [:]).filter { allowed.contains($0.key) }
        if probabilities.isEmpty, let choice = answer.choice, allowed.contains(choice) {
            probabilities[choice] = answer.confidence ?? 1
        }
        return probabilities
    }

    /// Cheap request used by Settings "Test key". Returns round-trip latency.
    public func ping() async throws -> Duration {
        let clock = ContinuousClock()
        let start = clock.now
        _ = try await send(Self.pingBody())
        return clock.now - start
    }

    /// Unauthenticated HEAD to the API host; any HTTP answer leaves a warm keep-alive connection.
    public func warmUp() async {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 3)
        request.httpMethod = "HEAD"
        _ = try? await session.data(for: request)
    }

    // MARK: - Transport

    private func send(_ body: Data) async throws -> ResponseBody {
        guard !apiKey.isEmpty else { throw JevError.missingKey }
        var request = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: Self.timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw JevError.decoding }
        switch http.statusCode {
        case 200..<300:
            do {
                return try JSONDecoder().decode(ResponseBody.self, from: data)
            } catch {
                throw JevError.decoding
            }
        case 401, 403: throw JevError.unauthorized
        case 422, 400: throw JevError.validation(Self.errorMessage(from: data))
        case 429: throw JevError.rateLimited
        case 529, 503: throw JevError.overloaded
        default: throw JevError.http(http.statusCode)
        }
    }

    /// Best-effort human message from an error body (`{"detail": ...}`, `{"error": {"message": ...}}`, ...).
    static func errorMessage(from data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) {
            if let message = findMessage(in: object) { return String(message.prefix(300)) }
        }
        let text = String(decoding: data.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "invalid request" : text
    }

    private static func findMessage(in object: Any) -> String? {
        if let text = object as? String { return text }
        if let dictionary = object as? [String: Any] {
            for key in ["message", "detail", "error", "msg"] {
                if let value = dictionary[key], let message = findMessage(in: value) { return message }
            }
        }
        if let array = object as? [Any] {
            let messages = array.compactMap { findMessage(in: $0) }
            if !messages.isEmpty { return messages.joined(separator: "; ") }
        }
        return nil
    }

    // MARK: - Encoding

    /// Option text for an emoji: `"<char> <name>; <keywords>"`.
    public static func criterion(for emoji: Emoji, maxKeywords: Int = 8) -> String {
        let nameWords = Set(EmojiStore.words(in: emoji.name))
        let extra = emoji.keywords.filter { !nameWords.contains($0) }.prefix(maxKeywords)
        var text = "\(emoji.char) \(emoji.name)"
        if !extra.isEmpty { text += "; " + extra.joined(separator: ", ") }
        return text
    }

    /// The request body, built by hand so `criteria` keeps candidate order (Foundation's JSON
    /// encoders do not guarantee key order), which keeps requests deterministic and cacheable.
    static func rankBody(query: String, context: PredictionContext, candidates: [Emoji]) -> Data {
        var json = "{\"model\":"
        appendString(Self.model, to: &json)
        json += ",\"state\":{"
        var fields: [(String, String)] = []
        if let app = context.appName ?? context.bundleID, !app.isEmpty { fields.append(("app", app)) }
        if let text = context.textBeforeTrigger?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            fields.append(("text_before", String(text.suffix(300))))
        }
        fields.append(("query", query))
        for (index, field) in fields.enumerated() {
            if index > 0 { json += "," }
            appendString(field.0, to: &json)
            json += ":"
            appendString(field.1, to: &json)
        }
        json += "},\"questions\":{\"emoji\":{\"type\":\"choice\",\"instructions\":"
        appendString(instructions, to: &json)
        json += ",\"criteria\":{"
        for (index, emoji) in candidates.enumerated() {
            if index > 0 { json += "," }
            appendString(emoji.id, to: &json)
            json += ":"
            appendString(criterion(for: emoji), to: &json)
        }
        json += "}}}}"
        return Data(json.utf8)
    }

    static func pingBody() -> Data {
        Data("""
        {"model":"\(model)","state":"Emojify connection test","questions":{"ok":{"type":"noul",\
        "instructions":"Is this a connection test?"}}}
        """.utf8)
    }

    /// Appends `value` as a JSON string literal.
    static func appendString(_ value: String, to json: inout String) {
        json.unicodeScalars.append("\"")
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": json += "\\\""
            case "\\": json += "\\\\"
            case "\n": json += "\\n"
            case "\r": json += "\\r"
            case "\t": json += "\\t"
            case let s where s.value < 0x20 || s.value == 0x2028 || s.value == 0x2029:
                json += String(format: "\\u%04x", s.value)
            default:
                json.unicodeScalars.append(scalar)
            }
        }
        json.unicodeScalars.append("\"")
    }

    // MARK: - Decoding

    struct ResponseBody: Decodable {
        let model: String?
        let answers: [String: Answer]
    }

    struct Answer: Decodable {
        let type: String?
        let choice: String?
        let confidence: Double?
        let probabilities: [String: Double]?
        let probability: Double?
    }
}
