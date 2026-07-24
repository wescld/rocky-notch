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
