import AppKit
import EmojifyCore
import SwiftUI
import UniformTypeIdentifiers

/// Display info for an app identified only by its bundle ID.
struct AppIdentity: Identifiable, Hashable {
    let bundleID: String
    let name: String
    let icon: NSImage
    let isInstalled: Bool

    var id: String { bundleID }

    @MainActor
    init(bundleID: String) {
        self.bundleID = bundleID
        let workspace = NSWorkspace.shared
        if let url = workspace.urlForApplication(withBundleIdentifier: bundleID) {
            name = AppIdentity.displayName(at: url)
            icon = workspace.icon(forFile: url.path)
            isInstalled = true
        } else {
            name = Self.knownNames[bundleID] ?? bundleID
            icon = workspace.icon(for: .applicationBundle)
            isInstalled = false
        }
    }

    /// Names for the default exclusions, so they read well even when not installed.
    private static let knownNames = [
        "com.tinyspeck.slackmacgap": "Slack",
        "com.hnc.Discord": "Discord",
        "com.microsoft.teams2": "Microsoft Teams",
        "com.linear": "Linear",
        "notion.id": "Notion",
        "com.github.GitHubClient": "GitHub Desktop",
        "com.apple.Terminal": "Terminal",
        "com.googlecode.iterm2": "iTerm",
        "com.mitchellh.ghostty": "Ghostty",
        "dev.warp.Warp-Stable": "Warp",
        "com.microsoft.VSCode": "Visual Studio Code",
        "com.apple.dt.Xcode": "Xcode",
        "dev.zed.Zed": "Zed",
        "com.todesktop.230313mzl4w4u92": "Cursor",
        "com.1password.1password": "1Password",
        "com.bitwarden.desktop": "Bitwarden",
        "com.apple.keychainaccess": "Keychain Access",
        "com.apple.Passwords": "Passwords",
    ]

    static func displayName(at url: URL) -> String {
        let info = Bundle(url: url)?.localizedInfoDictionary ?? Bundle(url: url)?.infoDictionary
        if let name = info?["CFBundleDisplayName"] as? String ?? info?["CFBundleName"] as? String, !name.isEmpty {
            return name
        }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

struct ExcludedAppsSettingsView: View {
    @ObservedObject var settings: AppSettings

    private var apps: [AppIdentity] {
        settings.excludedBundleIDs
            .map(AppIdentity.init(bundleID:))
            .sorted {
                // Installed apps first, then alphabetical.
                if $0.isInstalled != $1.isInstalled { return $0.isInstalled }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    var body: some View {
        SettingsPage {
            Section {
                HStack {
                    Menu {
                        let running = runningApps
                        if running.isEmpty {
                            Text("No other apps running")
                        }
                        ForEach(running, id: \.bundleID) { app in
                            Button {
                                add(app.bundleID)
                            } label: {
                                Label {
                                    Text(app.name)
                                } icon: {
                                    Image(nsImage: Self.menuIcon(app.icon))
                                }
                            }
                        }
                        Divider()
                        Button("Choose from Applications…", action: chooseApp)
                    } label: {
                        Label("Add App", systemImage: "plus")
                    }
                    .fixedSize()
                    Spacer()
                    Button("Restore Defaults") {
                        withAnimation(ShellTheme.ease) {
                            settings.excludedBundleIDs = AppSettings.defaultExcludedBundleIDs
                        }
                    }
                    .disabled(settings.excludedBundleIDs == AppSettings.defaultExcludedBundleIDs)
                }
            }
            Section {
                if settings.excludedBundleIDs.isEmpty {
                    HStack {
                        Spacer()
                        VStack(spacing: 6) {
                            Image(systemName: "checkmark.seal")
                                .font(.system(size: 22))
                                .foregroundStyle(.tertiary)
                            Text("Emojify works in every app.")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 18)
                        Spacer()
                    }
                } else {
                    ForEach(apps) { app in
                        AppRow(app: app) { remove(app.bundleID) }
                    }
                }
            } header: {
                Text("Emojify stays silent in these apps")
            } footer: {
                Footnote("Excluded by default: apps with their own :shortcode: picker (Slack, Discord), terminals and code editors where : is everyday syntax, and password managers.")
            }
        }
    }

    /// Regular apps currently running that aren't excluded yet, ourselves excluded.
    private var runningApps: [AppIdentity] {
        let own = Bundle.main.bundleIdentifier
        var seen = Set(settings.excludedBundleIDs)
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.bundleIdentifier)
            .filter { $0 != own && seen.insert($0).inserted }
            .map(AppIdentity.init(bundleID:))
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func add(_ bundleID: String) {
        guard !settings.excludedBundleIDs.contains(bundleID) else { return }
        withAnimation(ShellTheme.ease) {
            settings.excludedBundleIDs.append(bundleID)
        }
    }

    private func remove(_ bundleID: String) {
        withAnimation(ShellTheme.ease) {
            settings.excludedBundleIDs.removeAll { $0 == bundleID }
        }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.title = "Exclude Apps"
        panel.prompt = "Exclude"
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let bundleID = Bundle(url: url)?.bundleIdentifier {
                add(bundleID)
            }
        }
    }

    private static func menuIcon(_ image: NSImage) -> NSImage {
        let copy = image.copy() as! NSImage
        copy.size = NSSize(width: 16, height: 16)
        return copy
    }
}

private struct AppRow: View {
    let app: AppIdentity
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: app.icon)
                .resizable()
                .frame(width: 26, height: 26)
                .opacity(app.isInstalled ? 1 : 0.5)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name)
                Text(app.isInstalled ? app.bundleID : "\(app.bundleID) · not installed")
                    .font(ShellTheme.mono(10))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button(action: onRemove) {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(hovering ? ShellTheme.danger : Color.secondary.opacity(0.6))
            }
            .buttonStyle(.plain)
            .help("Remove \(app.name)")
            .accessibilityLabel("Remove \(app.name)")
        }
        .onHover { hovering = $0 }
        .padding(.vertical, 1)
    }
}
