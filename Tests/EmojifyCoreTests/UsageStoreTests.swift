import XCTest
@testable import EmojifyCore

final class UsageStoreTests: XCTestCase {
    private var url: URL!

    override func setUp() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmojifyTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("usage.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    func testNeverUsedIsZero() {
        let store = UsageStore(fileURL: url, halfLife: 3600)
        XCTAssertEqual(store.frecency(of: "joy"), 0)
        XCTAssertEqual(store.top(5), [])
    }

    func testFrequencyAndRecency() {
        let clock = TestClock()
        let store = UsageStore(fileURL: url, halfLife: 3 * 86_400, writeDelay: 60, now: clock.now)
        store.recordUse(of: "joy")
        store.recordUse(of: "joy")
        store.recordUse(of: "fire")
        XCTAssertGreaterThan(store.frecency(of: "joy"), store.frecency(of: "fire"))
        XCTAssertEqual(store.top(2), ["joy", "fire"])

        // A week later one fresh pick of 🔥 beats two stale picks of 😂.
        clock.advance(by: 7 * 86_400)
        store.recordUse(of: "fire")
        XCTAssertGreaterThan(store.frecency(of: "fire"), store.frecency(of: "joy"))
        XCTAssertEqual(store.top(1), ["fire"])
        XCTAssertLessThanOrEqual(store.frecency(of: "fire"), 1)
    }

    func testHalfLifeDecay() {
        let clock = TestClock()
        let store = UsageStore(fileURL: url, halfLife: 100, writeDelay: 60, now: clock.now)
        store.recordUse(of: "joy")
        let fresh = store.frecency(of: "joy")
        clock.advance(by: 100)
        let decayed = store.frecency(of: "joy")
        XCTAssertLessThan(decayed, fresh)
        // value v -> v/(v+2): 1 pick = 1/3, half a pick = 0.2
        XCTAssertEqual(fresh, 1.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(decayed, 0.2, accuracy: 1e-9)
    }

    func testQueryAffinity() {
        let store = UsageStore(fileURL: url, halfLife: 86_400, writeDelay: 60)
        store.recordUse(of: "joy", query: "haha")
        XCTAssertGreaterThan(store.affinity(of: "joy", query: "haha"), 0)
        XCTAssertGreaterThan(store.affinity(of: "joy", query: ":HAHA"), 0)
        XCTAssertEqual(store.affinity(of: "joy", query: "lol"), 0)
        let snapshot = store.snapshot(query: "haha")
        XCTAssertGreaterThan(snapshot.boost(for: "joy"), store.snapshot(query: "lol").boost(for: "joy"))
    }

    func testPersistsAcrossInstances() {
        let first = UsageStore(fileURL: url, halfLife: 86_400, writeDelay: 60)
        first.recordUse(of: "rocket", query: "ship")
        first.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let second = UsageStore(fileURL: url, halfLife: 86_400)
        XCTAssertEqual(second.top(1), ["rocket"])
        XCTAssertGreaterThan(second.affinity(of: "rocket", query: "ship"), 0)
    }

    func testDebouncedWriteHappensWithoutFlush() {
        let store = UsageStore(fileURL: url, halfLife: 86_400, writeDelay: 0.05)
        for _ in 0..<10 { store.recordUse(of: "tada") }
        let written = expectation(description: "written")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { written.fulfill() }
        wait(for: [written], timeout: 2)
        XCTAssertEqual(UsageStore(fileURL: url, halfLife: 86_400).top(1), ["tada"])
    }

    func testCorruptFileStartsEmpty() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        let store = UsageStore(fileURL: url, halfLife: 86_400)
        XCTAssertEqual(store.top(3), [])
        store.recordUse(of: "joy")
        store.flush()
        XCTAssertEqual(UsageStore(fileURL: url, halfLife: 86_400).top(1), ["joy"])
    }

    func testConcurrentUseIsSafe() {
        let store = UsageStore(fileURL: url, halfLife: 86_400, writeDelay: 60)
        DispatchQueue.concurrentPerform(iterations: 500) { i in
            store.recordUse(of: "e\(i % 7)", query: "q\(i % 3)")
            _ = store.frecency(of: "e\(i % 5)")
            _ = store.top(3)
        }
        XCTAssertEqual(store.top(10).count, 7)
    }

    func testRemoveAll() {
        let store = UsageStore(fileURL: url, halfLife: 86_400, writeDelay: 60)
        store.recordUse(of: "joy")
        store.removeAll()
        XCTAssertEqual(store.top(1), [])
        XCTAssertEqual(UsageStore(fileURL: url, halfLife: 86_400).top(1), [])
    }
}

/// Manually advanced clock for decay tests.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)

    var now: @Sendable () -> Date {
        { [self] in lock.withLock { current } }
    }

    func advance(by seconds: TimeInterval) {
        lock.withLock { current += seconds }
    }
}
