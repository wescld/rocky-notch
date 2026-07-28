import Foundation

/// Recovers the agent's closing words for Kimi Code sessions.
///
/// Every other integration hands us the final assistant message on `Stop`
/// (`last_assistant_message`), which is what lets the notch show the handoff —
/// and, when it ends in a question, flag that the agent is waiting on the user.
/// Kimi's `Stop` payload carries no such field, so a Kimi session could only
/// ever say "done", even when it had just asked something.
///
/// Kimi does record the turn on disk, so we read it back from there. This is a
/// deliberate, self-contained coupling to an internal file layout with no
/// stability contract: every failure path returns nil and the session simply
/// falls back to "done", exactly as it behaves today. Tracked upstream as
/// MoonshotAI/kimi-code#2123, asking for the field on the hook payload; this
/// can be deleted the day that lands.
public enum KimiTranscript {
    /// Kimi's data home, matching the CLI's own resolution order.
    public static func defaultHome(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let explicit = environment["KIMI_CODE_HOME"], !explicit.isEmpty { return explicit }
        return (NSHomeDirectory() as NSString).appendingPathComponent(".kimi-code")
    }

    /// Only the tail is read: these logs grow for the whole session, and the
    /// closing words are always at the end.
    static let tailBytes = 512 * 1024

    /// Locates the wire log for a session id. Sessions live under a
    /// per-workspace directory whose name we cannot derive from the hook
    /// payload, so the session id is matched by globbing one level down.
    public static func wireLogURL(
        sessionId: String,
        home: String,
        fileManager: FileManager = .default
    ) -> URL? {
        guard !sessionId.isEmpty else { return nil }
        let sessions = URL(fileURLWithPath: home).appendingPathComponent("sessions")
        guard let workspaces = try? fileManager.contentsOfDirectory(
            at: sessions,
            includingPropertiesForKeys: nil
        ) else { return nil }

        // Kimi's hook payload already carries the `session_` prefix that names
        // the directory, but accept a bare id too rather than depend on it.
        let leaf = sessionId.hasPrefix("session_") ? sessionId : "session_\(sessionId)"
        for workspace in workspaces {
            let candidate = workspace
                .appendingPathComponent(leaf)
                .appendingPathComponent("agents")
                .appendingPathComponent("main")
                .appendingPathComponent("wire.jsonl")
            if fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// Last assistant text in a chunk of the wire log.
    ///
    /// The turn is a stream of loop events; assistant prose arrives as one or
    /// more `content.part` records. Tool calls and results are interleaved, so
    /// the parts belonging to the final stretch of prose are joined and
    /// anything before the last tool call is discarded — that earlier prose is
    /// narration ("let me check X"), not the handoff.
    public static func lastAssistantText(inTail chunk: Data) -> String? {
        // Decoded leniently on purpose: the tail starts at a byte offset, which
        // can land inside a multi-byte character. A validating decode would
        // reject the whole chunk over those stray bytes and lose an intact
        // message further down. The replacement character lands in the leading
        // line, which is discarded below for not starting with `{`.
        let text = String(decoding: chunk, as: UTF8.self)
        var parts: [String] = []

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            // A truncated first line is expected: we start mid-file.
            guard line.first == "{",
                  let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "context.append_loop_event",
                  let event = object["event"] as? [String: Any],
                  let eventType = event["type"] as? String
            else { continue }

            switch eventType {
            case "content.part":
                guard let part = event["part"] as? [String: Any],
                      part["type"] as? String == "text",
                      let value = part["text"] as? String,
                      !value.isEmpty
                else { continue }
                parts.append(value)
            case "tool.call", "step.begin":
                // Work resumed after that prose, so it was not the closing word.
                parts.removeAll()
            default:
                continue
            }
        }

        let joined = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    /// The closing words of a Kimi session, or nil if they cannot be recovered.
    public static func lastAssistantMessage(
        sessionId: String,
        home: String? = nil,
        fileManager: FileManager = .default
    ) -> String? {
        let root = home ?? defaultHome()
        guard let url = wireLogURL(sessionId: sessionId, home: root, fileManager: fileManager),
              let handle = try? FileHandle(forReadingFrom: url)
        else { return nil }
        defer { try? handle.close() }

        guard let size = try? handle.seekToEnd() else { return nil }
        let offset = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        guard (try? handle.seek(toOffset: offset)) != nil,
              let chunk = try? handle.readToEnd()
        else { return nil }

        return lastAssistantText(inTail: chunk)
    }
}
