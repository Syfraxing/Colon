import EmojifyCore
import SwiftUI

struct JevSettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var key: JevKeyModel
    let engine: SuggestionEngine?

    var body: some View {
        SettingsPage {
            Section {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(ShellTheme.accent)
                        .frame(width: 36, height: 36)
                        .background(ShellTheme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Smarter ranking with Jev")
                            .font(.headline)
                        Footnote("Emojify searches locally first, instantly. With a Jev key it also asks TypeSafe’s Jev decision model which emoji you most likely mean, so :haha finds 😂 and :sus finds 🤨. Without a key everything still works offline.")
                    }
                }
                .padding(.vertical, 2)
            }

            Section("API key") {
                JevKeyEditor(model: key)
                if let engine, key.hasKey {
                    EngineStatusRow(engine: engine)
                }
            }

            Section {
                Toggle(isOn: Binding(
                    get: { key.hasKey && settings.useJev },
                    set: { settings.useJev = $0 }
                )) {
                    Text("Rerank suggestions with Jev")
                    Text(key.hasKey ? "Local results show first; Jev refines them a moment later." : "Add an API key to turn this on.")
                }
                .disabled(!key.hasKey)
            }

            Section {
                TextContextConsent(isOn: Binding(
                    get: { key.hasKey && settings.useJev && settings.sendTextContext },
                    set: { settings.sendTextContext = $0 }
                ))
                    .disabled(!key.hasKey || !settings.useJev)
            } header: {
                Text("Privacy")
            }
        }
        .onAppear { key.refresh() }
    }
}

/// What the running engine last saw from Jev (live, unlike the one-off Test).
private struct EngineStatusRow: View {
    @ObservedObject var engine: SuggestionEngine

    var body: some View {
        LabeledContent("Last request") {
            switch engine.jevStatus {
            case .disabled: Text("Jev is off").foregroundStyle(.secondary)
            case .noKey: Text("No key loaded").foregroundStyle(.secondary)
            case .idle: Text("Ready").foregroundStyle(.secondary)
            case .ok(let ms): Text("Connected · \(ms) ms").foregroundStyle(ShellTheme.success)
            case .error(let message): Text(message).foregroundStyle(ShellTheme.warning).lineLimit(1)
            }
        }
        .font(.callout)
    }
}
