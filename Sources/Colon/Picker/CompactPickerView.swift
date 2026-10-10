import ColonCore
import SwiftUI

// MARK: - Compact inline layout

/// One row of emoji with the sliding selection pill; the highlighted emoji's `:shortcode:`
/// (and Jev meter) is the caption underneath. Mouse events come from the controller.
struct CompactPickerView: View {
    @ObservedObject var model: PickerModel
    let theme: PickerTheme

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                if !model.suggestions.isEmpty && model.showsSelection {
                    SelectionPill(theme: theme, isTentative: model.isSelectionTentative, pulse: model.insertPulse)
                        .frame(width: PickerMetrics.compactCell, height: PickerMetrics.compactCell)
                        .offset(x: CGFloat(model.selectedIndex) * PickerMetrics.compactCell)
                }
                HStack(spacing: 0) {
                    ForEach(Array(model.suggestions.enumerated()), id: \.element.id) { index, suggestion in
                        PulsingGlyph(glyph: model.displayText(suggestion.emoji), id: suggestion.id,
                                     size: PickerMetrics.compactGlyph, selectedScale: 1.1,
                                     isSelected: model.showsSelection && index == model.selectedIndex,
                                     pulse: model.insertPulse, reduceMotion: model.reduceMotion)
                            .frame(width: PickerMetrics.compactCell, height: PickerMetrics.compactCell)
                            .transition(.opacity)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: PickerMetrics.compactCell)
            .padding(PickerMetrics.listInset)

            CompactCaption(model: model, theme: theme)
                .frame(height: PickerMetrics.compactCaptionHeight)
        }
        .overlay(alignment: .top) {
            if model.isRefining { RefiningShimmer(theme: theme).transition(.opacity) }
        }
        .animation(.easeOut(duration: 0.2), value: model.isRefining)
    }
}

/// `:shortcode:` of the highlighted emoji on the left; Jev meter, Jev badge or the recents tag on the right.
private struct CompactCaption: View {
    @ObservedObject var model: PickerModel
    let theme: PickerTheme

    var body: some View {
        let selected = model.showsSelection ? model.selectedSuggestion : nil
        HStack(spacing: 8) {
            if model.isStripUnengaged && selected == nil {
                RecentsLabel(theme: theme)
                    .transition(.opacity)
            } else if let selected {
                ShortcodeText(code: ShortcodeMatcher.displayShortcode(for: selected.emoji, query: model.query),
                              query: model.query, theme: theme, isSelected: true)
                    .id(selected.id)
                    .transition(.opacity)
            }
            Spacer(minLength: 6)
            Group {
                if model.isStripUnengaged {
                    // ↩ still types a newline until → engages the strip.
                    HStack(spacing: 6) {
                        Keycap("→", theme: theme)
                        Text("choose")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(theme.tertiary)
                    }
                } else if model.isRecents {
                    RecentsLabel(theme: theme)
                } else if let probability = selected?.jevProbability {
                    JevMeter(probability: probability, isSelected: true, theme: theme)
                } else {
                    JevBadge(status: model.jevStatus, isRefining: model.isRefining, theme: theme)
                }
            }
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .animation(.pickerEase(0.12), value: selected?.id)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.divider).frame(height: 1)
        }
    }
}

// MARK: - Shared pieces (list + compact)

/// Small "Recent" label shown when the trigger alone lists the most-used emoji.
struct RecentsLabel: View {
    let theme: PickerTheme

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 9, weight: .semibold))
            Text("Recent")
                .font(.system(size: 10.5, weight: .semibold))
        }
        .foregroundStyle(theme.tertiary)
        .accessibilityElement(children: .combine)
    }
}

/// The highlight behind the selected row or cell. Tentative (recents the user has not arrowed
/// into yet) draws it fainter. A ⌘↩ insert flashes it with the accent.
struct SelectionPill: View {
    let theme: PickerTheme
    let isTentative: Bool
    let pulse: InsertPulse?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PickerMetrics.cornerRadius - PickerMetrics.listInset, style: .continuous)
        shape.fill(theme.selection)
            .opacity(isTentative ? 0.55 : 1)
            .animation(.pickerEase(0.16), value: isTentative)
            .keyframeAnimator(initialValue: 0.0, trigger: pulse?.serial ?? 0) { content, flash in
                content.overlay {
                    shape.fill(theme.accent.opacity(0.22 * flash))
                        .overlay(shape.strokeBorder(theme.accent.opacity(0.55 * flash), lineWidth: 1))
                }
            } keyframes: { _ in
                LinearKeyframe(1, duration: 0.05)
                CubicKeyframe(0, duration: 0.5)
            }
    }
}

/// An emoji glyph that grows a touch when selected and pops when it was just inserted with ⌘↩.
struct PulsingGlyph: View {
    let glyph: String
    let id: String
    let size: CGFloat
    let selectedScale: CGFloat
    let isSelected: Bool
    let pulse: InsertPulse?
    let reduceMotion: Bool

    /// Bumped only when the pulse targets this glyph, so a selection change never replays it.
    @State private var pops = 0

    var body: some View {
        Text(glyph)
            .font(.system(size: size))
            .scaleEffect(isSelected ? selectedScale : 1)
            .animation(.pickerEase(0.16), value: isSelected)
            .keyframeAnimator(initialValue: CGFloat(1), trigger: pops) { content, scale in
                content.scaleEffect(scale)
            } keyframes: { _ in
                CubicKeyframe(1.3, duration: 0.08)
                SpringKeyframe(1, duration: 0.42, spring: .init(response: 0.32, dampingRatio: 0.55))
            }
            .onChange(of: pulse) { _, new in
                if let new, new.id == id, !reduceMotion { pops += 1 }
            }
    }
}
