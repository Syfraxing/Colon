import AppKit
import ColonCore
import SwiftUI

/// Drives the onboarding practice field with the real `TriggerEngine` and a dedicated
/// `SuggestionEngine`, mirroring what `InputController` does in other apps. (The global
/// input layer stays silent while Colon itself is frontmost, so the field runs its own copy.)
@MainActor
final class PracticeController: ObservableObject {
    @Published private(set) var isShowing = false
    @Published private(set) var selectedIndex = 0
    @Published private(set) var lastInserted: String?

    let engine: SuggestionEngine
    private let settings: AppSettings
    private var trigger: TriggerEngine

    init(settings: AppSettings, engine: SuggestionEngine) {
        self.settings = settings
        self.engine = engine
        let store = EmojiStore.shared
        trigger = TriggerEngine(
            trigger: settings.triggerString,
            minQueryLength: settings.minQueryLength,
            autoReplaceOnClosingTrigger: settings.autoReplaceOnClosingTrigger,
            showsRecentsOnTrigger: settings.showRecentsOnTrigger,
            shortcodeExists: { store.emoji(forShortcode: $0) != nil }
        )
    }

    var visibleSuggestions: [Suggestion] {
        Array(engine.suggestions.prefix(settings.maxResults))
    }

    /// Returns true when the key was consumed (must not reach the text view).
    func handle(_ input: KeyInput, in textView: NSTextView) -> Bool {
        trigger.trigger = settings.triggerString
        trigger.minQueryLength = settings.minQueryLength
        trigger.autoReplaceOnClosingTrigger = settings.autoReplaceOnClosingTrigger
        trigger.showsRecentsOnTrigger = settings.showRecentsOnTrigger
        // The practice list is always vertical.
        trigger.horizontalLayout = false

        let result = trigger.handle(input, pickerVisible: isShowing && !visibleSuggestions.isEmpty)
        switch result.action {
        case .none:
            break
        case .show(let query):
            if !isShowing { selectedIndex = 0 }
            let context = PredictionContext(appName: "Colon", bundleID: Bundle.main.bundleIdentifier)
            engine.update(query: query, context: context)
            isShowing = true
        case .hide:
            hide()
        case .moveSelection(let delta):
            let count = visibleSuggestions.count
            if count > 0 {
                selectedIndex = (selectedIndex + delta + count) % count
            }
        case .commitSelection(let deleteCount):
            let suggestions = visibleSuggestions
            if suggestions.indices.contains(selectedIndex) {
                insert(engine.output(for: suggestions[selectedIndex].item), replacing: deleteCount, in: textView)
            }
            hide()
        case .commitSelectionKeepOpen(let deleteCount):
            let suggestions = visibleSuggestions
            if suggestions.indices.contains(selectedIndex) {
                insert(engine.output(for: suggestions[selectedIndex].item), replacing: deleteCount, in: textView)
            } else {
                trigger.keepOpenInsertFailed()
            }
        case .commitShortcode(let shortcode, let deleteCount):
            if let emoji = EmojiStore.shared.emoji(forShortcode: shortcode) {
                insert(engine.output(for: emoji), replacing: deleteCount, in: textView)
            }
            hide()
        }
        return result.swallow
    }

    func select(_ suggestion: Suggestion, in textView: NSTextView) {
        let deleteCount = trigger.typedLength ?? 0
        insert(engine.output(for: suggestion.item), replacing: deleteCount, in: textView)
        hide()
    }

    func interrupt() {
        hide()
    }

    private func hide() {
        trigger.reset()
        engine.reset()
        isShowing = false
        selectedIndex = 0
    }

    /// Deletes `count` characters before the caret and inserts `text`, like `Inserter.replace`.
    private func insert(_ text: String, replacing count: Int, in textView: NSTextView) {
        let string = textView.string as NSString
        let caret = textView.selectedRange().location
        var start = caret
        var removed = 0
        while removed < count, start > 0 {
            start = string.rangeOfComposedCharacterSequence(at: start - 1).location
            removed += 1
        }
        let range = NSRange(location: start, length: caret - start)
        if textView.shouldChangeText(in: range, replacementString: text) {
            textView.replaceCharacters(in: range, with: text)
            textView.didChangeText()
        }
        lastInserted = text
    }
}

struct PracticeField: View {
    @ObservedObject var settings: AppSettings
    @StateObject private var controller: PracticeController

    init(settings: AppSettings, engine: SuggestionEngine) {
        self.settings = settings
        _controller = StateObject(wrappedValue: PracticeController(settings: settings, engine: engine))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PracticeTextView(controller: controller, placeholder: "Type \(settings.triggerString)haha here…")
                .frame(height: 40)
                .padding(.horizontal, 12)
                .glassCard(cornerRadius: 12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(ShellTheme.accent.opacity(controller.isShowing ? 0.6 : 0), lineWidth: 1.5)
                )

            PracticeSuggestions(controller: controller, engine: controller.engine)
                .frame(height: 170, alignment: .top)
        }
        .animation(ShellTheme.ease, value: controller.isShowing)
    }
}

