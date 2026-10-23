import XCTest
@testable import RockyCore

/// Env/argv fixtures are the values Claude Code 2.1.295 actually handed a
/// capture hook on 2026-10-09 (interactive TUI, `claude -p`, Python Agent SDK).
final class ClaudeHeadlessPolicyTests: XCTestCase {
    private let tuiEnv = [
        "CLAUDE_CODE_ENTRYPOINT": "cli",
        "CLAUDE_CODE_SESSION_ATTENDED": "1",
        "CLAUDECODE": "1",
        "CLAUDE_PID": "39403",
    ]
    private let tuiArgv = [
        "claude", "--setting-sources", "", "--settings", "/tmp/s.json",
        "--model", "haiku", "--permission-mode", "default",
    ]
    private let printEnv = [
        "CLAUDE_CODE_ENTRYPOINT": "sdk-cli",
        "CLAUDE_CODE_SESSION_ATTENDED": "0",
        "CLAUDECODE": "1",
        "CLAUDE_PID": "38219",
    ]
    private let printArgv = ["claude", "-p", "--model", "haiku", "Use the Bash tool"]
    private let sdkEnv = [
        "CLAUDE_CODE_ENTRYPOINT": "sdk-py",
        "CLAUDE_CODE_SESSION_ATTENDED": "0",
        "CLAUDE_PID": "43558",
    ]
    private let sdkArgv = [
        "/Users/me/.local/bin/claude", "--output-format", "stream-json", "--verbose",
        "--input-format", "stream-json",
    ]
    private let hookArgv = ["/Applications/Rocky.app/Contents/MacOS/rocky-hook", "--agent", "claude-code"]

    /// Every hook event kind Rocky receives, the blocking one included.
    private let allKinds: [HookEvent.Kind] = [
        .sessionStart, .sessionEnd, .stop, .subagentStart, .subagentStop, .notification,
        .permissionRequest, .postToolUse, .userPromptSubmit, .unknown("PreCompact"),
    ]

    // MARK: - Detection

    func testInteractiveTuiIsNotHeadless() {
        XCTAssertNil(ClaudeHeadlessPolicy.headlessSignal(environment: tuiEnv, parentArguments: tuiArgv))
    }

    func testPrintRunIsHeadlessFromEnvironment() {
        XCTAssertEqual(
            ClaudeHeadlessPolicy.headlessSignal(environment: printEnv, parentArguments: printArgv),
            .sdkEntrypoint("sdk-cli")
        )
    }

    func testPythonAgentSdkIsHeadlessEvenWithoutPrintFlag() {
        XCTAssertFalse(ClaudeHeadlessPolicy.isPrintMode(arguments: sdkArgv))
        XCTAssertEqual(
            ClaudeHeadlessPolicy.headlessSignal(environment: sdkEnv, parentArguments: sdkArgv),
            .sdkEntrypoint("sdk-py")
        )
    }

    /// Owner decision: T3 Code (TypeScript Agent SDK, full-access auto-approve)
    /// keeps the notch card as its only chance to deny.
    func testTypeScriptSdkKeepsCards() {
        XCTAssertNil(
            ClaudeHeadlessPolicy.headlessSignal(
                environment: ["CLAUDE_CODE_ENTRYPOINT": "sdk-ts", "CLAUDE_CODE_SESSION_ATTENDED": "0"],
                parentArguments: sdkArgv
            )
        )
    }

    func testUnknownEntrypointsKeepCards() {
        for entrypoint in ["sdk-go", "sdk", "claude-desktop", "claude-vscode", "remote", "cli"] {
            XCTAssertNil(
                ClaudeHeadlessPolicy.headlessSignal(
                    environment: ["CLAUDE_CODE_ENTRYPOINT": entrypoint, "CLAUDE_CODE_SESSION_ATTENDED": "0"],
                    parentArguments: printArgv
                ),
                entrypoint
            )
        }
        XCTAssertEqual(ClaudeHeadlessPolicy.passthroughEntrypoints, ["sdk-cli", "sdk-py"])
    }

