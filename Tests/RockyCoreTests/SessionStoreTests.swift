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
        agentId: String? = nil,
        lastAssistantMessage: String? = nil
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
                lastAssistantMessage: lastAssistantMessage,
                agentId: agentId
            )
        )
    }

    /// Approving at the terminal never reaches the blocked hook, so PostToolUse
    /// is the only evidence the gate is settled. Without it the card sat in the
    /// notch until the 55s decision timeout.
    func testPostToolUseClearsPendingApprovedAtTerminal() {
        var store = SessionStore()
        store.apply(envelope("SessionStart"), at: t0)
        store.apply(envelope("PermissionRequest", toolName: "Bash"), at: t0 + 1)
        XCTAssertEqual(store.sessions["s1"]?.status, .waitingPermission)

        store.apply(envelope("PostToolUse", requestId: "r2", toolName: "Bash"), at: t0 + 2)
        XCTAssertNil(store.sessions["s1"]?.pending)
        XCTAssertEqual(store.sessions["s1"]?.status, .running)
    }

    func testPostToolUseWithoutPendingLeavesStatusAlone() {
        var store = SessionStore()
        store.apply(envelope("SessionStart"), at: t0)
        store.apply(envelope("Notification", type: "agent_needs_input"), at: t0 + 1)
        XCTAssertEqual(store.sessions["s1"]?.status, .waitingInput)

        store.apply(envelope("PostToolUse", toolName: "Read"), at: t0 + 2)
        XCTAssertEqual(store.sessions["s1"]?.status, .waitingInput)
    }

    func testJumpTargetMergedFromEnvelope() {
        var store = SessionStore()
        let start = HookEnvelope(
            requestId: "r1",
            hookPid: 1,
            agent: "claude-code",
            event: HookEvent(sessionId: "s1", hookEventName: "SessionStart", cwd: "/tmp/proj"),
            jumpTarget: JumpTarget(terminalApp: "Warp", terminalTTY: "/dev/ttys001")
        )
        store.apply(start, at: t0)
        XCTAssertEqual(store.sessions["s1"]?.jumpTarget?.terminalApp, "Warp")
        XCTAssertEqual(store.sessions["s1"]?.jumpTarget?.terminalTTY, "/dev/ttys001")

        // Later event refines with Warp pane UUID without dropping earlier fields.
        let refined = HookEnvelope(
            requestId: "r2",
            hookPid: 1,
            agent: "claude-code",
            event: HookEvent(sessionId: "s1", hookEventName: "UserPromptSubmit", cwd: "/tmp/proj"),
            jumpTarget: JumpTarget(warpPaneUUID: "DEADBEEF")
        )
        store.apply(refined, at: t0 + 1)
        XCTAssertEqual(store.sessions["s1"]?.jumpTarget?.terminalApp, "Warp")
        XCTAssertEqual(store.sessions["s1"]?.jumpTarget?.terminalTTY, "/dev/ttys001")
        XCTAssertEqual(store.sessions["s1"]?.jumpTarget?.warpPaneUUID, "DEADBEEF")
    }

    func testGhosttySessionIDPreservedAcrossUnsafeHook() {
        var store = SessionStore()
        let start = HookEnvelope(
            requestId: "r1",
            hookPid: 1,
            agent: "claude-code",
            event: HookEvent(sessionId: "s1", hookEventName: "SessionStart", cwd: "/tmp/proj"),
            jumpTarget: JumpTarget(
                terminalApp: "Ghostty",
                workingDirectory: "/tmp/proj",
                terminalSessionID: "surface-abc"
            )
        )
        store.apply(start, at: t0)
        XCTAssertEqual(store.sessions["s1"]?.jumpTarget?.terminalSessionID, "surface-abc")

        // PreToolUse probe intentionally omits surface id (unsafe event).
        let tool = HookEnvelope(
            requestId: "r2",
            hookPid: 1,
            agent: "claude-code",
            event: HookEvent(
                sessionId: "s1",
                hookEventName: "PreToolUse",
                cwd: "/tmp/proj",
                toolName: "Bash"
            ),
            jumpTarget: JumpTarget(terminalApp: "Ghostty", workingDirectory: "/tmp/proj")
        )
        store.apply(tool, at: t0 + 1)
        XCTAssertEqual(
            store.sessions["s1"]?.jumpTarget?.terminalSessionID,
            "surface-abc",
            "merge must keep Ghostty surface id when later hooks leave it nil"
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

    /// Grok dual-loads `~/.claude/settings.json` hooks (compat.claude).
    /// SessionStart often arrives as claude-code first, then grok — the chip
    /// must upgrade to Grok instead of sticking on Claude.
    func testGrokClaudeCompatDualFireUpgradesAgentLabel() {
        var store = SessionStore()
        store.apply(envelope("SessionStart"), at: t0) // agent: claude-code
        XCTAssertEqual(store.sessions["s1"]?.agent, "claude-code")

        let grokStart = HookEnvelope(
            requestId: "r-g",
            hookPid: 2,
            agent: "grok",
            event: HookEvent(
                sessionId: "s1",
                hookEventName: "SessionStart",
                cwd: "/tmp/proj"
            )
        )
        store.apply(grokStart, at: t0 + 0.01)
        XCTAssertEqual(store.sessions["s1"]?.agent, "grok")

        // Later Claude-compat PostToolUse must not demote the label.
        store.apply(envelope("PostToolUse", requestId: "r-pt", toolName: "Read"), at: t0 + 1)
        XCTAssertEqual(store.sessions["s1"]?.agent, "grok")
    }

    func testPreferredAgentNeverDemotesAwayFromGrok() {
        XCTAssertEqual(
            SessionStore.preferredAgent(current: "grok", incoming: "claude-code"),
            "grok"
        )
        XCTAssertEqual(
            SessionStore.preferredAgent(current: "claude-code", incoming: "grok"),
            "grok"
        )
        XCTAssertEqual(
            SessionStore.preferredAgent(current: "claude-code", incoming: "claude-code"),
            "claude-code"
        )
        XCTAssertEqual(
            SessionStore.preferredAgent(current: "cursor", incoming: "claude-code"),
            "cursor"
        )
    }

    /// Only an explicit "the agent is blocked" signal may claim the user's
    /// attention. idle_prompt fires at the end of every idle turn, so treating
    /// it as "needs you" would paint every finished session amber and bury the
    /// ones that genuinely are.
    func testNotificationTypes() {
        var store = SessionStore()
        store.apply(envelope("SessionStart"), at: t0)
        store.apply(envelope("Notification", type: "idle_prompt"), at: t0 + 1)
        XCTAssertEqual(store.sessions["s1"]?.status, .idle)
        XCTAssertNil(store.sessions["s1"]?.waitingInputReason)

        store.apply(envelope("Notification", type: "agent_needs_input"), at: t0 + 2)
        XCTAssertEqual(store.sessions["s1"]?.status, .waitingInput)
        XCTAssertEqual(store.sessions["s1"]?.waitingInputReason, .agentNeedsInput)

        store.apply(envelope("UserPromptSubmit"), at: t0 + 3)
        store.apply(envelope("Notification", type: "elicitation_dialog"), at: t0 + 4)
        XCTAssertEqual(store.sessions["s1"]?.status, .waitingInput)
        XCTAssertEqual(store.sessions["s1"]?.waitingInputReason, .elicitation)

        // permission_prompt is redundant with PermissionRequest — no change.
        store.apply(envelope("UserPromptSubmit"), at: t0 + 5)
        store.apply(envelope("Notification", type: "permission_prompt"), at: t0 + 6)
        XCTAssertEqual(store.sessions["s1"]?.status, .running)
    }

    // MARK: - Agent handoff message

    /// The whole point: the notch can show what the agent left the user with
    /// ("Want me to commit?") instead of a bare "done" they have to open a
    /// terminal to decode.
    func testStopCapturesTheAgentsClosingMessage() {
        var store = SessionStore()
        store.apply(envelope("SessionStart"), at: t0)
        store.apply(
            envelope("Stop", lastAssistantMessage: "Tests pass. Want me to commit?"),
            at: t0 + 1
        )
        XCTAssertEqual(store.sessions["s1"]?.lastAgentMessage, "Tests pass. Want me to commit?")
        XCTAssertEqual(store.sessions["s1"]?.status, .idle)
    }

    /// Agents that don't hand us the text stay blank rather than guess.
    func testStopWithoutMessageLeavesHandoffEmpty() {
        var store = SessionStore()
        store.apply(envelope("SessionStart"), at: t0)
        store.apply(envelope("Stop"), at: t0 + 1)
        XCTAssertNil(store.sessions["s1"]?.lastAgentMessage)
    }

    /// Stop fires at the end of every turn, including one the agent ended
    /// blocked. It must not erase a wait that arrived just before it.
    func testStopDoesNotOverwriteAnExplicitWait() {
        var store = SessionStore()
        store.apply(envelope("SessionStart"), at: t0)
        store.apply(envelope("Notification", type: "agent_needs_input"), at: t0 + 1)
        store.apply(envelope("Stop", lastAssistantMessage: "Which environment?"), at: t0 + 2)
        XCTAssertEqual(store.sessions["s1"]?.status, .waitingInput)
        XCTAssertEqual(store.sessions["s1"]?.waitingInputReason, .agentNeedsInput)
        XCTAssertEqual(store.sessions["s1"]?.lastAgentMessage, "Which environment?")
    }

    /// The user answered, so the handoff is spent.
    func testNewPromptClearsTheHandoff() {
        var store = SessionStore()
        store.apply(envelope("SessionStart"), at: t0)
        store.apply(envelope("Notification", type: "agent_needs_input"), at: t0 + 1)
        store.apply(envelope("Stop", lastAssistantMessage: "Want me to commit?"), at: t0 + 2)

        store.apply(envelope("UserPromptSubmit"), at: t0 + 3)
        XCTAssertNil(store.sessions["s1"]?.lastAgentMessage)
        XCTAssertNil(store.sessions["s1"]?.waitingInputReason)
        XCTAssertEqual(store.sessions["s1"]?.status, .running)
    }

    /// Agents narrate what they did first and ask last, so the preview must
    /// show the end of the message — the opening is recap the user doesn't
    /// need to act on.
    func testDisplayAgentMessageKeepsTheClosingWords() throws {
        XCTAssertEqual(
            SessionStore.displayAgentMessage(
                from: "I refactored the parser.\n\n- split the lexer\n\nLet me know and I'll commit."
            ),
            "Let me know and I'll commit."
        )
        // Whitespace inside the closing line collapses.
        XCTAssertEqual(
            SessionStore.displayAgentMessage(from: "Done.\n\n  Want me to\tcommit?  "),
            "Want me to commit?"
        )
        // Tables/rules/fences are layout, not the message.
        XCTAssertEqual(
            SessionStore.displayAgentMessage(
                from: "Results:\n\nWaiting on you to proceed.\n\n| file | ok |\n| --- | --- |"
            ),
            "Waiting on you to proceed."
        )
        // Blank and nil produce no handoff, so the row falls back to "done".
        XCTAssertNil(SessionStore.displayAgentMessage(from: "   \n  "))
        XCTAssertNil(SessionStore.displayAgentMessage(from: nil))
    }

    /// Agents write markdown for a rendered terminal; in a one-line chip the
    /// syntax is pure noise.
    func testDisplayAgentMessageStripsMarkdownNoise() {
        XCTAssertEqual(
            SessionStore.displayAgentMessage(from: "**No projeto atual, qual te trava?**"),
            "No projeto atual, qual te trava?"
        )
        XCTAssertEqual(
            SessionStore.displayAgentMessage(from: "- Did not verify `web-app` consumption"),
            "Did not verify web-app consumption"
        )
        XCTAssertEqual(
            SessionStore.displayAgentMessage(from: "10. Run the __shadow__ check"),
            "Run the shadow check"
        )
        XCTAssertEqual(
            SessionStore.displayAgentMessage(from: "See [the docs](https://example.com/x) first"),
            "See the docs first"
        )
        // Identifiers and arithmetic must survive: unwrapping single
        // delimiters would mangle them.
        XCTAssertEqual(
            SessionStore.displayAgentMessage(from: "Renamed some_var and set n = 2 * 3"),
            "Renamed some_var and set n = 2 * 3"
        )
    }

    /// The notch row truncates again on width, so the preview must read from
    /// its start — anchoring at the end leaves the reader with the middle of a
    /// sentence once both cuts apply.
    func testDisplayAgentMessageReadsFromTheStartOfTheClosingLine() throws {
        let long = "Want me to apply the fixes? " + String(repeating: "detail ", count: 60)
        let shown = try XCTUnwrap(SessionStore.displayAgentMessage(from: long))
        XCTAssertEqual(shown.count, 140)
        XCTAssertTrue(shown.hasPrefix("Want me to apply the fixes?"))
        XCTAssertTrue(shown.hasSuffix("…"))
    }

    /// A finished turn that left words behind is worth reading, so it outlives
    /// a bare "done" row.
    func testHandoffOutlivesABareDoneRow() {
        var store = SessionStore()
        store.apply(envelope("SessionStart"), at: t0)
        store.setAgentProcess(pid: 99, sessionId: "s1")
        store.apply(envelope("Stop", lastAssistantMessage: "Want me to commit?"), at: t0 + 1)

        store.pruneOrphans(now: t0 + 1 + 10 * 60)
        XCTAssertNotNil(store.sessions["s1"], "past the 5m bare-done window")

        store.pruneOrphans(now: t0 + 1 + 16 * 60)
        XCTAssertNil(store.sessions["s1"], "but still bounded")
    }

    /// Punctuation, not vocabulary — the same check has to work whatever
    /// language the agent replied in.
    func testAsksSomethingReadsPunctuationNotWords() {
        XCTAssertTrue(SessionStore.asksSomething("Quer que eu aplique os 3 P1?"))
        XCTAssertTrue(SessionStore.asksSomething("Should I commit this?"))
        XCTAssertTrue(SessionStore.asksSomething("¿Aplico los cambios?"))
        XCTAssertTrue(SessionStore.asksSomething("现在提交吗？"))
        // Asks phrased as statements stay neutral rather than guess.
        XCTAssertFalse(SessionStore.asksSomething("Let me know and I'll commit."))
        XCTAssertFalse(SessionStore.asksSomething("Me avise que faço o commit."))
        XCTAssertFalse(SessionStore.asksSomething(nil))
    }

    /// The hint is computed on the full closing line, so a question mark that
    /// falls past the display truncation still counts.
    func testQuestionHintSurvivesTruncation() {
        var store = SessionStore()
        store.apply(envelope("SessionStart"), at: t0)
        let long = "Quer que eu aplique " + String(repeating: "os itens ", count: 40) + "agora?"
        store.apply(envelope("Stop", lastAssistantMessage: long), at: t0 + 1)

        let session = store.sessions["s1"]
        XCTAssertEqual(session?.handoffAsksSomething, true)
        XCTAssertEqual(session?.lastAgentMessage?.hasSuffix("…"), true, "display text is cut")
    }

    func testNewPromptClearsTheQuestionHint() {
        var store = SessionStore()
        store.apply(envelope("SessionStart"), at: t0)
        store.apply(envelope("Stop", lastAssistantMessage: "Commit?"), at: t0 + 1)
        XCTAssertEqual(store.sessions["s1"]?.handoffAsksSomething, true)

        store.apply(envelope("UserPromptSubmit"), at: t0 + 2)
        XCTAssertEqual(store.sessions["s1"]?.handoffAsksSomething, false)
    }

    /// idle_prompt confirms the turn ended, but must never pull a session out
    /// of an explicit wait that arrived before it.
    func testIdlePromptDoesNotDowngradeAnExplicitWait() {
        var store = SessionStore()
        store.apply(envelope("SessionStart"), at: t0)
        store.apply(envelope("Notification", type: "agent_needs_input"), at: t0 + 1)
        store.apply(envelope("Notification", type: "idle_prompt"), at: t0 + 2)
        XCTAssertEqual(store.sessions["s1"]?.status, .waitingInput)
        XCTAssertEqual(store.sessions["s1"]?.waitingInputReason, .agentNeedsInput)
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

    func testPruneDeadHostsDropsWhenAgentNameNoLongerMatches() {
        // PID reused by an unrelated process after the agent exits.
        var store = SessionStore()
        store.apply(
            HookEnvelope(
                requestId: "r", hookPid: 1, agent: "codex",
                event: HookEvent(sessionId: "c1", hookEventName: "SessionStart", cwd: "/tmp")
            ),
            at: t0
        )
        store.setTerminalApp(pid: 100, sessionId: "c1")
        store.setAgentProcess(pid: 200, sessionId: "c1")

        let abandoned = store.pruneDeadHosts(
            isAgentAlive: { _, _ in false }, // name no longer matches / dead
            isHostAlive: { $0 == 100 }
        )
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

    func testIdleSessionsPrunedAfterShortRetention() {
        // Stop without SessionEnd (Codex/Grok): card must not stick until 2h.
        var store = SessionStore()
        store.apply(envelope("SessionStart"), at: t0)
        store.setAgentProcess(pid: 99, sessionId: "s1")
        store.apply(envelope("Stop"), at: t0 + 1)

        store.pruneOrphans(now: t0 + 1 + 4 * 60)
        XCTAssertNotNil(store.sessions["s1"], "still inside 5m click-to-jump window")

        store.pruneOrphans(now: t0 + 1 + 6 * 60)
        XCTAssertNil(store.sessions["s1"])
    }

    /// A session the agent reported as blocked must survive the user stepping
    /// away — expiring it after a few minutes defeats the whole state.
    func testExplicitWaitingInputSurvivesTheUserSteppingAway() {
        var store = SessionStore()
        store.apply(envelope("SessionStart"), at: t0)
        store.setAgentProcess(pid: 99, sessionId: "s1")
        store.apply(envelope("Notification", type: "agent_needs_input"), at: t0 + 1)

        store.pruneOrphans(now: t0 + 1 + 45 * 60)
        XCTAssertNotNil(store.sessions["s1"], "must outlive a lunch break")

        // Still bounded: the orphan timeout is the backstop.
        store.pruneOrphans(now: t0 + 1 + 3 * 60 * 60)
        XCTAssertNil(store.sessions["s1"])
    }

    /// The untracked leash still wins: with no agent PID we cannot see the CLI
    /// exit, so a waiting session must not linger for hours.
    func testUntrackedWaitingSessionStillCappedByShortLeash() {
        var store = SessionStore()
        store.apply(envelope("SessionStart"), at: t0)  // no setAgentProcess
        store.apply(envelope("Notification", type: "agent_needs_input"), at: t0 + 1)

        store.pruneOrphans(now: t0 + 1 + 10 * 60)
        XCTAssertNotNil(store.sessions["s1"])

        store.pruneOrphans(now: t0 + 1 + 16 * 60)
        XCTAssertNil(store.sessions["s1"], "capped by untrackedAgentTimeout")
    }

    func testUntrackedAgentPrunedSoonerThanFullOrphan() {
        // SessionStart only, agent PID never resolved, process already gone.
        var store = SessionStore()
        store.apply(
            HookEnvelope(
                requestId: "r", hookPid: 1, agent: "codex",
                event: HookEvent(sessionId: "c1", hookEventName: "SessionStart", cwd: "/tmp")
            ),
            at: t0
        )
        // No setAgentProcess — untracked.
        store.pruneOrphans(now: t0 + 14 * 60)
        XCTAssertNotNil(store.sessions["c1"])

        store.pruneOrphans(now: t0 + 16 * 60)
        XCTAssertNil(store.sessions["c1"])
    }

    func testUntrackedTimeoutDoesNotApplyToCursor() {
        var store = SessionStore()
        store.apply(
            HookEnvelope(
                requestId: "r", hookPid: 1, agent: "cursor",
                event: HookEvent(sessionId: "cur", hookEventName: "SessionStart", cwd: "/tmp")
            ),
            at: t0
        )
        // Cursor has no separate CLI PID; use full orphan window, not untracked.
        store.pruneOrphans(now: t0 + 20 * 60)
        XCTAssertNotNil(store.sessions["cur"])

        store.pruneOrphans(now: t0 + 3 * 60 * 60)
        XCTAssertNil(store.sessions["cur"])
    }

    func testPendingSurvivesAllRetentionTimeouts() {
        var store = SessionStore()
        store.apply(envelope("PermissionRequest", toolName: "Bash"), at: t0)
        store.pruneOrphans(now: t0 + 3 * 60 * 60)
        XCTAssertNotNil(store.sessions["s1"]?.pending)
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

    /// OpenCode has no transcript to tail; live activity comes from PostToolUse.
    func testOpenCodePostToolUseSetsLiveActivity() {
        var store = SessionStore()
        store.apply(
            HookEnvelope(
                hookPid: 1, agent: "opencode",
                event: HookEvent(sessionId: "oc", hookEventName: "SessionStart", cwd: "/tmp")
            ),
            at: t0
        )
        store.apply(
            HookEnvelope(
                hookPid: 1, agent: "opencode",
                event: HookEvent(
                    sessionId: "oc",
                    hookEventName: "PostToolUse",
                    toolName: "bash",
                    toolInput: .object(["command": .string("npm test")])
                )
            ),
            at: t0.addingTimeInterval(1)
        )
        XCTAssertNotNil(store.sessions["oc"]?.lastAction)
        XCTAssertTrue(store.sessions["oc"]?.lastAction?.contains("npm test") == true
            || store.sessions["oc"]?.lastAction?.lowercased().contains("bash") == true)
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

    /// The row that wants the user must be findable without scanning past the
    /// ones still happily working — recency alone buries it.
    func testSessionsNeedingTheUserSortFirst() {
        var store = SessionStore()
        // Asked a question a while ago, then kept being pushed down by others.
        store.apply(envelope("SessionStart", session: "asked"), at: t0)
        store.apply(
            envelope("Stop", session: "asked", lastAssistantMessage: "Commit?"),
            at: t0 + 1
        )
        // Busy and recent.
        store.apply(envelope("SessionStart", session: "busy"), at: t0 + 50)
        // Explicitly blocked, older than "busy".
        store.apply(envelope("SessionStart", session: "blocked"), at: t0 + 10)
        store.apply(
            envelope("Notification", session: "blocked", type: "agent_needs_input"),
            at: t0 + 11
        )

        XCTAssertEqual(store.ordered.map(\.id), ["blocked", "asked", "busy"])
    }

    func testOrderingIsStableForEquallyRankedSessions() {
        var store = SessionStore()
        store.apply(envelope("SessionStart", session: "b"), at: t0)
        store.apply(envelope("SessionStart", session: "a"), at: t0)
        // Same rank and same timestamp — id breaks the tie deterministically.
        XCTAssertEqual(store.ordered.map(\.id), ["a", "b"])
    }

    /// Kimi has no transcript to tail, so its live activity is derived from the
    /// PostToolUse event — the notch shows what an autonomous session is doing.
    func testKimiPostToolUseSetsLiveActivity() {
        var store = SessionStore()
        let start = HookEnvelope(
            hookPid: 1, agent: "kimi-code",
            event: HookEvent(sessionId: "k1", hookEventName: "SessionStart", cwd: "/tmp/p")
        )
        store.apply(start, at: t0)

        let post = HookEnvelope(
            hookPid: 1, agent: "kimi-code",
            event: HookEvent(
                sessionId: "k1", hookEventName: "PostToolUse",
                toolName: "Bash", toolInput: .object(["command": .string("npm test")])
            )
        )
        store.apply(post, at: t0 + 1)
        XCTAssertEqual(store.sessions["k1"]?.lastAction, "running npm test")
    }

    /// The PostToolUse activity is Kimi-scoped: other agents keep getting their
    /// activity from the transcript, so this must not start setting it for them.
    func testNonKimiPostToolUseLeavesActivityUnset() {
        var store = SessionStore()
        store.apply(envelope("SessionStart"), at: t0) // agent: claude-code
        store.apply(envelope("PostToolUse", toolName: "Bash"), at: t0 + 1)
        XCTAssertNil(store.sessions["s1"]?.lastAction)
    }
}
