import Foundation
import RockyCore

enum IntegrationError: LocalizedError {
    case unparseableSettings(String)

    var errorDescription: String? {
        switch self {
        case .unparseableSettings(let path):
            "\(path) could not be parsed as JSON. "
                + "Nothing was changed. Fix the file and try again."
        }
    }
}

/// One agent CLI whose hooks config we can install into.
/// Safety rules (spec §3.4): backup before writing, atomic write, never
/// overwrite a file that failed to parse, remove only our own entries.
struct AgentIntegration {
    let displayName: String
    let configURL: URL
    /// Directory whose presence means the agent is installed on this machine.
    /// Usually the config's parent; for Grok the config lives under
    /// `~/.grok/hooks/` which may not exist until first install.
    let presenceDirectory: URL
    let events: [(name: String, needsReply: Bool)]
    let commandArguments: String
    /// Extra note shown in the install confirmation dialog.
    let installNote: String
    /// When true, uninstall deletes the config file if it is left completely
    /// empty (Grok's dedicated `rocky.json` holds nothing else). Shared configs
    /// like `~/.claude/settings.json` set this false so uninstall never removes
    /// a file that still carries the user's own keys.
    var removesConfigWhenEmpty: Bool = false

    /// The hook binary lives next to the app executable inside the bundle.
    static var hookBinaryPath: String {
        let executable = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
        return executable.deletingLastPathComponent()
            .appendingPathComponent("rocky-hook").path
    }

    private static var home: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    static var claudeCode: AgentIntegration {
        let config = home.appendingPathComponent(".claude/settings.json")
        return AgentIntegration(
            displayName: "Claude Code",
            configURL: config,
            presenceDirectory: config.deletingLastPathComponent(),
            events: ClaudeSettingsMerger.claudeEvents,
            commandArguments: "",
            installNote: ""
        )
    }

    static var codex: AgentIntegration {
        let config = home.appendingPathComponent(".codex/hooks.json")
        return AgentIntegration(
            displayName: "Codex",
            configURL: config,
            presenceDirectory: config.deletingLastPathComponent(),
            events: ClaudeSettingsMerger.codexEvents,
            commandArguments: "--agent codex",
            installNote: ""
        )
    }

    static var grok: AgentIntegration {
        // Grok discovers `~/.grok/hooks/*.json` and merges them. A dedicated
        // rocky.json keeps uninstall surgical (delete our file / unmerge).
        let config = home.appendingPathComponent(".grok/hooks/rocky.json")
        return AgentIntegration(
            displayName: "Grok",
            configURL: config,
            presenceDirectory: home.appendingPathComponent(".grok"),
            events: ClaudeSettingsMerger.grokEvents,
            commandArguments: "--agent grok",
            installNote: """

            Grok uses PreToolUse (not PermissionRequest) for blocking hooks. \
            Rocky auto-passes read-only tools, and auto-passes everything when \
            Grok is in always-approve / YOLO (config or session mode). In \
            normal prompt mode, Rocky asks about shell, edits, and other \
            writes — Deny blocks; Allow continues.
            """,
            removesConfigWhenEmpty: true
        )
    }

    /// Only offer integrations for CLIs that exist on this machine.
    var isAgentPresent: Bool {
        FileManager.default.fileExists(atPath: presenceDirectory.path)
    }

    var isInstalled: Bool {
        ClaudeSettingsMerger.isInstalled(settings: try? Data(contentsOf: configURL))
    }

    /// True when installed but stale: moved bundle or missing newly added
    /// hook events. Re-merging is idempotent and self-heals both.
    var needsReinstall: Bool {
        guard isInstalled else { return false }
        let data = try? Data(contentsOf: configURL)
        return !ClaudeSettingsMerger.isCurrent(
            settings: data,
            hookBinaryPath: Self.hookBinaryPath,
            events: events
        )
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
        // Grok's dedicated rocky.json holds nothing but our hooks, so drop the
        // file once it is completely empty. Only ever delete when *nothing*
        // remains — a shared config keeping foreign keys must survive uninstall.
        if removesConfigWhenEmpty,
           let root = try? JSONSerialization.jsonObject(with: cleaned) as? [String: Any],
           root.isEmpty {
            try? FileManager.default.removeItem(at: configURL)
            return
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
                to: configURL.appendingPathExtension("rocky-bak"),
                options: .atomic
            )
        }
        try data.write(to: configURL, options: .atomic)
    }
}
