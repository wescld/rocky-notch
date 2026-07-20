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
    public var orphanTimeout: TimeInterval = 2 * 60 * 60

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
             .userPromptSubmit, .unknown:
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
                let flat = prompt.replacingOccurrences(of: "\n", with: " ")
                session.task = flat.count > 100 ? String(flat.prefix(99)) + "…" : flat
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
            session.pending != nil
                || now.timeIntervalSince(session.lastEventAt) < orphanTimeout
        }
    }
}
