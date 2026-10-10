import ColonCore
import SwiftUI

/// Root of the single, long-lived hosting view.
struct PickerRootView: View {
    @ObservedObject var model: PickerModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = PickerTheme(scheme)
        switch model.mode {
        case .inline:
            // Leading-aligned: a narrow compact card keeps its first emoji under the trigger.
            GlassCard(theme: theme,
                      size: model.inlineCardSize,
                      alignment: model.placement == .below ? .topLeading : .bottomLeading,
                      isPresented: model.isPresented,
                      reduceMotion: model.reduceMotion) {
                switch model.layout {
                case .list: InlinePickerView(model: model, theme: theme)
                case .compact: CompactPickerView(model: model, theme: theme)
                }
            }
        case .search:
            GlassCard(theme: theme,
                      size: CGSize(width: PickerMetrics.searchWidth, height: PickerMetrics.searchHeight),
                      alignment: .top,
                      isPresented: model.isPresented,
                      reduceMotion: model.reduceMotion) {
                SearchPickerView(model: model, theme: theme)
            }
        }
    }
}

// MARK: - Glass card

/// The rounded glass surface: blur, neutral tint, hairline, sheen and a soft shadow drawn only
/// outside the card so it never muddies the translucency.
struct GlassCard<Content: View>: View {
    let theme: PickerTheme
    let size: CGSize
    let alignment: Alignment
    let isPresented: Bool
    let reduceMotion: Bool
    @ViewBuilder var content: Content

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: PickerMetrics.cornerRadius, style: .continuous)
    }

    var body: some View {
        let fromBelow = alignment.vertical == .bottom
        content
            .frame(width: size.width, height: size.height, alignment: fromBelow ? .bottom : .top)
            .background {
                ZStack {
                    GlassBackground(cornerRadius: PickerMetrics.cornerRadius, isDark: theme.isDark)
                    shape.fill(theme.tint)
                }
            }
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(theme.hairline, lineWidth: 1)
                shape.inset(by: 1)
                    .strokeBorder(LinearGradient(colors: [theme.sheen, .clear], startPoint: .top, endPoint: .center), lineWidth: 1)
            }
            .background { CardShadow(theme: theme) }
            .scaleEffect(isPresented || reduceMotion ? 1 : 0.96, anchor: fromBelow ? .bottom : .top)
            .offset(y: isPresented || reduceMotion ? 0 : (fromBelow ? 4 : -4))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            .padding(PickerMetrics.shadowMargin)
    }
}

private struct CardShadow: View {
    let theme: PickerTheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PickerMetrics.cornerRadius, style: .continuous)
        shape.fill(Color.black)
            .shadow(color: theme.shadow, radius: 18, y: 10)
            .shadow(color: theme.contactShadow, radius: 1.5, y: 0.5)
            .mask {
                ShadowCutout(cornerRadius: PickerMetrics.cornerRadius, inset: PickerMetrics.shadowMargin)
                    .fill(style: FillStyle(eoFill: true))
                    .padding(-PickerMetrics.shadowMargin)
            }
            .allowsHitTesting(false)
    }
}

/// Everything around the card, nothing inside it.
private struct ShadowCutout: Shape {
    let cornerRadius: CGFloat
    let inset: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        path.addRoundedRect(in: rect.insetBy(dx: inset, dy: inset),
                            cornerSize: CGSize(width: cornerRadius, height: cornerRadius),
                            style: .continuous)
        return path
    }
}

// MARK: - Inline

struct InlinePickerView: View {
    @ObservedObject var model: PickerModel
    let theme: PickerTheme

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if model.suggestions.isEmpty {
                    // Never on screen (the controller hides an empty inline panel); keeps the
                    // card at `inlineCardHeight(rows: 0)` so hit-testing and layout agree.
                    Color.clear.frame(height: PickerMetrics.emptyHeight)
                } else {
                    VStack(spacing: 0) {
                        if model.showsRecentsHeader {
                            RecentsLabel(theme: theme)
                                .padding(.leading, 10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .frame(height: PickerMetrics.recentsHeaderHeight)
                                .transition(.opacity)
                        }
                        SuggestionList(model: model, theme: theme, interactive: false)
                            .frame(height: CGFloat(model.suggestions.count) * PickerMetrics.rowHeight, alignment: .top)
                    }
                }
            }
            .padding(PickerMetrics.listInset)

