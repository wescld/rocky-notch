import AppKit
import Darwin
import RockyCore

/// Best-effort "bring the terminal here". The GUI ancestor must be resolved
/// at event time (the hook process dies right after the exchange); focusing
/// later uses the stored PID / JumpTarget. Silent no-op on any failure.
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

    /// Precision jump when we have a `JumpTarget`; otherwise activate the host PID.
    /// Warp tab cycling can take a few hundred ms — always runs off the main thread.
    static func focus(session: AgentSession) {
        DispatchQueue.global(qos: .userInitiated).async {
            focusSync(session: session)
        }
    }

    /// Synchronous jump for tests / callers that already own a background queue.
    static func focusSync(session: AgentSession) {
        if let target = session.jumpTarget {
            // tmux: switch pane first, then focus the outer terminal.
            if let tmuxTarget = target.tmuxTarget, !tmuxTarget.isEmpty {
                _ = selectTmuxPane(target: tmuxTarget, socketPath: target.tmuxSocketPath)
            }

            switch target.terminalApp {
            case "Warp":
                jumpToWarp(target)
                return
            case "Terminal":
                if jumpToTerminalTab(tty: target.terminalTTY) { return }
            case "iTerm":
                if jumpToITerm(sessionID: target.terminalSessionID, tty: target.terminalTTY) {
                    return
                }
            case "Ghostty":
                if jumpToGhostty(sessionID: target.terminalSessionID) { return }
            default:
                break
            }
        }
        activateHost(session: session)
    }

    // MARK: - Host activate (baseline)

    private static func activateHost(session: AgentSession) {
        if let pid = session.terminalAppPid,
           let app = NSRunningApplication(processIdentifier: pid) {
            app.activate()
            return
        }
        // Fall back to bundle id when PID is gone but we know the app.
        if let name = session.jumpTarget?.terminalApp,
           let bundleID = bundleIdentifier(for: name) {
            _ = run("/usr/bin/open", ["-b", bundleID])
        }
    }

    private static func bundleIdentifier(for terminalApp: String) -> String? {
        switch terminalApp {
        case "Warp": return "dev.warp.Warp-Stable"
        case "Ghostty": return "com.mitchellh.ghostty"
        case "Terminal": return "com.apple.Terminal"
        case "iTerm": return "com.googlecode.iterm2"
        case "WezTerm": return "com.github.wez.wezterm"
        default: return nil
        }
    }

    // MARK: - Warp precision

    private static let warpFrontmostMaxWait: TimeInterval = 1.5
    private static let warpFrontmostPollInterval: TimeInterval = 0.025
    private static let warpTabCycleSettleDelay: TimeInterval = 0.1

    private static func jumpToWarp(_ target: JumpTarget) {
        _ = run("/usr/bin/open", ["-b", "dev.warp.Warp-Stable"])

        guard let targetPaneUUID = target.warpPaneUUID, !targetPaneUUID.isEmpty else {
            return
        }

        let reader = WarpSQLiteReader()
        let start = Date()
        while !isWarpFrontmost() {
            if Date().timeIntervalSince(start) >= warpFrontmostMaxWait { break }
            Thread.sleep(forTimeInterval: warpFrontmostPollInterval)
        }

        if reader.currentFocusedPaneUUID() == targetPaneUUID {
            return
        }

        let tabCount = max(1, reader.tabCountInActiveWindow())
        let maxAttempts = tabCount + 2
        for _ in 0..<maxAttempts {
            advanceWarpTab()
            Thread.sleep(forTimeInterval: warpTabCycleSettleDelay)
            if reader.currentFocusedPaneUUID() == targetPaneUUID {
                return
            }
        }
        // Cycle failed — Warp is at least activated.
    }

    private static func isWarpFrontmost() -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "dev.warp.Warp-Stable"
    }

    /// Advance Warp one tab via Accessibility menu click (synthetic Cmd+Shift+]
    /// is unreliable against Warp — AX menu action is the path that works).
    private static func advanceWarpTab() {
        let source = #"""
        tell application id "dev.warp.Warp-Stable" to activate
        delay 0.08
        tell application "System Events"
            tell process "Warp"
                click menu item "Switch to Next Tab" of menu "Tab" of menu bar item "Tab" of menu bar 1
            end tell
        end tell
        """#
        var error: NSDictionary?
        if let script = NSAppleScript(source: source) {
            script.executeAndReturnError(&error)
        }
    }

    // MARK: - Terminal.app / iTerm / Ghostty

    private static func jumpToTerminalTab(tty: String?) -> Bool {
        guard let tty, !tty.isEmpty else { return false }
        let escaped = escapeAppleScript(tty)
        let source = """
        tell application "Terminal"
            if not (it is running) then return false
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    if (tty of t as text) is "\(escaped)" then
                        set selected of t to true
                        set frontmost of w to true
                        return true
                    end if
                end repeat
            end repeat
        end tell
        return false
        """
        return runAppleScriptBool(source)
    }

    private static func jumpToITerm(sessionID: String?, tty: String?) -> Bool {
        let sid = escapeAppleScript(sessionID)
        let ttyEsc = escapeAppleScript(tty)
        let source = """
        tell application "iTerm"
            if not (it is running) then return false
            activate
            repeat with aWindow in windows
                repeat with aTab in tabs of aWindow
                    repeat with aSession in sessions of aTab
                        set matched to false
                        if "\(sid)" is not "" and (id of aSession as text) is "\(sid)" then
                            set matched to true
                        end if
                        if not matched and "\(ttyEsc)" is not "" and (tty of aSession as text) is "\(ttyEsc)" then
                            set matched to true
                        end if
                        if matched then
                            select aWindow
                            tell aWindow to select aTab
                            select aSession
                            return true
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return false
        """
        return runAppleScriptBool(source)
    }

    private static func jumpToGhostty(sessionID: String?) -> Bool {
        // Ghostty scripting is limited; activate + session id when available.
        _ = run("/usr/bin/open", ["-b", "com.mitchellh.ghostty"])
        guard let sessionID, !sessionID.isEmpty else { return true }
        let escaped = escapeAppleScript(sessionID)
        let source = """
        tell application "Ghostty"
            if not (it is running) then return false
            activate
            try
                repeat with aWindow in windows
                    repeat with aTab in tabs of aWindow
                        repeat with aTerminal in terminals of aTab
                            if (id of aTerminal as text) is "\(escaped)" then
                                set frontmost of aWindow to true
                                select aTab
                                return true
                            end if
                        end repeat
                    end repeat
                end repeat
            end try
        end tell
        return false
        """
        return runAppleScriptBool(source)
    }

    // MARK: - tmux

    @discardableResult
    private static func selectTmuxPane(target: String, socketPath: String?) -> Bool {
        guard let tmux = resolveTmuxPath() else { return false }
        var args: [String] = []
        if let socketPath, !socketPath.isEmpty {
            args += ["-S", socketPath]
        }
        args += ["select-pane", "-t", target]
        _ = run(tmux, args)
        // Best-effort: switch client if attached
        if target.contains(":") {
            let session = String(target.split(separator: ":").first ?? "")
            if !session.isEmpty {
                var switchArgs: [String] = []
                if let socketPath, !socketPath.isEmpty {
                    switchArgs += ["-S", socketPath]
                }
                switchArgs += ["switch-client", "-t", session]
                _ = run(tmux, switchArgs)
            }
        }
        return true
    }

    private static func resolveTmuxPath() -> String? {
        for path in ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"] {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    // MARK: - Helpers

    private static func escapeAppleScript(_ value: String?) -> String {
        guard let value else { return "" }
        return value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func runAppleScriptBool(_ source: String) -> Bool {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return false }
        let result = script.executeAndReturnError(&error)
        if error != nil { return false }
        // AppleScript booleans come back as "true"/"false" strings sometimes.
        if result.booleanValue { return true }
        let text = result.stringValue?.lowercased() ?? ""
        return text == "true" || text == "1"
    }

    @discardableResult
    private static func run(_ executable: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
