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
        case "opencode":
            // Binary is `opencode`; Bun may appear in the tree when spawning
            // the bridge plugin's child rocky-hook process.
            return ["opencode"]
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
            if isAgentProcess(pid: parent, markers: markers) == true {
                return Int32(parent)
            }
            if let name = processName(of: parent)?.lowercased(), isLikelyGuiHost(name) {
                return nil
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

    /// Agent CLI still running **and** still the agent.
    /// After Ctrl+C the PID can be reused by an unrelated process; a bare
    /// `kill(pid, 0)` would keep the Rocky card forever in that case.
    public static func isAgentProcessStillValid(pid: Int32, agent: String) -> Bool {
        guard isProcessAlive(pid) else { return false }
        let markers = agentNameMarkers(for: agent)
        // Cursor / unknown: existence alone is enough.
        guard !markers.isEmpty else { return true }
        // Identity unreadable — keep (fail-open), as before.
        return isAgentProcess(pid: pid_t(pid), markers: markers) ?? true
    }

    /// Whether a live process is this agent's CLI. `nil` when its identity
    /// could not be read at all, which callers treat as "no opinion" rather
    /// than as a denial.
    static func isAgentProcess(pid: pid_t, markers: [String]) -> Bool? {
        identityMatches(
            executablePath: executablePath(of: pid),
            processName: processName(of: pid),
            markers: markers
        )
    }

    /// Split out from the process lookup so the rule itself is testable.
    ///
    /// The path is consulted first and the name second, because the name alone
    /// is not enough: the Claude Code installer keeps its binary at
    /// `.../claude/versions/<version>`, so `proc_name` returns the version
    /// number and no marker ever matches it — Rocky never resolved an agent PID
    /// for a Claude Code session, which cost those rows both Ctrl+C detection
    /// and their full retention window. The name check stays as a fallback so
    /// agents that already resolved keep resolving when a path is unreadable.
    static func identityMatches(
        executablePath: String?,
        processName: String?,
        markers: [String]
    ) -> Bool? {
        if let processName, nameMatches(processName.lowercased(), markers: markers) {
            return true
        }
        // Only the path may answer "no". A name that does not match is the
        // normal state of a live Claude Code process — it is named after its
        // version — so letting the name deny would report a running agent as
        // gone, and `pruneDeadHosts` would drop the session off the notch.
        guard let executablePath else { return nil }
        return isAgentExecutable(executablePath, markers: markers)
    }

    /// Working directories of every live process that looks like `agent`.
    ///
    /// Answers "could a session of this agent still be alive in that folder?".
    /// Returns nil whenever the answer cannot be trusted — the process list is
    /// unreadable, or a matching process exists whose directory we could not
    /// read — so callers can tell "nothing is running" apart from "I could not
    /// tell", and never act on the second as if it were the first.
    ///
    /// Matching is on the executable's *path*, not its name: the Claude Code
    /// installer keeps the binary at `.../claude/versions/<version>`, so
    /// `proc_name` reports the version number and a name check never matches.
    public static func agentWorkingDirectories(for agent: String) -> Set<String>? {
        let markers = agentNameMarkers(for: agent)
        guard !markers.isEmpty, let pids = allPids() else { return nil }
        var directories: Set<String> = []
        var unreadable = false
        for pid in pids where pid > 0 {
            // Same rule the ancestry walk uses, name fallback included: a
            // path-only check would skip a live agent whose path failed to
            // read, and a skipped agent reads as "not running there".
            switch isAgentProcess(pid: pid, markers: markers) {
            case .some(false):
                continue
            case nil:
                // Could be the agent; nothing about it was readable.
                unreadable = true
            case .some(true):
                // A process can exit between the two lookups, and one whose
                // directory we cannot read says nothing about the others —
                // abandoning the whole scan for it would answer "cannot tell"
                // for the machine, which keeps every stale row alive.
                if let cwd = workingDirectory(of: pid) {
                    directories.insert(cwd)
                } else {
                    unreadable = true
                }
            }
        }
        // Matches existed but not one of them could be placed: that genuinely
        // is no information, and must not read as "nothing is running".
        if directories.isEmpty, unreadable { return nil }
        return directories
    }

    /// A marker has to own a whole path component, so `claude` matches
    /// `~/.local/share/claude/versions/2.1.220` and `~/.claude/local/claude`,
    /// but not Claude Code's own scratch root at `/private/tmp/claude-501/…`.
    /// A leading dot is ignored so a hidden install directory still counts.
    /// Bundled apps are excluded outright: `/Applications/Claude.app/...` is
    /// the desktop app, not the CLI.
    static func isAgentExecutable(_ path: String, markers: [String]) -> Bool {
        guard !path.contains(".app/") else { return false }
        return path.split(separator: "/").contains { component in
            // Case-insensitive: markers are lower-cased, but a path keeps the
            // casing it was created with, and macOS volumes are usually
            // case-insensitive — so a `Claude/` install would slip past.
            let name = (component.hasPrefix(".") ? component.dropFirst() : component[...])
                .lowercased()
            return markers.contains(name)
        }
    }

    /// Every live PID, or nil if the table could not be read.
    ///
    /// A filled buffer is indistinguishable from a truncated one, and a missed
    /// process reads as "that agent is not running" — the answer that costs a
    /// live row. So a full buffer is retried larger rather than accepted.
    private static func allPids() -> [pid_t]? {
        var capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return nil }
        for _ in 0..<4 {
            // Room to spare: processes can appear between sizing and reading.
            var pids = [pid_t](repeating: 0, count: Int(capacity) + 128)
            let byteCount = Int32(MemoryLayout<pid_t>.size * pids.count)
            let written = proc_listallpids(&pids, byteCount)
            guard written > 0 else { return nil }
            if Int(written) < pids.count {
                return Array(pids.prefix(Int(written)))
            }
            capacity = Int32(pids.count * 2)
        }
        return nil
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let read = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, $0, size)
        }
        guard read == size else { return nil }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }
        return path.isEmpty ? nil : path
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
