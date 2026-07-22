import XCTest
@testable import RockyCore

final class GrokToolPolicyTests: XCTestCase {
    func testAutoPassesReadOnlyTools() {
        for name in ["read_file", "Read", "grep", "list_dir", "todo_write", "web_search"] {
            XCTAssertTrue(GrokToolPolicy.shouldAutoPass(toolName: name), name)
        }
    }

    func testDoesNotAutoPassWriteOrShell() {
        for name in [
            "run_terminal_command", "Bash", "search_replace", "Edit",
            "write", "Write", "spawn_subagent", "use_tool",
        ] {
            XCTAssertFalse(GrokToolPolicy.shouldAutoPass(toolName: name), name)
        }
    }

    func testNilAndEmpty() {
        XCTAssertFalse(GrokToolPolicy.shouldAutoPass(toolName: nil))
        XCTAssertFalse(GrokToolPolicy.shouldAutoPass(toolName: ""))
    }

    func testAlwaysApproveModeNames() {
        for name in [
            "always-approve", "always_approve", "bypassPermissions",
            "bypass-permissions", "YOLO", "yolo",
        ] {
            XCTAssertTrue(GrokToolPolicy.isAlwaysApproveModeName(name), name)
        }
        for name in ["default", "dontAsk", "acceptEdits", "plan", ""] {
            XCTAssertFalse(GrokToolPolicy.isAlwaysApproveModeName(name), name)
        }
    }

    func testAlwaysApproveFromPayloadSkipsGateForShell() {
        XCTAssertTrue(
            GrokToolPolicy.shouldSkipRockyGate(
                toolName: "run_terminal_command",
                permissionMode: "bypassPermissions",
                home: "/tmp/no-such-home"
            )
        )
        XCTAssertFalse(
            GrokToolPolicy.shouldSkipRockyGate(
                toolName: "run_terminal_command",
                permissionMode: "default",
                home: "/tmp/no-such-home"
            )
        )
    }

    func testParseAlwaysApproveFromConfigTOML() {
        let always = """
        [ui]
        permission_mode = "always-approve"
        yolo = false
        """
        XCTAssertTrue(GrokToolPolicy.parseAlwaysApprove(fromTOML: always))

        let yolo = """
        [ui]
        permission_mode = "default"
        yolo = true
        """
        XCTAssertTrue(GrokToolPolicy.parseAlwaysApprove(fromTOML: yolo))

        let normal = """
        [ui]
        permission_mode = "default"
        yolo = false

        [models]
        default = "grok-4.5"
        """
        XCTAssertFalse(GrokToolPolicy.parseAlwaysApprove(fromTOML: normal))

        // Keys outside [ui] must not count.
        let wrongSection = """
        [models]
        permission_mode = "always-approve"
        """
        XCTAssertFalse(GrokToolPolicy.parseAlwaysApprove(fromTOML: wrongSection))
    }
}
