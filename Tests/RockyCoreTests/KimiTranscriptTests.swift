import XCTest
@testable import RockyCore

final class KimiTranscriptTests: XCTestCase {
    private func loopEvent(_ type: String, text: String? = nil) -> String {
        var event: [String: Any] = ["type": type]
        if let text {
            event["part"] = ["type": "text", "text": text]
        }
        let object: [String: Any] = ["type": "context.append_loop_event", "event": event]
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(data: data, encoding: .utf8)!
    }

    private func tail(_ lines: [String]) -> Data {
        Data(lines.joined(separator: "\n").utf8)
    }

    func testReadsTheClosingProse() {
        let chunk = tail([
            loopEvent("step.begin"),
            loopEvent("content.part", text: "Em que tarefa você quer que eu trabalhe agora?"),
        ])
        XCTAssertEqual(
            KimiTranscript.lastAssistantText(inTail: chunk),
            "Em que tarefa você quer que eu trabalhe agora?"
        )
    }

    func testJoinsPartsOfTheSameStretch() {
        let chunk = tail([
            loopEvent("content.part", text: "Terminei a análise."),
            loopEvent("content.part", text: "Quer que eu aplique a correção?"),
        ])
        XCTAssertEqual(
            KimiTranscript.lastAssistantText(inTail: chunk),
            "Terminei a análise.\nQuer que eu aplique a correção?"
        )
    }

    /// Prose before a tool call is narration ("let me check X"), not the
    /// handoff — the agent went back to work after saying it.
    func testDiscardsProseFollowedByMoreWork() {
        let chunk = tail([
            loopEvent("content.part", text: "Vou ler os arquivos primeiro."),
            loopEvent("tool.call"),
            loopEvent("tool.result"),
            loopEvent("content.part", text: "Pronto. Posso seguir?"),
        ])
        XCTAssertEqual(KimiTranscript.lastAssistantText(inTail: chunk), "Pronto. Posso seguir?")
    }

    func testReturnsNilWhenTurnEndedOnAToolCall() {
        let chunk = tail([
            loopEvent("content.part", text: "Aplicando o patch."),
            loopEvent("tool.call"),
        ])
        XCTAssertNil(KimiTranscript.lastAssistantText(inTail: chunk))
    }

    /// Reading only the tail means the first line is usually cut mid-JSON.
    func testSurvivesATruncatedLeadingLine() {
        let chunk = Data(
            ("part\":{\"type\":\"text\",\"text\":\"cortado\"}}}\n"
                + loopEvent("content.part", text: "íntegro")).utf8
        )
        XCTAssertEqual(KimiTranscript.lastAssistantText(inTail: chunk), "íntegro")
    }

    func testIgnoresUnrelatedRecords() {
        let chunk = tail([
            #"{"type":"usage.record","tokens":42}"#,
            #"{"type":"context.append_message","message":{"role":"user"}}"#,
            loopEvent("content.part", text: "resposta"),
        ])
        XCTAssertEqual(KimiTranscript.lastAssistantText(inTail: chunk), "resposta")
    }

    func testEmptyAndGarbageYieldNil() {
        XCTAssertNil(KimiTranscript.lastAssistantText(inTail: Data()))
        XCTAssertNil(KimiTranscript.lastAssistantText(inTail: Data("not json at all".utf8)))
        XCTAssertNil(KimiTranscript.lastAssistantText(inTail: tail([loopEvent("content.part", text: "   ")])))
    }

    // MARK: - Locating the log

    func testFindsWireLogAcrossWorkspaces() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kimi-\(UUID().uuidString)")
        let id = "abc-123"
        let log = home
            .appendingPathComponent("sessions/wd_project_deadbeef/session_\(id)/agents/main")
        try FileManager.default.createDirectory(at: log, withIntermediateDirectories: true)
        // A second workspace that does not hold this session.
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("sessions/wd_other_cafe"),
            withIntermediateDirectories: true
        )
        let file = log.appendingPathComponent("wire.jsonl")
        try Data(loopEvent("content.part", text: "oi").utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: home) }

        // Resolved on both sides: the temp dir is reached through /var, a
        // symlink to /private/var.
        XCTAssertEqual(
            KimiTranscript.wireLogURL(sessionId: id, home: home.path)?
                .resolvingSymlinksInPath().path,
            file.resolvingSymlinksInPath().path
        )
        XCTAssertEqual(KimiTranscript.lastAssistantMessage(sessionId: id, home: home.path), "oi")

        // What Kimi actually sends on the hook: the id already prefixed.
        XCTAssertEqual(
            KimiTranscript.lastAssistantMessage(sessionId: "session_\(id)", home: home.path),
            "oi"
        )
    }

    func testMissingSessionYieldsNil() {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kimi-missing-\(UUID().uuidString)")
        XCTAssertNil(KimiTranscript.wireLogURL(sessionId: "nope", home: home.path))
        XCTAssertNil(KimiTranscript.lastAssistantMessage(sessionId: "nope", home: home.path))
        XCTAssertNil(KimiTranscript.wireLogURL(sessionId: "", home: home.path))
    }

    func testHomeHonoursKimiCodeHome() {
        XCTAssertEqual(
            KimiTranscript.defaultHome(environment: ["KIMI_CODE_HOME": "/custom/kimi"]),
            "/custom/kimi"
        )
        XCTAssertTrue(KimiTranscript.defaultHome(environment: [:]).hasSuffix("/.kimi-code"))
    }
}
