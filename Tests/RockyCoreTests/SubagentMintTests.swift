import XCTest
@testable import RockyCore

/// The in-flight list only ships on `Stop`/`SubagentStop`, so a subagent
/// spawned mid-turn used to be invisible for exactly as long as it ran.
/// `SubagentStart` (or, under an old hook snapshot, the child's first tool
/// call) lets the hub mint the row while the work is live; the list stays
/// authoritative for removal. These tests pin the store half of that deal.
final class SubagentMintTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func envelope(
        _ name: String,
        session: String = "s1",
        agentId: String? = nil,
        agentType: String? = nil,
        backgroundTasks: [BackgroundTask]? = nil
    ) -> HookEnvelope {
        HookEnvelope(
            requestId: "r1",
            hookPid: 1,
            agent: "claude-code",
            event: HookEvent(
                sessionId: session,
                hookEventName: name,
                cwd: "/tmp/proj",
                agentId: agentId,
                agentType: agentType,
                backgroundTasks: backgroundTasks
            )
        )
    }

    func mint(
        _ store: inout SessionStore,
        agentId: String = "ag1",
        agentType: String? = "Explore",
        description: String? = "Map the import pipeline",
        model: String? = nil,
        parent: String? = nil,
        at date: Date? = nil
    ) {
        store.mintSubagent(
            sessionId: "s1",
            agentId: agentId,
            agentType: agentType,
            description: description,
            model: model,
            parentAgentId: parent,
            at: date ?? t0 + 5
        )
    }

    // MARK: - Event plumbing

    func testSubagentStartParsesAsItsOwnKind() {
        XCTAssertEqual(HookEvent.Kind(name: "SubagentStart"), .subagentStart)
        XCTAssertEqual(HookEvent.Kind.canonical("subagent_start"), "SubagentStart")
        XCTAssertEqual(HookEvent.Kind.canonical("subagentstart"), "SubagentStart")
    }

    func testSubagentStartPayloadDecodes() throws {
        let json = """
        {"session_id":"s1","hook_event_name":"SubagentStart",
         "agent_id":"ag1","agent_type":"Explore",
         "transcript_path":"/tmp/t/s1.jsonl"}
        """
        let event = try JSONDecoder().decode(HookEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.kind, .subagentStart)
        XCTAssertEqual(event.agentId, "ag1")
        XCTAssertEqual(event.agentType, "Explore")
        XCTAssertEqual(event.transcriptPath, "/tmp/t/s1.jsonl")
    }

    /// The spawn signal never enters the state machine: no session is created
    /// for it, and an existing one is left exactly as it was.
    func testSubagentStartNeverTouchesSessionState() {
        var store = SessionStore()
        store.apply(envelope("SubagentStart", agentId: "ag1"), at: t0)
        XCTAssertTrue(store.sessions.isEmpty)

        store.apply(envelope("SessionStart"), at: t0)
        let before = store.sessions["s1"]
        store.apply(envelope("SubagentStart", agentId: "ag1"), at: t0 + 1)
        XCTAssertEqual(store.sessions["s1"], before)
    }

    // MARK: - Minting

    func testMintAddsARowToARunningSession() {
        var store = SessionStore()
        store.apply(envelope("SessionStart"), at: t0)
        mint(&store)
        let session = store.sessions["s1"]
        XCTAssertEqual(session?.backgroundTasks.map(\.id), ["ag1"])
        XCTAssertEqual(session?.backgroundTasks.first?.kind, "subagent")
        XCTAssertEqual(session?.backgroundTasks.first?.agentType, "Explore")
        XCTAssertEqual(
            session?.backgroundTasks.first?.description,
            "Map the import pipeline"
        )
        // Minting adds a row, never a state: the main loop is still mid-turn.
        XCTAssertEqual(session?.status, .running)
    }

    func testMintIntoAMissingSessionIsANoOp() {
        var store = SessionStore()
        mint(&store)
        XCTAssertTrue(store.sessions.isEmpty)
    }

    /// A row the payload already announced wins: the mint only fills what is
    /// missing, and never disturbs what the live events wrote.
    func testMintOnAnExistingRowFillsOnlyMissingFields() {
        var store = SessionStore()
        store.apply(envelope("SessionStart"), at: t0)
        var announced = BackgroundTask(
            id: "ag1",
            kind: "subagent",
            status: "running",
            description: "Payload description",
            agentType: "general-purpose"
        )
        announced.lastAction = "Bash: npm test"
        store.apply(
            envelope("Stop", backgroundTasks: [announced]),
            at: t0 + 1
        )
        mint(&store, description: "Sidecar description", model: "fable", parent: "ag0")
        let task = store.sessions["s1"]?.backgroundTasks.first
        XCTAssertEqual(task?.description, "Payload description")
        XCTAssertEqual(task?.lastAction, "Bash: npm test")
        XCTAssertEqual(task?.model, "fable")
        // ag0 is not in the list, so it renders at top level — but the edge is
        // recorded for the moment the parent is announced.
        XCTAssertEqual(task?.parentAgentId, "ag0")
    }

    /// The tool call that triggered a fallback mint had no row to land on;
    /// carrying it in keeps the row from starting blank until the next one.
    func testMintCarriesTheTriggeringAction() {
        var store = SessionStore()
        store.apply(envelope("SessionStart"), at: t0)
        store.mintSubagent(
            sessionId: "s1", agentId: "ag1", agentType: "Explore",
            description: nil, model: nil, parentAgentId: nil,
            lastAction: "Bash: ls", at: t0 + 5
        )
        XCTAssertEqual(store.sessions["s1"]?.backgroundTasks.first?.lastAction, "Bash: ls")
    }

    /// The mint lands after an async read; a fresher event that raced in
    /// between keeps its clock.
    func testMintNeverMovesTheClockBackward() {
        var store = SessionStore()
        store.apply(envelope("SessionStart"), at: t0 + 10)
        mint(&store, at: t0 + 5)
        XCTAssertEqual(store.sessions["s1"]?.lastEventAt, t0 + 10)
    }

    func testMintDoesNotDuplicateRows() {
        var store = SessionStore()
        store.apply(envelope("SessionStart"), at: t0)
        mint(&store)
        mint(&store)
        XCTAssertEqual(store.sessions["s1"]?.backgroundTasks.count, 1)
    }

    /// Resting with live children is delegating, not done — the same
    /// normalization `SubagentStop` applies. Relevant after a relaunch, when
    /// a restored idle session's children resurface through the mint path.
    func testMintLiftsARestingSessionToDelegating() {
        var store = SessionStore()
        store.apply(envelope("SessionStart"), at: t0)
        store.apply(envelope("Stop", backgroundTasks: []), at: t0 + 1)
        XCTAssertEqual(store.sessions["s1"]?.status, .idle)
        mint(&store)
        XCTAssertEqual(store.sessions["s1"]?.status, .delegating)
    }

    /// A blocked session keeps saying so: a spawn does not answer a question.
    func testMintLeavesAWaitingSessionWaiting() {
        var store = SessionStore()
        store.apply(envelope("SessionStart"), at: t0)
        let blocked = HookEnvelope(
            requestId: "r2", hookPid: 1, agent: "claude-code",
            event: HookEvent(
                sessionId: "s1", hookEventName: "Notification",
                cwd: "/tmp/proj", notificationType: "agent_needs_input"
            )
        )
        store.apply(blocked, at: t0 + 1)
        mint(&store)
        XCTAssertEqual(store.sessions["s1"]?.status, .waitingInput)
    }

    // MARK: - The list stays authoritative

    /// Minting adds rows early; it never keeps them late. The next wholesale
    /// replace removes anything the CLI does not vouch for.
    func testAuthoritativeReplaceRemovesAMintedRowTheCLIDoesNotReport() {
        var store = SessionStore()
        store.apply(envelope("SessionStart"), at: t0)
        mint(&store)
        let other = BackgroundTask(id: "ag2", kind: "subagent", status: "running")
        store.apply(
            envelope("SubagentStop", agentId: "ag1", backgroundTasks: [other]),
            at: t0 + 10
        )
        XCTAssertEqual(store.sessions["s1"]?.backgroundTasks.map(\.id), ["ag2"])
    }

    func testStopWithAnEmptyListDrainsMintedRows() {
        var store = SessionStore()
        store.apply(envelope("SessionStart"), at: t0)
        mint(&store)
        store.apply(envelope("Stop", backgroundTasks: []), at: t0 + 10)
        XCTAssertEqual(store.sessions["s1"]?.backgroundTasks, [])
        XCTAssertEqual(store.sessions["s1"]?.status, .idle)
    }

    /// When the list confirms a minted agent, the mint's enrichment survives
    /// the swap the same way live-action enrichment always has.
    func testReplaceCarriesMintedEnrichmentForAConfirmedAgent() {
        var store = SessionStore()
        store.apply(envelope("SessionStart"), at: t0)
        mint(&store, model: "fable")
        let confirmed = BackgroundTask(
            id: "ag1",
            kind: "subagent",
            status: "running",
            description: "Map the import pipeline",
            agentType: "Explore"
        )
        store.apply(
            envelope("SubagentStop", agentId: "other", backgroundTasks: [confirmed]),
            at: t0 + 10
        )
        XCTAssertEqual(store.sessions["s1"]?.backgroundTasks.first?.model, "fable")
    }

    /// A subagent's own tool call annotates the minted row — before this the
    /// annotation had nothing to land on until the first Stop.
    func testChildToolCallAnnotatesAMintedRow() {
        var store = SessionStore()
        store.apply(envelope("SessionStart"), at: t0)
        mint(&store)
        let toolEvent = HookEnvelope(
            requestId: "r3", hookPid: 1, agent: "claude-code",
            event: HookEvent(
                sessionId: "s1", hookEventName: "PostToolUse",
                cwd: "/tmp/proj",
                toolName: "Bash",
                toolInput: .object(["command": .string("ls")]),
                agentId: "ag1"
            )
        )
        store.apply(toolEvent, at: t0 + 6)
        XCTAssertNotNil(store.sessions["s1"]?.backgroundTasks.first?.lastAction)
    }

    // MARK: - Persistence

    /// A snapshot taken mid-turn (`.running` with minted rows) must not come
    /// back as "done · click to jump" over agents still working.
    func testRunningSnapshotWithChildrenRestoresAsDelegating() {
        var session = AgentSession(
            id: "s1", agent: "claude-code", cwd: "/tmp/proj", hookPid: nil,
            status: .running, pending: nil, lastEventAt: t0, title: nil,
            model: nil, terminalAppPid: nil, transcriptPath: nil, lastAction: nil
        )
        session.backgroundTasks = [
            BackgroundTask(id: "ag1", kind: "subagent", status: "running")
        ]
        let restored = PersistedSession(from: session).asSession(now: t0)
        XCTAssertEqual(restored.status, .delegating)
    }

    func testRunningSnapshotWithoutChildrenStillRestoresAsIdle() {
        let session = AgentSession(
            id: "s1", agent: "claude-code", cwd: "/tmp/proj", hookPid: nil,
            status: .running, pending: nil, lastEventAt: t0, title: nil,
            model: nil, terminalAppPid: nil, transcriptPath: nil, lastAction: nil
        )
        let restored = PersistedSession(from: session).asSession(now: t0)
        XCTAssertEqual(restored.status, .idle)
    }

    // MARK: - Sidecar path safety

    /// The agent id names a file inside `subagents/`; a separator or a
    /// dot-segment would resolve outside it. Ids come from hook payloads.
    func testMetaPathRejectsTraversalInAgentId() {
        let transcript = "/tmp/t/s1.jsonl"
        XCTAssertNotNil(BackgroundTask.metaPath(transcriptPath: transcript, agentId: "ag1"))
        for bad in ["", ".", "..", "../ag1", "a/b", "a\\b", "../../etc/passwd"] {
            XCTAssertNil(
                BackgroundTask.metaPath(transcriptPath: transcript, agentId: bad),
                "expected nil for agentId \(bad)"
            )
        }
    }

    // MARK: - Hook install

    func testClaudeEventsIncludeSubagentStart() {
        XCTAssertTrue(
            ClaudeSettingsMerger.claudeEvents.contains { $0.name == "SubagentStart" }
        )
    }

    /// An install written before SubagentStart existed reports stale, which is
    /// what makes the app re-merge and pick the event up.
    func testInstallPredatingSubagentStartIsNotCurrent() throws {
        let oldEvents = ClaudeSettingsMerger.claudeEvents.filter {
            $0.name != "SubagentStart"
        }
        let merged = try ClaudeSettingsMerger.merge(
            settings: nil,
            hookBinaryPath: "/Applications/Rocky.app/Contents/MacOS/rocky-hook",
            events: oldEvents,
            commandArguments: "--agent claude-code"
        )
        XCTAssertFalse(
            ClaudeSettingsMerger.isCurrent(
                settings: merged,
                hookBinaryPath: "/Applications/Rocky.app/Contents/MacOS/rocky-hook",
                events: ClaudeSettingsMerger.claudeEvents,
                commandArguments: "--agent claude-code"
            )
        )
    }
}
