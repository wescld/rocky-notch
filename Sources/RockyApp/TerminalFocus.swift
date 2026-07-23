import AppKit
import Darwin
import RockyCore

/// Best-effort "bring the terminal here". The GUI ancestor must be resolved
/// at event time (the hook process dies right after the exchange); focusing
/// later uses the stored PID. Silent no-op on any failure.
///
/// Agent PID resolution lives in `ProcessAncestry` (shared with rocky-hook so
/// the PID is captured before the fire-and-forget hook exits).
enum TerminalFocus {
    /// Walks up from `pid` to the first ancestor that is a regular GUI app.
    static func guiAncestor(of pid: Int32) -> Int32? {
        var current = pid_t(pid)
        for _ in 0..<15 {
            guard let parent = ProcessAncestry.parentPid(of: current), parent > 1 else {
                return nil
            }
            if let app = NSRunningApplication(processIdentifier: parent),
               app.activationPolicy == .regular {
                return parent
            }
            current = parent
        }
        return nil
    }

    /// Walks up from the short-lived hook PID to the agent CLI process.
    /// Prefer the `agentProcessPid` the hook already put on the envelope —
    /// this is the fallback when that field is missing (older hooks).
    static func agentAncestor(of hookPid: Int32, agent: String) -> Int32? {
        ProcessAncestry.agentAncestor(of: hookPid, agent: agent)
    }

    static func isProcessAlive(_ pid: Int32) -> Bool {
        ProcessAncestry.isProcessAlive(pid)
    }

    /// Agent CLI still running **and** still named like the agent (PID reuse).
    static func isAgentProcessStillValid(pid: Int32, agent: String) -> Bool {
        ProcessAncestry.isAgentProcessStillValid(pid: pid, agent: agent)
    }

    static func focus(session: AgentSession) {
        guard let pid = session.terminalAppPid,
              let app = NSRunningApplication(processIdentifier: pid)
        else { return }
        app.activate()
    }
}
