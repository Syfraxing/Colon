import Foundation

/// Frecency of picked emoji, persisted in Application Support. OWNER: core worker.
public final class UsageStore: @unchecked Sendable {
    public static let shared = UsageStore()

    public init(fileURL: URL? = nil) {
        // SCAFFOLD
    }

    public func recordUse(of emojiID: String) {
        // SCAFFOLD
    }

    /// 0...1 boost; 0 for never used.
    public func frecency(of emojiID: String) -> Double {
        // SCAFFOLD
        0
    }

    /// Most frecent emoji ids, best first.
    public func top(_ limit: Int) -> [String] {
        // SCAFFOLD
        []
    }
}
