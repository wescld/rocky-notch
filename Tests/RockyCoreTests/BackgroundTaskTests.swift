import XCTest
@testable import RockyCore

final class BackgroundTaskTests: XCTestCase {
    /// Verbatim from a real Claude Code `Stop` payload: one subagent and two
    /// background shells driving other CLIs.
    let stopPayload = """
    {
      "hook_event_name": "Stop",
      "session_id": "s1",
      "cwd": "/tmp/proj",
      "stop_hook_active": false,
      "last_assistant_message": "Os três estão rodando em paralelo.",
      "background_tasks": [
        {"id": "a39556a21c6e1cb3a", "type": "subagent", "status": "running",
         "description": "Fable design review of brainstorm",
         "agent_type": "general-purpose"},
        {"id": "bidlzfw85", "type": "shell", "status": "running",
         "description": "Run codex job monitor in background",
         "command": "bash /tmp/scratch/mon-codex.sh"},
        {"id": "bdpgdn936", "type": "shell", "status": "running",
         "description": "Run grok run monitor in background",
         "command": "bash /tmp/scratch/mon-grok.sh"}
      ],
      "session_crons": []
    }
    """

    func decode(_ json: String) throws -> HookEvent {
        try JSONDecoder().decode(HookEvent.self, from: Data(json.utf8))
    }

    func testDecodesRealStopPayload() throws {
        let event = try decode(stopPayload)
        let tasks = try XCTUnwrap(event.backgroundTasks)
        XCTAssertEqual(tasks.count, 3)
        XCTAssertEqual(tasks[0].id, "a39556a21c6e1cb3a")
        XCTAssertEqual(tasks[0].kind, "subagent")
        XCTAssertTrue(tasks[0].isSubagent)
        XCTAssertEqual(tasks[0].agentType, "general-purpose")
        XCTAssertEqual(tasks[1].kind, "shell")
        XCTAssertEqual(tasks[1].command, "bash /tmp/scratch/mon-codex.sh")
        XCTAssertNil(tasks[1].agentType)
    }

    /// Empty and absent are different claims: one says "nothing is pending",
    /// the other says "this agent never told us".
    func testEmptyListDecodesAsEmptyNotNil() throws {
        let event = try decode("""
        {"hook_event_name": "Stop", "session_id": "s1", "background_tasks": []}
        """)
        XCTAssertEqual(event.backgroundTasks, [])
    }

    func testAbsentListDecodesAsNil() throws {
        let event = try decode("""
        {"hook_event_name": "Stop", "session_id": "s1"}
        """)
        XCTAssertNil(event.backgroundTasks)
    }

    /// One unusable entry must not cost the whole list — the id is the join
    /// key for tool events, so an entry without one is the only casualty.
    func testEntryWithoutIdIsDroppedAndTheRestSurvive() throws {
        let event = try decode("""
        {"hook_event_name": "Stop", "session_id": "s1", "background_tasks": [
          {"type": "shell", "description": "no id here"},
          {"id": "keep", "type": "subagent"}
        ]}
        """)
        XCTAssertEqual(event.backgroundTasks?.map(\.id), ["keep"])
    }

    func testUnknownTypeIsKeptVerbatim() throws {
        let event = try decode("""
        {"hook_event_name": "Stop", "session_id": "s1", "background_tasks": [
          {"id": "x", "type": "teleporter"}
        ]}
        """)
        XCTAssertEqual(event.backgroundTasks?.first?.kind, "teleporter")
    }

    // MARK: - Display

    func testTitlePrefersTheAgentsOwnSentence() {
        let task = BackgroundTask(
            id: "x", kind: "shell",
            description: "Run codex job monitor in background",
            command: "bash /tmp/mon.sh"
        )
        XCTAssertEqual(task.title, "Run codex job monitor in background")
    }

    func testTitleFallsBackToCommandThenType() {
        XCTAssertEqual(
            BackgroundTask(id: "x", kind: "shell", command: "npm test").title,
            "npm test"
        )
        XCTAssertEqual(BackgroundTask(id: "x", kind: "shell").title, "shell")
    }

    /// The model is what makes the row read "Fable" instead of the generic
    /// agent type the payload carries.
    func testSubagentLabelPrefersResolvedModel() {
        var task = BackgroundTask(id: "x", kind: "subagent", agentType: "general-purpose")
        XCTAssertEqual(task.providerLabel, "general-purpose")
        task.model = "fable"
        XCTAssertEqual(task.providerLabel, "Fable")
    }

