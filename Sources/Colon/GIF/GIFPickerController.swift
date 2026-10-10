import AppKit
import Combine
import ColonCore
import SwiftUI

/// The GIF search panel (`:gif ` in any app). A key but non-activating panel like emoji search
/// mode: the app being typed in stays frontmost, the panel's search field takes the keyboard,
/// and a pick is pasted into that app once the panel is ordered out.
///
/// Searches go to GIPHY with the user's own key; when a Jev key exists the results are reranked
/// for the search terms (and, if the user opted in, the text being written). Queries, results
/// and media live in memory only and are dropped when the panel closes.
@MainActor
final class GIFPickerController {
    /// Posted by the input layer after it deleted `<trigger>gif `.
    /// `userInfo["context"]` is the `PredictionContext` of the field being typed in.
    static let openNotification = Notification.Name("ColonOpenGIFSearch")
    static let debounce: Duration = .milliseconds(250)

    /// Opens Settings on the GIFs tab (the no-key state links there).
    var onOpenSettings: (() -> Void)?
    /// Called just before the panel shows, so the coordinator can close the emoji picker.
    var onWillShow: (() -> Void)?
    /// Called after a GIF was put into the target app (sound/haptic feedback).
    var onInserted: (() -> Void)?

    private let settings: AppSettings
    private let makeClient: (String) -> GIFSearching
    private let makeRanker: (String) -> GIFRanking
    let model = GIFPickerModel()
    private let loader = GIFImageLoader()
    private let panel = GIFPanel()
    private let hostingView: NSHostingView<GIFRootView>

    private var client: GIFSearching?
    private var ranker: GIFRanking?
    private var context = PredictionContext()
    private var target: NSRunningApplication?
    /// Results per normalized query ("" = trending) for this panel session only.
    private var cache: [String: (results: [GIFResult], reranked: Bool)] = [:]
    private var generation = 0
    private var keyTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var rerankTask: Task<Void, Never>?
    private var insertTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var clickMonitors: [Any] = []
    private(set) var isVisible = false

    init(settings: AppSettings,
         makeClient: @escaping (String) -> GIFSearching = { GIPHYClient(apiKey: $0) },
         makeRanker: @escaping (String) -> GIFRanking = { JevGIFRanker(apiKey: $0) }) {
        self.settings = settings
        self.makeClient = makeClient
        self.makeRanker = makeRanker
        hostingView = NSHostingView(rootView: GIFRootView(model: model, loader: loader))
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        panel.onCancel = { [weak self] in self?.hide() }

        model.onSearchTextChange = { [weak self] text in self?.scheduleSearch(text, debounce: true) }
        model.onPick = { [weak self] result in self?.insert(result) }
        model.onCancel = { [weak self] in self?.hide() }
        model.onOpenSettings = { [weak self] in
            self?.hide()
            self?.onOpenSettings?()
        }
        model.onRetry = { [weak self] in self?.retry() }

        let center = NotificationCenter.default
        center.publisher(for: Self.openNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in
                let context = note.userInfo?["context"] as? PredictionContext ?? PredictionContext()
                self?.show(context: context, target: NSWorkspace.shared.frontmostApplication)
            }
            .store(in: &cancellables)
        center.publisher(for: NSWindow.didResignKeyNotification, object: panel)
            .sink { [weak self] _ in
                guard let self, self.isVisible, self.insertTask == nil else { return }
                self.hide()
            }
            .store(in: &cancellables)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .sink { [weak self] _ in self?.hide() }
            .store(in: &cancellables)
        center.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.hide() }
            .store(in: &cancellables)

