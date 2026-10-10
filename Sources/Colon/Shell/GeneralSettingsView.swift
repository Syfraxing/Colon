import ColonCore
import SwiftUI

struct GeneralSettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var launchAtLogin: LaunchAtLogin

    var body: some View {
        SettingsPage {
            Section {
                Toggle(isOn: $settings.isEnabled) {
                    Text("Enable Colon")
                    Text("Show the picker when you type the trigger in any app.")
                }
                Toggle(isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                )) {
                    Text("Launch at login")
                }
                if launchAtLogin.needsApproval {
                    HStack {
                        Footnote("Waiting for approval in System Settings → General → Login Items.")
                        Spacer()
                        Button("Open Login Items", action: launchAtLogin.openLoginItems)
                            .controlSize(.small)
                    }
                }
                if let error = launchAtLogin.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(ShellTheme.warning)
                }
            }

            Section("Trigger") {
                TriggerField(settings: settings)
                ValueStepper(title: "Letters before the picker shows", value: $settings.minQueryLength, range: 1...5)
                Toggle(isOn: $settings.autoReplaceOnClosingTrigger) {
                    Text("Replace exact shortcodes when closed")
                    Text(closingExample)
                }
            }

            Section("Picker") {
                Picker(selection: $settings.pickerLayout) {
                    Text("List").tag(PickerLayout.list)
                    Text("Compact").tag(PickerLayout.compact)
                } label: {
                    Text("Layout")
                    Text(settings.pickerLayout == .list
                        ? "Emoji with their shortcodes, one per row."
                        : "One row of emoji; ← → choose, the shortcode shows underneath.")
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Toggle(isOn: $settings.showRecentsOnTrigger) {
                    Text("Show recent emoji on trigger")
                    Text("Typing \(settings.triggerString) alone shows your most-used emoji. ↩ still types a newline until you arrow into them.")
                }
                ValueStepper(title: "Suggestions shown", value: $settings.maxResults, range: 3...12)
                HStack {
                    Text("Skin tone")
                    Spacer()
                    SkinTonePicker(selection: $settings.skinTone)
                }
            }

            Section("Search languages") {
                SearchLanguagesRow(settings: settings)
            }

            Section("Feedback") {
                Toggle(isOn: $settings.playsInsertSound) {
                    Text("Sound on insert")
                    Text("A soft, quiet click each time an emoji goes in.")
                }
                .onChange(of: settings.playsInsertSound) { _, isOn in
                    if isOn { Feedback.previewClick() }
                }
                Toggle(isOn: $settings.hapticFeedback) {
                    Text("Haptic feedback")
                    Text("A light tick on the trackpad as the highlight moves.")
                }
                .onChange(of: settings.hapticFeedback) { _, isOn in
                    if isOn { Feedback.previewHaptic() }
                }
            }

            Section {
                Picker("Insert emoji by", selection: $settings.insertionMethod) {
                    Text("Typing").tag(InsertionMethod.typing)
                    Text("Pasting").tag(InsertionMethod.paste)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Insertion")
            } footer: {
                Footnote(settings.insertionMethod == .typing
                    ? "Types the emoji as keystrokes. Your clipboard is never touched. Works in almost every app."
                    : "Pastes with ⌘V and restores your clipboard right after. Try this if an app drops typed emoji.")
            }
        }
    }

    private var closingExample: String {
        let t = settings.triggerString
        return "Typing \(t)joy\(t) inserts 😂 instantly, without opening the picker."
    }
}

/// Trigger string editor. Only valid values (1–3 chars, no whitespace) are written to settings.
private struct TriggerField: View {
    @ObservedObject var settings: AppSettings
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        LabeledContent {
                HStack(spacing: 10) {
                    if let problem {
                        Text(problem)
                            .font(.caption)
                            .foregroundStyle(ShellTheme.danger)
                    } else {
                        HStack(spacing: 6) {
                            CodeChip("\(draft)haha")
                            Image(systemName: "arrow.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                            Text("😂")
                        }
                    }
                    TextField("", text: $draft, prompt: Text(":"))
                        .textFieldStyle(.roundedBorder)
                        .font(ShellTheme.mono(13, weight: .medium))
                        .multilineTextAlignment(.center)
                        .frame(width: 56)
                        .focused($focused)
                        .onSubmit(commit)
                }
        } label: {
            Text("Trigger")
            Text("Starts a search, Slack style. Up to 3 symbols, e.g. : or ;;")
        }
        .onAppear { draft = settings.triggerString }
        .onChange(of: draft) { _, _ in commit() }
        .onChange(of: focused) { _, isFocused in
            // Leaving the field with an invalid value restores the saved trigger.
            if !isFocused, problem != nil { draft = settings.triggerString }
        }
    }

