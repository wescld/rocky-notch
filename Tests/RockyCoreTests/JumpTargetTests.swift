import XCTest
@testable import RockyCore

final class JumpTargetTests: XCTestCase {
    func testMergePrefersNonNilFromOther() {
        let base = JumpTarget(terminalApp: "Warp", terminalTTY: "/dev/ttys001")
        let other = JumpTarget(workingDirectory: "/tmp/x", warpPaneUUID: "ABC")
        let merged = base.merging(other)
        XCTAssertEqual(merged.terminalApp, "Warp")
        XCTAssertEqual(merged.terminalTTY, "/dev/ttys001")
        XCTAssertEqual(merged.warpPaneUUID, "ABC")
        XCTAssertEqual(merged.workingDirectory, "/tmp/x")
    }

    func testMergeDoesNotClobberWithNil() {
        let base = JumpTarget(terminalApp: "Warp", warpPaneUUID: "OLD")
        let other = JumpTarget(terminalApp: nil, terminalTTY: "/dev/ttys002", warpPaneUUID: nil)
        let merged = base.merging(other)
        XCTAssertEqual(merged.terminalApp, "Warp")
        XCTAssertEqual(merged.warpPaneUUID, "OLD")
        XCTAssertEqual(merged.terminalTTY, "/dev/ttys002")
    }

    func testHasPreciseLocator() {
        XCTAssertFalse(JumpTarget().hasPreciseLocator)
        XCTAssertTrue(JumpTarget(terminalTTY: "/dev/ttys001").hasPreciseLocator)
        XCTAssertTrue(JumpTarget(warpPaneUUID: "ABC").hasPreciseLocator)
        XCTAssertTrue(JumpTarget(tmuxTarget: "%1").hasPreciseLocator)
        XCTAssertFalse(JumpTarget(terminalApp: "Warp").hasPreciseLocator)
    }

    func testCodableRoundTrip() throws {
        let target = JumpTarget(
            terminalApp: "Warp",
            workingDirectory: "/Users/me/proj",
            terminalTTY: "/dev/ttys012",
            warpPaneUUID: "DEADBEEF"
        )
        let data = try JSONEncoder().encode(target)
        let decoded = try JSONDecoder().decode(JumpTarget.self, from: data)
        XCTAssertEqual(decoded, target)
    }
}

final class TerminalProbeTests: XCTestCase {
    func testInferWarpFromTermProgram() {
        let env = ["TERM_PROGRAM": "WarpTerminal"]
        XCTAssertEqual(TerminalProbe.inferTerminalApp(from: env), "Warp")
    }

    func testInferGhosttyFromTermProgram() {
        let env = ["TERM_PROGRAM": "ghostty"]
        XCTAssertEqual(TerminalProbe.inferTerminalApp(from: env), "Ghostty")
    }

    func testInferTerminalApp() {
        XCTAssertEqual(
            TerminalProbe.inferTerminalApp(from: ["TERM_PROGRAM": "Apple_Terminal"]),
            "Terminal"
        )
        XCTAssertEqual(
            TerminalProbe.inferTerminalApp(from: ["TERM_PROGRAM": "iTerm.app"]),
            "iTerm"
        )
    }

    func testTermProgramBeatsLeakedGhosttyEnv() {
        // Ghostty env can leak into other apps via GUI inheritance.
        let env = [
            "TERM_PROGRAM": "WarpTerminal",
            "GHOSTTY_RESOURCES_DIR": "/Applications/Ghostty.app/Contents/Resources",
        ]
        XCTAssertEqual(TerminalProbe.inferTerminalApp(from: env), "Warp")
    }

    func testFallbackWarpEnvWhenNoTermProgram() {
        let env = ["WARP_IS_LOCAL_SHELL_SESSION": "1"]
        XCTAssertEqual(TerminalProbe.inferTerminalApp(from: env), "Warp")
    }

    func testJumpTargetCapturesWarpPane() {
        let env = ["TERM_PROGRAM": "WarpTerminal"]
        let target = TerminalProbe.jumpTarget(
            environment: env,
            cwd: "/tmp/proj",
            currentTTY: { "/dev/ttys009" },
            warpPaneResolver: { cwd in
                XCTAssertEqual(cwd, "/tmp/proj")
                return "aabbccddeeff00112233445566778899"
            }
        )
        XCTAssertEqual(target.terminalApp, "Warp")
        XCTAssertEqual(target.workingDirectory, "/tmp/proj")
        XCTAssertEqual(target.terminalTTY, "/dev/ttys009")
        XCTAssertEqual(target.warpPaneUUID, "aabbccddeeff00112233445566778899")
    }

