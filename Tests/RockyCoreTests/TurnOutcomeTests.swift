import XCTest
@testable import RockyCore

final class TurnOutcomeTests: XCTestCase {
    private func decode(_ json: String) throws -> HookEvent {
        try JSONDecoder().decode(HookEvent.self, from: Data(json.utf8))
    }

    func testStopFailureSurvivesIPCHopAndMessageEnrichment() throws {
        let event = try decode(#"{"session_id":"s","hook_event_name":"StopFailure"}"#)
        XCTAssertEqual(event.kind, .stop)
        XCTAssertEqual(event.outcome, .failed)
        let enriched = event.withLastAssistantMessage("Failure details")
        let decoded = try NDJSON.decode(HookEnvelope.self, from: NDJSON.encodeLine(HookEnvelope(event: enriched)))
        XCTAssertEqual(decoded.event.outcome, .failed)
        XCTAssertEqual(decoded.event.hookEventName, "Stop") // old peers understand the event
    }

    func testTerminationReasonsAndFullyIdle() throws {
        for (reason, outcome) in [
            ("cancelled by user", TurnOutcome.cancelled), ("interrupted", .cancelled),
            ("timed out", .timedOut), ("timeout", .timedOut), ("error", .failed),
            ("invocation complete", .succeeded),
        ] {
            let event = try decode("{\"conversationId\":\"s\",\"fullyIdle\":true,\"terminationReason\":\"\(reason)\"}")
            XCTAssertEqual(event.outcome, outcome)
            XCTAssertEqual(event.fullyIdle, true)
        }
        let busy = try decode(#"{"conversationId":"s","fullyIdle":false,"terminationReason":"invocation complete"}"#)
        XCTAssertEqual(busy.outcome, .none)
        XCTAssertEqual(try JSONDecoder().decode(HookEvent.self, from: JSONEncoder().encode(busy)).fullyIdle, false)
    }

    func testFailureReasonsArePreservedRegardlessOfFullyIdle() throws {
        for (reason, outcome) in [("error", TurnOutcome.failed), ("cancelled", .cancelled), ("timeout", .timedOut)] {
            for fullyIdle in [true, false] {
                let event = try decode("{\"session_id\":\"s\",\"hook_event_name\":\"Stop\",\"terminationReason\":\"\(reason)\",\"fullyIdle\":\(fullyIdle)}")
                XCTAssertEqual(event.outcome, outcome, "\(reason), fullyIdle=\(fullyIdle)")
                var store = SessionStore()
                store.apply(HookEnvelope(event: event), at: Date())
                let session = try XCTUnwrap(store.sessions["s"])
                XCTAssertEqual(session.lastOutcome, outcome)
                XCTAssertFalse(session.completedSuccessfully)
            }
        }
    }

    func testMalformedOptionalOutcomeMetadataDoesNotDropStop() throws {
        for key in ["terminationReason", "fullyIdle", "rocky_outcome"] {
            for value in ["42", "true", "{}", "[]"] where !(key == "fullyIdle" && value == "true") {
                let event = try decode("{\"session_id\":\"s\",\"hook_event_name\":\"Stop\",\"\(key)\":\(value)}")
                XCTAssertEqual(event.kind, .stop)
                XCTAssertEqual(event.outcome, .succeeded)
                XCTAssertNil(event.fullyIdle)
                var store = SessionStore()
                store.apply(HookEnvelope(event: HookEvent(sessionId: "s", hookEventName: "UserPromptSubmit")), at: Date())
                store.apply(HookEnvelope(event: event), at: Date())
                XCTAssertEqual(store.sessions["s"]?.status, .idle)
            }
        }
    }

    func testOldHookAndFutureOutcomeDefaults() throws {
        XCTAssertEqual(try decode(#"{"session_id":"s","hook_event_name":"Stop"}"#).outcome, .succeeded)
        XCTAssertEqual(try decode(#"{"session_id":"s","hook_event_name":"UserPromptSubmit"}"#).outcome, .none)
        XCTAssertEqual(try decode(#"{"session_id":"s","hook_event_name":"Stop","rocky_outcome":"future-value"}"#).outcome, .none)
    }

    func testIdleIsNotSuccessAndFailuresNeverComplete() throws {
        for outcome in [TurnOutcome.failed, .cancelled, .timedOut, .none, .succeeded] {
            var store = SessionStore()
            store.apply(HookEnvelope(event: HookEvent(sessionId: "s", hookEventName: "Stop", outcome: outcome)), at: Date())
            let session = try XCTUnwrap(store.sessions["s"])
            XCTAssertEqual(session.status, .idle)
            XCTAssertEqual(session.completedSuccessfully, outcome == .succeeded)
            let restored = try SessionPersistence.decode(SessionPersistence.encode([session]))
            XCTAssertEqual(restored.first?.lastOutcome, outcome)
        }
        var store = SessionStore()
        store.apply(HookEnvelope(event: HookEvent(sessionId: "s", hookEventName: "Notification", notificationType: "idle_prompt")), at: Date())
        XCTAssertFalse(try XCTUnwrap(store.sessions["s"]).completedSuccessfully)
        store.apply(HookEnvelope(event: HookEvent(sessionId: "s", hookEventName: "Stop", fullyIdle: false)), at: Date())
        XCTAssertEqual(store.sessions["s"]?.status, .delegating)
        XCTAssertFalse(try XCTUnwrap(store.sessions["s"]).completedSuccessfully)
    }

    func testFailedParentDoesNotCelebrateWhenLastChildFinishes() throws {
        var store = SessionStore()
        let tasks = [BackgroundTask(id: "child", kind: "subagent", status: "running")]
        store.apply(HookEnvelope(event: HookEvent(sessionId: "s", hookEventName: "StopFailure", backgroundTasks: tasks)), at: Date())
        XCTAssertEqual(store.sessions["s"]?.status, .delegating)
        store.apply(HookEnvelope(event: HookEvent(sessionId: "s", hookEventName: "SubagentStop", backgroundTasks: [])), at: Date())
        XCTAssertEqual(store.sessions["s"]?.status, .idle)
        XCTAssertFalse(try XCTUnwrap(store.sessions["s"]).completedSuccessfully)
    }

    func testNewTurnClearsPreviousFailure() throws {
        var store = SessionStore()
        store.apply(HookEnvelope(event: HookEvent(sessionId: "s", hookEventName: "StopFailure")), at: Date())
        store.apply(HookEnvelope(event: HookEvent(sessionId: "s", hookEventName: "UserPromptSubmit")), at: Date())
        XCTAssertEqual(store.sessions["s"]?.lastOutcome, TurnOutcome.none)
    }
}
