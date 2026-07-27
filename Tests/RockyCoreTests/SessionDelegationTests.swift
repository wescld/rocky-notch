import XCTest
@testable import RockyCore

/// A turn that ends by delegating is not a turn that finished. Before this,
/// `Stop` meant idle unconditionally, so the notch showed "done · click to
/// jump" over a session whose subagents were still working.
final class SessionDelegationTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    let subagent = BackgroundTask(
        id: "ag1",
        kind: "subagent",
        status: "running",
        description: "Fable design review of brainstorm",
        agentType: "general-purpose"
    )
    let shell = BackgroundTask(
        id: "sh1",
        kind: "shell",
        status: "running",
        description: "Run codex job monitor in background",
        command: "bash /tmp/mon-codex.sh"
    )

    func envelope(
        _ name: String,
        session: String = "s1",
        requestId: String = "r1",
        toolName: String? = nil,
        toolInput: JSONValue? = nil,
        agentId: String? = nil,
        lastAssistantMessage: String? = nil,
        backgroundTasks: [BackgroundTask]? = nil
    ) -> HookEnvelope {
        HookEnvelope(
            requestId: requestId,
            hookPid: 1,
            agent: "claude-code",
            event: HookEvent(
                sessionId: session,
                hookEventName: name,
                cwd: "/tmp/proj",
                toolName: toolName,
                toolInput: toolInput,
                lastAssistantMessage: lastAssistantMessage,
                agentId: agentId,
                backgroundTasks: backgroundTasks
            )
        )
    }

    // MARK: - Stop

    func testStopWithWorkInFlightDelegatesInsteadOfGoingIdle() {
        var store = SessionStore()
        store.apply(envelope("SessionStart"), at: t0)
        store.apply(
            envelope("Stop", lastAssistantMessage: "Fable está rodando.",
                     backgroundTasks: [subagent, shell]),
            at: t0 + 10
        )
        XCTAssertEqual(store.sessions["s1"]?.status, .delegating)
        XCTAssertEqual(store.sessions["s1"]?.backgroundTasks.map(\.id), ["ag1", "sh1"])
    }

    func testStopWithNothingInFlightStillGoesIdle() {
        var store = SessionStore()
        store.apply(envelope("SessionStart"), at: t0)
        store.apply(envelope("Stop", backgroundTasks: []), at: t0 + 10)
        XCTAssertEqual(store.sessions["s1"]?.status, .idle)
    }

    /// Providers that never report in-flight work must behave exactly as before.
    func testStopWithoutTheFieldStillGoesIdle() {
        var store = SessionStore()
        store.apply(envelope("SessionStart"), at: t0)
        store.apply(envelope("Stop"), at: t0 + 10)
        XCTAssertEqual(store.sessions["s1"]?.status, .idle)
    }

    /// Delegating must not outrank an explicit "I am blocked on you": the user
    /// is still the one holding this session up.
    func testWaitingInputSurvivesADelegatingStop() {
        var store = SessionStore()
        store.apply(envelope("SessionStart"), at: t0)
        var blocked = envelope("Notification")
        blocked = HookEnvelope(
            requestId: "r1", hookPid: 1, agent: "claude-code",
            event: HookEvent(
                sessionId: "s1", hookEventName: "Notification",
                cwd: "/tmp/proj", notificationType: "agent_needs_input"
            )
        )
        store.apply(blocked, at: t0 + 5)
        store.apply(envelope("Stop", backgroundTasks: [subagent]), at: t0 + 6)
        XCTAssertEqual(store.sessions["s1"]?.status, .waitingInput)
    }

    /// `idle_prompt` trails the end of every idle turn, including one that
    /// ended by delegating. It used to force idle regardless, which put out the
    /// light on a session whose agents were still running — the in-flight list
    /// survived, so the row showed "↳2" under a grey dot.
    func testIdlePromptDoesNotUndoDelegating() {
        var store = SessionStore()
        store.apply(envelope("SessionStart"), at: t0)
        store.apply(envelope("Stop", backgroundTasks: [subagent, shell]), at: t0 + 10)

        let idlePrompt = HookEnvelope(
            requestId: "r2", hookPid: 1, agent: "claude-code",
            event: HookEvent(
                sessionId: "s1", hookEventName: "Notification",
                cwd: "/tmp/proj", notificationType: "idle_prompt"
            )
        )
        store.apply(idlePrompt, at: t0 + 11)
        XCTAssertEqual(store.sessions["s1"]?.status, .delegating)
        XCTAssertEqual(store.sessions["s1"]?.backgroundTasks.count, 2)
    }

    func testIdlePromptStillIdlesASessionWithNothingInFlight() {
        var store = SessionStore()
        store.apply(envelope("SessionStart"), at: t0)
        let idlePrompt = HookEnvelope(
            requestId: "r2", hookPid: 1, agent: "claude-code",
            event: HookEvent(
                sessionId: "s1", hookEventName: "Notification",
                cwd: "/tmp/proj", notificationType: "idle_prompt"
            )
        )
        store.apply(idlePrompt, at: t0 + 5)
        XCTAssertEqual(store.sessions["s1"]?.status, .idle)
    }

    // MARK: - SubagentStop

    func testLastChildComingBackFinallyMakesTheSessionIdle() {
        var store = SessionStore()
        store.apply(envelope("SessionStart"), at: t0)
        store.apply(envelope("Stop", backgroundTasks: [subagent, shell]), at: t0 + 10)
        XCTAssertEqual(store.sessions["s1"]?.status, .delegating)

        store.apply(
            envelope("SubagentStop", agentId: "ag1", backgroundTasks: [shell]),
            at: t0 + 20
        )
        XCTAssertEqual(store.sessions["s1"]?.status, .delegating)
        XCTAssertEqual(store.sessions["s1"]?.backgroundTasks.map(\.id), ["sh1"])

        store.apply(
            envelope("SubagentStop", agentId: "ag2", backgroundTasks: []),
            at: t0 + 30
        )
        XCTAssertEqual(store.sessions["s1"]?.status, .idle)
        XCTAssertEqual(store.sessions["s1"]?.backgroundTasks, [])
    }

    /// A child finishing while the main loop is working says nothing about the
    /// main loop.
    func testSubagentStopLeavesARunningSessionRunning() {
        var store = SessionStore()
        store.apply(envelope("SessionStart"), at: t0)
        store.apply(
            envelope("SubagentStop", agentId: "ag1", backgroundTasks: []),
            at: t0 + 5
        )
        XCTAssertEqual(store.sessions["s1"]?.status, .running)
    }

    /// The closing words on a SubagentStop are the *subagent's*. Letting them
    /// through would overwrite the parent's handoff with a stranger's sentence.
    func testSubagentStopDoesNotOverwriteTheParentsHandoff() {
        var store = SessionStore()
        store.apply(envelope("SessionStart"), at: t0)
        store.apply(
            envelope("Stop", lastAssistantMessage: "Quer que eu commite?",
                     backgroundTasks: [subagent]),
            at: t0 + 10
        )
        store.apply(
            envelope("SubagentStop", agentId: "ag1",
                     lastAssistantMessage: "Answering Part 4 critique",
                     backgroundTasks: []),
            at: t0 + 20
        )
        XCTAssertEqual(store.sessions["s1"]?.lastAgentMessage, "Quer que eu commite?")
        XCTAssertTrue(store.sessions["s1"]?.handoffAsksSomething == true)
    }

    // MARK: - Subagent tool events

    func testSubagentToolCallAnnotatesItsOwnRow() {
        var store = SessionStore()
        store.apply(envelope("SessionStart"), at: t0)
        store.apply(envelope("Stop", backgroundTasks: [subagent]), at: t0 + 10)
        store.apply(
            envelope("PostToolUse", requestId: "r2", toolName: "Read",
                     toolInput: .object(["file_path": .string("/tmp/x.swift")]),
                     agentId: "ag1"),
            at: t0 + 20
        )
        XCTAssertNotNil(store.sessions["s1"]?.backgroundTasks.first?.lastAction)
        // The parent is untouched: still parked, still its own last action.
        XCTAssertEqual(store.sessions["s1"]?.status, .delegating)
        XCTAssertNil(store.sessions["s1"]?.lastAction)
        // …but the clock moved, which is the only live proof it is alive.
        XCTAssertEqual(store.sessions["s1"]?.lastEventAt, t0 + 20)
    }

    /// A subagent tool call must never resolve the parent's approval card —
    /// that gate belongs to the main thread.
    func testSubagentToolCallLeavesTheParentsPendingAlone() {
        var store = SessionStore()
        store.apply(envelope("SessionStart"), at: t0)
        store.apply(envelope("PermissionRequest", toolName: "Bash"), at: t0 + 5)
        store.apply(
            envelope("PostToolUse", requestId: "r2", toolName: "Read", agentId: "ag1"),
            at: t0 + 6
        )
        XCTAssertEqual(store.sessions["s1"]?.status, .waitingPermission)
        XCTAssertNotNil(store.sessions["s1"]?.pending)
    }

    func testSubagentToolCallForAnUnknownChildIsANoOp() {
        var store = SessionStore()
        store.apply(envelope("SessionStart"), at: t0)
        store.apply(
            envelope("PostToolUse", requestId: "r2", toolName: "Read", agentId: "ghost"),
            at: t0 + 5
        )
        XCTAssertEqual(store.sessions["s1"]?.backgroundTasks, [])
        XCTAssertEqual(store.sessions["s1"]?.status, .running)
    }

    // MARK: - Enrichment survives refreshes

    func testRefreshKeepsLiveActionAndResolvedModel() {
        var store = SessionStore()
        store.apply(envelope("SessionStart"), at: t0)
        store.apply(envelope("Stop", backgroundTasks: [subagent, shell]), at: t0 + 10)
        store.setSubagentModel("fable", agentId: "ag1", sessionId: "s1")
        store.apply(
            envelope("PostToolUse", requestId: "r2", toolName: "Read", agentId: "ag1"),
            at: t0 + 15
        )
        let action = store.sessions["s1"]?.backgroundTasks.first?.lastAction

        // Another child finishes: the payload reannounces the survivors, and
        // what Rocky learned about them must not be reset by it.
        store.apply(
            envelope("SubagentStop", agentId: "sh1", backgroundTasks: [subagent]),
            at: t0 + 20
        )
        XCTAssertEqual(store.sessions["s1"]?.backgroundTasks.first?.model, "fable")
        XCTAssertEqual(store.sessions["s1"]?.backgroundTasks.first?.lastAction, action)
    }

    // MARK: - Retention

    /// The idle window is a few minutes of click-to-jump; a delegating session
    /// would vanish mid-flight if it inherited that.
    /// Both halves resolve an agent PID so the only difference between them is
    /// the status — sessions without one take the observational branch and
    /// would survive either way, proving nothing.
    func testDelegatingSurvivesTheIdleRetentionWindow() {
        var store = SessionStore()
        store.apply(envelope("SessionStart"), at: t0)
        store.setAgentProcess(pid: 42, sessionId: "s1")
        store.apply(envelope("Stop", backgroundTasks: [subagent]), at: t0 + 10)
        store.pruneOrphans(now: t0 + store.idleRetentionTimeout + 60)
        XCTAssertEqual(store.sessions["s1"]?.status, .delegating)
    }

    func testIdleStillExpiresOnTheShortWindow() {
        var store = SessionStore()
        store.apply(envelope("SessionStart"), at: t0)
        store.setAgentProcess(pid: 42, sessionId: "s1")
        store.apply(envelope("Stop", backgroundTasks: []), at: t0 + 10)
        store.pruneOrphans(now: t0 + store.idleRetentionTimeout + 60)
        XCTAssertNil(store.sessions["s1"])
    }

    // MARK: - Event naming

    func testSubagentStopIsRecognizedInEitherSpelling() {
        XCTAssertEqual(HookEvent.Kind(name: "SubagentStop"), .subagentStop)
        XCTAssertEqual(HookEvent.Kind(name: "subagent_stop"), .subagentStop)
        XCTAssertEqual(HookEvent.Kind.canonical("subagent_stop"), "SubagentStop")
    }
}
