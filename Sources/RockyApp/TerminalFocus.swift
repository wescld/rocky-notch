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
        var target = session.jumpTarget
        // Sessions captured before we read WARP_TERMINAL_SESSION_UUID still
        // lack warpPaneUUID. Re-probe the live agent process env when possible.
        if target?.terminalApp == "Warp" || target == nil,
           normalizedWarpUUID(target?.warpPaneUUID) == nil,
           let liveUUID = warpUUIDFromLiveAgent(session: session) {
            var refined = target ?? JumpTarget(terminalApp: "Warp")
            refined.warpPaneUUID = liveUUID
            if refined.terminalApp == nil { refined.terminalApp = "Warp" }
            target = refined
        }

        if let target {
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
                if jumpToGhostty(target) { return }
            default:
                break
            }
        }
        activateHost(session: session)
    }

    /// Read `WARP_TERMINAL_SESSION_UUID` from a still-running agent CLI.
    private static func warpUUIDFromLiveAgent(session: AgentSession) -> String? {
        guard let pid = session.agentProcessPid,
              isAgentProcessStillValid(pid: pid, agent: session.agent)
        else { return nil }
        if let raw = processEnvironmentValue(pid: pid, key: "WARP_TERMINAL_SESSION_UUID") {
            return TerminalProbe.normalizeWarpSessionUUID(raw)
        }
        if let url = processEnvironmentValue(pid: pid, key: "WARP_FOCUS_URL") {
            return TerminalProbe.parseWarpFocusURL(url)
        }
        return nil
    }

    /// Best-effort `KEY=value` lookup from another process's environment.
    private static func processEnvironmentValue(pid: Int32, key: String) -> String? {
        // `ps eww` dumps the env of same-user processes without entitlements.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["eww", "-p", "\(pid)"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        // ps eww: one long line of space-separated KEY=value tokens.
        let prefix = key + "="
        for token in text.split(whereSeparator: { $0 == " " || $0 == "\n" }) {
            let s = String(token)
            if s.hasPrefix(prefix) {
                let value = String(s.dropFirst(prefix.count))
                return value.isEmpty ? nil : value
            }
        }
        return nil
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
        // Best path: Warp's own deep link focuses the exact session/tab.
        // This does not need Accessibility and works even when SQLite
        // `terminal_panes` is empty (current Warp Stable).
        if let uuid = normalizedWarpUUID(target.warpPaneUUID) {
            if run("/usr/bin/open", ["warp://session/\(uuid)"]) {
                return
            }
        }

        // No session UUID (or open failed) — activate Warp, then try the
        // legacy Accessibility tab-cycle if we still have a locator.
        _ = run("/usr/bin/open", ["-b", "dev.warp.Warp-Stable"])

        guard let targetPaneUUID = normalizedWarpUUID(target.warpPaneUUID) else {
            return
        }

        let reader = WarpSQLiteReader()
        let start = Date()
        while !isWarpFrontmost() {
            if Date().timeIntervalSince(start) >= warpFrontmostMaxWait { break }
            Thread.sleep(forTimeInterval: warpFrontmostPollInterval)
        }

        let targetUpper = targetPaneUUID.uppercased()
        if reader.currentFocusedPaneUUID()?.uppercased() == targetUpper {
            return
        }

        let tabCount = max(1, reader.tabCountInActiveWindow())
        // If SQLite has no tabs, cycling is hopeless — stay on activated Warp.
        guard tabCount > 0 else { return }

        let maxAttempts = tabCount + 2
        for _ in 0..<maxAttempts {
            advanceWarpTab()
            Thread.sleep(forTimeInterval: warpTabCycleSettleDelay)
            if reader.currentFocusedPaneUUID()?.uppercased() == targetUpper {
                return
            }
        }
        // Cycle failed — Warp is at least activated.
    }

    /// Lowercase 32-hex form accepted by `warp://session/<uuid>`.
    private static func normalizedWarpUUID(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return TerminalProbe.normalizeWarpSessionUUID(raw)
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

    /// Focus a Ghostty surface by stable terminal id (preferred), else cwd.
    ///
    /// Ghostty's sdef exposes `window` / `tab` / `terminal` with `id`, plus
    /// `activate window`, `select tab`, and `focus` on a terminal. Focus of a
    /// split can settle asynchronously, so we retry a few times when we have
    /// a surface id. No id and no cwd → activate app only (still "success"
    /// so the caller does not double-activate via `activateHost`).
    ///
    /// Limitations: requires Automation permission for Ghostty; surface ids
    /// are only trustworthy when captured on SessionStart/UserPromptSubmit
    /// (see `TerminalProbe`). If the surface was closed, falls through to
    /// app activate.
    private static func jumpToGhostty(_ target: JumpTarget) -> Bool {
        let sessionID = target.terminalSessionID?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cwd = target.workingDirectory?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if sessionID.isEmpty, cwd.isEmpty {
            return run("/usr/bin/open", ["-b", "com.mitchellh.ghostty"])
        }

        let sid = escapeAppleScript(sessionID.isEmpty ? nil : sessionID)
        let wd = escapeAppleScript(cwd.isEmpty ? nil : cwd)
        // Delays are small; Ghostty applies focus asynchronously after `focus`.
        let source = """
        tell application "Ghostty"
            if not (it is running) then return false
            activate

            set targetWindow to missing value
            set targetTab to missing value
            set targetTerminal to missing value

            if "\(sid)" is not "" then
                repeat with aWindow in windows
                    repeat with aTab in tabs of aWindow
                        repeat with aTerminal in terminals of aTab
                            try
                                if (id of aTerminal as text) is "\(sid)" then
                                    set targetWindow to aWindow
                                    set targetTab to aTab
                                    set targetTerminal to aTerminal
                                    exit repeat
                                end if
                            end try
                        end repeat
                        if targetTerminal is not missing value then exit repeat
                    end repeat
                    if targetTerminal is not missing value then exit repeat
                end repeat
            end if

            if targetTerminal is missing value and "\(wd)" is not "" then
                repeat with aWindow in windows
                    repeat with aTab in tabs of aWindow
                        repeat with aTerminal in terminals of aTab
                            try
                                if (working directory of aTerminal as text) is "\(wd)" then
                                    set targetWindow to aWindow
                                    set targetTab to aTab
                                    set targetTerminal to aTerminal
                                    exit repeat
                                end if
                            end try
                        end repeat
                        if targetTerminal is not missing value then exit repeat
                    end repeat
                    if targetTerminal is not missing value then exit repeat
                end repeat
            end if

            if targetTerminal is missing value then return false

            repeat 3 times
                try
                    if targetWindow is not missing value then
                        activate window targetWindow
                        delay 0.04
                    end if
                    if targetTab is not missing value then
                        select tab targetTab
                        delay 0.04
                    end if
                    focus targetTerminal
                    delay 0.08
                end try

                if "\(sid)" is "" then return true

                try
                    if (id of focused terminal of selected tab of front window as text) is "\(sid)" then
                        return true
                    end if
                end try
            end repeat

            -- Matched a surface but could not confirm focus; still best-effort.
            return true
        end tell
        """
        if runAppleScriptBool(source) {
            return true
        }
        // Script miss / Automation denied — at least bring Ghostty forward.
        return run("/usr/bin/open", ["-b", "com.mitchellh.ghostty"])
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
