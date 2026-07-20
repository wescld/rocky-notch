import AppKit
import VibenotchCore

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

    static func focus(session: AgentSession) {
        guard let pid = session.terminalAppPid,
              let app = NSRunningApplication(processIdentifier: pid)
        else { return }
        app.activate()
    }

    private static func parentPid(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent > 0 ? parent : nil
    }
}
