import Foundation

/// Merge/unmerge Rocky hook entries into Cursor's `hooks.json`.
///
/// Cursor's schema differs from Claude/Codex/Grok:
/// ```
/// { "version": 1, "hooks": { "preToolUse": [{ "command": "…", "timeout": 60 }] } }
/// ```
/// Each event maps to a flat array of hook definitions (no nested `hooks` groups).
/// Rules match `ClaudeSettingsMerger`: backup is the caller's job; we never
/// touch foreign keys; ours are identified by `rocky-hook` in `command`.
public enum CursorSettingsMerger {
    public enum MergeError: Error, Equatable {
        case notAnObject
    }

    public static let commandMarker = "rocky-hook"
    public static let legacyMarker = "vibenotch-hook"
    public static let schemaVersion = 1

    /// Lifecycle + preToolUse as the blocking approval channel (Cursor has no
    /// PermissionRequest). beforeSubmitPrompt carries the user prompt text.
    public static let cursorEvents: [(name: String, needsReply: Bool)] = [
        ("sessionStart", false),
        ("sessionEnd", false),
        ("beforeSubmitPrompt", false),
        ("stop", false),
        ("preToolUse", true),
    ]

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

        for (event, needsReply) in events {
            var entries = (hooks[event] as? [[String: Any]]) ?? []
            entries.removeAll(where: isOurs)

            var command = shellQuote(hookBinaryPath)
            if !commandArguments.isEmpty {
                command += " " + commandArguments
            }
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

    public static func isCurrent(
        settings data: Data?,
        hookBinaryPath: String,
        events: [(name: String, needsReply: Bool)] = cursorEvents
    ) -> Bool {
        guard let root = try? parse(data),
              let hooks = root["hooks"] as? [String: Any] else { return false }
        for (event, _) in events {
            guard let entries = hooks[event] as? [[String: Any]],
                  entries.contains(where: {
                      ($0["command"] as? String)?.contains(hookBinaryPath) == true
                  })
            else { return false }
        }
        return true
    }

    public static func isInstalled(settings data: Data?) -> Bool {
        guard let root = try? parse(data),
              let hooks = root["hooks"] as? [String: Any],
              let entries = hooks["preToolUse"] as? [[String: Any]]
        else { return false }
        return entries.contains(where: isOurs)
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

    private static func shellQuote(_ path: String) -> String {
        path.contains(" ") ? "\"\(path)\"" : path
    }
}
