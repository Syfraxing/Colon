import AppKit
import ColonCore
import SwiftUI

/// Snippets tab: triggers that expand to saved text (`:sig` → signature). Edits persist through
/// `AppSettings.snippets` (local `UserDefaults` only).
struct SnippetsSettingsView: View {
    @ObservedObject var settings: AppSettings
    /// The trigger field being edited (SwiftUI focus).
    @FocusState private var focusedTrigger: UUID?
    /// The text editor that should take focus (an AppKit text view, so not `@FocusState`).
    @State private var focusedText: UUID?

    /// One-click rows for the snippets almost everyone wants; the user fills in the text.
    private static let starters: [(title: String, trigger: String)] = [
        ("Name", "name"), ("Email", "email"), ("Phone", "phone"), ("Address", "addr"), ("Signature", "sig"),
    ]

    private var missingStarters: [(title: String, trigger: String)] {
        Self.starters.filter { Snippet.problem(with: $0.trigger, among: settings.snippets) == nil }
    }

    var body: some View {
        SettingsPage {
            Section {
                HStack {
                    Button {
                        add(trigger: "", focusing: .trigger)
                    } label: {
                        Label("Add Snippet", systemImage: "plus")
                    }
                    Spacer()
                }
                if !missingStarters.isEmpty {
                    HStack(spacing: 6) {
                        Text("Quick add")
                            .foregroundStyle(.secondary)
                            .padding(.trailing, 4)
                        ForEach(missingStarters, id: \.trigger) { starter in
                            Button {
                                add(trigger: starter.trigger, focusing: .text)
                            } label: {
                                Text(starter.title)
                            }
                            .controlSize(.small)
                            .help("Adds \(settings.triggerString)\(starter.trigger)")
                            .accessibilityLabel("Add \(starter.title) snippet")
                        }
                    }
                }
            } footer: {
                Footnote("Type \(settings.triggerString) and a trigger, e.g. \(settings.triggerString)sig, and the snippet shows in the picker above the emoji. Snippets with no text don't appear.")
            }

            Section {
                if settings.snippets.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "text.quote")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(.tertiary)
                        Text("No Snippets")
                            .foregroundStyle(.secondary)
                        Text("Add one above, or start from a quick add.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                    .accessibilityElement(children: .combine)
                } else {
                    ForEach(settings.snippets) { snippet in
                        SnippetEditorRow(snippet: snippet, settings: settings, focusedTrigger: $focusedTrigger,
                                         focusedText: $focusedText) {
                            remove(snippet.id)
                        }
                    }
                }
            } header: {
                Text("Snippets")
            } footer: {
                Footnote("Stored only on this Mac. Snippets are never sent to Jev: while one matches what you type, Jev isn't asked at all.")
            }
        }
    }

    private enum FocusTarget { case trigger, text }

    private func add(trigger: String, focusing target: FocusTarget) {
        let snippet = Snippet(trigger: trigger, text: "")
        withAnimation(ShellTheme.ease) {
            settings.snippets.append(snippet)
        }
        // Focus once the row exists.
        DispatchQueue.main.async {
            switch target {
            case .trigger: focusedTrigger = snippet.id
            case .text: focusedText = snippet.id
            }
        }
    }

    private func remove(_ id: UUID) {
        withAnimation(ShellTheme.ease) {
            settings.snippets.removeAll { $0.id == id }
        }
    }
}

private struct SnippetEditorRow: View {
    let snippet: Snippet
    @ObservedObject var settings: AppSettings
    var focusedTrigger: FocusState<UUID?>.Binding
    @Binding var focusedText: UUID?
    let onRemove: () -> Void

    /// What the user typed; saved only while valid, so the stored trigger is always usable.
    @State private var draftTrigger: String
    @State private var hovering = false

    init(snippet: Snippet, settings: AppSettings, focusedTrigger: FocusState<UUID?>.Binding,
         focusedText: Binding<UUID?>, onRemove: @escaping () -> Void) {
        self.snippet = snippet
        self.settings = settings
        self.focusedTrigger = focusedTrigger
        _focusedText = focusedText
        self.onRemove = onRemove
        _draftTrigger = State(initialValue: snippet.trigger)
    }

