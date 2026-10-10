import XCTest
@testable import ColonCore

/// Intercepts requests made through a session configured with it.
final class MockURLProtocol: URLProtocol {
    struct Stub {
        var status: Int
        var body: Data
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var stub = Stub(status: 200, body: Data())
    nonisolated(unsafe) private static var captured: [URLRequest] = []
    nonisolated(unsafe) private static var capturedBodies: [Data] = []

    static func respond(status: Int, json: String) {
        lock.withLock {
            stub = Stub(status: status, body: Data(json.utf8))
            captured = []
            capturedBodies = []
        }
    }

    static var lastRequest: URLRequest? { lock.withLock { captured.last } }
    static var lastBody: Data? { lock.withLock { capturedBodies.last } }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
        let stub = Self.lock.withLock {
            Self.captured.append(request)
            Self.capturedBodies.append(body)
            return Self.stub
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: stub.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

final class JevClientTests: XCTestCase {
    private let sampleResponse = """
    {"model":"jev-1.13.0","answers":{"emoji":{"type":"choice","choice":"joy","confidence":0.48,\
    "probabilities":{"joy":0.57,"rofl":0.25,"laughing":0.1,"not_a_candidate":0.08}}},\
    "usage":{"input_tokens":448,"output_tokens":66}}
    """

    private func candidates(_ ids: [String]) -> [Emoji] {
        ids.compactMap { EmojiStore.shared.emoji(id: $0) }
    }

    func testRequestEncoding() async throws {
        MockURLProtocol.respond(status: 200, json: sampleResponse)
        let client = JevClient(apiKey: "test-key", session: MockURLProtocol.session())
        let context = PredictionContext(appName: "Messages", bundleID: "com.apple.MobileSMS",
                                        textBeforeTrigger: "lmao that video was \"insane\"\n")
        _ = try await client.rank(query: "haha", context: context, candidates: candidates(["joy", "rofl", "laughing"]))

        let request = try XCTUnwrap(MockURLProtocol.lastRequest)
        XCTAssertEqual(request.url, JevClient.endpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.timeoutInterval, 1.5)

        let body = try XCTUnwrap(MockURLProtocol.lastBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "jev-latest")
        let state = try XCTUnwrap(json["state"] as? [String: String])
        XCTAssertEqual(state, ["app": "Messages", "text_before": "lmao that video was \"insane\"", "query": "haha"])
        let questions = try XCTUnwrap(json["questions"] as? [String: Any])
        let emoji = try XCTUnwrap(questions["emoji"] as? [String: Any])
        XCTAssertEqual(emoji["type"] as? String, "choice")
        XCTAssertEqual(emoji["instructions"] as? String, JevClient.instructions)
        let criteria = try XCTUnwrap(emoji["criteria"] as? [String: String])
        XCTAssertEqual(Set(criteria.keys), ["joy", "rofl", "laughing"])
        XCTAssertTrue(try XCTUnwrap(criteria["joy"]).hasPrefix("😂 face with tears of joy; "))

        // Candidate order is preserved in the raw body.
        let text = String(decoding: body, as: UTF8.self)
        let joy = try XCTUnwrap(text.range(of: "\"joy\":"))
        let rofl = try XCTUnwrap(text.range(of: "\"rofl\":"))
        XCTAssertLessThan(joy.lowerBound, rofl.lowerBound)
    }

    func testOmitsEmptyContext() async throws {
        MockURLProtocol.respond(status: 200, json: sampleResponse)
        let client = JevClient(apiKey: "k", session: MockURLProtocol.session())
        _ = try await client.rank(query: "joy", context: PredictionContext(), candidates: candidates(["joy"]))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(MockURLProtocol.lastBody)) as? [String: Any])
        XCTAssertEqual(json["state"] as? [String: String], ["query": "joy"])
    }

    func testResponseDecodingKeepsOnlyCandidates() async throws {
        MockURLProtocol.respond(status: 200, json: sampleResponse)
        let client = JevClient(apiKey: "k", session: MockURLProtocol.session())
        let result = try await client.rank(query: "haha", context: PredictionContext(appName: "Messages"),
                                           candidates: candidates(["joy", "rofl", "laughing"]))
        XCTAssertEqual(result, ["joy": 0.57, "rofl": 0.25, "laughing": 0.1])
    }

