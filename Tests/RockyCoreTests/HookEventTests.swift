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

    func testDecodesGrokCamelCasePayload() throws {
        let event = try decode("""
        {
          "hookEventName": "pre_tool_use",
          "sessionId": "019f8a2b-85d7-75d3-9873-f72239a27629",
          "cwd": "/Users/w/proj",
          "workspaceRoot": "/Users/w/proj/",
          "transcriptPath": "/Users/w/.grok/sessions/abc/events.jsonl",
          "toolName": "run_terminal_command",
          "toolInput": {"command": "npm test"},
          "timestamp": "2026-07-22T14:12:18.417054+00:00"
        }
        """)
        XCTAssertEqual(event.kind, .permissionRequest)
        XCTAssertEqual(event.hookEventName, "PreToolUse")
        XCTAssertEqual(event.sessionId, "019f8a2b-85d7-75d3-9873-f72239a27629")
        XCTAssertEqual(event.cwd, "/Users/w/proj")
        XCTAssertEqual(event.toolName, "run_terminal_command")
        XCTAssertEqual(event.toolSummary, "npm test")
        XCTAssertEqual(event.transcriptPath, "/Users/w/.grok/sessions/abc/events.jsonl")
    }

    func testDecodesGrokLifecycleEventNames() throws {
        for (raw, kind) in [
            ("session_start", HookEvent.Kind.sessionStart),
            ("user_prompt_submit", .userPromptSubmit),
            ("notification", .notification),
            ("stop", .stop),
            ("session_end", .sessionEnd),
        ] as [(String, HookEvent.Kind)] {
            let event = try decode("""
            {"sessionId": "s", "hookEventName": "\(raw)", "cwd": "/tmp"}
            """)
            XCTAssertEqual(event.kind, kind, raw)
        }
    }

    func testGrokToolSummaryUsesTargetFile() throws {
        let event = try decode("""
        {
          "sessionId": "s",
          "hookEventName": "PreToolUse",
          "toolName": "search_replace",
          "toolInput": {"file_path": "/tmp/x.swift", "old_string": "a", "new_string": "b"}
        }
        """)
        XCTAssertEqual(event.toolSummary, "/tmp/x.swift")
    }

    func testDecodesCursorConversationIdAndWorkspaceRoots() throws {
        let event = try decode("""
        {
          "conversation_id": "conv-abc",
          "generation_id": "gen-1",
          "hook_event_name": "preToolUse",
          "workspace_roots": ["/Users/w/proj", "/Users/w/other"],
          "tool_name": "Shell",
          "tool_input": {"command": "npm test"},
          "model": "claude-opus-4"
        }
        """)
        XCTAssertEqual(event.kind, .permissionRequest)
        XCTAssertEqual(event.hookEventName, "PreToolUse")
        XCTAssertEqual(event.sessionId, "conv-abc")
        XCTAssertEqual(event.cwd, "/Users/w/proj")
        XCTAssertEqual(event.toolName, "Shell")
        XCTAssertEqual(event.toolSummary, "npm test")
        XCTAssertEqual(event.model, "claude-opus-4")
    }

    func testDecodesCursorBeforeShellExecution() throws {
        let event = try decode("""
        {
          "conversation_id": "c1",
          "hook_event_name": "beforeShellExecution",
          "command": "rm -rf /tmp/x",
          "cwd": "/Users/w/proj",
          "sandbox": false
        }
        """)
        XCTAssertEqual(event.kind, .permissionRequest)
        XCTAssertEqual(event.hookEventName, "BeforeShellExecution")
        XCTAssertEqual(event.toolName, "Shell")
        XCTAssertEqual(event.toolSummary, "rm -rf /tmp/x")
        XCTAssertEqual(event.cwd, "/Users/w/proj")
    }

    func testDecodesCursorBeforeSubmitPrompt() throws {
        let event = try decode("""
        {
          "conversation_id": "c1",
          "hook_event_name": "beforeSubmitPrompt",
          "prompt": "fix the auth bug",
          "workspace_roots": ["/tmp/p"]
        }
        """)
        XCTAssertEqual(event.kind, .userPromptSubmit)
        XCTAssertEqual(event.prompt, "fix the auth bug")
        XCTAssertEqual(event.cwd, "/tmp/p")
    }

    /// Kimi sends UserPromptSubmit `prompt` as a structured array, not a string.
    /// Decoding must still yield the text so the "You: …" task chip works —
    /// a plain String decode would throw and drop the whole event.
    func testDecodesKimiArrayPrompt() throws {
        let event = try decode("""
        {
          "session_id": "s",
          "hook_event_name": "UserPromptSubmit",
          "prompt": [{"type": "text", "text": "fix the auth bug"}]
        }
        """)
        XCTAssertEqual(event.kind, .userPromptSubmit)
        XCTAssertEqual(event.prompt, "fix the auth bug")
    }

    func testKimiMultiPartPromptJoinsTextAndSkipsNonText() throws {
        let event = try decode("""
        {
          "session_id": "s",
          "hook_event_name": "UserPromptSubmit",
          "prompt": [
            {"type": "text", "text": "look at"},
            {"type": "image"},
            {"type": "text", "text": "this screenshot"}
          ]
        }
        """)
        XCTAssertEqual(event.prompt, "look at this screenshot")
    }
}
