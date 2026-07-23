import Darwin
import Foundation

/// Process-tree helpers shared by rocky-hook (resolve agent PID while the hook
/// is still alive) and RockyApp (prune + focus). Pure Darwin — no AppKit — so
/// the hook binary can link RockyCore alone.
public enum ProcessAncestry {
    /// Name fragments that identify each agent CLI in `proc_name` output.
    public static func agentNameMarkers(for agent: String) -> [String] {
        switch agent {
        case "codex":
            return ["codex"]
        case "claude-code":
            return ["claude"]
        case "grok":
            return ["grok"]
        case "cursor":
            // Hosted in the Cursor app itself; no separate CLI to track.
            return []
        default:
            return [agent.lowercased()]
        }
    }

    /// Walks up from `hookPid` to the agent CLI (codex / claude / grok).
    /// Stops at a likely GUI host so we never treat Warp/Terminal as the agent.
    public static func agentAncestor(of hookPid: Int32, agent: String) -> Int32? {
        let markers = agentNameMarkers(for: agent)
        guard !markers.isEmpty else { return nil }
        var current = pid_t(hookPid)
        for _ in 0..<15 {
            guard let parent = parentPid(of: current), parent > 1 else { return nil }
            if let name = processName(of: parent)?.lowercased() {
                if nameMatches(name, markers: markers) {
                    return Int32(parent)
                }
                if isLikelyGuiHost(name) { return nil }
            }
            current = parent
        }
        return nil
    }

    /// True if `pid` still exists (GUI or CLI).
    public static func isProcessAlive(_ pid: Int32) -> Bool {
        guard pid > 1 else { return false }
        if kill(pid, 0) == 0 { return true }
        // EPERM: process exists but we can't signal it — still alive.
        return errno == EPERM
    }

    /// Agent CLI still running **and** still named like the agent.
    /// After Ctrl+C the PID can be reused by an unrelated process; a bare
    /// `kill(pid, 0)` would keep the Rocky card forever in that case.
    public static func isAgentProcessStillValid(pid: Int32, agent: String) -> Bool {
        guard isProcessAlive(pid) else { return false }
        let markers = agentNameMarkers(for: agent)
        // Cursor / unknown: existence alone is enough.
        guard !markers.isEmpty else { return true }
        guard let name = processName(of: pid_t(pid))?.lowercased() else {
            // Process exists but name is unreadable — keep (fail-open).
            return true
        }
        return nameMatches(name, markers: markers)
    }

    public static func parentPid(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent > 0 ? parent : nil
    }

    public static func processName(of pid: pid_t) -> String? {
        var name = [CChar](repeating: 0, count: 256)
        let result = name.withUnsafeMutableBufferPointer { buf in
            proc_name(pid, buf.baseAddress, UInt32(buf.count))
        }
        guard result > 0 else { return nil }
        return String(cString: name)
    }

    private static func nameMatches(_ name: String, markers: [String]) -> Bool {
        markers.contains { name == $0 || name.hasPrefix($0) || name.contains($0) }
    }

    /// Host apps we refuse to treat as the agent CLI (no AppKit required).
    private static func isLikelyGuiHost(_ name: String) -> Bool {
        // Warp's main binary often reports as "stable".
        let hosts = [
            "stable", "warp", "terminal", "iterm", "iterm2",
            "cursor", "code", "electron", "windowserver", "loginwindow",
        ]
        return hosts.contains { name == $0 || name.contains($0) }
    }
}
