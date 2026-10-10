import AppKit
import Carbon.HIToolbox
import ColonCore

/// Where synthesized events enter the event stream.
enum EventPoster {
    /// HID level: used outside the tap callback (mouse picks, search mode).
    case hid
    /// Straight after our tap, from inside its callback: lands ahead of any user keystroke still
    /// waiting at the tap, so fast typing can never interleave with the replacement.
    case tap(CGEventTapProxy)

    func post(_ event: CGEvent) {
        switch self {
        case .hid: event.post(tap: .cghidEventTap)
        case .tap(let proxy): event.tapPostEvent(proxy)
        }
    }
}

/// Keyboard events we synthesize. They carry a marker in `eventSourceUserData` so our own tap
/// ignores them, and come from a private source so held physical modifiers never leak in.
enum SyntheticEvent {
    /// "EMJF"
    static let marker: Int64 = 0x454D_4A46
    nonisolated(unsafe) private static let source = CGEventSource(stateID: .privateState)

    static func isSynthetic(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == marker
    }

    /// Key down + up pair.
    static func keyPress(_ keyCode: CGKeyCode, flags: CGEventFlags = [], text: [UniChar]? = nil) -> [CGEvent] {
        [true, false].compactMap { isDown in
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: isDown) else {
                return nil
            }
            event.flags = flags
            if let text {
                text.withUnsafeBufferPointer {
                    event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress)
                }
            }
            event.setIntegerValueField(.eventSourceUserData, value: marker)
            return event
        }
    }
}

/// Puts text into the frontmost app. OWNER: input worker.
@MainActor
enum Inserter {
    /// How long the emoji stays on the pasteboard before the user's contents are restored.
    private static let pasteRestoreDelay: TimeInterval = 0.25
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    /// The user's pasteboard while ours is on it, and the pending restore.
    private static var savedPasteboard: [NSPasteboardItem]?
    private static var pasteboardChangeCount = 0
    private static var restoreWork: DispatchWorkItem?

    /// Delete `deleteCount` characters before the caret, then insert `text`.
    static func replace(deleteCount: Int, with text: String, method: InsertionMethod) {
        replace(deleteCount: deleteCount, with: text, method: method, poster: .hid)
    }

    /// Same as `replace(deleteCount:with:method:)`, choosing where the events are posted.
    /// All events are posted back to back in order: they travel the same queue as the user's keys,
    /// so no sleeps are needed for ordering. Multi-line text (snippets) is always pasted: a typed
    /// line break can act as Return, which sends the message in chat apps.
    static func replace(deleteCount: Int, with text: String, method: InsertionMethod, poster: EventPoster) {
        let method = text.contains(where: \.isNewline) ? .paste : method
        var events: [CGEvent] = []
        for _ in 0..<max(0, deleteCount) {
            events += SyntheticEvent.keyPress(CGKeyCode(kVK_Delete))
        }
        switch method {
        case .typing:
            // Virtual key 0 is only the carrier; apps read the Unicode string.
            for chunk in UnicodeChunker.chunks(text) {
                events += SyntheticEvent.keyPress(0, text: chunk)
            }
        case .paste:
            guard !text.isEmpty else { break }
            putOnPasteboard(text)
            events += SyntheticEvent.keyPress(KeyLayout.keyCode(for: "v") ?? CGKeyCode(kVK_ANSI_V),
                                               flags: .maskCommand)
        }
        events.forEach(poster.post)
        InputLog.debug("inserted via \(method.rawValue), deleted \(deleteCount)")
    }

    /// Saves every item and type on the general pasteboard (once, even across rapid inserts),
    /// writes `text` marked transient, and schedules the restore.
    private static func putOnPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        restoreWork?.cancel()
        if savedPasteboard == nil {
            savedPasteboard = (pasteboard.pasteboardItems ?? []).map { item in
                let copy = NSPasteboardItem()
                for type in item.types {
                    if let data = item.data(forType: type) { copy.setData(data, forType: type) }
                }
                return copy
            }
        }
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: transientType)
        item.setData(Data(), forType: concealedType)
        pasteboard.writeObjects([item])
        pasteboardChangeCount = pasteboard.changeCount

        let work = DispatchWorkItem {
            MainActor.assumeIsolated { restorePasteboard() }
        }
        restoreWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + pasteRestoreDelay, execute: work)
    }

    private static func restorePasteboard() {
        defer {
            savedPasteboard = nil
            restoreWork = nil
        }
        let pasteboard = NSPasteboard.general
        // If something else wrote to the pasteboard meanwhile (the user copied), keep that.
        guard pasteboard.changeCount == pasteboardChangeCount, let saved = savedPasteboard else { return }
        pasteboard.clearContents()
        if !saved.isEmpty { pasteboard.writeObjects(saved) }
    }
}

/// Reverse keyboard-layout lookup, needed to synthesize ⌘V on non-QWERTY layouts.
@MainActor
enum KeyLayout {
    private static var cache: (layoutID: String, codes: [Character: CGKeyCode])?

    static func keyCode(for character: Character) -> CGKeyCode? {
        guard let source = currentLayoutSource(),
              let layoutID = property(source, kTISPropertyInputSourceID) as String? else { return nil }
        if let cache, cache.layoutID == layoutID { return cache.codes[character] }
        let codes = buildTable(source)
        cache = (layoutID, codes)
        return codes[character]
    }

    private static func currentLayoutSource() -> TISInputSource? {
        let current = TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()
        if property(current, kTISPropertyUnicodeKeyLayoutData) as CFData? != nil { return current }
        // e.g. a Japanese input method: use its ASCII-capable layout.
        return TISCopyCurrentASCIICapableKeyboardLayoutInputSource().takeRetainedValue()
    }

    private static func buildTable(_ source: TISInputSource) -> [Character: CGKeyCode] {
        guard let data = property(source, kTISPropertyUnicodeKeyLayoutData) as CFData?,
              let bytes = CFDataGetBytePtr(data) else { return [:] }
        var table: [Character: CGKeyCode] = [:]
        bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
            for keyCode in 0..<128 {
                var deadKeyState: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDown), 0,
                                            UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                            &deadKeyState, chars.count, &length, &chars)
                guard status == noErr, length == 1,
                      let character = String(utf16CodeUnits: chars, count: length).first,
                      table[character] == nil else { continue }
                table[character] = CGKeyCode(keyCode)
            }
        }
        return table
    }

    private static func property<T>(_ source: TISInputSource, _ key: CFString) -> T? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue() as? T
    }
}