    private var problem: String? {
        if draft.isEmpty { return "Can’t be empty" }
        if draft.contains(where: \.isWhitespace) { return "No spaces" }
        if draft.count > 3 { return "Max 3 characters" }
        if draft.contains(where: { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "+" || $0 == "-" }) {
            return "Use symbols, not letters"
        }
        if !AppSettings.isValidTrigger(draft) { return "Use plain ASCII symbols" }
        return nil
    }

    private func commit() {
        guard problem == nil, draft != settings.triggerString else { return }
        settings.triggerString = draft
    }
}

private struct ValueStepper: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                Text("\(value)")
                    .font(ShellTheme.mono(13, weight: .medium))
                    .monospacedDigit()
                    .frame(minWidth: 18, alignment: .trailing)
                    .contentTransition(.numericText(value: Double(value)))
                    .animation(ShellTheme.ease, value: value)
                Stepper(title, value: $value, in: range)
                    .labelsHidden()
            }
        } label: {
            Text(title)
        }
    }
}

/// English is always searched; extra CLDR languages are picked in a checklist popover.
private struct SearchLanguagesRow: View {
    @ObservedObject var settings: AppSettings
    @State private var showsPicker = false

    private struct Language: Identifiable {
        let code: String
        let native: String
        let local: String?
        var id: String { code }
    }

    /// Sorted by the language's own name, like Language & Region's "Add Language" list.
    private static let languages: [Language] = SearchLanguages.supported
        .map { code in
            let names = SearchLanguages.localizedNames(for: code)
            return Language(code: code, native: names.native, local: names.local)
        }
        .sorted { $0.native.localizedStandardCompare($1.native) == .orderedAscending }

    var body: some View {
        LabeledContent {
            Button("Choose…") { showsPicker.toggle() }
                .popover(isPresented: $showsPicker, arrowEdge: .trailing) { picker }
                .accessibilityLabel("Choose search languages")
        } label: {
            Text(summary)
            Text("Find emoji by their names in these languages too, e.g. \(settings.triggerString)inima → ❤️ in Romanian. Accents are optional; shortcodes always work.")
        }
    }

    /// "English, Spanish, and Romanian": names in the UI language, in the order they were chosen.
    private var summary: String {
        let names = settings.searchLanguages.map { code in
            let names = SearchLanguages.localizedNames(for: code)
            return names.local ?? names.native
        }
        return (["English"] + names).formatted(.list(type: .and))
    }

    private var picker: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: .constant(true)) {
                    LanguageLabel(native: "English", local: nil)
                }
                .disabled(true)
                .help("English names and shortcodes are always searched.")
                .accessibilityHint("Always on")
                Divider()
                ForEach(Self.languages) { language in
                    Toggle(isOn: binding(for: language.code)) {
                        LanguageLabel(native: language.native, local: language.local)
                    }
                    .accessibilityLabel(SearchLanguages.displayName(for: language.code))
                }
            }
            .toggleStyle(.checkbox)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .frame(width: 336, height: 380)
    }

    /// One line per language: own name first, then the name in the UI language in secondary
    /// colour. The secondary part truncates first, so rows never wrap.
    private struct LanguageLabel: View {
        let native: String
        let local: String?

        var body: some View {
            HStack(spacing: 6) {
                Text(native)
                    .fixedSize()
                if let local {
                    Text(local)
                        .foregroundStyle(.secondary)
                        .truncationMode(.tail)
                }
            }
            .lineLimit(1)
        }
    }

    private func binding(for code: String) -> Binding<Bool> {
        Binding(
            get: { settings.searchLanguages.contains(code) },
            set: { isOn in
                if isOn {
                    if !settings.searchLanguages.contains(code) { settings.searchLanguages.append(code) }
                } else {
                    settings.searchLanguages.removeAll { $0 == code }
                }
            }
        )
    }
}

private struct SkinTonePicker: View {
    @Binding var selection: SkinTone

    var body: some View {
        HStack(spacing: 4) {
            ForEach(SkinTone.allCases, id: \.self) { tone in
                Button {
                    withAnimation(ShellTheme.ease) { selection = tone }
                } label: {
                    Text(tone.swatch)
                        .font(.system(size: 17))
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(tone == selection ? ShellTheme.accent.opacity(0.18) : .clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(tone == selection ? ShellTheme.accent : .clear, lineWidth: 1.5)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Self.name(tone))
                .accessibilityLabel(Self.name(tone))
                .accessibilityAddTraits(tone == selection ? .isSelected : [])
            }
        }
    }

    static func name(_ tone: SkinTone) -> String {
        switch tone {
        case .none: "Default"
        case .light: "Light"
        case .mediumLight: "Medium-light"
        case .medium: "Medium"
        case .mediumDark: "Medium-dark"
        case .dark: "Dark"
        }
    }
}