    func testJumpTargetPrefersWarpSessionEnvOverSQLite() {
        let env = [
            "TERM_PROGRAM": "WarpTerminal",
            "WARP_TERMINAL_SESSION_UUID": "31e4ddb3c9fc41109f3e8e18e2125685",
        ]
        var resolverCalled = false
        let target = TerminalProbe.jumpTarget(
            environment: env,
            cwd: "/tmp/proj",
            currentTTY: { nil },
            warpPaneResolver: { _ in
                resolverCalled = true
                return "deadbeefdeadbeefdeadbeefdeadbeef"
            }
        )
        XCTAssertEqual(target.warpPaneUUID, "31e4ddb3c9fc41109f3e8e18e2125685")
        XCTAssertFalse(resolverCalled, "env UUID should short-circuit SQLite lookup")
    }

    func testJumpTargetParsesWarpFocusURL() {
        let env = [
            "TERM_PROGRAM": "WarpTerminal",
            "WARP_FOCUS_URL": "warp://session/f60d5dfa5a5e4102bede001061a83aac",
        ]
        let target = TerminalProbe.jumpTarget(
            environment: env,
            cwd: "/tmp/proj",
            currentTTY: { nil },
            warpPaneResolver: { _ in nil }
        )
        XCTAssertEqual(target.warpPaneUUID, "f60d5dfa5a5e4102bede001061a83aac")
    }

    func testWarpFocusURLParsing() {
        XCTAssertEqual(
            TerminalProbe.parseWarpFocusURL("warp://session/31e4ddb3c9fc41109f3e8e18e2125685"),
            "31e4ddb3c9fc41109f3e8e18e2125685"
        )
        XCTAssertEqual(
            TerminalProbe.parseWarpFocusURL("warp://session/31E4DDB3-C9FC-4110-9F3E-8E18E2125685"),
            "31e4ddb3c9fc41109f3e8e18e2125685"
        )
        XCTAssertNil(TerminalProbe.parseWarpFocusURL("https://example.com/session/x"))
        XCTAssertNil(TerminalProbe.normalizeWarpSessionUUID("not-a-uuid"))
        XCTAssertNil(TerminalProbe.normalizeWarpSessionUUID("gggggggggggggggggggggggggggggggg"))
    }

    func testJumpTargetIgnoresGenericDevTty() {
        let target = TerminalProbe.jumpTarget(
            environment: ["TERM_PROGRAM": "WarpTerminal"],
            cwd: nil,
            currentTTY: { "/dev/tty" },
            warpPaneResolver: { _ in nil }
        )
        XCTAssertNil(target.terminalTTY)
    }

    func testJumpTargetSkipsWarpResolverForOtherTerminals() {
        var resolverCalled = false
        let target = TerminalProbe.jumpTarget(
            environment: ["TERM_PROGRAM": "ghostty"],
            cwd: "/tmp/proj",
            currentTTY: { nil },
            warpPaneResolver: { _ in
                resolverCalled = true
                return "NOPE"
            }
        )
        XCTAssertEqual(target.terminalApp, "Ghostty")
        XCTAssertNil(target.warpPaneUUID)
        XCTAssertFalse(resolverCalled)
    }

    func testTmuxEnvCaptured() {
        let env: [String: String] = [
            "TERM_PROGRAM": "ghostty",
            "TMUX": "/tmp/tmux-501/default,1234,0",
            "TMUX_PANE": "%3",
        ]
        let target = TerminalProbe.jumpTarget(
            environment: env,
            cwd: nil,
            currentTTY: { nil },
            warpPaneResolver: { _ in nil }
        )
        XCTAssertEqual(target.tmuxSocketPath, "/tmp/tmux-501/default")
        // display-message may or may not succeed in CI; pane id is the floor.
        XCTAssertNotNil(target.tmuxTarget)
        XCTAssertTrue(
            target.tmuxTarget == "%3" || (target.tmuxTarget?.contains(":") == true),
            "tmuxTarget should be pane id or session:window.pane, got \(target.tmuxTarget ?? "nil")"
        )
    }

