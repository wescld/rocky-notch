import Foundation
import VibenotchCore

enum IntegrationError: LocalizedError {
    case unparseableSettings(String)

    var errorDescription: String? {
        switch self {
        case .unparseableSettings(let path):
            "O arquivo \(path) não pôde ser lido como JSON. "
                + "Nada foi alterado — corrija o arquivo e tente de novo."
        }
    }
}

/// One agent CLI whose hooks config we can install into.
/// Safety rules (spec §3.4): backup before writing, atomic write, never
/// overwrite a file that failed to parse, remove only our own entries.
struct AgentIntegration {
    let displayName: String
    let configURL: URL
    let events: [(name: String, needsReply: Bool)]
    let commandArguments: String

    /// The hook binary lives next to the app executable inside the bundle.
    static var hookBinaryPath: String {
        let executable = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
        return executable.deletingLastPathComponent()
            .appendingPathComponent("vibenotch-hook").path
    }

    static var claudeCode: AgentIntegration {
        AgentIntegration(
            displayName: "Claude Code",
            configURL: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/settings.json"),
            events: ClaudeSettingsMerger.claudeEvents,
            commandArguments: ""
        )
    }

    static var codex: AgentIntegration {
        AgentIntegration(
            displayName: "Codex",
            configURL: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex/hooks.json"),
            events: ClaudeSettingsMerger.codexEvents,
            commandArguments: "--agent codex"
        )
    }

    /// Only offer integrations for CLIs that exist on this machine.
    var isAgentPresent: Bool {
        FileManager.default.fileExists(
            atPath: configURL.deletingLastPathComponent().path
        )
    }

    var isInstalled: Bool {
        ClaudeSettingsMerger.isInstalled(settings: try? Data(contentsOf: configURL))
    }

    /// True when installed but pointing at a stale binary path (app moved).
    var needsReinstall: Bool {
        guard isInstalled,
              let data = try? Data(contentsOf: configURL),
              let text = String(data: data, encoding: .utf8)
        else { return false }
        return !text.contains(Self.hookBinaryPath)
    }

    func install() throws {
        let existing = try? Data(contentsOf: configURL)
        let merged: Data
        do {
            merged = try ClaudeSettingsMerger.merge(
                settings: existing,
                hookBinaryPath: Self.hookBinaryPath,
                events: events,
                commandArguments: commandArguments
            )
        } catch {
            throw IntegrationError.unparseableSettings(configURL.path)
        }
        try write(merged, backupOf: existing)
    }

    func uninstall() throws {
        guard let existing = try? Data(contentsOf: configURL) else { return }
        let cleaned: Data
        do {
            cleaned = try ClaudeSettingsMerger.unmerge(settings: existing)
        } catch {
            throw IntegrationError.unparseableSettings(configURL.path)
        }
        try write(cleaned, backupOf: existing)
    }

    private func write(_ data: Data, backupOf existing: Data?) throws {
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if let existing {
            try existing.write(
                to: configURL.appendingPathExtension("vibenotch-bak"),
                options: .atomic
            )
        }
        try data.write(to: configURL, options: .atomic)
    }
}
