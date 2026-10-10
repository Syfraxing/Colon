import XCTest
@testable import EmojifyCore

/// Ranking-quality eval against the live Jev API. Prints local top-5 vs blended top-5 and latency
/// for ~60 realistic queries (with and without text context) as a Markdown table.
///
///     JEV_API_KEY=... JEV_EVAL=1 swift test --filter JevEvalTests
///
/// Set `JEV_EVAL_OUT=/path/table.md` to also write the table to a file. Skipped unless both
/// variables are set, so plain `swift test` never spends API calls. The key is never printed.
@MainActor
final class JevEvalTests: XCTestCase {
    static let queries = [
        "haha", "lol", "yay", "sus", "ty", "omg", "love", "sad", "cry", "fire", "ship", "party", "rip", "eyes",
        "think", "cool", "nervous", "facepalm", "clap", "100", "rocket", "money", "coffee", "sleepy", "angry",
        "wink", "ok", "pray", "flex", "skull", "heart", "gm", "gn", "bday", "beer", "pizza", "dog", "cat", "sun",
        "rain",
    ]

    static let withContext: [(String, String, String)] = [
        ("haha", "Messages", "lmao that video was insane"),
        ("sad", "Messages", "my dog passed away this morning"),
        ("fire", "Slack", "just shipped the new release to prod"),
        ("ship", "GitHub", "PR is approved, merging now"),
        ("party", "Messages", "WE CLOSED THE ROUND"),
        ("rip", "Messages", "my phone fell in the pool"),
        ("cry", "Messages", "they cancelled the show after one season"),
        ("ty", "Mail", "got the package, it's perfect"),
        ("love", "Messages", "happy anniversary babe"),
        ("cool", "Messages", "see you at 7 then"),
        ("ok", "Slack", "can you review my PR when you get a sec?"),
        ("eyes", "Messages", "did you see what she just posted"),
        ("think", "Slack", "should we go with option b instead"),
        ("nervous", "Messages", "interview in 10 minutes"),
        ("money", "Messages", "just got paid"),
        ("gm", "Slack", "morning team"),
        ("gn", "Messages", "heading to bed, talk tomorrow"),
        ("sus", "Messages", "he said he was 'working late' again"),
        ("skull", "Messages", "i tripped in front of the whole class"),
        ("bday", "Messages", "happy birthday sarah!!"),
    ]

    func testEval() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let key = env["JEV_API_KEY"], !key.isEmpty, env["JEV_EVAL"] == "1" else {
            throw XCTSkip("set JEV_API_KEY and JEV_EVAL=1 to run the live ranking eval")
        }
        let client = JevClient(apiKey: key)
        let warm = try await client.ping()

        let defaults = UserDefaults(suiteName: "EmojifyEval-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        settings.useJev = true
        settings.sendTextContext = true
        let usageURL = FileManager.default.temporaryDirectory.appendingPathComponent("eval-usage-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: usageURL) }
        let usage = UsageStore(fileURL: usageURL, halfLife: UsageStore.defaultHalfLife, writeDelay: 3600)
        let local = EmojiSearch(store: .shared, usage: usage)

        var rows: [String] = []
        var latencies: [Int] = []
        var failures = 0
        let cases = Self.queries.map { ($0, "Messages", "") } + Self.withContext
        for (query, app, text) in cases {
            // A fresh engine per case: no cache hits, no cross-query state.
            let engine = SuggestionEngine(settings: settings, store: .shared, usage: usage, jev: client)
            engine.debounce = .zero
            engine.update(query: query, context: PredictionContext(appName: app, textBeforeTrigger: text.isEmpty ? nil : text))
            let deadline = ContinuousClock.now + .seconds(5)
            while engine.isRefining, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            let localTop = local.search(query, limit: 5).map(\.emoji.char).joined(separator: " ")
            let blended = engine.suggestions.prefix(5).map { s in
                s.jevProbability.map { "\(s.emoji.char)\(Int(($0 * 100).rounded()))" } ?? s.emoji.char
            }.joined(separator: " ")
            let latency: String
            switch engine.jevStatus {
            case .ok(let ms):
                latencies.append(ms)
                latency = "\(ms)"
            case .error(let message):
                failures += 1
                latency = "error: \(message)"
            default:
                failures += 1
                latency = "\(engine.jevStatus)"
            }
            let contextCell = text.isEmpty ? "" : "\(app): \(text)"
            rows.append("| `:\(query)` | \(contextCell) | \(localTop) | \(blended) | \(latency) |")
        }

        latencies.sort()
        func percentile(_ p: Double) -> Int {
            latencies.isEmpty ? 0 : latencies[min(latencies.count - 1, Int(Double(latencies.count - 1) * p))]
        }
        var table = """
        Jev eval — \(cases.count) cases, warm ping \(warm), p50 \(percentile(0.5)) ms, p90 \(percentile(0.9)) ms, \
        max \(latencies.last ?? 0) ms, failures \(failures)
        Blended cells show emoji followed by Jev probability in percent.

        | query | context | local top-5 | blended top-5 (p%) | ms |
        | --- | --- | --- | --- | --- |

        """
        table += rows.joined(separator: "\n") + "\n"
        print(table)
        if let out = env["JEV_EVAL_OUT"], !out.isEmpty {
            try table.write(toFile: out, atomically: true, encoding: .utf8)
        }
        XCTAssertEqual(failures, 0)
    }
}
