import Foundation

/// Extracts a human one-liner ("o que o agente está fazendo agora") from the
/// tail of a Claude Code transcript JSONL. Pure and tolerant: malformed or
/// unknown lines are skipped; nil when nothing meaningful found.
public enum TranscriptTail {
    public struct Update: Equatable, Sendable {
        public let lastAction: String?
        /// Tokens spent in this chunk: input + output + cache writes.
        /// Cache reads are excluded — they'd dwarf and distort the number.
        public let tokens: Int
    }

    /// Scans the given chunk (one or more newline-separated JSONL lines,
    /// newest last): most recent action + token usage found in it.
    public static func scan(_ chunk: Data) -> Update {
        let lines = chunk.split(separator: 0x0A)
        var tokens = 0
        var action: String?
        for line in lines.reversed() {
            let data = Data(line)
            tokens += usage(fromLine: data)
            if action == nil {
                action = self.action(fromLine: data)
            }
        }
        return Update(lastAction: action, tokens: tokens)
    }

    /// Scans the given chunk (one or more newline-separated JSONL lines,
    /// newest last) and returns the most recent action.
    public static func lastAction(in chunk: Data) -> String? {
        scan(chunk).lastAction
    }

    static func usage(fromLine data: Data) -> Int {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            root["type"] as? String == "assistant",
            let message = root["message"] as? [String: Any],
            let usage = message["usage"] as? [String: Any]
        else { return 0 }
        let input = usage["input_tokens"] as? Int ?? 0
        let output = usage["output_tokens"] as? Int ?? 0
        let cacheWrite = usage["cache_creation_input_tokens"] as? Int ?? 0
        return input + output + cacheWrite
    }

    static func action(fromLine data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let agy = agyAction(from: root) { return agy }
        guard
            root["type"] as? String == "assistant",
            let message = root["message"] as? [String: Any],
            let content = message["content"] as? [[String: Any]]
        else { return nil }

        // Prefer the last tool call; fall back to a text snippet.
        for block in content.reversed() {
            guard block["type"] as? String == "tool_use",
                  let name = block["name"] as? String
            else { continue }
            let input = block["input"] as? [String: Any]
            return snippet(friendly(tool: name, input: input))
        }
        for block in content.reversed() {
            guard block["type"] as? String == "text",
                  let text = block["text"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            return snippet(text)
        }
        return nil
    }

    /// Agy brain JSONL: `PLANNER_RESPONSE.tool_calls` plus a few step types.
    private static func agyAction(from root: [String: Any]) -> String? {
        switch root["type"] as? String {
        case "PLANNER_RESPONSE":
            guard let calls = root["tool_calls"] as? [[String: Any]],
                  let last = calls.last,
                  let name = last["name"] as? String
            else { return nil }
            let args = AgyTranscript.unquoteArgs(last["args"] as? [String: Any])
            return snippet(friendly(tool: name, input: args))
        case "VIEW_FILE":
            return "reading a file"
        case "CODE_ACTION":
            if let content = root["content"] as? String,
               !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return snippet(content)
            }
            return "editing a file"
        default:
            return nil
        }
    }

    /// "editing auth.ts" beats "Edit: /very/long/path/auth.ts" at a glance.
    public static func friendly(tool: String, input: [String: Any]?) -> String {
        func base(_ key: String) -> String? {
            (input?[key] as? String).map { ($0 as NSString).lastPathComponent }
        }
        switch tool {
        case "Bash", "run_terminal_command", "PowerShell", "run_command":
            if let command = input?["command"] as? String ?? input?["CommandLine"] as? String {
                return "running \(command)"
            }
            return "running a command"
        case "Edit", "MultiEdit", "NotebookEdit", "search_replace",
             "replace_file_content", "multi_replace_file_content":
            return base("file_path").map { "editing \($0)" }
                ?? base("target_file").map { "editing \($0)" }
                ?? base("TargetFile").map { "editing \($0)" }
                ?? "editing a file"
        case "Write", "write", "write_to_file":
            return base("file_path").map { "writing \($0)" }
                ?? base("target_file").map { "writing \($0)" }
                ?? base("TargetFile").map { "writing \($0)" }
                ?? "writing a file"
        case "Read", "read_file", "view_file":
            return base("file_path").map { "reading \($0)" }
                ?? base("target_file").map { "reading \($0)" }
                ?? base("AbsolutePath").map { "reading \($0)" }
                ?? "reading a file"
        case "Grep", "Glob", "grep", "list_dir", "ListDir", "find_by_name", "grep_search":
            return "searching the codebase"
        case "WebFetch", "WebSearch", "web_search", "web_fetch", "open_page",
             "search_web", "read_url_content":
            if let url = input?["url"] as? String ?? input?["Url"] as? String,
               let host = URL(string: url)?.host {
                return "browsing \(host)"
            }
            if let query = input?["query"] as? String ?? input?["Query"] as? String {
                return "searching \(query)"
            }
            return "browsing the web"
        case "Task", "Agent", "spawn_subagent", "invoke_subagent":
            return "delegating to a subagent"
        case "TodoWrite", "TaskCreate", "TaskUpdate", "todo_write":
            return "planning tasks"
        default:
            return "using \(tool)"
        }
    }

    private static func snippet(_ text: String) -> String {
        let flattened = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flattened.count > 80
            ? String(flattened.prefix(79)) + "…"
            : flattened
    }
}
