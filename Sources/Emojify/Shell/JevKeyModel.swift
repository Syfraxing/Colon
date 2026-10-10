import AppKit
import EmojifyCore
import SwiftUI

/// Saving, masking and testing the Jev API key. The full key is never published to the UI:
/// views only ever see `maskedKey`.
@MainActor
final class JevKeyModel: ObservableObject {
    enum TestState: Equatable {
        case idle
        case testing
        case success(milliseconds: Int)
        case failure(String)
    }

    enum KeySource: Equatable {
        case none
        case keychain
        case environment
    }

    static let consoleURL = URL(string: "https://console.typesafe.ai")!

    /// Text in the SecureField. Cleared as soon as the key is saved.
    @Published var draft = ""
    @Published private(set) var maskedKey: String?
    @Published private(set) var source: KeySource = .none
    @Published private(set) var testState: TestState = .idle
    @Published private(set) var saveError: String?

    /// Called after the saved key changes, so the engine can reload it.
    var onKeyChanged: (() -> Void)?

    private var testTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?

    init(onKeyChanged: (() -> Void)? = nil) {
        self.onKeyChanged = onKeyChanged
        refresh()
    }

    var hasKey: Bool { source != .none }

    var canSave: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Re-reads the key off the main thread (a Keychain read can block on an access prompt).
    func refresh(then completion: (() -> Void)? = nil) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            let masked = await Task.detached(priority: .userInitiated) {
                KeychainStore.jevAPIKey.map(JevKeyModel.mask)
            }.value
            guard let self, !Task.isCancelled else { return }
            maskedKey = masked
            source = masked == nil ? .none : (Self.environmentKeyPresent ? .environment : .keychain)
            completion?()
        }
    }

    private static var environmentKeyPresent: Bool {
        #if DEBUG
        return !(ProcessInfo.processInfo.environment["JEV_API_KEY"] ?? "").isEmpty
        #else
        return false
        #endif
    }

    func save() {
        guard canSave else { return }
        if KeychainStore.setJevAPIKey(draft) {
            draft = ""
            saveError = nil
            onKeyChanged?()
            refresh { [weak self] in self?.test() }
        } else {
            saveError = "Couldn’t save the key to the Keychain."
        }
    }

    func remove() {
        testTask?.cancel()
        saveError = KeychainStore.setJevAPIKey(nil) ? nil : "Couldn’t remove the key from the Keychain."
        testState = .idle
        onKeyChanged?()
        refresh()
    }

    func test() {
        testTask?.cancel()
        testState = .testing
        testTask = Task { [weak self] in
            let key = await Task.detached(priority: .userInitiated) { KeychainStore.jevAPIKey }.value
            guard let key else {
                self?.testState = .failure("Add an API key first.")
                return
            }
            let result: TestState
            do {
                let latency = try await JevClient(apiKey: key).ping()
                result = .success(milliseconds: Self.milliseconds(latency))
            } catch is CancellationError {
                return
            } catch {
                result = .failure(Self.describe(error))
            }
            guard !Task.isCancelled else { return }
            self?.testState = result
        }
    }

    func openConsole() {
        NSWorkspace.shared.open(Self.consoleURL)
    }

    /// `••••••••3f9a`: enough to recognise which key is saved, never enough to reuse it.
    nonisolated static func mask(_ key: String) -> String {
        let tail = key.count > 12 ? String(key.suffix(4)) : ""
        return String(repeating: "•", count: 8) + tail
    }

    nonisolated static func milliseconds(_ duration: Duration) -> Int {
        let (seconds, attoseconds) = duration.components
        return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case JevError.missingKey: "No API key."
        case JevError.unauthorized: "Key rejected (401). Check it in the TypeSafe console."
        case JevError.validation: "Jev rejected the test request."
        case JevError.rateLimited: "Rate limited. Try again in a moment."
        case JevError.overloaded: "Jev is overloaded right now. Try again shortly."
        case JevError.http(let code): "Server error (HTTP \(code))."
        case JevError.decoding: "Unexpected response from Jev."
        case let urlError as URLError where urlError.code == .timedOut: "Timed out."
        case let urlError as URLError where urlError.code == .notConnectedToInternet: "You’re offline."
        default: "Couldn’t reach Jev."
        }
    }
}

/// Key entry + saved state + test, used by both the Jev tab and onboarding.
struct JevKeyEditor: View {
    @ObservedObject var model: JevKeyModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let masked = model.maskedKey {
                HStack(spacing: 10) {
                    Image(systemName: "key.fill")
                        .foregroundStyle(ShellTheme.accent)
                    Text(masked)
                        .font(ShellTheme.mono(13))
                        .textSelection(.disabled)
                    if model.source == .environment {
                        Text("from JEV_API_KEY")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Test", action: model.test)
                        .disabled(model.testState == .testing)
                    if model.source == .keychain {
                        Button("Remove", role: .destructive, action: model.remove)
                    }
                }
                JevTestStatusView(state: model.testState)
            }
            HStack(spacing: 8) {
                SecureField("Jev API key", text: $model.draft, prompt: Text(model.hasKey ? "Paste a new key to replace it" : "Paste your Jev API key"))
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
            HStack(spacing: 4) {
                Text("Don’t have a key?")
                    .foregroundStyle(.secondary)
                Link("Get one at console.typesafe.ai", destination: JevKeyModel.consoleURL)
            }
            .font(.caption)
        }
    }
}

struct JevTestStatusView: View {
    let state: JevKeyModel.TestState

    var body: some View {
        switch state {
        case .idle:
            EmptyView()
        case .testing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Testing…").foregroundStyle(.secondary)
            }
            .font(.caption)
        case .success(let ms):
            Label("Connected · \(ms) ms", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(ShellTheme.success)
        case .failure(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .font(.caption)
                .foregroundStyle(ShellTheme.danger)
        }
    }
}

/// Explicit opt-in for sending text context to Jev, with exactly what leaves the Mac.
struct TextContextConsent: View {
    @Binding var isOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $isOn) {
                Text("Send the text before the trigger for better suggestions")
            }
            .toggleStyle(.checkbox)
            VStack(alignment: .leading, spacing: 4) {
                Text("Off by default. When on, each Jev request includes:")
                bullet("your query, e.g. “haha”, and the app name (always sent)")
                bullet("up to 300 characters before the trigger, read from the focused text field via Accessibility only at that moment")
                Text("Never sent: keystrokes, other text, or anything from password fields. Requests go to api.typesafe.ai over HTTPS.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 20)
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•")
            Text(text)
        }
    }
}
