import Darwin
import Foundation

/// Best-effort terminal metadata for jump-back. Pure over env (+ optional
/// providers) so unit tests never need a real terminal or Warp install.
///
/// Fail-open: every path returns a partial `JumpTarget`; never throws.
///
/// ## Ghostty limitations
/// Current Ghostty (macOS) sets `TERM_PROGRAM=ghostty`, `GHOSTTY_RESOURCES_DIR`,
/// `GHOSTTY_BIN_DIR`, and `GHOSTTY_SHELL_FEATURES`, but does **not** export a
/// per-surface id into the shell environment. The stable surface UUID only
/// appears via AppleScript (`id of terminal`). We optionally query the
/// *focused* terminal on SessionStart / UserPromptSubmit — the only moments
/// the focused surface is reliably the session's host. Later hooks must not
/// refresh that id: the user may have switched tabs, and stamping the newly
/// focused surface would send jump-back to the wrong place. Merge preserves
/// the last good `terminalSessionID` when later probes leave it nil.
public enum TerminalProbe {
    /// Hook events where Ghostty's focused-surface AppleScript (or any env
    /// surface id) is safe to trust.
    public static let ghosttySurfaceSafeEvents: Set<String> = [
        "SessionStart",
        "UserPromptSubmit",
        "BeforeSubmitPrompt",
    ]

    /// Build a jump target from the hook process environment.
    ///
    /// - Parameters:
    ///   - environment: process env (`ProcessInfo.processInfo.environment`)
    ///   - cwd: session working directory from the hook payload
    ///   - hookEventName: raw/canonical hook event name; gates Ghostty surface capture
    ///   - currentTTY: provider for the controlling TTY path
    ///   - warpPaneResolver: optional Warp pane UUID for `cwd` (SQLite)
    ///   - ghosttySurfaceResolver: optional AppleScript (or test) surface-id probe
    public static func jumpTarget(
        environment: [String: String],
        cwd: String?,
        hookEventName: String? = nil,
        currentTTY: () -> String? = { Self.currentTTYPath() },
        warpPaneResolver: (String) -> String? = { _ in nil },
        ghosttySurfaceResolver: () -> String? = { nil }
    ) -> JumpTarget {
        let terminalApp = inferTerminalApp(from: environment)
        var target = JumpTarget(
            terminalApp: terminalApp,
            workingDirectory: emptyToNil(cwd)
        )

        // tmux: capture before outer-terminal specifics so the jump can
        // select-pane even when the outer app targeting is best-effort.
        if let tmux = environment["TMUX"], !tmux.isEmpty {
            target.tmuxSocketPath = tmuxSocketPath(from: tmux)
            target.tmuxTarget = resolveTmuxTarget(environment: environment)
        }

        if terminalApp == "cmux" {
            target.terminalSessionID = emptyToNil(environment["CMUX_SURFACE_ID"])
        }

        if terminalApp == "iTerm" {
            // ITERM_SESSION_ID looks like "w0t0p0:UUID"
            target.terminalSessionID =
                emptyToNil(environment["ITERM_SESSION_ID"])
                ?? target.terminalSessionID
        }

        if terminalApp == "Ghostty" {
            // Only stamp a surface id on safe events. Unsafe events leave
            // terminalSessionID nil so SessionStore.merging keeps the prior id.
            if shouldCaptureGhosttySurfaceID(hookEventName: hookEventName) {
                target.terminalSessionID =
                    ghosttySurfaceID(from: environment)
                    ?? emptyToNil(ghosttySurfaceResolver())
                    ?? target.terminalSessionID
            }
        }

        if target.terminalTTY == nil {
            // ctermid can return the generic "/dev/tty", which is not a real
            // device path and is useless for Terminal.app tab matching.
            if let tty = currentTTY(), tty != "/dev/tty", tty.hasPrefix("/dev/") {
                target.terminalTTY = tty
            }
        }

        if terminalApp == "Warp" {
            // Prefer the live session UUID Warp injects into every shell
            // (`WARP_TERMINAL_SESSION_UUID` / `WARP_FOCUS_URL`). Newer Warp
            // builds leave `terminal_panes` empty in SQLite, so the cwd→pane
            // lookup often returns nil — the env var is the reliable path.
            target.warpPaneUUID =
                Self.warpSessionUUID(from: environment)
                ?? {
                    guard let cwd, !cwd.isEmpty else { return nil }
                    return warpPaneResolver(cwd)
                }()
        }

        return target
    }

