import AppKit
import EmojifyCore
import SwiftUI

/// What the picker mirrors from `SuggestionEngine`.
struct PickerSnapshot {
    var query: String
    var suggestions: [Suggestion]
    var isRefining: Bool
    var jevStatus: JevStatus
}

/// A keyboard-driven request to bring a row or cell into view; `serial` makes repeats fire.
struct ScrollRequest: Equatable {
    let id: String
    let serial: Int
}

/// View state for the panel. The controller feeds it; the SwiftUI tree observes it, so the
/// hosting view is built once and only diffs on change.
@MainActor
final class PickerModel: ObservableObject {
    enum Mode { case inline, search }
    enum Placement { case below, above }

    @Published var mode: Mode = .inline
    @Published var placement: Placement = .below
    /// Drives the appear/disappear scale + travel.
    @Published var isPresented = false

    @Published private(set) var query = ""
    @Published private(set) var suggestions: [Suggestion] = []
    @Published private(set) var isRefining = false
    @Published private(set) var jevStatus: JevStatus = .idle
    @Published private(set) var selectedIndex = 0

    // Search mode
    @Published private(set) var searchText = ""
    @Published private(set) var sections: [EmojiSection] = []
    @Published private(set) var gridSelection = GridPosition(section: 0, item: 0)
    /// Cell or row id the scroll view should bring into view (keyboard navigation only).
    @Published private(set) var scrollTarget: ScrollRequest?

    /// Rows the inline card can show; the panel is sized for this many.
    var maxRows = 8

    var snapshotProvider: () -> PickerSnapshot = { PickerSnapshot(query: "", suggestions: [], isRefining: false, jevStatus: .idle) }
    /// The glyph to show and insert (skin tone applied).
    var displayText: (Emoji) -> String = { $0.char }
    var onPick: ((Emoji) -> Void)?
    var onCancel: (() -> Void)?
    var onSearchTextChange: ((String) -> Void)?

    weak var searchField: NSTextField?

    private var syncScheduled = false
    /// The user moved the highlight for the current query: keep their emoji and freeze the order.
    private var userMovedHighlight = false

    let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    // MARK: Derived

    var isGridVisible: Bool { mode == .search && searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    var selectedSuggestion: Suggestion? {
        suggestions.indices.contains(selectedIndex) ? suggestions[selectedIndex] : nil
    }

    var selectedGridEmoji: Emoji? {
        guard sections.indices.contains(gridSelection.section) else { return nil }
        let section = sections[gridSelection.section]
        return section.emoji.indices.contains(gridSelection.item) ? section.emoji[gridSelection.item] : nil
    }

    /// The emoji Return would insert right now.
    var currentEmoji: Emoji? { isGridVisible ? selectedGridEmoji : selectedSuggestion?.emoji }

    var inlineCardHeight: CGFloat { PickerMetrics.inlineCardHeight(rows: suggestions.count) }

    // MARK: Engine mirroring

    /// Coalesces the engine's several `@Published` writes per update into one sync after they land.
    func scheduleSync() {
        guard !syncScheduled else { return }
        syncScheduled = true
        DispatchQueue.main.async { [weak self] in self?.syncIfNeeded() }
    }

    func syncIfNeeded() {
        guard syncScheduled else { return }
        syncScheduled = false
        apply(snapshotProvider())
    }

    /// Forces a fresh read, e.g. right before showing.
    func syncNow() {
        syncScheduled = true
        syncIfNeeded()
    }

    private func apply(_ snapshot: PickerSnapshot) {
        let queryChanged = snapshot.query != query
        let limit = mode == .inline ? maxRows : Int.max
        var incoming = Array(snapshot.suggestions.prefix(limit))
        let previousID = selectedSuggestion?.id

        if queryChanged {
            userMovedHighlight = false
        } else if userMovedHighlight {
            incoming = Self.preservingOrder(of: suggestions, updatedWith: incoming)
        }

        let reordered = !queryChanged && incoming.map(\.id) != suggestions.map(\.id)
        let newIndex: Int
        if queryChanged || !userMovedHighlight {
            newIndex = 0
        } else if let previousID, let i = incoming.firstIndex(where: { $0.id == previousID }) {
            newIndex = i
        } else {
            newIndex = min(selectedIndex, max(incoming.count - 1, 0))
        }

        let update = {
            self.query = snapshot.query
            self.suggestions = incoming
            self.selectedIndex = newIndex
            if self.isRefining != snapshot.isRefining { self.isRefining = snapshot.isRefining }
            if self.jevStatus != snapshot.jevStatus { self.jevStatus = snapshot.jevStatus }
        }
        if !isPresented {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t, update)
        } else if reordered && !reduceMotion {
            // A Jev rerank of the same query: rows glide to their new places.
            withAnimation(.spring(response: 0.34, dampingFraction: 0.86), update)
        } else {
            // A keystroke: only the height eases; rows swap without fanfare.
            withAnimation(.easeOut(duration: 0.1), update)
        }
        if mode == .search, queryChanged || reordered, let id = selectedSuggestion?.id {
            requestScroll("row/\(id)")
        }
    }

