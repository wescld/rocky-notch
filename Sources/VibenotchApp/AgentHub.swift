import AppKit
import Combine
import VibenotchCore

/// Main-thread source of truth for the UI. Owns the SessionStore state
/// machine, decision timeouts, and the IPC server wiring.
@MainActor
final class AgentHub: ObservableObject {
    @Published private(set) var store = SessionStore()
    @Published private(set) var serverError: String?

    /// Hook-side timeout is 60s; we always decide 5s earlier so the hook
    /// exits cleanly (passthrough) instead of being killed.
    static let hookTimeout: TimeInterval = 60
    var decisionTimeout: TimeInterval { Self.hookTimeout - 5 }

    var onPermissionRequest: ((AgentSession) -> Void)?
    var onSessionIdle: ((AgentSession) -> Void)?

    private let server: IPCServer
    private var timeoutTasks: [String: Task<Void, Never>] = [:]
    private var pruneTimer: Timer?

    var sessions: [AgentSession] { store.ordered }

    init(server: IPCServer = IPCServer()) {
        self.server = server
        server.onEnvelope = { [weak self] envelope in
            self?.handle(envelope)
        }
        server.onPendingDropped = { [weak self] requestId in
            self?.finishPending(requestId: requestId)
        }
    }

    func start() {
        do {
            try server.start()
        } catch IPCServer.StartError.anotherInstanceRunning {
            serverError = "outra instância do vibenotch já está rodando"
            NSApp.terminate(nil)
        } catch {
            serverError = "falha ao iniciar IPC: \(error)"
        }
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { _ in
            Task { @MainActor [weak self] in
                self?.store.pruneOrphans(now: Date())
            }
        }
    }

    func stop() {
        server.stop()
        pruneTimer?.invalidate()
        for task in timeoutTasks.values { task.cancel() }
        timeoutTasks.removeAll()
    }

    /// User action from the notch card (or timeout → .passthrough).
    func decide(requestId: String, decision: Decision) {
        server.reply(decision, to: requestId)
        finishPending(requestId: requestId)
    }

    /// Resolves the hook's GUI ancestor; injectable for tests.
    var resolveTerminalApp: (Int32) -> Int32? = { TerminalFocus.guiAncestor(of: $0) }

    private func handle(_ envelope: HookEnvelope) {
        store.apply(envelope, at: Date())
        if let guiPid = resolveTerminalApp(envelope.hookPid) {
            store.setTerminalApp(pid: guiPid, sessionId: envelope.event.sessionId)
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
            }
        default:
            break
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

    private func finishPending(requestId: String) {
        timeoutTasks[requestId]?.cancel()
        timeoutTasks[requestId] = nil
        store.resolvePending(requestId: requestId, at: Date())
    }
}
