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
}
