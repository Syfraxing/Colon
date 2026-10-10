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
    /// With no local match at all, Jev's top pick needs this probability before anything is shown,
    /// so gibberish (`:zzqx` → top ≈ 0.2) leaves Enter native while slang (`:yeet` → 🚀 ≈ 0.67) still works.
    public nonisolated static let noLocalMatchMinimumTop = 0.4
    /// Most emoji shown on the bare trigger (recents strip).
    public nonisolated static let recentsLimit = 8
    static let localPoolSize = 40
    static let localCandidates = 24
    static let frecentCandidates = 16
    static let maxCandidates = 140
    /// Shorter queries are too ambiguous to be worth a network round trip.
    public nonisolated static let minimumJevQueryLength = 2

    /// Delay before asking Jev, so fast typing sends one request.
    var debounce: Duration = .milliseconds(60)

    private let settings: AppSettings
    private let store: EmojiStore
    private let usage: UsageStore
    private let search: EmojiSearch
    private let injectedJev: JevRanking?
    private let popular: [Emoji]

    /// Built from the key cached by `reloadAPIKey()`; the engine never reads the Keychain per query.
    private var client: JevClient?
    private var keyLoaded = false
    private var keyLoad: Task<Void, Never>?
    private var lastNetworkUse: ContinuousClock.Instant?
    private var cache = LRUCache<CacheKey, [String: Double]>(capacity: 64)
    private var task: Task<Void, Never>?
    private var generation = 0
    private var context = PredictionContext()
    /// Local matches for the current query (larger than what is shown), used for blending.
    private var localPool: [Suggestion] = []
    /// The user's snippets matching the current query. While any match, Jev is not asked, so
    /// nothing resembling a trigger leaves the Mac alongside them.
    private var snippetHits: [SnippetSearch.Hit] = []
    /// Set when the user moved the highlight; later Jev answers must not reorder rows.
    private var orderFrozen = false
    private var cancellables = Set<AnyCancellable>()

    /// `jev` nil means: use a `JevClient` for the key `reloadAPIKey()` loads (started here).
    public init(settings: AppSettings, store: EmojiStore = .shared, usage: UsageStore = .shared, jev: JevRanking? = nil) {
        self.settings = settings
        self.store = store
        self.usage = usage
        self.injectedJev = jev
        search = EmojiSearch(store: store, usage: usage)
        popular = PopularEmoji.ids.compactMap { store.emoji(id: $0) }
        jevStatus = settings.useJev ? .idle : .disabled
        if jev == nil { reloadAPIKey() }

        settings.$useJev
            .dropFirst()
            .sink { [weak self] _ in
                // `@Published` fires before the property changes; read the settled value next tick.
                DispatchQueue.main.async { self?.refreshStatus() }
            }
            .store(in: &cancellables)
    }

    /// Recompute local results synchronously, then (debounced) ask Jev to rerank.
    /// The same query with only a new context (e.g. the AX anchor/text arriving late) keeps the
    /// local results and just reschedules Jev. The raw empty query (the bare trigger) publishes the
    /// recents strip and never calls Jev. Snippets whose trigger matches are merged in
    /// (`SnippetSearch.merge`); while any snippet matches, Jev is skipped.
    public func update(query: String, context: PredictionContext) {
        let normalized = EmojiSearch.normalize(query)
        let sameQuery = !normalized.isEmpty && normalized == EmojiSearch.normalize(self.query)
        let startingSession = self.query.isEmpty
        let context = sanitized(context)
        if sameQuery && context == self.context { return }
        cancelPending()
        self.query = query
        self.context = context

        guard !normalized.isEmpty else {
            localPool = []
            snippetHits = []
            guard query.isEmpty else {
                // Only the bare trigger shows recents; text that normalises away (`::`, spaces) shows nothing.
                suggestions = []
                orderFrozen = false
                return
            }
            // Rebuilding on a context-only update would reorder the strip under a moved highlight.
            if !(startingSession && orderFrozen && !suggestions.isEmpty) {
                orderFrozen = false
                suggestions = recents()
            }
            return
        }

        let boosts = usage.snapshot(query: normalized)
        if !sameQuery {
            orderFrozen = false
            localPool = search.search(normalized, limit: Self.localPoolSize, boosts: boosts)
            snippetHits = SnippetSearch.search(normalized, in: settings.snippets)
            suggestions = SnippetSearch.merge(snippetHits, into: Array(localPool.prefix(maxResults)), limit: maxResults)
        }

        guard snippetHits.isEmpty, normalized.count >= Self.minimumJevQueryLength, let ranker = currentRanker() else { return }
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

    /// Reads the Jev key from the Keychain off the main thread and caches it. Call at launch
    /// (the initializer does) and after Settings saves or deletes a key.
    @discardableResult
    public func reloadAPIKey() -> Task<Void, Never> {
        keyLoad?.cancel()
        let task = Task { [weak self] in
            let key = await Task.detached(priority: .userInitiated) { KeychainStore.jevAPIKey }.value
            guard let self, !Task.isCancelled else { return }
            self.client = key.map { JevClient(apiKey: $0) }
            self.keyLoaded = true
            self.cache.removeAll()
            self.refreshStatus()
        }
        keyLoad = task
        return task
    }

    /// Clear query/results and cancel any in-flight Jev request.
    public func reset() {
        cancelPending()
        query = ""
        context = PredictionContext()
        localPool = []
        snippetHits = []
        suggestions = []
        orderFrozen = false
    }

    /// Call when the user moves the highlight (↑/↓): a late Jev answer then only updates
    /// probabilities and never reorders rows under the user. `update` unfreezes.
    public func freezeOrder() {
        orderFrozen = true
    }

    /// The user's most frecent emoji, topped up with popular ones, at most `recentsLimit` (and
    /// `maxResults`). Scores descend in display order so the strip reads best-first.
    public func recents() -> [Suggestion] {
        let limit = min(Self.recentsLimit, maxResults)
        var result: [Suggestion] = []
        var seen = Set<String>()
        func add(_ emoji: Emoji) {
            guard result.count < limit, seen.insert(emoji.id).inserted else { return }
            result.append(Suggestion(emoji: emoji, score: Double(limit - result.count)))
        }
        usage.top(limit).compactMap { store.emoji(id: $0) }.forEach(add)
        popular.forEach(add)
        return result
    }

    /// Call after the user inserts an emoji.
    public func recordUse(_ emoji: Emoji) {
        let normalized = EmojiSearch.normalize(query)
        usage.recordUse(of: emoji.id, query: normalized.isEmpty ? nil : normalized)
    }

    /// Call after the user inserts a suggestion. Snippet picks are not recorded (personal data
    /// stays out of the usage history).
    public func recordUse(_ item: Suggestion.Item) {
        if case .emoji(let emoji) = item { recordUse(emoji) }
    }

    /// The text to insert for a picked suggestion: the emoji (skin tone applied) or the snippet text.
    public func output(for item: Suggestion.Item) -> String {
        switch item {
        case .emoji(let emoji): output(for: emoji)
        case .snippet(let snippet): snippet.text
        }
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
                guard suggestion.emoji != nil else { return suggestion }
                var updated = suggestion
                updated.jevProbability = probabilities[suggestion.id] ?? 0
                return updated
            }
            return
        }
        let emoji = Self.blend(local: localPool, probabilities: probabilities, store: store, limit: maxResults)
        suggestions = SnippetSearch.merge(snippetHits, into: emoji, limit: maxResults)
    }

    /// `0.7 * p + 0.3 * local / bestLocal`; an exact-shortcode top hit stays first while Jev roughly agrees.
    nonisolated static func blend(local: [Suggestion], probabilities: [String: Double], store: EmojiStore, limit: Int) -> [Suggestion] {
        guard !probabilities.isEmpty else { return Array(local.prefix(limit)) }
        let bestLocal = local.first?.score ?? 0
        let bestJev = probabilities.values.max() ?? 0
        if local.isEmpty && bestJev < noLocalMatchMinimumTop { return [] }

        var blended: [(suggestion: Suggestion, order: Int)] = []
        var seen = Set<String>()
        for (rank, item) in local.enumerated() {
            let p = probabilities[item.id] ?? 0
            let normalizedLocal = bestLocal > 0 ? item.score / bestLocal : 0
            var blendedItem = item
            blendedItem.score = jevWeight * p + localWeight * normalizedLocal
            blendedItem.jevProbability = p
            blended.append((blendedItem, rank))
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
        localPool.prefix(Self.localCandidates).compactMap(\.emoji).forEach(add)
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
        if let status = unavailableStatus() {
            jevStatus = status
            return nil
        }
        if jevStatus == .disabled || jevStatus == .noKey { jevStatus = .idle }
        return injectedJev ?? client
    }

    /// `.disabled` / `.noKey` when Jev can't be used, nil when it can.
    private func unavailableStatus() -> JevStatus? {
        guard settings.useJev else { return .disabled }
        if injectedJev != nil { return nil }
        // Until the first key load finishes, stay quiet rather than flashing "no key".
        if !keyLoaded { return jevStatus == .disabled ? .idle : jevStatus }
        return client == nil ? .noKey : nil
    }

    private func refreshStatus() {
        if let status = unavailableStatus() {
            cancelPending()
            jevStatus = status
        } else if jevStatus == .disabled || jevStatus == .noKey {
            jevStatus = .idle
        }
    }

    /// Text before the trigger only goes to Jev when the user opted in.
    private func sanitized(_ context: PredictionContext) -> PredictionContext {
        guard !settings.sendTextContext, context.textBeforeTrigger != nil else { return context }
        var context = context
        context.textBeforeTrigger = nil
        return context
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

    mutating func removeAll() {
        values.removeAll()
        order.removeAll()
    }

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
