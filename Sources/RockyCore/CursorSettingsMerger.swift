import Foundation

/// Merge/unmerge Rocky hook entries into Cursor's `hooks.json`.
///
/// Cursor's schema (flat command arrays + top-level `version`):
/// ```
/// { "version": 1, "hooks": { "beforeShellExecution": [{ "command": "…", "timeout": 60 }] } }
/// ```
/// Cursor hooks Rocky installs (the official hook set is larger):
/// beforeSubmitPrompt, beforeShellExecution, beforeMCPExecution,
/// beforeReadFile, afterFileEdit, stop.
///
/// Rules match `ClaudeSettingsMerger`: backup is the caller's job; we never
/// touch foreign keys; ours are identified by `rocky-hook` in `command`.
public enum CursorSettingsMerger {
    public enum MergeError: Error, Equatable {
        case notAnObject
    }

    public static let commandMarker = "rocky-hook"
    public static let legacyMarker = "vibenotch-hook"
    public static let schemaVersion = 1

    /// The six Cursor hook events Rocky currently uses.
    /// Blocking approval: shell + MCP. beforeReadFile is installed but
    /// fire-and-forget (timeout 10) so Rocky does not widen Cursor's own
    /// read policy. Cursor's generic preToolUse can deny writes, but cannot
    /// route them to a human (`ask` is not enforced), so afterFileEdit stays
    /// observational.
    /// Session cards are created on beforeSubmitPrompt; torn down via stop
    /// (idle) + orphan/dead-host pruning. Cursor now documents sessionEnd,
    /// but Rocky does not install it yet.
    public static let cursorEvents: [(name: String, needsReply: Bool)] = [
        ("beforeSubmitPrompt", false),
        ("beforeShellExecution", true),
        ("beforeMCPExecution", true),
        ("beforeReadFile", false),
        ("afterFileEdit", false),
        ("stop", false),
    ]

    /// Events older Rocky builds may have installed but the current event set
    /// intentionally does not. Some are official Cursor hooks today; this is
    /// a migration list, not a claim about Cursor's supported schema.
    /// Unmerge sweeps them so a reinstall does not leave stale Rocky entries.
    public static let legacyEvents: [String] = [
        "sessionStart",
        "sessionEnd",
        "preToolUse",
    ]

    public static func hookCommand(
        hookBinaryPath: String,
        commandArguments: String
    ) -> String {
        var command = ShellCommand.quote(hookBinaryPath)
        if !commandArguments.isEmpty {
            command += " " + commandArguments
        }
        return command
    }

    public static func merge(
        settings data: Data?,
        hookBinaryPath: String,
        events: [(name: String, needsReply: Bool)] = cursorEvents,
        commandArguments: String = "--agent cursor",
        permissionTimeout: Int = 60
    ) throws -> Data {
        var root = try parse(data)
        root["version"] = (root["version"] as? Int) ?? schemaVersion
        var hooks = (root["hooks"] as? [String: Any]) ?? [:]

        // Drop legacy Rocky entries so reinstall self-heals the event set.
        for legacy in legacyEvents {
            guard var entries = hooks[legacy] as? [[String: Any]] else { continue }
            entries.removeAll(where: isOurs)
            hooks[legacy] = entries.isEmpty ? nil : entries
        }

        let command = hookCommand(
            hookBinaryPath: hookBinaryPath,
            commandArguments: commandArguments
        )

        for (event, needsReply) in events {
            var entries = (hooks[event] as? [[String: Any]]) ?? []
            entries.removeAll(where: isOurs)

            var hook: [String: Any] = [
                "command": command,
            ]
            if needsReply {
                hook["timeout"] = permissionTimeout
            } else {
                hook["timeout"] = 10
            }
            entries.append(hook)
            hooks[event] = entries
        }

        root["hooks"] = hooks
        return try serialize(root)
    }

    public static func unmerge(settings data: Data?) throws -> Data {
        var root = try parse(data)
        guard var hooks = root["hooks"] as? [String: Any] else {
            return try serialize(root)
        }
        for (event, value) in hooks {
            guard var entries = value as? [[String: Any]] else { continue }
            entries.removeAll(where: isOurs)
            hooks[event] = entries.isEmpty ? nil : entries
        }
        root["hooks"] = hooks.isEmpty ? nil : hooks
        return try serialize(root)
    }

    /// Full command string (path + args), matching what `merge` writes.
    public static func isCurrent(
        settings data: Data?,
        hookBinaryPath: String,
        events: [(name: String, needsReply: Bool)] = cursorEvents,
        commandArguments: String = "--agent cursor"
    ) -> Bool {
        guard let root = try? parse(data),
              let hooks = root["hooks"] as? [String: Any] else { return false }
        let expected = hookCommand(
            hookBinaryPath: hookBinaryPath,
            commandArguments: commandArguments
        )
        for (event, _) in events {
            guard let entries = hooks[event] as? [[String: Any]],
                  entries.contains(where: {
                      ShellCommand.matches($0["command"] as? String, expected: expected)
                  })
            else { return false }
        }
        return true
    }

    public static func isInstalled(settings data: Data?) -> Bool {
        guard let root = try? parse(data),
              let hooks = root["hooks"] as? [String: Any]
        else { return false }
        // Prefer the real approval channel; also accept a legacy preToolUse
        // install so needsReinstall can detect and self-heal.
        for key in ["beforeShellExecution", "preToolUse"] {
            if let entries = hooks[key] as? [[String: Any]],
               entries.contains(where: isOurs) {
                return true
            }
        }
        return false
    }

    // MARK: - Internals

    private static func isOurs(_ hook: [String: Any]) -> Bool {
        guard let command = hook["command"] as? String else { return false }
        return command.contains(commandMarker) || command.contains(legacyMarker)
    }

    private static func parse(_ data: Data?) throws -> [String: Any] {
        guard let data, !data.isEmpty else { return [:] }
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

}
