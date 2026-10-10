import AppKit
import Combine
import EmojifyCore
import SwiftUI

/// The floating glass picker. A non-activating `NSPanel` hosting SwiftUI that never steals focus
/// from the app being typed in. OWNER: picker worker.
@MainActor
final class PickerPanelController {
    /// Called when the user clicks a suggestion.
    var onPick: ((Emoji) -> Void)?
    /// Called when the panel dismisses itself (e.g. click outside).
    var onDismiss: (() -> Void)?

    private let engine: SuggestionEngine
    private let settings: AppSettings
    private let store: EmojiStore
    private let usage: UsageStore
    let model = PickerModel()
    private let panel = PickerPanel()
    private let hostingView: PickerHostingView

    private var cancellables = Set<AnyCancellable>()
    private var clickMonitors: [Any] = []
    /// Requested by `show`/`showSearch` and not yet hidden.
    private var isActive = false
    /// The panel is actually ordered in (inline mode skips this while the list is empty).
    private var isOnScreen = false
    /// Bumped on every show so a pending fade-out never orders out a re-shown panel.
    private var presentationToken = 0
    /// Caret rect the inline panel was positioned for; x stays anchored while the query grows.
    private var anchorCaret: CGRect?
    /// The anchor came from the mouse because no caret was known yet.
    private var anchorIsFallback = false
    private var searchContext = PredictionContext()
    private lazy var categorySections = EmojiCatalog.categorySections(from: store)

    init(engine: SuggestionEngine, settings: AppSettings, store: EmojiStore = .shared, usage: UsageStore = .shared) {
        self.engine = engine
        self.settings = settings
        self.store = store
        self.usage = usage
        hostingView = PickerHostingView(rootView: PickerRootView(model: model))
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        hostingView.mouseHandler = self

        model.snapshotProvider = { [weak engine] in
            guard let engine else { return PickerSnapshot(query: "", suggestions: [], isRefining: false, jevStatus: .idle) }
            return PickerSnapshot(query: engine.query, suggestions: engine.suggestions,
                                  isRefining: engine.isRefining, jevStatus: engine.jevStatus)
        }
        model.displayText = { [weak engine] emoji in engine?.output(for: emoji) ?? emoji.char }
        model.onPick = { [weak self] emoji in self?.onPick?(emoji) }
        model.onCancel = { [weak self] in self?.dismiss() }
        model.onSearchTextChange = { [weak self] text in self?.searchTextChanged(text) }
        panel.onCancel = { [weak self] in self?.dismiss() }

        engine.objectWillChange
            .sink { [weak model] _ in model?.scheduleSync() }
            .store(in: &cancellables)
        model.onSynced = { [weak self] in self?.updateInlinePresence() }

        let center = NotificationCenter.default
        center.publisher(for: NSWindow.didResignKeyNotification, object: panel)
            .sink { [weak self] _ in
                guard let self, self.isOnScreen, self.model.mode == .search else { return }
                self.dismiss()
            }
            .store(in: &cancellables)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .sink { [weak self] _ in
                guard let self, self.isOnScreen else { return }
                self.dismiss()
            }
            .store(in: &cancellables)
        center.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                guard let self, self.isOnScreen else { return }
                self.dismiss()
            }
            .store(in: &cancellables)

