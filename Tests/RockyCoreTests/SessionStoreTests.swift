import XCTest
@testable import RockyCore

final class SessionStoreTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func envelope(
        _ name: String,
        session: String = "s1",
        requestId: String = "r1",
        type: String? = nil,
        toolName: String? = nil,
        agentId: String? = nil
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
                notificationType: type,
                agentId: agentId
            )
        )
    }

    func testLifecycle() {
        var store = SessionStore()
        store.apply(envelope("SessionStart"), at: t0)
        XCTAssertEqual(store.sessions["s1"]?.status, .running)

        store.apply(envelope("PermissionRequest", toolName: "Bash"), at: t0 + 1)
        XCTAssertEqual(store.sessions["s1"]?.status, .waitingPermission)
        XCTAssertEqual(store.sessions["s1"]?.pending?.toolName, "Bash")

        store.resolvePending(requestId: "r1", at: t0 + 2)
        XCTAssertEqual(store.sessions["s1"]?.status, .running)
        XCTAssertNil(store.sessions["s1"]?.pending)

        store.apply(envelope("Stop"), at: t0 + 3)
        XCTAssertEqual(store.sessions["s1"]?.status, .idle)

        store.apply(envelope("SessionEnd"), at: t0 + 4)
        XCTAssertNil(store.sessions["s1"])
    }

    func testPermissionRequestWithoutSessionStartCreatesSession() {
        var store = SessionStore()
        store.apply(envelope("PermissionRequest", toolName: "Edit"), at: t0)
        XCTAssertEqual(store.sessions["s1"]?.status, .waitingPermission)
    }

    func testGrokPreToolUseMapsToPermissionWait() {
        var store = SessionStore()
        let env = HookEnvelope(
            requestId: "r-grok",
            hookPid: 1,
            agent: "grok",
            event: HookEvent(
                sessionId: "s1",
                hookEventName: "pre_tool_use",
                cwd: "/tmp/proj",
                toolName: "run_terminal_command",
                toolInput: .object(["command": .string("ls")])
            )
        )
        store.apply(env, at: t0)
        XCTAssertEqual(store.sessions["s1"]?.agent, "grok")
        XCTAssertEqual(store.sessions["s1"]?.status, .waitingPermission)
        XCTAssertEqual(store.sessions["s1"]?.pending?.toolName, "run_terminal_command")
    }

    func testNotificationTypes() {
        var store = SessionStore()
        store.apply(envelope("SessionStart"), at: t0)
        store.apply(envelope("Notification", type: "idle_prompt"), at: t0 + 1)
        XCTAssertEqual(store.sessions["s1"]?.status, .waitingInput)

        // permission_prompt is redundant with PermissionRequest — no change.
        store.apply(envelope("SessionStart"), at: t0 + 2)
        store.apply(envelope("Notification", type: "permission_prompt"), at: t0 + 3)
        XCTAssertEqual(store.sessions["s1"]?.status, .running)
    }

    func testSubagentEventsIgnored() {
        var store = SessionStore()
        store.apply(envelope("SessionStart", agentId: "sub-1"), at: t0)
        XCTAssertTrue(store.sessions.isEmpty)
    }

    func testPruneDeadHostsDropsSessionsWithDeadPid() {
        var store = SessionStore()
        store.apply(envelope("SessionStart", session: "live"), at: t0)
        store.apply(envelope("SessionStart", session: "dead"), at: t0)
        store.setTerminalApp(pid: 100, sessionId: "live")
        store.setTerminalApp(pid: 200, sessionId: "dead")

        let abandoned = store.pruneDeadHosts { pid in pid == 100 }
        XCTAssertEqual(Set(store.sessions.keys), ["live"])
        XCTAssertTrue(abandoned.isEmpty)
    }

    func testPruneDeadHostsDropsWhenAgentProcessDiesButTerminalLives() {
        // Codex Ctrl+C: agent CLI exits, Warp (terminalAppPid) stays up.
        var store = SessionStore()
        store.apply(envelope("SessionStart", session: "codex-1"), at: t0)
        store.setTerminalApp(pid: 100, sessionId: "codex-1")
        store.setAgentProcess(pid: 200, sessionId: "codex-1")

        let abandoned = store.pruneDeadHosts { pid in pid == 100 } // only Warp alive
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertTrue(abandoned.isEmpty)
    }

    func testPruneDeadHostsReturnsPendingRequestIds() {
        var store = SessionStore()
        store.apply(
            envelope("PermissionRequest", session: "s1", requestId: "req-dead", toolName: "Bash"),
            at: t0
        )
        store.setTerminalApp(pid: 9, sessionId: "s1")
        let abandoned = store.pruneDeadHosts { _ in false }
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertEqual(abandoned, ["req-dead"])
    }

    func testRemoveSessionsByAgent() {
        var store = SessionStore()
        store.apply(
            HookEnvelope(
                requestId: "r", hookPid: 1, agent: "cursor",
                event: HookEvent(sessionId: "c1", hookEventName: "SessionStart", cwd: "/tmp")
            ),
            at: t0
        )
        store.apply(
            HookEnvelope(
                requestId: "r2", hookPid: 1, agent: "claude-code",
                event: HookEvent(sessionId: "cl", hookEventName: "SessionStart", cwd: "/tmp")
            ),
            at: t0
        )
        let abandoned = store.removeSessions(agent: "cursor")
        XCTAssertNil(store.sessions["c1"])
        XCTAssertNotNil(store.sessions["cl"])
        XCTAssertTrue(abandoned.isEmpty)
    }

    func testRemoveSessionsByAgentHonorsPredicate() {
        // Cursor-app-quit net only sweeps sessions with no resolved host PID.
        var store = SessionStore()
        store.apply(
            HookEnvelope(
                requestId: "r", hookPid: 1, agent: "cursor",
                event: HookEvent(sessionId: "gui", hookEventName: "SessionStart", cwd: "/tmp")
            ),
            at: t0
        )
        store.apply(
            HookEnvelope(
                requestId: "r2", hookPid: 1, agent: "cursor",
                event: HookEvent(sessionId: "cli", hookEventName: "SessionStart", cwd: "/tmp")
            ),
            at: t0
        )
        // "cli" is hosted by a live terminal; "gui" never resolved a host PID.
        store.setTerminalApp(pid: 4242, sessionId: "cli")

        store.removeSessions(agent: "cursor") { $0.terminalAppPid == nil }
        XCTAssertNil(store.sessions["gui"])
        XCTAssertNotNil(store.sessions["cli"])
    }

    func testOrphanPruning() {
        var store = SessionStore()
        store.apply(envelope("SessionStart"), at: t0)
        store.apply(envelope("PermissionRequest", session: "s2", requestId: "r2"), at: t0)

        store.pruneOrphans(now: t0 + 3 * 60 * 60)
        // s1 is stale and dropped; s2 has a pending request and survives.
        XCTAssertNil(store.sessions["s1"])
        XCTAssertNotNil(store.sessions["s2"])
    }

    func testActiveTimeAccumulatesWithCappedGaps() {
        var store = SessionStore()
        store.apply(envelope("SessionStart"), at: t0)
        store.apply(envelope("Stop"), at: t0 + 120)
        // Long overnight gap counts only the 5-minute cap.
        store.apply(envelope("UserPromptSubmit"), at: t0 + 120 + 8 * 60 * 60)
        XCTAssertEqual(store.sessions["s1"]?.activeSeconds, 120 + 5 * 60)
    }

    func testTokensAccumulate() {
        var store = SessionStore()
        store.apply(envelope("SessionStart"), at: t0)
        store.addTokens(150, sessionId: "s1")
        store.addTokens(50, sessionId: "s1")
        store.addTokens(-10, sessionId: "s1")
        XCTAssertEqual(store.sessions["s1"]?.tokens, 200)
    }

    func testUserPromptSetsTask() throws {
        var store = SessionStore()
        let env = HookEnvelope(
            requestId: "r", hookPid: 1, agent: "claude-code",
            event: HookEvent(
                sessionId: "s1", hookEventName: "UserPromptSubmit",
                cwd: "/tmp/p", prompt: "fix the auth bug\nin middleware"
            )
        )
        store.apply(env, at: t0)
        XCTAssertEqual(store.sessions["s1"]?.status, .running)
        XCTAssertEqual(store.sessions["s1"]?.task, "fix the auth bug in middleware")
    }

    func testGrokUserQueryTagsStrippedFromTask() {
        var store = SessionStore()
        let env = HookEnvelope(
            requestId: "r", hookPid: 1, agent: "grok",
            event: HookEvent(
                sessionId: "s1", hookEventName: "UserPromptSubmit",
                cwd: "/tmp/p",
                prompt: "<user_query>\nsem fazer nada, seria possivel dar suporte ao cursor?\n</user_query>"
            )
        )
        store.apply(env, at: t0)
        XCTAssertEqual(
            store.sessions["s1"]?.task,
            "sem fazer nada, seria possivel dar suporte ao cursor?"
        )
    }

    func testDisplayTaskStripsOrphanUserQueryTag() {
        XCTAssertEqual(
            SessionStore.displayTask(from: "<user_query> short ask"),
            "short ask"
        )
        XCTAssertEqual(
            SessionStore.displayTask(from: "plain prompt"),
            "plain prompt"
        )
        // Truncation after strip so tags don't burn the budget.
        let long = String(repeating: "a", count: 120)
        let task = SessionStore.displayTask(
            from: "<user_query>\n\(long)\n</user_query>"
        )
        XCTAssertFalse(task.contains("user_query"))
        XCTAssertTrue(task.hasSuffix("…"))
        XCTAssertEqual(task.count, 100)
    }

    func testOrderedByRecency() {
        var store = SessionStore()
        store.apply(envelope("SessionStart", session: "old"), at: t0)
        store.apply(envelope("SessionStart", session: "new"), at: t0 + 10)
        XCTAssertEqual(store.ordered.map(\.id), ["new", "old"])
    }
}
