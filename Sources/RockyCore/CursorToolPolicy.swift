import Foundation

/// Cursor's blocking hooks are `beforeShellExecution` and `beforeMCPExecution`
/// (plus optional `beforeReadFile`). There is no before-write hook — file
/// edits only emit observational `afterFileEdit`.
///
/// Rocky only opens the notch for shell and MCP. Read-file hooks auto-pass
/// silently so we do not override Cursor's own allow-list.
public enum CursorToolPolicy {
    /// True when Rocky should open the approval UI for this Cursor hook.
    public static func shouldPrompt(toolName: String?, hookEventName: String? = nil) -> Bool {
        if let hook = hookEventName.map({ HookEvent.Kind.canonical($0) }) {
            switch hook {
            case "BeforeShellExecution", "BeforeMCPExecution":
                return true
            case "BeforeReadFile":
                return false
            default:
                break
            }
        }
        guard let toolName, !toolName.isEmpty else { return false }
        let lower = toolName.lowercased()
        if lower == "shell" || lower == "bash" { return true }
        if toolName.hasPrefix("MCP:") || toolName.hasPrefix("mcp:") { return true }
        // MCP payloads often use the bare tool name with server context.
        if lower.contains("mcp") { return true }
        return false
    }

    /// True when the hook should exit silently without a Rocky card.
    /// Prefer silent fail-open over `{"permission":"allow"}` so Rocky never
    /// widens Cursor's own permission policy.
    public static func shouldAutoPass(toolName: String?, hookEventName: String? = nil) -> Bool {
        !shouldPrompt(toolName: toolName, hookEventName: hookEventName)
    }
}
