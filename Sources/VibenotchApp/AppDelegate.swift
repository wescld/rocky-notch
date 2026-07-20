import AppKit
import Combine
import SwiftUI
import VibenotchCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var iconObservation: AnyCancellable?
    private var notchController: NotchWindowController?
    private let settings = SettingsWindowController()
    private var defaultsObserver: AnyCancellable?
    private let integrations: [AgentIntegration] = [.claudeCode, .codex]
    let hub = AgentHub()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        registerPixelFont()
        hub.start()
        installAutoDecideForTesting()
        wireAlerts()
        setUpStatusItem()
        applyDisplayMode()
        defaultsObserver = NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyDisplayMode() }
        healStaleHookPathIfNeeded()
    }

    private func applyDisplayMode() {
        guard ProcessInfo.processInfo.environment["VIBENOTCH_HEADLESS"] == nil else { return }
        switch Preferences.displayMode {
        case .notch:
            if notchController == nil {
                notchController = NotchWindowController(hub: hub)
            }
            notchController?.setVisible(true)
        case .menuBar:
            notchController?.setVisible(false)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hub.stop()
    }

    private func registerPixelFont() {
        guard let url = Bundle.main.url(
            forResource: "PressStart2P-Regular", withExtension: "ttf", subdirectory: "Fonts"
        ) else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }

    // MARK: - Status menu

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.menuBarIcon()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item

        // Icon mirrors the fleet: normal → idle, filled+orange → needs you.
        iconObservation = hub.$store
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshStatusIcon() }
    }

    private func refreshStatusIcon() {
        let needsAttention = hub.sessions.contains {
            $0.status == .waitingPermission || $0.status == .waitingInput
        }
        statusItem?.button?.image = Self.menuBarIcon()
        // Template icon: the system tints it; amber = "Rocky needs you".
        statusItem?.button?.contentTintColor = needsAttention ? .systemOrange : nil
    }

    /// Rocky silhouette as a template menu bar icon — monochrome like every
    /// other status item, tinted amber while something waits for the user.
    private static func menuBarIcon() -> NSImage? {
        // The @2x bitmap (36px) shown at 18pt maps 1:1 to device pixels on
        // retina — crisp pixel art.
        guard let url = Bundle.main.url(
            forResource: "menubar-mono@2x", withExtension: "png", subdirectory: "Art"
        ), let image = NSImage(contentsOf: url) else {
            return NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "Rocky")
        }
        image.size = NSSize(width: 16, height: 16)
        image.isTemplate = true
        return image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: "Rocky \(Vibenotch.version)", action: nil, keyEquivalent: "")
        menu.addItem(.separator())

        // Menu-bar mode: the session console lives inside the menu itself.
        if Preferences.displayMode == .menuBar {
            let listItem = NSMenuItem()
            let list = SessionListView(hub: hub)
                .frame(width: 400)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.black)
                )
                .padding(.horizontal, 6)
                .colorScheme(.dark)
            listItem.view = NSHostingView(rootView: list)
            menu.addItem(listItem)
            menu.addItem(.separator())
        }

        for (index, integration) in integrations.enumerated() where integration.isAgentPresent {
            let item: NSMenuItem
            if integration.isInstalled {
                item = NSMenuItem(
                    title: "Remove \(integration.displayName) integration ✓",
                    action: #selector(toggleIntegration(_:)),
                    keyEquivalent: ""
                )
            } else {
                item = NSMenuItem(
                    title: "Install \(integration.displayName) integration…",
                    action: #selector(toggleIntegration(_:)),
                    keyEquivalent: ""
                )
            }
            item.tag = index
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(
            withTitle: "Quit Rocky",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
    }

    @objc private func openSettings() {
        settings.show(hub: hub, integrations: integrations)
    }

    @objc private func toggleIntegration(_ sender: NSMenuItem) {
        guard integrations.indices.contains(sender.tag) else { return }
        let integration = integrations[sender.tag]
        do {
            if integration.isInstalled {
                try integration.uninstall()
            } else {
                let alert = NSAlert()
                alert.messageText = "Install the \(integration.displayName) integration?"
                alert.informativeText = """
                Rocky will add hooks to \(integration.configURL.path) \
                (a .vibenotch-bak backup is created). New sessions will show \
                up with permission approval. If Rocky isn't running, nothing \
                changes in your workflow.
                """
                alert.addButton(withTitle: "Install")
                alert.addButton(withTitle: "Cancel")
                NSApp.activate()
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                try integration.install()
            }
        } catch {
            presentError(error)
        }
    }

    private func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Rocky"
        alert.informativeText = error.localizedDescription
        NSApp.activate()
        alert.runModal()
    }

    /// If the app bundle moved since install, re-point the hooks silently.
    private func healStaleHookPathIfNeeded() {
        for integration in integrations where integration.needsReinstall {
            try? integration.install()
        }
    }

    // MARK: - Alerts

    private func wireAlerts() {
        let previousPermission = hub.onPermissionRequest
        hub.onPermissionRequest = { [weak self] session in
            previousPermission?(session)
            RockyVoice.shared.question()
            self?.notchController?.revealPending()
        }
        hub.onSessionIdle = { _ in
            RockyVoice.shared.done()
        }
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
