/// Per-capture highlight state of the inline picker. It belongs to one capture and one query:
/// a new query or a new capture starts unengaged, with no pointer pill and an unfrozen order.
public struct PickerHighlight: Equatable, Sendable {
    /// The user moved the highlight with the keyboard. For the bare-trigger strip this is
    /// "engaged": only then do Return/Tab insert, so only then is a row highlighted.
    public private(set) var isEngaged = false
    /// The pointer rests on a row of the unengaged strip (clicking it inserts).
    public private(set) var pointerHighlight = false
    /// The user moved the highlight (keyboard or pointer): keep their row and freeze the order.
    public private(set) var userMovedHighlight = false
    /// Set by `beginCapture`; the next `sync` starts clean even if the query is unchanged.
    private var startsCapture = false

    public init() {}

    /// The picker hid, or a new capture is about to be shown. The bare-trigger strip's query is always `""`, so a
    /// query comparison alone cannot tell two captures apart.
    public mutating func beginCapture() {
        startsCapture = true
    }

    /// An engine snapshot arrived. Returns true when the state was reset (new query or new
    /// capture): the highlight goes back to the first row and the order is not frozen.
    @discardableResult
    public mutating func sync(queryChanged: Bool) -> Bool {
        guard queryChanged || startsCapture else { return false }
        self = PickerHighlight()
        return true
    }

    /// Arrow keys moved the highlight, or the strip was engaged.
    public mutating func moveByKeyboard() {
        userMovedHighlight = true
        isEngaged = true
    }

    /// The pointer selected a row. `onUnengagedStrip`: the faint pill appears under it.
    public mutating func point(onUnengagedStrip: Bool) {
        userMovedHighlight = true
        if onUnengagedStrip { pointerHighlight = true }
    }
}
