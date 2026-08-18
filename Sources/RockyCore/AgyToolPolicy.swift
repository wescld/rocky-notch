import Foundation

/// Agy fires `PreToolUse` for every tool, including read-only ones that never
/// prompt in the TUI. Rocky auto-passes those so the notch only asks about
/// writes, shell, and other actions that need a human.
///
/// `--dangerously-skip-permissions` and `/permissions` `always-proceed` still
/// run PreToolUse hooks, so Rocky must opt out itself — otherwise the notch
/// becomes a second gate the user already turned off.
public enum AgyToolPolicy {
    /// Tools Agy treats as read-only / informational. Keep in sync with the
    /// official hook matcher names (lowercased step types).
    public static let autoPassTools: Set<String> = [
        "view_file",
        "list_dir",
        "find_by_name",
        "grep_search",
        "search_web",
        "read_url_content",
        "list_permissions",
        "ask_question",
    ]

    /// Mode strings that mean "don't prompt the human".
    public static let alwaysProceedModes: Set<String> = [
        "always-proceed",
        "always_proceed",
        "alwaysproceed",
        "dangerously-skip-permissions",
        "dangerously_skip_permissions",
        "yolo",
    ]

    public static func shouldAutoPass(toolName: String?) -> Bool {
        guard let toolName, !toolName.isEmpty else { return false }
        return autoPassTools.contains(toolName)
    }

    public static func isAlwaysProceedModeName(_ raw: String) -> Bool {
        let key = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        let compact = key.replacingOccurrences(of: "-", with: "")
        return alwaysProceedModes.contains(key)
            || alwaysProceedModes.contains(compact)
    }

    /// PreToolUse should not open a Rocky card when the tool is read-only or
    /// Agy is already in always-proceed / skip-permissions.
    /// Session-level skip flags that live on the `agy` argv, not in settings.
    public static func permissionMode(fromArguments arguments: [String]) -> String? {
        if arguments.contains("--dangerously-skip-permissions") {
            return "dangerously-skip-permissions"
        }
        return nil
    }

    public static func shouldSkipRockyGate(
        toolName: String?,
        permissionMode: String? = nil,
        home: String = NSHomeDirectory()
    ) -> Bool {
        if shouldAutoPass(toolName: toolName) { return true }
        if let permissionMode, isAlwaysProceedModeName(permissionMode) {
            return true
        }
        return isAlwaysProceedInConfig(home: home)
    }

    /// Best-effort read of `toolPermission` from the two places Agy 1.1.x
    /// persists it. Session-only `/permissions` toggles may not rewrite these
    /// files; the payload's `permissionMode` (when present) wins first.
    public static func isAlwaysProceedInConfig(home: String = NSHomeDirectory()) -> Bool {
        let candidates = [
            (home as NSString).appendingPathComponent(".gemini/antigravity-cli/settings.json"),
            (home as NSString).appendingPathComponent(".gemini/config/config.json"),
        ]
        for path in candidates {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let root = object as? [String: Any]
            else { continue }
            if configSaysAlwaysProceed(root) { return true }
        }
        return false
    }

    /// Pure scan for tests. Accepts a settings/config object graph.
    public static func configSaysAlwaysProceed(_ root: [String: Any]) -> Bool {
        let keys = ["toolPermission", "tool_permission", "permissionMode", "permission_mode"]
        if let value = firstString(in: root, keys: keys), isAlwaysProceedModeName(value) {
            return true
        }
        if let userSettings = root["userSettings"] as? [String: Any],
           let value = firstString(in: userSettings, keys: keys),
           isAlwaysProceedModeName(value) {
            return true
        }
        return false
    }

    private static func firstString(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }
}