    /// ATTENDED=1 decides first: a TUI that inherited an `sdk-*` entrypoint
    /// from the shell that launched it is still interactive.
    func testAttendedWinsOverInheritedSdkEntrypoint() {
        XCTAssertNil(
            ClaudeHeadlessPolicy.headlessSignal(
                environment: ["CLAUDE_CODE_ENTRYPOINT": "sdk-cli", "CLAUDE_CODE_SESSION_ATTENDED": "1"],
                parentArguments: printArgv
            )
        )
        // Unattended alone, without a listed entrypoint, is not enough.
        XCTAssertNil(
            ClaudeHeadlessPolicy.headlessSignal(
                environment: ["CLAUDE_CODE_ENTRYPOINT": "cli", "CLAUDE_CODE_SESSION_ATTENDED": "0"],
                parentArguments: tuiArgv
            )
        )
        // Entrypoint without the attended variable still decides.
        XCTAssertEqual(
            ClaudeHeadlessPolicy.headlessSignal(
                environment: ["CLAUDE_CODE_ENTRYPOINT": "sdk-cli"], parentArguments: nil
            ),
            .sdkEntrypoint("sdk-cli")
        )
    }

    /// Older Claude Code without the variables: the parent argv decides.
    func testArgvFallbackWhenEnvironmentIsSilent() {
        XCTAssertEqual(
            ClaudeHeadlessPolicy.headlessSignal(environment: [:], parentArguments: printArgv),
            .printFlag
        )
        XCTAssertNil(ClaudeHeadlessPolicy.headlessSignal(environment: [:], parentArguments: tuiArgv))
        XCTAssertNil(ClaudeHeadlessPolicy.headlessSignal(environment: [:], parentArguments: nil))
    }

    /// Claude Code that reports itself interactive is believed over argv.
    func testInteractiveEnvironmentWinsOverArgv() {
        XCTAssertNil(ClaudeHeadlessPolicy.headlessSignal(environment: tuiEnv, parentArguments: printArgv))
    }

    func testPrintFlagParsing() {
        XCTAssertTrue(ClaudeHeadlessPolicy.isPrintMode(arguments: ["claude", "-p", "hi"]))
        XCTAssertTrue(ClaudeHeadlessPolicy.isPrintMode(arguments: ["claude", "--print", "hi"]))
        XCTAssertTrue(ClaudeHeadlessPolicy.isPrintMode(arguments: ["claude", "--model", "x", "-p"]))
        XCTAssertTrue(ClaudeHeadlessPolicy.isPrintMode(arguments: ["claude", "-cp", "hi"]))
        XCTAssertFalse(ClaudeHeadlessPolicy.isPrintMode(arguments: ["claude"]))
        XCTAssertFalse(ClaudeHeadlessPolicy.isPrintMode(arguments: ["claude", "-c"]))
        XCTAssertFalse(ClaudeHeadlessPolicy.isPrintMode(arguments: ["claude", "explain -p in grep"]))
        XCTAssertFalse(ClaudeHeadlessPolicy.isPrintMode(arguments: ["claude", "--permission-mode", "plan"]))
        XCTAssertFalse(ClaudeHeadlessPolicy.isPrintMode(arguments: ["claude", "--", "-p"]))
        // argv[0] is never a flag.
        XCTAssertFalse(ClaudeHeadlessPolicy.isPrintMode(arguments: ["-p"]))
        // A bundle with letters that are not boolean claude flags is not -p.
        XCTAssertFalse(ClaudeHeadlessPolicy.isPrintMode(arguments: ["claude", "-pz"]))
    }

    // MARK: - Mode

    func testModeDefaultsToPassthrough() {
        XCTAssertEqual(ClaudeHeadlessPolicy.mode(hookArguments: hookArgv, environment: [:]), .passthrough)
        XCTAssertEqual(
            ClaudeHeadlessPolicy.mode(
                hookArguments: hookArgv, environment: ["ROCKY_HOOK_HEADLESS_PERMISSIONS": "bogus"]
            ),
            .passthrough
        )
    }

    func testModeCanOptIntoGate() {
        XCTAssertEqual(
            ClaudeHeadlessPolicy.mode(hookArguments: hookArgv + ["--headless-permissions", "gate"], environment: [:]),
            .gate
        )
        XCTAssertEqual(
            ClaudeHeadlessPolicy.mode(hookArguments: hookArgv, environment: ["ROCKY_HOOK_HEADLESS_PERMISSIONS": "GATE"]),
            .gate
        )
        // The flag beats the environment.
        XCTAssertEqual(
            ClaudeHeadlessPolicy.mode(
                hookArguments: hookArgv + ["--headless-permissions", "passthrough"],
                environment: ["ROCKY_HOOK_HEADLESS_PERMISSIONS": "gate"]
            ),
            .passthrough
        )
    }

