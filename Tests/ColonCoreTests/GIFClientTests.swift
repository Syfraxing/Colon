import XCTest
@testable import ColonCore

final class GIFClientTests: XCTestCase {
    /// Trimmed from a real GIPHY search response: sizes are strings, one item is a clip, one is broken.
    private let sampleResponse = """
    {"data":[
      {"type":"gif","id":"l0MYt5jPR6QX5pnqM","slug":"happy-dance-l0MYt5jPR6QX5pnqM","title":"Happy Dance GIF by Disney",
       "images":{
         "fixed_width_small":{"url":"https://media2.giphy.com/media/l0MYt5jPR6QX5pnqM/100w.gif?cid=abc&rid=100w.gif&ct=g","width":"100","height":"75","size":"81234"},
         "fixed_width":{"url":"https://media2.giphy.com/media/l0MYt5jPR6QX5pnqM/200w.gif","width":"200","height":"150"},
         "downsized_medium":{"url":"https://media2.giphy.com/media/l0MYt5jPR6QX5pnqM/giphy.gif?cid=abc&rid=giphy.gif&ct=g","width":"480","height":"360","size":"2345678"},
         "original":{"url":"https://media2.giphy.com/media/l0MYt5jPR6QX5pnqM/giphy.gif","width":"480","height":"360","size":"9999999"}}},
      {"type":"video","id":"clip1","slug":"clip-clip1","title":"A clip","images":{}},
      {"type":"gif","id":"broken","title":"No images"},
      {"type":"gif","id":"3o7abKhOpu0NwenH3O","slug":"excited-3o7abKhOpu0NwenH3O","title":"Excited GIF",
       "images":{
         "fixed_width_small":{"url":"https://media0.giphy.com/media/3o7abKhOpu0NwenH3O/100w.gif","width":100,"height":100},
         "downsized":{"url":"https://media0.giphy.com/media/3o7abKhOpu0NwenH3O/giphy-downsized.gif","width":"250","height":"250","size":"1500000"}}},
      {"type":"gif","id":"l0MYt5jPR6QX5pnqM","slug":"dup","title":"Duplicate",
       "images":{"fixed_width_small":{"url":"https://example.com/a.gif"},"downsized_medium":{"url":"https://example.com/b.gif"}}}
    ],
    "pagination":{"total_count":2,"count":5,"offset":0},
    "meta":{"status":200,"msg":"OK","response_id":"xyz"}}
    """

