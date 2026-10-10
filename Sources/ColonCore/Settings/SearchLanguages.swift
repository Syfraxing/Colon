import Foundation

/// Languages whose emoji names and keywords (Unicode CLDR annotations) Colon can search besides
/// English, which is always on (the base dataset and every shortcode). Each has a bundled file
/// `Resources/i18n/<code>.json.deflate`, built by `scripts/build-emoji-data.py` (`LANGUAGES`).
public enum SearchLanguages {
    /// Colon language codes, sorted. A test checks each has a bundled file and vice versa.
    public static let supported: [String] = [
        "ar", "ca", "cs", "da", "de", "el", "es", "fi", "fr", "he", "hi", "hr", "hu", "id", "it", "ja",
        "ko", "ms", "nl", "no", "pl", "pt", "pt-PT", "ro", "ru", "sk", "sv", "th", "tr", "uk", "vi", "zh",
        "zh-Hant",
    ]

    private static let supportedSet = Set(supported)

    /// The supported code for a BCP 47 / macOS language identifier (`ro-RO` -> `ro`,
    /// `pt-PT` -> `pt-PT`, `pt-BR` -> `pt`, `zh-Hant-TW` / `zh-HK` -> `zh-Hant`, `nb` -> `no`),
    /// nil for English and unsupported languages.
    public static func code(for identifier: String) -> String? {
        let language = Locale.Language(identifier: identifier)
        guard var code = language.languageCode?.identifier else { return nil }
        if code == "nb" || code == "nn" { code = "no" }
        if code == "zh" {
            let script = language.script ?? Locale.Language(identifier: language.maximalIdentifier).script
            return script?.identifier == "Hant" ? "zh-Hant" : "zh"
        }
        if let region = language.region?.identifier, supportedSet.contains("\(code)-\(region)") {
            return "\(code)-\(region)"
        }
        return supportedSet.contains(code) ? code : nil
    }

    /// Default selection besides English: the user's macOS preferred languages that Colon supports,
    /// in preference order. English-only systems get none.
    public static func defaultSelection(preferredLanguages: [String] = Locale.preferredLanguages) -> [String] {
        var result: [String] = []
        for identifier in preferredLanguages {
            if let code = code(for: identifier), !result.contains(code) { result.append(code) }
        }
        return result
    }

    /// Keeps supported codes once each, in order.
    public static func sanitized(_ codes: [String]) -> [String] {
        var seen = Set<String>()
        return codes.filter { supportedSet.contains($0) && seen.insert($0).inserted }
    }

    /// `Română` (`Romanian`): the language's own name, then the name in the UI language when different.
    public static func displayName(for code: String, in locale: Locale = .current) -> String {
        let native = Locale(identifier: code).localizedString(forIdentifier: code) ?? code
        let local = locale.localizedString(forIdentifier: code) ?? code
        let nativeTitle = native.prefix(1).uppercased() + native.dropFirst()
        return nativeTitle.lowercased() == local.lowercased() ? nativeTitle : "\(nativeTitle) (\(local))"
    }
}