    func testITermSessionId() {
        let env = [
            "TERM_PROGRAM": "iTerm.app",
            "ITERM_SESSION_ID": "w0t1p2:ABCDEF",
        ]
        let target = TerminalProbe.jumpTarget(
            environment: env,
            cwd: "/tmp",
            currentTTY: { "/dev/ttys001" },
            warpPaneResolver: { _ in nil }
        )
        XCTAssertEqual(target.terminalApp, "iTerm")
        XCTAssertEqual(target.terminalSessionID, "w0t1p2:ABCDEF")
    }

    // MARK: - Ghostty

    func testInferGhosttyFromResourcesDirFallback() {
        let env = [
            "GHOSTTY_RESOURCES_DIR": "/Applications/Ghostty.app/Contents/Resources/ghostty",
            "GHOSTTY_BIN_DIR": "/Applications/Ghostty.app/Contents/MacOS",
        ]
        XCTAssertEqual(TerminalProbe.inferTerminalApp(from: env), "Ghostty")
    }

    func testGhosttySurfaceIDFromEnvKeys() {
        let env = [
            "TERM_PROGRAM": "ghostty",
            "GHOSTTY_SURFACE_ID": "A0BED0CC-C017-42CD-9CAD-030392F4B017",
            "GHOSTTY_RESOURCES_DIR": "/Applications/Ghostty.app/Contents/Resources/ghostty",
        ]
        XCTAssertEqual(
            TerminalProbe.ghosttySurfaceID(from: env),
            "A0BED0CC-C017-42CD-9CAD-030392F4B017"
        )

        // Prefer GHOSTTY_SURFACE_ID over weaker aliases.
        let multi = [
            "TERM_PROGRAM": "ghostty",
            "GHOSTTY_SURFACE_ID": "surface-primary",
            "GHOSTTY_TERMINAL_ID": "terminal-secondary",
            "TERM_SESSION_ID": "term-session",
        ]
        XCTAssertEqual(TerminalProbe.ghosttySurfaceID(from: multi), "surface-primary")

        // TERM_SESSION_ID only when Ghostty identity is clear.
        let termSessionOnly = [
            "TERM_PROGRAM": "ghostty",
            "TERM_SESSION_ID": "w0t0p0:UUID",
        ]
        XCTAssertEqual(TerminalProbe.ghosttySurfaceID(from: termSessionOnly), "w0t0p0:UUID")
        XCTAssertNil(TerminalProbe.ghosttySurfaceID(from: ["TERM_SESSION_ID": "other"]))
    }

    func testGhosttyJumpTargetCapturesSurfaceOnSafeEvents() {
        let env = [
            "TERM_PROGRAM": "ghostty",
            "GHOSTTY_SURFACE_ID": "surface-from-env",
        ]
        let start = TerminalProbe.jumpTarget(
            environment: env,
            cwd: "/tmp/proj",
            hookEventName: "SessionStart",
            currentTTY: { nil },
            warpPaneResolver: { _ in nil },
            ghosttySurfaceResolver: { "should-not-run-when-env-set" }
        )
        XCTAssertEqual(start.terminalApp, "Ghostty")
        XCTAssertEqual(start.terminalSessionID, "surface-from-env")
        XCTAssertEqual(start.workingDirectory, "/tmp/proj")

        var resolverCalls = 0
        let prompt = TerminalProbe.jumpTarget(
            environment: ["TERM_PROGRAM": "ghostty"],
            cwd: "/tmp/proj",
            hookEventName: "UserPromptSubmit",
            currentTTY: { nil },
            warpPaneResolver: { _ in nil },
            ghosttySurfaceResolver: {
                resolverCalls += 1
                return "surface-from-applescript"
            }
        )
        XCTAssertEqual(prompt.terminalSessionID, "surface-from-applescript")
        XCTAssertEqual(resolverCalls, 1)

        // Cursor-style alias for the same user-submit moment.
        let beforeSubmit = TerminalProbe.jumpTarget(
            environment: ["TERM_PROGRAM": "ghostty"],
            cwd: nil,
            hookEventName: "BeforeSubmitPrompt",
            currentTTY: { nil },
            ghosttySurfaceResolver: { "surface-cursor" }
        )
        XCTAssertEqual(beforeSubmit.terminalSessionID, "surface-cursor")
    }