        // Leftovers from a previous run (the app quit before the 10 minute cleanup).
        DispatchQueue.global(qos: .utility).async { MainActor.assumeIsolated { GIFInserter.removeAllFiles() } }
    }

    // MARK: Show / hide

    /// Opens the panel for `target` (the app that receives the GIF). No-op when GIF search is off.
    func show(context: PredictionContext, target: NSRunningApplication?) {
        guard settings.gifSearchEnabled else { return }
        onWillShow?()
        if isVisible { hide() }

        self.target = target
        var context = context
        if context.appName == nil, context.bundleID == nil {
            context.appName = target?.localizedName
            context.bundleID = target?.bundleIdentifier
        }
        if !(settings.useJev && settings.sendTextContext) { context.textBeforeTrigger = nil }
        self.context = context

        model.reset()
        position()
        isVisible = true
        present()
        focusSearchField(retries: 3)
        loadKeysAndStart()
    }

    /// Takes the panel off screen at once (it is key: a fade would swallow keys meant for the
    /// target app) and forgets the session's queries, results and media.
    func hide() {
        guard isVisible else { return }
        isVisible = false
        generation += 1
        [keyTask, searchTask, rerankTask, insertTask].forEach { $0?.cancel() }
        keyTask = nil
        searchTask = nil
        rerankTask = nil
        insertTask = nil
        removeClickMonitors()

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { model.isPresented = false }
        panel.alphaValue = 0
        panel.orderOut(nil)

        cache.removeAll()
        client = nil
        ranker = nil
        target = nil
        context = PredictionContext()
        loader.purge()
        withTransaction(transaction) { model.reset() }
    }

    func contains(screenPoint: CGPoint) -> Bool {
        isVisible && cardRect.contains(screenPoint)
    }

    private func present() {
        installClickMonitors()
        panel.alphaValue = model.reduceMotion ? 1 : 0
        panel.makeKeyAndOrderFront(nil)
        if model.reduceMotion {
            model.isPresented = true
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
            panel.animator().alphaValue = 1
        }
        withAnimation(.pickerEase(0.18)) { model.isPresented = true }
    }

    private func focusSearchField(retries: Int) {
        if let field = model.searchField, field.window === panel {
            panel.makeFirstResponder(field)
            (field.currentEditor() as? NSTextView)?.insertionPointColor = NSColor(PickerTheme.accent)
            return
        }
        guard retries > 0 else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible else { return }
            self.focusSearchField(retries: retries - 1)
        }
    }

    // MARK: Searching

    /// Reads both keys off the main thread (a Keychain read can block on an access prompt).
    private func loadKeysAndStart() {
        let wantsJev = settings.useJev
        let session = generation
        keyTask = Task { [weak self] in
            let keys = await Task.detached(priority: .userInitiated) {
                (gif: KeychainStore.key(for: .gif), jev: wantsJev ? KeychainStore.jevAPIKey : nil)
            }.value
            guard let self, self.isVisible, self.generation == session else { return }
            self.keyTask = nil
            guard let gifKey = keys.gif else {
                self.model.showProblem(.noKey)
                return
            }
            self.client = self.makeClient(gifKey)
            self.ranker = keys.jev.map(self.makeRanker)
            self.scheduleSearch(self.model.searchText, debounce: false)
        }
    }

    private func retry() {
        cache.removeAll()
        if client == nil {
            model.phase = .starting
            loadKeysAndStart()
        } else {
            scheduleSearch(model.searchText, debounce: false)
        }
    }

    private func scheduleSearch(_ text: String, debounce: Bool) {
        guard isVisible, let client else { return }
        generation += 1
        let session = generation
        searchTask?.cancel()
        rerankTask?.cancel()
        model.isRefining = false
        let terms = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let cacheKey = terms.lowercased()

        if let cached = cache[cacheKey] {
            model.isLoading = false
            model.setResults(cached.results)
            model.isReranked = cached.reranked
            loader.cancel(except: Set(cached.results.map(\.preview.url)))
            if !cached.reranked { rerank(cached.results, terms: terms, cacheKey: cacheKey, session: session) }
            return
        }

        if model.results.isEmpty, model.phase != .empty { model.phase = .loading }
        model.isLoading = true
        searchTask = Task { [weak self] in
            if debounce {
                try? await Task.sleep(for: Self.debounce)
            }
            guard !Task.isCancelled else { return }
            do {
                let results = terms.isEmpty
                    ? try await client.trending(limit: GIPHYClient.defaultLimit)
                    : try await client.search(terms, limit: GIPHYClient.defaultLimit)
                guard let self, !Task.isCancelled, self.generation == session else { return }
                self.cache[cacheKey] = (results, false)
                self.model.isLoading = false
                self.model.setResults(results)
                self.loader.cancel(except: Set(results.map(\.preview.url)))
                self.rerank(results, terms: terms, cacheKey: cacheKey, session: session)
            } catch {
                guard let self, !Task.isCancelled, self.generation == session else { return }
                self.handle(error)
            }
        }
    }

    /// Jev reorders results already on screen; it never delays showing them.
    private func rerank(_ results: [GIFResult], terms: String, cacheKey: String, session: Int) {
        guard let ranker, !terms.isEmpty, results.count > 1 else { return }
        let context = context
        model.isRefining = true
        rerankTask = Task { [weak self] in
            let reordered = await GIFRerank.rerank(results, terms: terms, context: context, ranker: ranker)
            guard let self, !Task.isCancelled, self.generation == session else { return }
            self.model.isRefining = false
            if let reordered, self.model.applyReranked(reordered) {
                self.cache[cacheKey] = (reordered, true)
            }
        }
    }

    private func handle(_ error: Error) {
        model.isLoading = false
        let problem: GIFProblem
        switch error {
        case GIFError.missingKey: problem = .noKey
        case GIFError.unauthorized: problem = .badKey
        case GIFError.rateLimited: problem = .rateLimited
        case let urlError as URLError:
            switch urlError.code {
            case .cancelled: return
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
                problem = .offline
            default:
                problem = .failed
            }
        case is CancellationError: return
        default: problem = .failed
        }
        // Keep what is on screen for transient failures; key problems replace it.
        if !model.results.isEmpty, problem != .noKey, problem != .badKey {
            model.notice = problem == .rateLimited ? "GIPHY’s hourly limit reached" : "Couldn’t update results"
            return
        }
        model.showProblem(problem)
    }

    // MARK: Inserting

    private func insert(_ result: GIFResult) {
        guard isVisible, insertTask == nil else { return }
        model.insertingID = result.id
        model.notice = nil
        let target = target
        insertTask = Task { [weak self] in
            guard let self else { return }
            do {
                let data = try await self.loader.data(for: result.full.url)
                guard !Task.isCancelled, self.isVisible else { return }
                let fileURL = try GIFInserter.writeTemporaryFile(data, named: result.suggestedFileName)
                let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
                let paste = target.map {
                    !$0.isTerminated && $0.processIdentifier != getpid() && $0.processIdentifier == frontmost
                } ?? false
                self.insertTask = nil
                // Order out first: key focus is back in the target app before ⌘V is posted.
                self.hide()
                GIFInserter.insert(data, fileURL: fileURL, paste: paste)
                self.onInserted?()
            } catch {
                guard !Task.isCancelled, self.isVisible else { return }
                if let urlError = error as? URLError, urlError.code == .cancelled { return }
                self.insertTask = nil
                self.model.insertingID = nil
                self.model.notice = "Couldn’t download that GIF. Try again or pick another."
            }
        }
    }

    // MARK: Positioning

    private func position() {
        let cardSize = CGSize(width: GIFMetrics.cardWidth, height: GIFMetrics.cardHeight)
        let margin = PickerMetrics.shadowMargin
        let panelSize = CGSize(width: cardSize.width + margin * 2, height: cardSize.height + margin * 2)
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(origin: .zero, size: panelSize)
        let cardX = visible.midX - cardSize.width / 2
        // Centre of the card on the upper third line, kept on screen (same spot as emoji search).
        var cardTop = visible.maxY - visible.height / 3 + cardSize.height / 2
        cardTop = min(cardTop, visible.maxY - PickerMetrics.screenInset)
        cardTop = max(cardTop, visible.minY + cardSize.height + PickerMetrics.screenInset)
        let origin = CGPoint(x: cardX - margin, y: cardTop - cardSize.height - margin)
        panel.setFrame(CGRect(origin: origin, size: panelSize), display: false)
    }

    /// The visible card in screen coordinates.
    private var cardRect: CGRect {
        panel.frame.insetBy(dx: PickerMetrics.shadowMargin, dy: PickerMetrics.shadowMargin)
    }

    // MARK: Click-away

    private func installClickMonitors() {
        guard clickMonitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.handleClick(at: NSEvent.mouseLocation) }
        }) {
            clickMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                if event.window === self.panel {
                    if !self.cardRect.contains(NSEvent.mouseLocation) { self.hide() }
                } else {
                    self.handleClick(at: NSEvent.mouseLocation)
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

    private func handleClick(at point: NSPoint) {
        guard isVisible, !cardRect.contains(point) else { return }
        hide()
    }
}