    /// Keeps the rows the user is looking at in place; probabilities still update.
    private static func preservingOrder(of current: [Suggestion], updatedWith incoming: [Suggestion]) -> [Suggestion] {
        let byID = Dictionary(incoming.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let kept = current.compactMap { byID[$0.id] }
        let keptIDs = Set(kept.map(\.id))
        return kept + incoming.filter { !keptIDs.contains($0.id) }
    }

    // MARK: Selection

    func moveSelection(by delta: Int) {
        syncIfNeeded()
        if isGridVisible {
            moveGrid(dx: 0, dy: delta)
            return
        }
        guard !suggestions.isEmpty, delta != 0 else { return }
        let count = suggestions.count
        let next = ((selectedIndex + delta) % count + count) % count
        userMovedHighlight = true
        setSelection(next)
        if mode == .search { requestScroll("row/\(suggestions[next].id)") }
    }

    /// Mouse hover / programmatic selection of a row.
    func selectRow(_ index: Int) {
        guard suggestions.indices.contains(index), index != selectedIndex else { return }
        userMovedHighlight = true
        setSelection(index)
    }

    private func setSelection(_ index: Int) {
        if reduceMotion {
            selectedIndex = index
        } else {
            withAnimation(.pickerEase(0.12)) { selectedIndex = index }
        }
    }

    func moveGrid(dx: Int, dy: Int) {
        let counts = sections.map(\.emoji.count)
        let next = GridNavigator.move(gridSelection, dx: dx, dy: dy, counts: counts, columns: PickerMetrics.gridColumns)
        guard next != gridSelection else { return }
        gridSelection = next
        requestScroll(sections[next.section].cellID(next.item))
    }

    func hoverGrid(_ position: GridPosition) {
        if gridSelection != position { gridSelection = position }
    }

    func jump(toSection index: Int) {
        guard sections.indices.contains(index), !sections[index].emoji.isEmpty else { return }
        gridSelection = GridPosition(section: index, item: 0)
        requestScroll("section/\(sections[index].id)")
    }

    private func requestScroll(_ id: String) {
        scrollTarget = ScrollRequest(id: id, serial: (scrollTarget?.serial ?? 0) + 1)
    }

    // MARK: Search mode

    func beginSearch(sections: [EmojiSection]) {
        searchText = ""
        self.sections = sections
        gridSelection = GridPosition(section: 0, item: 0)
        if let first = sections.first { requestScroll("section/\(first.id)") }
    }

    func endSearch() {
        searchText = ""
    }

    func searchTextDidChange(_ text: String) {
        guard text != searchText else { return }
        searchText = text
        onSearchTextChange?(text)
    }

    /// Commands from the search field editor. Returns true when handled.
    func handleSearchCommand(_ selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            if isGridVisible { moveGrid(dx: 0, dy: -1) } else { moveSelection(by: -1) }
        case #selector(NSResponder.moveDown(_:)):
            if isGridVisible { moveGrid(dx: 0, dy: 1) } else { moveSelection(by: 1) }
        case #selector(NSResponder.moveLeft(_:)):
            guard isGridVisible else { return false }
            moveGrid(dx: -1, dy: 0)
        case #selector(NSResponder.moveRight(_:)):
            guard isGridVisible else { return false }
            moveGrid(dx: 1, dy: 0)
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
            pickCurrent()
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel?()
        default:
            return false
        }
        return true
    }

    func pickCurrent() {
        syncIfNeeded()
        if let emoji = currentEmoji { onPick?(emoji) }
    }

    func pick(_ emoji: Emoji) {
        onPick?(emoji)
    }
}
