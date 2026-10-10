import AppKit
import ColonCore
import SwiftUI

/// Layout constants shared by the SwiftUI views and the AppKit hit-testing in the controller.
enum PickerMetrics {
    /// Transparent margin around the card inside the panel, room for the soft shadow.
    static let shadowMargin: CGFloat = 28
    static let cornerRadius: CGFloat = 14
    static let caretGap: CGFloat = 6
    static let screenInset: CGFloat = 8

    // Inline mode
    static let inlineWidth: CGFloat = 300
    static let rowHeight: CGFloat = 34
    static let listInset: CGFloat = 5
    static let footerHeight: CGFloat = 28
    static let emptyHeight: CGFloat = 46
    /// Distance from the card's left edge to the left edge of the emoji glyph; the glyph sits under the trigger.
    static let glyphLeading: CGFloat = listInset + 10
    /// "Recent" label above the list when the trigger alone shows the most-used emoji.
    static let recentsHeaderHeight: CGFloat = 22

    // Compact inline layout: one row of emoji with a caption underneath
    static let compactCell: CGFloat = 36
    static let compactGlyph: CGFloat = 24
    static let compactCaptionHeight: CGFloat = 28
    /// Wide enough for a long `:shortcode:` caption next to the Jev meter.
    static let compactMinWidth: CGFloat = 236
    static let compactGlyphLeading: CGFloat = listInset + (compactCell - compactGlyph) / 2

    // Search mode
    static let searchWidth: CGFloat = 420
    static let searchHeight: CGFloat = 456
    static let searchFieldHeight: CGFloat = 52
    static let searchFooterHeight: CGFloat = 50
    static let gridColumns = 9
    static let gridCell: CGFloat = 42
    static let gridSpacing: CGFloat = 2

    static func inlineCardHeight(rows: Int, recentsHeader: Bool = false) -> CGFloat {
        let body = rows == 0 ? emptyHeight : CGFloat(rows) * rowHeight
        return listInset * 2 + (recentsHeader ? recentsHeaderHeight : 0) + body + footerHeight
    }

    static func compactCardWidth(cells: Int) -> CGFloat {
        max(compactMinWidth, listInset * 2 + CGFloat(cells) * compactCell)
    }

    static var compactCardHeight: CGFloat { listInset * 2 + compactCell + compactCaptionHeight }

    /// The visible inline card for `count` suggestions.
    static func inlineCardSize(layout: PickerLayout, count: Int, recentsHeader: Bool) -> CGSize {
        switch layout {
        case .list:
            CGSize(width: inlineWidth, height: inlineCardHeight(rows: count, recentsHeader: recentsHeader))
        case .compact:
            CGSize(width: compactCardWidth(cells: count), height: compactCardHeight)
        }
    }

    /// The largest card a capture can grow to; the panel is sized (and placed) for this once.
    static func inlineMaxCardSize(layout: PickerLayout, maxResults: Int) -> CGSize {
        inlineCardSize(layout: layout, count: maxResults, recentsHeader: true)
    }

    static func glyphLeading(for layout: PickerLayout) -> CGFloat {
        layout == .list ? glyphLeading : compactGlyphLeading
    }

    /// Index of the compact cell under `x` (measured from the card's left edge), if any.
    static func compactCellIndex(atX x: CGFloat, count: Int) -> Int? {
        let offset = x - listInset
        guard offset >= 0 else { return nil }
        let index = Int(offset / compactCell)
        return index < count ? index : nil
    }

    static func panelSize(card: CGSize) -> CGSize {
        CGSize(width: card.width + shadowMargin * 2, height: card.height + shadowMargin * 2)
    }
}

/// Colours of the monocode-inspired glass, resolved per appearance.
struct PickerTheme {
    let isDark: Bool

    init(_ scheme: ColorScheme) {
        isDark = scheme == .dark
    }

    /// hsl(211 92% 62%)
    static let accent = Color(red: 0.2704, green: 0.6083, blue: 0.9696)
    var accent: Color { Self.accent }

    /// The "content" colour every translucent fill and stroke is derived from.
    var content: Color { isDark ? .white : Color(white: 0.18) }
    /// hsl(240 0% 92%) on dark, near-black on light.
    var text: Color { isDark ? Color(white: 0.92) : Color(white: 0.11) }
    var secondary: Color { text.opacity(0.55) }
    var tertiary: Color { text.opacity(isDark ? 0.36 : 0.42) }
    /// Neutral tint layered over the blur: hsl(240 0% 9%) / 40% on dark, 97% on light. The
    /// light tint is heavier so the card reads as paper-white, not grey, over bright documents.
    var tint: Color { isDark ? Color(white: 0.09).opacity(0.42) : Color(white: 0.97).opacity(0.68) }
    var hairline: Color { content.opacity(isDark ? 0.09 : 0.10) }
    var divider: Color { content.opacity(isDark ? 0.07 : 0.08) }
    var selection: Color { content.opacity(isDark ? 0.13 : 0.10) }
    var hover: Color { content.opacity(isDark ? 0.07 : 0.05) }
    var keycapFill: Color { content.opacity(isDark ? 0.08 : 0.07) }
    var keycapStroke: Color { content.opacity(isDark ? 0.10 : 0.12) }
    /// Soft top highlight that sells the glass edge.
    var sheen: Color { Color.white.opacity(isDark ? 0.06 : 0.35) }
    var shadow: Color { Color.black.opacity(isDark ? 0.45 : 0.16) }
    var contactShadow: Color { Color.black.opacity(isDark ? 0.35 : 0.08) }
}

extension Animation {
    /// cubic-bezier(0.22, 1, 0.36, 1) — the house curve.
    static func pickerEase(_ duration: Double) -> Animation {
        .timingCurve(0.22, 1, 0.36, 1, duration: duration)
    }
}
