import CoreGraphics
import Foundation

/// Splits text for `CGEvent.keyboardSetUnicodeString`, which silently truncates after 20 UTF-16
/// units. Chunks never split a grapheme cluster (a ZWJ sequence or flag stays in one event).
public enum UnicodeChunker {
    public static let maxUTF16Units = 20

    public static func chunks(_ text: String, maxUTF16Units limit: Int = maxUTF16Units) -> [[UniChar]] {
        precondition(limit >= 2, "a chunk must fit at least one surrogate pair")
        var result: [[UniChar]] = []
        var current: [UniChar] = []
        for character in text {
            let units = Array(String(character).utf16)
            if units.count > limit {
                // A single grapheme longer than the event limit cannot stay whole; split it on
                // scalar boundaries so no surrogate pair is ever broken.
                if !current.isEmpty { result.append(current); current = [] }
                for scalar in character.unicodeScalars {
                    let scalarUnits = Array(String(scalar).utf16)
                    if current.count + scalarUnits.count > limit { result.append(current); current = [] }
                    current += scalarUnits
                }
                continue
            }
            if current.count + units.count > limit {
                result.append(current)
                current = []
            }
            current += units
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

/// Accessibility geometry helpers.
public enum AXGeometry {
    /// Converts an Accessibility rect (global, top-left origin at the primary display) into Cocoa
    /// screen coordinates (bottom-left origin at the primary display). Both spaces share the primary
    /// display as reference, so the flip with its height is correct on every attached screen.
    public static func cocoaRect(fromAX rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: rect.origin.x, y: primaryScreenHeight - rect.origin.y - rect.height,
               width: rect.width, height: rect.height)
    }

    /// Converts a point in CGEvent/Quartz global coordinates (top-left origin) to Cocoa coordinates.
    public static func cocoaPoint(fromQuartz point: CGPoint, primaryScreenHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenHeight - point.y)
    }

    /// Apps sometimes answer bounds queries with junk. A usable caret rect has a positive height,
    /// lies on a screen and (when the element frame is known) within the element, ±`tolerance`.
    public static func isPlausible(_ rect: CGRect, screens: [CGRect], elementFrame: CGRect?,
                                   tolerance: CGFloat = 8) -> Bool {
        guard rect.height > 0, rect.width >= 0, rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.height < 2_000 else { return false }
        let probe = CGRect(x: rect.minX, y: rect.minY, width: max(rect.width, 1), height: rect.height)
        guard screens.contains(where: { $0.intersects(probe) }) else { return false }
        if let elementFrame, elementFrame.width > 0, elementFrame.height > 0 {
            return elementFrame.insetBy(dx: -tolerance, dy: -tolerance).intersects(probe)
        }
        return true
    }
}

/// Locates the active trigger in text read on demand (via Accessibility) right before the caret.
/// The text is used transiently and never stored.
public enum TriggerLocator {
    public struct Match: Equatable, Sendable {
        /// UTF-16 distance from the start of the trigger to the caret (trigger + query).
        public var utf16Distance: Int
        /// Text before the trigger (everything in the input string up to the trigger).
        public var textBefore: Substring
    }

    /// Finds the last `trigger` that is followed only by query characters up to the end of
    /// `textBeforeCaret`. Returns nil if the text does not end in an active `:query`.
    public static func locate(trigger: String, in textBeforeCaret: String,
                              maxQueryLength: Int = TriggerEngine.maxQueryLength) -> Match? {
        guard !trigger.isEmpty else { return nil }
        var queryLength = 0
        var cursor = textBeforeCaret.endIndex
        while cursor > textBeforeCaret.startIndex {
            if textBeforeCaret[..<cursor].hasSuffix(trigger) {
                let start = textBeforeCaret.index(cursor, offsetBy: -trigger.count)
                return Match(utf16Distance: textBeforeCaret[start...].utf16.count,
                             textBefore: textBeforeCaret[..<start])
            }
            let previous = textBeforeCaret.index(before: cursor)
            guard TriggerEngine.isQueryCharacter(textBeforeCaret[previous]), queryLength < maxQueryLength else {
                return nil
            }
            queryLength += 1
            cursor = previous
        }
        return nil
    }

    /// The context Jev may see: the last `limit` characters before the trigger, nil if empty.
    public static func context(before match: Match, limit: Int = 300) -> String? {
        let text = String(match.textBefore.suffix(limit))
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }
}
