import Foundation

/// Loads the bundled emoji dataset once and builds the indexes `EmojiSearch` runs on, plus the
/// per-language search terms (`languageIndex`), each loaded on first use. OWNER: core worker.
public final class EmojiStore: @unchecked Sendable {
    public static let shared = EmojiStore()

    /// Name of the SwiftPM resource bundle that carries `emoji.json` and `i18n/`.
    static let resourceBundleName = "Colon_ColonCore.bundle"
    static let resourceName = "emoji.json"

    /// Every emoji in dataset order (Unicode category order).
    public let all: [Emoji]

    /// English shortcodes, keywords and name words (folded, see `TextFolding`).
    let baseIndex: TermIndex
    /// Per emoji (same index as `all`): lowercased UTF-8 shortcodes, used for fuzzy matching.
    let shortcodeBytes: [[[UInt8]]]

    /// Per emoji (same index as `all`): 0...1 prior from `PopularEmoji` (1 = most commonly sent).
    let popularity: [Double]

    private let indexByShortcode: [String: Int]
    private let indexByID: [String: Int]

    /// Loaded languages by code (nil value = no bundled file). Guarded by `languageLock`.
    private var languages: [String: Language?] = [:]
    private let languageLock = NSLock()

    /// All other instance state is immutable after init; `languages` is only touched under
    /// `languageLock`. That is what makes `@unchecked Sendable` sound.
    public init(emoji: [Emoji]? = nil) {
        all = emoji ?? Self.loadBundledDataset()

        var byShortcode: [String: Int] = [:]
        var byID: [String: Int] = [:]
        var terms: [Term] = []
        var shortcodeBytes: [[[UInt8]]] = []
        terms.reserveCapacity(all.count * 14)
        shortcodeBytes.reserveCapacity(all.count)

        for (index, emoji) in all.enumerated() {
            let ref = Int32(index)
            let isFlag = emoji.category == "Flags"
            byID[emoji.id] = byID[emoji.id] ?? index

            var codes: [[UInt8]] = []
            var seen = Set<String>()
            for (position, code) in emoji.shortcodes.enumerated() {
                let lowered = code.lowercased()
                guard seen.insert(lowered).inserted else { continue }
                byShortcode[lowered] = byShortcode[lowered] ?? index
                let bytes = Array(lowered.utf8)
                codes.append(bytes)
                // Two-letter flag codes (`gm`, `sm`) collide with chat shorthand; rank them like name words.
                let isCountryCode = isFlag && bytes.count == 2
                terms.append(Term(key: bytes, emoji: ref, kind: isCountryCode ? .nameWord : .shortcode,
                                  isPrimary: position == 0))
            }
            shortcodeBytes.append(codes)

            seen.removeAll(keepingCapacity: true)
            for keyword in emoji.keywords {
                let lowered = TextFolding.fold(keyword)
                guard seen.insert(lowered).inserted else { continue }
                let bytes = Array(lowered.utf8)
                let isCountryCode = isFlag && bytes.count == 2
                terms.append(Term(key: bytes, emoji: ref, kind: isCountryCode ? .nameWord : .keyword, isPrimary: false))
            }

            seen.removeAll(keepingCapacity: true)
            for word in Self.words(in: TextFolding.fold(emoji.name)) where seen.insert(word).inserted {
                terms.append(Term(key: Array(word.utf8), emoji: ref, kind: .nameWord, isPrimary: false))
            }
        }

        baseIndex = TermIndex(terms)
        self.shortcodeBytes = shortcodeBytes
        indexByShortcode = byShortcode
        indexByID = byID

        var popularity = [Double](repeating: 0, count: all.count)
        let popular = PopularEmoji.ids
        for (rank, id) in popular.enumerated() {
            if let index = byID[id] { popularity[index] = 1 - Double(rank) / Double(popular.count) }
        }
        self.popularity = popularity
    }

    /// Exact lookup by any shortcode (without colons), case-insensitive.
    public func emoji(forShortcode shortcode: String) -> Emoji? {
        var code = shortcode.lowercased()
        if code.hasPrefix(":") { code.removeFirst() }
        if code.hasSuffix(":") { code.removeLast() }
        return indexByShortcode[code].map { all[$0] }
    }

    /// Lookup by `Emoji.id`.
    public func emoji(id: String) -> Emoji? {
        index(ofID: id).map { all[$0] }
    }

    /// Position of the emoji in dataset order.
    public func index(ofID id: String) -> Int? {
        indexByID[id]
    }

    /// Search terms of a `SearchLanguages` code, loaded from `i18n/<code>.json.deflate` on first use
    /// and cached; nil when no such file is bundled. The first call per language decompresses and
    /// indexes ~2000 entries, so make it off the main thread (`SuggestionEngine` does).
    func language(_ code: String) -> Language? {
        languageLock.lock()
        defer { languageLock.unlock() }
        if let cached = languages[code] { return cached }
        let loaded = Self.bundledResourceURL("i18n/\(code).json.deflate").flatMap { url in
            try? Data(contentsOf: url, options: .mappedIfSafe)
        }.flatMap { try? language(deflatedJSON: $0) }
        languages[code] = loaded
        return loaded
    }

