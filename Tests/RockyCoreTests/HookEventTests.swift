import XCTest
@testable import RockyCore

final class HookEventTests: XCTestCase {
    func decode(_ json: String) throws -> HookEvent {
        try JSONDecoder().decode(HookEvent.self, from: Data(json.utf8))
    }

    func testDecodesPermissionRequest() throws {
        let event = try decode("""
        {
          "session_id": "abc123",
          "cwd": "/Users/w/proj",
          "permission_mode": "default",
          "hook_event_name": "PermissionRequest",
          "tool_name": "Bash",
          "tool_input": {"command": "npm test"}
        }
        """)
        XCTAssertEqual(event.kind, .permissionRequest)
        XCTAssertEqual(event.toolName, "Bash")
        XCTAssertEqual(event.toolSummary, "npm test")
    }

    func testDecodesSessionStartWithExtraUnknownFields() throws {
        let event = try decode("""
        {
          "session_id": "abc123",
          "hook_event_name": "SessionStart",
          "source": "startup",
          "model": "claude-sonnet-5",
          "session_title": "auth-refactor",
          "some_future_field": {"nested": [1, 2]}
        }
        """)
        XCTAssertEqual(event.kind, .sessionStart)
        XCTAssertEqual(event.sessionTitle, "auth-refactor")
    }

    func testDecodesNotificationType() throws {
        let event = try decode("""
        {"session_id": "s", "hook_event_name": "Notification",
         "message": "waiting", "type": "idle_prompt"}
        """)
        XCTAssertEqual(event.kind, .notification)
        XCTAssertEqual(event.notificationType, "idle_prompt")
    }

    func testUnknownEventNameDoesNotFail() throws {
        let event = try decode("""
        {"session_id": "s", "hook_event_name": "SomethingNew"}
        """)
        XCTAssertEqual(event.kind, .unknown("SomethingNew"))
    }

    func testToolSummaryForEdit() throws {
        let event = try decode("""
        {"session_id": "s", "hook_event_name": "PermissionRequest",
         "tool_name": "Edit", "tool_input": {"file_path": "/a/b.swift"}}
        """)
        XCTAssertEqual(event.toolSummary, "/a/b.swift")
    }
}
