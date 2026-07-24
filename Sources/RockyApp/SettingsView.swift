import AppKit
import SwiftUI
import RockyCore

// MARK: - Tabs

/// Sidebar sections for Rocky Settings (keeps the window scannable as options grow).
private enum SettingsTab: String, CaseIterable, Identifiable, Hashable {
    case general
    case integrations
    case diagnostics
    case usage
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .integrations: "Integrations"
        case .diagnostics: "Diagnostics"
        case .usage: "Usage"
        case .about: "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .integrations: "puzzlepiece.extension"
        case .diagnostics: "stethoscope"
        case .usage: "chart.bar"
        case .about: "info.circle"
        }
    }
}

// MARK: - Root

/// Rocky's settings window: sidebar tabs + grouped forms per area.
/// English-only, like the rest of the product.
struct SettingsView: View {
    @ObservedObject var hub: AgentHub
    let integrations: [AgentIntegration]

    @State private var selectedTab: SettingsTab = .general
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
        NavigationSplitView {
            List(SettingsTab.allCases, selection: $selectedTab) { tab in
                Label(tab.title, systemImage: tab.systemImage)
                    .tag(tab)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 160, ideal: 176, max: 200)
        } detail: {
            detailContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 620, idealWidth: 660, minHeight: 420, idealHeight: 480)
        .id(refresh)
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selectedTab {
        case .general:
            settingsForm { generalSections }
        case .integrations:
            settingsForm { integrationsSection }
        case .diagnostics:
            settingsForm { diagnosticsSection }
        case .usage:
            settingsForm { usageSections }
        case .about:
            settingsForm { aboutSections }
        }
    }

    private func settingsForm<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        Form {
            content()
        }
        .formStyle(.grouped)
        .padding(.top, 4)
    }

    // MARK: - General

    @ViewBuilder
    private var generalSections: some View {
        Section("Startup") {
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
    }

    // MARK: - Integrations

    @ViewBuilder
    private var integrationsSection: some View {
        Section {
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
        } header: {
            Text("Agent hooks")
        } footer: {
            Text("Install merges Rocky into each agent’s official hooks config (fail-open if Rocky is quit).")
                .font(.caption)
        }
    }

    // MARK: - Diagnostics

    @ViewBuilder
    private var diagnosticsSection: some View {
        Section {
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
        } header: {
            Text("Hook health")
        } footer: {
            Text("Stale paths after moving Rocky.app are the usual failure — Repair rewrites the hook binary path.")
                .font(.caption)
        }
    }

    // MARK: - Usage

    @ViewBuilder
    private var usageSections: some View {
        Section("Notch chips") {
            Toggle("Show account rate limits in the notch", isOn: $showAccountUsage)
                .onChange(of: showAccountUsage) { _, newValue in
                    Preferences.showAccountUsage = newValue
                    hub.refreshAccountUsage()
                }
            Text("The Claude and Codex usage chips share this toggle. Expand the notch to see them.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("Claude") {
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
                    value: usageValue(five.roundedUsedPercentage, resetsAt: five.resetsAt)
                )
                if let seven = usage.sevenDay {
                    LabeledContent(
                        "7-day window",
                        value: usageValue(seven.roundedUsedPercentage, resetsAt: seven.resetsAt)
                    )
                }
            }
            if let usageError {
                Text(usageError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }

        Section("Codex") {
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
                        value: usageValue(window.roundedUsedPercentage, resetsAt: window.resetsAt)
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
                        + "then Refresh."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Button("Refresh") {
                    hub.refreshAccountUsage()
                }
            }
        }
    }

    /// "7% used" with a trailing "· resets …" when the window carries a reset time.
    private func usageValue(_ percent: Int, resetsAt: Date?) -> String {
        var text = "\(percent)% used"
        if let resetsAt, let reset = UsageReset.describe(resetsAt, now: Date()) {
            text += " · resets \(reset)"
        }
        return text
    }

    // MARK: - About

    @ViewBuilder
    private var aboutSections: some View {
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

    // MARK: - Actions

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

// MARK: - Health report helper

extension AgentIntegration {
    /// Build a health report for Settings diagnostics (nil if agent absent).
    func healthReport() -> HookHealthReport? {
        guard isAgentPresent else { return nil }
        // Kimi / OpenCode install a plugin (JS or registry), not a JSON hooks
        // file. Reuse the same binary + installed/current checks; never try to
        // JSON-parse the plugin path (that produced a false "not valid JSON").
        if pluginBackend != nil || openCodeBackend != nil {
            return pluginStyleHealthReport()
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

    /// Health for agents that install via a dedicated plugin backend
    /// (`pluginBackend` for Kimi, `openCodeBackend` for OpenCode).
    private func pluginStyleHealthReport() -> HookHealthReport {
        var issues: [HookHealthReport.Issue] = []
        let path = AgentIntegration.hookBinaryPath
        if !FileManager.default.fileExists(atPath: path) {
            issues.append(.binaryNotFound(path: path))
        } else if !FileManager.default.isExecutableFile(atPath: path) {
            issues.append(.binaryNotExecutable(path: path))
        }
        let installed: Bool
        let current: Bool
        if let pluginBackend {
            installed = pluginBackend.isInstalled
            current = pluginBackend.isCurrent
        } else if let openCodeBackend {
            installed = openCodeBackend.isInstalled
            current = openCodeBackend.isCurrent
        } else {
            installed = false
            current = false
        }
        if !installed {
            issues.append(.notInstalled)
        } else if !current {
            issues.append(
                .staleCommandPath(recorded: "(plugin)", expected: path)
            )
        }
        return HookHealthReport(
            agent: displayName.lowercased(),
            displayName: displayName,
            issues: issues,
            expectedBinaryPath: path,
            configPath: openCodeBackend.map { $0.pluginURL.path }
        )
    }
}

// MARK: - Window

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
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 660, height: 480))
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        // Refresh hosted root when reopening so hub/integrations stay current.
        if let hosting = window?.contentViewController as? NSHostingController<SettingsView> {
            hosting.rootView = SettingsView(hub: hub, integrations: integrations)
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
