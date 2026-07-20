import AppKit
import VibenotchCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    let hub = AgentHub()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        hub.start()
        installAutoDecideForTesting()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "waveform.circle",
            accessibilityDescription: "vibenotch"
        )

        let menu = NSMenu()
        menu.addItem(
            withTitle: "vibenotch \(Vibenotch.version)",
            action: nil,
            keyEquivalent: ""
        )
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit vibenotch",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        item.menu = menu
        statusItem = item
    }

    func applicationWillTerminate(_ notification: Notification) {
        hub.stop()
    }

    /// Integration-test hook: VIBENOTCH_AUTODECIDE=allow|deny|ask makes the
    /// hub answer every permission request without UI. Never set in normal use.
    private func installAutoDecideForTesting() {
        guard
            let raw = ProcessInfo.processInfo.environment["VIBENOTCH_AUTODECIDE"],
            let decision = Decision(rawValue: raw)
        else { return }
        hub.onPermissionRequest = { [weak self] session in
            guard let requestId = session.pending?.requestId else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self?.hub.decide(requestId: requestId, decision: decision)
            }
        }
    }
}
