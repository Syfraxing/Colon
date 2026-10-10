import Foundation

/// Scores GIF results for the user's search. Lets tests inject fakes.
public protocol GIFRanking: Sendable {
    /// Returns result id -> probability for `results` (ids are `GIFResult.id`).
    func rank(terms: String, context: PredictionContext, results: [GIFResult]) async throws -> [String: Double]
}

/// Asks Jev one `choice` question over the result ids, with each GIF's title and tags as criteria.
public struct JevGIFRanker: GIFRanking {
    /// A GIF answer may take longer than an emoji one: the provider's order is already on screen.
    public static let timeout: TimeInterval = 2.5

    public static let instructions = """
        The user is searching for a GIF to send. state.query is what they typed into the GIF search \
        while writing in state.app. Each option describes one GIF by its title and tags. Choose the GIF \
        that best expresses what they want to say: match the meaning, mood and reaction behind the \
        search, not only the literal words. If state.text_before is present it is the message being \
        written; use its tone. Prefer clear, widely understood reaction GIFs over obscure ones.
        """

    private let apiKey: String
    private let session: URLSession

    public init(apiKey: String, session: URLSession = JevClient.sharedSession) {
        self.apiKey = apiKey
        self.session = session
    }

    public func rank(terms: String, context: PredictionContext, results: [GIFResult]) async throws -> [String: Double] {
        let options = Array(results.prefix(JevClient.maxOptions))
        guard !options.isEmpty else { return [:] }
        guard !apiKey.isEmpty else { throw JevError.missingKey }

        var request = URLRequest(url: JevClient.endpoint, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: Self.timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Self.rankBody(terms: terms, context: context, results: options)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw JevError.decoding }
        switch http.statusCode {
        case 200..<300: break
        case 401, 403: throw JevError.unauthorized
        case 422, 400: throw JevError.validation
        case 429: throw JevError.rateLimited
        case 529, 503: throw JevError.overloaded
        default: throw JevError.http(http.statusCode)
        }
        let body: JevClient.ResponseBody
        do {
            body = try JSONDecoder().decode(JevClient.ResponseBody.self, from: data)
        } catch {
            throw JevError.decoding
        }
        guard let answer = body.answers["gif"] else { throw JevError.decoding }
        let allowed = Set(options.map(\.id))
        var probabilities = (answer.probabilities ?? [:]).filter { allowed.contains($0.key) }
        if probabilities.isEmpty, let choice = answer.choice, allowed.contains(choice) {
            probabilities[choice] = answer.confidence ?? 1
        }
        return probabilities
    }

    /// Option text: `"<title>; <tag>, <tag>"`, bounded so 24 options stay a small request.
    public static func criterion(for result: GIFResult, maxTags: Int = 8) -> String {
        let title = result.displayTitle
        let titleWords = Set(title.lowercased().split(separator: " ").map(String.init))
        let tags = result.tags.filter { !titleWords.contains($0) }.prefix(maxTags)
        var text = title.isEmpty ? "GIF" : title
        if !tags.isEmpty { text += "; " + tags.joined(separator: ", ") }
        return String(text.prefix(160))
    }

    /// Built by hand like `JevClient.rankBody` so `criteria` keeps provider order.
    static func rankBody(terms: String, context: PredictionContext, results: [GIFResult]) -> Data {
        var json = "{\"model\":"
        JevClient.appendString(JevClient.model, to: &json)
        json += ",\"state\":{"
        var fields: [(String, String)] = []
        if let app = context.appName ?? context.bundleID, !app.isEmpty { fields.append(("app", app)) }
        if let text = context.textBeforeTrigger?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            fields.append(("text_before", String(text.suffix(300))))
        }
        fields.append(("query", terms))
        for (index, field) in fields.enumerated() {
            if index > 0 { json += "," }
            JevClient.appendString(field.0, to: &json)
            json += ":"
            JevClient.appendString(field.1, to: &json)
        }
        json += "},\"questions\":{\"gif\":{\"type\":\"choice\",\"instructions\":"
        JevClient.appendString(instructions, to: &json)
        json += ",\"criteria\":{"
        for (index, result) in results.enumerated() {
            if index > 0 { json += "," }
            JevClient.appendString(result.id, to: &json)
            json += ":"
            JevClient.appendString(criterion(for: result), to: &json)
        }
        json += "}}}}"
        return Data(json.utf8)
    }
}

/// Blending Jev's answer into the provider's order.
public enum GIFRerank {
    /// Weight of Jev's probability against the provider's position (the provider is a good
    /// relevance signal on its own, so it keeps 30%).
    public static let jevWeight = 0.7

    /// Orders `results` by `jevWeight * p / maxP + (1 - jevWeight) * positionScore`, where the
    /// provider's first result has position score 1 and the last 0. Stable for ties; results Jev
    /// did not score keep their provider position relative to each other.
    public static func reorder(_ results: [GIFResult], probabilities: [String: Double],
                               jevWeight: Double = GIFRerank.jevWeight) -> [GIFResult] {
        guard results.count > 1, let maxProbability = probabilities.values.max(), maxProbability > 0 else {
            return results
        }
        let last = Double(results.count - 1)
        let scored = results.enumerated().map { index, result -> (Int, Double, GIFResult) in
            let jev = (probabilities[result.id] ?? 0) / maxProbability
            let position = 1 - Double(index) / last
            return (index, jevWeight * jev + (1 - jevWeight) * position, result)
        }
        return scored.sorted { lhs, rhs in
            lhs.1 != rhs.1 ? lhs.1 > rhs.1 : lhs.0 < rhs.0
        }.map(\.2)
    }

    /// Asks `ranker` and returns the blended order, or nil when there is nothing to change
    /// (no terms, a single result, an error, or an answer that keeps the same order).
    public static func rerank(_ results: [GIFResult], terms: String, context: PredictionContext,
                              ranker: GIFRanking) async -> [GIFResult]? {
        let trimmed = terms.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, results.count > 1 else { return nil }
        guard let probabilities = try? await ranker.rank(terms: trimmed, context: context, results: results),
              !Task.isCancelled else { return nil }
        let reordered = reorder(results, probabilities: probabilities)
        return reordered.map(\.id) == results.map(\.id) ? nil : reordered
    }
}
