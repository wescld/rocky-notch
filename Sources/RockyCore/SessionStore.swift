import Foundation

public struct PendingPermission: Equatable, Sendable {
    public let requestId: String
    public let toolName: String
    public let summary: String
    public let receivedAt: Date
    /// Raw tool input — the UI derives richer previews (e.g. Edit diffs).
    public let toolInput: JSONValue?

    public init(
        requestId: String,
        toolName: String,
        summary: String,
        receivedAt: Date,
        toolInput: JSONValue? = nil
    ) {
        self.requestId = requestId
        self.toolName = toolName
        self.summary = summary
        self.receivedAt = receivedAt
        self.toolInput = toolInput
    }
}

public struct AgentSession: Identifiable, Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case running
        case waitingPermission
        case waitingInput
        case idle
    }

    public let id: String
    public var agent: String
    public var cwd: String?
    public var hookPid: Int32?
    public var status: Status
    public var pending: PendingPermission?
    public var lastEventAt: Date
    public var title: String?
    public var model: String?
    /// PID of the GUI app (terminal/editor) hosting this session, resolved
    /// from the hook's process ancestry while the hook is still alive.
    public var terminalAppPid: Int32?
    /// PID of the agent CLI process (codex / claude / grok), if resolved.
    /// Used to drop the card when the user Ctrl+C's the agent while the
    /// terminal app (e.g. Warp) is still running.
    public var agentProcessPid: Int32? = nil
    public var transcriptPath: String?
    /// Last meaningful action from the transcript ("Bash: npm test").
    public var lastAction: String?
    /// Tokens spent this session (input + output + cache writes).
    public var tokens: Int = 0
    /// Accumulated "working" time: event gaps capped at 5 minutes.
    public var activeSeconds: TimeInterval = 0
    /// What the user asked for (latest prompt, truncated).
    public var task: String?

    public var projectName: String {
        if let title, !title.isEmpty { return title }
        guard let cwd else { return "session" }
        return (cwd as NSString).lastPathComponent
    }
}

/// Pure state machine over hook events. No I/O, fully unit-testable.
/// The app wraps it in an ObservableObject; the store itself owns the rules.
public struct SessionStore: Equatable, Sendable {
    public private(set) var sessions: [String: AgentSession] = [:]

    /// Sessions with no events for this long and no pending request are pruned.
    /// Covers long-running cards whose host + agent are still up.
    public var orphanTimeout: TimeInterval = 2 * 60 * 60

    /// After `Stop` the card stays briefly so the user can click-to-jump back
    /// to the terminal. Codex/Grok have no reliable SessionEnd, so without a
    /// short idle retention these "done" rows stick until Warp quits (or
    /// orphanTimeout).
    public var idleRetentionTimeout: TimeInterval = 5 * 60

    /// After Notification idle / permission fallback the card says "your turn
    /// in the terminal". If the user never comes back (and SessionEnd never
    /// fires), drop on this shorter window instead of 2h.
    public var waitingInputRetentionTimeout: TimeInterval = 10 * 60

    /// Sessions where we never resolved an agent CLI PID cannot detect Ctrl+C.
    /// Cursor is excluded (no separate CLI). Everyone else gets this leash so
    /// a fire-and-forget SessionStart alone cannot stick for 2h.
    public var untrackedAgentTimeout: TimeInterval = 15 * 60

    public init() {}

    public var ordered: [AgentSession] {
        sessions.values.sorted { $0.lastEventAt > $1.lastEventAt }
    }

