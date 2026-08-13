import Foundation

/// Recovers the agent's closing words and last action from an Agy brain
/// transcript. Agy's `Stop` hook has no `lastAssistantMessage`, so without
/// this the notch can only say "done".
///
/// Layout (agy 1.1.x, no stability contract):
/// `~/.gemini/antigravity-cli/brain/<conversationId>/.system_generated/logs/transcript.jsonl`
///
/// Every failure path returns nil and the session falls back to "done", the
/// same behaviour as having no recovery at all.
public enum AgyTranscript {
    public static let tailBytes = 512 * 1024

    public static func brainRoot(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".gemini/antigravity-cli/brain", isDirectory: true)
    }

    public static func transcriptURL(
        sessionId: String,
        home: String = NSHomeDirectory()
    ) -> URL {
        brainRoot(home: home)
            .appendingPathComponent(sessionId, isDirectory: true)
            .appendingPathComponent(".system_generated/logs/transcript.jsonl")
    }

    /// Last user-facing assistant prose in a transcript tail, or nil.
    /// Tool-call narration and thinking are discarded — they are not the
    /// handoff. ASK_QUESTION content wins when it is the last thing said.
    public static func lastAssistantText(inTail chunk: Data) -> String? {
        let text = String(decoding: chunk, as: UTF8.self)
        var last: String?

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.first == "{",
                  let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            let type = object["type"] as? String
            let source = object["source"] as? String
            if source == "USER_EXPLICIT" || type == "USER_INPUT" || type == "CONVERSATION_HISTORY" {
                continue
            }
            if type == "PLANNER_RESPONSE" {
                let calls = object["tool_calls"] as? [[String: Any]] ?? []
                if !calls.isEmpty {
                    // Work resumed; earlier prose was narration, not the close.
                    last = nil
                    continue
                }
                if let content = cleanContent(object["content"] as? String) {
                    last = content
                }
                continue
            }
            if type == "ASK_QUESTION",
               let content = cleanContent(object["content"] as? String) {
                last = content
                continue
            }
            if type == "CODE_ACTION" || type == "VIEW_FILE" || type == "CHECKPOINT" {
                // Work happened after any earlier prose, so that prose was
                // narration, not the closing handoff.
                last = nil
                continue
            }
            if let content = cleanContent(object["content"] as? String), source == "MODEL" {
                last = content
            }
        }
        return last
    }

    public static func lastAssistantMessage(
        sessionId: String,
        transcriptPath: String? = nil,
        home: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) -> String? {
        let url: URL
        if let transcriptPath, fileManager.fileExists(atPath: transcriptPath) {
            url = URL(fileURLWithPath: transcriptPath)
        } else {
            url = transcriptURL(sessionId: sessionId, home: home)
            guard fileManager.fileExists(atPath: url.path) else { return nil }
        }
        return lastAssistantText(inTail: tail(of: url) ?? Data())
    }

    /// Pull the user's request out of Agy's wrapped `<USER_REQUEST>` block.
    public static func userRequest(from content: String) -> String? {
        guard let start = content.range(of: "<USER_REQUEST>"),
              let end = content.range(of: "</USER_REQUEST>", range: start.upperBound..<content.endIndex)
        else {
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let inner = content[start.upperBound..<end.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return inner.isEmpty ? nil : inner
    }

    /// Agy transcripts sometimes JSON-encode values as extra-quoted strings
    /// (`"\"/tmp/x\""`). Strip one wrapping pair so paths and commands match
    /// what the hook payload (unquoted) already carries.
    public static func unquote(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count >= 2,
           (value.hasPrefix("\"") && value.hasSuffix("\""))
            || (value.hasPrefix("'") && value.hasSuffix("'")) {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }

    public static func unquoteArgs(_ args: [String: Any]?) -> [String: Any]? {
        guard let args else { return nil }
        var cleaned: [String: Any] = [:]
        for (key, value) in args {
            if let text = value as? String {
                cleaned[key] = unquote(text)
            } else {
                cleaned[key] = value
            }
        }
        return cleaned
    }

    // MARK: - Internals

    private static func cleanContent(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func tail(of url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let offset = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        guard (try? handle.seek(toOffset: offset)) != nil else { return nil }
        return try? handle.readToEnd()
    }
}
