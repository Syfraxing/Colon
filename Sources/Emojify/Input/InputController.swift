import AppKit
import Carbon.HIToolbox
import Combine
import EmojifyCore

/// Receives trigger events from the keyboard tap. Implemented by `AppCoordinator`.
@MainActor
protocol InputControllerDelegate: AnyObject {
    /// Picker should appear/update. `caret` is in Cocoa screen coordinates (bottom-left origin), nil if unknown.
    func inputShow(query: String, caret: CGRect?, context: PredictionContext)
    func inputHide()
    func inputMoveSelection(by delta: Int)
    /// Return the emoji string to insert for the current selection, or nil to just close.
    func inputCommitSelection() -> String?
    /// Return the emoji string for an exact shortcode (closing-trigger auto replace), nil if unknown.
    func inputCommit(shortcode: String) -> String?
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
final class InputController {
    weak var delegate: InputControllerDelegate?
    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
        engine = TriggerEngine(
            trigger: settings.triggerString,
            minQueryLength: settings.minQueryLength,
            autoReplaceOnClosingTrigger: settings.autoReplaceOnClosingTrigger,
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
    /// Bumped whenever a capture ends so stale probe results are dropped.
    private var captureID = 0
    private var probeInFlight = false
    private var latestQuery = ""
    private var anchor: CGRect?
    private var context = PredictionContext()
    private var idleWork: DispatchWorkItem?

    private let axQueue = DispatchQueue(label: "Emojify.input.ax", qos: .userInteractive)
    /// Delays before re-probing when the focused element could not be read (Chromium/Electron
    /// build their tree asynchronously once asked).
    private static let probeRetryDelays: [TimeInterval] = [0.15, 0.4]
    /// A capture with no keystroke for this long is abandoned.
    private static let idleTimeout: TimeInterval = 10
    private static let healthInterval: TimeInterval = 3

    // MARK: Lifecycle

    /// Install the event tap. Returns false if Accessibility permission is missing.
    @discardableResult
    func start() -> Bool {
        wantsRunning = true
        startObserving()
        startHealthTimer()
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
    /// reinstall it if it will not come back, tear it down if trust was revoked, and install it
    /// as soon as trust is granted.
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
        guard wantsRunning else { return }
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
            if !isOwnWindow(at: event.location) { resetCapture() }
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

        // The engine believes the picker is up but our probe has not shown it yet: never swallow
        // navigation keys for an invisible picker.
        if engine.isShowing, !pickerVisible, input.isPickerKey {
            resetCapture()
            return pass
        }

        let result = engine.handle(input)
        switch result.action {
        case .none:
            break
        case .show(let query):
            show(query: query)
        case .hide:
            InputLog.debug("hide")
            endCapture(notifyDelegate: true)
        case .moveSelection(let delta):
            delegate?.inputMoveSelection(by: delta)
        case .commitSelection(let deleteCount):
            return commitSelection(deleteCount: deleteCount, proxy: proxy) ? nil : pass
        case .commitShortcode(let shortcode, let deleteCount):
            return commit(shortcode: shortcode, deleteCount: deleteCount, proxy: proxy) ? nil : pass
        }
        if engine.isTracking { scheduleIdleTimeout() } else { cancelIdleTimeout() }
        return result.swallow ? nil : pass
    }

    /// Returns true if the Enter/Tab was consumed. With no row to insert it passes through untouched.
    private func commitSelection(deleteCount: Int, proxy: CGEventTapProxy) -> Bool {
        let wasVisible = pickerVisible
        // The delegate closes the picker itself when asked to commit.
        let text = wasVisible ? delegate?.inputCommitSelection() : nil
        endCapture(notifyDelegate: false)
        guard let text else {
            InputLog.debug("commit with no selection, key passes through")
            return false
        }
        InputLog.debug("commit selection, deleteCount \(deleteCount)")
        Inserter.replace(deleteCount: deleteCount, with: text, method: settings.insertionMethod, poster: .tap(proxy))
        return true
    }

    /// Returns true if the closing trigger was consumed. Unknown shortcodes keep `:xyz:` literal.
    private func commit(shortcode: String, deleteCount: Int, proxy: CGEventTapProxy) -> Bool {
        let text = delegate?.inputCommit(shortcode: shortcode)
        endCapture(notifyDelegate: false)
        guard let text else { return false }
        InputLog.debug("commit shortcode :\(shortcode):, deleteCount \(deleteCount)")
        Inserter.replace(deleteCount: deleteCount, with: text, method: settings.insertionMethod, poster: .tap(proxy))
        return true
    }

    /// Why we must stay out of the way right now, or nil when active. Cheap and in-process only.
    private func silenceReason() -> String? {
        if !settings.isEnabled { return "disabled" }
        if IsSecureEventInputEnabled() { return "secure input" }
        if frontmostApp?.processIdentifier == ProcessInfo.processInfo.processIdentifier { return "Emojify frontmost" }
        if settings.isExcluded(bundleID: frontmostApp?.bundleIdentifier) { return "excluded app" }
        if !isKeyboardLayoutInput { return "input method active" }
        return nil
    }

    /// Keycode → `KeyInput`. Printable keys use the event's own Unicode string so every layout works;
    /// control keys use layout-independent virtual keycodes. Returns nil for keys that change nothing
    /// (a dead key waiting for its second press).
    private func translate(_ event: CGEvent) -> KeyInput? {
        let flags = event.flags
        if flags.contains(.maskCommand) || flags.contains(.maskControl) { return .interrupt }
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        switch keyCode {
        case kVK_Delete:
            // ⌥⌫ deletes a word: we cannot follow that, so end the capture.
            return flags.contains(.maskAlternate) ? .interrupt : .backspace
        case kVK_Return, kVK_ANSI_KeypadEnter: return .enter
        case kVK_Tab: return .tab
        case kVK_Escape: return .escape
        case kVK_UpArrow: return .up
        case kVK_DownArrow: return .down
        case kVK_LeftArrow: return .left
        case kVK_RightArrow: return .right
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

    private func isOwnWindow(at quartzPoint: CGPoint) -> Bool {
        let point = AXGeometry.cocoaPoint(fromQuartz: quartzPoint,
                                          primaryScreenHeight: NSScreen.screens.first?.frame.height ?? 0)
        // Our floating panels (the picker); the menu bar item and settings window do not count.
        return NSApp.windows.contains { $0 is NSPanel && $0.isVisible && $0.frame.contains(point) }
    }

    // MARK: Picker presentation

    private func show(query: String) {
        latestQuery = query
        if pickerVisible {
            InputLog.debug("show query \(query)")
            delegate?.inputShow(query: query, caret: anchor, context: context)
        } else if !probeInFlight {
            InputLog.debug("capture started, probing focus")
            probe(captureID: captureID, attempt: 0)
        }
    }

    /// Reads the focused element off the main thread one hop after the key, so the target app has
    /// already applied it, then shows the picker if the capture is still current.
    private func probe(captureID id: Int, attempt: Int) {
        probeInFlight = true
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
        guard id == captureID, engine.isShowing, frontmostApp == app else {
            if id == captureID { probeInFlight = false }
            return
        }
        switch result.status {
        case .usable:
            probeInFlight = false
            anchor = result.anchor ?? CaretLocator.mouseAnchor()
            context = PredictionContext(appName: app?.localizedName, bundleID: app?.bundleIdentifier,
                                        textBeforeTrigger: settings.sendTextContext ? result.textBeforeTrigger : nil)
            pickerVisible = true
            InputLog.debug("show query \(latestQuery) (anchor \(result.anchor == nil ? "mouse" : "ax"))")
            delegate?.inputShow(query: latestQuery, caret: anchor, context: context)
        case .noFocusedElement where attempt < Self.probeRetryDelays.count:
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.probeRetryDelays[attempt]) { [weak self] in
                MainActor.assumeIsolated { self?.retryProbe(captureID: id, attempt: attempt + 1) }
            }
        case .noFocusedElement, .secure, .notText:
            // Fail closed: no picker, nothing swallowed for this capture.
            InputLog.debug("silent: focused element \(result.status)")
            probeInFlight = false
            resetCapture()
        }
    }

    private func retryProbe(captureID id: Int, attempt: Int) {
        guard id == captureID, engine.isShowing else {
            if id == captureID { probeInFlight = false }
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

    /// Clears per-capture UI state; hides the picker through the delegate if it is visible.
    private func endCapture(notifyDelegate: Bool) {
        captureID &+= 1
        probeInFlight = false
        anchor = nil
        context = PredictionContext()
        latestQuery = ""
        cancelIdleTimeout()
        let wasVisible = pickerVisible
        pickerVisible = false
        if wasVisible, notifyDelegate { delegate?.inputHide() }
    }

    private func scheduleIdleTimeout() {
        idleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                InputLog.debug("capture idle timeout")
                self?.resetCapture()
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
        Publishers.CombineLatest3(settings.$triggerString, settings.$minQueryLength,
                                  settings.$autoReplaceOnClosingTrigger)
            .sink { [weak self] trigger, minLength, autoReplace in
                self?.configureEngine(trigger: trigger, minQueryLength: minLength, autoReplace: autoReplace)
            }
            .store(in: &cancellables)
        settings.$isEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                if !enabled { self?.resetCapture() }
            }
            .store(in: &cancellables)
        settings.$excludedBundleIDs
            .sink { [weak self] excluded in
                guard let self, let bundleID = self.frontmostApp?.bundleIdentifier,
                      excluded.contains(bundleID) else { return }
                self.resetCapture()
            }
            .store(in: &cancellables)
    }

    private func configureEngine(trigger: String, minQueryLength: Int, autoReplace: Bool) {
        let trigger = trigger.isEmpty ? ":" : trigger
        let minQueryLength = max(0, minQueryLength)
        guard trigger != engine.trigger || minQueryLength != engine.minQueryLength
                || autoReplace != engine.autoReplaceOnClosingTrigger else { return }
        resetCapture()
        engine.trigger = trigger
        engine.minQueryLength = minQueryLength
        engine.autoReplaceOnClosingTrigger = autoReplace
        InputLog.debug("engine configured: trigger \(trigger), min \(minQueryLength), autoReplace \(autoReplace)")
    }

    /// IMEs (Japanese, Chinese, …) compose text the tap cannot see; stay silent while one is active.
    private static func currentInputSourceIsKeyboardLayout() -> Bool {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceType) else { return true }
        let type = Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
        return type == (kTISTypeKeyboardLayout as String)
    }
}

private extension KeyInput {
    /// Keys the engine swallows while the picker is visible.
    var isPickerKey: Bool {
        switch self {
        case .up, .down, .enter, .tab, .escape: true
        default: false
        }
    }
}
