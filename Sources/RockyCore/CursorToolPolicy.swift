import Foundation

/// Cursor fires `preToolUse` for every tool. Rocky auto-passes read-only tools
/// so the notch only asks about shell, writes, deletes, tasks, and MCP calls.
public enum CursorToolPolicy {
    /// Tools Cursor treats as safe / observational. Keep aligned with Cursor's
    /// agent tool names (Shell, Read, Write, Grep, Delete, Task, MCP:…).
    public static let autoPassTools: Set<String> = [
        "Read",
        "Grep",
        "Glob",
        "SemanticSearch",
        "ReadLints",
        "TodoWrite",
    ]

    public static func shouldAutoPass(toolName: String?) -> Bool {
        guard let toolName, !toolName.isEmpty else { return false }
        // Explicit deny list wins for anything write-like misnamed.
        if writeLike(toolName) { return false }
        // MCP tools always need a human (or Cursor's own gate).
        if toolName.hasPrefix("MCP:") || toolName.hasPrefix("mcp:") { return false }
        // autoPassTools is the single source of truth; match case-insensitively
        // so a lowercase alias (read/grep/glob) resolves without a second list.
        let lower = toolName.lowercased()
        return autoPassTools.contains { $0.lowercased() == lower }
    }

    private static func writeLike(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("write")
            || lower.contains("edit")
            || lower.contains("delete")
            || lower == "shell"
            || lower == "task"
            || lower == "bash"
    }
}