    func testShellLabelIsGuessedFromTheCommandAndDescription() {
        XCTAssertEqual(
            BackgroundTask(id: "x", kind: "shell", description: "Run codex job monitor").providerLabel,
            "Codex"
        )
        XCTAssertEqual(
            BackgroundTask(id: "x", kind: "shell", command: "bash /tmp/mon-grok.sh").providerLabel,
            "Grok"
        )
        XCTAssertEqual(
            BackgroundTask(id: "x", kind: "shell", command: "kimi --resume").providerLabel,
            "Kimi"
        )
    }

    /// A guess with nothing to go on shows no chip rather than a wrong one —
    /// the task's own description still says what it is.
    func testShellLabelIsNilWhenNothingMatches() {
        XCTAssertNil(
            BackgroundTask(id: "x", kind: "shell", command: "npm run build").providerLabel
        )
    }

    // MARK: - The overflow line

    func testGroupedLineWithNothingToNameIsJustACount() {
        let tasks = [
            BackgroundTask(id: "sh1", kind: "shell"),
            BackgroundTask(id: "sh2", kind: "shell"),
        ]
        XCTAssertEqual(BackgroundTask.groupedLabel(tasks), "2 shell jobs")
    }

    /// Past the row cap the descriptions are gone, so the line has to at least
    /// keep who is out there.
    func testGroupedLineKeepsWhoIsInTheGroup() {
        let tasks = [
            BackgroundTask(id: "sh1", kind: "shell", description: "Monitor codex review job"),
            BackgroundTask(id: "sh2", kind: "shell", command: "bash /tmp/mon-grok.sh"),
        ]
        XCTAssertEqual(
            BackgroundTask.groupedLabel(tasks),
            "2 shell jobs · Codex · Grok"
        )
    }

    func testGroupedLineDeduplicatesRepeatedProviders() {
        let tasks = [
            BackgroundTask(id: "a", kind: "shell", command: "codex exec one"),
            BackgroundTask(id: "b", kind: "shell", command: "codex exec two"),
        ]
        XCTAssertEqual(
            BackgroundTask.groupedLabel(tasks),
            "2 shell jobs · Codex"
        )
    }

    func testGroupedLineTrimsALongRoster() {
        let tasks = ["codex", "grok", "kimi", "gemini"].enumerated().map { index, name in
            BackgroundTask(id: "t\(index)", kind: "shell", command: "\(name) run")
        }
        XCTAssertEqual(
            BackgroundTask.groupedLabel(tasks, maxNames: 3),
            "4 shell jobs · Codex · Grok · Kimi …"
        )
    }

    /// The same line covers a fan-out past the row cap, where the group really
    /// is agents — so it must not call them shell jobs.
    func testGroupedLineNamesAgentsWhenTheGroupIsAgents() {
        let tasks = (0..<12).map {
            BackgroundTask(id: "ag\($0)", kind: "subagent", agentType: "general-purpose")
        }
        XCTAssertEqual(
            BackgroundTask.groupedLabel(tasks),
            "12 more agents · general-purpose"
        )
    }

    /// Mixed or unrecognized work stays generic instead of claiming a type.
    func testGroupedLineStaysGenericWhenTheGroupIsMixed() {
        let tasks = [
            BackgroundTask(id: "a", kind: "subagent"),
            BackgroundTask(id: "b", kind: "shell"),
        ]
        XCTAssertEqual(BackgroundTask.groupedLabel(tasks), "2 more tasks")
    }

    func testGroupedLineIsSingularForOne() {
        XCTAssertEqual(
            BackgroundTask.groupedLabel([BackgroundTask(id: "a", kind: "shell")]),
            "1 shell job"
        )
    }

    // MARK: - Subagent sidecar

    func testMetaPathIsDerivedFromTheParentTranscript() {
        XCTAssertEqual(
            BackgroundTask.metaPath(
                transcriptPath: "/Users/k/.claude/projects/-proj/0273d813.jsonl",
                agentId: "a39556a21c6e1cb3a"
            ),
            "/Users/k/.claude/projects/-proj/0273d813/subagents/agent-a39556a21c6e1cb3a.meta.json"
        )
    }

    func testMetaPathNeedsAnAgentId() {
        XCTAssertNil(BackgroundTask.metaPath(transcriptPath: "/tmp/s.jsonl", agentId: ""))
    }

    func testSubagentMetaParsesTheModel() throws {
        let data = Data("""
        {"agentType":"general-purpose","description":"Fable design review",
         "toolUseId":"toolu_01","spawnDepth":1,"model":"fable"}
        """.utf8)
        let meta = try XCTUnwrap(SubagentMeta(data))
        XCTAssertEqual(meta.model, "fable")
        XCTAssertEqual(meta.agentType, "general-purpose")
    }

    func testSubagentMetaRejectsUnrelatedJSON() {
        XCTAssertNil(SubagentMeta(Data(#"{"unrelated":true}"#.utf8)))
        XCTAssertNil(SubagentMeta(Data("not json".utf8)))
    }
}
