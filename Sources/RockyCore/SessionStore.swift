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
        /// The turn ended, but the session left work in flight and will be
        /// woken by it. Distinct from `idle` because the machine is busy and
        /// from `running` because the main loop is parked: a session that
        /// delegated must not be celebrated as finished, nor expire on the
        /// short click-to-jump window while its agents are still working.
        case delegating
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
    /// Subagents, background shells and other work the session registered as
    /// in flight. Reported wholesale on every `Stop` / `SubagentStop`, so the
    /// list maintains itself: each child that finishes reannounces the rest,
    /// and an empty list is the session saying it is finally done.
    public var backgroundTasks: [BackgroundTask] = []

    /// Live activity (a tool call landing) outranks a wait we were told about
    /// earlier: the agent cannot be blocked on the user and running a tool at
    /// the same time. Only clears an input wait — a pending permission is a
    /// live card the user still has to decide, so it stays.
    /// The handoff goes with the wait: work resumed, so whatever the agent
    /// left us with was answered somewhere we could not see. Keeping it would
    /// let a stale question resurface as the next turn's closing message,
    /// since `Stop` only overwrites it when it carries one of its own.
    mutating func clearWaitForLiveActivity() {
        guard status == .waitingInput else { return }
        lastAgentMessage = nil
        handoffAsksSomething = false
        waitingInputReason = nil
        status = .running
    }

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

    /// Where a session settles when a turn ends. Work it delegated means the
    /// machine is still busy, so "at rest" is not the same as "done" — and
    /// more than one event ends a turn (`Stop`, and the `idle_prompt`
    /// notification that trails it), so the rule lives in one place rather
    /// than in each of them.
    static func restingStatus(of session: AgentSession) -> AgentSession.Status {
        session.backgroundTasks.isEmpty ? .idle : .delegating
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
        // Subagent hooks would duplicate the parent session, so they are
        // dropped — with two exceptions that say something about the parent
        // nothing else does. `SubagentStop` reports the work still in flight,
        // and a subagent's own tool calls are the only live evidence that a
        // parked session is still moving. The latter never enters the state
        // machine: it annotates its own row and leaves.
        if let agentId = event.agentId, event.kind != .subagentStop {
            if event.kind == .postToolUse {
                noteSubagentActivity(agentId: agentId, event: event, at: date)
            }
            return
        }

        switch event.kind {
        case .sessionEnd:
            sessions[event.sessionId] = nil
            return
        case .sessionStart, .stop, .subagentStop, .notification,
             .permissionRequest, .postToolUse, .userPromptSubmit, .unknown:
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
        // Stop and SubagentStop both carry the whole in-flight list, so it is
        // replaced rather than accumulated — the agent is authoritative about
        // what exists. Rocky's own enrichment survives the swap.
        if let reported = event.backgroundTasks {
            session.backgroundTasks = Self.merging(
                existing: session.backgroundTasks,
                reported: reported
            )
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
                // that already reported an explicit block — or one still
                // waiting on work it delegated, which this fires for too.
                if session.waitingInputReason == nil {
                    session.status = Self.restingStatus(of: session)
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
            // Same reasoning for an explicit wait: the tool ran, so the block
            // is over even though no prompt event told us so.
            session.clearWaitForLiveActivity()
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
                session.status = Self.restingStatus(of: session)
            }
        case .subagentStop:
            // The closing words on this event are the *subagent's*; the parent
            // keeps its own. All that is taken from here is the refreshed
            // in-flight list applied above — and where that leaves a session
            // at rest, in both directions.
            //
            // Draining to empty is the obvious one. The other matters just as
            // much: a relaunch restores a delegating session as idle with no
            // list (Rocky cannot vouch for work it did not see start), and the
            // next event is often a SubagentStop still carrying children. Only
            // handling the drain left that session idle with children drawn
            // under it — the "done · click to jump" over live agents this
            // whole change exists to stop, back through another door.
            //
            // A session whose main loop is running, or which is blocked on the
            // user, is not at rest and is left alone.
            switch session.status {
            case .running, .waitingPermission, .waitingInput:
                break
            case .idle, .delegating:
                session.status = Self.restingStatus(of: session)
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
        // A fresh tool call in the transcript is proof the agent is working, so
        // whatever it was blocked on got answered somewhere we cannot see —
        // approving a permission or picking an option at the terminal prompt
        // fires no UserPromptSubmit, which used to leave the row amber for the
        // rest of the session while its tokens ticked up.
        sessions[sessionId]?.clearWaitForLiveActivity()
    }

    public mutating func addTokens(_ tokens: Int, sessionId: String) {
        guard tokens > 0 else { return }
        sessions[sessionId]?.tokens += tokens
    }

    /// The model behind a subagent, resolved from its on-disk sidecar. Purely a
    /// label ("Fable" instead of "general-purpose"); no state depends on it.
    public mutating func setSubagentModel(
        _ model: String,
        agentId: String,
        sessionId: String
    ) {
        guard let index = sessions[sessionId]?.backgroundTasks
            .firstIndex(where: { $0.id == agentId })
        else { return }
        sessions[sessionId]?.backgroundTasks[index].model = model
    }

    /// A subagent ran a tool. Deliberately outside the state machine: it
    /// annotates that child's row and refreshes the session clock, which is the
    /// only live proof that a parked session is still moving.
    private mutating func noteSubagentActivity(
        agentId: String,
        event: HookEvent,
        at date: Date
    ) {
        guard var session = sessions[event.sessionId],
              let index = session.backgroundTasks.firstIndex(where: { $0.id == agentId })
        else { return }
        if let toolName = event.toolName {
            session.backgroundTasks[index].lastAction = TranscriptTail.friendly(
                tool: toolName,
                input: event.toolInput?.objectValue
            )
        }
        let gap = date.timeIntervalSince(session.lastEventAt)
        if gap > 0 {
            session.activeSeconds += min(gap, 5 * 60)
        }
        session.lastEventAt = date
        sessions[event.sessionId] = session
    }

    /// The payload decides *which* work exists; Rocky is the only source for
    /// what that work is doing, so live actions and resolved models are carried
    /// across a refresh instead of being reset by every child that finishes.
    static func merging(
        existing: [BackgroundTask],
        reported: [BackgroundTask]
    ) -> [BackgroundTask] {
        guard !existing.isEmpty else { return reported }
        let previous = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return reported.map { task in
            guard let old = previous[task.id] else { return task }
            var merged = task
            merged.lastAction = task.lastAction ?? old.lastAction
            merged.model = task.model ?? old.model
            return merged
        }
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
            case .running, .delegating, .waitingPermission:
                // Delegating is work in progress: expiring it on the idle
                // window would drop the row precisely while its agents run.
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
    /// Drop a single session the user dismissed from the panel. Returns its
    /// abandoned pending request id, if any, so the hub can cancel the timeout.
    @discardableResult
    public mutating func remove(id: String) -> String? {
        guard let session = sessions[id] else { return nil }
        sessions[id] = nil
        return session.pending?.requestId
    }

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
        let flat = stripMarkdown(tail)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return flat.isEmpty ? nil : flat
    }

    /// Strips the markdown agents write for a rendered terminal but which is
    /// noise in a one-line chip — `**Want me to commit?**` should read as the
    /// question, not as asterisks.
    ///
    /// Single `*` and `_` are deliberately left alone: they collide with
    /// `snake_case` identifiers and arithmetic, and mangling a variable name is
    /// worse than showing one stray character.
    private static func stripMarkdown(_ line: String) -> String {
        var text = line.replacingOccurrences(
            // Leading bullet, ordered marker, quote or heading.
            of: "^\\s*(?:[-*+]\\s+|\\d+[.)]\\s+|>\\s*|#{1,6}\\s+)",
            with: "",
            options: .regularExpression
        )
        // [label](url) → label
        text = text.replacingOccurrences(
            of: "\\[([^\\]]*)\\]\\([^)]*\\)",
            with: "$1",
            options: .regularExpression
        )
        // Paired emphasis only, so the delimiters are unambiguous.
        for pattern in ["\\*\\*([^*]+)\\*\\*", "__([^_]+)__", "`([^`]+)`"] {
            text = text.replacingOccurrences(
                of: pattern, with: "$1", options: .regularExpression
            )
        }
        return text
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
