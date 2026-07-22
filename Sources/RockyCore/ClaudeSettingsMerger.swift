import Foundation

/// Pure merge/unmerge of vibenotch hook entries into an agent CLI's hooks
/// config. The same JSON structure is shared by Claude Code
/// (`~/.claude/settings.json`, hooks as one key among many) and Codex
/// (`~/.codex/hooks.json`, hooks as the only key). Rules:
/// - Never touch keys we don't own; unknown structure in `hooks` is preserved.
/// - Our entries are identified by the hook command containing "rocky-hook".
/// - Merge is idempotent (re-running replaces our entries, no duplicates).
/// - Unparseable input throws — callers must never overwrite a file they
///   couldn't parse.
public enum ClaudeSettingsMerger {
    public enum MergeError: Error, Equatable {
        case notAnObject
    }

    public static let commandMarker = "rocky-hook"
    /// Pre-rename marker; still matched so old installs migrate cleanly.
    public static let legacyMarker = "vibenotch-hook"

    /// Hook events we install per agent. PermissionRequest is the approval
    /// channel; PreToolUse is deliberately absent (fires for every call,
    /// would stall auto-approved tools). Codex has no SessionEnd or
    /// Notification — orphan pruning covers session cleanup there.
    public static let claudeEvents: [(name: String, needsReply: Bool)] = [
        ("SessionStart", false),
        ("SessionEnd", false),
        ("UserPromptSubmit", false),
        ("Stop", false),
        ("Notification", false),
        ("PostToolUse", false),
        ("PermissionRequest", true),
    ]

    public static let codexEvents: [(name: String, needsReply: Bool)] = [
        ("SessionStart", false),
        ("UserPromptSubmit", false),
        ("Stop", false),
        ("PermissionRequest", true),
    ]

    /// Grok has no PermissionRequest; PreToolUse is the blocking approval
    /// channel. SessionEnd + Notification are supported and keep the session
    /// card accurate without relying on orphan pruning alone.
    public static let grokEvents: [(name: String, needsReply: Bool)] = [
        ("SessionStart", false),
        ("SessionEnd", false),
        ("UserPromptSubmit", false),
        ("Stop", false),
        ("Notification", false),
        ("PreToolUse", true),
    ]

    public static func merge(
        settings data: Data?,
        hookBinaryPath: String,
        events: [(name: String, needsReply: Bool)] = claudeEvents,
        commandArguments: String = "",
        permissionTimeout: Int = 60
    ) throws -> Data {
        var root = try parse(data)
        var hooks = (root["hooks"] as? [String: Any]) ?? [:]

        for (event, needsReply) in events {
            var groups = (hooks[event] as? [[String: Any]]) ?? []
            groups.removeAll(where: isOurs)

            var hook: [String: Any] = [
                "type": "command",
                "command": hookCommand(
                    hookBinaryPath: hookBinaryPath,
                    commandArguments: commandArguments
                ),
            ]
            if needsReply {
                hook["timeout"] = permissionTimeout
            } else {
                hook["timeout"] = 10
            }
            groups.append(["hooks": [hook]])
            hooks[event] = groups
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
            guard var groups = value as? [[String: Any]] else { continue }
            groups.removeAll(where: isOurs)
            hooks[event] = groups.isEmpty ? nil : groups
        }
        root["hooks"] = hooks.isEmpty ? nil : hooks
        return try serialize(root)
    }

    /// True when every expected event has our hook pointing at this binary.
    /// False means the installed config predates the current app (missing
    /// event or moved bundle) and should be re-merged.
    /// The exact command string installed for an integration. Shared with
    /// `merge` so staleness is judged against what `merge` would write.
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

    /// Compares the full command, arguments included, not just the binary
    /// path: an install predating `--agent claude-code` is stale and must be
    /// re-merged, otherwise the hook falls back to sniffing GROK_* env vars.
    public static func isCurrent(
        settings data: Data?,
        hookBinaryPath: String,
        events: [(name: String, needsReply: Bool)],
        commandArguments: String = ""
    ) -> Bool {
        guard let root = try? parse(data),
              let hooks = root["hooks"] as? [String: Any] else { return false }
        let expected = hookCommand(
            hookBinaryPath: hookBinaryPath,
            commandArguments: commandArguments
        )
        for (event, _) in events {
            guard let groups = hooks[event] as? [[String: Any]],
                  groups.contains(where: { group in
                      (group["hooks"] as? [[String: Any]])?.contains {
                          ($0["command"] as? String) == expected
                      } == true
                  })
            else { return false }
        }
        return true
    }

    public static func isInstalled(settings data: Data?) -> Bool {
        guard let root = try? parse(data),
              let hooks = root["hooks"] as? [String: Any]
        else { return false }
        // Claude/Codex install under PermissionRequest; Grok under PreToolUse.
        for event in ["PermissionRequest", "PreToolUse"] {
            if let groups = hooks[event] as? [[String: Any]], groups.contains(where: isOurs) {
                return true
            }
        }
        return false
    }

    // MARK: - Internals

    private static func isOurs(_ group: [String: Any]) -> Bool {
        guard let hooks = group["hooks"] as? [[String: Any]] else { return false }
        return hooks.contains { hook in
            guard let command = hook["command"] as? String else { return false }
            return command.contains(commandMarker) || command.contains(legacyMarker)
        }
    }

    private static func parse(_ data: Data?) throws -> [String: Any] {
        guard let data, !data.isEmpty else { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any]
        else { throw MergeError.notAnObject }
        return dict
    }

    private static func serialize(_ root: [String: Any]) throws -> Data {
        // Compacted nil values: JSONSerialization can't encode Optional.
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
