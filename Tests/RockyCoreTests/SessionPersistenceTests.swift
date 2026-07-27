import XCTest
@testable import RockyCore

final class SessionPersistenceTests: XCTestCase {
    func testRoundTripDropsPendingAndDowngradesRunning() throws {
        var session = AgentSession(
            id: "s1",
            agent: "claude-code",
            cwd: "/tmp/proj",
            hookPid: 1,
            status: .waitingPermission,
            pending: PendingPermission(
                requestId: "r1",
                toolName: "Bash",
                summary: "ls",
                receivedAt: Date()
            ),
            lastEventAt: Date(),
            title: nil,
            model: "sonnet",
            terminalAppPid: 99,
            transcriptPath: nil,
            lastAction: "Bash: ls"
        )
        session.jumpTarget = JumpTarget(terminalApp: "Warp", warpPaneUUID: "ABC")
        session.tokens = 1200
        session.task = "fix the bug"

        let data = try SessionPersistence.encode([session])
        let restored = try SessionPersistence.decode(data)
        XCTAssertEqual(restored.count, 1)
        let s = try XCTUnwrap(restored.first)
        XCTAssertEqual(s.id, "s1")
        XCTAssertNil(s.pending)
        XCTAssertEqual(s.status, .idle)
        XCTAssertEqual(s.jumpTarget?.warpPaneUUID, "ABC")
        XCTAssertEqual(s.tokens, 1200)
        XCTAssertEqual(s.task, "fix the bug")
    }

    /// The handoff is meant to outlive a bare "done" row by a quarter of an
    /// hour; dropping it from the snapshot made a relaunch inside that window
    /// silently downgrade the row to "done · click to jump".
    func testHandoffSurvivesTheRoundTrip() throws {
        var session = AgentSession(
            id: "s1",
            agent: "claude-code",
            cwd: "/tmp/proj",
            hookPid: 1,
            status: .idle,
            pending: nil,
            lastEventAt: Date(),
            title: nil,
            model: nil,
            terminalAppPid: nil,
            transcriptPath: nil,
            lastAction: nil
        )
        session.lastAgentMessage = "Quer que eu commite?"
        session.handoffAsksSomething = true

        let restored = try SessionPersistence.decode(SessionPersistence.encode([session]))
        XCTAssertEqual(restored.first?.lastAgentMessage, "Quer que eu commite?")
        XCTAssertEqual(restored.first?.handoffAsksSomething, true)
    }

    /// Delegated work outlives the app that was watching it. Dropping the list
    /// made a restored session claim "done" over running agents and fall back
    /// to the short idle retention, which could prune it mid-flight — so the
    /// list is carried across and the session comes back delegating.
    func testDelegatingSurvivesTheRoundTrip() throws {
        var session = AgentSession(
            id: "s1",
            agent: "claude-code",
            cwd: "/tmp/proj",
            hookPid: 1,
            status: .delegating,
            pending: nil,
            lastEventAt: Date(),
            title: nil,
            model: nil,
            terminalAppPid: nil,
            transcriptPath: nil,
            lastAction: nil
        )
        session.backgroundTasks = [
            BackgroundTask(id: "ag1", kind: "subagent", description: "Fable review", model: "fable")
        ]

        let restored = try SessionPersistence.decode(SessionPersistence.encode([session]))
        XCTAssertEqual(restored.first?.status, .delegating)
        XCTAssertEqual(restored.first?.backgroundTasks.map(\.id), ["ag1"])
        // Enrichment travels too, so the row does not lose "Fable" on relaunch.
        XCTAssertEqual(restored.first?.backgroundTasks.first?.model, "fable")
    }

    /// A delegating session whose list did not survive has nothing to show for
    /// the claim, so it settles as idle rather than asserting invisible work.
    func testDelegatingWithoutAListComesBackIdle() throws {
        let session = AgentSession(
            id: "s1",
            agent: "claude-code",
            cwd: "/tmp/proj",
            hookPid: 1,
            status: .delegating,
            pending: nil,
            lastEventAt: Date(),
            title: nil,
            model: nil,
            terminalAppPid: nil,
            transcriptPath: nil,
            lastAction: nil
        )
        let restored = try SessionPersistence.decode(SessionPersistence.encode([session]))
        XCTAssertEqual(restored.first?.status, .idle)
    }

    func testDropsStaleSessions() throws {
        var old = AgentSession(
            id: "old",
            agent: "codex",
            cwd: "/tmp",
            hookPid: nil,
            status: .idle,
            pending: nil,
            lastEventAt: Date().addingTimeInterval(-3 * 60 * 60),
            title: nil,
            model: nil,
            terminalAppPid: nil,
            transcriptPath: nil,
            lastAction: nil
        )
        old.tokens = 1
        let data = try SessionPersistence.encode([old])
        let restored = try SessionPersistence.decode(data)
        XCTAssertTrue(restored.isEmpty)
    }

    func testRestoreOnlyFillsMissing() {
        var store = SessionStore()
        let live = AgentSession(
            id: "s1",
            agent: "grok",
            cwd: "/tmp",
            hookPid: 1,
            status: .running,
            pending: nil,
            lastEventAt: Date(),
            title: nil,
            model: nil,
            terminalAppPid: nil,
            transcriptPath: nil,
            lastAction: nil
        )
        store.restore([live])
        // Mutate "disk" version — should not overwrite live.
        var disk = live
        disk.agent = "claude-code"
        store.restore([disk])
        XCTAssertEqual(store.sessions["s1"]?.agent, "grok")

        let other = AgentSession(
            id: "s2",
            agent: "cursor",
            cwd: "/tmp",
            hookPid: nil,
            status: .idle,
            pending: nil,
            lastEventAt: Date(),
            title: nil,
            model: nil,
            terminalAppPid: nil,
            transcriptPath: nil,
            lastAction: nil
        )
        store.restore([other])
        XCTAssertEqual(store.sessions.count, 2)
    }
}
