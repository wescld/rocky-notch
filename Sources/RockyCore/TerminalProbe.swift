import Darwin
import Foundation

/// Best-effort terminal metadata for jump-back. Pure over env (+ optional
/// providers) so unit tests never need a real terminal or Warp install.
///
/// Fail-open: every path returns a partial `JumpTarget`; never throws.
public enum TerminalProbe {
    /// Build a jump target from the hook process environment.
    ///
    /// - Parameters:
    ///   - environment: process env (`ProcessInfo.processInfo.environment`)
    ///   - cwd: session working directory from the hook payload
    ///   - currentTTY: provider for the controlling TTY path
    ///   - warpPaneResolver: optional Warp pane UUID for `cwd` (SQLite)
    public static func jumpTarget(
        environment: [String: String],
        cwd: String?,
        currentTTY: () -> String? = { Self.currentTTYPath() },
        warpPaneResolver: (String) -> String? = { _ in nil }
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
            // Ghostty exposes GHOSTTY_SURFACE_ID in newer builds; optional.
            target.terminalSessionID =
                emptyToNil(environment["GHOSTTY_SURFACE_ID"])
                ?? target.terminalSessionID
        }

        if target.terminalTTY == nil {
            target.terminalTTY = currentTTY()
        }

        if terminalApp == "Warp", let cwd, !cwd.isEmpty {
            target.warpPaneUUID = warpPaneResolver(cwd)
        }

        return target
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
        if environment["GHOSTTY_RESOURCES_DIR"] != nil {
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

    private static func emptyToNil(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
