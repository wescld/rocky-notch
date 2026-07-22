import XCTest
@testable import RockyCore

final class CursorToolPolicyTests: XCTestCase {
    func testAutoPassesReadOnlyTools() {
        for name in ["Read", "Grep", "Glob", "SemanticSearch", "ReadLints", "TodoWrite"] {
            XCTAssertTrue(CursorToolPolicy.shouldAutoPass(toolName: name), name)
        }
    }

    func testDoesNotAutoPassWriteShellOrMCP() {
        for name in ["Shell", "Write", "Delete", "Task", "MCP:linear__save_issue", "Bash"] {
            XCTAssertFalse(CursorToolPolicy.shouldAutoPass(toolName: name), name)
        }
    }

    func testNilAndEmpty() {
        XCTAssertFalse(CursorToolPolicy.shouldAutoPass(toolName: nil))
        XCTAssertFalse(CursorToolPolicy.shouldAutoPass(toolName: ""))
    }

    func testAlwaysApproveModeNames() {
        for name in [
            "yolo", "YOLO", "full-auto", "fullAutoRun", "full_auto",
            "auto-run", "always-approve", "bypassPermissions",
        ] {
            XCTAssertTrue(CursorToolPolicy.isAlwaysApproveModeName(name), name)
        }
        for name in ["default", "ask", "plan", "agent", ""] {
            XCTAssertFalse(CursorToolPolicy.isAlwaysApproveModeName(name), name)
        }
    }

    func testAlwaysApproveFromPayloadSkipsGateForWrite() {
        XCTAssertTrue(
            CursorToolPolicy.shouldSkipRockyGate(
                toolName: "Write",
                permissionMode: "yolo",
                home: "/tmp/no-such-home"
            )
        )
        XCTAssertFalse(
            CursorToolPolicy.shouldSkipRockyGate(
                toolName: "Write",
                permissionMode: "default",
                home: "/tmp/no-such-home"
            )
        )
    }

    func testParseAlwaysApproveFromApplicationUserJSON() {
        let yolo = """
        {
          "composerState": {
            "modes4": [
              {
                "id": "agent",
                "name": "Agent",
                "autoRun": true,
                "fullAutoRun": true,
                "shouldAutoApplyIfNoEditTool": true
              },
              {
                "id": "plan",
                "name": "Plan",
                "autoRun": false,
                "fullAutoRun": false
              }
            ]
          }
        }
        """
        XCTAssertTrue(CursorToolPolicy.parseAlwaysApprove(fromApplicationUserJSON: yolo))

        let autoRunOnly = """
        {
          "composerState": {
            "modes4": [
              {
                "id": "agent",
                "autoRun": true,
                "fullAutoRun": false
              }
            ]
          }
        }
        """
        // autoRun alone is not full YOLO — Cursor may still prompt for some tools.
        XCTAssertFalse(CursorToolPolicy.parseAlwaysApprove(fromApplicationUserJSON: autoRunOnly))

        let normal = """
        {
          "composerState": {
            "modes4": [
              { "id": "agent", "autoRun": false, "fullAutoRun": false }
            ]
          }
        }
        """
        XCTAssertFalse(CursorToolPolicy.parseAlwaysApprove(fromApplicationUserJSON: normal))

        // Plan mode YOLO must not count — only Agent.
        let planOnly = """
        {
          "composerState": {
            "modes4": [
              { "id": "plan", "fullAutoRun": true },
              { "id": "agent", "fullAutoRun": false }
            ]
          }
        }
        """
        XCTAssertFalse(CursorToolPolicy.parseAlwaysApprove(fromApplicationUserJSON: planOnly))

        XCTAssertFalse(CursorToolPolicy.parseAlwaysApprove(fromApplicationUserJSON: "{}"))
        XCTAssertFalse(CursorToolPolicy.parseAlwaysApprove(fromApplicationUserJSON: "not-json"))
    }

    func testReadOnlyStillSkipsWithoutYolo() {
        XCTAssertTrue(
            CursorToolPolicy.shouldSkipRockyGate(
                toolName: "Read",
                permissionMode: nil,
                home: "/tmp/no-such-home"
            )
        )
    }
}