    /// Whether this hook event is safe to use for Ghostty surface id capture.
    ///
    /// - `nil` event name: treat as safe (manual/test probes, no merge risk).
    /// - SessionStart / UserPromptSubmit (and Cursor BeforeSubmitPrompt): safe.
    /// - Everything else: skip — focused-surface queries would be wrong after
    ///   the user switches Ghostty tabs mid-turn.
    public static func shouldCaptureGhosttySurfaceID(hookEventName: String?) -> Bool {
        guard let hookEventName, !hookEventName.isEmpty else { return true }
        let canonical = HookEvent.Kind.canonical(hookEventName)
        return ghosttySurfaceSafeEvents.contains(canonical)
    }

    /// Surface / terminal id from Ghostty-related env vars when present.
    ///
    /// Current Ghostty releases do not set these; kept for forward-compat and
    /// custom builds. Order is most-specific first.
    public static func ghosttySurfaceID(from environment: [String: String]) -> String? {
        let keys = [
            "GHOSTTY_SURFACE_ID",
            "GHOSTTY_TERMINAL_ID",
            "GHOSTTY_SESSION_ID",
        ]
        for key in keys {
            if let value = emptyToNil(environment[key]) {
                return value
            }
        }
        // macOS sometimes exposes TERM_SESSION_ID; only trust it alongside
        // Ghostty identity so we do not steal another terminal's session token.
        if inferTerminalApp(from: environment) == "Ghostty" {
            return emptyToNil(environment["TERM_SESSION_ID"])
        }
        return nil
    }

    /// Query Ghostty for the focused terminal surface id via AppleScript.
    ///
    /// Fail-open: returns nil on any error / timeout. Intended for hook use on
    /// SessionStart / UserPromptSubmit only (see `shouldCaptureGhosttySurfaceID`).
    public static func queryGhosttyFocusedSurfaceID(
        runner: ((String) -> String?)? = nil
    ) -> String? {
        let script = """
        tell application "Ghostty"
            if not (it is running) then return ""
            try
                return id of focused terminal of selected tab of front window as text
            on error
                return ""
            end try
        end tell
        """
        let run = runner ?? { runOsascript($0, timeout: 0.35) }
        return emptyToNil(run(script))
    }

    /// Warp session UUID used by `warp://session/<uuid>` deep links.
    /// Accepts bare `WARP_TERMINAL_SESSION_UUID` or parses `WARP_FOCUS_URL`.
    public static func warpSessionUUID(from environment: [String: String]) -> String? {
        if let raw = emptyToNil(environment["WARP_TERMINAL_SESSION_UUID"]) {
            return normalizeWarpSessionUUID(raw)
        }
        if let url = emptyToNil(environment["WARP_FOCUS_URL"]),
           let uuid = parseWarpFocusURL(url) {
            return uuid
        }
        return nil
    }

