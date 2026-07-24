import Foundation
import Sparkle

/// Thin wrapper around Sparkle 2's `SPUStandardUpdaterController`.
///
/// Local / ad-hoc builds ship with an empty `SUPublicEDKey`. Sparkle must
/// **not** start in that case — otherwise it alerts "Unable to Check For
/// Updates" on every launch. Real release builds inject a public key via CI
/// (`SPARKLE_PUBLIC_ED_KEY`) and get background checks.
@MainActor
final class UpdateChecker {
    static let shared = UpdateChecker()

    private var updaterController: SPUStandardUpdaterController?
    /// True when Sparkle is fully configured (feed URL + Ed25519 public key).
    private(set) var isAvailable = false

    private init() {}

    /// Feed + public key both required before Sparkle is allowed to start.
    private static var isFullyConfigured: Bool {
        let feed = (Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let publicKey = (Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !feed.isEmpty && !publicKey.isEmpty
    }

    /// Call once from `applicationDidFinishLaunching`.
    func start() {
        guard Self.isFullyConfigured else {
            // Dev / ad-hoc: stay silent. No controller, no Sparkle dialogs.
            isAvailable = false
            updaterController = nil
            return
        }

        #if DEBUG
        // Construct but do not start scheduled checks in debug.
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        #else
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        #endif
        isAvailable = updaterController != nil
    }

    /// User-initiated update check (status menu / Settings).
    /// No-op when Sparkle is not configured (local builds).
    func checkForUpdates(_ sender: Any? = nil) {
        guard isAvailable, let updaterController else { return }
        #if DEBUG
        // Lazy-start on first manual check in DEBUG.
        if !updaterController.updater.sessionInProgress {
            try? updaterController.updater.start()
        }
        #endif
        updaterController.checkForUpdates(sender)
    }
}
