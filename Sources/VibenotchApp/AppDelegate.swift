import AppKit
import VibenotchCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var notchController: NotchWindowController?
    private let adapter = ClaudeCodeAdapter()
    let hub = AgentHub()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        hub.start()
        installAutoDecideForTesting()
        wireAlerts()
        if ProcessInfo.processInfo.environment["VIBENOTCH_HEADLESS"] == nil {
            notchController = NotchWindowController(hub: hub)
        }
        setUpStatusItem()
        healStaleHookPathIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hub.stop()
    }

    // MARK: - Status menu

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "waveform.circle",
            accessibilityDescription: "vibenotch"
        )
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: "vibenotch \(Vibenotch.version)", action: nil, keyEquivalent: "")
        menu.addItem(.separator())

        if adapter.isInstalled {
            menu.addItem(withTitle: "Claude Code: integração instalada ✓", action: nil, keyEquivalent: "")
            let remove = NSMenuItem(
                title: "Remover integração do Claude Code",
                action: #selector(uninstallIntegration),
                keyEquivalent: ""
            )
            remove.target = self
            menu.addItem(remove)
        } else {
            let install = NSMenuItem(
                title: "Instalar integração com Claude Code…",
                action: #selector(installIntegration),
                keyEquivalent: ""
            )
            install.target = self
            menu.addItem(install)
        }
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit vibenotch",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
    }

    @objc private func installIntegration() {
        let alert = NSAlert()
        alert.messageText = "Instalar integração com o Claude Code?"
        alert.informativeText = """
        O vibenotch vai adicionar hooks ao ~/.claude/settings.json \
        (um backup .vibenotch-bak é criado). Sessões novas do Claude Code \
        passam a aparecer no notch, com aprovação de permissões. \
        Se o vibenotch não estiver rodando, nada muda no seu fluxo.
        """
        alert.addButton(withTitle: "Instalar")
        alert.addButton(withTitle: "Cancelar")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try adapter.install()
        } catch {
            presentError(error)
        }
    }

    @objc private func uninstallIntegration() {
        do {
            try adapter.uninstall()
        } catch {
            presentError(error)
        }
    }

    private func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "vibenotch"
        alert.informativeText = error.localizedDescription
        NSApp.activate()
        alert.runModal()
    }

    /// If the app bundle moved since install, re-point the hooks silently.
    private func healStaleHookPathIfNeeded() {
        guard adapter.needsReinstall else { return }
        try? adapter.install()
    }

    // MARK: - Alerts

    private func wireAlerts() {
        let previousPermission = hub.onPermissionRequest
        hub.onPermissionRequest = { [weak self] session in
            previousPermission?(session)
            NSSound(named: "Glass")?.play()
            self?.notchController?.revealPending()
        }
        hub.onSessionIdle = { _ in
            NSSound(named: "Pop")?.play()
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