    /// Builds a language from its file: `{"<Emoji.id>": ["<name>", "<keyword>", ...]}` as raw
    /// DEFLATE. The name's words rank as name words, the rest as keywords. Unknown ids (emoji the
    /// running macOS cannot render) are skipped.
    func language(deflatedJSON data: Data) throws -> Language {
        let json = try (data as NSData).decompressed(using: .zlib) as Data
        let entries = try JSONDecoder().decode([String: [String]].self, from: json)
        var terms: [Term] = []
        terms.reserveCapacity(entries.count * 12)
        var names: [Int: String] = [:]
        names.reserveCapacity(entries.count)
        var seen = Set<String>()
        for (id, values) in entries {
            guard let index = indexByID[id], let name = values.first else { continue }
            let ref = Int32(index)
            if !name.isEmpty { names[index] = name }
            seen.removeAll(keepingCapacity: true)
            for keyword in values.dropFirst() {
                let folded = TextFolding.fold(keyword)
                guard seen.insert(folded).inserted else { continue }
                terms.append(Term(key: Array(folded.utf8), emoji: ref, kind: .keyword, isPrimary: false))
            }
            for word in Self.words(in: TextFolding.fold(name)) where seen.insert(word).inserted {
                terms.append(Term(key: Array(word.utf8), emoji: ref, kind: .nameWord, isPrimary: false))
            }
        }
        return Language(index: TermIndex(terms), names: names)
    }

    /// One extra search language.
    struct Language: Sendable {
        let index: TermIndex
        /// CLDR name per emoji (position in `all`), folded like the terms: `inima rosie`.
        let names: [Int: String]
    }

    // MARK: - Index

    struct Term: Sendable {
        enum Kind: UInt8, Sendable {
            case shortcode, keyword, nameWord
        }

        let key: [UInt8]
        let emoji: Int32
        let kind: Kind
        /// The term is the emoji's primary shortcode (`Emoji.id`).
        let isPrimary: Bool
    }

    /// Searchable terms sorted by `key` (bytewise) for binary-searched prefix lookups.
    struct TermIndex: Sendable {
        let terms: [Term]

        init(_ terms: [Term]) {
            self.terms = terms.sorted { EmojiStore.less($0.key, $1.key) }
        }

        /// First index in `terms` whose key is not less than `prefix`.
        func lowerBound(_ prefix: [UInt8]) -> Int {
            var low = 0
            var high = terms.count
            while low < high {
                let mid = (low + high) / 2
                if EmojiStore.less(terms[mid].key, prefix) { low = mid + 1 } else { high = mid }
            }
            return low
        }
    }

    static func less(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        let count = min(lhs.count, rhs.count)
        var i = 0
        while i < count {
            if lhs[i] != rhs[i] { return lhs[i] < rhs[i] }
            i += 1
        }
        return lhs.count < rhs.count
    }

    /// Lowercased alphanumeric words of an emoji name (`flag: United States` -> `flag`, `united`, `states`).
    static func words(in name: String) -> [String] {
        name.lowercased()
            .split { !($0.isLetter || $0.isNumber) }
            .map(String.init)
    }

    // MARK: - Loading

    /// Highest Unicode emoji version the running macOS renders with Apple Color Emoji.
    static func supportedEmojiVersion(for os: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> Double {
        switch (os.majorVersion, os.minorVersion) {
        case let (major, minor) where major > 26 || (major == 26 && minor >= 4): 17.0
        case let (major, minor) where major > 15 || (major == 15 && minor >= 4): 16.0
        case let (major, minor) where major > 14 || (major == 14 && minor >= 4): 15.1
        default: 15.0
        }
    }

    /// Decodes dataset JSON, dropping emoji newer than `maxVersion` (they would render as tofu).
    static func decode(_ data: Data, maxVersion: Double = supportedEmojiVersion()) throws -> [Emoji] {
        try JSONDecoder().decode([Entry].self, from: data)
            .filter { ($0.version ?? 0) <= maxVersion }
            .map(\.emoji)
    }

    /// A file in the ColonCore resource bundle. In the packaged app the SwiftPM bundle is copied into
    /// `Colon.app/Contents/Resources/`, where `Bundle.module` does not look (its accessor would
    /// trap), so check there first.
    static func bundledResourceURL(_ relativePath: String) -> URL? {
        let fileManager = FileManager.default
        func find(in bundle: URL) -> URL? {
            [
                bundle.appendingPathComponent(relativePath),
                bundle.appendingPathComponent("Contents/Resources/\(relativePath)"),
            ].first { fileManager.fileExists(atPath: $0.path) }
        }
        if let resources = Bundle.main.resourceURL,
           let url = find(in: resources.appendingPathComponent(resourceBundleName, isDirectory: true)) {
            return url
        }
        return find(in: Bundle.module.bundleURL)
    }

    private static func loadBundledDataset() -> [Emoji] {
        guard let url = bundledResourceURL(resourceName) else {
            fatalError("Colon: \(resourceName) is missing from \(resourceBundleName)")
        }
        do {
            return try decode(Data(contentsOf: url, options: .mappedIfSafe))
        } catch {
            fatalError("Colon: cannot load \(url.path): \(error)")
        }
    }

    /// Dataset row: an `Emoji` plus the optional Unicode version `v` (present only when > 15.0).
    private struct Entry: Decodable {
        let emoji: Emoji
        let version: Double?

        private enum CodingKeys: String, CodingKey {
            case version = "v"
        }

        init(from decoder: Decoder) throws {
            emoji = try Emoji(from: decoder)
            version = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(Double.self, forKey: .version)
        }
    }
}
