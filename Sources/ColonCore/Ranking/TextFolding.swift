import Foundation

/// Case- and accent-insensitive search keys: `Inimă` -> `inima`, `Corazón` -> `corazon`, `Straße` -> `strasse`.
///
/// Lowercase, decompose (NFD), drop combining diacritical marks (U+0300–U+036F), map the few letters
/// NFD keeps whole (`ł ø đ ß æ œ ı`), recompose (NFC). Marks outside that block (Japanese dakuten,
/// Indic vowel signs, Arabic harakat) are letters there and stay. `scripts/build-emoji-data.py`
/// `fold()` applies the identical steps to the bundled language files; keep the two in sync.
public enum TextFolding {
    public static func fold(_ text: String) -> String {
        if text.utf8.allSatisfy({ $0 < 0x80 }) {
            return text.lowercased()
        }
        var scalars = String.UnicodeScalarView()
        for scalar in text.lowercased().decomposedStringWithCanonicalMapping.unicodeScalars {
            switch scalar.value {
            case 0x300...0x36F: continue
            case 0x142: scalars.append("l")                  // ł
            case 0xF8: scalars.append("o")                   // ø
            case 0x111: scalars.append("d")                  // đ
            case 0xDF: scalars.append(contentsOf: "ss".unicodeScalars) // ß
            case 0xE6: scalars.append(contentsOf: "ae".unicodeScalars) // æ
            case 0x153: scalars.append(contentsOf: "oe".unicodeScalars) // œ
            case 0x131: scalars.append("i")                  // ı
            default: scalars.append(scalar)
            }
        }
        return String(scalars).precomposedStringWithCanonicalMapping
    }
}
