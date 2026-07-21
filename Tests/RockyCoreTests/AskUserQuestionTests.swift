import XCTest
@testable import RockyCore

final class AskUserQuestionTests: XCTestCase {
    private func input(_ json: String) -> JSONValue {
        try! JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    private let sample = """
    {
      "questions": [
        {
          "question": "Which deployment target?",
          "header": "Target",
          "multiSelect": false,
          "options": [
            {"label": "Production", "description": "Deploy to prod"},
            {"label": "Staging", "description": "Deploy to staging"},
            {"label": "Local only"}
          ]
        }
      ]
    }
    """

    func testParsesQuestionsAndOptions() {
        let request = AskUserQuestionRequest.from(toolName: "AskUserQuestion", input: input(sample))
        XCTAssertEqual(request?.questions.count, 1)
        let question = request?.questions.first
        XCTAssertEqual(question?.text, "Which deployment target?")
        XCTAssertEqual(question?.header, "Target")
        XCTAssertEqual(question?.multiSelect, false)
        XCTAssertEqual(question?.options.map(\.label), ["Production", "Staging", "Local only"])
        XCTAssertEqual(question?.options.first?.description, "Deploy to prod")
        XCTAssertNil(question?.options.last?.description)
    }

    func testIgnoresOtherToolsAndMalformedInput() {
        XCTAssertNil(AskUserQuestionRequest.from(toolName: "Bash", input: input(sample)))
        XCTAssertNil(AskUserQuestionRequest.from(toolName: "AskUserQuestion", input: nil))
        XCTAssertNil(AskUserQuestionRequest.from(
            toolName: "AskUserQuestion",
            input: input(#"{"questions": [{"question": "No options?", "options": []}]}"#)
        ))
    }

    func testUpdatedInputAppendsAnswersAndKeepsQuestions() {
        let original = input(sample)
        let updated = AskUserQuestionRequest.updatedInput(
            original: original,
            answers: ["Which deployment target?": ["Staging"]]
        )
        XCTAssertEqual(updated["answers"]?["Which deployment target?"]?.stringValue, "Staging")
        XCTAssertEqual(updated["questions"], original["questions"])
    }

    func testUpdatedInputJoinsMultiSelectAnswers() {
        let updated = AskUserQuestionRequest.updatedInput(
            original: nil,
            answers: ["Sections?": ["Intro", "Conclusion"]]
        )
        XCTAssertEqual(updated["answers"]?["Sections?"]?.stringValue, "Intro, Conclusion")
    }

    func testAllowStdoutCarriesUpdatedInput() throws {
        let updated = AskUserQuestionRequest.updatedInput(
            original: input(sample),
            answers: ["Which deployment target?": ["Production"]]
        )
        let data = try XCTUnwrap(PermissionRequestOutput.stdout(for: .allow, updatedInput: updated))
        let payload = try JSONDecoder().decode(JSONValue.self, from: data)
        let decision = payload["hookSpecificOutput"]?["decision"]
        XCTAssertEqual(decision?["behavior"]?.stringValue, "allow")
        XCTAssertEqual(
            decision?["updatedInput"]?["answers"]?["Which deployment target?"]?.stringValue,
            "Production"
        )
    }

    func testDenyStdoutOmitsUpdatedInput() throws {
        let data = try XCTUnwrap(PermissionRequestOutput.stdout(for: .deny, updatedInput: .object([:])))
        let payload = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertNil(payload["hookSpecificOutput"]?["decision"]?["updatedInput"])
        XCTAssertEqual(payload["hookSpecificOutput"]?["decision"]?["behavior"]?.stringValue, "deny")
    }
}
