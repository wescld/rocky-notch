import Foundation

public enum CommandRiskLevel: String, Codable, CaseIterable, Sendable, Comparable {
    case none, low, elevated, high, critical, destructive

    private var rank: Int {
        Self.allCases.firstIndex(of: self)!
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }

    /// Closed, non-sensitive explanations; never copy tool input into warnings.
    public var warning: String? {
        switch self {
        case .destructive:
            return "destructive — may discard files, rewrite commits, or delete data"
        case .critical:
            return "critical — may force updates, delete remote refs, or change privileged state"
        case .high:
            return "high risk — bypasses verification hooks (--no-verify / -n)"
        default:
            return nil
        }
    }
}

/// Advisory only. This classifier never changes the permission decision.
public enum ToolRiskClassifier {
    public static func risk(toolName: String?, toolInput: JSONValue? = nil) -> CommandRiskLevel {
        let command = toolInput?["command"]?.stringValue
            ?? toolInput?["CommandLine"]?.stringValue ?? ""
        let git = GitCommandRisk.analyze(command)
        return max(substringRisk(toolName: toolName, command: git.nonGitText.lowercased()), git.level)
    }

    private static func substringRisk(toolName: String?, command: String) -> CommandRiskLevel {
        let name = (toolName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["delete", "delete_file"].contains(name) || [
            "rm -rf", "rm -fr", "git reset --hard", "diskutil erase", "drop database",
            "drop table", "truncate table", "mkfs", "dd if=",
        ].contains(where: command.contains) { return .destructive }
        if ["--force", "-f origin", "sudo ", "chmod -r", "chown -r"].contains(where: command.contains) {
            return .critical
        }
        if name.contains("shell") || name.hasPrefix("mcp:") || name.hasPrefix("mcp__")
            || ["bash", "exec_command", "execute_command", "run_terminal_command",
                "run_shell_command", "powershell", "run_command", "mcp"].contains(name) {
            return .elevated
        }
        if ["edit", "multiedit", "notebookedit", "write", "write_to_file", "search_replace",
            "replace_file_content", "multi_replace_file_content"].contains(name) { return .low }
        return .none
    }
}
