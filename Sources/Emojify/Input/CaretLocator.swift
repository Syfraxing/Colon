import AppKit
import ApplicationServices
import EmojifyCore

/// Finds the text caret on screen via Accessibility. OWNER: input worker.
@MainActor
enum CaretLocator {
    /// Caret rect in Cocoa screen coordinates (bottom-left origin), nil when unavailable.
    /// Ladder: AX caret bounds → focused element (one-line fields only) → mouse location.
    static func caretRect() -> CGRect? {
        let app = NSWorkspace.shared.frontmostApplication
        let probe = FocusProbe.read(pid: app?.processIdentifier, bundleID: app?.bundleIdentifier,
                                    trigger: nil, includeContext: false, screens: .current())
        return probe.anchor ?? mouseAnchor()
    }

    /// Last-resort anchor: a 1×16 pt rect at the mouse pointer.
    static func mouseAnchor() -> CGRect {
        let mouse = NSEvent.mouseLocation
        return CGRect(x: mouse.x, y: mouse.y - 16, width: 1, height: 16)
    }
}

/// Screen geometry captured on the main thread for use by off-main AX probes.
struct ScreenSnapshot: Sendable {
    var primaryHeight: CGFloat
    var frames: [CGRect]

    @MainActor
    static func current() -> ScreenSnapshot {
        let screens = NSScreen.screens
        return ScreenSnapshot(primaryHeight: screens.first?.frame.height ?? 0, frames: screens.map(\.frame))
    }
}

/// What Accessibility tells us about the focused element, read on demand when a capture starts.
/// Safe to run on any thread; never retained beyond the current capture.
struct FocusProbe: Sendable {
    enum Status: Sendable, Equatable {
        /// A text element we may act in.
        case usable
        /// No focused element could be read (Electron/Chromium tree not built yet, or no AX).
        case noFocusedElement
        /// Password field, or the role could not be read (fail closed).
        case secure
        /// Focus is on a control that does not take text.
        case notText
    }

    var status: Status
    /// Picker anchor in Cocoa coordinates: the trigger character, else the caret, else a one-line
    /// field's frame. nil when none is trustworthy.
    var anchor: CGRect?
    /// Up to 300 characters before the trigger; only when context was requested.
    var textBeforeTrigger: String?

    /// Roles that never take typed text.
    private static let nonTextRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXMenuItem",
        "AXMenuBarItem", "AXSlider", "AXImage", "AXDisclosureTriangle",
    ]
    /// Taller elements are editors/web areas whose frame says nothing about the caret.
    private static let maxFallbackFieldHeight: CGFloat = 160
    private static let contextLimit = 300

    /// - Parameters:
    ///   - trigger: the active trigger, to anchor on it and cut context before it. nil = caret only.
    ///   - includeContext: read text before the trigger (user opted in to sending context).
    static func read(pid: pid_t?, bundleID: String?, trigger: String?, includeContext: Bool,
                     screens: ScreenSnapshot) -> FocusProbe {
        guard let element = AXReader.focusedElement(pid: pid) else {
            if let pid { AccessibilityUnlocker.shared.unlockIfNeeded(pid: pid, bundleID: bundleID) }
            return FocusProbe(status: .noFocusedElement)
        }
        guard let role = AXReader.string(element, kAXRoleAttribute) else {
            return FocusProbe(status: .secure)
        }
        let subrole = AXReader.string(element, kAXSubroleAttribute)
        if role == "AXSecureTextField" || subrole == "AXSecureTextField" {
            return FocusProbe(status: .secure)
        }
        if nonTextRoles.contains(role) {
            return FocusProbe(status: .notText)
        }

        let elementFrame = AXReader.frame(element).map {
            AXGeometry.cocoaRect(fromAX: $0, primaryScreenHeight: screens.primaryHeight)
        }
        func plausible(_ axRect: CGRect?) -> CGRect? {
            guard let axRect else { return nil }
            let rect = AXGeometry.cocoaRect(fromAX: axRect, primaryScreenHeight: screens.primaryHeight)
            return AXGeometry.isPlausible(rect, screens: screens.frames, elementFrame: elementFrame) ? rect : nil
        }

        var anchor: CGRect?
        var context: String?
        if let selection = AXReader.selectedRange(element) {
            let caret = selection.location
            if let trigger {
                let lookback = trigger.utf16.count + TriggerEngine.maxQueryLength * 2
                    + (includeContext ? contextLimit * 2 : 0)
                let start = max(0, caret - lookback)
                if let text = AXReader.text(element, range: CFRange(location: start, length: caret - start)),
                   let match = TriggerLocator.locate(trigger: trigger, in: text) {
                    let triggerLocation = caret - match.utf16Distance
                    anchor = plausible(AXReader.bounds(element, CFRange(location: triggerLocation,
                                                                        length: trigger.utf16.count)))
                    if includeContext { context = TriggerLocator.context(before: match, limit: contextLimit) }
                }
            }
            if anchor == nil { anchor = caretRect(element, selection: selection, plausible: plausible) }
        }
        if anchor == nil, let elementFrame, elementFrame.height <= maxFallbackFieldHeight {
            anchor = elementFrame
        }
        return FocusProbe(status: .usable, anchor: anchor, textBeforeTrigger: context)
    }

    /// Caret bounds ladder: next glyph's leading edge, previous glyph's trailing edge (unless it is
    /// a newline), then the zero-length range (NSTextView answers that one line high at document end).
    private static func caretRect(_ element: AXUIElement, selection: CFRange,
                                  plausible: (CGRect?) -> CGRect?) -> CGRect? {
        let location = selection.location
        if let next = plausible(AXReader.bounds(element, CFRange(location: location, length: max(selection.length, 1)))) {
            return CGRect(x: next.minX, y: next.minY, width: 0, height: next.height)
        }
        if location > 0,
           AXReader.text(element, range: CFRange(location: location - 1, length: 1)).map({ !$0.contains(where: \.isNewline) }) ?? true,
           let previous = plausible(AXReader.bounds(element, CFRange(location: location - 1, length: 1))) {
            return CGRect(x: previous.maxX, y: previous.minY, width: 0, height: previous.height)
        }
        return plausible(AXReader.bounds(element, CFRange(location: location, length: 0)))
    }
}