            PickerFooter(theme: theme, jevStatus: model.jevStatus, isRefining: model.isRefining,
                         hint: model.isStripUnengaged ? .choose : .insert, showsJev: !model.isRecents)
                .frame(height: PickerMetrics.footerHeight)
        }
        .overlay(alignment: .top) {
            if model.isRefining { RefiningShimmer(theme: theme).transition(.opacity) }
        }
        .animation(.easeOut(duration: 0.2), value: model.isRefining)
    }
}

/// Rows plus the sliding selection fill. `interactive` adds SwiftUI hover/click (search mode, where
/// the panel is key); inline mode gets mouse events from the controller instead.
struct SuggestionList: View {
    @ObservedObject var model: PickerModel
    let theme: PickerTheme
    let interactive: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            if !model.suggestions.isEmpty && model.showsSelection {
                SelectionPill(theme: theme, isTentative: model.isSelectionTentative, pulse: model.insertPulse)
                    .frame(height: PickerMetrics.rowHeight)
                    .offset(y: CGFloat(model.selectedIndex) * PickerMetrics.rowHeight)
            }
            VStack(spacing: 0) {
                ForEach(Array(model.suggestions.enumerated()), id: \.element.id) { index, suggestion in
                    SuggestionRow(suggestion: suggestion,
                                  displayText: model.displayText,
                                  query: model.query,
                                  isSelected: model.showsSelection && index == model.selectedIndex,
                                  pulse: model.insertPulse,
                                  reduceMotion: model.reduceMotion,
                                  theme: theme)
                        .id("row/\(suggestion.id)")
                        .contentShape(Rectangle())
                        .modifier(RowInteraction(enabled: interactive, index: index, item: suggestion.item, model: model))
                        .transition(.opacity)
                }
            }
        }
    }
}

private struct RowInteraction: ViewModifier {
    let enabled: Bool
    let index: Int
    let item: Suggestion.Item
    let model: PickerModel

    func body(content: Content) -> some View {
        if enabled {
            content
                .onContinuousHover { phase in
                    if case .active = phase { model.selectRow(index) }
                }
                .onTapGesture { model.pick(item) }
        } else {
            content
        }
    }
}

struct SuggestionRow: View {
    let suggestion: Suggestion
    let displayText: (Emoji) -> String
    let query: String
    let isSelected: Bool
    let pulse: InsertPulse?
    let reduceMotion: Bool
    let theme: PickerTheme

    var body: some View {
        HStack(spacing: 10) {
            SuggestionGlyph(suggestion: suggestion, displayText: displayText, size: 22, selectedScale: 1.08,
                            isSelected: isSelected, pulse: pulse, reduceMotion: reduceMotion, theme: theme)
                .frame(width: 26, height: 26)
            switch suggestion.item {
            case .emoji(let emoji):
                emojiDetails(emoji)
            case .snippet(let snippet):
                ShortcodeText(code: snippet.trigger, query: query, theme: theme, isSelected: isSelected, closes: false)
                    .layoutPriority(1)
                Spacer(minLength: 8)
                // Text preview instead of a name: the row reads as "this expands to …".
                nameText(SnippetPreview.oneLine(snippet.text))
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: PickerMetrics.rowHeight)
    }

    @ViewBuilder
    private func emojiDetails(_ emoji: Emoji) -> some View {
        let code = ShortcodeMatcher.displayShortcode(for: emoji, query: query)
        ShortcodeText(code: code, query: query, theme: theme, isSelected: isSelected)
            .layoutPriority(1)
        Spacer(minLength: 8)
        if let probability = suggestion.jevProbability {
            JevMeter(probability: probability, isSelected: isSelected, theme: theme)
        } else if !Self.nameRepeats(code: code, name: emoji.name) {
            // The full name, else the longest run of whole words that fits, else nothing:
            // never "grinning fac…".
            ViewThatFits(in: .horizontal) {
                ForEach(Self.wordPrefixes(of: emoji.name), id: \.self) { name in
                    nameText(name).fixedSize()
                }
                Color.clear.frame(width: 0, height: 0)
            }
        }
    }

    /// `:fire:` next to "fire" says nothing new.
    private static func nameRepeats(code: String, name: String) -> Bool {
        code.replacingOccurrences(of: "_", with: " ").lowercased() == name.lowercased()
    }

    /// Connectors that open a trailing clause ("… with smiling eyes").
    private static let connectors: Set<String> = ["with", "of", "and", "in", "on", "or", "for", "to"]

    /// "grinning face with smiling eyes" → [itself, "grinning face", "grinning"]: whole clauses
    /// go first, then single words, so a shortened name still reads as a phrase.
    static func wordPrefixes(of name: String) -> [String] {
        let words = name.split(separator: " ").map(String.init)
        var result = [name]
        var end = words.count
        while end > 1 {
            if let cut = words[..<end].lastIndex(where: { connectors.contains($0.lowercased()) }), cut > 0 {
                end = cut
            } else {
                end -= 1
            }
            let prefix = words[..<end].joined(separator: " ")
            if prefix != result.last { result.append(prefix) }
        }
        return result
    }

    private func nameText(_ name: String) -> some View {
        Text(name)
            .font(.system(size: 11))
            .foregroundStyle(theme.tertiary)
            .lineLimit(1)
    }
}

/// `:shortcode:` in SF Mono with the matched part emphasised. Snippet triggers drop the closing colon.
struct ShortcodeText: View {
    let code: String
    let query: String
    let theme: PickerTheme
    let isSelected: Bool
    var closes = true

