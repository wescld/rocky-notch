import Foundation

/// Kimi Code discovers hooks from user plugins, not from a shared config file.
/// A plugin is a folder with a `kimi.plugin.json` manifest, registered by an
/// entry in `~/.kimi-code/plugins/installed.json`. Rocky installs a dedicated
/// plugin so uninstall stays surgical (drop our registry entry, delete our
/// folder) — the plugin equivalent of Grok's dedicated `rocky.json`.
///
/// This enum owns the pure JSON logic (manifest + registry merge/unmerge),
/// mirroring `ClaudeSettingsMerger`: it never touches the filesystem, never
/// overwrites a registry that failed to parse, and only ever removes our own
/// entry. The filesystem side (staging the folder, atomic writes, backups)
/// lives in the app layer.
public enum KimiPluginMerger {
    public enum MergeError: Error, Equatable {
        case notAnObject
        /// The registry declares a `version` we do not understand; refuse to
        /// rewrite it rather than risk corrupting a newer format.
        case unsupportedVersion(Int)
    }

    /// Stable plugin id / manifest name. Namespaced (not the generic "rocky")
    /// so it never collides with another tool's entry in a shared registry.
    public static let pluginId = "rocky-notch"
    /// Registry schema version Rocky writes and knows how to merge into.
    public static let registryVersion = 1

    public static let commandMarker = "rocky-hook"
    /// Pre-rename marker; still matched so old installs migrate cleanly.
    public static let legacyMarker = "vibenotch-hook"

    /// Events Rocky registers as Kimi hooks. PreToolUse is the blocking
    /// approval channel (Kimi has no PermissionRequest). PermissionRequest /
    /// PermissionResult are deliberately absent: Kimi fires them as observe-only,
    /// but rocky-hook decides whether to wait on `HookEvent.kind`, so registering
    /// them would hang the hook for the full timeout. The rest are observe-only
    /// and keep the session card accurate.
    public static let kimiEvents: [(name: String, needsReply: Bool)] = [
        ("SessionStart", false),
        ("SessionEnd", false),
        ("UserPromptSubmit", false),
        ("Stop", false),
        ("Notification", false),
        ("PostToolUse", false),
        ("PreToolUse", true),
    ]

    // MARK: - Manifest

    /// The `kimi.plugin.json` content Rocky writes into its plugin folder.
    /// `matcher` is intentionally omitted so PreToolUse fires for every tool;
    /// read-only filtering happens in `rocky-hook` (`KimiToolPolicy`).
    public static func manifest(
        hookBinaryPath: String,
        events: [(name: String, needsReply: Bool)] = kimiEvents,
        commandArguments: String = "",
        permissionTimeout: Int = 60
    ) throws -> Data {
        let command = hookCommand(
            hookBinaryPath: hookBinaryPath,
            commandArguments: commandArguments
        )
        let hooks: [[String: Any]] = events.map { event, needsReply in
            [
                "event": event,
                "command": command,
                "timeout": needsReply ? permissionTimeout : 10,
            ]
        }
        let root: [String: Any] = [
            "name": pluginId,
            "description": "Rocky notch integration for Kimi Code.",
            "hooks": hooks,
        ]
        return try serialize(root)
    }

    /// The exact command string installed for a hook. Shared with `manifest`
    /// so staleness is judged against what `manifest` would write. Mirrors
    /// `ClaudeSettingsMerger.hookCommand`.
    public static func hookCommand(
        hookBinaryPath: String,
        commandArguments: String
    ) -> String {
        var command = shellQuote(hookBinaryPath)
        if !commandArguments.isEmpty {
            command += " " + commandArguments
        }
        return command
    }

    // MARK: - Registry (installed.json)

