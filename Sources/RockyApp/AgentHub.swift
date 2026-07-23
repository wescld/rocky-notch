import AppKit
import Combine
import RockyCore

/// Main-thread source of truth for the UI. Owns the SessionStore state
/// machine, decision timeouts, and the IPC server wiring.
@MainActor
final class AgentHub: ObservableObject {
    @Published private(set) var store = SessionStore()
    @Published private(set) var serverError: String?
    /// Sessions that just finished a turn; Rocky celebrates them briefly.
    @Published private(set) var celebrating: Set<String> = []

    /// Hook-side timeout is 60s; we always decide 5s earlier so the hook
    /// exits cleanly (passthrough) instead of being killed.
    static let hookTimeout: TimeInterval = 60
    var decisionTimeout: TimeInterval { Self.hookTimeout - 5 }

    var onPermissionRequest: ((AgentSession) -> Void)?
    var onSessionIdle: ((AgentSession) -> Void)?

    private let server: IPCServer
    private let transcripts = TranscriptWatcher()
    private var timeoutTasks: [String: Task<Void, Never>] = [:]
    private var pruneTimer: Timer?

    var sessions: [AgentSession] { store.ordered }

    init(server: IPCServer = IPCServer()) {
        self.server = server
        server.onEnvelope = { [weak self] envelope in
            self?.handle(envelope)
        }
        server.onPendingDropped = { [weak self] requestId in
            // Connection died without a decision: the agent CLI took over
            // (cancelled or prompting at the terminal).
            self?.finishPending(requestId: requestId, fellBackToTerminal: true)
        }
        transcripts.onUpdate = { [weak self] sessionId, update in
            if let action = update.lastAction {
                self?.store.setLastAction(action, sessionId: sessionId)
            }
            self?.store.addTokens(update.tokens, sessionId: sessionId)
        }
    }