    public mutating func apply(_ envelope: HookEnvelope, at date: Date) {
        let event = envelope.event
        // Subagent hooks would duplicate the parent session; skip them.
        guard event.agentId == nil else { return }

        switch event.kind {
        case .sessionEnd:
            sessions[event.sessionId] = nil
            return
        case .sessionStart, .stop, .notification, .permissionRequest,
             .postToolUse, .userPromptSubmit, .unknown:
            break
        }

        var session = sessions[event.sessionId] ?? AgentSession(
            id: event.sessionId,
            agent: envelope.agent,
            cwd: event.cwd,
            hookPid: envelope.hookPid,
            status: .running,
            pending: nil,
            lastEventAt: date,
            title: nil,
            model: nil,
            terminalAppPid: nil,
            transcriptPath: nil,
            lastAction: nil
        )
        // Grok loads Claude Code settings hooks by default
        // (`[compat.claude] hooks = true`). Rocky is installed in both
        // places, so one Grok session dual-fires envelopes — often
        // `--agent claude-code` first, then `--agent grok`. Without an
        // upgrade, the notch chip stuck on "Claude".
        session.agent = Self.preferredAgent(current: session.agent, incoming: envelope.agent)
        // Active time: count the gap since the last event, capped so long
        // idle stretches don't inflate the number.
        let gap = date.timeIntervalSince(session.lastEventAt)
        if gap > 0 {
            session.activeSeconds += min(gap, 5 * 60)
        }
        session.lastEventAt = date
        session.hookPid = envelope.hookPid
        if let cwd = event.cwd { session.cwd = cwd }
        if let path = event.transcriptPath { session.transcriptPath = path }

        switch event.kind {
        case .sessionStart:
            session.status = .running
            session.title = event.sessionTitle ?? session.title
            session.model = event.model ?? session.model
        case .userPromptSubmit:
            session.status = .running
            if let prompt = event.prompt {
                session.task = Self.displayTask(from: prompt)
            }
        case .permissionRequest:
            session.status = .waitingPermission
            session.pending = PendingPermission(
                requestId: envelope.requestId,
                toolName: event.toolName ?? "tool",
                summary: event.toolSummary ?? event.toolName ?? "",
                receivedAt: date,
                toolInput: event.toolInput
            )
        case .notification:
            // permission_prompt is redundant with PermissionRequest; the rest
            // of the "needs you" types map to waitingInput.
            switch event.notificationType {
            case "idle_prompt", "agent_needs_input", "elicitation_dialog":
                session.status = .waitingInput
            default:
                break
            }
        case .postToolUse:
            // The tool executed, so the approval happened somewhere we cannot
            // see (the terminal prompt). Drop the card instead of leaving it
            // up until the decision timeout.
            session.pending = nil
            if session.status == .waitingPermission { session.status = .running }
            // Kimi / OpenCode have no transcript for Rocky to tail; live
            // activity comes from PostToolUse (plugin bridge or hooks).
            if envelope.agent == "kimi-code" || envelope.agent == "opencode",
               let toolName = event.toolName {
                session.lastAction = TranscriptTail.friendly(
                    tool: toolName,
                    input: event.toolInput?.objectValue
                )
            }
        case .stop:
            session.status = .idle
            session.pending = nil
        case .sessionEnd, .unknown:
            break
        }

        sessions[event.sessionId] = session
    }

    public mutating func setTerminalApp(pid: Int32, sessionId: String) {
        sessions[sessionId]?.terminalAppPid = pid
    }

    public mutating func setAgentProcess(pid: Int32, sessionId: String) {
        sessions[sessionId]?.agentProcessPid = pid
    }

    public mutating func setLastAction(_ action: String, sessionId: String) {
        sessions[sessionId]?.lastAction = action
    }

    public mutating func addTokens(_ tokens: Int, sessionId: String) {
        guard tokens > 0 else { return }
        sessions[sessionId]?.tokens += tokens
    }

    /// Called when a pending request was answered or timed out.
    /// `fellBackToTerminal` (ask/timeout/dropped): the agent is now waiting
    /// for the user at the terminal prompt, not running.
    public mutating func resolvePending(
        requestId: String,
        at date: Date,
        fellBackToTerminal: Bool = false
    ) {
        for (id, var session) in sessions where session.pending?.requestId == requestId {
            session.pending = nil
            if session.status == .waitingPermission {
                session.status = fellBackToTerminal ? .waitingInput : .running
            }
            session.lastEventAt = date
            sessions[id] = session
        }
    }

    public mutating func pruneOrphans(now: Date) {
        sessions = sessions.filter { _, session in
            // Pending permission: keep until decided or dead-host prune.
            if session.pending != nil { return true }
            let age = now.timeIntervalSince(session.lastEventAt)
            // Turn finished (Stop) — short click-to-jump window.
            if session.status == .idle {
                return age < idleRetentionTimeout
            }
            // "Your turn in the terminal" — user walked away / session closed.
            if session.status == .waitingInput {
                return age < waitingInputRetentionTimeout
            }
            // No agent PID: cannot detect CLI exit; short leash (not Cursor).
            if session.agentProcessPid == nil, session.agent != "cursor" {
                return age < untrackedAgentTimeout
            }
            return age < orphanTimeout
        }
    }

