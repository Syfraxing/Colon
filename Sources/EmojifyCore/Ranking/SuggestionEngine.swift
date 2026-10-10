import Combine
import Foundation

public enum JevStatus: Equatable, Sendable {
    case disabled          // user turned Jev off
    case noKey             // no API key saved
    case idle              // ready
    case ok(milliseconds: Int)
    case error(String)
}

/// Combines instant local search + frecency with an async Jev rerank.
/// The picker UI observes `suggestions`; the input layer calls `update`. OWNER: core worker.
///
/// `update` publishes local results synchronously. After a short debounce it asks Jev to rank a
/// candidate pool (local matches + frecent + popular emoji), blends the probabilities with the
/// local scores and publishes again. Stale answers (the query moved on) are dropped, answers are
/// cached per (query, app, context), and errors leave the local results in place.
@MainActor
public final class SuggestionEngine: ObservableObject {
    @Published public private(set) var query: String = ""
    /// Ordered best-first, at most `settings.maxResults`.
    @Published public private(set) var suggestions: [Suggestion] = []
    /// True while a Jev request for the current query is in flight.
    @Published public private(set) var isRefining = false
    @Published public private(set) var jevStatus: JevStatus = .idle

    // Tuning. Weights from ARCHITECTURE.md "Ranking"; adjusted with scripts/eval-jev.swift.
    public nonisolated static let jevWeight = 0.7
    public nonisolated static let localWeight = 0.3
    /// An exact-shortcode local top stays first while its Jev probability is at least this share of Jev's best.
    public nonisolated static let exactPinTolerance = 0.35
    /// Emoji only Jev proposed (no local match) need at least this probability to be shown.
    public nonisolated static let jevOnlyThreshold = 0.02
    static let localPoolSize = 40
    static let localCandidates = 24
    static let frecentCandidates = 16
    static let maxCandidates = 140

    /// Delay before asking Jev, so fast typing sends one request.
    var debounce: Duration = .milliseconds(60)

    private let settings: AppSettings
    private let store: EmojiStore
    private let usage: UsageStore
    private let search: EmojiSearch
    private let injectedJev: JevRanking?
    private let popular: [Emoji]

    private var client: (key: String, ranker: JevClient)?
    private var keyCheckedAt: ContinuousClock.Instant?
    private var lastNetworkUse: ContinuousClock.Instant?
    private var cache = LRUCache<CacheKey, [String: Double]>(capacity: 64)
    private var task: Task<Void, Never>?
    private var generation = 0
    private var context = PredictionContext()
    /// Local matches for the current query (larger than what is shown), used for blending.
    private var localPool: [Suggestion] = []
    /// Set when the user moved the highlight; later Jev answers must not reorder rows.
    private var orderFrozen = false
    private var cancellables = Set<AnyCancellable>()

    /// `jev` nil means: build a `JevClient` from `KeychainStore.jevAPIKey` on demand.
    public init(settings: AppSettings, store: EmojiStore = .shared, usage: UsageStore = .shared, jev: JevRanking? = nil) {
        self.settings = settings
        self.store = store
        self.usage = usage
        self.injectedJev = jev
        search = EmojiSearch(store: store, usage: usage)
        popular = PopularEmoji.ids.compactMap { store.emoji(id: $0) }
        jevStatus = baseStatus(refreshKey: true) ?? .idle

        settings.$useJev
            .dropFirst()
            .sink { [weak self] _ in
                // `@Published` fires before the property changes; read the settled value next tick.
                DispatchQueue.main.async { self?.refreshStatus() }
            }
            .store(in: &cancellables)
    }

