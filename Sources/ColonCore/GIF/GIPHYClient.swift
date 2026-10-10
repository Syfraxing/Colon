import Foundation

/// Client for the GIPHY API (https://developers.giphy.com/docs/api). Bring-your-own key: a free
/// beta key from the GIPHY developer dashboard allows 100 calls an hour. Requests always ask
/// for `rating=pg-13`. The app must show "Powered by GIPHY" wherever results appear.
///
/// The key travels as the `api_key` query item, so request URLs are never logged.
public struct GIPHYClient: GIFSearching {
    public static let baseURL = URL(string: "https://api.giphy.com/v1/gifs")!
    public static let dashboardURL = URL(string: "https://developers.giphy.com/dashboard/")!
    public static let rating = "pg-13"
    public static let defaultLimit = 24
    public static let timeout: TimeInterval = 6
    /// GIFs larger than this are inserted as GIPHY's downsized rendition instead of the original.
    public static let maxInsertBytes = 6_000_000

    /// One shared session. Responses are tiny JSON; nothing is cached.
    public static let sharedSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout + 4
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    private let apiKey: String
    private let session: URLSession
    private let language: String

    public init(apiKey: String, session: URLSession = GIPHYClient.sharedSession,
                language: String = GIPHYClient.preferredLanguage()) {
        self.apiKey = apiKey
        self.session = session
        self.language = language
    }

    /// Client for the key in the Keychain, nil when there is none. Call off the main thread.
    public static func fromKeychain() -> GIPHYClient? {
        KeychainStore.key(for: .gif).map { GIPHYClient(apiKey: $0) }
    }

