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

/// Why a session is waiting on the user. Only explicit signals from the agent
/// set this — it is what separates "the agent told us it is blocked" from
/// "the turn merely ended", so the notch can be loud about one and quiet about
/// the other.
public enum WaitingInputReason: Equatable, Sendable {
    /// Agent notification: a background session is waiting on input.
    case agentNeedsInput
    /// An MCP server opened an elicitation form.
    case elicitation
    /// The user chose to answer at the terminal instead of the notch.
    case permissionFallback
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
    /// Precision jump metadata from the hook (Warp pane, TTY, tmux…).
    public var jumpTarget: JumpTarget? = nil
    public var transcriptPath: String?
    /// Last meaningful action from the transcript ("Bash: npm test").
    public var lastAction: String?
    /// Tokens spent this session (input + output + cache writes).
    public var tokens: Int = 0
    /// Accumulated "working" time: event gaps capped at 5 minutes.
    public var activeSeconds: TimeInterval = 0
    /// What the user asked for (latest prompt, truncated).
    public var task: String?
    /// The agent's closing words for the turn, normalized to one short line.
    /// This is the handoff: "Want me to commit?" reads at a glance in the
    /// notch, so the user knows which session needs them without opening a
    /// terminal. Only set when the agent hands us the text (Claude's `Stop`
    /// carries `last_assistant_message`); agents that don't stay blank rather
    /// than guess.
    public var lastAgentMessage: String?
    /// The closing line carried a question mark. Display hint only — see
    /// `SessionStore.asksSomething`. Computed before truncation so a question
    /// past the cut still counts.
    public var handoffAsksSomething: Bool = false
    /// Set only by explicit "the agent is blocked" signals. `nil` while
    /// `status == .waitingInput` never happens: the two move together.
    public var waitingInputReason: WaitingInputReason?

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

    /// A finished turn that left the user a message is a handoff worth reading,
    /// so it outlives a bare "done" row — but still expires, because the user
    /// may simply not care.
    public var handoffRetentionTimeout: TimeInterval = 15 * 60

    /// Sessions where we never resolved an agent CLI PID cannot detect Ctrl+C.
    /// Cursor is excluded (no separate CLI). Everyone else gets this leash so
    /// a fire-and-forget SessionStart alone cannot stick for 2h.
    public var untrackedAgentTimeout: TimeInterval = 15 * 60

    public init() {}

    /// Sessions that want the user float to the top. Sorting purely by recency
    /// buries the one that asked something under the ones still working — which
    /// is the row the user opened the notch to find. Ties fall back to recency,
    /// then id, so equal rows never flicker between orderings.
    public var ordered: [AgentSession] {
        sessions.values.sorted { a, b in
            let rankA = Self.attentionRank(a)
            let rankB = Self.attentionRank(b)
            if rankA != rankB { return rankA < rankB }
            if a.lastEventAt != b.lastEventAt { return a.lastEventAt > b.lastEventAt }
            return a.id < b.id
        }
    }