    /// Recompute local results synchronously, then (debounced) ask Jev to rerank.
    public func update(query: String, context: PredictionContext) {
        let startingSession = self.query.isEmpty
        cancelPending()
        self.query = query
        self.context = context
        orderFrozen = false

        let normalized = EmojiSearch.normalize(query)
        guard !normalized.isEmpty else {
            localPool = []
            suggestions = []
            return
        }

        let boosts = usage.snapshot(query: normalized)
        localPool = search.search(normalized, limit: Self.localPoolSize, boosts: boosts)
        suggestions = Array(localPool.prefix(maxResults))

        guard let ranker = currentRanker() else { return }
        let key = CacheKey(query: normalized, app: context.bundleID ?? context.appName ?? "",
                           textHash: context.textBeforeTrigger.map { $0.hashValue } ?? 0)
        if let cached = cache[key] {
            apply(cached)
            return
        }

        if startingSession, needsWarmUp() {
            Task.detached(priority: .userInitiated) { await ranker.warmUp() }
        }
        let candidates = candidatePool(boosts: boosts)
        let generation = generation
        isRefining = true
        task = Task { [weak self, debounce] in
            do {
                try await Task.sleep(for: debounce)
                let clock = ContinuousClock()
                let start = clock.now
                let probabilities = try await ranker.rank(query: normalized, context: context, candidates: candidates)
                let elapsed = clock.now - start
                guard let self, self.generation == generation else { return }
                self.lastNetworkUse = clock.now
                self.cache[key] = probabilities
                self.isRefining = false
                self.jevStatus = .ok(milliseconds: Self.milliseconds(elapsed))
                self.apply(probabilities)
            } catch {
                guard let self, self.generation == generation, !Task.isCancelled, !(error is CancellationError) else { return }
                self.isRefining = false
                self.jevStatus = .error(Self.describe(error))
            }
        }
    }

    /// Clear query/results and cancel any in-flight Jev request.
    public func reset() {
        cancelPending()
        query = ""
        context = PredictionContext()
        localPool = []
        suggestions = []
        orderFrozen = false
    }

    /// Call when the user moves the highlight (↑/↓): a late Jev answer then only updates
    /// probabilities and never reorders rows under the user. `update` unfreezes.
    public func freezeOrder() {
        orderFrozen = true
    }

    /// Call after the user inserts an emoji.
    public func recordUse(_ emoji: Emoji) {
        let normalized = EmojiSearch.normalize(query)
        usage.recordUse(of: emoji.id, query: normalized.isEmpty ? nil : normalized)
    }

    /// The string to insert for `emoji`, with the preferred skin tone applied when supported.
    public func output(for emoji: Emoji) -> String {
        Self.applying(settings.skinTone, to: emoji)
    }

    /// Inserts the tone modifier right after the first scalar (dropping its VS16), which the dataset
    /// build verified matches Unicode's toned sequence for every `supportsSkinTone` emoji.
    public nonisolated static func applying(_ tone: SkinTone, to emoji: Emoji) -> String {
        guard emoji.supportsSkinTone, let modifier = tone.modifier?.unicodeScalars.first else { return emoji.char }
        var scalars = Array(emoji.char.unicodeScalars)
        guard !scalars.isEmpty else { return emoji.char }
        if scalars.count > 1, scalars[1].value == 0xFE0F { scalars.remove(at: 1) }
        scalars.insert(modifier, at: 1)
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }

    // MARK: - Blending

    private var maxResults: Int { max(1, settings.maxResults) }

    /// Blends Jev probabilities into the current local pool and publishes.
    private func apply(_ probabilities: [String: Double]) {
        if orderFrozen {
            suggestions = suggestions.map { suggestion in
                var updated = suggestion
                updated.jevProbability = probabilities[suggestion.id] ?? 0
                return updated
            }
            return
        }
        suggestions = Self.blend(local: localPool, probabilities: probabilities, store: store, limit: maxResults)
    }

    /// `0.7 * p + 0.3 * local / bestLocal`; an exact-shortcode top hit stays first while Jev roughly agrees.
    nonisolated static func blend(local: [Suggestion], probabilities: [String: Double], store: EmojiStore, limit: Int) -> [Suggestion] {
        guard !probabilities.isEmpty else { return Array(local.prefix(limit)) }
        let bestLocal = local.first?.score ?? 0
        let bestJev = probabilities.values.max() ?? 0

        var blended: [(suggestion: Suggestion, order: Int)] = []
        var seen = Set<String>()
        for (rank, item) in local.enumerated() {
            let p = probabilities[item.id] ?? 0
            let normalizedLocal = bestLocal > 0 ? item.score / bestLocal : 0
            blended.append((Suggestion(emoji: item.emoji, score: jevWeight * p + localWeight * normalizedLocal,
                                       jevProbability: p), rank))
            seen.insert(item.id)
        }
        for (id, p) in probabilities where !seen.contains(id) && p >= jevOnlyThreshold {
            guard let emoji = store.emoji(id: id) else { continue }
            blended.append((Suggestion(emoji: emoji, score: jevWeight * p, jevProbability: p), local.count + (store.index(ofID: id) ?? 0)))
        }

        var pinned: Suggestion?
        if let top = local.first, top.score >= EmojiSearch.exactShortcodeScore,
           (probabilities[top.id] ?? 0) >= bestJev * exactPinTolerance,
           let index = blended.firstIndex(where: { $0.suggestion.id == top.id }) {
            pinned = blended.remove(at: index).suggestion
        }
        blended.sort { $0.suggestion.score != $1.suggestion.score ? $0.suggestion.score > $1.suggestion.score : $0.order < $1.order }
        var result = blended.map(\.suggestion)
        if let pinned {
            result.insert(pinned, at: 0)
        }
        return Array(result.prefix(limit))
    }

