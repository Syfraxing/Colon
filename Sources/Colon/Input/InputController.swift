import AppKit
import Carbon.HIToolbox
import Combine
import ColonCore

/// Receives trigger events from the keyboard tap. Implemented by `AppCoordinator`.
@MainActor
protocol InputControllerDelegate: AnyObject {
    /// Picker should appear/update. `caret` is in Cocoa screen coordinates (bottom-left origin), nil if unknown.
    func inputShow(query: String, caret: CGRect?, context: PredictionContext)
    func inputHide()
    func inputMoveSelection(by delta: Int)
    /// Return the emoji string to insert for the current selection, or nil to just close.
    func inputCommitSelection() -> String?
    /// ⌘↩: return the emoji string for the current selection and record its use, but keep the
    /// picker open for another pick. nil when there is no selection.
    func inputCommitSelectionKeepOpen() -> String?
    /// Return the emoji string for an exact shortcode (closing-trigger auto replace), nil if unknown.
    func inputCommit(shortcode: String) -> String?
    /// Whether a Cocoa screen point lies inside the picker (a click there is a pick, not an interrupt).
    func inputIsPointInPicker(_ point: CGPoint) -> Bool
    /// The picker is on screen with a selectable row (`picker.isVisible && picker.selectedSuggestion != nil`).
    /// Picker keys are swallowed only while this is true.
    func inputPickerIsVisible() -> Bool
}

/// Owns the CGEventTap, runs `TriggerEngine`, honours exclusions/secure input,
/// and performs the deletion + insertion. OWNER: input worker.
///
/// Threading: the tap lives on the **main run loop**. The engine, the delegate and the picker are
/// all main-actor state, so the callback can decide synchronously — including asking the delegate
/// whether a row exists before swallowing Enter/Tab — and post the replacement through the tap
/// proxy, which puts it ahead of any keystroke still queued behind the one being handled. Fast
/// typists therefore can never interleave with an insertion, without locks or a hold queue. The
/// callback does no cross-process work (Accessibility reads run on `axQueue` after it returns),
/// so it stays well under a millisecond and a busy target app cannot stall the tap.
@MainActor
final class InputController: ObservableObject {
    weak var delegate: InputControllerDelegate?
    private let settings: AppSettings

    /// Health of the pipeline for the menu bar; refreshed on changes and by the ~2 s health poll.
    @Published private(set) var status: InputStatus = .noPermission

    init(settings: AppSettings) {
        self.settings = settings
        engine = TriggerEngine(
            trigger: AppSettings.isValidTrigger(settings.triggerString) ? settings.triggerString : ":",
            minQueryLength: settings.minQueryLength,
            autoReplaceOnClosingTrigger: settings.autoReplaceOnClosingTrigger,
            showsRecentsOnTrigger: settings.showRecentsOnTrigger,
            horizontalLayout: settings.pickerLayout == .compact,
            shortcodeExists: { EmojiStore.shared.emoji(forShortcode: $0) != nil }
        )
    }

    /// True once the tap is installed (requires Accessibility permission).
    private(set) var isRunning = false

    // MARK: State

    private var engine: TriggerEngine
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    /// The coordinator asked us to run; the health timer installs the tap once permitted.
    private var wantsRunning = false
    private var healthTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []

    /// Cached so the callback never asks another process.
    private var frontmostApp: NSRunningApplication?
    /// The current input source is a plain keyboard layout (not an IME composing text).
    private var isKeyboardLayoutInput = true

    /// Picker visibility as driven by us (the engine may want it shown before the AX probe returns).
    private var pickerVisible = false
    /// Probe result, anchor and context of the current capture.
    private var capture = CaptureSession()
    private var stripWork: DispatchWorkItem?
    private var idleWork: DispatchWorkItem?

    private let axQueue = DispatchQueue(label: "Colon.input.ax", qos: .userInteractive)
    /// Delays before re-probing when the focused element could not be read: Chromium/Electron build
    /// their tree asynchronously once asked, which takes seconds after a fresh launch. About 4 s in
    /// all; keys are never swallowed meanwhile because the picker is not shown.
    private static let probeRetryDelays: [TimeInterval] = [0.15, 0.25, 0.35, 0.5, 0.75, 1, 1]
    /// A capture with no keystroke for this long is abandoned.
    private static let idleTimeout: TimeInterval = 10
    private static let healthInterval: TimeInterval = 2
    /// The bare-trigger strip waits this long for another key, so `a :)` or `Time: ` never flash it.
    private static let stripDelay: TimeInterval = 0.1