    var body: some View {
        Text(attributed)
            .font(.system(size: 13, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var attributed: AttributedString {
        let matched = Set(ShortcodeMatcher.matchedOffsets(in: code, query: query) ?? [])
        let rest = theme.text.opacity(isSelected ? 0.78 : 0.62)
        var result = AttributedString(":")
        result.foregroundColor = theme.tertiary
        var run = ""
        var runMatched = false
        func flush() {
            guard !run.isEmpty else { return }
            var piece = AttributedString(run)
            piece.foregroundColor = runMatched ? theme.text : rest
            if runMatched { piece.font = .system(size: 13, weight: .semibold, design: .monospaced) }
            result += piece
            run = ""
        }
        for (i, ch) in code.enumerated() {
            let isMatch = matched.contains(i)
            if isMatch != runMatched { flush(); runMatched = isMatch }
            run.append(ch)
        }
        flush()
        if closes {
            var close = AttributedString(":")
            close.foregroundColor = theme.tertiary
            result += close
        }
        return result
    }
}

/// The glyph column: the emoji itself, or a text badge for a snippet.
struct SuggestionGlyph: View {
    let suggestion: Suggestion
    let displayText: (Emoji) -> String
    let size: CGFloat
    let selectedScale: CGFloat
    let isSelected: Bool
    let pulse: InsertPulse?
    let reduceMotion: Bool
    let theme: PickerTheme

    var body: some View {
        switch suggestion.item {
        case .emoji(let emoji):
            PulsingGlyph(glyph: displayText(emoji), id: suggestion.id, size: size, selectedScale: selectedScale,
                         isSelected: isSelected, pulse: pulse, reduceMotion: reduceMotion)
        case .snippet:
            SnippetBadge(size: size, theme: theme)
                .scaleEffect(isSelected ? selectedScale : 1)
                .animation(.pickerEase(0.16), value: isSelected)
        }
    }
}

/// Marks a snippet row: an accent quote mark on a soft tile where an emoji would be.
struct SnippetBadge: View {
    let size: CGFloat
    let theme: PickerTheme

    var body: some View {
        Image(systemName: "text.quote")
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(theme.accent)
            .frame(width: size * 1.1, height: size * 1.1)
            .background(
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .fill(theme.accent.opacity(theme.isDark ? 0.18 : 0.14))
            )
    }
}

enum SnippetPreview {
    /// The snippet on one line: line breaks shown as "↵", runs of whitespace collapsed.
    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty }
            .joined(separator: " ↵ ")
    }
}

/// Tiny probability bar + percentage once Jev has scored a row. Quiet by default so the
/// shortcodes stay the headline; the highlighted row's figure steps up to secondary.
struct JevMeter: View {
    let probability: Double
    let isSelected: Bool
    let theme: PickerTheme

    var body: some View {
        let p = min(max(probability, 0), 1)
        HStack(spacing: 6) {
            Capsule()
                .fill(theme.content.opacity(theme.isDark ? 0.09 : 0.08))
                .frame(width: 28, height: 3)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(theme.accent.opacity(isSelected ? 1 : 0.8))
                        .frame(width: max(3, 28 * p), height: 3)
                }
            Text(p < 0.01 ? "<1%" : "\(Int((p * 100).rounded()))%")
                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                .foregroundStyle(isSelected ? theme.secondary : theme.tertiary)
                .frame(minWidth: 26, alignment: .trailing)
                .contentTransition(.numericText())
        }
        .animation(.pickerEase(0.25), value: p)
        .animation(.pickerEase(0.16), value: isSelected)
    }
}

/// Search mode's "nothing matched", centred in the results area. (Inline mode has no empty
/// state: the panel hides itself when the list is empty.)
struct EmptyResultsView: View {
    let query: String
    let theme: PickerTheme

