import XCTest
@testable import VibenotchCore

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

    func testOrphanPruning() {
        var store = SessionStore()
        store.apply(envelope("SessionStart"), at: t0)
        store.apply(envelope("PermissionRequest", session: "s2", requestId: "r2"), at: t0)

        store.pruneOrphans(now: t0 + 3 * 60 * 60)
        // s1 is stale and dropped; s2 has a pending request and survives.
        XCTAssertNil(store.sessions["s1"])
        XCTAssertNotNil(store.sessions["s2"])
    }

    func testOrderedByRecency() {
        var store = SessionStore()
        store.apply(envelope("SessionStart", session: "old"), at: t0)
        store.apply(envelope("SessionStart", session: "new"), at: t0 + 10)
        XCTAssertEqual(store.ordered.map(\.id), ["new", "old"])
    }
}
