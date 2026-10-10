import AppKit
import Combine
import EmojifyCore
import KeyboardShortcuts

/// Menu bar icon + menu. OWNER: shell worker.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    var onOpenSettings: (() -> Void)?
    var onQuit: (() -> Void)?
    /// Opens the picker in search mode. The "Open Picker" item is disabled until this is set.
    var onOpenPicker: (() -> Void)?

    private let settings: AppSettings
    private let engine: SuggestionEngine
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let header = MenuHeaderView()
    private var cancellables = Set<AnyCancellable>()
    /// Last app other than Emojify that was frontmost: the target of "Pause for …".
    private var lastExternalApp: NSRunningApplication?
    private var inputStatus: InputStatus = .running

    init(settings: AppSettings, engine: SuggestionEngine) {
        self.settings = settings
        self.engine = engine
        super.init()

        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        header.onToggle = { [weak self] isOn in self?.settings.isEnabled = isOn }

        settings.$isEnabled
            .sink { [weak self] isEnabled in self?.applyEnabled(isEnabled) }
            .store(in: &cancellables)

        lastExternalApp = Self.externalFrontmost()
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .compactMap { $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
            .filter { $0.bundleIdentifier != Bundle.main.bundleIdentifier && $0 != NSRunningApplication.current }
            .sink { [weak self] app in self?.lastExternalApp = app }
            .store(in: &cancellables)
    }

    /// Reflects what the input layer is doing (permission missing, secure input, …).
    func update(inputStatus: InputStatus) {
        self.inputStatus = inputStatus
        applyEnabled(settings.isEnabled)
    }

    private func applyEnabled(_ isEnabled: Bool) {
        guard let button = statusItem.button else { return }
        let symbol = switch inputStatus {
        case .noPermission: "exclamationmark.triangle"
        case .secureInput: "lock"
        case .running, .disabled: "face.smiling"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Emojify")?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
        image?.isTemplate = true
        button.image = image
        button.appearsDisabled = !isEnabled || inputStatus != .running
        button.toolTip = isEnabled ? (statusMessage ?? "Emojify") : "Emojify (off)"
        header.isOn = isEnabled
    }

    /// Why Emojify isn't listening right now, if it isn't (and the user hasn't just turned it off).
    private var statusMessage: String? {
        switch inputStatus {
        case .running, .disabled: nil
        case .noPermission: "Accessibility permission needed"
        case .secureInput: "Paused: another app turned on Secure Input"
        }
    }

    private static func externalFrontmost() -> NSRunningApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication, app != NSRunningApplication.current else { return nil }
        return app
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        header.isOn = settings.isEnabled
        let headerItem = NSMenuItem()
        headerItem.view = header
        menu.addItem(headerItem)
        if settings.isEnabled, let message = statusMessage {
            let item = NSMenuItem(title: message, action: nil, keyEquivalent: "")
            if inputStatus == .noPermission {
                item.action = #selector(openSettings)
                item.target = self
            }
            item.isEnabled = item.action != nil
            item.image = symbol(inputStatus == .secureInput ? "lock.fill" : "exclamationmark.triangle.fill")
            item.toolTip = inputStatus == .secureInput
                ? "macOS hides keystrokes from every app while Secure Input is on (password fields, some terminals). Emojify resumes automatically."
                : "Open setup to grant Accessibility access."
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let openPicker = NSMenuItem(title: "Open Picker", action: #selector(openPicker), keyEquivalent: "")
        openPicker.target = self
        openPicker.image = symbol("magnifyingglass")
        openPicker.setShortcut(for: .openPicker)
        openPicker.isEnabled = onOpenPicker != nil && settings.isEnabled
        menu.addItem(openPicker)

        if let app = Self.externalFrontmost() ?? lastExternalApp, let bundleID = app.bundleIdentifier {
            let name = app.localizedName ?? bundleID
            let excluded = settings.isExcluded(bundleID: bundleID)
            let pause = NSMenuItem(title: "Pause in \(name)", action: #selector(togglePause(_:)), keyEquivalent: "")
            pause.target = self
            pause.representedObject = bundleID
            pause.state = excluded ? .on : .off
            pause.image = symbol("pause.circle")
            pause.toolTip = excluded ? "Emojify is off in \(name). Click to turn it back on." : "Stop Emojify from appearing in \(name)."
            menu.addItem(pause)
        }

        menu.addItem(.separator())
        menu.addItem(jevStatusItem())
        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let quit = NSMenuItem(title: "Quit Emojify", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func jevStatusItem() -> NSMenuItem {
        let (text, color): (String, NSColor) = switch engine.jevStatus {
        case .disabled: ("Jev off · local ranking", .tertiaryLabelColor)
        case .noKey: ("Jev · no API key", .tertiaryLabelColor)
        case .idle: ("Jev · ready", .systemGreen)
        case .ok(let ms): ("Jev · connected \(ms) ms", .systemGreen)
        case .error(let message): ("Jev · \(message)", .systemOrange)
        }
        let item = NSMenuItem(title: text, action: #selector(openSettings), keyEquivalent: "")
        item.target = self
        item.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.menuFont(ofSize: 0),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        item.image = Self.dot(color: color)
        item.toolTip = "Open Jev settings"
        return item
    }

    private func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    private static func dot(color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.midX - 4, y: rect.midY - 4, width: 8, height: 8)).fill()
            return true
        }
    }

    // MARK: Actions

    @objc private func openPicker() {
        onOpenPicker?()
    }

    @objc private func togglePause(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        if settings.isExcluded(bundleID: bundleID) {
            settings.excludedBundleIDs.removeAll { $0 == bundleID }
        } else {
            settings.excludedBundleIDs.append(bundleID)
        }
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }

    @objc private func quit() {
        onQuit?()
    }
}

/// "Emojify" title with an on/off switch, the first row of the menu.
private final class MenuHeaderView: NSView {
    var onToggle: ((Bool) -> Void)?

    var isOn: Bool {
        get { toggle.state == .on }
        set {
            toggle.state = newValue ? .on : .off
            subtitle.stringValue = newValue ? "On" : "Off"
        }
    }

    private let title = NSTextField(labelWithString: "Emojify")
    private let subtitle = NSTextField(labelWithString: "On")
    private let toggle = NSSwitch()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 34))
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        toggle.controlSize = .small
        toggle.target = self
        toggle.action = #selector(toggled)
        toggle.setAccessibilityLabel("Enable Emojify")

        let labels = NSStackView(views: [title, subtitle])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 0

        let row = NSStackView(views: [labels, NSView(), toggle])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func toggled() {
        onToggle?(toggle.state == .on)
    }
}
