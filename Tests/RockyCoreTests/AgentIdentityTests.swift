import XCTest
@testable import RockyCore

final class AgentIdentityTests: XCTestCase {
    private let grokEnv = ["GROK_SESSION_ID": "s-1"]

    func testDefaultsToClaudeCode() {
        XCTAssertEqual(
            AgentIdentity.resolve(arguments: ["rocky-hook"], environment: [:]),
            "claude-code"
        )
    }

    func testExplicitAgentWins() {
        XCTAssertEqual(
            AgentIdentity.resolve(
                arguments: ["rocky-hook", "--agent", "codex"],
                environment: [:]
            ),
            "codex"
        )
    }

    func testGrokEnvIsSniffedWhenNoFlag() {
        XCTAssertEqual(
            AgentIdentity.resolve(arguments: ["rocky-hook"], environment: grokEnv),
            "grok"
        )
        XCTAssertEqual(
            AgentIdentity.resolve(
                arguments: ["rocky-hook"],
                environment: ["GROK_HOOK_EVENT": "PreToolUse"]
            ),
            "grok"
        )
    }

    /// The regression this guards: Grok shells out to `claude`, which inherits
    /// GROK_SESSION_ID. Without the explicit flag the hook would answer Claude
    /// in Grok's reply shape and the notch approval would silently stop working.
    func testExplicitClaudeBeatsInheritedGrokEnv() {
        XCTAssertEqual(
            AgentIdentity.resolve(
                arguments: ["rocky-hook", "--agent", "claude-code"],
                environment: grokEnv
            ),
            "claude-code"
        )
    }

    func testMalformedFlagFallsBackInsteadOfConsumingGarbage() {
        // Trailing flag with no value.
        XCTAssertEqual(
            AgentIdentity.resolve(arguments: ["rocky-hook", "--agent"], environment: [:]),
            "claude-code"
        )
        // Blank value must not become the agent name.
        XCTAssertEqual(
            AgentIdentity.resolve(arguments: ["rocky-hook", "--agent", "  "], environment: grokEnv),
            "grok"
        )
    }

    func testEmptyGrokEnvValueIsNotASignal() {
        XCTAssertEqual(
            AgentIdentity.resolve(
                arguments: ["rocky-hook"],
                environment: ["GROK_SESSION_ID": ""]
            ),
            "claude-code"
        )
    }
}
