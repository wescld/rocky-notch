import XCTest
@testable import RockyCore

final class SessionDiscoveryTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("rocky-discovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
        tempRoot = nil
    }

    // MARK: - Claude

    func testClaudeDiscoversRecentSession() throws {
        let projects = tempRoot.appendingPathComponent(".claude/projects", isDirectory: true)
        let workspace = projects.appendingPathComponent("-tmp-demo-repo", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let transcript = workspace.appendingPathComponent("session-123.jsonl")
        let body = """
        {"cwd":"/tmp/demo-repo","sessionId":"session-123","type":"user","message":{"role":"user","content":"Fix the flaky auth tests."},"timestamp":"2026-04-03T03:20:00Z"}
        {"cwd":"/tmp/demo-repo","sessionId":"session-123","type":"assistant","message":{"role":"assistant","model":"claude-sonnet-4-5","content":[{"type":"text","text":"Checking auth tests."},{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"npm test"}}]},"timestamp":"2026-04-03T03:20:06Z"}
        """
        try body.write(to: transcript, atomically: true, encoding: .utf8)

        let now = ISO8601DateFormatter().date(from: "2026-04-03T03:20:10Z")!
        let sessions = SessionDiscovery.discoverClaude(
            rootURL: projects,
            now: now,
            maxAge: 2 * 60 * 60
        )

        XCTAssertEqual(sessions.count, 1)
        let s = try XCTUnwrap(sessions.first)
        XCTAssertEqual(s.id, "session-123")
        XCTAssertEqual(s.agent, "claude-code")
        XCTAssertEqual(s.cwd, "/tmp/demo-repo")
        XCTAssertEqual(s.status, .idle)
        XCTAssertNil(s.pending)
        XCTAssertEqual(s.model, "claude-sonnet-4-5")
        XCTAssertEqual(s.transcriptPath, transcript.path)
        XCTAssertEqual(s.task, "Fix the flaky auth tests.")
        XCTAssertEqual(s.lastAction, "running npm test")
        XCTAssertEqual(s.jumpTarget?.workingDirectory, "/tmp/demo-repo")
        XCTAssertNil(s.hookPid)
        XCTAssertNil(s.agentProcessPid)
        XCTAssertNil(s.terminalAppPid)
    }

    func testClaudeSkipsStaleAndSubagents() throws {
        let projects = tempRoot.appendingPathComponent(".claude/projects", isDirectory: true)
        let workspace = projects.appendingPathComponent("-tmp-demo", isDirectory: true)
        let subagents = workspace.appendingPathComponent("subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)

        let recent = workspace.appendingPathComponent("recent.jsonl")
        let stale = workspace.appendingPathComponent("stale.jsonl")
        let sub = subagents.appendingPathComponent("child.jsonl")

        let line = { (id: String, ts: String) in
            #"{"cwd":"/tmp/demo","sessionId":"\#(id)","type":"user","message":{"role":"user","content":"hi"},"timestamp":"\#(ts)"}"#
        }
        try line("recent", "2026-04-03T03:20:00Z").write(to: recent, atomically: true, encoding: .utf8)
        try line("stale", "2026-04-01T03:20:00Z").write(to: stale, atomically: true, encoding: .utf8)
        try line("child", "2026-04-03T03:20:00Z").write(to: sub, atomically: true, encoding: .utf8)

        // Force mtimes so maxAge filter uses file dates, not write-now.
        let now = ISO8601DateFormatter().date(from: "2026-04-03T03:20:10Z")!
        try setMtime(recent, to: now)
        try setMtime(stale, to: now.addingTimeInterval(-3 * 60 * 60))
        try setMtime(sub, to: now)

        let sessions = SessionDiscovery.discoverClaude(
            rootURL: projects,
            now: now,
            maxAge: 2 * 60 * 60
        )
        XCTAssertEqual(sessions.map(\.id), ["recent"])
    }

    func testClaudeHandlesTrailingLineWithoutNewline() throws {
        let projects = tempRoot.appendingPathComponent(".claude/projects", isDirectory: true)
        let workspace = projects.appendingPathComponent("-tmp-demo", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let transcript = workspace.appendingPathComponent("trailing.jsonl")
        // Deliberately omit trailing newline.
        let body = #"{"cwd":"/tmp/demo","sessionId":"trailing","type":"user","message":{"role":"user","content":"hi"},"timestamp":"2026-04-03T03:20:00Z"}"#
            + "\n"
            + #"{"cwd":"/tmp/demo","sessionId":"trailing","type":"assistant","message":{"role":"assistant","model":"opus","content":[{"type":"text","text":"done"}]},"timestamp":"2026-04-03T03:20:02Z"}"#
        try body.write(to: transcript, atomically: true, encoding: .utf8)

        let now = ISO8601DateFormatter().date(from: "2026-04-03T03:20:10Z")!
        let sessions = SessionDiscovery.discoverClaude(rootURL: projects, now: now)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.model, "opus")
    }

    func testClaudeRespectsMaxFiles() throws {
        let projects = tempRoot.appendingPathComponent(".claude/projects", isDirectory: true)
        let workspace = projects.appendingPathComponent("-tmp-demo", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let now = ISO8601DateFormatter().date(from: "2026-04-03T03:20:10Z")!

        for i in 0..<5 {
            let url = workspace.appendingPathComponent("s\(i).jsonl")
            let body = #"{"cwd":"/tmp/demo","sessionId":"s\#(i)","type":"user","message":{"role":"user","content":"hi"},"timestamp":"2026-04-03T03:20:0\#(i)Z"}"#
            try body.write(to: url, atomically: true, encoding: .utf8)
            try setMtime(url, to: now.addingTimeInterval(TimeInterval(i)))
        }

        let sessions = SessionDiscovery.discoverClaude(
            rootURL: projects,
            now: now.addingTimeInterval(10),
            maxFiles: 2
        )
        XCTAssertEqual(sessions.count, 2)
    }

    // MARK: - Codex

    func testCodexDiscoversRolloutSession() throws {
        let root = tempRoot.appendingPathComponent(".codex/sessions/2026/04/03", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rollout = root.appendingPathComponent(
            "rollout-2026-04-03T03-20-00-019f2984-dbca-7fb0-8ce4-9d56dbb848d6.jsonl"
        )
        let body = """
        {"timestamp":"2026-04-03T03:20:00Z","type":"session_meta","payload":{"session_id":"019f2984-dbca-7fb0-8ce4-9d56dbb848d6","id":"019f2984-dbca-7fb0-8ce4-9d56dbb848d6","timestamp":"2026-04-03T03:20:00Z","cwd":"/tmp/chimera","originator":"Codex Desktop"}}
        {"timestamp":"2026-04-03T03:20:01Z","type":"turn_context","payload":{"turn_id":"t1","cwd":"/tmp/chimera","model":"gpt-5.6-sol"}}
        {"timestamp":"2026-04-03T03:20:02Z","type":"event_msg","payload":{"type":"user_message","message":"Add multiplayer lobby"}}
        {"timestamp":"2026-04-03T03:20:03Z","type":"response_item","payload":{"type":"function_call","name":"shell_command","arguments":{"command":"ls"}}}
        """
        try body.write(to: rollout, atomically: true, encoding: .utf8)
        let now = ISO8601DateFormatter().date(from: "2026-04-03T03:20:10Z")!
        try setMtime(rollout, to: now)

        let sessions = SessionDiscovery.discoverCodex(
            rootURL: tempRoot.appendingPathComponent(".codex/sessions", isDirectory: true),
            now: now
        )
        XCTAssertEqual(sessions.count, 1)
        let s = try XCTUnwrap(sessions.first)
        XCTAssertEqual(s.id, "019f2984-dbca-7fb0-8ce4-9d56dbb848d6")
        XCTAssertEqual(s.agent, "codex")
        XCTAssertEqual(s.cwd, "/tmp/chimera")
        XCTAssertEqual(s.status, .idle)
        XCTAssertNil(s.pending)
        XCTAssertEqual(s.model, "gpt-5.6-sol")
        XCTAssertEqual(s.task, "Add multiplayer lobby")
        XCTAssertEqual(s.jumpTarget?.workingDirectory, "/tmp/chimera")
    }

    func testCodexIgnoresNonRolloutJSONL() throws {
        let root = tempRoot.appendingPathComponent(".codex/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let other = root.appendingPathComponent("session_index.jsonl")
        try #"{"id":"x"}"#.write(to: other, atomically: true, encoding: .utf8)
        let now = Date()
        try setMtime(other, to: now)
        let sessions = SessionDiscovery.discoverCodex(rootURL: root, now: now)
        XCTAssertTrue(sessions.isEmpty)
    }

    // MARK: - Store integration

    func testRestoreDoesNotOverwriteLiveAndApplyWins() {
        var store = SessionStore()
        let live = AgentSession(
            id: "session-123",
            agent: "claude-code",
            cwd: "/live",
            hookPid: 42,
            status: .running,
            pending: nil,
            lastEventAt: Date(),
            title: nil,
            model: "live-model",
            terminalAppPid: 99,
            transcriptPath: nil,
            lastAction: nil
        )
        store.restore([live])

        let discovered = SessionDiscovery.makeObservationalSession(
            id: "session-123",
            agent: "claude-code",
            cwd: "/from-disk",
            lastEventAt: Date().addingTimeInterval(-60),
            model: "disk-model",
            transcriptPath: "/tmp/t.jsonl",
            task: "old task"
        )
        store.restore([discovered])
        XCTAssertEqual(store.sessions["session-123"]?.cwd, "/live")
        XCTAssertEqual(store.sessions["session-123"]?.status, .running)
        XCTAssertEqual(store.sessions["session-123"]?.model, "live-model")

        // New discovery id seeds fine.
        let other = SessionDiscovery.makeObservationalSession(
            id: "other",
            agent: "codex",
            cwd: "/tmp/other",
            lastEventAt: Date(),
            transcriptPath: "/tmp/other.jsonl"
        )
        store.restore([other])
        XCTAssertEqual(store.sessions.count, 2)
        XCTAssertEqual(store.sessions["other"]?.status, .idle)
        XCTAssertNil(store.sessions["other"]?.pending)
    }

    func testObservationalIdleSurvivesPruneWithinOrphanTimeout() {
        var store = SessionStore()
        let recent = SessionDiscovery.makeObservationalSession(
            id: "recent",
            agent: "claude-code",
            cwd: "/tmp",
            lastEventAt: Date().addingTimeInterval(-30 * 60),
            transcriptPath: "/tmp/r.jsonl"
        )
        let ancient = SessionDiscovery.makeObservationalSession(
            id: "ancient",
            agent: "claude-code",
            cwd: "/tmp",
            lastEventAt: Date().addingTimeInterval(-3 * 60 * 60),
            transcriptPath: "/tmp/a.jsonl"
        )
        store.restore([recent, ancient])
        store.pruneOrphans(now: Date())
        XCTAssertNotNil(store.sessions["recent"])
        XCTAssertNil(store.sessions["ancient"])
    }

    func testIdleWithHostPidStillUsesShortRetention() {
        var store = SessionStore()
        var session = SessionDiscovery.makeObservationalSession(
            id: "stopped",
            agent: "claude-code",
            cwd: "/tmp",
            lastEventAt: Date().addingTimeInterval(-10 * 60),
            transcriptPath: "/tmp/s.jsonl"
        )
        session.terminalAppPid = 1234
        store.restore([session])
        store.pruneOrphans(now: Date())
        XCTAssertNil(store.sessions["stopped"])
    }

    func testNeverInventsPendingPermission() {
        let session = SessionDiscovery.makeObservationalSession(
            id: "x",
            agent: "claude-code",
            cwd: "/tmp",
            lastEventAt: Date(),
            transcriptPath: "/tmp/x.jsonl"
        )
        XCTAssertNil(session.pending)
        XCTAssertEqual(session.status, .idle)
    }

    func testDiscoverRecentCombinesHomeRoots() throws {
        // Layout under a fake home so we don't touch the real ~/.claude.
        let home = tempRoot.appendingPathComponent("home", isDirectory: true)
        let claudeWS = home
            .appendingPathComponent(".claude/projects/-tmp-a", isDirectory: true)
        let codexDir = home
            .appendingPathComponent(".codex/sessions/2026/04/03", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeWS, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)

        let claudeFile = claudeWS.appendingPathComponent("c1.jsonl")
        try #"{"cwd":"/tmp/a","sessionId":"c1","type":"user","message":{"role":"user","content":"hi"},"timestamp":"2026-04-03T03:20:00Z"}"#
            .write(to: claudeFile, atomically: true, encoding: .utf8)

        let codexFile = codexDir.appendingPathComponent("rollout-2026-04-03T03-20-00-c2.jsonl")
        try #"{"timestamp":"2026-04-03T03:20:01Z","type":"session_meta","payload":{"id":"c2","session_id":"c2","cwd":"/tmp/b","timestamp":"2026-04-03T03:20:01Z"}}"#
            .write(to: codexFile, atomically: true, encoding: .utf8)

        let now = ISO8601DateFormatter().date(from: "2026-04-03T03:20:10Z")!
        try setMtime(claudeFile, to: now)
        try setMtime(codexFile, to: now)

        let sessions = SessionDiscovery.discoverRecent(home: home.path, now: now)
        let ids = Set(sessions.map(\.id))
        XCTAssertEqual(ids, ["c1", "c2"])
        XCTAssertEqual(sessions.first(where: { $0.id == "c1" })?.agent, "claude-code")
        XCTAssertEqual(sessions.first(where: { $0.id == "c2" })?.agent, "codex")
    }

    // MARK: - Helpers

    private func setMtime(_ url: URL, to date: Date) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: date],
            ofItemAtPath: url.path
        )
    }
}
