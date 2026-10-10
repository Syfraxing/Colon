import ColonCore
import KeyboardShortcuts
import SwiftUI

struct ShortcutsSettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        SettingsPage {
            Section {
                KeyboardShortcuts.Recorder("Open picker", name: .openPicker)
            } header: {
                Text("Global")
            } footer: {
                Footnote("Opens the picker in search mode from anywhere. The emoji you pick goes into the app you were using.")
            }

            Section("While the picker is open") {
                KeyRow(keys: ["↑", "↓"], text: "Move the selection")
                KeyRow(keys: ["⏎", "⇥"], text: "Insert the selected emoji")
                KeyRow(keys: ["esc"], text: "Close the picker and keep what you typed")
                KeyRow(keys: ["space"], text: "Close the picker and keep typing")
                KeyRow(keys: ["⌫"], text: "Edit the query; deleting the trigger closes the picker")
                if settings.autoReplaceOnClosingTrigger {
                    KeyRow(keys: [settings.triggerString], text: "After an exact shortcode like \(settings.triggerString)joy, insert it directly")
                }
            }
        }
    }
}

private struct KeyRow: View {
    let keys: [String]
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                ForEach(keys, id: \.self) { KeyCap($0) }
            }
            .frame(width: 70, alignment: .leading)
            Text(text)
            Spacer(minLength: 0)
        }
    }
}
