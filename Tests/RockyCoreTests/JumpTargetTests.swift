import XCTest
@testable import RockyCore

final class JumpTargetTests: XCTestCase {
    func testMergePrefersNonNilFromOther() {
        let base = JumpTarget(terminalApp: "Warp", terminalTTY: "/dev/ttys001")
        let other = JumpTarget(warpPaneUUID: "ABC", workingDirectory: "/tmp/x")
        let merged = base.merging(other)
        XCTAssertEqual(merged.terminalApp, "Warp")
        XCTAssertEqual(merged.terminalTTY, "/dev/ttys001")
        XCTAssertEqual(merged.warpPaneUUID, "ABC")
        XCTAssertEqual(merged.workingDirectory, "/tmp/x")
    }

    func testMergeDoesNotClobberWithNil() {
        let base = JumpTarget(terminalApp: "Warp", warpPaneUUID: "OLD")
        let other = JumpTarget(terminalApp: nil, warpPaneUUID: nil, terminalTTY: "/dev/ttys002")
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
                return "PANEUUID"
            }
        )
        XCTAssertEqual(target.terminalApp, "Warp")
        XCTAssertEqual(target.workingDirectory, "/tmp/proj")
        XCTAssertEqual(target.terminalTTY, "/dev/ttys009")
        XCTAssertEqual(target.warpPaneUUID, "PANEUUID")
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