    // MARK: Lifecycle

    /// Install the event tap. Returns false if Accessibility permission is missing.
    @discardableResult
    func start() -> Bool {
        wantsRunning = true
        startObserving()
        startHealthTimer()
        defer { refreshStatus() }
        guard settings.isEnabled else { return AXIsProcessTrusted() }
        return installTap()
    }

    func stop() {
        wantsRunning = false
        healthTimer?.invalidate()
        healthTimer = nil
        removeTap()
        observers.forEach {
            NSWorkspace.shared.notificationCenter.removeObserver($0)
            DistributedNotificationCenter.default().removeObserver($0)
        }
        observers.removeAll()
        cancellables.removeAll()
        resetCapture()
        refreshStatus()
    }

    /// The UI dismissed the picker (click outside, Esc in panel). Reset tracking.
    func cancelTracking() {
        InputLog.debug("capture cancelled by UI")
        engine.reset()
        endCapture(notifyDelegate: false)
    }

    /// The user clicked a suggestion with the mouse: delete the typed `:query` and insert `text`.
    func commitFromMouse(_ text: String) {
        let deleteCount = engine.typedLength ?? 0
        InputLog.debug("commit from mouse, deleteCount \(deleteCount)")
        engine.reset()
        endCapture(notifyDelegate: false)
        Inserter.replace(deleteCount: deleteCount, with: text, method: settings.insertionMethod, poster: .hid)
    }

    // MARK: Tap

    private func installTap() -> Bool {
        if tap != nil { return true }
        // Probe trust without creating a tap: creating one would raise the system prompt before
        // onboarding has explained it.
        guard AXIsProcessTrusted() else {
            InputLog.debug("accessibility not granted")
            return false
        }
        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { proxy, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                // Installed on the main run loop, so the callback always runs on the main thread.
                return MainActor.assumeIsolated {
                    let controller = Unmanaged<InputController>.fromOpaque(refcon).takeUnretainedValue()
                    return controller.handle(proxy: proxy, type: type, event: event)
                }
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            InputLog.debug("tapCreate failed")
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        tapSource = source
        isRunning = true
        InputLog.debug("tap installed")
        prepareAccessibility(for: frontmostApp)
        return true
    }

    private func removeTap() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tap = nil
        tapSource = nil
        isRunning = false
    }

    /// A non-nil tap is not necessarily a healthy one: re-enable it if the system disabled it,
    /// reinstall it if it will not come back, tear it down if trust was revoked or Colon was
    /// turned off, and install it as soon as trust is granted.
    private func startHealthTimer() {
        guard healthTimer == nil else { return }
        let timer = Timer(timeInterval: Self.healthInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkHealth() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        healthTimer = timer
    }

    private func checkHealth() {
        defer { refreshStatus() }
        guard wantsRunning else { return }
        guard settings.isEnabled else {
            if tap != nil {
                InputLog.debug("disabled, removing tap")
                resetCapture()
                removeTap()
            }
            return
        }
        guard AXIsProcessTrusted() else {
            if tap != nil {
                InputLog.debug("accessibility revoked, removing tap")
                removeTap()
                resetCapture()
            }
            return
        }
        guard let tap else {
            _ = installTap()
            return
        }
        if !CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
            if !CGEvent.tapIsEnabled(tap: tap) {
                InputLog.debug("tap would not re-enable, reinstalling")
                removeTap()
                _ = installTap()
            }
            resetCapture()
        }
    }

    private func refreshStatus() {
        let current: InputStatus
        if !settings.isEnabled {
            current = .disabled
        } else if tap == nil || !AXIsProcessTrusted() {
            current = .noPermission
        } else if IsSecureEventInputEnabled() {
            current = .secureInput
        } else {
            current = .running
        }
        if status != current { status = current }
    }

    // MARK: Callback