    func testSearchRequestBuilding() async throws {
        MockURLProtocol.respond(status: 200, json: sampleResponse)
        let client = GIPHYClient(apiKey: "test-key", rating: .pg13, session: MockURLProtocol.session(), language: "en")
        _ = try await client.search("  happy dance  ", limit: 24)

        let request = try XCTUnwrap(MockURLProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "GET")
        let url = try XCTUnwrap(request.url)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "api.giphy.com")
        XCTAssertEqual(components.path, "/v1/gifs/search")
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["api_key"], "test-key")
        XCTAssertEqual(items["q"], "happy dance")
        XCTAssertEqual(items["limit"], "24")
        XCTAssertEqual(items["offset"], "0")
        XCTAssertEqual(items["rating"], "pg-13")
        XCTAssertEqual(items["lang"], "en")
        XCTAssertNil(items["random_id"], "no per-user tracking id")
    }

    func testRatingAndTrendingRequest() async throws {
        MockURLProtocol.respond(status: 200, json: sampleResponse)
        let client = GIPHYClient(apiKey: "k", rating: .g, session: MockURLProtocol.session())
        _ = try await client.search("", limit: 500)

        let url = try XCTUnwrap(MockURLProtocol.lastRequest?.url)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.path, "/v1/gifs/trending", "empty terms show trending")
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["rating"], "g")
        XCTAssertEqual(items["limit"], "50", "limit is clamped to GIPHY's maximum")
        XCTAssertNil(items["q"])
    }

    func testResponseDecoding() async throws {
        MockURLProtocol.respond(status: 200, json: sampleResponse)
        let client = GIPHYClient(apiKey: "k", session: MockURLProtocol.session())
        let results = try await client.search("dance", limit: 24)

        XCTAssertEqual(results.map(\.id), ["l0MYt5jPR6QX5pnqM", "3o7abKhOpu0NwenH3O"],
                       "clips, broken items and duplicates are dropped")
        let first = results[0]
        XCTAssertEqual(first.title, "Happy Dance GIF by Disney")
        XCTAssertEqual(first.displayTitle, "Happy Dance")
        XCTAssertEqual(first.tags, ["happy", "dance"])
        XCTAssertEqual(first.preview.url.absoluteString,
                       "https://media2.giphy.com/media/l0MYt5jPR6QX5pnqM/100w.gif?cid=abc&rid=100w.gif&ct=g",
                       "grid uses fixed_width_small, URL untouched")
        XCTAssertEqual(first.preview.width, 100)
        XCTAssertEqual(first.preview.height, 75)
        XCTAssertEqual(first.full.url.absoluteString,
                       "https://media2.giphy.com/media/l0MYt5jPR6QX5pnqM/giphy.gif?cid=abc&rid=giphy.gif&ct=g",
                       "insert uses downsized_medium")
        XCTAssertEqual(first.full.width, 480)
        XCTAssertEqual(first.full.byteCount, 2_345_678)
        XCTAssertEqual(first.fileName, "giphy-l0MYt5jPR6QX5pnqM.gif")

        let second = results[1]
        XCTAssertEqual(second.displayTitle, "Excited")
        XCTAssertEqual(second.preview.width, 100, "numeric sizes decode too")
        XCTAssertEqual(second.full.url.lastPathComponent, "giphy-downsized.gif", "falls back to downsized")
    }

    func testHTTPErrorsMapToTypedErrors() async {
        let cases: [(Int, GIFError)] = [(401, .unauthorized), (403, .unauthorized), (429, .rateLimited), (500, .http(500))]
        for (status, expected) in cases {
            MockURLProtocol.respond(status: status, json: #"{"meta":{"status":\#(status),"msg":"secret server detail"}}"#)
            let client = GIPHYClient(apiKey: "k", session: MockURLProtocol.session())
            do {
                _ = try await client.search("hi", limit: 5)
                XCTFail("expected \(expected)")
            } catch {
                XCTAssertEqual(error as? GIFError, expected)
            }
        }
    }

    func testMetaStatusErrorAndGarbage() {
        XCTAssertThrowsError(try GIPHYClient.decode(Data(#"{"data":[],"meta":{"status":429}}"#.utf8))) {
            XCTAssertEqual($0 as? GIFError, .rateLimited)
        }
        XCTAssertThrowsError(try GIPHYClient.decode(Data("not json".utf8))) {
            XCTAssertEqual($0 as? GIFError, .decoding)
        }
        XCTAssertEqual(try GIPHYClient.decode(Data(#"{"data":[]}"#.utf8)), [])
    }

    func testMissingKeySendsNothing() async {
        MockURLProtocol.respond(status: 200, json: sampleResponse)
        let client = GIPHYClient(apiKey: "", session: MockURLProtocol.session())
        do {
            _ = try await client.search("hi", limit: 5)
            XCTFail("expected missingKey")
        } catch {
            XCTAssertEqual(error as? GIFError, .missingKey)
        }
        XCTAssertNil(MockURLProtocol.lastRequest)
    }

    func testRatingDefaults() {
        let defaults = UserDefaults(suiteName: "GIFClientTests-\(UUID().uuidString)")!
        XCTAssertEqual(GIFRating.current(defaults), .pg13)
        defaults.set("r", forKey: GIFRating.defaultsKey)
        XCTAssertEqual(GIFRating.current(defaults), .r)
        defaults.set("nc-17", forKey: GIFRating.defaultsKey)
        XCTAssertEqual(GIFRating.current(defaults), .pg13)
    }

    func testGridNavigation() {
        // 8 results in 3 columns: rows [0 1 2] [3 4 5] [6 7]
        XCTAssertEqual(GIFGrid.index(after: 0, dx: 1, dy: 0, count: 8, columns: 3), 1)
        XCTAssertEqual(GIFGrid.index(after: 2, dx: 1, dy: 0, count: 8, columns: 3), 3, "→ wraps to the next row")
        XCTAssertEqual(GIFGrid.index(after: 0, dx: -1, dy: 0, count: 8, columns: 3), 0)
        XCTAssertEqual(GIFGrid.index(after: 1, dx: 0, dy: 1, count: 8, columns: 3), 4)
        XCTAssertEqual(GIFGrid.index(after: 5, dx: 0, dy: 1, count: 8, columns: 3), 7, "↓ into a short last row")
        XCTAssertEqual(GIFGrid.index(after: 7, dx: 0, dy: 1, count: 8, columns: 3), 7)
        XCTAssertEqual(GIFGrid.index(after: 1, dx: 0, dy: -1, count: 8, columns: 3), 1)
        XCTAssertEqual(GIFGrid.index(after: 7, dx: 1, dy: 0, count: 8, columns: 3), 7)
        XCTAssertEqual(GIFGrid.index(after: 0, dx: 0, dy: 1, count: 0, columns: 3), 0)
    }
}