    private var problem: Snippet.TriggerProblem? {
        Snippet.problem(with: draftTrigger, among: settings.snippets, excluding: snippet.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(settings.triggerString)
                    .font(ShellTheme.mono(13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Trigger", text: $draftTrigger, prompt: Text("trigger"))
                    .labelsHidden()
                    .font(ShellTheme.mono(13, weight: .medium))
                    .foregroundStyle(problem == nil ? Color.primary : ShellTheme.danger)
                    .textFieldStyle(.plain)
                    .frame(maxWidth: 180)
                    .focused(focusedTrigger, equals: snippet.id)
                    .onChange(of: draftTrigger) { _, new in commit(new) }
                    .accessibilityLabel("Trigger")
                Spacer(minLength: 12)
                Button(action: onRemove) {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(hovering ? ShellTheme.danger : Color.secondary.opacity(0.6))
                }
                .buttonStyle(.plain)
                .help("Delete snippet")
                .accessibilityLabel("Delete snippet \(snippet.trigger)")
            }
            if let problem {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: "exclamationmark.circle.fill")
                    Text(problem.message)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption)
                .foregroundStyle(ShellTheme.danger)
                .transition(.opacity)
            }
            SnippetTextView(
                text: textBinding,
                placeholder: "Text to insert…",
                accessibilityLabel: "Text for \(settings.triggerString)\(snippet.trigger)",
                isFocused: focusedText == snippet.id
            ) { isFirstResponder in
                if isFirstResponder {
                    focusedText = snippet.id
                } else if focusedText == snippet.id {
                    focusedText = nil
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(ShellTheme.fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(ShellTheme.hairline)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .animation(ShellTheme.ease, value: problem)
        .onHover { hovering = $0 }
        .padding(.vertical, 4)
    }

    private func commit(_ trigger: String) {
        guard Snippet.problem(with: trigger, among: settings.snippets, excluding: snippet.id) == nil,
              let index = settings.snippets.firstIndex(where: { $0.id == snippet.id }),
              settings.snippets[index].trigger != trigger else { return }
        settings.snippets[index].trigger = trigger
    }

    private var textBinding: Binding<String> {
        Binding {
            settings.snippets.first { $0.id == snippet.id }?.text ?? ""
        } set: { text in
            guard let index = settings.snippets.firstIndex(where: { $0.id == snippet.id }) else { return }
            settings.snippets[index].text = text
        }
    }
}

/// Multi-line snippet text. An `NSTextView` instead of `TextEditor`: overlay scrollers (no legacy
/// scroller track inside the box), Tab moves focus, and the box grows with the text between two
/// and six lines.
private struct SnippetTextView: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let accessibilityLabel: String
    /// SwiftUI focus (set by Quick add) points at this editor; turning true makes it first responder.
    let isFocused: Bool
    /// Reports first-responder changes so SwiftUI focus stays in step with clicks.
    let onFocusChange: (Bool) -> Void

    private static let font = NSFont.systemFont(ofSize: 13)
    private static let inset = NSSize(width: 8, height: 7)
    private static let lineRange: ClosedRange<Int> = 2...6

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = SnippetNSTextView()
        textView.delegate = context.coordinator
        textView.onFocusChange = { [coordinator = context.coordinator] in coordinator.parent.onFocusChange($0) }
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = Self.font
        textView.textContainerInset = Self.inset
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.insertionPointColor = ShellTheme.accentNS

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScrollElasticity = .none
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? SnippetNSTextView else { return }
        if textView.string != text { textView.string = text }
        textView.placeholder = placeholder
        textView.setAccessibilityLabel(accessibilityLabel)
        if isFocused, !context.coordinator.wasFocused, textView.window?.firstResponder !== textView {
            DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        }
        context.coordinator.wasFocused = isFocused
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView scrollView: NSScrollView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite,
              let textView = scrollView.documentView as? SnippetNSTextView else { return nil }
        let line = Self.lineHeight
        let minHeight = CGFloat(Self.lineRange.lowerBound) * line + Self.inset.height * 2
        let maxHeight = CGFloat(Self.lineRange.upperBound) * line + Self.inset.height * 2
        let content = textView.contentHeight(forWidth: width - Self.inset.width * 2) + Self.inset.height * 2
        return CGSize(width: width, height: min(max(content.rounded(.up), minHeight), maxHeight))
    }

    private static var lineHeight: CGFloat {
        (font.ascender - font.descender + font.leading).rounded(.up)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SnippetTextView
        var wasFocused = false

        init(parent: SnippetTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}

private final class SnippetNSTextView: NSTextView {
    var placeholder = "" { didSet { needsDisplay = true } }
    var onFocusChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onFocusChange?(false) }
        return accepted
    }

    /// Tab moves between controls, as everywhere else in Settings; snippet text never needs tabs.
    override func insertTab(_ sender: Any?) {
        window?.selectNextKeyView(sender)
    }

    override func insertBacktab(_ sender: Any?) {
        window?.selectPreviousKeyView(sender)
    }

    /// Height the text needs when wrapped at `width`.
    func contentHeight(forWidth width: CGFloat) -> CGFloat {
        textContainer?.size = NSSize(width: max(width, 1), height: CGFloat.greatestFiniteMagnitude)
        if let layoutManager = textLayoutManager {
            layoutManager.ensureLayout(for: layoutManager.documentRange)
            return layoutManager.usageBoundsForTextContainer.height
        }
        if let layoutManager, let textContainer {
            layoutManager.ensureLayout(for: textContainer)
            return layoutManager.usedRect(for: textContainer).height
        }
        return 0
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.placeholderTextColor,
        ]
        placeholder.draw(at: NSPoint(x: textContainerInset.width, y: textContainerInset.height), withAttributes: attributes)
    }
}
