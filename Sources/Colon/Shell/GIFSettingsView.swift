import ColonCore
import SwiftUI

/// Settings → GIFs: what `:gif` does, the GIPHY key, content rating and privacy.
struct GIFSettingsView: View {
    @ObservedObject var settings: AppSettings
    @StateObject private var key = GIFKeyModel()
    @AppStorage(GIFRating.defaultsKey) private var rating = GIFRating.default.rawValue

    private static let tint = Color(red: 0.62, green: 0.36, blue: 0.98)

    var body: some View {
        SettingsPage {
            Section {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "photo.stack.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Self.tint)
                        .frame(width: 36, height: 36)
                        .background(Self.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("GIFs anywhere")
                            .font(.headline)
                        Footnote("Type \(settings.triggerString)gif and a space in any app to search GIPHY. Arrow keys pick, ↩ pastes the GIF where you were typing, Esc closes. Your clipboard comes back a moment later.")
                    }
                }
                .padding(.vertical, 2)

                Toggle(isOn: $settings.gifSearchEnabled) {
                    Text("Open GIF search with")
                    HStack(spacing: 4) {
                        CodeChip("\(settings.triggerString)gif")
                        Text("followed by a space")
                    }
                }
            }

            Section("GIPHY API key") {
                GIFKeyEditor(model: key)
            }

            Section {
                Picker("Content rating", selection: $rating) {
                    ForEach(GIFRating.allCases) { rating in
                        Text(rating.title).tag(rating.rawValue)
                    }
                }
                Footnote("GIPHY only returns GIFs at or below this rating. PG-13 is the default.")
            }

            Section("Privacy") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your search terms go to GIPHY (api.giphy.com) over HTTPS with your key. Colon never saves your searches; results stay in memory while the panel is open.")
                    Text("If you have a Jev key, the search terms and the GIF titles go to Jev to put the best match first, plus the text before the trigger only if you allowed that in the Jev tab.")
                    Text("A GIF you pick is saved to Colon’s cache folder so apps can paste it, and removed after a day.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { key.refresh() }
    }
}

/// Key entry, saved state and test for GIPHY, styled like the Jev key editor.
private struct GIFKeyEditor: View {
    @ObservedObject var model: GIFKeyModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let masked = model.maskedKey {
                HStack(spacing: 10) {
                    Image(systemName: "key.fill")
                        .foregroundStyle(ShellTheme.accent)
                    Text(masked)
                        .font(ShellTheme.mono(13))
                        .textSelection(.disabled)
                    Spacer()
                    Button("Test", action: model.test)
                        .disabled(model.testState == .testing)
                    Button("Remove", role: .destructive, action: model.remove)
                }
                JevTestStatusView(state: model.testState)
            }
            HStack(spacing: 8) {
                SecureField("GIPHY API key", text: $model.draft,
                            prompt: Text(model.hasKey ? "Paste a new key to replace it" : "Paste your GIPHY API key"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(ShellTheme.mono(12))
                    .onSubmit(model.save)
                Button("Save", action: model.save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canSave)
            }
            if let error = model.saveError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(ShellTheme.danger)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text("Don’t have a key?")
                        .foregroundStyle(.secondary)
                    Link("Get a free one at developers.giphy.com", destination: GIPHYClient.dashboardURL)
                }
                Text("Create an app, choose API, and copy its key. Free beta keys allow 100 requests an hour, plenty for personal use.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
        }
    }
}
