import AppKit
import ColonCore
import SwiftUI

/// Search mode: a focused field on top, a category grid (empty query) or ranked rows below,
/// and a preview footer for the highlighted emoji.
struct SearchPickerView: View {
    @ObservedObject var model: PickerModel
    let theme: PickerTheme

    var body: some View {
        VStack(spacing: 0) {
            searchBar
                .frame(height: PickerMetrics.searchFieldHeight)
            Rectangle().fill(theme.divider).frame(height: 1)
            Group {
                if model.showsGrid {
                    VStack(spacing: 0) {
                        CategoryStrip(model: model, theme: theme)
                        EmojiGrid(model: model, theme: theme)
                    }
                } else if model.suggestions.isEmpty {
                    EmptyResultsView(query: model.searchText.trimmingCharacters(in: .whitespaces), theme: theme)
                        .transition(.opacity)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical) {
                            SuggestionList(model: model, theme: theme, interactive: true)
                                .padding(PickerMetrics.listInset)
                        }
                        .scrollIndicators(.never)
                        .onChange(of: model.scrollTarget) { _, target in
                            guard let id = target?.id, id.hasPrefix("row/") else { return }
                            proxy.scrollTo(id)
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            SearchFooter(model: model, theme: theme)
                .frame(height: PickerMetrics.searchFooterHeight)
        }
        .overlay(alignment: .top) {
            if model.isRefining { RefiningShimmer(theme: theme).transition(.opacity) }
        }
        .animation(.easeOut(duration: 0.2), value: model.isRefining)
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(theme.tertiary)
            SearchField(model: model, theme: theme)
                .frame(height: 24)
            if model.isRefining || model.jevStatus != .idle, !model.showsGrid {
                JevBadge(status: model.jevStatus, isRefining: model.isRefining, theme: theme)
                    .transition(.opacity)
            }
            Keycap("esc", theme: theme)
        }
        .padding(.horizontal, 16)
    }
}

/// AppKit text field so the controller can focus it deterministically and the field editor's
/// arrow/return/escape commands reach the model before the text view eats them.
struct SearchField: NSViewRepresentable {
    let model: PickerModel
    let theme: PickerTheme

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 17)
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = context.coordinator
        model.searchField = field
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != model.searchText { field.stringValue = model.searchText }
        field.textColor = NSColor(theme.text)
        field.placeholderAttributedString = NSAttributedString(string: "Search emoji", attributes: [
            .foregroundColor: NSColor(theme.tertiary),
            .font: NSFont.systemFont(ofSize: 17),
        ])
        (field.currentEditor() as? NSTextView)?.insertionPointColor = NSColor(theme.accent)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        let model: PickerModel

        init(model: PickerModel) {
            self.model = model
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            model.searchTextDidChange(field.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            model.handleSearchCommand(selector)
        }
    }
}

private struct CategoryStrip: View {
    @ObservedObject var model: PickerModel
    let theme: PickerTheme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(model.sections.enumerated()), id: \.element.id) { index, section in
                let isCurrent = index == model.gridSelection.section
                Image(systemName: section.symbol)
                    .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? theme.accent : theme.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(isCurrent ? theme.accent.opacity(theme.isDark ? 0.14 : 0.12) : .clear)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { model.jump(toSection: index) }
                    .help(section.title)
            }
        }
        .animation(.pickerEase(0.18), value: model.gridSelection.section)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.divider).frame(height: 1)
        }
    }
}

private struct EmojiGrid: View {
    @ObservedObject var model: PickerModel
    let theme: PickerTheme

    private let columns = Array(repeating: GridItem(.fixed(PickerMetrics.gridCell), spacing: PickerMetrics.gridSpacing),
                                count: PickerMetrics.gridColumns)

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVGrid(columns: columns, alignment: .leading, spacing: PickerMetrics.gridSpacing) {
                    ForEach(Array(model.sections.enumerated()), id: \.element.id) { sectionIndex, section in
                        Section {
                            ForEach(section.emoji.indices, id: \.self) { item in
                                let position = GridPosition(section: sectionIndex, item: item)
                                EmojiCell(glyph: model.displayText(section.emoji[item]),
                                          isSelected: model.gridSelection == position,
                                          theme: theme)
                                    .id(section.cellID(item))
                                    .onContinuousHover { phase in
                                        if case .active = phase { model.hoverGrid(position) }
                                    }
                                    .onTapGesture { model.pick(section.emoji[item]) }
                            }
                        } header: {
                            Text(section.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(theme.tertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, 6)
                                .padding(.top, sectionIndex == 0 ? 4 : 12)
                                .padding(.bottom, 4)
                                .id("section/\(section.id)")
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
            .scrollIndicators(.never)
            .onChange(of: model.scrollTarget) { _, target in
                guard let id = target?.id, !id.hasPrefix("row/") else { return }
                if id.hasPrefix("section/") {
                    withAnimation(.pickerEase(0.3)) { proxy.scrollTo(id, anchor: .top) }
                } else {
                    proxy.scrollTo(id)
                }
            }
        }
    }
}

private struct EmojiCell: View {
    let glyph: String
    let isSelected: Bool
    let theme: PickerTheme

    var body: some View {
        Text(glyph)
            .font(.system(size: 26))
            .fixedSize()
            .frame(width: PickerMetrics.gridCell, height: PickerMetrics.gridCell)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? theme.selection : .clear)
            )
            .scaleEffect(isSelected ? 1.06 : 1)
            .animation(.pickerEase(0.14), value: isSelected)
            .contentShape(Rectangle())
    }
}

private struct SearchFooter: View {
    @ObservedObject var model: PickerModel
    let theme: PickerTheme

    var body: some View {
        let emoji = model.showsGrid ? model.selectedGridEmoji : model.selectedSuggestion?.emoji
        HStack(spacing: 10) {
            if let emoji {
                Text(model.displayText(emoji))
                    .font(.system(size: 26))
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(emoji.name.prefix(1).uppercased() + emoji.name.dropFirst())
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(theme.text)
                        .lineLimit(1)
                    Text(":\(ShortcodeMatcher.displayShortcode(for: emoji, query: model.searchText)):")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(theme.secondary)
                        .lineLimit(1)
                }
                .transaction { $0.animation = nil }
            }
            Spacer(minLength: 8)
            if emoji != nil {
                HStack(spacing: 6) {
                    Keycap(model.showsGrid ? "←↑↓→" : "↑↓", theme: theme)
                    Text("move").foregroundStyle(theme.tertiary)
                    Keycap("↩", theme: theme).padding(.leading, 4)
                    Text("insert").foregroundStyle(theme.tertiary)
                }
                .font(.system(size: 10.5, weight: .medium))
                .fixedSize()
            }
        }
        .padding(.horizontal, 14)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.divider).frame(height: 1)
        }
    }
}
