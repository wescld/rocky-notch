import Foundation

/// Extracts a human one-liner ("o que o agente está fazendo agora") from the
/// tail of a Claude Code transcript JSONL. Pure and tolerant: malformed or
/// unknown lines are skipped; nil when nothing meaningful found.
public enum TranscriptTail {
    /// Scans the given chunk (one or more newline-separated JSONL lines,
    /// newest last) and returns the most recent action.
    public static func lastAction(in chunk: Data) -> String? {
        let lines = chunk.split(separator: 0x0A)
        for line in lines.reversed() {
            if let action = action(fromLine: Data(line)) {
                return action
            }
        }
        return nil
    }

    static func action(fromLine data: Data) -> String? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
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
            let detail = (input?["command"] as? String)
                ?? (input?["file_path"] as? String)
                ?? (input?["url"] as? String)
            return snippet(detail.map { "\(name): \($0)" } ?? name)
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

    private static func snippet(_ text: String) -> String {
        let flattened = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flattened.count > 80
            ? String(flattened.prefix(79)) + "…"
            : flattened
    }
}