    /// Local top matches, then frecent, then popular emoji; deduplicated, at most `maxCandidates`.
    private func candidatePool(boosts: UsageStore.Snapshot) -> [Emoji] {
        var pool: [Emoji] = []
        var seen = Set<String>()
        func add(_ emoji: Emoji) {
            if pool.count < Self.maxCandidates, seen.insert(emoji.id).inserted { pool.append(emoji) }
        }
        localPool.prefix(Self.localCandidates).forEach { add($0.emoji) }
        usage.top(Self.frecentCandidates).compactMap { store.emoji(id: $0) }.forEach(add)
        popular.forEach(add)
        return pool
    }

    // MARK: - Jev plumbing

    private func cancelPending() {
        generation += 1
        task?.cancel()
        task = nil
        isRefining = false
    }

    /// The ranker to use now, or nil (with `jevStatus` updated) when Jev is off or has no key.
    private func currentRanker() -> JevRanking? {
        if let status = baseStatus(refreshKey: false) {
            jevStatus = status
            return nil
        }
        if case .disabled = jevStatus { jevStatus = .idle }
        if case .noKey = jevStatus { jevStatus = .idle }
        return injectedJev ?? client?.ranker
    }

    /// `.disabled` / `.noKey` when Jev can't be used, nil when it can. Re-reads the Keychain at most every 2 s.
    private func baseStatus(refreshKey force: Bool) -> JevStatus? {
        guard settings.useJev else { return .disabled }
        if injectedJev != nil { return nil }
        let now = ContinuousClock.now
        if force || keyCheckedAt.map({ now - $0 > .seconds(2) }) ?? true {
            keyCheckedAt = now
            if let key = KeychainStore.jevAPIKey {
                if client?.key != key { client = (key, JevClient(apiKey: key)) }
            } else {
                client = nil
            }
        }
        return client == nil ? .noKey : nil
    }

    private func refreshStatus() {
        if let status = baseStatus(refreshKey: true) {
            cancelPending()
            jevStatus = status
        } else if jevStatus == .disabled || jevStatus == .noKey {
            jevStatus = .idle
        }
    }

    private func needsWarmUp() -> Bool {
        lastNetworkUse.map { ContinuousClock.now - $0 > .seconds(30) } ?? true
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let (seconds, attoseconds) = duration.components
        return Int(seconds * 1000 + attoseconds / 1_000_000_000_000_000)
    }

    private static func describe(_ error: Error) -> String {
        if let jev = error as? JevError { return jev.errorDescription ?? "Jev error" }
        if let url = error as? URLError {
            switch url.code {
            case .timedOut: return "Jev timed out"
            case .notConnectedToInternet, .networkConnectionLost: return "Offline"
            default: return url.localizedDescription
            }
        }
        return error.localizedDescription
    }

    private struct CacheKey: Hashable {
        let query: String
        let app: String
        let textHash: Int
    }
}

/// Minimal LRU map; capacity is small so linear bookkeeping is fine.
struct LRUCache<Key: Hashable, Value> {
    let capacity: Int
    private var values: [Key: Value] = [:]
    private var order: [Key] = []

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    var count: Int { values.count }

    subscript(key: Key) -> Value? {
        mutating get {
            guard let value = values[key] else { return nil }
            touch(key)
            return value
        }
        set {
            guard let newValue else {
                values[key] = nil
                order.removeAll { $0 == key }
                return
            }
            values[key] = newValue
            touch(key)
            if order.count > capacity {
                values[order.removeFirst()] = nil
            }
        }
    }

    private mutating func touch(_ key: Key) {
        if let index = order.firstIndex(of: key) { order.remove(at: index) }
        order.append(key)
    }
}
