import Foundation

/// Frecency of picked emoji, persisted in Application Support. OWNER: core worker.
///
/// Every pick adds 1 to a score that halves every `halfLife`, so the score blends how often and how
/// recently an emoji was used. Scores are also kept per query (`haha` -> 😂) so a habit for one
/// shortcut doesn't leak into every other search. Thread-safe; disk writes are debounced and async.
public final class UsageStore: @unchecked Sendable {
    public static let shared = UsageStore()

    public static let defaultHalfLife: TimeInterval = 3 * 24 * 60 * 60

    /// `~/Library/Application Support/Emojify/usage.json`
    public static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Emojify", isDirectory: true).appendingPathComponent("usage.json")
    }

    static let maxEmojiEntries = 400
    static let maxQueryEntries = 400
    static let maxEmojiPerQuery = 8

    private let fileURL: URL
    private let halfLife: TimeInterval
    private let writeDelay: TimeInterval
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private let ioQueue = DispatchQueue(label: "so.slayer.Emojify.usage", qos: .utility)

    // Guarded by `lock`.
    private var state: UsageFile
    private var generation = 0
    private var writtenGeneration = 0

    public convenience init(fileURL: URL? = nil) {
        self.init(fileURL: fileURL, halfLife: Self.defaultHalfLife)
    }

    /// - Parameters:
    ///   - writeDelay: debounce for disk writes; bursts of picks produce one write.
    ///   - now: injectable clock for tests.
    public init(fileURL: URL?, halfLife: TimeInterval, writeDelay: TimeInterval = 1.0,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.fileURL = fileURL ?? Self.defaultFileURL
        self.halfLife = halfLife
        self.writeDelay = writeDelay
        self.now = now
        state = Self.load(from: self.fileURL)
    }

    public func recordUse(of emojiID: String) {
        recordUse(of: emojiID, query: nil)
    }

    /// Records a pick, remembering which query it was picked for.
    public func recordUse(of emojiID: String, query: String?) {
        let time = now().timeIntervalSince1970
        lock.lock()
        state.emoji[emojiID] = bumped(state.emoji[emojiID], at: time)
        if let key = Self.queryKey(query) {
            var picks = state.queries[key] ?? [:]
            picks[emojiID] = bumped(picks[emojiID], at: time)
            if picks.count > Self.maxEmojiPerQuery {
                picks = Self.pruned(picks, keeping: Self.maxEmojiPerQuery, at: time, halfLife: halfLife)
            }
            state.queries[key] = picks
        }
        if state.emoji.count > Self.maxEmojiEntries {
            state.emoji = Self.pruned(state.emoji, keeping: Self.maxEmojiEntries, at: time, halfLife: halfLife)
        }
        if state.queries.count > Self.maxQueryEntries {
            let ranked = state.queries.map { key, picks in
                (key, picks.values.map { $0.value(at: time, halfLife: halfLife) }.reduce(0, +))
            }.sorted { $0.1 > $1.1 }
            state.queries = Dictionary(uniqueKeysWithValues: ranked.prefix(Self.maxQueryEntries).map { ($0.0, state.queries[$0.0]!) })
        }
        generation += 1
        let scheduled = generation
        lock.unlock()

        ioQueue.asyncAfter(deadline: .now() + writeDelay) { [weak self] in
            self?.write(ifGeneration: scheduled)
        }
    }

    /// 0...1 boost; 0 for never used.
    public func frecency(of emojiID: String) -> Double {
        let time = now().timeIntervalSince1970
        lock.lock()
        defer { lock.unlock() }
        return Self.normalized(state.emoji[emojiID]?.value(at: time, halfLife: halfLife) ?? 0)
    }

    /// 0...1 affinity of `emojiID` for this exact query (how often it was picked after typing it).
    public func affinity(of emojiID: String, query: String) -> Double {
        guard let key = Self.queryKey(query) else { return 0 }
        let time = now().timeIntervalSince1970
        lock.lock()
        defer { lock.unlock() }
        return Self.normalized(state.queries[key]?[emojiID]?.value(at: time, halfLife: halfLife) ?? 0)
    }

    /// Most frecent emoji ids, best first.
    public func top(_ limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        let time = now().timeIntervalSince1970
        lock.lock()
        defer { lock.unlock() }
        return state.emoji
            .map { ($0.key, $0.value.value(at: time, halfLife: halfLife)) }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
            .prefix(limit)
            .map(\.0)
    }

    /// Point-in-time scores for many lookups without taking the lock each time.
    public func snapshot(query: String? = nil) -> Snapshot {
        let time = now().timeIntervalSince1970
        lock.lock()
        defer { lock.unlock() }
        let global = state.emoji.mapValues { Self.normalized($0.value(at: time, halfLife: halfLife)) }
        let picks = Self.queryKey(query).flatMap { state.queries[$0] } ?? [:]
        return Snapshot(frecency: global,
                        affinity: picks.mapValues { Self.normalized($0.value(at: time, halfLife: halfLife)) })
    }

    public struct Snapshot: Sendable {
        public static let empty = Snapshot(frecency: [:], affinity: [:])

        /// 0...1 per emoji id.
        public let frecency: [String: Double]
        /// 0...1 per emoji id, for the snapshot's query.
        public let affinity: [String: Double]

        /// Combined 0...1 personal boost: query habits weigh more than global use.
        public func boost(for emojiID: String) -> Double {
            let f = frecency[emojiID] ?? 0
            let a = affinity[emojiID] ?? 0
            return min(1, 0.4 * f + 0.6 * a + 0.4 * f * a)
        }
    }

    /// Writes pending changes now (call on app termination).
    public func flush() {
        ioQueue.sync { write(ifGeneration: nil) }
    }

    /// Forget all usage (memory and disk).
    public func removeAll() {
        lock.lock()
        state = UsageFile()
        generation += 1
        lock.unlock()
        flush()
    }

    // MARK: - Private

    private func bumped(_ entry: UsageEntry?, at time: TimeInterval) -> UsageEntry {
        UsageEntry(score: (entry?.value(at: time, halfLife: halfLife) ?? 0) + 1,
                   updated: time,
                   count: (entry?.count ?? 0) + 1)
    }

    /// Runs on `ioQueue`. `nil` writes whatever is pending.
    private func write(ifGeneration expected: Int?) {
        lock.lock()
        guard generation != writtenGeneration, expected == nil || expected == generation else {
            lock.unlock()
            return
        }
        let snapshot = state
        let current = generation
        lock.unlock()

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(snapshot)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            lock.lock()
            writtenGeneration = max(writtenGeneration, current)
            lock.unlock()
        } catch {
            // Usage history is a convenience; a failed write is retried on the next pick.
        }
    }

    private static func load(from url: URL) -> UsageFile {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(UsageFile.self, from: data) else { return UsageFile() }
        return file
    }

    private static func queryKey(_ query: String?) -> String? {
        guard let query else { return nil }
        let key = query.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ": "))
        return key.isEmpty ? nil : key
    }

    /// Maps a decayed score (0...∞) onto 0...1; one fresh pick ≈ 0.33, five ≈ 0.71.
    private static func normalized(_ value: Double) -> Double {
        value <= 0 ? 0 : value / (value + 2)
    }

    private static func pruned(_ entries: [String: UsageEntry], keeping limit: Int,
                               at time: TimeInterval, halfLife: TimeInterval) -> [String: UsageEntry] {
        let kept = entries
            .sorted { $0.value.value(at: time, halfLife: halfLife) > $1.value.value(at: time, halfLife: halfLife) }
            .prefix(limit)
        return Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }
}

private struct UsageFile: Codable {
    var version = 1
    var emoji: [String: UsageEntry] = [:]
    var queries: [String: [String: UsageEntry]] = [:]
}

private struct UsageEntry: Codable {
    /// Decayed pick score as of `updated`.
    var score: Double
    /// Seconds since 1970.
    var updated: TimeInterval
    /// Lifetime picks (informational).
    var count: Int

    func value(at time: TimeInterval, halfLife: TimeInterval) -> Double {
        score * pow(0.5, max(0, time - updated) / halfLife)
    }
}
