import Foundation

/// On-disk session discovery from agent-written JSONL transcripts.
///
/// Complements `SessionPersistence` (Rocky's own snapshot + PID liveness):
/// this finds Claude / Codex sessions even when Rocky was never running.
/// Discovered rows are always observational — status `.idle`, no pending
/// permission, no host/agent PIDs. Live hooks still win via
/// `SessionStore.restore` (fills missing ids only) + `apply`.
public enum SessionDiscovery {
    /// Aligned with `SessionStore.orphanTimeout` / `SessionPersistence.maxAge`.
    public static let maxAge: TimeInterval = 2 * 60 * 60
    /// Cap how many recent files we open per agent root.
    public static let maxFiles: Int = 40
    /// Per-file read budget so launch never slurps multi-hundred-MB transcripts.
    public static let maxBytesPerFile: Int = 512 * 1_024
    public static let streamingChunkSize = 64 * 1_024

    public static func claudeProjectsRoot(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    public static func codexSessionsRoot(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    /// Scan Claude + Codex transcript roots and return idle observational rows.
    public static func discoverRecent(
        home: String = NSHomeDirectory(),
        now: Date = Date(),
        fileManager: FileManager = .default,
        maxAge: TimeInterval = maxAge,
        maxFiles: Int = maxFiles,
        maxBytesPerFile: Int = maxBytesPerFile
    ) -> [AgentSession] {
        let claude = discoverClaude(
            rootURL: claudeProjectsRoot(home: home),
            now: now,
            fileManager: fileManager,
            maxAge: maxAge,
            maxFiles: maxFiles,
            maxBytesPerFile: maxBytesPerFile
        )
        let codex = discoverCodex(
            rootURL: codexSessionsRoot(home: home),
            now: now,
            fileManager: fileManager,
            maxAge: maxAge,
            maxFiles: maxFiles,
            maxBytesPerFile: maxBytesPerFile
        )
        return (claude + codex).sorted { $0.lastEventAt > $1.lastEventAt }
    }

    /// Drops discovered rows whose agent has no live process anywhere near the
    /// directory they were found in.
    ///
    /// Discovery reads transcripts, and a transcript outlives the session that
    /// wrote it — nothing in the file says whether that agent is still running.
    /// So every launch reseeded sessions the user had already closed, and the
    /// notch claimed work that had been over for an hour.
    ///
    /// The rule is deliberately weak, because a wrong drop costs a real row:
    /// a session is kept unless *no* process of its agent is running in that
    /// directory, in one above it, or in one below it. That still cannot tell
    /// two sessions in the same folder apart — there it keeps both — but it
    /// settles the case that actually misleads, where the agent is not running
    /// there at all.
    ///
    /// `workingDirectories` returning nil means "cannot tell"; those sessions
    /// are kept untouched.
    public static func filterToLiveAgents(
        _ sessions: [AgentSession],
        workingDirectories: (String) -> Set<String>?
    ) -> [AgentSession] {
        var cache: [String: Set<String>?] = [:]
        return sessions.filter { session in
            guard let cwd = session.cwd, !cwd.isEmpty else { return true }
            let directories = cache[session.agent] ?? {
                let looked = workingDirectories(session.agent)
                cache[session.agent] = looked
                return looked
            }()
            guard let directories else { return true }
            return directories.contains { sharesTree($0, cwd) }
        }
    }

    /// Same directory, or one contains the other. Compared by path boundary so
    /// `/a/web` is not treated as living inside `/a/web-app`.
    ///
    /// Both sides are canonicalized first: the kernel reports a process's
    /// directory through the firmlink (`/private/tmp/…`) while a transcript
    /// records the path the user typed (`/tmp/…`), and comparing those raw
    /// would drop a live session as dead. The rest of the codebase already
    /// normalizes this pair — see `WarpSQLiteReader.cwdLookupCandidates` and
    /// the transcript path in `makeObservationalSession`.
    static func sharesTree(_ lhs: String, _ rhs: String) -> Bool {
        let left = canonicalPath(lhs)
        let right = canonicalPath(rhs)
        return left == right || left.hasPrefix(right + "/") || right.hasPrefix(left + "/")
    }

    /// Collapses the `/private` firmlink prefix and any `..` / trailing slash,
    /// so two spellings of the same directory compare equal.
    static func canonicalPath(_ path: String) -> String {
        let standardized = (path as NSString).standardizingPath
        for pair in ["/private/tmp", "/private/var"] where standardized == pair
            || standardized.hasPrefix(pair + "/") {
            return String(standardized.dropFirst("/private".count))
        }
        return standardized
    }

    // MARK: - Claude

    public static func discoverClaude(
        rootURL: URL,
        now: Date = Date(),
        fileManager: FileManager = .default,
        maxAge: TimeInterval = maxAge,
        maxFiles: Int = maxFiles,
        maxBytesPerFile: Int = maxBytesPerFile
    ) -> [AgentSession] {
        let candidates = recentJSONLFiles(
            rootURL: rootURL,
            now: now,
            fileManager: fileManager,
            maxAge: maxAge,
            maxFiles: maxFiles,
            pathFilter: { url in
                url.pathExtension == "jsonl" && !url.path.contains("/subagents/")
            }
        )
        return candidates.compactMap { candidate in
            parseClaudeSession(
                at: candidate.fileURL,
                fallbackUpdatedAt: candidate.modifiedAt,
                maxBytes: maxBytesPerFile
            )
        }
    }

    // MARK: - Codex

    public static func discoverCodex(
        rootURL: URL,
        now: Date = Date(),
        fileManager: FileManager = .default,
        maxAge: TimeInterval = maxAge,
        maxFiles: Int = maxFiles,
        maxBytesPerFile: Int = maxBytesPerFile
    ) -> [AgentSession] {
        let candidates = recentJSONLFiles(
            rootURL: rootURL,
            now: now,
            fileManager: fileManager,
            maxAge: maxAge,
            maxFiles: maxFiles,
            pathFilter: { url in
                url.pathExtension == "jsonl"
                    && url.lastPathComponent.hasPrefix("rollout-")
            }
        )
        var byID: [String: AgentSession] = [:]
        for candidate in candidates {
            guard let session = parseCodexSession(
                at: candidate.fileURL,
                fallbackUpdatedAt: candidate.modifiedAt,
                maxBytes: maxBytesPerFile
            ) else { continue }
            if let existing = byID[session.id], existing.lastEventAt >= session.lastEventAt {
                continue
            }
            byID[session.id] = session
        }
        return byID.values.sorted { $0.lastEventAt > $1.lastEventAt }
    }

    // MARK: - Conversion

    /// Build an observational `AgentSession` — never invents pending permissions.
    public static func makeObservationalSession(
        id: String,
        agent: String,
        cwd: String,
        lastEventAt: Date,
        model: String? = nil,
        transcriptPath: String,
        task: String? = nil,
        lastAction: String? = nil
    ) -> AgentSession {
        // Normalize /var ↔ /private/var firmlinks so store + tests agree.
        let standardizedPath = (transcriptPath as NSString).standardizingPath
        var session = AgentSession(
            id: id,
            agent: agent,
            cwd: cwd,
            hookPid: nil,
            status: .idle,
            pending: nil,
            lastEventAt: lastEventAt,
            title: nil,
            model: model,
            terminalAppPid: nil,
            transcriptPath: standardizedPath,
            lastAction: lastAction
        )
        session.jumpTarget = JumpTarget(workingDirectory: cwd)
        session.task = task
        return session
    }

    // MARK: - Internals

    private struct Candidate {
        var fileURL: URL
        var modifiedAt: Date
    }

    private static func recentJSONLFiles(
        rootURL: URL,
        now: Date,
        fileManager: FileManager,
        maxAge: TimeInterval,
        maxFiles: Int,
        pathFilter: (URL) -> Bool
    ) -> [Candidate] {
        guard fileManager.fileExists(atPath: rootURL.path),
              let enumerator = fileManager.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
              )
        else { return [] }

        let cutoff = now.addingTimeInterval(-maxAge)
        var candidates: [Candidate] = []
        for case let fileURL as URL in enumerator {
            guard pathFilter(fileURL) else { continue }
            let values = try? fileURL.resourceValues(
                forKeys: [.isRegularFileKey, .contentModificationDateKey]
            )
            guard values?.isRegularFile == true,
                  let modifiedAt = values?.contentModificationDate,
                  modifiedAt >= cutoff
            else { continue }
            candidates.append(Candidate(fileURL: fileURL, modifiedAt: modifiedAt))
        }
        return Array(
            candidates
                .sorted { $0.modifiedAt > $1.modifiedAt }
                .prefix(maxFiles)
        )
    }

    private static func parseClaudeSession(
        at fileURL: URL,
        fallbackUpdatedAt: Date,
        maxBytes: Int
    ) -> AgentSession? {
        var sessionID = fileURL.deletingPathExtension().lastPathComponent
        var cwd: String?
        var updatedAt = fallbackUpdatedAt
        var model: String?
        var task: String?
        var lastAction: String?

        forEachJSONLLine(at: fileURL, maxBytes: maxBytes) { object in
            if let value = object["sessionId"] as? String, !value.isEmpty {
                sessionID = value
            }
            if let value = object["cwd"] as? String, !value.isEmpty {
                cwd = value
            }
            if let ts = parseTimestamp(object["timestamp"]) {
                updatedAt = ts
            }

            let message = object["message"] as? [String: Any]
            let role = message?["role"] as? String
            let topType = object["type"] as? String

            if role == "user" || topType == "user" {
                if let prompt = promptText(from: message?["content"] ?? object["content"]) {
                    if task == nil {
                        task = SessionStore.displayTask(from: prompt)
                    }
                }
            } else if role == "assistant" || topType == "assistant" {
                if let value = message?["model"] as? String, !value.isEmpty {
                    model = value
                }
                if let action = actionFromAssistantContent(message?["content"]) {
                    lastAction = action
                }
            }
        }

        guard let cwd, !cwd.isEmpty, !sessionID.isEmpty else { return nil }
        return makeObservationalSession(
            id: sessionID,
            agent: "claude-code",
            cwd: cwd,
            lastEventAt: updatedAt,
            model: model,
            transcriptPath: fileURL.path,
            task: task,
            lastAction: lastAction
        )
    }

    private static func parseCodexSession(
        at fileURL: URL,
        fallbackUpdatedAt: Date,
        maxBytes: Int
    ) -> AgentSession? {
        var sessionID: String?
        var cwd: String?
        var updatedAt = fallbackUpdatedAt
        var model: String?
        var task: String?
        var lastAction: String?

        forEachJSONLLine(at: fileURL, maxBytes: maxBytes) { object in
            if let ts = parseTimestamp(object["timestamp"]) {
                updatedAt = ts
            }
            let type = object["type"] as? String
            let payload = object["payload"] as? [String: Any] ?? [:]

            if type == "session_meta" {
                if let id = (payload["id"] as? String) ?? (payload["session_id"] as? String),
                   !id.isEmpty {
                    sessionID = id
                }
                if let value = payload["cwd"] as? String, !value.isEmpty {
                    cwd = value
                }
                if let ts = parseTimestamp(payload["timestamp"]) {
                    updatedAt = max(updatedAt, ts)
                }
            } else if type == "turn_context" {
                if let value = payload["model"] as? String, !value.isEmpty {
                    model = value
                }
                // Latest wins. `session_meta` records where the session was
                // born, but `codex resume` can restart it somewhere else and
                // only `turn_context` says so — keeping the birthplace shows
                // the wrong project name, and now also compares a live agent
                // against a directory it left, which reads as "not running".
                if let value = payload["cwd"] as? String, !value.isEmpty {
                    cwd = value
                }
            } else if type == "event_msg" {
                let eventType = payload["type"] as? String
                if eventType == "user_message",
                   let message = payload["message"] as? String,
                   !message.isEmpty,
                   task == nil {
                    task = SessionStore.displayTask(from: message)
                }
            } else if type == "response_item" {
                // function/tool calls: name + arguments
                if let name = payload["name"] as? String, !name.isEmpty {
                    let input = payload["arguments"] as? [String: Any]
                        ?? payload["input"] as? [String: Any]
                    lastAction = TranscriptTail.friendly(tool: name, input: input)
                }
            }
        }

        guard let sessionID, !sessionID.isEmpty,
              let cwd, !cwd.isEmpty
        else { return nil }

        return makeObservationalSession(
            id: sessionID,
            agent: "codex",
            cwd: cwd,
            lastEventAt: updatedAt,
            model: model,
            transcriptPath: fileURL.path,
            task: task,
            lastAction: lastAction
        )
    }

    /// Stream JSONL lines up to `maxBytes` without loading the whole file.
    private static func forEachJSONLLine(
        at fileURL: URL,
        maxBytes: Int,
        body: ([String: Any]) -> Void
    ) {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return }
        defer { try? handle.close() }

        var buffer = Data()
        var bytesRead = 0
        while bytesRead < maxBytes,
              let chunk = try? handle.read(
                upToCount: min(streamingChunkSize, maxBytes - bytesRead)
              ),
              !chunk.isEmpty {
            bytesRead += chunk.count
            buffer.append(chunk)
            for line in extractCompleteLines(from: &buffer) {
                guard let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                body(object)
            }
        }
        // Trailing line without newline (partial file / mid-flush kill).
        if !buffer.isEmpty {
            let trailing = String(decoding: buffer, as: UTF8.self)
            if let data = trailing.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                body(object)
            }
        }
    }

    private static func extractCompleteLines(from buffer: inout Data) -> [String] {
        let newline = UInt8(ascii: "\n")
        var lines: [String] = []
        while let newlineIndex = buffer.firstIndex(of: newline) {
            let lineData = buffer.prefix(upTo: newlineIndex)
            buffer.removeSubrange(...newlineIndex)
            guard !lineData.isEmpty else { continue }
            lines.append(String(decoding: lineData, as: UTF8.self))
        }
        return lines
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoBasic: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func parseTimestamp(_ value: Any?) -> Date? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return isoFractional.date(from: text) ?? isoBasic.date(from: text)
    }

    private static func promptText(from content: Any?) -> String? {
        if let text = content as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let blocks = content as? [[String: Any]] else { return nil }
        for block in blocks {
            if block["type"] as? String == "text",
               let text = block["text"] as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private static func actionFromAssistantContent(_ content: Any?) -> String? {
        guard let blocks = content as? [[String: Any]] else { return nil }
        for block in blocks.reversed() {
            if block["type"] as? String == "tool_use",
               let name = block["name"] as? String {
                return TranscriptTail.friendly(
                    tool: name,
                    input: block["input"] as? [String: Any]
                )
            }
        }
        for block in blocks.reversed() {
            if block["type"] as? String == "text",
               let text = block["text"] as? String {
                let flat = text
                    .split(whereSeparator: \.isWhitespace)
                    .joined(separator: " ")
                guard !flat.isEmpty else { continue }
                if flat.count > 80 { return String(flat.prefix(79)) + "…" }
                return flat
            }
        }
        return nil
    }
}
