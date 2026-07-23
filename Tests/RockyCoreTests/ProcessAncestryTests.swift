import XCTest
@testable import RockyCore

final class ProcessAncestryTests: XCTestCase {
    func testAgentNameMarkers() {
        XCTAssertEqual(ProcessAncestry.agentNameMarkers(for: "codex"), ["codex"])
        XCTAssertEqual(ProcessAncestry.agentNameMarkers(for: "claude-code"), ["claude"])
        XCTAssertEqual(ProcessAncestry.agentNameMarkers(for: "grok"), ["grok"])
        XCTAssertTrue(ProcessAncestry.agentNameMarkers(for: "cursor").isEmpty)
    }

    func testIsProcessAliveSelf() {
        let selfPid = ProcessInfo.processInfo.processIdentifier
        XCTAssertTrue(ProcessAncestry.isProcessAlive(selfPid))
        XCTAssertFalse(ProcessAncestry.isProcessAlive(0))
        XCTAssertFalse(ProcessAncestry.isProcessAlive(-1))
    }

    func testIsAgentProcessStillValidRejectsDeadPid() {
        // Extremely unlikely to be a live process with this PID for long, but
        // we only assert dead-or-wrong-name is false when process is gone.
        // Use a PID that is almost certainly free after fork-exit of a child.
        let pipe = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/echo")
        proc.arguments = ["x"]
        proc.standardOutput = pipe
        try? proc.run()
        proc.waitUntilExit()
        let deadPid = proc.processIdentifier
        XCTAssertFalse(
            ProcessAncestry.isAgentProcessStillValid(pid: deadPid, agent: "codex")
        )
    }

    func testAgentAncestorOfSelfFindsNothingUseful() {
        // Current test process is `xctest` / swift — not codex/claude/grok.
        let pid = ProcessInfo.processInfo.processIdentifier
        XCTAssertNil(ProcessAncestry.agentAncestor(of: pid, agent: "codex"))
        XCTAssertNil(ProcessAncestry.agentAncestor(of: pid, agent: "cursor"))
    }
}