    private func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            InputLog.debug("tap re-enabled after \(type == .tapDisabledByTimeout ? "timeout" : "user input")")
            resetCapture()
            return pass
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            // Clicks on our own panel are picks, handled by the picker; anything else moves focus/caret.
            let point = AXGeometry.cocoaPoint(fromQuartz: event.location,
                                              primaryScreenHeight: NSScreen.screens.first?.frame.height ?? 0)
            if !(delegate?.inputIsPointInPicker(point) ?? false) { resetCapture() }
            return pass
        case .keyDown:
            break
        default:
            return pass
        }
        if SyntheticEvent.isSynthetic(event) { return pass }

        if let reason = silenceReason() {
            if engine.isTracking {
                InputLog.debug("silent: \(reason)")
                resetCapture()
            }
            return pass
        }
        guard let input = translate(event) else { return pass }

        // Picker keys belong to the picker only while it is on screen with a row to pick: we have
        // shown it (the focus probe may still be running) and the UI confirms a selection.
        let visible = pickerVisible && (delegate?.inputPickerIsVisible() ?? false)
        cancelStrip()
        let result = engine.handle(input, pickerVisible: visible)
        if !result.action.isCommit, !capture.follows(engine) {
            // The engine ended the capture (also silently, as with `:D ` or `:-)`) or began a new one
            // (a trigger right after multi-insert): forget the old probe, anchor and context, so the
            // next capture probes and anchors where it is typed. Commits end the capture themselves,
            // after the delegate has read the selection.
            endCapture(notifyDelegate: true)
        }
        switch result.action {
        case .none:
            break
        case .show(let query):
            show(query: query)
        case .hide:
            InputLog.debug("hide")
            // Still capturing (e.g. below the minimum length): keep the anchor and probe result.
            // A capture the engine ended was ended above.
            hidePicker()
        case .moveSelection(let delta):
            delegate?.inputMoveSelection(by: delta)
        case .commitSelection(let deleteCount):
            commitSelection(deleteCount: deleteCount, key: event, proxy: proxy)
            return nil
        case .commitShortcode(let shortcode, let deleteCount):
            commit(shortcode: shortcode, deleteCount: deleteCount, key: event, proxy: proxy)
            return nil
        case .commitSelectionKeepOpen(let deleteCount):
            commitSelectionKeepOpen(deleteCount: deleteCount, key: event, proxy: proxy)
            return nil
        }
        // Probe the focused element as soon as a trigger is typed: the anchor and the context come
        // from it.
        if capture.needsProbe {
            InputLog.debug("capture started, probing focus")
            probe(captureID: capture.startProbe(), attempt: 0)
        }
        if engine.isTracking { scheduleIdleTimeout() } else { cancelIdleTimeout() }
        return result.swallow ? nil : pass
    }

    /// Enter/Tab was swallowed: insert the selection, or re-post the key if there is none.
    private func commitSelection(deleteCount: Int, key: CGEvent, proxy: CGEventTapProxy) {
        // The delegate closes the picker itself when asked to commit.
        let text = delegate?.inputCommitSelection()
        endCapture(notifyDelegate: false)
        guard let text else {
            InputLog.debug("commit with no selection, re-posting key")
            repost(key, proxy: proxy)
            return
        }
        InputLog.debug("commit selection, deleteCount \(deleteCount)")
        Inserter.replace(deleteCount: deleteCount, with: text, method: settings.insertionMethod, poster: .tap(proxy))
    }

    /// ⌘↩ was swallowed: insert the selection and leave the picker up for the next pick. Without a
    /// selection the key stays swallowed (re-posting ⌘↩ would send the message) and nothing changes.
    private func commitSelectionKeepOpen(deleteCount: Int, key: CGEvent, proxy: CGEventTapProxy) {
        guard let text = delegate?.inputCommitSelectionKeepOpen() else {
            InputLog.debug("keep-open commit with no selection, key swallowed")
            engine.keepOpenInsertFailed()
            scheduleIdleTimeout()
            return
        }
        InputLog.debug("commit selection (keep open), deleteCount \(deleteCount)")
        Inserter.replace(deleteCount: deleteCount, with: text, method: settings.insertionMethod, poster: .tap(proxy))
        scheduleIdleTimeout()
    }

    /// The closing trigger was swallowed: insert the shortcode's emoji, or re-post the trigger
    /// character so `:xyz:` stays literal.
    private func commit(shortcode: String, deleteCount: Int, key: CGEvent, proxy: CGEventTapProxy) {
        let text = delegate?.inputCommit(shortcode: shortcode)
        endCapture(notifyDelegate: false)
        guard let text else {
            InputLog.debug("unknown shortcode, re-posting closing trigger")
            repost(key, proxy: proxy)
            return
        }
        InputLog.debug("commit shortcode :\(shortcode):, deleteCount \(deleteCount)")
        Inserter.replace(deleteCount: deleteCount, with: text, method: settings.insertionMethod, poster: .tap(proxy))
    }

    /// Delivers a swallowed key after all, marked so our tap lets it through untouched. Posted at
    /// the tap, so it keeps its place ahead of later keystrokes.
    private func repost(_ key: CGEvent, proxy: CGEventTapProxy) {
        guard let copy = key.copy() else { return }
        copy.setIntegerValueField(.eventSourceUserData, value: SyntheticEvent.marker)
        copy.tapPostEvent(proxy)
    }

    /// Why we must stay out of the way right now, or nil when active. Cheap and in-process only.
    private func silenceReason() -> String? {
        if !settings.isEnabled { return "disabled" }
        if IsSecureEventInputEnabled() { return "secure input" }
        // Our own Settings window or the search panel has the keyboard.
        if NSApp.isActive || NSApp.keyWindow != nil { return "Colon has focus" }
        if settings.isExcluded(bundleID: frontmostApp?.bundleIdentifier) { return "excluded app" }
        if !isKeyboardLayoutInput { return "input method active" }
        return nil
    }

    /// Keycode → `KeyInput`. Printable keys use the event's own Unicode string so every layout works;
    /// control keys use layout-independent virtual keycodes. Returns nil for keys that change nothing
    /// (a dead key waiting for its second press).
    private func translate(_ event: CGEvent) -> KeyInput? {
        let flags = event.flags
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        if flags.contains(.maskCommand), !flags.contains(.maskControl), !flags.contains(.maskAlternate),
           !flags.contains(.maskShift), keyCode == kVK_Return || keyCode == kVK_ANSI_KeypadEnter {
            return .commandEnter
        }
        if flags.contains(.maskCommand) || flags.contains(.maskControl) { return .interrupt }
        switch keyCode {
        case kVK_Delete:
            // ⌥⌫ deletes a word: we cannot follow that, so end the capture.
            return flags.contains(.maskAlternate) ? .interrupt : .backspace
        case kVK_Return, kVK_ANSI_KeypadEnter: return .enter
        case kVK_Tab: return .tab
        case kVK_Escape: return .escape
        case kVK_UpArrow, kVK_DownArrow, kVK_LeftArrow, kVK_RightArrow:
            // ⇧/⌥ arrows select text or jump words: native, and the capture cannot follow.
            if flags.contains(.maskShift) || flags.contains(.maskAlternate) { return .interrupt }
            switch keyCode {
            case kVK_UpArrow: return .up
            case kVK_DownArrow: return .down
            case kVK_LeftArrow: return .left
            default: return .right
            }
        case kVK_ForwardDelete, kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown, kVK_Help:
            return .interrupt
        default:
            break
        }
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &length, unicodeString: &buffer)
        guard length > 0 else { return nil }
        let text = String(utf16CodeUnits: buffer, count: min(length, buffer.count))
        // Control characters and the private-use range AppKit uses for function keys move the caret
        // or do something we cannot model.
        if text.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F || (0xF700...0xF8FF).contains($0.value) }) {
            return .interrupt
        }
        return .text(text)
    }

    // MARK: Picker presentation

    private func show(query: String) {
        capture.latestQuery = query
        if query.isEmpty, !pickerVisible, !capture.stripDelayElapsed {
            scheduleStrip()
            return
        }
        presentIfReady()
    }

    /// Shows or updates the picker once the focus probe succeeded (and, for the bare-trigger strip,
    /// once its delay has passed).
    private func presentIfReady() {
        guard engine.isShowing, capture.focusUsable else { return }
        if capture.latestQuery.isEmpty, !pickerVisible, !capture.stripDelayElapsed { return }
        pickerVisible = true
        InputLog.debug("show query \(capture.latestQuery)")
        delegate?.inputShow(query: capture.latestQuery, caret: capture.anchor, context: capture.context)
    }

    private func scheduleStrip() {
        stripWork?.cancel()
        let id = capture.id
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.capture.isCurrent(id) else { return }
                self.stripWork = nil
                self.capture.stripDelayElapsed = true
                self.presentIfReady()
            }
        }
        stripWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.stripDelay, execute: work)
    }

    private func cancelStrip() {
        stripWork?.cancel()
        stripWork = nil
    }

    /// Hides the picker but keeps the capture (anchor, probe result) alive.
    private func hidePicker() {
        cancelStrip()
        let wasVisible = pickerVisible
        pickerVisible = false
        if wasVisible { delegate?.inputHide() }
    }

    /// Reads the focused element off the main thread one hop after the key, so the target app has
    /// already applied it, then shows the picker if the capture is still current. The caller has
    /// marked the probe as running (`CaptureSession.startProbe`).
    private func probe(captureID id: Int, attempt: Int) {
        let app = frontmostApp
        let pid = app?.processIdentifier
        let bundleID = app?.bundleIdentifier
        let trigger = engine.trigger
        let includeContext = settings.sendTextContext
        let screens = ScreenSnapshot.current()
        axQueue.async { [weak self] in
            let result = FocusProbe.read(pid: pid, bundleID: bundleID, trigger: trigger,
                                         includeContext: includeContext, screens: screens)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.finishProbe(result, captureID: id, attempt: attempt, app: app)
                }
            }
        }
    }

    private func finishProbe(_ result: FocusProbe, captureID id: Int, attempt: Int, app: NSRunningApplication?) {
        guard capture.isCurrent(id), engine.isTracking, frontmostApp == app else {
            capture.probeEnded(captureID: id)
            return
        }
        switch result.status {
        case .usable:
            let context = PredictionContext(appName: app?.localizedName, bundleID: app?.bundleIdentifier,
                                            textBeforeTrigger: settings.sendTextContext ? result.textBeforeTrigger : nil)
            capture.probeSucceeded(captureID: id, anchor: result.anchor ?? CaretLocator.mouseAnchor(), context: context)
            InputLog.debug("focus usable (anchor \(result.anchor == nil ? "mouse" : "ax"))")
            presentIfReady()
        case .noFocusedElement where attempt < Self.probeRetryDelays.count:
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.probeRetryDelays[attempt]) { [weak self] in
                MainActor.assumeIsolated { self?.retryProbe(captureID: id, attempt: attempt + 1) }
            }
        case .noFocusedElement, .secure, .notText:
            // Fail closed: no picker, nothing swallowed for this capture.
            InputLog.debug("silent: focused element \(result.status)")
            capture.probeEnded(captureID: id)
            resetCapture()
        }
    }

    private func retryProbe(captureID id: Int, attempt: Int) {
        guard capture.isCurrent(id), engine.isTracking else {
            capture.probeEnded(captureID: id)
            return
        }
        probe(captureID: id, attempt: attempt)
    }

    /// Ends the capture in the engine and the UI.
    private func resetCapture() {
        let wasActive = engine.isTracking || pickerVisible
        engine.reset()
        if wasActive { InputLog.debug("capture reset") }
        endCapture(notifyDelegate: true)
    }

    /// Clears per-capture state (a new capture starts from scratch, and probes or timers of this one
    /// are dropped); hides the picker through the delegate if it is visible.
    private func endCapture(notifyDelegate: Bool) {
        capture.restart(for: engine)
        cancelStrip()
        cancelIdleTimeout()
        let wasVisible = pickerVisible
        pickerVisible = false
        if wasVisible, notifyDelegate { delegate?.inputHide() }
    }

    /// Abandons a capture after `idleTimeout` without a keystroke. Resting the pointer on the
    /// picker counts as activity: the user is about to click a row, so the picker must not vanish
    /// from under the click.
    private func scheduleIdleTimeout() {
        idleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.delegate?.inputIsPointInPicker(NSEvent.mouseLocation) == true {
                    self.scheduleIdleTimeout()
                    return
                }
                InputLog.debug("capture idle timeout")
                self.resetCapture()
            }
        }
        idleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleTimeout, execute: work)
    }

    private func cancelIdleTimeout() {
        idleWork?.cancel()
        idleWork = nil
    }

    // MARK: Observation

    private func startObserving() {
        guard observers.isEmpty else { return }
        frontmostApp = NSWorkspace.shared.frontmostApplication
        isKeyboardLayoutInput = Self.currentInputSourceIsKeyboardLayout()

        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                               object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                self?.frontmostApp = app ?? NSWorkspace.shared.frontmostApplication
                self?.resetCapture()
                self?.prepareAccessibility(for: app)
            }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.frontmostApp = NSWorkspace.shared.frontmostApplication
                self?.resetCapture()
            }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                               object: nil, queue: .main) { note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                AccessibilityUnlocker.shared.forget(pid: app.processIdentifier)
            }
        })
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isKeyboardLayoutInput = Self.currentInputSourceIsKeyboardLayout()
                self?.resetCapture()
            }
        })

        // `@Published` emits before the property changes, so use the emitted values.
        Publishers.CombineLatest(
            Publishers.CombineLatest3(settings.$triggerString, settings.$minQueryLength,
                                      settings.$autoReplaceOnClosingTrigger),
            Publishers.CombineLatest(settings.$showRecentsOnTrigger, settings.$pickerLayout)
        )
        .sink { [weak self] typing, features in
            self?.configureEngine(EngineConfiguration(
                trigger: typing.0, minQueryLength: typing.1, autoReplace: typing.2,
                showsRecents: features.0, horizontalLayout: features.1 == .compact))
        }
        .store(in: &cancellables)
        // Delivered after the property is set, so `checkHealth` sees the new value and tears the
        // tap down (disabled) or installs it (enabled) right away.
        settings.$isEnabled
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.checkHealth() }
            .store(in: &cancellables)
        settings.$excludedBundleIDs
            .sink { [weak self] excluded in
                guard let self, let bundleID = self.frontmostApp?.bundleIdentifier,
                      excluded.contains(bundleID) else { return }
                self.resetCapture()
            }
            .store(in: &cancellables)
    }

    /// Starts building a Chromium/Electron app's accessibility tree as soon as it comes forward, so
    /// it is ready by the first trigger. Only while the tap runs (enabled and trusted).
    private func prepareAccessibility(for app: NSRunningApplication?) {
        guard tap != nil, let app, !settings.isExcluded(bundleID: app.bundleIdentifier) else { return }
        let pid = app.processIdentifier
        let bundleID = app.bundleIdentifier
        let bundleURL = app.bundleURL
        axQueue.async {
            AccessibilityUnlocker.shared.prepare(pid: pid, bundleID: bundleID, bundleURL: bundleURL)
        }
    }

    private struct EngineConfiguration: Equatable {
        var trigger: String
        var minQueryLength: Int
        var autoReplace: Bool
        var showsRecents: Bool
        var horizontalLayout: Bool
    }

    /// Applies settings to the engine. Any change affects how the open capture is read (trigger,
    /// minimum, auto replace, recents, layout), so it resets it.
    private func configureEngine(_ wanted: EngineConfiguration) {
        var wanted = wanted
        wanted.trigger = AppSettings.isValidTrigger(wanted.trigger) ? wanted.trigger : ":"
        wanted.minQueryLength = max(1, wanted.minQueryLength)
        let current = EngineConfiguration(
            trigger: engine.trigger, minQueryLength: engine.minQueryLength,
            autoReplace: engine.autoReplaceOnClosingTrigger, showsRecents: engine.showsRecentsOnTrigger,
            horizontalLayout: engine.horizontalLayout)
        guard wanted != current else { return }
        resetCapture()
        engine.trigger = wanted.trigger
        engine.minQueryLength = wanted.minQueryLength
        engine.autoReplaceOnClosingTrigger = wanted.autoReplace
        engine.showsRecentsOnTrigger = wanted.showsRecents
        engine.horizontalLayout = wanted.horizontalLayout
        InputLog.debug("engine configured: trigger \(wanted.trigger), min \(wanted.minQueryLength), autoReplace \(wanted.autoReplace), recents \(wanted.showsRecents), compact \(wanted.horizontalLayout)")
    }

    /// IMEs (Japanese, Chinese, …) compose text the tap cannot see; stay silent while one is active.
    private static func currentInputSourceIsKeyboardLayout() -> Bool {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceType) else { return true }
        let type = Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
        return type == (kTISTypeKeyboardLayout as String)
    }
}

private extension TriggerResult.Action {
    /// Inserts (or re-posts the key); the commit path ends or keeps the capture itself.
    var isCommit: Bool {
        switch self {
        case .commitSelection, .commitShortcode, .commitSelectionKeepOpen: true
        case .none, .show, .hide, .moveSelection: false
        }
    }
}

