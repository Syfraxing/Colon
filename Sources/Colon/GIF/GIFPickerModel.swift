import AppKit
import ColonCore
import SwiftUI

/// Layout constants for the GIF panel.
enum GIFMetrics {
    static let cardWidth: CGFloat = 480
    static let cardHeight: CGFloat = 520
    static let searchFieldHeight: CGFloat = 52
    static let footerHeight: CGFloat = 44
    static let columns = 3
    static let gridInset: CGFloat = 10
    static let gridSpacing: CGFloat = 6
    static let cellHeight: CGFloat = 112
    static let cellRadius: CGFloat = 9

    static var cellWidth: CGFloat {
        (cardWidth - gridInset * 2 - gridSpacing * CGFloat(columns - 1)) / CGFloat(columns)
    }
}

/// Why the panel cannot show results.
enum GIFProblem: Equatable {
    case noKey
    case badKey
    case rateLimited
    case offline
    case failed
}

/// State of the GIF panel. The controller drives it; the views only read it and report input.
@MainActor
final class GIFPickerModel: ObservableObject {
    enum Phase: Equatable {
        /// Reading the key from the Keychain.
        case starting
        /// First request for the current text is in flight and nothing is on screen yet.
        case loading
        case results
        case empty
        case problem(GIFProblem)
    }

    @Published var searchText = ""
    @Published var phase: Phase = .starting
    @Published private(set) var results: [GIFResult] = []
    @Published private(set) var selectedID: String?
    /// A newer request is in flight while older results stay on screen.
    @Published var isLoading = false
    /// Jev is reranking the visible results.
    @Published var isRefining = false
    /// The visible order came from Jev.
    @Published var isReranked = false
    /// The GIF being downloaded for insertion.
    @Published var insertingID: String?
    /// Short message in the footer (e.g. a failed download).
    @Published var notice: String?
    @Published var isPresented = false
    /// Bumped to make the grid scroll the selection into view.
    @Published private(set) var scrollRequest = 0

    let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    /// Whether results are shown for typed terms (vs. trending).
    var isTrending: Bool { searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The user moved the selection with the keyboard since the results arrived: keep the
    /// order still (a late Jev answer must not shuffle the grid under them).
    private(set) var navigatedByKeyboard = false

    weak var searchField: NSTextField?
    var onSearchTextChange: ((String) -> Void)?
    var onPick: ((GIFResult) -> Void)?
    var onCancel: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onRetry: (() -> Void)?

    var selectedResult: GIFResult? {
        selectedID.flatMap { id in results.first { $0.id == id } }
    }

    var selectedIndex: Int? {
        selectedID.flatMap { id in results.firstIndex { $0.id == id } }
    }

    func reset() {
        searchText = ""
        phase = .starting
        results = []
        selectedID = nil
        isLoading = false
        isRefining = false
        isReranked = false
        insertingID = nil
        notice = nil
        navigatedByKeyboard = false
    }

    /// New provider results: select the first one, scroll to the top.
    func setResults(_ newResults: [GIFResult]) {
        navigatedByKeyboard = false
        isReranked = false
        notice = nil
        let update = {
            self.results = newResults
            self.selectedID = newResults.first?.id
            self.phase = newResults.isEmpty ? .empty : .results
        }
        if reduceMotion {
            update()
        } else {
            withAnimation(.pickerEase(0.22), update)
        }
        scrollRequest += 1
    }

    /// Jev's order for the same results. Ignored once the user has navigated with the keyboard.
    /// Returns whether the order was applied.
    @discardableResult
    func applyReranked(_ reordered: [GIFResult]) -> Bool {
        guard !navigatedByKeyboard, Set(reordered.map(\.id)) == Set(results.map(\.id)) else { return false }
        let selectFirst = selectedID == results.first?.id
        let update = {
            self.results = reordered
            if selectFirst { self.selectedID = reordered.first?.id }
            self.isReranked = true
        }
        if reduceMotion {
            update()
        } else {
            withAnimation(.pickerEase(0.4), update)
        }
        scrollRequest += 1
        return true
    }

    func showProblem(_ problem: GIFProblem) {
        results = []
        selectedID = nil
        isLoading = false
        isRefining = false
        phase = .problem(problem)
    }

    // MARK: Input

    func searchTextDidChange(_ text: String) {
        searchText = text
        notice = nil
        onSearchTextChange?(text)
    }

    /// Field editor commands. Returns true when handled.
    func handleCommand(_ selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            move(dx: 0, dy: -1)
        case #selector(NSResponder.moveDown(_:)):
            move(dx: 0, dy: 1)
        case #selector(NSResponder.moveLeft(_:)):
            guard !results.isEmpty else { return false }
            move(dx: -1, dy: 0)
        case #selector(NSResponder.moveRight(_:)):
            guard !results.isEmpty else { return false }
            move(dx: 1, dy: 0)
        case #selector(NSResponder.insertNewline(_:)):
            pickSelected()
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            break
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel?()
        default:
            return false
        }
        return true
    }

    func move(dx: Int, dy: Int) {
        guard !results.isEmpty else { return }
        navigatedByKeyboard = true
        let current = selectedIndex ?? 0
        let next = Self.index(after: current, dx: dx, dy: dy, count: results.count, columns: GIFMetrics.columns)
        guard next != selectedIndex else { return }
        selectedID = results[next].id
        scrollRequest += 1
    }

    /// Grid navigation: ←/→ wrap across rows, ↑/↓ stay in the column and stop at the edges.
    static func index(after current: Int, dx: Int, dy: Int, count: Int, columns: Int) -> Int {
        guard count > 0 else { return 0 }
        var next = current + dx
        if dy != 0 {
            let candidate = current + dy * columns
            next = (0..<count).contains(candidate) ? candidate : current
            // ↓ from the second-to-last row into a shorter last row: land on its last item.
            if dy > 0, candidate >= count, current / columns < (count - 1) / columns { next = count - 1 }
        }
        return min(max(next, 0), count - 1)
    }

    func hover(_ id: String) {
        guard selectedID != id, insertingID == nil else { return }
        selectedID = id
    }

    func pickSelected() {
        guard insertingID == nil, let result = selectedResult else { return }
        onPick?(result)
    }

    func pick(_ result: GIFResult) {
        guard insertingID == nil else { return }
        selectedID = result.id
        onPick?(result)
    }
}