/// Thin, timeout-bounded wrappers around the AX C API. Every element gets a short messaging
/// timeout so a hung target app can never stall us for long.
enum AXReader {
    static let messagingTimeout: Float = 0.05

    static func focusedElement(pid: pid_t?) -> AXUIElement? {
        if let pid {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, messagingTimeout)
            if let element = element(app, kAXFocusedUIElementAttribute) { return element }
        }
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, messagingTimeout)
        return element(systemWide, kAXFocusedUIElementAttribute)
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute) as? String
    }

    static func selectedRange(_ element: AXUIElement) -> CFRange? {
        guard let value = value(element, kAXSelectedTextRangeAttribute),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range), range.location >= 0 else { return nil }
        return range
    }

    /// Element frame in AX coordinates (top-left origin).
    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let positionValue = value(element, kAXPositionAttribute),
              let sizeValue = value(element, kAXSizeAttribute),
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// Bounds of a character range in AX coordinates.
    static func bounds(_ element: AXUIElement, _ range: CFRange) -> CGRect? {
        guard let value = parameterized(element, kAXBoundsForRangeParameterizedAttribute, range: range),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }

    /// Text in a UTF-16 range: `kAXStringForRange`, falling back to slicing `kAXValue`.
    static func text(_ element: AXUIElement, range: CFRange) -> String? {
        guard range.location >= 0, range.length >= 0 else { return nil }
        if range.length == 0 { return "" }
        if let string = parameterized(element, kAXStringForRangeParameterizedAttribute, range: range) as? String {
            return string
        }
        guard let value = string(element, kAXValueAttribute) as NSString?,
              range.location + range.length <= value.length else { return nil }
        return value.substring(with: NSRange(location: range.location, length: range.length))
    }

    private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = value(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let result = value as! AXUIElement
        AXUIElementSetMessagingTimeout(result, messagingTimeout)
        return result
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private static func parameterized(_ element: AXUIElement, _ attribute: String, range: CFRange) -> CFTypeRef? {
        var range = range
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, attribute as CFString, parameter, &value) == .success
        else { return nil }
        return value
    }
}

/// Electron and Chromium build their accessibility tree only for assistive clients. When the
/// focused-element read comes back empty, ask once per process: `AXManualAccessibility` (Electron)
/// and, for Chromium browsers only, `AXEnhancedUserInterface` (it disturbs window animations and
/// window managers elsewhere). Native apps never reach this.
final class AccessibilityUnlocker: @unchecked Sendable {
    static let shared = AccessibilityUnlocker()

    private static let chromiumBrowsers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "org.chromium.Chromium", "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.Browser",
        "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]

    private let lock = NSLock()
    private var unlocked: Set<pid_t> = []

    func unlockIfNeeded(pid: pid_t, bundleID: String?) {
        lock.lock()
        let isNew = unlocked.insert(pid).inserted
        lock.unlock()
        guard isNew else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, AXReader.messagingTimeout)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if let bundleID, Self.chromiumBrowsers.contains(bundleID) {
            AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
        InputLog.debug("enabled accessibility tree for pid \(pid)")
    }

    /// Forget terminated processes so a recycled pid gets unlocked again.
    func forget(pid: pid_t) {
        lock.lock()
        unlocked.remove(pid)
        lock.unlock()
    }
}
