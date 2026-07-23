import XCTest
@testable import RockyCore

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

    func testGrokPermissionOutputFormat() throws {
        let allow = try XCTUnwrap(PermissionRequestOutput.stdout(for: .allow, agent: "grok"))
        let allowRoot = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: allow) as? [String: Any]
        )
        XCTAssertEqual(allowRoot["decision"] as? String, "allow")
        XCTAssertNil(allowRoot["hookSpecificOutput"])

        let deny = try XCTUnwrap(PermissionRequestOutput.stdout(for: .deny, agent: "grok"))
        let denyRoot = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: deny) as? [String: Any]
        )
        XCTAssertEqual(denyRoot["decision"] as? String, "deny")
        XCTAssertEqual(denyRoot["reason"] as? String, "Denied in Rocky")

        XCTAssertNil(PermissionRequestOutput.stdout(for: .passthrough, agent: "grok"))
    }

    func testKimiPermissionOutputFormat() throws {
        // Kimi's PreToolUse hook is deny-only: only deny prints, as
        // hookSpecificOutput.permissionDecision (not Claude's decision.behavior).
        let deny = try XCTUnwrap(PermissionRequestOutput.stdout(for: .deny, agent: "kimi-code"))
        let denyRoot = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: deny) as? [String: Any]
        )
        let specific = try XCTUnwrap(denyRoot["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(specific["permissionDecision"] as? String, "deny")
        XCTAssertEqual(specific["permissionDecisionReason"] as? String, "Denied in Rocky")
        // Must not leak the Claude-shaped payload Kimi would ignore.
        XCTAssertNil(specific["decision"])
        XCTAssertNil(specific["behavior"])

        // Allow is not expressible (deny-only): the hook exits silently so
        // Kimi's own permission flow proceeds. Same for ask / passthrough.
        XCTAssertNil(PermissionRequestOutput.stdout(for: .allow, agent: "kimi-code"))
        XCTAssertNil(PermissionRequestOutput.stdout(for: .ask, agent: "kimi-code"))
        XCTAssertNil(PermissionRequestOutput.stdout(for: .passthrough, agent: "kimi-code"))
    }

    func testSocketPath() {
        XCTAssertEqual(
            IPC.socketPath(home: "/Users/w"),
            "/Users/w/Library/Application Support/rocky/rocky.sock"
        )
    }

    func testCursorPermissionOutputFormat() throws {
        let allow = try XCTUnwrap(PermissionRequestOutput.stdout(for: .allow, agent: "cursor"))
        let allowRoot = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: allow) as? [String: Any]
        )
        XCTAssertEqual(allowRoot["permission"] as? String, "allow")
        XCTAssertEqual(allowRoot["continue"] as? Bool, true)
        XCTAssertNil(allowRoot["user_message"])
        XCTAssertNil(allowRoot["userMessage"])

        let deny = try XCTUnwrap(PermissionRequestOutput.stdout(for: .deny, agent: "cursor"))
        let denyRoot = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: deny) as? [String: Any]
        )
        XCTAssertEqual(denyRoot["permission"] as? String, "deny")
        XCTAssertEqual(denyRoot["continue"] as? Bool, false)
        XCTAssertEqual(denyRoot["userMessage"] as? String, "Denied in Rocky")
        XCTAssertEqual(
            denyRoot["agentMessage"] as? String,
            "The user denied this action in Rocky."
        )
        XCTAssertNil(denyRoot["user_message"])

        let ask = try XCTUnwrap(PermissionRequestOutput.stdout(for: .ask, agent: "cursor"))
        let askRoot = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: ask) as? [String: Any]
        )
        XCTAssertEqual(askRoot["permission"] as? String, "ask")
        XCTAssertEqual(askRoot["continue"] as? Bool, true)
        XCTAssertEqual(askRoot["userMessage"] as? String, "Approve in Rocky or Cursor")

        XCTAssertNil(PermissionRequestOutput.stdout(for: .passthrough, agent: "cursor"))
    }
}