    func start() {
        do {
            try server.start()
        } catch IPCServer.StartError.anotherInstanceRunning {
            serverError = "another Rocky instance is already running"
            NSApp.terminate(nil)
        } catch {
            serverError = "failed to start IPC: \(error)"
        }
        // Host-process checks need to be snappy (Cursor quit → cards vanish).
        // Long idle orphan pruning is cheap and shares the same tick.
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            Task { @MainActor [weak self] in
                self?.pruneStaleSessions()
            }
        }
    }

    /// Drop sessions that can no longer be interacted with:
    /// 1. idle past `idleRetentionTimeout` (~5 min after Stop — click-to-jump)
    /// 2. waitingInput past `waitingInputRetentionTimeout` (~10 min)
    /// 3. no agent PID past `untrackedAgentTimeout` (~15 min; not Cursor)
    /// 4. any status past `orphanTimeout` (2h) with no pending request
    /// 5. agent CLI process exited / PID reused (even if Warp/Cursor still up)
    /// 6. host GUI process (terminal/IDE) has exited
    /// 7. Cursor app fully quit (sessionEnd often never fires on force-quit)
    ///
    /// Codex/Grok have no reliable SessionEnd. Without (1)–(5), closed sessions
    /// stick in the notch while Warp stays open.
    private func pruneStaleSessions() {
        let before = Set(store.sessions.keys)
        store.pruneOrphans(now: Date())

        var abandoned = store.pruneDeadHosts(
            isAgentAlive: { pid, agent in
                TerminalFocus.isAgentProcessStillValid(pid: pid, agent: agent)
            },
            isHostAlive: { TerminalFocus.isProcessAlive($0) }
        )

        // Cursor force-quit safety net: drop only the sessions whose host PID
        // was never resolved (guiAncestor missed Cursor's todesktop bundle).
        // Sessions with a resolved host are already covered by pruneDeadHosts,
        // and a cursor-agent CLI session in a live terminal must not be killed
        // just because the Cursor GUI app isn't running.
        if !Self.isCursorRunning() {
            abandoned += store.removeSessions(agent: "cursor") { $0.terminalAppPid == nil }
        }

        for requestId in abandoned {
            timeoutTasks[requestId]?.cancel()
            timeoutTasks[requestId] = nil
        }
        for sessionId in before.subtracting(Set(store.sessions.keys)) {
            transcripts.unwatch(sessionId: sessionId)
        }
    }

    /// Cursor's bundle id is a todesktop hash and changes across builds; match
    /// by localized name / bundle id substring.
    static func isCursorRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            let name = (app.localizedName ?? "").lowercased()
            let bid = (app.bundleIdentifier ?? "").lowercased()
            return name == "cursor" || bid.contains("cursor")
        }
    }

    func stop() {
        server.stop()
        transcripts.stopAll()
        pruneTimer?.invalidate()
        for task in timeoutTasks.values { task.cancel() }
        timeoutTasks.removeAll()
    }

    /// User action from the notch card (or timeout → .passthrough).
    func decide(requestId: String, decision: Decision, updatedInput: JSONValue? = nil) {
        server.reply(decision, to: requestId, updatedInput: updatedInput)
        finishPending(
            requestId: requestId,
            fellBackToTerminal: decision == .ask || decision == .passthrough
        )
    }

    /// Resolves the hook's GUI ancestor; injectable for tests.
    var resolveTerminalApp: (Int32) -> Int32? = { TerminalFocus.guiAncestor(of: $0) }
    /// Resolves the agent CLI process (codex/claude/grok); injectable for tests.
    var resolveAgentProcess: (Int32, String) -> Int32? = {
        TerminalFocus.agentAncestor(of: $0, agent: $1)
    }

    private func handle(_ envelope: HookEnvelope) {
        // Subagent permission requests have no UI (we track top-level
        // sessions only) — release the hook immediately instead of holding
        // it until the timeout.
        if envelope.event.kind == .permissionRequest, envelope.event.agentId != nil {
            server.reply(.passthrough, to: envelope.requestId)
            return
        }

        let knownBefore = Set(store.sessions.keys)
        let pendingBefore = store.sessions[envelope.event.sessionId]?.pending?.requestId
        store.apply(envelope, at: Date())
        // A pending request the store just dropped (tool ran, turn stopped, or
        // a newer request replaced it) still has a hook blocked on the other
        // end. Release it now so it exits clean instead of burning its 58s
        // deadline, and stop its timeout from firing a late decision.
        if let stale = pendingBefore,
           stale != envelope.requestId,
           store.sessions[envelope.event.sessionId]?.pending?.requestId != stale {
            timeoutTasks[stale]?.cancel()
            timeoutTasks[stale] = nil
            server.reply(.passthrough, to: stale)
        }
        if let guiPid = resolveTerminalApp(envelope.hookPid) {
            store.setTerminalApp(pid: guiPid, sessionId: envelope.event.sessionId)
        }
        // Prefer the PID the hook resolved while still alive. Fall back to a
        // post-hoc walk (often fails for fire-and-forget events — hook already
        // reaped) so older hooks still work when the race is kind.
        let sessionAgent = store.sessions[envelope.event.sessionId]?.agent
            ?? envelope.agent
        let agentPid = envelope.agentProcessPid
            ?? resolveAgentProcess(envelope.hookPid, sessionAgent)
            ?? resolveAgentProcess(envelope.hookPid, envelope.agent)
        if let agentPid {
            store.setAgentProcess(pid: agentPid, sessionId: envelope.event.sessionId)
        }

        // Transcript enrichment follows the session's lifetime. Codex marks
        // its transcript_path as unstable for hooks; only tail Claude's.
        let sessionId = envelope.event.sessionId
        if envelope.agent == "claude-code",
           let path = store.sessions[sessionId]?.transcriptPath {
            transcripts.watch(sessionId: sessionId, path: path)
        }
        if knownBefore.contains(sessionId), store.sessions[sessionId] == nil {
            transcripts.unwatch(sessionId: sessionId)
        }

        switch envelope.event.kind {
        case .permissionRequest:
            scheduleTimeout(requestId: envelope.requestId)
            if let session = store.sessions[envelope.event.sessionId] {
                onPermissionRequest?(session)
            }
        case .stop:
            if let session = store.sessions[envelope.event.sessionId] {
                onSessionIdle?(session)
                celebrate(sessionId: session.id)
            }
        default:
            break
        }
    }

    private func celebrate(sessionId: String) {
        celebrating.insert(sessionId)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3.5))
            self?.celebrating.remove(sessionId)
        }
    }

    private func scheduleTimeout(requestId: String) {
        timeoutTasks[requestId]?.cancel()
        timeoutTasks[requestId] = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(decisionTimeout))
            guard !Task.isCancelled else { return }
            self.decide(requestId: requestId, decision: .passthrough)
        }
    }

    private func finishPending(requestId: String, fellBackToTerminal: Bool = false) {
        timeoutTasks[requestId]?.cancel()
        timeoutTasks[requestId] = nil
        store.resolvePending(
            requestId: requestId,
            at: Date(),
            fellBackToTerminal: fellBackToTerminal
        )
    }
}
