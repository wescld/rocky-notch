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
    enum ConfigStyle {
        /// Claude / Codex: nested `[{ "hooks": [{ "command" }] }]`.
        case nestedGroups
        /// Cursor: flat `[{ "command" }]` plus top-level `version`.
        case cursorFlat
    }

    let displayName: String
    let configURL: URL
    /// Directory whose presence means the agent is installed on this machine.
    /// Usually the config's parent; Grok/Cursor live under a directory that may
    /// not exist until first install.
    let presenceDirectory: URL
    let events: [(name: String, needsReply: Bool)]
    let commandArguments: String
    let configStyle: ConfigStyle
    /// Extra note shown in the install confirmation dialog.
    let installNote: String
    /// When true, uninstall deletes the config file if it is left completely
    /// empty (Grok's dedicated `rocky.json` holds nothing else). Shared configs
    /// like `~/.claude/settings.json` set this false so uninstall never removes
    /// a file that still carries the user's own keys.
    var removesConfigWhenEmpty: Bool = false
    /// Set for providers that install via a plugin registry instead of merging a
    /// hooks config file (Kimi Code). When present, the lifecycle methods below
    /// delegate to it; `configURL`/`configStyle` are then unused.
    var pluginBackend: KimiPluginBackend? = nil
    /// OpenCode installs a JS bridge plugin instead of merging a hooks config.
    /// When present, lifecycle methods delegate to it; `configURL`/`configStyle`
    /// are only used for path display.
    var openCodeBackend: OpenCodePluginBackend? = nil

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
            // Explicit, so a Claude session that inherited Grok's GROK_* env
            // (grok shelling out to `claude`) is not mistaken for Grok and
            // answered in Grok's reply shape.
            commandArguments: "--agent claude-code",
            configStyle: .nestedGroups,
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
            configStyle: .nestedGroups,
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
            configStyle: .nestedGroups,
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

    static var cursor: AgentIntegration {
        let config = home.appendingPathComponent(".cursor/hooks.json")
        return AgentIntegration(
            displayName: "Cursor",
            configURL: config,
            presenceDirectory: home.appendingPathComponent(".cursor"),
            events: CursorSettingsMerger.cursorEvents,
            commandArguments: "--agent cursor",
            configStyle: .cursorFlat,
            installNote: """

            Cursor's official hooks: beforeSubmitPrompt (session + task), \
            beforeShellExecution / beforeMCPExecution (approval gate), \
            beforeReadFile / afterFileEdit (observe; no edit block API), \
            stop (idle). File edits cannot be gated — Cursor has no beforeWrite. \
            Decisions return {continue, permission, userMessage, agentMessage}.
            """
        )
    }

    static var kimi: AgentIntegration {
        // $KIMI_CODE_HOME if the app inherited it, else ~/.kimi-code.
        let kimiHome = ProcessInfo.processInfo.environment["KIMI_CODE_HOME"]
            .map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".kimi-code")
        let commandArguments = "--agent kimi-code"
        let events = KimiPluginMerger.kimiEvents
        return AgentIntegration(
            // Kimi installs as a plugin; configURL/configStyle are unused (the
            // pluginBackend owns install/uninstall). configURL points at the
            // shared registry only so logs and paths read sensibly.
            displayName: "Kimi",
            configURL: kimiHome.appendingPathComponent("plugins/installed.json"),
            presenceDirectory: kimiHome,
            events: events,
            commandArguments: commandArguments,
            configStyle: .nestedGroups,
            installNote: """

            Kimi Code uses PreToolUse (not PermissionRequest) for blocking \
            hooks, and it is deny-only: Rocky can block a tool call, but \
            "Continue" only lets Kimi proceed — in manual mode Kimi still shows \
            its own prompt. So Rocky observes Kimi by default and acts as the \
            gate when you run Kimi in auto / yolo. Rocky installs a dedicated \
            plugin; run `/plugins reload` in an open Kimi session (or restart \
            Kimi) for it to take effect.
            """,
            pluginBackend: KimiPluginBackend(
                kimiHome: kimiHome,
                commandArguments: commandArguments,
                events: events
            )
        )
    }

    static var openCode: AgentIntegration {
        let configHome = OpenCodePluginBackend.defaultConfigHome()
        let commandArguments = "--agent opencode"
        // Presence: config dir OR the CLI binary install at ~/.opencode.
        let presence = FileManager.default.fileExists(atPath: configHome.path)
            ? configHome
            : home.appendingPathComponent(".opencode")
        return AgentIntegration(
            displayName: "OpenCode",
            configURL: configHome.appendingPathComponent(
                "plugins/\(OpenCodePluginMerger.pluginFileName)"
            ),
            presenceDirectory: presence,
            events: [],
            commandArguments: commandArguments,
            configStyle: .nestedGroups,
            installNote: """

            OpenCode uses JavaScript plugins (not shell hooks). Rocky installs \
            a bridge plugin at ~/.config/opencode/plugins/rocky-notch.js that \
            forwards permission.ask and session events to rocky-hook. Restart \
            OpenCode after installing. Approval cards only appear for tools \
            whose permission is "ask" in opencode.json (OpenCode defaults to \
            allow-all).
            """,
            openCodeBackend: OpenCodePluginBackend(
                configHome: configHome,
                commandArguments: commandArguments
            )
        )
    }

    /// Only offer integrations for CLIs that exist on this machine.
    var isAgentPresent: Bool {
        if openCodeBackend != nil {
            // OpenCode: config dir, or binary under ~/.opencode/bin, or on PATH.
            if FileManager.default.fileExists(atPath: presenceDirectory.path) {
                return true
            }
            let bin = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".opencode/bin/opencode")
            if FileManager.default.fileExists(atPath: bin.path) { return true }
            return false
        }
        return FileManager.default.fileExists(atPath: presenceDirectory.path)
    }

    /// One-line "what to expect" sentence for the install confirmation. The
    /// config-file agents gate by default, so their sessions prompt for
    /// approval; Kimi's plugin observes by default (its deny-only gate is
    /// opt-in), so promising a prompt would be wrong. OpenCode is similar:
    /// sessions always show up; permission cards need permission: "ask".
    var installExpectation: String {
        pluginBackend != nil || openCodeBackend != nil
            ? "New sessions will show up in Rocky."
            : "New sessions will show up with permission approval."
    }

    var isInstalled: Bool {
        if let pluginBackend { return pluginBackend.isInstalled }
        if let openCodeBackend { return openCodeBackend.isInstalled }
        let data = try? Data(contentsOf: configURL)
        switch configStyle {
        case .nestedGroups:
            return ClaudeSettingsMerger.isInstalled(settings: data)
        case .cursorFlat:
            return CursorSettingsMerger.isInstalled(settings: data)
        }
    }

    /// True when installed but stale: moved bundle or missing newly added
    /// hook events. Re-merging is idempotent and self-heals both.
    var needsReinstall: Bool {
        if let pluginBackend {
            return pluginBackend.isInstalled && !pluginBackend.isCurrent
        }
        if let openCodeBackend {
            return openCodeBackend.isInstalled && !openCodeBackend.isCurrent
        }
        guard isInstalled else { return false }
        let data = try? Data(contentsOf: configURL)
        switch configStyle {
        case .nestedGroups:
            return !ClaudeSettingsMerger.isCurrent(
                settings: data,
                hookBinaryPath: Self.hookBinaryPath,
                events: events,
                commandArguments: commandArguments
            )
        case .cursorFlat:
            return !CursorSettingsMerger.isCurrent(
                settings: data,
                hookBinaryPath: Self.hookBinaryPath,
                events: events,
                commandArguments: commandArguments
            )
        }
    }

    func install() throws {
        if let pluginBackend {
            try pluginBackend.install()
            return
        }
        if let openCodeBackend {
            try openCodeBackend.install()
            return
        }
        let existing = try? Data(contentsOf: configURL)
        let merged: Data
        do {
            switch configStyle {
            case .nestedGroups:
                merged = try ClaudeSettingsMerger.merge(
                    settings: existing,
                    hookBinaryPath: Self.hookBinaryPath,
                    events: events,
                    commandArguments: commandArguments
                )
            case .cursorFlat:
                merged = try CursorSettingsMerger.merge(
                    settings: existing,
                    hookBinaryPath: Self.hookBinaryPath,
                    events: events,
                    commandArguments: commandArguments
                )
            }
        } catch {
            throw IntegrationError.unparseableSettings(configURL.path)
        }
        try write(merged, backupOf: existing)
    }

    func uninstall() throws {
        if let pluginBackend {
            try pluginBackend.uninstall()
            return
        }
        if let openCodeBackend {
            try openCodeBackend.uninstall()
            return
        }
        guard let existing = try? Data(contentsOf: configURL) else { return }
        let cleaned: Data
        do {
            switch configStyle {
            case .nestedGroups:
                cleaned = try ClaudeSettingsMerger.unmerge(settings: existing)
            case .cursorFlat:
                cleaned = try CursorSettingsMerger.unmerge(settings: existing)
            }
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
