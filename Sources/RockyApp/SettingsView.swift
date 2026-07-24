import SwiftUI
import RockyCore

/// Rocky's settings window: display mode, sounds, integration status and
/// app details. English-only, like the rest of the product.
struct SettingsView: View {
    @ObservedObject var hub: AgentHub
    let integrations: [AgentIntegration]

    @State private var displayMode = Preferences.displayMode
    @State private var soundsEnabled = Preferences.soundsEnabled
    @State private var kimiGateEnabled = Preferences.kimiGateEnabled
    @State private var integrationError: String?
    @State private var refresh = 0

    private var kimiInstalled: Bool {
        integrations.contains { $0.pluginBackend != nil && $0.isInstalled }
    }

    var body: some View {
        Form {
            Section("Display") {
                Picker("Show Rocky in", selection: $displayMode) {
                    Text("Notch").tag(Preferences.DisplayMode.notch)
                    Text("Menu bar only").tag(Preferences.DisplayMode.menuBar)
                }
                .pickerStyle(.radioGroup)
                .onChange(of: displayMode) { _, newValue in
                    Preferences.displayMode = newValue
                }
                Text(
                    displayMode == .notch
                        ? "Sessions live around the notch; hover to expand."
                        : "The notch panel is hidden; sessions live in the menu bar icon."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Sounds") {
                Toggle("Rocky speaks (permission and completion chimes)", isOn: $soundsEnabled)
                    .onChange(of: soundsEnabled) { _, newValue in
                        Preferences.soundsEnabled = newValue
                    }
            }

            Section("Integrations") {
                ForEach(Array(integrations.enumerated()), id: \.offset) { _, integration in
                    if integration.isAgentPresent {
                        HStack {
                            Text(integration.displayName)
                            Spacer()
                            if integration.isInstalled {
                                Text("Installed")
                                    .foregroundStyle(.green)
                                Button("Remove") {
                                    perform { try integration.uninstall() }
                                }
                            } else {
                                Button("Install") {
                                    perform { try integration.install() }
                                    // Plugin-based agents (Kimi) don't hot-load:
                                    // a running session must reload. Say so, once,
                                    // right after a successful install.
                                    if integration.pluginBackend != nil,
                                       integrationError == nil {
                                        Self.showPluginReloadReminder(integration.displayName)
                                    }
                                }
                            }
                        }
                    }
                }
                if kimiInstalled {
                    Toggle("Gate Kimi tool calls (auto / yolo mode)", isOn: $kimiGateEnabled)
                        .onChange(of: kimiGateEnabled) { _, newValue in
                            Preferences.kimiGateEnabled = newValue
                        }
                    Text(
                        "Kimi is deny-only: Rocky can block a tool but not answer "
                            + "Kimi's own prompt. Leave off for normal (manual) Kimi — "
                            + "Rocky just observes. Turn on when you run Kimi in "
                            + "auto / yolo and want Rocky as the approval gate."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if let integrationError {
                    Text(integrationError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Updates") {
                if UpdateChecker.shared.isAvailable {
                    Button("Check for Updates…") {
                        UpdateChecker.shared.checkForUpdates()
                    }
                    Text("Rocky uses Sparkle to download signed updates from GitHub Releases.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("In-app updates are not configured in this build.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Details") {
                LabeledContent("Version", value: Rocky.version)
                LabeledContent("Active sessions", value: "\(hub.sessions.count)")
                LabeledContent(
                    "Tokens (tracked sessions)",
                    value: SessionMeta.tokens(hub.sessions.reduce(0) { $0 + $1.tokens }) ?? "0"
                )
                LabeledContent("Hook binary", value: AgentIntegration.hookBinaryPath)
                    .truncationMode(.middle)
                    .lineLimit(1)
                LabeledContent("Socket", value: IPC.socketPath())
                    .truncationMode(.middle)
                    .lineLimit(1)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 520)
        .id(refresh)
    }

    private func perform(_ action: () throws -> Void) {
        do {
            integrationError = nil
            try action()
        } catch {
            integrationError = error.localizedDescription
        }
        refresh += 1
    }

    /// One-time nudge after installing a plugin-based integration (Kimi): the
    /// hook won't fire in an already-open session until the plugin is reloaded.
    private static func showPluginReloadReminder(_ displayName: String) {
        let alert = NSAlert()
        alert.messageText = "\(displayName) integration installed"
        alert.informativeText = """
        Start a new \(displayName) session, or run /plugins reload in an open \
        one, for Rocky to take effect.
        """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

/// Owns the (single) settings window.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    func show(hub: AgentHub, integrations: [AgentIntegration]) {
        if window == nil {
            let view = SettingsView(hub: hub, integrations: integrations)
            let hosting = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: hosting)
            window.title = "Rocky Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
