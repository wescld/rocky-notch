import XCTest
@testable import RockyCore

final class KimiToolPolicyTests: XCTestCase {
    func testAutoPassesKimiAutoApprovedTools() {
        for name in [
            "Read", "Grep", "Glob", "WebSearch", "FetchURL", "Skill",
            "TodoList", "Agent", "AskUserQuestion", "select_tools",
        ] {
            XCTAssertTrue(KimiToolPolicy.shouldAutoPass(toolName: name), name)
        }
    }

    func testDoesNotAutoPassWriteShellOrMCP() {
        for name in [
            "Write", "Edit", "Bash", "CronCreate", "AgentSwarm",
            "mcp__github__create_issue", "SomeUnknownTool",
        ] {
            XCTAssertFalse(KimiToolPolicy.shouldAutoPass(toolName: name), name)
        }
    }

    func testMatchIsCaseSensitive() {
        // Kimi's tool names are exact; a case variant is an unknown tool and
        // must be gated rather than silently auto-passed.
        XCTAssertFalse(KimiToolPolicy.shouldAutoPass(toolName: "read"))
        XCTAssertFalse(KimiToolPolicy.shouldAutoPass(toolName: "BASH"))
    }

    func testNilAndEmpty() {
        XCTAssertFalse(KimiToolPolicy.shouldAutoPass(toolName: nil))
        XCTAssertFalse(KimiToolPolicy.shouldAutoPass(toolName: ""))
    }
}