    /// Adds or refreshes Rocky's entry in the plugins registry, preserving
    /// every foreign entry and unknown top-level key. `now` is the ISO
    /// timestamp for `updatedAt`; an existing entry's `installedAt` is kept.
    public static func registryMerge(
        registry data: Data?,
        pluginRoot: String,
        now: String
    ) throws -> Data {
        var root = try parseRegistry(data)
        var plugins = (root["plugins"] as? [[String: Any]]) ?? []

        let previousInstalledAt = plugins.first(where: isOurs)?["installedAt"] as? String
        plugins.removeAll(where: isOurs)
        plugins.append([
            "id": pluginId,
            "root": pluginRoot,
            "source": "local-path",
            "enabled": true,
            "installedAt": previousInstalledAt ?? now,
            "updatedAt": now,
        ])

        root["plugins"] = plugins
        root["version"] = registryVersion
        return try serialize(root)
    }

    /// Removes Rocky's entry, leaving every foreign entry and the file itself
    /// intact. Never deletes the shared registry.
    public static func registryUnmerge(registry data: Data?) throws -> Data {
        var root = try parseRegistry(data)
        guard var plugins = root["plugins"] as? [[String: Any]] else {
            return try serialize(root)
        }
        plugins.removeAll(where: isOurs)
        root["plugins"] = plugins
        return try serialize(root)
    }

    public static func isInstalled(registry data: Data?) -> Bool {
        guard let root = try? parseRegistry(data),
              let plugins = root["plugins"] as? [[String: Any]]
        else { return false }
        return plugins.contains(where: isOurs)
    }

    /// True when our registry entry points at `pluginRoot`, is enabled, and the
    /// on-disk manifest carries our current hook command for every expected
    /// event. False means a moved app bundle or a newly added event — the app
    /// re-installs to self-heal. Mirrors `ClaudeSettingsMerger.isCurrent`.
    public static func isCurrent(
        registry data: Data?,
        manifest manifestData: Data?,
        pluginRoot: String,
        hookBinaryPath: String,
        events: [(name: String, needsReply: Bool)] = kimiEvents,
        commandArguments: String = ""
    ) -> Bool {
        guard let root = try? parseRegistry(data),
              let plugins = root["plugins"] as? [[String: Any]],
              let entry = plugins.first(where: isOurs),
              (entry["root"] as? String) == pluginRoot,
              (entry["enabled"] as? Bool) == true
        else { return false }

        guard let manifestData,
              let manifest = try? parseObject(manifestData),
              let hooks = manifest["hooks"] as? [[String: Any]]
        else { return false }

        let expected = hookCommand(
            hookBinaryPath: hookBinaryPath,
            commandArguments: commandArguments
        )
        for (event, _) in events {
            guard hooks.contains(where: {
                ($0["event"] as? String) == event
                    && ($0["command"] as? String) == expected
            }) else { return false }
        }
        return true
    }

    // MARK: - Internals

    private static func isOurs(_ entry: [String: Any]) -> Bool {
        if (entry["id"] as? String) == pluginId { return true }
        // Fallback: an entry whose root or command still carries our marker,
        // so a half-written or renamed entry is never orphaned.
        if let root = entry["root"] as? String,
           root.contains(pluginId) || root.contains(commandMarker) {
            return true
        }
        return false
    }

    /// Parses the registry, tolerating an absent/empty file (fresh install) but
    /// refusing a malformed one or an unknown schema version.
    private static func parseRegistry(_ data: Data?) throws -> [String: Any] {
        guard let data, !data.isEmpty else {
            return ["version": registryVersion, "plugins": [[String: Any]]()]
        }
        let root = try parseObject(data)
        if let version = root["version"] as? Int, version != registryVersion {
            throw MergeError.unsupportedVersion(version)
        }
        return root
    }

    private static func parseObject(_ data: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any]
        else { throw MergeError.notAnObject }
        return dict
    }

    private static func serialize(_ root: [String: Any]) throws -> Data {
        let cleaned = root.compactMapValues { $0 }
        return try JSONSerialization.data(
            withJSONObject: cleaned,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }

    private static func shellQuote(_ path: String) -> String {
        path.contains(" ") ? "\"\(path)\"" : path
    }
}