    /// `warp://session/<uuid>` → uuid (hex, no separators).
    public static func parseWarpFocusURL(_ url: String) -> String? {
        // Expected: warp://session/<32-hex>  (optionally with dashes)
        guard let schemeRange = url.range(of: "://") else { return nil }
        let rest = url[schemeRange.upperBound...]
        let parts = rest.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: true)
        // parts[0] = "session", parts[1] = uuid  (host may be "session" when no authority)
        if parts.count >= 2, parts[0].lowercased() == "session" {
            return normalizeWarpSessionUUID(String(parts[1]))
        }
        // Alternate: warp://session/UUID parsed with URLComponents host+path
        if let components = URLComponents(string: url),
           components.host?.lowercased() == "session" {
            let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return normalizeWarpSessionUUID(path)
        }
        return nil
    }

    public static func normalizeWarpSessionUUID(_ raw: String) -> String? {
        let cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        guard cleaned.count == 32,
              cleaned.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdef").contains($0) })
        else {
            return nil
        }
        return cleaned
    }

    // MARK: - Terminal inference

    /// Prefer `TERM_PROGRAM` (set by the terminal when exec'ing the shell).
    /// Fall back to well-known env vars only when TERM_PROGRAM is empty —
    /// those can leak across GUI apps via macOS inheritance.
    public static func inferTerminalApp(from environment: [String: String]) -> String? {
        if environment["CMUX_WORKSPACE_ID"] != nil || environment["CMUX_SOCKET_PATH"] != nil {
            return "cmux"
        }
        if environment["ZELLIJ"] != nil {
            return "Zellij"
        }

        if let termProgram = environment["TERM_PROGRAM"]?.lowercased(), !termProgram.isEmpty {
            switch termProgram {
            case "apple_terminal":
                return "Terminal"
            case "iterm.app", "iterm2":
                return "iTerm"
            case let value where value.contains("warp"):
                return "Warp"
            case let value where value.contains("ghostty"):
                return "Ghostty"
            case let value where value.contains("wezterm"):
                return "WezTerm"
            case "vscode":
                return "VS Code"
            case "vscode-insiders":
                return "VS Code Insiders"
            default:
                break
            }
        }

        if environment["ITERM_SESSION_ID"] != nil || environment["LC_TERMINAL"] == "iTerm2" {
            return "iTerm"
        }
        if environment["WARP_IS_LOCAL_SHELL_SESSION"] != nil {
            return "Warp"
        }
        if environment["GHOSTTY_RESOURCES_DIR"] != nil || environment["GHOSTTY_BIN_DIR"] != nil {
            return "Ghostty"
        }
        return nil
    }

    // MARK: - TTY / tmux helpers

    public static func currentTTYPath() -> String? {
        // ttyname(STDIN_FILENO) is often nil for hooks (stdin is a pipe from
        // the agent). Walk /dev/fd via ttyname on the controlling terminal.
        if let path = ttyname(STDIN_FILENO) {
            let s = String(cString: path)
            if s.hasPrefix("/dev/") { return s }
        }
        // ctermid returns the controlling terminal path.
        var buf = [CChar](repeating: 0, count: Int(L_ctermid))
        guard ctermid(&buf) != nil else { return nil }
        let path = String(cString: buf)
        guard !path.isEmpty, path != "?", FileManager.default.fileExists(atPath: path) else {
            return nil
        }
        return path
    }

    /// `$TMUX` is `socket,pid,session` — socket is the first comma field.
    static func tmuxSocketPath(from tmuxEnv: String) -> String? {
        let socket = tmuxEnv.split(separator: ",", maxSplits: 1).first.map(String.init)
        return emptyToNil(socket)
    }

    /// Prefer `tmux display-message` for a full `session:window.pane` target.
    /// Falls back to bare `$TMUX_PANE` (`%N`) which still works with select-pane.
    static func resolveTmuxTarget(environment: [String: String]) -> String? {
        if let full = runTmuxDisplayMessage(environment: environment) {
            return full
        }
        return emptyToNil(environment["TMUX_PANE"])
    }

    private static func runTmuxDisplayMessage(environment: [String: String]) -> String? {
        // Keep this extremely short: hooks must not stall the agent.
        let tmux = "/usr/bin/tmux"
        guard FileManager.default.isExecutableFile(atPath: tmux)
            || FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/tmux")
            || FileManager.default.isExecutableFile(atPath: "/usr/local/bin/tmux")
        else {
            return nil
        }
        let executable: String
        if FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/tmux") {
            executable = "/opt/homebrew/bin/tmux"
        } else if FileManager.default.isExecutableFile(atPath: "/usr/local/bin/tmux") {
            executable = "/usr/local/bin/tmux"
        } else {
            executable = tmux
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["display-message", "-p", "#S:#I.#P"]
        process.environment = environment
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        // Hard cap: never block the hook for more than a few dozen ms.
        let deadline = Date().addingTimeInterval(0.05)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return emptyToNil(text)
    }

    /// Run `/usr/bin/osascript -e` with a wall-clock cap. Fail-open.
    static func runOsascript(_ source: String, timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func emptyToNil(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
