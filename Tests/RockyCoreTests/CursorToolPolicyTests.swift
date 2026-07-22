import XCTest
@testable import RockyCore

final class CursorToolPolicyTests: XCTestCase {
    func testPromptsForShellAndMCPHooks() {
        XCTAssertTrue(
            CursorToolPolicy.shouldPrompt(
                toolName: "Shell",
                hookEventName: "beforeShellExecution"
            )
        )
        XCTAssertTrue(
            CursorToolPolicy.shouldPrompt(
                toolName: "MCP:linear__save_issue",
                hookEventName: "beforeMCPExecution"
            )
        )
        XCTAssertTrue(CursorToolPolicy.shouldPrompt(toolName: "Shell"))
        XCTAssertTrue(CursorToolPolicy.shouldPrompt(toolName: "Bash"))
    }

    func testAutoPassesReadFileAndUnknown() {
        XCTAssertTrue(
            CursorToolPolicy.shouldAutoPass(
                toolName: nil,
                hookEventName: "beforeReadFile"
            )
        )
        XCTAssertTrue(CursorToolPolicy.shouldAutoPass(toolName: "Read"))
        XCTAssertTrue(CursorToolPolicy.shouldAutoPass(toolName: nil))
        XCTAssertTrue(CursorToolPolicy.shouldAutoPass(toolName: ""))
    }

    func testDoesNotPromptForWritesViaPolicy() {
        // Cursor has no beforeWrite; afterFileEdit is observational.
        XCTAssertTrue(CursorToolPolicy.shouldAutoPass(toolName: "Write"))
        XCTAssertTrue(CursorToolPolicy.shouldAutoPass(toolName: "Delete"))
    }
}
