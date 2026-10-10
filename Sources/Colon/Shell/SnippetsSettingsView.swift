import ColonCore
import SwiftUI

/// Snippets tab: triggers that expand to saved text (`:sig` → signature). Edits persist through
/// `AppSettings.snippets` (local `UserDefaults` only).
struct SnippetsSettingsView: View {
    @ObservedObject var settings: AppSettings
    @FocusState private var focus: Field?

    enum Field: Hashable {
        case trigger(UUID)
        case text(UUID)
    }

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
                        ForEach(missingStarters, id: \.trigger) { starter in
                            Button {
                                add(trigger: starter.trigger, focusing: .text)
                            } label: {
                                Text(starter.title)
                            }
                            .help("Adds \(settings.triggerString)\(starter.trigger)")
                        }
                    }
                    .font(.system(size: 12))
                }
            } footer: {
                Footnote("Type \(settings.triggerString) and a trigger, e.g. \(settings.triggerString)sig, and the snippet shows in the picker above the emoji. Snippets with no text don't appear.")
            }

            Section {
                if settings.snippets.isEmpty {
                    HStack {
                        Spacer()
                        VStack(spacing: 6) {
                            Image(systemName: "text.quote")
                                .font(.system(size: 22))
                                .foregroundStyle(.tertiary)
                            Text("No snippets yet.")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 18)
                        Spacer()
                    }
                } else {
                    ForEach(settings.snippets) { snippet in
                        SnippetEditorRow(snippet: snippet, settings: settings, focus: $focus) {
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
            focus = target == .trigger ? .trigger(snippet.id) : .text(snippet.id)
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
    var focus: FocusState<SnippetsSettingsView.Field?>.Binding
    let onRemove: () -> Void

    /// What the user typed; saved only while valid, so the stored trigger is always usable.
    @State private var draftTrigger: String
    @State private var hovering = false

    init(snippet: Snippet, settings: AppSettings, focus: FocusState<SnippetsSettingsView.Field?>.Binding,
         onRemove: @escaping () -> Void) {
        self.snippet = snippet
        self.settings = settings
        self.focus = focus
        self.onRemove = onRemove
        _draftTrigger = State(initialValue: snippet.trigger)
    }

    private var problem: Snippet.TriggerProblem? {
        Snippet.problem(with: draftTrigger, among: settings.snippets, excluding: snippet.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(settings.triggerString)
                    .font(ShellTheme.mono(13, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Trigger", text: $draftTrigger, prompt: Text("trigger"))
                    .labelsHidden()
                    .font(ShellTheme.mono(13, weight: .medium))
                    .textFieldStyle(.plain)
                    .frame(maxWidth: 180)
                    .focused(focus, equals: .trigger(snippet.id))
                    .onChange(of: draftTrigger) { _, new in commit(new) }
                    .accessibilityLabel("Trigger")
                Spacer()
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
                Text(problem.message)
                    .font(.caption)
                    .foregroundStyle(ShellTheme.danger)
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: textBinding)
                    .font(.system(size: 12.5))
                    .scrollContentBackground(.hidden)
                    .focused(focus, equals: .text(snippet.id))
                    .frame(minHeight: 38, maxHeight: 110)
                    .accessibilityLabel("Text for \(snippet.trigger)")
                if snippet.text.isEmpty {
                    Text("Text to insert…")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(ShellTheme.fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(ShellTheme.hairline)
            )
        }
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