    // MARK: - Routing (what the hook skips)

    func testHeadlessSkipsOnlyThePermissionRequest() {
        for kind in allKinds {
            let signal = ClaudeHeadlessPolicy.passthroughSignal(
                agent: "claude-code", eventKind: kind, toolName: "Bash", hookArguments: hookArgv,
                environment: printEnv, parentArguments: printArgv
            )
            if kind == .permissionRequest {
                XCTAssertEqual(signal, .sdkEntrypoint("sdk-cli"))
            } else {
                XCTAssertNil(signal, "\(kind) must still be forwarded in headless runs")
            }
        }
    }

    /// Owner decision: AskUserQuestion is a question, not an approval, and is
    /// always forwarded to the notch — headless (`-p`, Python SDK) included.
    func testAskUserQuestionIsAlwaysForwarded() {
        for env in [tuiEnv, printEnv, sdkEnv] {
            XCTAssertNil(
                ClaudeHeadlessPolicy.passthroughSignal(
                    agent: "claude-code", eventKind: .permissionRequest, toolName: "AskUserQuestion",
                    hookArguments: hookArgv, environment: env, parentArguments: printArgv
                )
            )
        }
        // While a real tool approval in the same headless run passes through.
        XCTAssertEqual(
            ClaudeHeadlessPolicy.passthroughSignal(
                agent: "claude-code", eventKind: .permissionRequest, toolName: "Bash",
                hookArguments: hookArgv, environment: sdkEnv, parentArguments: sdkArgv
            ),
            .sdkEntrypoint("sdk-py")
        )
    }

    /// Subagent monitoring is untouched in both kinds of session.
    func testSubagentEventsAreAlwaysForwarded() {
        for env in [tuiEnv, printEnv, sdkEnv] {
            for kind in [HookEvent.Kind.subagentStart, .subagentStop] {
                XCTAssertNil(
                    ClaudeHeadlessPolicy.passthroughSignal(
                        agent: "claude-code", eventKind: kind, toolName: "Bash", hookArguments: hookArgv,
                        environment: env, parentArguments: printArgv
                    )
                )
            }
        }
    }

    /// Interactive sessions: every event — the permission request and the
    /// AskUserQuestion card (which arrives as a PermissionRequest) included —
    /// goes to the app exactly as before.
    func testInteractiveForwardsEveryEventIncludingAskUserQuestion() throws {
        for kind in allKinds {
            XCTAssertNil(
                ClaudeHeadlessPolicy.passthroughSignal(
                    agent: "claude-code", eventKind: kind, toolName: "Bash", hookArguments: hookArgv,
                    environment: tuiEnv, parentArguments: tuiArgv
                ),
                "\(kind) must be forwarded in interactive sessions"
            )
        }
        let payload = #"{"session_id":"s","hook_event_name":"PermissionRequest","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which?","header":"Q","options":[{"label":"A"},{"label":"B"}],"multiSelect":false}]}}"#
        let ask = try JSONDecoder().decode(HookEvent.self, from: Data(payload.utf8))
        XCTAssertEqual(ask.kind, .permissionRequest)
        XCTAssertNil(
            ClaudeHeadlessPolicy.passthroughSignal(
                agent: "claude-code", eventKind: ask.kind, toolName: ask.toolName, hookArguments: hookArgv,
                environment: tuiEnv, parentArguments: tuiArgv
            )
        )
    }

    func testGateModeKeepsHeadlessCards() {
        XCTAssertNil(
            ClaudeHeadlessPolicy.passthroughSignal(
                agent: "claude-code", eventKind: .permissionRequest, toolName: "Bash",
                hookArguments: hookArgv + ["--headless-permissions", "gate"],
                environment: printEnv, parentArguments: printArgv
            )
        )
    }

    /// Other agents never inherit the Claude rule, even when a Claude env
    /// leaked into them (e.g. codex launched from a `claude -p` shell).
    func testOtherAgentsAreUnaffected() {
        for agent in ["codex", "grok", "cursor", "kimi-code", "opencode", "agy"] {
            XCTAssertNil(
                ClaudeHeadlessPolicy.passthroughSignal(
                    agent: agent, eventKind: .permissionRequest, toolName: "Bash",
                    hookArguments: ["rocky-hook", "--agent", agent],
                    environment: printEnv, parentArguments: printArgv
                )
            )
        }
    }
}
