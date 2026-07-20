import XCTest
@testable import VibenotchCore

final class TranscriptTailTests: XCTestCase {
    func chunk(_ lines: String...) -> Data {
        Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    func testExtractsToolUseWithCommand() {
        let data = chunk(
            #"{"type":"user","message":{"content":"oi"}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"npm test"}}]}}"#
        )
        XCTAssertEqual(TranscriptTail.lastAction(in: data), "Bash: npm test")
    }

    func testExtractsFilePathForEdit() {
        let data = chunk(
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/a/b.swift"}}]}}"#
        )
        XCTAssertEqual(TranscriptTail.lastAction(in: data), "Edit: /a/b.swift")
    }

    func testFallsBackToTextSnippet() {
        let data = chunk(
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Vou começar pelo scaffold do projeto."}]}}"#
        )
        XCTAssertEqual(
            TranscriptTail.lastAction(in: data),
            "Vou começar pelo scaffold do projeto."
        )
    }

    func testNewestLineWins() {
        let data = chunk(
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"old"}}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"new"}}]}}"#
        )
        XCTAssertEqual(TranscriptTail.lastAction(in: data), "Bash: new")
    }

    func testMalformedAndForeignLinesSkipped() {
        let data = chunk(
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/x"}}]}}"#,
            "not json at all",
            #"{"type":"summary","whatever":1}"#
        )
        XCTAssertEqual(TranscriptTail.lastAction(in: data), "Read: /x")
    }

    func testLongTextTruncated() throws {
        let long = String(repeating: "a", count: 200)
        let data = chunk(
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"\#(long)"}]}}"#
        )
        let action = try XCTUnwrap(TranscriptTail.lastAction(in: data))
        XCTAssertEqual(action.count, 80)
        XCTAssertTrue(action.hasSuffix("…"))
    }

    func testEmptyChunkReturnsNil() {
        XCTAssertNil(TranscriptTail.lastAction(in: Data()))
    }

    func testScanSumsUsageExcludingCacheReads() {
        let data = chunk(
            #"{"type":"assistant","message":{"usage":{"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":30,"cache_read_input_tokens":9000},"content":[{"type":"text","text":"oi"}]}}"#,
            #"{"type":"user","message":{"content":"x"}}"#,
            #"{"type":"assistant","message":{"usage":{"input_tokens":10,"output_tokens":5},"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}"#
        )
        let update = TranscriptTail.scan(data)
        XCTAssertEqual(update.tokens, 195)
        XCTAssertEqual(update.lastAction, "Bash: ls")
    }
}
