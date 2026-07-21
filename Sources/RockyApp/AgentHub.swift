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
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { _ in
            Task { @MainActor [weak self] in
                self?.store.pruneOrphans(now: Date())
            }
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

    private func handle(_ envelope: HookEnvelope) {
        // Subagent permission requests have no UI (we track top-level
        // sessions only) — release the hook immediately instead of holding
        // it until the timeout.
        if envelope.event.kind == .permissionRequest, envelope.event.agentId != nil {
            server.reply(.passthrough, to: envelope.requestId)
            return
        }

        let knownBefore = Set(store.sessions.keys)
        store.apply(envelope, at: Date())
        if let guiPid = resolveTerminalApp(envelope.hookPid) {
            store.setTerminalApp(pid: guiPid, sessionId: envelope.event.sessionId)
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