    public func search(_ terms: String, limit: Int = GIPHYClient.defaultLimit) async throws -> [GIFResult] {
        let trimmed = terms.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return try await trending(limit: limit) }
        return try await fetch(searchRequest(terms: trimmed, limit: limit))
    }

    public func trending(limit: Int = GIPHYClient.defaultLimit) async throws -> [GIFResult] {
        try await fetch(trendingRequest(limit: limit))
    }

    /// Cheap request for Settings "Test": one trending result. Returns round-trip latency.
    public func ping() async throws -> Duration {
        let clock = ContinuousClock()
        let start = clock.now
        _ = try await fetch(trendingRequest(limit: 1))
        return clock.now - start
    }

    // MARK: Requests

    func searchRequest(terms: String, limit: Int, offset: Int = 0) -> URLRequest {
        request(path: "search", items: [
            URLQueryItem(name: "q", value: String(terms.prefix(50))),
            URLQueryItem(name: "limit", value: String(Self.clampedLimit(limit))),
            URLQueryItem(name: "offset", value: String(max(0, offset))),
            URLQueryItem(name: "rating", value: Self.rating),
            URLQueryItem(name: "lang", value: language),
            URLQueryItem(name: "bundle", value: "messaging_non_clips"),
        ])
    }

    func trendingRequest(limit: Int) -> URLRequest {
        request(path: "trending", items: [
            URLQueryItem(name: "limit", value: String(Self.clampedLimit(limit))),
            URLQueryItem(name: "rating", value: Self.rating),
            URLQueryItem(name: "bundle", value: "messaging_non_clips"),
        ])
    }

    private func request(path: String, items: [URLQueryItem]) -> URLRequest {
        var components = URLComponents(url: Self.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "api_key", value: apiKey)] + items
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: Self.timeout)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    static func clampedLimit(_ limit: Int) -> Int {
        min(max(limit, 1), 50)
    }

    /// Two-letter language code GIPHY understands, from the user's preferred languages.
    public static func preferredLanguage() -> String {
        let code = Locale.preferredLanguages.first.flatMap { Locale(identifier: $0).language.languageCode?.identifier }
        guard let code, code.count == 2 else { return "en" }
        return code
    }

    // MARK: Transport

    private func fetch(_ request: URLRequest) async throws -> [GIFResult] {
        guard !apiKey.isEmpty else { throw GIFError.missingKey }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GIFError.decoding }
        switch http.statusCode {
        case 200..<300:
            return try Self.decode(data)
        case 401, 403: throw GIFError.unauthorized
        case 429: throw GIFError.rateLimited
        default: throw GIFError.http(http.statusCode)
        }
    }

    // MARK: Decoding

    static func decode(_ data: Data) throws -> [GIFResult] {
        let body: ResponseBody
        do {
            body = try JSONDecoder().decode(ResponseBody.self, from: data)
        } catch {
            throw GIFError.decoding
        }
        if let status = body.meta?.status, !(200..<300).contains(status) {
            switch status {
            case 401, 403: throw GIFError.unauthorized
            case 429: throw GIFError.rateLimited
            default: throw GIFError.http(status)
            }
        }
        var seen = Set<String>()
        return (body.data?.elements ?? []).compactMap { item -> GIFResult? in
            guard seen.insert(item.id).inserted, let result = result(from: item) else { return nil }
            return result
        }
    }

    static func result(from item: Item) -> GIFResult? {
        guard item.type == nil || item.type == "gif", let images = item.images else { return nil }
        let previewCandidates = [images.fixed_width, images.fixed_height, images.downsized, images.original]
        guard let preview = previewCandidates.lazy.compactMap({ $0?.rendition }).first else { return nil }
        let original = images.original?.rendition
        let full: GIFRendition?
        if let original, (original.byteCount ?? 0) <= maxInsertBytes {
            full = original
        } else {
            full = [images.downsized_medium, images.downsized, images.original].lazy.compactMap { $0?.rendition }.first
        }
        guard let full else { return nil }
        return GIFResult(id: item.id, title: item.title ?? "", tags: tags(slug: item.slug, id: item.id),
                         preview: preview, full: full)
    }

    /// `happy-dance-xT9IgG50Fb7Mi0prBC` → `["happy", "dance"]`.
    static func tags(slug: String?, id: String) -> [String] {
        guard var slug, !slug.isEmpty else { return [] }
        if slug.hasSuffix(id) { slug.removeLast(id.count) }
        var seen = Set<String>()
        return slug.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map(String.init)
            .filter { !$0.isEmpty && $0 != "gif" && seen.insert($0).inserted }
    }

    struct ResponseBody: Decodable {
        let data: Lossy<Item>?
        let meta: Meta?
    }

    struct Meta: Decodable {
        let status: Int?
    }

    struct Item: Decodable {
        let type: String?
        let id: String
        let slug: String?
        let title: String?
        let images: Images?
    }

    // swiftlint:disable identifier_name
    struct Images: Decodable {
        let fixed_width: Image?
        let fixed_height: Image?
        let downsized: Image?
        let downsized_medium: Image?
        let original: Image?
    }
    // swiftlint:enable identifier_name

    struct Image: Decodable {
        let url: String?
        let width: FlexibleInt?
        let height: FlexibleInt?
        let size: FlexibleInt?

        var rendition: GIFRendition? {
            guard let url, let parsed = URL(string: url), parsed.scheme == "https" else { return nil }
            return GIFRendition(url: parsed, width: width?.value ?? 0, height: height?.value ?? 0,
                                byteCount: size?.value)
        }
    }

    /// GIPHY sends sizes as strings ("200"); accept numbers too. Anything else reads as nil.
    struct FlexibleInt: Decodable {
        let value: Int?

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let int = try? container.decode(Int.self) {
                value = int
            } else if let string = try? container.decode(String.self) {
                value = Int(string)
            } else {
                value = nil
            }
        }
    }

    /// Decodes an array, dropping elements that fail instead of failing the whole response.
    struct Lossy<Element: Decodable>: Decodable {
        let elements: [Element]

        init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            var elements: [Element] = []
            while !container.isAtEnd {
                if let element = try? container.decode(Element.self) {
                    elements.append(element)
                } else {
                    _ = try? container.decode(Skip.self)
                }
            }
            self.elements = elements
        }

        /// Accepts any JSON value, so a bad element is consumed and decoding moves on.
        private struct Skip: Decodable {
            init(from decoder: Decoder) throws {}
        }
    }
}