    var body: some View {
        VStack(spacing: 6) {
            Text("🫥")
                .font(.system(size: 34))
                .opacity(0.9)
                .padding(.bottom, 4)
            Text(query.isEmpty ? "No emoji yet" : "No emoji for “\(query)”")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("Try another word, or a shortcode like “tada”")
                .font(.system(size: 11.5))
                .foregroundStyle(theme.tertiary)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Footer & chrome

struct PickerFooter: View {
    enum Hint { case insert, choose }

    let theme: PickerTheme
    let jevStatus: JevStatus
    let isRefining: Bool
    var hint: Hint = .insert
    /// Recents never go to Jev, so the badge would say nothing there.
    var showsJev = true

    var body: some View {
        HStack(spacing: 6) {
            switch hint {
            case .insert:
                Keycap("↩", theme: theme)
                Keycap("⇥", theme: theme)
                Text("insert").foregroundStyle(theme.tertiary)
                Keycap("esc", theme: theme).padding(.leading, 6)
                Text("close").foregroundStyle(theme.tertiary)
                Spacer(minLength: 4)
                if showsJev { JevBadge(status: jevStatus, isRefining: isRefining, theme: theme) }
            case .choose:
                // Recents: ↩ still types a newline until ↓ engages the strip, so say how to pick.
                Keycap("↓", theme: theme)
                Text("choose").foregroundStyle(theme.tertiary)
                Spacer(minLength: 4)
                Text("or keep typing to search").foregroundStyle(theme.tertiary)
            }
        }
        .font(.system(size: 10.5, weight: .medium))
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.divider).frame(height: 1)
        }
    }
}

struct Keycap: View {
    let label: String
    let theme: PickerTheme

    init(_ label: String, theme: PickerTheme) {
        self.label = label
        self.theme = theme
    }

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(theme.secondary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 4)
            .frame(minWidth: 17, minHeight: 16)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(theme.keycapFill))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(theme.keycapStroke, lineWidth: 0.5))
    }
}

/// "Jev" when the reranker is live, "Local" when it is off or keyless; dot shows health.
struct JevBadge: View {
    let status: JevStatus
    let isRefining: Bool
    let theme: PickerTheme

    var body: some View {
        HStack(spacing: 4) {
            if isRefining {
                Image(systemName: "sparkle")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(theme.accent)
                    .symbolEffect(.pulse, options: .repeating)
            } else {
                Circle().fill(dotColor).frame(width: 5, height: 5)
            }
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isLive ? theme.secondary : theme.tertiary)
        }
        .padding(.horizontal, 7)
        .frame(height: 17)
        .background(Capsule().fill(isRefining ? theme.accent.opacity(0.14) : theme.keycapFill))
        .overlay(Capsule().strokeBorder(isRefining ? theme.accent.opacity(0.35) : theme.keycapStroke, lineWidth: 0.5))
        .animation(.pickerEase(0.2), value: isRefining)
        .help(helpText)
    }

    private var isLive: Bool {
        switch status {
        case .idle, .ok: true
        case .disabled, .noKey, .error: false
        }
    }

    private var label: String {
        switch status {
        case .disabled, .noKey: "Local"
        case .idle, .ok, .error: "Jev"
        }
    }

    private var dotColor: Color {
        switch status {
        case .ok: theme.accent
        case .idle: theme.accent.opacity(0.55)
        case .error: Color(red: 1.0, green: 0.62, blue: 0.25)
        case .disabled, .noKey: theme.content.opacity(0.3)
        }
    }

    private var helpText: String {
        switch status {
        case .disabled: "Jev reranking is off"
        case .noKey: "Add a Jev API key in Settings to rerank"
        case .idle: "Jev reranking ready"
        case let .ok(ms): "Reranked by Jev in \(ms) ms"
        case let .error(message): "Jev unavailable: \(message)"
        }
    }
}

/// A thin accent glint that sweeps the top edge while Jev is refining.
struct RefiningShimmer: View {
    let theme: PickerTheme

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let phase = CGFloat((t / 1.1).truncatingRemainder(dividingBy: 1))
            GeometryReader { geo in
                let w = geo.size.width
                let glint = w * 0.45
                LinearGradient(colors: [theme.accent.opacity(0), theme.accent, theme.accent.opacity(0)],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: glint, height: 1.5)
                    .offset(x: -glint + (w + glint) * phase)
                    .blur(radius: 0.3)
            }
        }
        .frame(height: 1.5)
        .padding(.top, 0.5)
        .padding(.horizontal, PickerMetrics.cornerRadius)
        .allowsHitTesting(false)
    }
}
