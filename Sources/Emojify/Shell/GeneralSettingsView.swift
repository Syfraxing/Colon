import EmojifyCore
import SwiftUI

struct GeneralSettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var launchAtLogin: LaunchAtLogin

    var body: some View {
        SettingsPage {
            Section {
                Toggle(isOn: $settings.isEnabled) {
                    Text("Enable Emojify")
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
                ValueStepper(
                    title: "Letters before the picker shows",
                    detail: settings.minQueryLength == 0 ? "Shows as soon as you type the trigger." : nil,
                    value: $settings.minQueryLength,
                    range: 0...5
                )
                Toggle(isOn: $settings.autoReplaceOnClosingTrigger) {
                    Text("Replace exact shortcodes when closed")
                    Text(closingExample)
                }
            }

            Section("Picker") {
                ValueStepper(title: "Suggestions shown", value: $settings.maxResults, range: 3...12)
                HStack {
                    Text("Skin tone")
                    Spacer()
                    SkinTonePicker(selection: $settings.skinTone)
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
        return nil
    }

    private func commit() {
        guard problem == nil, draft != settings.triggerString else { return }
        settings.triggerString = draft
    }
}

private struct ValueStepper: View {
    let title: String
    var detail: String?
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
            if let detail { Text(detail) }
        }
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
