import AppKit
import SwiftUI
import RockyCore

/// Rocky's settings window: display mode, sounds, integration status and
/// app details. English-only, like the rest of the product.
struct SettingsView: View {
    @ObservedObject var hub: AgentHub
    let integrations: [AgentIntegration]

    @State private var displayMode = Preferences.displayMode
    @State private var soundsEnabled = Preferences.soundsEnabled
    @State private var showCompletionCards = Preferences.showCompletionCards
    @State private var showAccountUsage = Preferences.showAccountUsage
    @State private var kimiGateEnabled = Preferences.kimiGateEnabled
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchError: String?
    @State private var integrationError: String?
    @State private var usageError: String?
    @State private var refresh = 0

    private var kimiInstalled: Bool {
        integrations.contains { $0.pluginBackend != nil && $0.isInstalled }
    }

    private var healthReports: [HookHealthReport] {
        _ = refresh
        return integrations.compactMap { $0.healthReport() }
    }

    private var statusLineStatus: ClaudeStatusLineInstaller.Status {
        _ = refresh
        return ClaudeStatusLineInstaller.status()
    }

    var body: some View {
        Form {
            Section("General") {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        do {
                            launchError = nil
                            try LaunchAtLogin.setEnabled(newValue)
                            launchAtLogin = LaunchAtLogin.isEnabled
                        } catch {
                            launchError = error.localizedDescription
                            launchAtLogin = LaunchAtLogin.isEnabled
                        }
                    }
                if let launchError {
                    Text(launchError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if LaunchAtLogin.statusDescription == "Needs approval in System Settings" {
                    Text("Allow Rocky in System Settings → General → Login Items.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

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

                Toggle("Show completion card when a turn finishes", isOn: $showCompletionCards)
                    .onChange(of: showCompletionCards) { _, newValue in
                        Preferences.showCompletionCards = newValue
                    }
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

            Section("Diagnostics") {
                let reports = healthReports
                if reports.isEmpty {
                    Text("No agent configs found on this Mac yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(reports.enumerated()), id: \.offset) { _, report in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(report.displayName)
                                Spacer()
                                if report.isHealthy {
                                    Text("OK")
                                        .foregroundStyle(.green)
                                } else {
                                    Text("Needs attention")
                                        .foregroundStyle(.orange)
                                }
                            }
                            ForEach(Array(report.issues.enumerated()), id: \.offset) { _, issue in
                                Text(issue.description)
                                    .font(.caption)
                                    .foregroundStyle(
                                        issue.severity == .error ? Color.red : Color.secondary
                                    )
                            }
                            if report.errors.contains(where: \.isAutoRepairable) {
                                Button("Repair \(report.displayName)") {
                                    if let integration = integrations.first(where: {
                                        $0.displayName == report.displayName
                                    }) {
                                        perform { try integration.install() }
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            Section("Account usage") {
                Toggle("Show account rate limits in the notch", isOn: $showAccountUsage)
                    .onChange(of: showAccountUsage) { _, newValue in
                        Preferences.showAccountUsage = newValue
                        hub.refreshAccountUsage()
                    }
                Text("Claude and Codex chips share this toggle.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Claude usage") {
                if statusLineStatus.isInstalled {
                    HStack {
                        Text(statusLineStatus.isWrapper
                            ? "Status line bridge installed (wrapping yours)"
                            : "Status line bridge installed")
                            .foregroundStyle(.green)
                        Spacer()
                        Button("Remove") {
                            performUsage { try ClaudeStatusLineInstaller.uninstall() }
                            hub.refreshAccountUsage()
                        }
                    }
                } else {
                    Button(statusLineStatus.hasConflict
                           ? "Install bridge (wrap existing status line)"
                           : "Install Claude status line bridge") {
                        performUsage { try ClaudeStatusLineInstaller.install() }
                        hub.refreshAccountUsage()
                    }
                    Text(
                        "Opt-in. Writes rate limits to \(ClaudeUsageLoader.defaultCacheURL.path) "
                            + "via Claude's statusLine. Requires jq. "
                            + "Start a Claude turn after install to seed the cache."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if let usage = hub.claudeUsage, let five = usage.fiveHour {
                    LabeledContent(
                        "5-hour window",
                        value: "\(five.roundedUsedPercentage)% used"
                    )
                    if let seven = usage.sevenDay {
                        LabeledContent(
                            "7-day window",
                            value: "\(seven.roundedUsedPercentage)% used"
                        )
                    }
                }
                if let usageError {
                    Text(usageError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Codex usage") {
                Text(
                    "Reads the latest token_count.rate_limits from local "
                        + "~/.codex/sessions/**/rollout-*.jsonl (no network, no install). "
                        + "Plus plans often expose a 7-day window only (chip: Cd N% 7d)."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                if let usage = hub.codexUsage, !usage.isEmpty {
                    if let plan = usage.planType {
                        LabeledContent("Plan", value: plan)
                    }
                    ForEach(usage.windows, id: \.key) { window in
                        LabeledContent(
                            "\(window.label) window",
                            value: "\(window.roundedUsedPercentage)% used"
                        )
                    }
                    if let source = usage.sourcePath {
                        LabeledContent("Source", value: (source as NSString).lastPathComponent)
                            .font(.caption)
                    }
                    Button("Refresh") {
                        hub.refreshAccountUsage()
                    }
                } else if showAccountUsage {
                    Text(
                        "No rate-limit lines found yet. Run any Codex turn (even a short one), "
                            + "then Refresh. The chip also appears in the expanded notch header."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Button("Refresh") {
                        hub.refreshAccountUsage()
                    }
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
        .frame(width: 480, height: 620)
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

    private func performUsage(_ action: () throws -> Void) {
        do {
            usageError = nil
            try action()
        } catch {
            usageError = error.localizedDescription
        }
        refresh += 1
    }

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

extension AgentIntegration {
    /// Build a health report for Settings diagnostics (nil if agent absent).
    func healthReport() -> HookHealthReport? {
        guard isAgentPresent else { return nil }
        if let pluginBackend {
            // Kimi plugin path — surface install state simply.
            var issues: [HookHealthReport.Issue] = []
            let path = AgentIntegration.hookBinaryPath
            if !FileManager.default.fileExists(atPath: path) {
                issues.append(.binaryNotFound(path: path))
            } else if !FileManager.default.isExecutableFile(atPath: path) {
                issues.append(.binaryNotExecutable(path: path))
            }
            if !pluginBackend.isInstalled {
                issues.append(.notInstalled)
            } else if !pluginBackend.isCurrent {
                issues.append(
                    .staleCommandPath(recorded: "(plugin)", expected: path)
                )
            }
            return HookHealthReport(
                agent: "kimi-code",
                displayName: displayName,
                issues: issues,
                expectedBinaryPath: path,
                configPath: nil
            )
        }
        let data = try? Data(contentsOf: configURL)
        return HookHealthCheck.inspectNested(
            agent: displayName.lowercased(),
            displayName: displayName,
            expectedBinaryPath: AgentIntegration.hookBinaryPath,
            configPath: configURL.path,
            configData: data
        )
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
