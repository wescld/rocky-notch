import XCTest
@testable import RockyCore

/// A transcript on disk is evidence a session *existed*, never that it is still
/// running. Seeding from it unchecked meant every relaunch resurrected sessions
/// the user had closed hours earlier — and Rocky showed them as real rows.
final class DiscoveryLivenessTests: XCTestCase {
    func session(_ id: String, agent: String, cwd: String?) -> AgentSession {
        AgentSession(
            id: id,
            agent: agent,
            cwd: cwd,
            hookPid: nil,
            status: .idle,
            pending: nil,
            lastEventAt: Date(),
            title: nil,
            model: nil,
            terminalAppPid: nil,
            transcriptPath: nil,
            lastAction: nil
        )
    }

    func testDropsASessionWhoseAgentIsNotRunningThere() {
        let sessions = [session("s1", agent: "claude-code", cwd: "/proj/web-app")]
        let kept = SessionDiscovery.filterToLiveAgents(sessions) { _ in ["/proj/other"] }
        XCTAssertTrue(kept.isEmpty)
    }

    func testKeepsASessionWithAProcessInTheSameDirectory() {
        let sessions = [session("s1", agent: "codex", cwd: "/proj/web-app")]
        let kept = SessionDiscovery.filterToLiveAgents(sessions) { _ in ["/proj/web-app"] }
        XCTAssertEqual(kept.map(\.id), ["s1"])
    }

    /// A CLI started one level up still owns sessions below it (and the other
    /// way round, for an agent launched inside a subfolder), so containment in
    /// either direction keeps the row.
    func testKeepsWhenOneDirectoryContainsTheOther() {
        let above = [session("s1", agent: "claude-code", cwd: "/proj/app/web")]
        XCTAssertEqual(
            SessionDiscovery.filterToLiveAgents(above) { _ in ["/proj/app"] }.count, 1
        )
        let below = [session("s2", agent: "claude-code", cwd: "/proj/app")]
        XCTAssertEqual(
            SessionDiscovery.filterToLiveAgents(below) { _ in ["/proj/app/web"] }.count, 1
        )
    }

    /// Sibling directories that share a prefix are not the same tree.
    func testPrefixAloneIsNotContainment() {
        let sessions = [session("s1", agent: "codex", cwd: "/proj/web")]
        let kept = SessionDiscovery.filterToLiveAgents(sessions) { _ in ["/proj/web-app"] }
        XCTAssertTrue(kept.isEmpty)
        XCTAssertFalse(SessionDiscovery.sharesTree("/proj/web", "/proj/web-app"))
    }

    /// "I could not tell" must never be acted on as "nothing is running" —
    /// an unreadable process table would otherwise wipe every discovered row.
    func testUnknownLivenessKeepsEverything() {
        let sessions = [session("s1", agent: "claude-code", cwd: "/proj/web-app")]
        let kept = SessionDiscovery.filterToLiveAgents(sessions) { _ in nil }
        XCTAssertEqual(kept.map(\.id), ["s1"])
    }

    func testSessionWithoutACwdIsKept() {
        let sessions = [session("s1", agent: "codex", cwd: nil)]
        let kept = SessionDiscovery.filterToLiveAgents(sessions) { _ in [] }
        XCTAssertEqual(kept.map(\.id), ["s1"])
    }

    /// Each agent is asked about once even when it owns many rows.
    func testLivenessIsLookedUpOncePerAgent() {
        var lookups: [String] = []
        let sessions = [
            session("s1", agent: "codex", cwd: "/proj/a"),
            session("s2", agent: "codex", cwd: "/proj/b"),
            session("s3", agent: "claude-code", cwd: "/proj/a"),
        ]
        _ = SessionDiscovery.filterToLiveAgents(sessions) { agent in
            lookups.append(agent)
            return ["/proj/a"]
        }
        XCTAssertEqual(lookups.sorted(), ["claude-code", "codex"])
    }

    // MARK: - Recognizing an agent binary

    /// The Claude Code installer keeps the binary at `.../claude/versions/<v>`,
    /// so the process reports `2.1.220` as its name and every name-based check
    /// misses it. The path still says claude.
    func testVersionedClaudeBinaryIsRecognized() {
        XCTAssertTrue(
            ProcessAncestry.isAgentExecutable(
                "/Users/k/.local/share/claude/versions/2.1.220",
                markers: ["claude"]
            )
        )
    }

    func testPlainBinaryIsRecognized() {
        XCTAssertTrue(
            ProcessAncestry.isAgentExecutable("/usr/local/bin/codex", markers: ["codex"])
        )
    }

    /// The desktop app is not the CLI, and its bundle path is full of the word.
    func testBundledAppIsNotTheCLI() {
        XCTAssertFalse(
            ProcessAncestry.isAgentExecutable(
                "/Applications/Claude.app/Contents/MacOS/Claude",
                markers: ["claude"]
            )
        )
    }

    func testHiddenInstallDirectoryStillCounts() {
        XCTAssertTrue(
            ProcessAncestry.isAgentExecutable("/Users/k/.claude/local/claude", markers: ["claude"])
        )
    }

    /// The versioned binary is why an agent PID was never resolved for Claude
    /// Code: `proc_name` answers "2.1.220", so the name check alone says no.
    func testIdentityFallsBackToTheNameButLeadsWithThePath() {
        XCTAssertEqual(
            ProcessAncestry.identityMatches(
                executablePath: "/Users/k/.local/share/claude/versions/2.1.220",
                processName: "2.1.220",
                markers: ["claude"]
            ),
            true
        )
        // Path unreadable, name still enough — how codex and grok already
        // resolved, and must keep resolving.
        XCTAssertEqual(
            ProcessAncestry.identityMatches(
                executablePath: nil, processName: "codex", markers: ["codex"]
            ),
            true
        )
    }

    /// PID reuse: the process exists but is something else entirely.
    func testIdentityRejectsAnUnrelatedProcess() {
        XCTAssertEqual(
            ProcessAncestry.identityMatches(
                executablePath: "/usr/bin/vim", processName: "vim", markers: ["claude"]
            ),
            false
        )
    }

    /// Nothing readable is not a denial — it used to keep the row, and still
    /// must, or an unreadable process would silently drop a live session.
    func testIdentityHasNoOpinionWhenNothingIsReadable() {
        XCTAssertNil(
            ProcessAncestry.identityMatches(
                executablePath: nil, processName: nil, markers: ["claude"]
            )
        )
    }

    func testUnrelatedBinaryIsNotMatched() {
        XCTAssertFalse(
            ProcessAncestry.isAgentExecutable("/usr/bin/node", markers: ["claude"])
        )
        // A marker has to own a path component, not merely appear inside one.
        XCTAssertFalse(
            ProcessAncestry.isAgentExecutable("/opt/notclaude/bin/tool", markers: ["claude"])
        )
        // Claude Code's own scratch root — every helper it spawns runs from
        // here, and counting them would make the check answer "yes" always.
        XCTAssertFalse(
            ProcessAncestry.isAgentExecutable(
                "/private/tmp/claude-501/session/scratchpad/probe",
                markers: ["claude"]
            )
        )
    }
}