        model.syncNow()
        hostingView.layoutSubtreeIfNeeded()
        // Group the catalog off the show path so the first hotkey press does not pay for it.
        DispatchQueue.main.async { [weak self] in _ = self?.categorySections }
    }

    /// True while the panel is on screen. In inline mode an empty result list keeps the panel
    /// hidden (the input layer then lets Enter/Tab/arrows through).
    var isVisible: Bool {
        isOnScreen
    }

    /// Currently highlighted suggestion.
    var selectedSuggestion: Suggestion? {
        model.syncIfNeeded()
        return model.selectedSuggestion
    }

    /// Whether `screenPoint` (Cocoa screen coords) falls on the visible card, so the input layer
    /// can let clicks on the picker through instead of treating them as an interruption.
    func contains(screenPoint: CGPoint) -> Bool {
        guard isOnScreen else { return false }
        return cardRectInWindow.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY).contains(screenPoint)
    }

    /// Show (or update) near `caret` (Cocoa screen coords). nil caret: near the mouse.
    /// Repeated calls while active only update/resize; the panel stays anchored at the first
    /// anchor (the trigger character) unless a real anchor replaces a fallback one.
    func show(near caret: CGRect?) {
        let switching = model.mode != .inline
        if switching {
            if isOnScreen { retract(animated: false) }
            model.mode = .inline
            panel.allowsKey = false
        }
        model.maxRows = settings.maxResults
        model.syncNow()

        if let caret {
            if anchorCaret == nil || anchorIsFallback || needsReposition(for: caret) {
                anchorCaret = caret
                anchorIsFallback = false
                positionInline(for: caret)
            }
        } else if anchorCaret == nil {
            let fallback = Self.mouseAnchor()
            anchorCaret = fallback
            anchorIsFallback = true
            positionInline(for: fallback)
        }
        isActive = true
        updateInlinePresence()
    }

    /// Programmatic hide. Never calls `onDismiss`.
    func hide() {
        guard isActive else { return }
        isActive = false
        anchorCaret = nil
        anchorIsFallback = false
        panel.allowsKey = false
        retract(animated: true)
        // The search text stays during the fade; `beginSearch` clears it on the next open.
        searchContext = PredictionContext()
    }

    /// Search mode (global hotkey): the panel becomes key and shows its own search field
    /// so the user can browse/search without typing into the target app. Picking calls `onPick`.
    func showSearch() {
        let target = NSWorkspace.shared.frontmostApplication
        searchContext = PredictionContext(appName: target?.localizedName, bundleID: target?.bundleIdentifier)
        if isOnScreen { retract(animated: false) }

        var sections = categorySections
        if let frequent = EmojiCatalog.frequentSection(store: store, usage: usage) {
            sections.insert(frequent, at: 0)
        }
        model.mode = .search
        model.maxRows = Int.max
        model.beginSearch(sections: sections)
        model.syncNow()

        anchorCaret = nil
        anchorIsFallback = false
        positionSearch()
        isActive = true
        panel.allowsKey = true
        present(makeKey: true)
        focusSearchField(retries: 3)
    }

    func moveSelection(by delta: Int) {
        model.moveSelection(by: delta)
    }

    // MARK: Presentation

    /// Inline: on screen exactly when active with at least one suggestion.
    private func updateInlinePresence() {
        guard model.mode == .inline else { return }
        let wanted = isActive && !model.suggestions.isEmpty
        if wanted && !isOnScreen {
            present(makeKey: false)
        } else if !wanted && isOnScreen {
            retract(animated: false)
        }
    }

    private func present(makeKey: Bool) {
        presentationToken += 1
        let wasOnScreen = panel.isVisible
        isOnScreen = true
        installClickMonitors()

        if makeKey {
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }

        if model.reduceMotion {
            model.isPresented = true
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                panel.animator().alphaValue = 1
            }
            return
        }
        if !wasOnScreen { panel.alphaValue = 0 }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
            panel.animator().alphaValue = 1
        }
        withAnimation(.pickerEase(0.15)) { model.isPresented = true }
    }

    /// Takes the panel off screen: a 100 ms fade, or at once (empty list, mode switch, reduce motion).
    private func retract(animated: Bool) {
        guard isOnScreen else { return }
        isOnScreen = false
        removeClickMonitors()
        presentationToken += 1
        let token = presentationToken

        guard animated, !model.reduceMotion else {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { model.isPresented = false }
            panel.alphaValue = 0
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.presentationToken == token else { return }
                self.panel.orderOut(nil)
            }
        })
        withAnimation(.easeIn(duration: 0.1)) { model.isPresented = false }
    }

    /// A dismissal the panel starts itself (click outside, Space change, Esc in search mode).
    private func dismiss() {
        guard isActive else { return }
        hide()
        onDismiss?()
    }

    private func focusSearchField(retries: Int) {
        if let field = model.searchField, field.window === panel {
            panel.makeFirstResponder(field)
            (field.currentEditor() as? NSTextView)?.insertionPointColor = NSColor(PickerTheme.accent)
            return
        }
        guard retries > 0 else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isOnScreen, self.model.mode == .search else { return }
            self.focusSearchField(retries: retries - 1)
        }
    }

    private func searchTextChanged(_ text: String) {
        let query = text.trimmingCharacters(in: .whitespaces)
        if query.isEmpty {
            engine.reset()
        } else {
            engine.update(query: query, context: searchContext)
        }
    }

    // MARK: Positioning

    private static func mouseAnchor() -> CGRect {
        let mouse = NSEvent.mouseLocation
        return CGRect(x: mouse.x, y: mouse.y - 12, width: 1, height: 24)
    }

    private static func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// The anchor is the trigger character, fixed for a capture; only a genuinely different
    /// anchor (another line, or a caret that moved left of it) moves the panel.
    private func needsReposition(for caret: CGRect) -> Bool {
        guard let anchor = anchorCaret else { return true }
        let tolerance = max(4, anchor.height / 2)
        return abs(caret.midY - anchor.midY) > tolerance || caret.minX < anchor.minX - 2
    }

    private func positionInline(for caret: CGRect) {
        let rows = settings.maxResults
        let cardSize = CGSize(width: PickerMetrics.inlineWidth, height: PickerMetrics.inlineCardHeight(rows: rows))
        let panelSize = PickerMetrics.panelSize(card: cardSize)
        let center = CGPoint(x: caret.midX, y: caret.midY)
        let visible = (Self.screen(containing: center)?.visibleFrame) ?? CGRect(origin: .zero, size: cardSize)
        let inset = PickerMetrics.screenInset
        let gap = PickerMetrics.caretGap

        var cardX = caret.minX - PickerMetrics.glyphLeading
        cardX = min(max(cardX, visible.minX + inset), visible.maxX - inset - cardSize.width)

        let roomBelow = caret.minY - gap - visible.minY
        let roomAbove = visible.maxY - caret.maxY - gap
        let placeBelow = roomBelow >= cardSize.height || roomBelow >= roomAbove
        let cardTop: CGFloat
        if placeBelow {
            cardTop = min(caret.minY - gap, visible.maxY - inset)
            model.placement = .below
        } else {
            cardTop = min(caret.maxY + gap + cardSize.height, visible.maxY - inset)
            model.placement = .above
        }
        let origin = CGPoint(x: cardX - PickerMetrics.shadowMargin,
                             y: cardTop - cardSize.height - PickerMetrics.shadowMargin)
        panel.setFrame(CGRect(origin: origin, size: panelSize), display: false)
    }

    private func positionSearch() {
        let cardSize = CGSize(width: PickerMetrics.searchWidth, height: PickerMetrics.searchHeight)
        let panelSize = PickerMetrics.panelSize(card: cardSize)
        let visible = Self.screen(containing: NSEvent.mouseLocation)?.visibleFrame ?? CGRect(origin: .zero, size: panelSize)
        let cardX = visible.midX - cardSize.width / 2
        // Centre of the card on the upper third line, kept on screen.
        var cardTop = visible.maxY - visible.height / 3 + cardSize.height / 2
        cardTop = min(cardTop, visible.maxY - PickerMetrics.screenInset)
        cardTop = max(cardTop, visible.minY + cardSize.height + PickerMetrics.screenInset)
        let origin = CGPoint(x: cardX - PickerMetrics.shadowMargin,
                             y: cardTop - cardSize.height - PickerMetrics.shadowMargin)
        model.placement = .below
        panel.setFrame(CGRect(origin: origin, size: panelSize), display: false)
    }

    /// The visible card in window coordinates (bottom-left origin).
    private var cardRectInWindow: CGRect {
        let size = panel.frame.size
        let margin = PickerMetrics.shadowMargin
        switch model.mode {
        case .search:
            return CGRect(x: margin, y: margin, width: size.width - margin * 2, height: size.height - margin * 2)
        case .inline:
            let height = model.inlineCardHeight
            let y = model.placement == .below ? size.height - margin - height : margin
            return CGRect(x: margin, y: y, width: PickerMetrics.inlineWidth, height: height)
        }
    }

    private func rowIndex(at windowPoint: NSPoint) -> Int? {
        let card = cardRectInWindow
        guard card.contains(windowPoint), !model.suggestions.isEmpty else { return nil }
        let offset = card.maxY - PickerMetrics.listInset - windowPoint.y
        guard offset >= 0 else { return nil }
        let index = Int(offset / PickerMetrics.rowHeight)
        return model.suggestions.indices.contains(index) ? index : nil
    }

    // MARK: Click-away

    private func installClickMonitors() {
        guard clickMonitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.handleClick(atScreenPoint: NSEvent.mouseLocation) }
        }) {
            clickMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                if event.window !== self.panel {
                    self.handleClick(atScreenPoint: NSEvent.mouseLocation)
                }
            }
            return event
        }) {
            clickMonitors.append(local)
        }
    }

    private func removeClickMonitors() {
        clickMonitors.forEach(NSEvent.removeMonitor)
        clickMonitors.removeAll()
    }

    private func handleClick(atScreenPoint point: NSPoint) {
        guard isOnScreen else { return }
        let card = cardRectInWindow.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)
        if !card.contains(point) { dismiss() }
    }
}

extension PickerPanelController: PickerMouseHandling {
    func pickerMouseMoved(at windowPoint: NSPoint) -> Bool {
        guard model.mode == .inline else { return false }
        if isOnScreen, let index = rowIndex(at: windowPoint) { model.selectRow(index) }
        return true
    }

    func pickerMouseDown(at windowPoint: NSPoint) -> Bool {
        guard isOnScreen else { return true }
        if !cardRectInWindow.contains(windowPoint) {
            dismiss()
            return true
        }
        guard model.mode == .inline else { return false }
        if let index = rowIndex(at: windowPoint) {
            model.selectRow(index)
            onPick?(model.suggestions[index].emoji)
        }
        return true
    }
}
