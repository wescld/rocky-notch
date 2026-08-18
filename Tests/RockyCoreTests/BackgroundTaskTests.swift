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

    /// An entry with no usable id is kept under a synthetic one. Dropping it
    /// looked tolerant until every entry was malformed: the list decoded to
    /// empty, and empty is how a session says it has nothing left to wait for
    /// — so a bad payload could announce a completion that never happened.
    func testEntryWithoutIdIsKeptUnderASyntheticOne() throws {
        let event = try decode("""
        {"hook_event_name": "Stop", "session_id": "s1", "background_tasks": [
          {"type": "shell", "description": "no id here"},
          {"id": "keep", "type": "subagent"}
        ]}
        """)
        let tasks = try XCTUnwrap(event.backgroundTasks)
        XCTAssertEqual(tasks.count, 2)
        XCTAssertEqual(tasks[0].description, "no id here")
        XCTAssertEqual(tasks[1].id, "keep")
        // The synthetic id must not collide with a real agent id, so the row
        // is counted and drawn but never claims a live action.
        XCTAssertTrue(tasks[0].id.hasPrefix("unidentified-"))
    }

    /// The failure that motivated it: work declared, nothing decodable.
    func testAnAllMalformedListIsStillWorkInFlight() throws {
        let event = try decode("""
        {"hook_event_name": "Stop", "session_id": "s1", "background_tasks": [
          {"type": "shell"}, {"type": "subagent"}
        ]}
        """)
        XCTAssertEqual(event.backgroundTasks?.count, 2)
    }

    /// Duplicate ids reach SwiftUI as duplicate identities.
    func testRepeatedIdsCollapse() throws {
        let event = try decode("""
        {"hook_event_name": "Stop", "session_id": "s1", "background_tasks": [
          {"id": "same", "type": "shell", "description": "first"},
          {"id": "same", "type": "shell", "description": "second"}
        ]}
        """)
        XCTAssertEqual(event.backgroundTasks?.count, 1)
        XCTAssertEqual(event.backgroundTasks?.first?.description, "first")
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

    /// Whole words only: a substring search called this one a Claude job.
    func testShellLabelDoesNotMatchInsideAWord() {
        XCTAssertNil(
            BackgroundTask(id: "x", kind: "shell", command: "/opt/notclaude/run").providerLabel
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

    // MARK: - Overflow row

    /// Closed, the line is the grouped one: what is hidden, and who is in it.
    func testOverflowLineNamesTheHiddenGroupWhileClosed() {
        let tasks = (0..<2).map {
            BackgroundTask(id: "ag\($0)", kind: "subagent", model: "sonnet")
        }
        XCTAssertEqual(
            BackgroundTask.overflowLabel(remaining: tasks, expanded: false),
            "2 more agents · Sonnet"
        )
    }

    /// Opened, nothing is hidden, so the line cannot claim a remainder — it
    /// says what the click does instead.
    func testOverflowLineOffersTheWayBackWhenNothingIsHidden() {
        XCTAssertEqual(
            BackgroundTask.overflowLabel(remaining: [], expanded: true),
            "show fewer"
        )
    }

    /// A fan-out past even the opened cap still has a real group to name; the
    /// chevron carries the direction of the click.
    func testOverflowLineStillNamesAGroupThatSurvivesExpanding() {
        let tasks = (0..<4).map {
            BackgroundTask(id: "ag\($0)", kind: "subagent", agentType: "Explore")
        }
        XCTAssertEqual(
            BackgroundTask.overflowLabel(remaining: tasks, expanded: true),
            "4 more agents · Explore"
        )
    }

    /// Closed with nothing left over there is no row at all, so the label has
    /// nothing to say — it must not invent a count.
    func testOverflowLineIsEmptyWhenClosedWithNothingHidden() {
        XCTAssertEqual(BackgroundTask.overflowLabel(remaining: [], expanded: false), "")
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

    /// Verbatim from a real nested spawn: a kai-implementer's Explore child.
    /// `spawnDepth` is deliberately ignored — display depth must come from
    /// ancestors actually visible in the list.
    func testSubagentMetaParsesTheParent() throws {
        let data = Data("""
        {"agentType":"Explore","description":"Inventory tests pinning C2 fills",
         "toolUseId":"toolu_01","parentAgentId":"af0b973f54c2ba433","spawnDepth":2}
        """.utf8)
        let meta = try XCTUnwrap(SubagentMeta(data))
        XCTAssertEqual(meta.parentAgentId, "af0b973f54c2ba433")
        XCTAssertNil(meta.model)
    }

    func testSubagentMetaTreatsAnEmptyParentAsNone() throws {
        let meta = try XCTUnwrap(SubagentMeta(Data(
            #"{"agentType":"Explore","parentAgentId":""}"#.utf8
        )))
        XCTAssertNil(meta.parentAgentId)
    }

    // MARK: - The display forest

    func sub(_ id: String, parent: String? = nil) -> BackgroundTask {
        BackgroundTask(
            id: id, kind: "subagent", status: "running",
            description: "task \(id)", agentType: "general-purpose",
            parentAgentId: parent
        )
    }

    func rows(_ tasks: [BackgroundTask], cap: Int = 12) -> [(String, Int)] {
        BackgroundTask.displayRows(tasks, cap: cap).rows.map { ($0.id, $0.depth) }
    }

    func testFlatListStaysFlatInPayloadOrder() {
        let tasks = [sub("a"), sub("b"), sub("c")]
        XCTAssertEqual(rows(tasks).map(\.0), ["a", "b", "c"])
        XCTAssertEqual(rows(tasks).map(\.1), [0, 0, 0])
        XCTAssertEqual(BackgroundTask.displayRows(tasks, cap: 2).overflow.map(\.id), ["c"])
    }

    func testChildrenIndentUnderTheirParentInForestOrder() {
        let drawn = rows([sub("a"), sub("b"), sub("x", parent: "a"), sub("y", parent: "x")])
        XCTAssertEqual(drawn.map(\.0), ["a", "x", "y", "b"])
        XCTAssertEqual(drawn.map(\.1), [0, 1, 2, 0])
    }

    /// A parent that finished is not an error state: its children are the work
    /// now. No badge, no indent, no memory of the old shape.
    func testOrphanPromotesToTopLevel() {
        let drawn = rows([sub("a"), sub("x", parent: "gone")])
        XCTAssertEqual(drawn.map(\.0), ["a", "x"])
        XCTAssertEqual(drawn.map(\.1), [0, 0])
    }

    /// The grandchild's sidecar said depth 2; with the middle parent out of
    /// the list it still draws at top level, proving depth comes from visible
    /// ancestry and never from `spawnDepth`.
    func testMissingMiddleParentPromotesTheGrandchild() {
        let drawn = rows([sub("a"), sub("y", parent: "x")])
        XCTAssertEqual(drawn.map(\.1), [0, 0])
    }

    /// An id collision with a shell must not fabricate an edge — in either
    /// direction, whatever garbage ends up in the field.
    func testShellsNeverJoinTheTree() {
        let shell = BackgroundTask(
            id: "sh", kind: "shell", command: "npm test", parentAgentId: "a"
        )
        let drawn = rows([sub("a"), shell, sub("x", parent: "sh")])
        XCTAssertEqual(drawn.map(\.1), [0, 0, 0])
    }

    /// Malformed ancestry degrades to the flat list: every id exactly once,
    /// never a loop, never a hidden row.
    func testCyclesAndSelfParentsDrawEveryIdExactlyOnce() {
        let tasks = [
            sub("a", parent: "a"),
            sub("b", parent: "c"),
            sub("c", parent: "b"),
            sub("d", parent: "b"),
        ]
        let display = BackgroundTask.displayRows(tasks, cap: 12)
        XCTAssertEqual(display.rows.map(\.id).sorted(), ["a", "b", "c", "d"])
        XCTAssertEqual(display.overflow, [])
        // The self-parent is a root; the cycle promotes at its first member,
        // which keeps the other one (and the innocent bystander) attached.
        XCTAssertEqual(display.rows.map(\.depth), [0, 0, 1, 1])
    }

    /// The resting cap shows what was dispatched. One fan-out must not bury
    /// the other roots under its own children.
    func testRootsAreNeverBuriedByAnotherRootsChildren() {
        let tasks = [
            sub("a"), sub("x", parent: "a"), sub("y", parent: "a"),
            sub("b"), sub("c"), sub("d"),
        ]
        let display = BackgroundTask.displayRows(tasks, cap: 4)
        XCTAssertEqual(display.rows.map(\.id), ["a", "b", "c", "d"])
        XCTAssertEqual(display.overflow.map(\.id), ["x", "y"])
    }

    func testLeftoverSlotsGoToChildrenInForestOrder() {
        let tasks = [
            sub("a"), sub("b"),
            sub("x", parent: "a"), sub("y", parent: "a"), sub("z", parent: "b"),
        ]
        let display = BackgroundTask.displayRows(tasks, cap: 4)
        XCTAssertEqual(display.rows.map(\.id), ["a", "x", "y", "b"])
        XCTAssertEqual(display.rows.map(\.depth), [0, 1, 1, 0])
        XCTAssertEqual(display.overflow.map(\.id), ["z"])
    }

    /// A child whose parent fell past the cap goes to the overflow with it —
    /// grouped, never dropped, and never drawn indented under nothing.
    func testChildOfAnUndrawnParentStaysInOverflow() {
        let tasks = [
            sub("a"), sub("b"), sub("c"), sub("d"), sub("e"),
            sub("x", parent: "e"),
        ]
        let display = BackgroundTask.displayRows(tasks, cap: 4)
        XCTAssertEqual(display.rows.map(\.id), ["a", "b", "c", "d"])
        XCTAssertEqual(display.overflow.map(\.id), ["e", "x"])
    }

    /// The snapshot must bring the tree back after a relaunch, and snapshots
    /// written before the field existed must still decode.
    func testParentSurvivesTheCodableRoundTripAndOldSnapshotsDecode() throws {
        let task = sub("x", parent: "a")
        let decoded = try JSONDecoder().decode(
            BackgroundTask.self,
            from: JSONEncoder().encode(task)
        )
        XCTAssertEqual(decoded.parentAgentId, "a")

        let old = try JSONDecoder().decode(BackgroundTask.self, from: Data(
            #"{"id":"x","type":"subagent","status":"running"}"#.utf8
        ))
        XCTAssertNil(old.parentAgentId)
    }

    /// No CLI reports ancestry in the payload today, but the decoder accepts
    /// it so the day one starts, the payload simply outranks the sidecar.
    func testPayloadParentIsDecodedAndEmptyMeansNone() throws {
        let event = try decode("""
        {"hook_event_name": "Stop", "session_id": "s1", "background_tasks": [
          {"id": "a", "type": "subagent"},
          {"id": "x", "type": "subagent", "parent_agent_id": "a"},
          {"id": "y", "type": "subagent", "parent_agent_id": ""}
        ]}
        """)
        let tasks = try XCTUnwrap(event.backgroundTasks)
        XCTAssertEqual(tasks[1].parentAgentId, "a")
        XCTAssertNil(tasks[2].parentAgentId)
    }
}
