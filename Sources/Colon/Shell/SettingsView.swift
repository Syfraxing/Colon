import ColonCore
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, jev, shortcuts, excludedApps, about

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .jev: "Jev"
        case .shortcuts: "Shortcuts"
        case .excludedApps: "Excluded Apps"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .jev: "sparkles"
        case .shortcuts: "command"
        case .excludedApps: "nosign"
        case .about: "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general: Color(white: 0.55)
        case .jev: ShellTheme.accent
        case .shortcuts: Color(red: 0.55, green: 0.45, blue: 0.95)
        case .excludedApps: Color(red: 0.95, green: 0.42, blue: 0.40)
        case .about: Color(red: 0.35, green: 0.70, blue: 0.85)
        }
    }
}

/// Which tab the Settings window shows. Owned by the window controller so the menu can deep-link.
@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var tab: SettingsTab? = .general
}

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var navigation: SettingsNavigation
    @ObservedObject var jevKey: JevKeyModel
    /// The live engine, for the Jev status line; nil before the coordinator passes it.
    let engine: SuggestionEngine?
    let updater: Updater
    @StateObject private var launchAtLogin = LaunchAtLogin()

    private var tab: SettingsTab { navigation.tab ?? .general }

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selection: $navigation.tab)
                .frame(width: 208)
            VStack(alignment: .leading, spacing: 0) {
                Text(tab.title)
                    .font(.system(size: 20, weight: .semibold))
                    .padding(.horizontal, 28)
                    .padding(.top, 22)
                    .frame(height: 58, alignment: .bottomLeading)
                detail
                    .id(tab)
                    .transition(.opacity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .ignoresSafeArea()
        .tint(ShellTheme.accent)
        .frame(minWidth: 720, minHeight: 520)
    }

    @ViewBuilder
    private var detail: some View {
        switch tab {
        case .general:
            GeneralSettingsView(settings: settings, launchAtLogin: launchAtLogin)
        case .jev:
            JevSettingsView(settings: settings, key: jevKey, engine: engine)
        case .shortcuts:
            ShortcutsSettingsView(settings: settings)
        case .excludedApps:
            ExcludedAppsSettingsView(settings: settings)
        case .about:
            AboutSettingsView(updater: updater)
        }
    }
}

/// Translucent sidebar: Liquid Glass panel on macOS 26+, behind-window vibrancy before.
private struct SettingsSidebar: View {
    @Binding var selection: SettingsTab?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsTab.allCases) { tab in
                SidebarRow(tab: tab, isSelected: (selection ?? .general) == tab) {
                    withAnimation(ShellTheme.ease) { selection = tab }
                }
            }
            Spacer()
            HStack(spacing: 8) {
                Image(nsImage: AppInfo.icon)
                    .resizable()
                    .frame(width: 22, height: 22)
                Text("Colon")
                    .font(.system(size: 12, weight: .semibold))
                Text(AppInfo.shortVersion)
                    .font(ShellTheme.mono(10))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
        }
        .padding(.horizontal, 16)
        .padding(.top, 54)
        .padding(.bottom, 10)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(background)
    }

    @ViewBuilder
    private var background: some View {
        if #available(macOS 26.0, *) {
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                Color.clear
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(8)
            }
        } else {
            VisualEffectBackground(material: .sidebar)
                .overlay(alignment: .trailing) {
                    Rectangle().fill(ShellTheme.hairline).frame(width: 1)
                }
        }
    }
}

private struct SidebarRow: View {
    let tab: SettingsTab
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                SidebarIcon(symbol: tab.symbol, tint: tab.tint)
                Text(tab.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(isSelected ? 0.11 : hovering ? 0.05 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// System Settings–style rounded square icon.
struct SidebarIcon: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(
                LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.75)], startPoint: .top, endPoint: .bottom),
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
    }
}

/// Grouped form with the shared styling every tab uses.
struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
    }
}

/// Secondary explanatory text under a control.
struct Footnote: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