    func testGhosttyJumpTargetSkipsSurfaceOnUnsafeEvents() {
        var resolverCalls = 0
        let env = [
            "TERM_PROGRAM": "ghostty",
            "GHOSTTY_SURFACE_ID": "would-be-wrong-after-tab-switch",
        ]
        for event in ["PreToolUse", "PostToolUse", "Stop", "Notification", "PermissionRequest"] {
            resolverCalls = 0
            let target = TerminalProbe.jumpTarget(
                environment: env,
                cwd: "/tmp/proj",
                hookEventName: event,
                currentTTY: { "/dev/ttys009" },
                warpPaneResolver: { _ in nil },
                ghosttySurfaceResolver: {
                    resolverCalls += 1
                    return "focused-other-tab"
                }
            )
            XCTAssertEqual(target.terminalApp, "Ghostty", event)
            XCTAssertNil(target.terminalSessionID, "must not stamp surface on \(event)")
            XCTAssertEqual(resolverCalls, 0, "resolver must not run on \(event)")
            // Still capture non-surface fields.
            XCTAssertEqual(target.workingDirectory, "/tmp/proj")
            XCTAssertEqual(target.terminalTTY, "/dev/ttys009")
        }
    }

    func testGhosttySurfaceSafeEventHelpers() {
        XCTAssertTrue(TerminalProbe.shouldCaptureGhosttySurfaceID(hookEventName: nil))
        XCTAssertTrue(TerminalProbe.shouldCaptureGhosttySurfaceID(hookEventName: "SessionStart"))
        XCTAssertTrue(TerminalProbe.shouldCaptureGhosttySurfaceID(hookEventName: "session_start"))
        XCTAssertTrue(TerminalProbe.shouldCaptureGhosttySurfaceID(hookEventName: "UserPromptSubmit"))
        XCTAssertFalse(TerminalProbe.shouldCaptureGhosttySurfaceID(hookEventName: "PreToolUse"))
        XCTAssertFalse(TerminalProbe.shouldCaptureGhosttySurfaceID(hookEventName: "Stop"))
    }

    func testGhosttyMergePreservesSessionIDWhenLaterHookOmitsIt() {
        let base = JumpTarget(
            terminalApp: "Ghostty",
            workingDirectory: "/tmp/a",
            terminalSessionID: "surface-original"
        )
        let later = JumpTarget(
            terminalApp: "Ghostty",
            workingDirectory: "/tmp/a",
            terminalSessionID: nil
        )
        let merged = base.merging(later)
        XCTAssertEqual(merged.terminalSessionID, "surface-original")
        XCTAssertEqual(merged.terminalApp, "Ghostty")
    }

    func testQueryGhosttyFocusedSurfaceIDUsesRunner() {
        let id = TerminalProbe.queryGhosttyFocusedSurfaceID { script in
            XCTAssertTrue(script.contains("Ghostty"))
            XCTAssertTrue(script.contains("focused terminal"))
            return "  LIVE-SURFACE-ID  \n"
        }
        XCTAssertEqual(id, "LIVE-SURFACE-ID")
        XCTAssertNil(TerminalProbe.queryGhosttyFocusedSurfaceID { _ in "" })
        XCTAssertNil(TerminalProbe.queryGhosttyFocusedSurfaceID { _ in nil })
    }
}

final class WarpSQLiteReaderTests: XCTestCase {
    func testCwdLookupCandidatesFirmlink() {
        XCTAssertEqual(
            WarpSQLiteReader.cwdLookupCandidates(for: "/tmp/foo"),
            ["/tmp/foo", "/private/tmp/foo"]
        )
        XCTAssertEqual(
            WarpSQLiteReader.cwdLookupCandidates(for: "/private/tmp/foo"),
            ["/private/tmp/foo", "/tmp/foo"]
        )
        XCTAssertEqual(
            WarpSQLiteReader.cwdLookupCandidates(for: "/Users/me/proj"),
            ["/Users/me/proj"]
        )
    }

    func testMissingDatabaseReturnsNil() {
        let reader = WarpSQLiteReader(databasePath: "/tmp/rocky-no-such-warp.sqlite")
        XCTAssertNil(reader.lookupPaneUUID(forCwd: "/tmp"))
        XCTAssertNil(reader.currentFocusedPaneUUID())
        XCTAssertEqual(reader.tabCountInActiveWindow(), 0)
    }
}
