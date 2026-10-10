import XCTest
@testable import ColonCore

/// Returns fixed probabilities and records what it was asked.
private final class FakeGIFRanker: GIFRanking, @unchecked Sendable {
    let probabilities: [String: Double]
    let error: Error?
    private(set) var askedTerms: String?
    private(set) var askedIDs: [String] = []

    init(_ probabilities: [String: Double], error: Error? = nil) {
        self.probabilities = probabilities
        self.error = error
    }

    func rank(terms: String, context: PredictionContext, results: [GIFResult]) async throws -> [String: Double] {
        askedTerms = terms
        askedIDs = results.map(\.id)
        if let error { throw error }
        return probabilities
    }
}

final class GIFRerankTests: XCTestCase {
    private func gif(_ id: String, title: String = "", tags: [String] = []) -> GIFResult {
        let url = URL(string: "https://media.giphy.com/media/\(id)/100w.gif")!
        let rendition = GIFRendition(url: url, width: 100, height: 100)
        return GIFResult(id: id, title: title, tags: tags, preview: rendition, full: rendition)
    }

    private lazy var results = ["a", "b", "c", "d"].map { gif($0) }

    func testJevAnswerReordersWithProviderAsTiebreak() async {
        let ranker = FakeGIFRanker(["c": 0.6, "d": 0.3, "a": 0.1])
        let reordered = await GIFRerank.rerank(results, terms: " lol ", context: PredictionContext(), ranker: ranker)
        // c: .7 + .3*(1/3) = .8, d: .35, a: .1167 + .3 = .4167, b: .2
        XCTAssertEqual(reordered?.map(\.id), ["c", "a", "d", "b"])
        XCTAssertEqual(ranker.askedTerms, "lol")
        XCTAssertEqual(ranker.askedIDs, ["a", "b", "c", "d"])
    }

    func testSameOrderOrNoAnswerReturnsNil() async {
        let same = await GIFRerank.rerank(results, terms: "x", context: PredictionContext(),
                                          ranker: FakeGIFRanker(["a": 0.9, "b": 0.05]))
        XCTAssertNil(same, "nothing to animate when Jev agrees")
        let empty = await GIFRerank.rerank(results, terms: "x", context: PredictionContext(), ranker: FakeGIFRanker([:]))
        XCTAssertNil(empty)
        let failed = await GIFRerank.rerank(results, terms: "x", context: PredictionContext(),
                                            ranker: FakeGIFRanker(["d": 1], error: JevError.rateLimited))
        XCTAssertNil(failed, "errors keep the provider order")
    }

    func testNoTermsSkipsJev() async {
        let ranker = FakeGIFRanker(["d": 1])
        let reordered = await GIFRerank.rerank(results, terms: "  ", context: PredictionContext(), ranker: ranker)
        XCTAssertNil(reordered)
        XCTAssertNil(ranker.askedTerms, "trending is never sent to Jev")
    }

    func testReorderIsStableForUnscoredResults() {
        let reordered = GIFRerank.reorder(results, probabilities: ["d": 1], jevWeight: 0.7)
        XCTAssertEqual(reordered.map(\.id), ["d", "a", "b", "c"])
        XCTAssertEqual(GIFRerank.reorder(results, probabilities: [:]).map(\.id), ["a", "b", "c", "d"])
    }

    func testCriterionAndRequestBody() throws {
        let result = gif("xyz", title: "Happy Dance GIF by Disney", tags: ["happy", "dance", "party", "celebrate"])
        XCTAssertEqual(JevGIFRanker.criterion(for: result), "Happy Dance; party, celebrate")
        XCTAssertEqual(JevGIFRanker.criterion(for: gif("q")), "GIF")

        let context = PredictionContext(appName: "Messages", bundleID: "com.apple.MobileSMS",
                                        textBeforeTrigger: "we won the game!!")
        let body = JevGIFRanker.rankBody(terms: "yay", context: context, results: [result, gif("q", title: "Yay")])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, JevClient.model)
        let state = try XCTUnwrap(json["state"] as? [String: String])
        XCTAssertEqual(state, ["app": "Messages", "text_before": "we won the game!!", "query": "yay"])
        let question = try XCTUnwrap((json["questions"] as? [String: Any])?["gif"] as? [String: Any])
        XCTAssertEqual(question["type"] as? String, "choice")
        XCTAssertEqual(question["criteria"] as? [String: String], ["xyz": "Happy Dance; party, celebrate", "q": "Yay"])
        // Criteria keep provider order in the raw body.
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertLessThan(try XCTUnwrap(text.range(of: "\"xyz\"")).lowerBound, try XCTUnwrap(text.range(of: "\"q\"")).lowerBound)
    }

    func testJevRankerDecodesProbabilities() async throws {
        MockURLProtocol.respond(status: 200, json: """
        {"model":"jev-1","answers":{"gif":{"type":"choice","choice":"b","confidence":0.6,\
        "probabilities":{"b":0.6,"a":0.3,"zzz":0.1}}}}
        """)
        let ranker = JevGIFRanker(apiKey: "jev-key", session: MockURLProtocol.session())
        let probabilities = try await ranker.rank(terms: "hi", context: PredictionContext(), results: [gif("a"), gif("b")])
        XCTAssertEqual(probabilities, ["b": 0.6, "a": 0.3], "ids that are not results are dropped")
        XCTAssertEqual(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer jev-key")
    }
}