    /// Lower sorts first. Proven signals outrank the question hint, which in
    /// turn outranks work that needs nobody — a wrong hint costs a row one
    /// position, never a state change.
    static func attentionRank(_ session: AgentSession) -> Int {
        if session.pending != nil { return 0 }
        if session.status == .waitingInput { return 1 }
        if session.status == .idle, session.handoffAsksSomething { return 2 }
        return 3
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
        if let jump = envelope.jumpTarget {
            session.jumpTarget = session.jumpTarget?.merging(jump) ?? jump
            // Prefer cwd from the jump target when the event omitted it.
            if session.cwd == nil, let wd = jump.workingDirectory {
                session.cwd = wd
            }
        }

        switch event.kind {
        case .sessionStart:
            session.status = .running
            session.title = event.sessionTitle ?? session.title
            session.model = event.model ?? session.model
        case .userPromptSubmit:
            session.status = .running
            // The user answered, so the previous handoff is spent: drop the
            // closing message and any wait it was blocked on.
            session.lastAgentMessage = nil
            session.handoffAsksSomething = false
            session.waitingInputReason = nil
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
            // permission_prompt is redundant with PermissionRequest.
            switch event.notificationType {
            case "agent_needs_input":
                session.status = .waitingInput
                session.waitingInputReason = .agentNeedsInput
            case "elicitation_dialog":
                session.status = .waitingInput
                session.waitingInputReason = .elicitation
            case "idle_prompt":
                // "Done and waiting for your next prompt" — fires at the end of
                // every idle turn, so it says nothing about whether the agent is
                // actually blocked on the user. Treating it as "needs you" would
                // paint every finished session amber and bury the ones that do.
                // It only confirms the turn ended; never downgrade a session
                // that already reported an explicit block.
                if session.waitingInputReason == nil {
                    session.status = .idle
                }
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
            // The agent's closing words are the handoff. Keep them so the notch
            // can show what it left us with instead of a bare "done".
            if let closing = Self.closingLine(from: event.lastAssistantMessage) {
                session.lastAgentMessage = Self.displayAgentMessage(from: closing)
                session.handoffAsksSomething = Self.asksSomething(closing)
            }
            session.pending = nil
            // Stop fires at the end of every turn, including one the agent
            // ended blocked on the user. Only an unblocked turn is "done" —
            // otherwise Stop would erase a wait that arrived just before it.
            if session.waitingInputReason == nil {
                session.status = .idle
            }
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

    public mutating func setJumpTarget(_ target: JumpTarget, sessionId: String) {
        if let existing = sessions[sessionId]?.jumpTarget {
            sessions[sessionId]?.jumpTarget = existing.merging(target)
        } else {
            sessions[sessionId]?.jumpTarget = target
        }
    }

    /// Seed from disk after relaunch. Only fills ids that are not already live.
    public mutating func restore(_ restored: [AgentSession]) {
        for session in restored where sessions[session.id] == nil {
            sessions[session.id] = session
        }
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
                session.waitingInputReason = fellBackToTerminal ? .permissionFallback : nil
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
            // Pure observational rows (JSONL discovery / no PIDs) keep the
            // longer orphan window so launch-seeded sessions aren't dropped
            // on the first prune tick, regardless of any closing message.
            if session.status == .idle,
               session.agentProcessPid == nil,
               session.terminalAppPid == nil {
                return age < orphanTimeout
            }

            var limit = orphanTimeout
            switch session.status {
            case .idle:
                // Turn finished — short click-to-jump window, unless the agent
                // left words behind, which the user still has to read.
                limit = session.lastAgentMessage == nil
                    ? idleRetentionTimeout
                    : handoffRetentionTimeout
            case .waitingInput:
                // The agent reported it is blocked on the user, so the row
                // stays until the agent or its host actually goes away.
                // Expiring it because the user stepped out defeats the state.
                limit = orphanTimeout
            case .running, .waitingPermission:
                break
            }
            // No agent PID: cannot detect CLI exit, so cap whatever the status
            // asked for with a short leash (Cursor has no separate CLI).
            if session.agentProcessPid == nil, session.agent != "cursor" {
                limit = min(limit, untrackedAgentTimeout)
            }
            return age < limit
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

    /// One-line preview of the agent's closing message for the notch.
    ///
    /// Agents narrate what they did first and put the ask last, so the preview
    /// starts from the message's last line rather than its opening recap.
    ///
    /// Within that line it keeps the *beginning*. The notch row is far narrower
    /// than this budget and truncates again visually, so anchoring anywhere but
    /// the start leaves the reader with the middle of a sentence — measured in
    /// practice, it renders as noise.
    ///
    /// Returns nil for blank input so the session falls back to "done" rather
    /// than showing an empty handoff.
    public static func displayAgentMessage(
        from raw: String?,
        maxLength: Int = 140
    ) -> String? {
        guard let flat = closingLine(from: raw) else { return nil }
        guard flat.count > maxLength else { return flat }
        return String(flat.prefix(maxLength - 1)) + "…"
    }

    /// The agent's last line with prose in it, collapsed to one line.
    /// Shared so the question hint reads the same text the user sees — but
    /// before truncation, which would hide a question mark past the cut.
    public static func closingLine(from raw: String?) -> String? {
        guard let raw else { return nil }
        let lines = raw
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !isMarkdownScaffolding($0) }
        // Fall back to the whole text when it is nothing but scaffolding.
        let tail = lines.last ?? raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let flat = tail
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return flat.isEmpty ? nil : flat
    }

    /// Whether the agent's closing line carries a question mark.
    ///
    /// Deliberately punctuation and not vocabulary: agents reply in whatever
    /// language the user writes in, so a keyword list ("should I", "quer que
    /// eu", …) would work in one and silently fail in the next. Punctuation
    /// survives the translation.
    ///
    /// This is a display hint only — it never moves the state machine, plays a
    /// sound, or changes retention, so a wrong guess costs one dot colour. It
    /// catches direct questions and misses asks phrased as statements
    /// ("let me know and I'll commit"), which stay neutral rather than guess.
    public static func asksSomething(_ closingLine: String?) -> Bool {
        guard let closingLine else { return false }
        return closingLine.contains { "?？؟".contains($0) }
    }

    /// Table rows, rules and fences carry no message; skip them so the preview
    /// lands on the agent's actual closing words. This is about layout, not
    /// meaning — Rocky never tries to judge whether the text is a question.
    private static func isMarkdownScaffolding(_ line: String) -> Bool {
        if line.hasPrefix("|") || line.hasPrefix("```") { return true }
        let rule = line.filter { !$0.isWhitespace }
        return rule.count >= 3 && rule.allSatisfy { "-=*_#".contains($0) }
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
