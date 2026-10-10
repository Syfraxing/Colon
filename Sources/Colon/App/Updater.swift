import AppKit
import Combine
import Sparkle

/// In-app updates via Sparkle 2. The appcast (`SUFeedURL`, HTTPS) must itself carry a valid
/// EdDSA signature (`SURequireSignedFeed`), and every archive is checked against the EdDSA
/// public key in `SUPublicEDKey` before it is even extracted (`SUVerifyUpdateBeforeExtraction`).
/// Sparkle then requires the extracted app's code signature to be valid. (Release builds keep
/// one stable signing certificate so macOS privacy grants survive updates.)
///
/// Updates stay off (UI disabled, nothing started) for builds that cannot be updated safely:
/// `swift run` binaries outside an .app bundle, apps launched from `.build`, and bundles whose
/// Info.plist still carries the placeholder public key (local builds without `SPARKLE_PUBLIC_KEY`).
@MainActor
final class Updater: NSObject, ObservableObject {
    /// The value committed in Resources/Info.plist; build-app.sh swaps in the real key.
    static let publicKeyPlaceholder = "SPARKLE_PUBLIC_KEY_PLACEHOLDER"

    /// Why updates are off, or nil when they are available.
    let unavailableReason: String?
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var lastUpdateCheckDate: Date?
    /// Version of an update found by a background check that the user hasn't looked at yet
    /// (Sparkle shows those alerts behind other apps; the menu offers a way back to it).
    @Published private(set) var pendingUpdateVersion: String?

    private var controller: SPUStandardUpdaterController?
    private var cancellables = Set<AnyCancellable>()

    var isAvailable: Bool { controller != nil }

    override init() {
        unavailableReason = Self.unavailableReason(for: .main)
        super.init()
    }

    /// Starts Sparkle. Its launch-time work is cheap; the scheduled check and all network
    /// traffic run off the main thread.
    func start() {
        guard unavailableReason == nil, controller == nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        self.controller = controller
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] canCheck in self?.canCheckForUpdates = canCheck }
            .store(in: &cancellables)
        controller.startUpdater()
        lastUpdateCheckDate = updater.lastUpdateCheckDate
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set {
            guard let updater = controller?.updater, updater.automaticallyChecksForUpdates != newValue else { return }
            objectWillChange.send()
            updater.automaticallyChecksForUpdates = newValue
        }
    }

    /// User-initiated check: Sparkle shows progress and the result, and brings its window to the
    /// front even though Colon is a menu bar app. While a background check's alert is waiting,
    /// this reopens that alert instead.
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    private func refreshLastCheck() {
        lastUpdateCheckDate = controller?.updater.lastUpdateCheckDate
    }

    private static func unavailableReason(for bundle: Bundle) -> String? {
        let bundleURL = bundle.bundleURL
        guard bundleURL.pathExtension == "app" else { return "Updates are available in the app bundle only." }
        guard !bundleURL.path.contains("/.build/") else { return "Development builds don't update." }
        guard let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              key != publicKeyPlaceholder,
              Data(base64Encoded: key)?.count == 32 else {
            return "This build has no update signing key."
        }
        guard let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              URL(string: feed)?.scheme == "https" else {
            return "This build has no update feed."
        }
        return nil
    }
}

// Sparkle calls its delegates on the main thread.

extension Updater: SPUUpdaterDelegate {
    nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        MainActor.assumeIsolated { refreshLastCheck() }
    }
}

extension Updater: SPUStandardUserDriverDelegate {
    /// Colon is a menu bar app. With gentle reminders Sparkle shows background-check alerts
    /// without stealing focus; `pendingUpdateVersion` surfaces them in the menu.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        let version = update.displayVersionString
        let userInitiated = state.userInitiated
        MainActor.assumeIsolated {
            pendingUpdateVersion = userInitiated ? nil : version
        }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { pendingUpdateVersion = nil }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated {
            pendingUpdateVersion = nil
            refreshLastCheck()
        }
    }
}
