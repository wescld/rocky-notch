import XCTest
@testable import VibenotchCore

final class IPCTests: XCTestCase {
    func testEnvelopeRoundTrip() throws {
        let envelope = HookEnvelope(
            requestId: "req-1",
            hookPid: 42,
            agent: "claude-code",
            event: HookEvent(
                sessionId: "s1",
                hookEventName: "PermissionRequest",
                cwd: "/tmp/x",
                toolName: "Bash",
                toolInput: .object(["command": .string("ls")])
            )
        )
        let line = try NDJSON.encodeLine(envelope)
        XCTAssertEqual(line.last, 0x0A)
        let decoded = try NDJSON.decode(HookEnvelope.self, from: line.dropLast())
        XCTAssertEqual(decoded, envelope)
    }

    func testDecisionRoundTrip() throws {
        for decision in [Decision.allow, .deny, .ask, .passthrough] {
            let msg = DecisionMessage(requestId: "r", decision: decision)
            let line = try NDJSON.encodeLine(msg)
            XCTAssertEqual(try NDJSON.decode(DecisionMessage.self, from: line), msg)
        }
    }

    func testPermissionOutputAllowDeny() throws {
        for decision in [Decision.allow, .deny] {
            let data = try XCTUnwrap(PermissionRequestOutput.stdout(for: decision))
            let root = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            let specific = try XCTUnwrap(root["hookSpecificOutput"] as? [String: Any])
            XCTAssertEqual(specific["hookEventName"] as? String, "PermissionRequest")
            let inner = try XCTUnwrap(specific["decision"] as? [String: Any])
            XCTAssertEqual(inner["behavior"] as? String, decision.rawValue)
        }
    }

    func testPermissionOutputSilentForAskAndPassthrough() {
        XCTAssertNil(PermissionRequestOutput.stdout(for: .ask))
        XCTAssertNil(PermissionRequestOutput.stdout(for: .passthrough))
    }

    func testSocketPath() {
        XCTAssertEqual(
            IPC.socketPath(home: "/Users/w"),
            "/Users/w/Library/Application Support/vibenotch/vibenotch.sock"
        )
    }
}
