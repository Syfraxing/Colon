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

    /// `EmojifyRepositoryURL`; nil when absent so no link is shown.
    static var repositoryURL: URL? {
        guard let string = Bundle.main.object(forInfoDictionaryKey: "EmojifyRepositoryURL") as? String,
              let url = URL(string: string), url.scheme == "https" else { return nil }
        return url
    }

    static var icon: NSImage { NSApp.applicationIconImage }
}

struct AboutSettingsView: View {
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
                    Text("Emojify")
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
                Footnote("Emojify is open source and free. It keeps no history of what you type; only the emoji you pick are remembered locally to rank favourites first.")
            }
        }
    }
}
