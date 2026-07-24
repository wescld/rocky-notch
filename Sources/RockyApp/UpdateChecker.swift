import Foundation
import Sparkle

/// Thin wrapper around Sparkle 2's `SPUStandardUpdaterController`.
///
/// - Automatic background checks are disabled in DEBUG builds.
/// - If `SUFeedURL` is missing/empty in Info.plist, the updater is not
///   started at all (local/dev builds still work without an appcast).
@MainActor
final class UpdateChecker {
    static let shared = UpdateChecker()

    private var updaterController: SPUStandardUpdaterController?
    /// True when Sparkle is wired and the user can invoke "Check for Updates…".
    private(set) var isAvailable = false
    private var startedOnDemand = false

    private init() {}

    /// Call once from `applicationDidFinishLaunching`.
    func start() {
        let feedURL = (Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !feedURL.isEmpty else {
            isAvailable = false
            return
        }

        #if DEBUG
        // Construct the controller but do not start scheduled checks.
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
        startedOnDemand = true
        #endif
        isAvailable = updaterController != nil
    }

    /// User-initiated update check (status menu / Settings).
    func checkForUpdates(_ sender: Any? = nil) {
        guard let updaterController else { return }
        #if DEBUG
        if !startedOnDemand {
            try? updaterController.updater.start()
            startedOnDemand = true
        }
        #endif
        updaterController.checkForUpdates(sender)
    }
}
