import AppKit
import SwiftUI

/// Values read from Info.plist (packaging fills them in for the .app bundle).
enum AppInfo {
    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        switch (short, build) {
        case let (short?, build?) where build != short: return "Version \(short) (\(build))"
        case let (short?, _): return "Version \(short)"
        default: return "Development build"
        }
    }

    static var shortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    /// `ColonRepositoryURL`; nil when absent so no link is shown.
    static var repositoryURL: URL? {
        guard let string = Bundle.main.object(forInfoDictionaryKey: "ColonRepositoryURL") as? String,
              let url = URL(string: string), url.scheme == "https" else { return nil }
        return url
    }

    static var icon: NSImage { NSApp.applicationIconImage }
}

struct AboutSettingsView: View {
    @ObservedObject var updater: Updater

    private struct Credit: Identifiable {
        let name: String
        let detail: String
        let url: URL
        var id: String { name }
    }

    private let credits = [
        Credit(name: "gemoji", detail: "Shortcodes and aliases by GitHub",
               url: URL(string: "https://github.com/github/gemoji")!),
        Credit(name: "Emojibase", detail: "Emoji names, keywords and metadata",
               url: URL(string: "https://emojibase.dev")!),
        Credit(name: "KeyboardShortcuts", detail: "Global shortcut recorder by Sindre Sorhus",
               url: URL(string: "https://github.com/sindresorhus/KeyboardShortcuts")!),
        Credit(name: "Sparkle", detail: "Secure in-app updates",
               url: URL(string: "https://sparkle-project.org")!),
        Credit(name: "Jev", detail: "Decision model by TypeSafe AI",
               url: URL(string: "https://typesafe.ai")!),
    ]

    var body: some View {
        SettingsPage {
            Section {
                VStack(spacing: 10) {
                    Image(nsImage: AppInfo.icon)
                        .resizable()
                        .frame(width: 96, height: 96)
                        .shadow(color: ShellTheme.accent.opacity(0.25), radius: 18, y: 6)
                    Text("Colon")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                    Text(AppInfo.version)
                        .font(ShellTheme.mono(11))
                        .foregroundStyle(.secondary)
                    Text("Type :haha anywhere. Get 😂.")
                        .foregroundStyle(.secondary)
                    if let repo = AppInfo.repositoryURL {
                        Link(destination: repo) {
                            Label("Source on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                        }
                        .padding(.top, 2)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }

            UpdatesSection(updater: updater)

            Section("Built with") {
                ForEach(credits) { credit in
                    LabeledContent {
                        Link(destination: credit.url) {
                            Image(systemName: "arrow.up.right.square")
                        }
                        .help(credit.url.absoluteString)
                    } label: {
                        Text(credit.name)
                        Text(credit.detail)
                    }
                }
            }

            Section {
                Footnote("Colon is open source and free. It keeps no history of what you type; only the emoji you pick are remembered locally to rank favourites first.")
            }
        }
    }
}

/// Current version, manual check and the automatic-check switch. Sparkle owns the schedule and
/// persists the switch itself; this view only reflects it.
private struct UpdatesSection: View {
    @ObservedObject var updater: Updater

    var body: some View {
        Section {
            LabeledContent("Current version") {
                Text(AppInfo.version)
                    .font(ShellTheme.mono(12))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Toggle(isOn: Binding(
                get: { updater.automaticallyChecksForUpdates },
                set: { updater.automaticallyChecksForUpdates = $0 }
            )) {
                Text("Automatically check for updates")
                Text("Checks once a day in the background.")
            }
            .disabled(!updater.isAvailable)
            LabeledContent {
                Button("Check for Updates…", action: updater.checkForUpdates)
                    .disabled(!updater.canCheckForUpdates)
            } label: {
                Text("Last checked")
                Text(lastChecked)
            }
        } header: {
            Text("Updates")
        } footer: {
            if let reason = updater.unavailableReason {
                Label(reason, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Footnote("Updates come over HTTPS and install only if they carry Colon's EdDSA release signature and a valid code signature.")
            }
        }
    }

    private var lastChecked: String {
        guard updater.isAvailable else { return "Not available in this build" }
        guard let date = updater.lastUpdateCheckDate else { return "Never" }
        return date.formatted(.relative(presentation: .named))
    }
}