    /// Drop sessions whose host GUI or agent CLI process is gone.
    /// Returns pending request ids so the hub can cancel decision timeouts.
    /// Sessions with no resolved PIDs are left alone (orphan / retention
    /// timeouts still apply).
    ///
    /// - `isAgentAlive`: CLI process still exists **and** still looks like the
    ///   agent (name check guards against PID reuse after exit).
    /// - `isHostAlive`: terminal/IDE process still exists.
    @discardableResult
    public mutating func pruneDeadHosts(
        isAgentAlive: (Int32, String) -> Bool,
        isHostAlive: (Int32) -> Bool
    ) -> [String] {
        var abandoned: [String] = []
        sessions = sessions.filter { _, session in
            var dead = false
            if let pid = session.agentProcessPid,
               !isAgentAlive(pid, session.agent) {
                dead = true
            }
            if let pid = session.terminalAppPid, !isHostAlive(pid) {
                dead = true
            }
            guard dead else { return true }
            if let requestId = session.pending?.requestId {
                abandoned.append(requestId)
            }
            return false
        }
        return abandoned
    }

    /// Convenience for tests / simple callers that only check PID existence.
    @discardableResult
    public mutating func pruneDeadHosts(isAlive: (Int32) -> Bool) -> [String] {
        pruneDeadHosts(
            isAgentAlive: { pid, _ in isAlive(pid) },
            isHostAlive: isAlive
        )
    }

    /// Remove sessions for a given agent (e.g. Cursor quit with no sessionEnd
    /// hooks). `where` narrows the sweep — the Cursor-app-quit net only targets
    /// sessions whose host PID was never resolved, so a `cursor-agent` CLI
    /// session running in a live terminal is left to the normal dead-host /
    /// orphan pruning instead of being killed the moment the GUI app is closed.
    /// Returns abandoned pending request ids.
    @discardableResult
    public mutating func removeSessions(
        agent: String,
        where predicate: (AgentSession) -> Bool = { _ in true }
    ) -> [String] {
        var abandoned: [String] = []
        sessions = sessions.filter { _, session in
            guard session.agent == agent, predicate(session) else { return true }
            if let requestId = session.pending?.requestId {
                abandoned.append(requestId)
            }
            return false
        }
        return abandoned
    }

    /// Resolve dual-fired Claude-compat hooks against the real agent.
    ///
    /// Prefer any non-`claude-code` identity over `claude-code`, and never
    /// demote away from a more specific agent once known. Pure Claude
    /// sessions only ever emit `claude-code` and stay labeled correctly.
    public static func preferredAgent(current: String, incoming: String) -> String {
        if current == incoming { return current }
        if incoming == "claude-code", current != "claude-code" { return current }
        if current == "claude-code" { return incoming }
        return current
    }

    /// One-line task chip from a raw UserPromptSubmit prompt.
    ///
    /// Grok wraps human turns in `<user_query>...</user_query>` for the model;
    /// those tags must not show up in the notch ("You: &lt;user_query&gt; …").
    public static func displayTask(from prompt: String, maxLength: Int = 100) -> String {
        var text = prompt
        let openTag = "<user_query>"
        let closeTag = "</user_query>"
        if let open = text.range(of: openTag, options: .caseInsensitive),
           let close = text.range(of: closeTag, options: .caseInsensitive),
           open.upperBound <= close.lowerBound {
            text = String(text[open.upperBound..<close.lowerBound])
        } else {
            // Truncated payloads may only carry the opening tag.
            text = text.replacingOccurrences(
                of: openTag, with: "", options: .caseInsensitive
            )
            text = text.replacingOccurrences(
                of: closeTag, with: "", options: .caseInsensitive
            )
        }
        let flat = text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard flat.count > maxLength else { return flat }
        return String(flat.prefix(maxLength - 1)) + "…"
    }
}
