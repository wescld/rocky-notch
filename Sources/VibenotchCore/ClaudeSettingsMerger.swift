import Foundation

/// Pure merge/unmerge of vibenotch hook entries into Claude Code's
/// `~/.claude/settings.json`. Rules:
/// - Never touch keys we don't own; unknown structure in `hooks` is preserved.
/// - Our entries are identified by the hook command containing "vibenotch-hook".
/// - Merge is idempotent (re-running replaces our entries, no duplicates).
/// - Unparseable input throws — callers must never overwrite a file they
///   couldn't parse.
public enum ClaudeSettingsMerger {
    public enum MergeError: Error, Equatable {
        case notAnObject
    }

    public static let commandMarker = "vibenotch-hook"

    /// Hook events we install. PermissionRequest is the approval channel;
    /// PreToolUse is deliberately absent (fires for every call, would stall
    /// auto-approved tools).
    static let events: [(name: String, needsReply: Bool)] = [
        ("SessionStart", false),
        ("SessionEnd", false),
        ("Stop", false),
        ("Notification", false),
        ("PermissionRequest", true),
    ]

    public static func merge(
        settings data: Data?,
        hookBinaryPath: String,
        permissionTimeout: Int = 60
    ) throws -> Data {
        var root = try parse(data)
        var hooks = (root["hooks"] as? [String: Any]) ?? [:]

        for (event, needsReply) in events {
            var groups = (hooks[event] as? [[String: Any]]) ?? []
            groups.removeAll(where: isOurs)

            var hook: [String: Any] = [
                "type": "command",
                "command": shellQuote(hookBinaryPath),
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

    public static func isInstalled(settings data: Data?) -> Bool {
        guard let root = try? parse(data),
              let hooks = root["hooks"] as? [String: Any],
              let groups = hooks["PermissionRequest"] as? [[String: Any]]
        else { return false }
        return groups.contains(where: isOurs)
    }

    // MARK: - Internals

    private static func isOurs(_ group: [String: Any]) -> Bool {
        guard let hooks = group["hooks"] as? [[String: Any]] else { return false }
        return hooks.contains { ($0["command"] as? String)?.contains(commandMarker) == true }
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
