import Foundation

/// Grok fires `PreToolUse` for every tool call, including read-only ones that
/// never prompt the user. Rocky auto-passes those so the notch only asks about
/// actions that need a human decision (shell, edits, network writes, etc.).
///
/// Grok's always-approve mode (`bypassPermissions` / `permission_mode =
/// "always-approve"`) still runs PreToolUse hooks by design — so Rocky must
/// opt out itself when the user already chose YOLO, otherwise the notch
/// becomes a second approval gate they never asked for.
public enum GrokToolPolicy {
    /// Tools Grok treats as read-only / never-prompt by default. Keep in sync
    /// with Grok's "Operations That Never Prompt by Default" list plus Claude
    /// aliases that may appear via harness compatibility.
    public static let autoPassTools: Set<String> = [
        // Grok native
        "read_file",
        "list_dir",
        "grep",
        "web_search",
        "todo_write",
        "get_command_or_subagent_output",
        "wait_commands_or_subagents",
        "kill_command_or_subagent",
        "skill",
        "search_tool",
        // Claude-compatible aliases (Grok matcher mapping)
        "Read",
        "Grep",
        "Glob",
        "ListDir",
        "WebSearch",
        "TodoWrite",
        "Skill",
        "TaskOutput",
        "BashOutput",
        "AgentOutputTool",
    ]

    /// Mode strings that mean "don't prompt the human" in Grok / Claude terms.
    public static let alwaysApproveModes: Set<String> = [
        "always-approve",
        "always_approve",
        "alwaysapprove",
        "bypasspermissions",
        "bypass-permissions",
        "yolo",
    ]

    public static func shouldAutoPass(toolName: String?) -> Bool {
        guard let toolName, !toolName.isEmpty else { return false }
        return autoPassTools.contains(toolName)
    }

    /// True when the hook payload or Grok config says always-approve / YOLO.
    public static func isAlwaysApproveMode(
        permissionMode: String? = nil,
        home: String = NSHomeDirectory()
    ) -> Bool {
        if let permissionMode, isAlwaysApproveModeName(permissionMode) {
            return true
        }
        return isAlwaysApproveInConfig(home: home)
    }

    /// PreToolUse should not open a Rocky card when the tool is read-only or
    /// Grok is already in always-approve.
    public static func shouldSkipRockyGate(
        toolName: String?,
        permissionMode: String? = nil,
        home: String = NSHomeDirectory()
    ) -> Bool {
        if shouldAutoPass(toolName: toolName) { return true }
        return isAlwaysApproveMode(permissionMode: permissionMode, home: home)
    }

    public static func isAlwaysApproveModeName(_ raw: String) -> Bool {
        let key = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        let compact = key.replacingOccurrences(of: "-", with: "")
        return alwaysApproveModes.contains(key)
            || alwaysApproveModes.contains(compact)
            || compact == "bypasspermissions"
    }

    /// Best-effort read of `~/.grok/config.toml` `[ui]` settings.
    /// Session-only Ctrl+O toggles may not rewrite this file; the payload's
    /// `permissionMode` (when present) wins first.
    public static func isAlwaysApproveInConfig(home: String = NSHomeDirectory()) -> Bool {
        let path = (home as NSString).appendingPathComponent(".grok/config.toml")
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return false
        }
        return parseAlwaysApprove(fromTOML: text)
    }

    /// Pure TOML-ish scan for tests. Looks at `[ui]` keys only.
    public static func parseAlwaysApprove(fromTOML text: String) -> Bool {
        var inUI = false
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine
                .trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") {
                // Only the top-level [ui] table carries the permission mode;
                // [ui.*] subtables and every other section are ignored.
                inUI = line == "[ui]"
                continue
            }
            guard inUI else { continue }
            if let value = tomlStringValue(line, key: "permission_mode"),
               isAlwaysApproveModeName(value) {
                return true
            }
            if let value = tomlStringValue(line, key: "defaultMode")
                ?? tomlStringValue(line, key: "default_mode"),
               isAlwaysApproveModeName(value) {
                return true
            }
            if let flag = tomlBoolValue(line, key: "yolo"), flag {
                return true
            }
        }
        return false
    }

    // MARK: - Tiny TOML helpers (keys we own; not a full parser)

    private static func tomlStringValue(_ line: String, key: String) -> String? {
        // Match the whole key exactly, so `permission_mode_extra = …` never
        // gets read as `permission_mode`. Accepts `key = "v"` / `key="v"` / `key = v`.
        guard let eq = line.firstIndex(of: "=") else { return nil }
        guard line[..<eq].trimmingCharacters(in: .whitespaces) == key else { return nil }
        var value = String(line[line.index(after: eq)...])
            .trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("#") { return nil }
        if let hash = value.firstIndex(of: "#") {
            value = String(value[..<hash]).trimmingCharacters(in: .whitespaces)
        }
        if value.count >= 2,
           (value.hasPrefix("\"") && value.hasSuffix("\""))
            || (value.hasPrefix("'") && value.hasSuffix("'")) {
            value = String(value.dropFirst().dropLast())
        }
        return value.isEmpty ? nil : value
    }

    private static func tomlBoolValue(_ line: String, key: String) -> Bool? {
        guard let value = tomlStringValue(line, key: key)?.lowercased() else {
            return nil
        }
        switch value {
        case "true", "yes", "1": return true
        case "false", "no", "0": return false
        default: return nil
        }
    }
}