private struct PracticeSuggestions: View {
    @ObservedObject var controller: PracticeController
    @ObservedObject var engine: SuggestionEngine

    var body: some View {
        if controller.isShowing {
            let suggestions = controller.visibleSuggestions
            VStack(spacing: 2) {
                if suggestions.isEmpty {
                    Text(engine.query.isEmpty ? "Keep typing…" : "No emoji for “\(engine.query)”")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                } else {
                    ForEach(Array(suggestions.prefix(5).enumerated()), id: \.element.id) { index, suggestion in
                        PracticeSuggestionRow(suggestion: suggestion, isSelected: index == controller.selectedIndex)
                    }
                }
            }
            .padding(6)
            .frame(width: 280)
            .glassCard(cornerRadius: 12)
            .transition(.opacity.combined(with: .offset(y: -6)))
        } else if let inserted = controller.lastInserted {
            Label {
                Text("Inserted \(inserted). That’s it, it works the same everywhere.")
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(ShellTheme.success)
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .transition(.opacity)
        } else {
            HStack(spacing: 6) {
                KeyCap("↑")
                KeyCap("↓")
                Text("choose")
                KeyCap("⏎")
                Text("insert")
                KeyCap("esc")
                Text("dismiss")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
    }
}

private struct PracticeSuggestionRow: View {
    let suggestion: Suggestion
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            switch suggestion.item {
            case .emoji(let emoji):
                Text(emoji.char)
                    .font(.system(size: 18))
                Text(":\(emoji.id):")
                    .font(ShellTheme.mono(12, weight: .medium))
                    .foregroundStyle(isSelected ? .primary : .secondary)
            case .snippet(let snippet):
                Image(systemName: "text.quote")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ShellTheme.accent)
                    .frame(width: 22)
                Text(":\(snippet.trigger)")
                    .font(ShellTheme.mono(12, weight: .medium))
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            Spacer(minLength: 0)
            if isSelected {
                KeyCap("⏎")
                    .scaleEffect(0.85)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.primary.opacity(0.12) : .clear)
        )
    }
}

/// Single-line text view that routes keystrokes through `PracticeController` first.
private struct PracticeTextView: NSViewRepresentable {
    let controller: PracticeController
    let placeholder: String

    func makeNSView(context: Context) -> PracticeNSTextView {
        let view = PracticeNSTextView()
        view.controller = controller
        view.placeholder = placeholder
        view.isRichText = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        view.textContainerInset = NSSize(width: 0, height: 10)
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.maximumNumberOfLines = 1
        view.textContainer?.lineBreakMode = .byClipping
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.insertionPointColor = ShellTheme.accentNS
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ view: PracticeNSTextView, context: Context) {
        view.controller = controller
        view.placeholder = placeholder
    }
}

final class PracticeNSTextView: NSTextView {
    var controller: PracticeController?
    var placeholder = "" { didSet { needsDisplay = true } }

    override func keyDown(with event: NSEvent) {
        guard let controller else { return super.keyDown(with: event) }
        if !controller.handle(Self.keyInput(for: event), in: self) {
            super.keyDown(with: event)
        }
    }

    /// ⌘↩ arrives as a key equivalent; route it to the picker (multi-insert) while it is open.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let controller, window?.firstResponder === self, Self.keyInput(for: event) == .commandEnter,
           controller.handle(.commandEnter, in: self) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        controller?.interrupt()
        super.mouseDown(with: event)
    }

    override func insertNewline(_ sender: Any?) {
        // Single line: Return is only meaningful while the picker is open.
    }

    override func insertTab(_ sender: Any?) {
        window?.selectNextKeyView(sender)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.monospacedSystemFont(ofSize: 15, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.6),
        ]
        placeholder.draw(at: NSPoint(x: 0, y: textContainerInset.height), withAttributes: attributes)
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }

    static func keyInput(for event: NSEvent) -> KeyInput {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.subtracting([.numericPad, .function, .capsLock]) == .command,
           event.keyCode == 36 || event.keyCode == 76 { return .commandEnter }
        if flags.contains(.command) || flags.contains(.control) { return .interrupt }
        switch event.keyCode {
        case 51: return .backspace
        case 123...126 where flags.contains(.shift) || flags.contains(.option):
            // Text selection and word jumps stay native.
            return .interrupt
        case 126: return .up
        case 125: return .down
        case 123: return .left
        case 124: return .right
        case 36, 76: return .enter
        case 48: return .tab
        case 53: return .escape
        default:
            guard let characters = event.characters, !characters.isEmpty,
                  characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value) })
            else { return .interrupt }
            return .text(characters)
        }
    }
}
