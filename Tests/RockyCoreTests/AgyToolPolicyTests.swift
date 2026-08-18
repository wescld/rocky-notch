import XCTest
@testable import RockyCore

final class AgyToolPolicyTests: XCTestCase {
    func testAutoPassesReadOnlyTools() {
        for name in [
            "view_file", "list_dir", "find_by_name", "grep_search",
            "search_web", "read_url_content", "list_permissions", "ask_question",
        ] {
            XCTAssertTrue(AgyToolPolicy.shouldAutoPass(toolName: name), name)
        }
    }

    func testDoesNotAutoPassWriteOrShell() {
        for name in [
            "run_command", "write_to_file", "replace_file_content",
            "multi_replace_file_content", "invoke_subagent", "ask_permission",
        ] {
            XCTAssertFalse(AgyToolPolicy.shouldAutoPass(toolName: name), name)
        }
    }

    func testNilAndEmpty() {
        XCTAssertFalse(AgyToolPolicy.shouldAutoPass(toolName: nil))
        XCTAssertFalse(AgyToolPolicy.shouldAutoPass(toolName: ""))
    }

    func testAlwaysProceedModeNames() {
        for name in [
            "always-proceed", "always_proceed",
            "dangerously-skip-permissions", "YOLO",
        ] {
            XCTAssertTrue(AgyToolPolicy.isAlwaysProceedModeName(name), name)
        }
        for name in ["request-review", "strict", "accept-edits", ""] {
            XCTAssertFalse(AgyToolPolicy.isAlwaysProceedModeName(name), name)
        }
    }

    func testAlwaysProceedFromPayloadSkipsGateForShell() {
        XCTAssertTrue(
            AgyToolPolicy.shouldSkipRockyGate(
                toolName: "run_command",
                permissionMode: "always-proceed",
                home: "/tmp/no-such-home"
            )
        )
        XCTAssertFalse(
            AgyToolPolicy.shouldSkipRockyGate(
                toolName: "run_command",
                permissionMode: "request-review",
                home: "/tmp/no-such-home"
            )
        )
    }

    func testLaunchFlagFromArguments() {
        XCTAssertEqual(
            AgyToolPolicy.permissionMode(fromArguments: [
                "agy", "--dangerously-skip-permissions", "-p", "hi",
            ]),
            "dangerously-skip-permissions"
        )
        XCTAssertNil(
            AgyToolPolicy.permissionMode(fromArguments: ["agy", "-p", "hi"])
        )
        XCTAssertTrue(
            AgyToolPolicy.shouldSkipRockyGate(
                toolName: "run_command",
                permissionMode: AgyToolPolicy.permissionMode(
                    fromArguments: ["agy", "--dangerously-skip-permissions"]
                ),
                home: "/tmp/no-such-home"
            )
        )
    }

    func testConfigSaysAlwaysProceed() {
        XCTAssertTrue(
            AgyToolPolicy.configSaysAlwaysProceed(["toolPermission": "always-proceed"])
        )
        XCTAssertTrue(
            AgyToolPolicy.configSaysAlwaysProceed([
                "userSettings": ["toolPermission": "always-proceed"]
            ])
        )
        XCTAssertFalse(
            AgyToolPolicy.configSaysAlwaysProceed(["toolPermission": "request-review"])
        )
        XCTAssertFalse(AgyToolPolicy.configSaysAlwaysProceed([:]))
    }
}
