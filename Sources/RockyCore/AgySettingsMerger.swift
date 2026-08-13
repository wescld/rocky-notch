import Foundation

/// Merge/unmerge Rocky hooks into Antigravity CLI's named-hook `hooks.json`.
///
/// Official schema (agy 1.1.x, `~/.gemini/config/hooks.json`):
/// ```
/// {
///   "rocky-notch": {
///     "PreToolUse": [{ "matcher": "*", "hooks": [{ "type": "command", "command": "…" }] }],
///     "Stop": [{ "type": "command", "command": "…" }]
///   }
/// }
/// ```
/// Tool events (`PreToolUse` / `PostToolUse`) are matcher groups. Lifecycle
/// events (`PreInvocation` / `PostInvocation` / `Stop`) are a flat handler
/// list — the matcher is ignored and must not be wrapped.
///
/// Agy payloads have no `hookEventName`, so each command carries
/// `--event <Name>` as well as `--agent agy`. Rules match the other mergers:
/// backup is the caller's job; we never touch foreign named hooks; ours are
/// identified by the `rocky-notch` key (and a `rocky-hook` command fallback).
public enum AgySettingsMerger {
    public enum MergeError: Error, Equatable {
        case notAnObject
    }

    public static let commandMarker = "rocky-hook"
    public static let legacyMarker = "vibenotch-hook"
    public static let hookName = "rocky-notch"
    public static let commandArguments = "--agent agy"

    /// Official 1.1.x events. PreToolUse is the blocking approval channel
    /// (Agy has no PermissionRequest). The rest are observational.
    public static let agyEvents: [(name: String, needsReply: Bool, grouped: Bool)] = [
        ("PreToolUse", true, true),
        ("PostToolUse", false, true),
        ("PreInvocation", false, false),
        ("PostInvocation", false, false),
        ("Stop", false, false),
    ]

    public static func hookCommand(
        hookBinaryPath: String,
        event: String,
        commandArguments: String = commandArguments
    ) -> String {
        var command = shellQuote(hookBinaryPath)
        if !commandArguments.isEmpty {
            command += " " + commandArguments
        }
        command += " --event \(event)"
        return command
    }

    public static func merge(
        settings data: Data?,
        hookBinaryPath: String,
        events: [(name: String, needsReply: Bool, grouped: Bool)] = agyEvents,
        commandArguments: String = commandArguments,
        permissionTimeout: Int = 60
    ) throws -> Data {
        var root = try parse(data)
        var group = (root[hookName] as? [String: Any]) ?? [:]
        group["enabled"] = true

        for (event, needsReply, grouped) in events {
            let command = hookCommand(
                hookBinaryPath: hookBinaryPath,
                event: event,
                commandArguments: commandArguments
            )
            let handler: [String: Any] = [
                "type": "command",
                "command": command,
                "timeout": needsReply ? permissionTimeout : 10,
            ]
            if grouped {
                var entries = (group[event] as? [[String: Any]]) ?? []
                entries.removeAll(where: isOurGroup)
                entries.append([
                    "matcher": "*",
                    "hooks": [handler],
                ])
                group[event] = entries
            } else {
                var handlers = (group[event] as? [[String: Any]]) ?? []
                handlers.removeAll(where: isOurHandler)
                handlers.append(handler)
                group[event] = handlers
            }
        }

        root[hookName] = group
        return try serialize(root)
    }

    public static func unmerge(settings data: Data?) throws -> Data {
        var root = try parse(data)
        // Only the group we own. Other named hooks are the user's, even if a
        // command string happens to mention rocky-hook.
        root[hookName] = nil
        return try serialize(root)
    }

    public static func isCurrent(
        settings data: Data?,
        hookBinaryPath: String,
        events: [(name: String, needsReply: Bool, grouped: Bool)] = agyEvents,
        commandArguments: String = commandArguments
    ) -> Bool {
        guard let root = try? parse(data),
              let group = root[hookName] as? [String: Any],
              (group["enabled"] as? Bool) != false
        else { return false }
        for (event, _, grouped) in events {
            let expected = hookCommand(
                hookBinaryPath: hookBinaryPath,
                event: event,
                commandArguments: commandArguments
            )
            let entries = group[event] as? [[String: Any]] ?? []
            let found: Bool
            if grouped {
                found = entries.contains { entry in
                    (entry["hooks"] as? [[String: Any]])?.contains {
                        ($0["command"] as? String) == expected
                    } == true
                }
            } else {
                found = entries.contains { ($0["command"] as? String) == expected }
            }
            if !found { return false }
        }
        return true
    }

    public static func isInstalled(settings data: Data?) -> Bool {
        guard let root = try? parse(data) else { return false }
        if let group = root[hookName] as? [String: Any] {
            let pre = group["PreToolUse"] as? [[String: Any]] ?? []
            if pre.contains(where: { isOurGroup($0) || isOurHandler($0) }) {
                return true
            }
        }
        // Fallback: a renamed group that still points at rocky-hook.
        for (name, value) in root where name != hookName {
            guard let group = value as? [String: Any],
                  let pre = group["PreToolUse"] as? [[String: Any]]
            else { continue }
            if pre.contains(where: { isOurGroup($0) || isOurHandler($0) }) {
                return true
            }
        }
        return false
    }

    // MARK: - Internals

    private static func isOurGroup(_ entry: [String: Any]) -> Bool {
        if let hooks = entry["hooks"] as? [[String: Any]] {
            return hooks.contains(where: isOurHandler)
        }
        return isOurHandler(entry)
    }

    private static func isOurHandler(_ hook: [String: Any]) -> Bool {
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