    func testChoiceWithoutProbabilitiesFallsBackToConfidence() async throws {
        MockURLProtocol.respond(status: 200, json: #"{"answers":{"emoji":{"type":"choice","choice":"rofl","confidence":0.6}}}"#)
        let client = JevClient(apiKey: "k", session: MockURLProtocol.session())
        let result = try await client.rank(query: "x", context: PredictionContext(), candidates: candidates(["joy", "rofl"]))
        XCTAssertEqual(result, ["rofl": 0.6])
    }

    func testCapsOptionsAt255() async throws {
        MockURLProtocol.respond(status: 200, json: sampleResponse)
        let client = JevClient(apiKey: "k", session: MockURLProtocol.session())
        _ = try await client.rank(query: "a", context: PredictionContext(), candidates: Array(EmojiStore.shared.all.prefix(400)))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(MockURLProtocol.lastBody)) as? [String: Any])
        let criteria = (json["questions"] as? [String: Any])?["emoji"] as? [String: Any]
        XCTAssertEqual((criteria?["criteria"] as? [String: String])?.count, 255)
    }

    func testErrorMapping() async {
        let cases: [(Int, JevError)] = [(401, .unauthorized), (422, .validation), (429, .rateLimited),
                                         (529, .overloaded), (500, .http(500))]
        let client = JevClient(apiKey: "k", session: MockURLProtocol.session())
        for (status, expected) in cases {
            MockURLProtocol.respond(status: status, json: #"{"detail":"secret server detail"}"#)
            do {
                _ = try await client.rank(query: "joy", context: PredictionContext(), candidates: candidates(["joy"]))
                XCTFail("expected \(expected)")
            } catch let error as JevError {
                XCTAssertEqual(error, expected)
                XCTAssertFalse(error.localizedDescription.contains("secret"))
            } catch {
                XCTFail("unexpected \(error)")
            }
        }
    }

    func testMalformedResponseIsDecodingError() async {
        MockURLProtocol.respond(status: 200, json: "{\"nope\":true}")
        let client = JevClient(apiKey: "k", session: MockURLProtocol.session())
        do {
            _ = try await client.rank(query: "joy", context: PredictionContext(), candidates: candidates(["joy"]))
            XCTFail("expected decoding error")
        } catch {
            XCTAssertEqual(error as? JevError, .decoding)
        }
    }

    func testMissingKey() async {
        let client = JevClient(apiKey: "", session: MockURLProtocol.session())
        do {
            _ = try await client.ping()
            XCTFail("expected missingKey")
        } catch {
            XCTAssertEqual(error as? JevError, .missingKey)
        }
    }

    func testPingSendsNoulQuestion() async throws {
        MockURLProtocol.respond(status: 200, json: #"{"model":"jev-1.13.0","answers":{"ok":{"type":"noul","probability":0.97}}}"#)
        let client = JevClient(apiKey: "k", session: MockURLProtocol.session())
        let latency = try await client.ping()
        XCTAssertGreaterThanOrEqual(latency, .zero)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(MockURLProtocol.lastBody)) as? [String: Any])
        let ok = (json["questions"] as? [String: Any])?["ok"] as? [String: Any]
        XCTAssertEqual(ok?["type"] as? String, "noul")
        XCTAssertNotNil(ok?["instructions"] as? String)
    }

    func testJSONStringEscaping() throws {
        var json = ""
        JevClient.appendString("a\"b\\c\nd\u{1}e😂", to: &json)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(json.utf8), options: .fragmentsAllowed) as? String,
                       "a\"b\\c\nd\u{1}e😂")
    }

    func testSharedSessionIsEphemeral() {
        let configuration = JevClient.sharedSession.configuration
        XCTAssertNil(configuration.urlCache)
        XCTAssertEqual(configuration.httpMaximumConnectionsPerHost, 4)
    }

    /// Live round trip; runs only when `JEV_API_KEY` is set (never commit a key).
    func testLiveRank() async throws {
        guard let key = ProcessInfo.processInfo.environment["JEV_API_KEY"], !key.isEmpty else {
            throw XCTSkip("set JEV_API_KEY to run live Jev tests")
        }
        let client = JevClient(apiKey: key)
        _ = try await client.ping()
        let result = try await client.rank(query: "haha", context: PredictionContext(appName: "Messages"),
                                           candidates: candidates(PopularEmoji.ids))
        XCTAssertFalse(result.isEmpty)
        let top = result.max { $0.value < $1.value }?.key
        XCTAssertTrue(["joy", "rofl", "laughing", "sweat_smile"].contains(top ?? ""), "top: \(top ?? "nil")")
    }
}
