import AppKit
import Darwin
import RockyCore

/// Best-effort "bring the terminal here". The GUI ancestor must be resolved
/// at event time (the hook process dies right after the exchange); focusing
/// later uses the stored PID. Silent no-op on any failure.
enum TerminalFocus {
    /// Walks up from `pid` to the first ancestor that is a regular GUI app.
    static func guiAncestor(of pid: Int32) -> Int32? {
        var current = pid_t(pid)
        for _ in 0..<15 {
            guard let parent = parentPid(of: current), parent > 1 else { return nil }
            if let app = NSRunningApplication(processIdentifier: parent),
               app.activationPolicy == .regular {
                return parent
            }
            current = parent
        }
        return nil
    }

    /// Walks up from the short-lived hook PID to the agent CLI process
    /// (codex / claude / grok). Stops at the first regular GUI app so we never
    /// treat Warp/Cursor as the agent process.
    static func agentAncestor(of hookPid: Int32, agent: String) -> Int32? {
        let markers = agentNameMarkers(for: agent)
        guard !markers.isEmpty else { return nil }
        var current = pid_t(hookPid)
        for _ in 0..<15 {
            guard let parent = parentPid(of: current), parent > 1 else { return nil }
            if let app = NSRunningApplication(processIdentifier: parent),
               app.activationPolicy == .regular {
                return nil
            }
            if let name = processName(of: parent)?.lowercased(),
               markers.contains(where: { name == $0 || name.hasPrefix($0) || name.contains($0) }) {
                return Int32(parent)
            }
            current = parent
        }
        return nil
    }

    /// True if `pid` still exists. Works for GUI and CLI processes (unlike
    /// `NSRunningApplication`, which is nil for headless binaries).
    static func isProcessAlive(_ pid: Int32) -> Bool {
        guard pid > 1 else { return false }
        if kill(pid, 0) == 0 { return true }
        // EPERM: process exists but we can't signal it — still alive.
        return errno == EPERM
    }

    static func focus(session: AgentSession) {
        guard let pid = session.terminalAppPid,
              let app = NSRunningApplication(processIdentifier: pid)
        else { return }
        app.activate()
    }

    private static func agentNameMarkers(for agent: String) -> [String] {
        switch agent {
        case "codex":
            return ["codex"]
        case "claude-code":
            return ["claude"]
        case "grok":
            return ["grok"]
        case "cursor":
            // Hosted in the Cursor app itself; terminalAppPid is enough.
            return []
        default:
            return [agent.lowercased()]
        }
    }

    private static func parentPid(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent > 0 ? parent : nil
    }

    private static func processName(of pid: pid_t) -> String? {
        var name = [CChar](repeating: 0, count: 256)
        let result = name.withUnsafeMutableBufferPointer { buf in
            proc_name(pid, buf.baseAddress, UInt32(buf.count))
        }
        guard result > 0 else { return nil }
        return String(cString: name)
    }
}
