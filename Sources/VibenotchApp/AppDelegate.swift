import AppKit
import Combine
import VibenotchCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var iconObservation: AnyCancellable?
    private var notchController: NotchWindowController?
    private let integrations: [AgentIntegration] = [.claudeCode, .codex]
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

        // Icon mirrors the fleet: normal → idle, filled+orange → needs you.
        iconObservation = hub.$store
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshStatusIcon() }
    }

    private func refreshStatusIcon() {
        let needsAttention = hub.sessions.contains {
            $0.status == .waitingPermission || $0.status == .waitingInput
        }
        let name = needsAttention ? "waveform.circle.fill" : "waveform.circle"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "vibenotch")
        if needsAttention {
            statusItem?.button?.contentTintColor = .systemOrange
        } else {
            statusItem?.button?.contentTintColor = nil
        }
        statusItem?.button?.image = image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: "Rocky — vibenotch \(Vibenotch.version)", action: nil, keyEquivalent: "")
        menu.addItem(.separator())

        for (index, integration) in integrations.enumerated() where integration.isAgentPresent {
            let item: NSMenuItem
            if integration.isInstalled {
                item = NSMenuItem(
                    title: "Remover integração do \(integration.displayName) ✓",
                    action: #selector(toggleIntegration(_:)),
                    keyEquivalent: ""
                )
            } else {
                item = NSMenuItem(
                    title: "Instalar integração com \(integration.displayName)…",
                    action: #selector(toggleIntegration(_:)),
                    keyEquivalent: ""
                )
            }
            item.tag = index
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit vibenotch",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
    }

    @objc private func toggleIntegration(_ sender: NSMenuItem) {
        guard integrations.indices.contains(sender.tag) else { return }
        let integration = integrations[sender.tag]
        do {
            if integration.isInstalled {
                try integration.uninstall()
            } else {
                let alert = NSAlert()
                alert.messageText = "Instalar integração com o \(integration.displayName)?"
                alert.informativeText = """
                O vibenotch vai adicionar hooks a \(integration.configURL.path) \
                (um backup .vibenotch-bak é criado). Sessões novas passam a \
                aparecer no notch, com aprovação de permissões. Se o vibenotch \
                não estiver rodando, nada muda no seu fluxo.
                """
                alert.addButton(withTitle: "Instalar")
                alert.addButton(withTitle: "Cancelar")
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
        alert.messageText = "vibenotch"
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
