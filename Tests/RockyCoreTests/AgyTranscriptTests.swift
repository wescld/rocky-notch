import XCTest
@testable import RockyCore

final class AgyTranscriptTests: XCTestCase {
    func testUserRequestExtractsInnerBlock() {
        let content = """
        <USER_REQUEST>
        Fix the flaky auth tests.
        </USER_REQUEST>
        <ADDITIONAL_METADATA>
        now
        </ADDITIONAL_METADATA>
        """
        XCTAssertEqual(AgyTranscript.userRequest(from: content), "Fix the flaky auth tests.")
    }

    func testUnquoteStripsOnePair() {
        XCTAssertEqual(AgyTranscript.unquote("\"/tmp/x\""), "/tmp/x")
        XCTAssertEqual(AgyTranscript.unquote("/tmp/x"), "/tmp/x")
        XCTAssertEqual(
            AgyTranscript.unquoteArgs(["CommandLine": "\"echo done\""])?["CommandLine"] as? String,
            "echo done"
        )
    }

    func testLastAssistantIgnoresToolNarration() {
        let tail = """
        {"source":"MODEL","type":"PLANNER_RESPONSE","tool_calls":[{"name":"run_command","args":{}}]}
        {"source":"MODEL","type":"PLANNER_RESPONSE","content":"All tests passed. Want me to commit?"}
        """
        XCTAssertEqual(
            AgyTranscript.lastAssistantText(inTail: Data(tail.utf8)),
            "All tests passed. Want me to commit?"
        )
    }

    func testLastAssistantDropsProseBeforeLaterTools() {
        let tail = """
        {"source":"MODEL","type":"PLANNER_RESPONSE","content":"Let me check."}
        {"source":"MODEL","type":"PLANNER_RESPONSE","tool_calls":[{"name":"view_file"}]}
        """
        XCTAssertNil(AgyTranscript.lastAssistantText(inTail: Data(tail.utf8)))
    }

    func testLaterActionClearsEarlierProse() {
        let tail = """
        {"source":"MODEL","type":"PLANNER_RESPONSE","content":"All tests passed."}
        {"source":"MODEL","type":"CODE_ACTION","content":"Created file hello.txt"}
        """
        XCTAssertNil(AgyTranscript.lastAssistantText(inTail: Data(tail.utf8)))
    }

    func testAskQuestionWinsAsHandoff() {
        let tail = """
        {"source":"MODEL","type":"PLANNER_RESPONSE","content":"Thinking"}
        {"source":"MODEL","type":"ASK_QUESTION","content":"Which test file should I edit?"}
        """
        XCTAssertEqual(
            AgyTranscript.lastAssistantText(inTail: Data(tail.utf8)),
            "Which test file should I edit?"
        )
    }
}
