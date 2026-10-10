import AppKit
import ColonCore
import SwiftUI

/// Saving, masking and testing the GIPHY API key. Views only ever see `maskedKey`.
@MainActor
final class GIFKeyModel: ObservableObject {
    /// Draft text in the SecureField. Cleared as soon as the key is saved.
    @Published var draft = ""
    @Published private(set) var maskedKey: String?
    @Published private(set) var testState: JevKeyModel.TestState = .idle
    @Published private(set) var saveError: String?
    /// The Keychain has been read at least once (avoids flashing the empty state).
    @Published private(set) var isLoaded = false

    private var testTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?

    init() {
        refresh()
    }

    var hasKey: Bool { maskedKey != nil }

    var canSave: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Re-reads the key off the main thread (a Keychain read can block on an access prompt).
    func refresh(then completion: (() -> Void)? = nil) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            let masked = await Task.detached(priority: .userInitiated) {
                KeychainStore.key(for: .gif).map(JevKeyModel.mask)
            }.value
            guard let self, !Task.isCancelled else { return }
            maskedKey = masked
            isLoaded = true
            completion?()
        }
    }

    func save() {
        guard canSave else { return }
        if KeychainStore.setKey(draft, for: .gif) {
            draft = ""
            saveError = nil
            refresh { [weak self] in self?.test() }
        } else {
            saveError = "Couldn’t save the key to the Keychain."
        }
    }

    func remove() {
        testTask?.cancel()
        saveError = KeychainStore.setKey(nil, for: .gif) ? nil : "Couldn’t remove the key from the Keychain."
        testState = .idle
        refresh()
    }

    /// One trending request with the saved key.
    func test() {
        testTask?.cancel()
        testState = .testing
        testTask = Task { [weak self] in
            let key = await Task.detached(priority: .userInitiated) { KeychainStore.key(for: .gif) }.value
            guard let key else {
                self?.testState = .failure("Add an API key first.")
                return
            }
            let result: JevKeyModel.TestState
            do {
                let latency = try await GIPHYClient(apiKey: key, rating: GIFRating.current()).ping()
                result = .success(milliseconds: JevKeyModel.milliseconds(latency))
            } catch is CancellationError {
                return
            } catch {
                result = .failure(Self.describe(error))
            }
            guard !Task.isCancelled else { return }
            self?.testState = result
        }
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case GIFError.missingKey: "No API key."
        case GIFError.unauthorized: "GIPHY rejected this key. Check it on the developer dashboard."
        case GIFError.rateLimited: "Rate limited: beta keys allow 100 requests an hour."
        case GIFError.http(let code): "GIPHY error (HTTP \(code))."
        case GIFError.decoding: "Unexpected response from GIPHY."
        case let urlError as URLError where urlError.code == .timedOut: "Timed out."
        case let urlError as URLError where urlError.code == .notConnectedToInternet: "You’re offline."
        default: "Couldn’t reach GIPHY."
        }
    }
}
