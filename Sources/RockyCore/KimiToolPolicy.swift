import Foundation

/// Kimi Code fires `PreToolUse` for every tool call, including the ones it
/// already auto-approves and never prompts about. Rocky must not open a card
/// for those — it would be a phantom prompt the user would never see from Kimi
/// itself. So the hook auto-passes Kimi's own auto-approved set and only
/// forwards the rest (writes, shell, MCP, unknown tools) to the app.
///
/// This mirrors `GrokToolPolicy` but is deliberately simpler: whether Rocky
/// actually gates the forwarded tools is a user setting decided in the app
/// (Kimi is deny-only, so gating only adds value in auto/yolo mode). The hook's
/// only job here is to never bother the user about a read-only / auto-approved
/// call.
public enum KimiToolPolicy {
    /// Kimi's built-in `DEFAULT_APPROVE_TOOLS`: tools it runs without ever
    /// prompting. Matched case-sensitively against the exact `tool_name` from
    /// the payload (Kimi 0.29.0). Trying to prove read-only-ness semantically
    /// (e.g. parsing a `Bash` command) is fragile — mirror Kimi's own list
    /// instead, which is the only thing that stays consistent with its UI.
    public static let autoApproveTools: Set<String> = [
        // Read / query.
        "Read",
        "Grep",
        "Glob",
        "ReadMediaFile",
        "TaskList",
        "TaskOutput",
        "CronList",
        "WebSearch",
        "FetchURL",
        "Skill",
        "GetGoal",
        "select_tools",
        // Auto-approved by Kimi though not strictly read-only.
        "SetTodoList",
        "TodoList",
        "Agent",
        "AskUserQuestion",
        "SetGoalBudget",
        "UpdateGoal",
    ]

    /// True when Kimi already auto-approves this tool, so Rocky must not gate it.
    /// Everything else — `Write`, `Edit`, `Bash`, `mcp__*`, and any tool added
    /// by a plugin or a newer Kimi — is treated as gateable.
    public static func shouldAutoPass(toolName: String?) -> Bool {
        guard let toolName, !toolName.isEmpty else { return false }
        return autoApproveTools.contains(toolName)
    }
}
