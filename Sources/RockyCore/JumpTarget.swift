import Foundation

/// Where to put focus when the user clicks a session in the notch.
///
/// Captured by `rocky-hook` while the agent process tree is still alive
/// (env + TTY + Warp SQLite). The app uses it for precision jump-back;
/// missing fields degrade to "activate the host GUI PID".
public struct JumpTarget: Codable, Equatable, Sendable {
    /// Human terminal name: `Warp`, `Ghostty`, `Terminal`, `iTerm`, …
    public var terminalApp: String?
    public var workingDirectory: String?
    /// e.g. `/dev/ttys012`
    public var terminalTTY: String?
    /// Terminal-local session id when available (iTerm `ITERM_SESSION_ID`,
    /// Ghostty surface UUID via AppleScript / optional env, cmux surface…).
    /// For Ghostty this is only refreshed on SessionStart / UserPromptSubmit.
    public var terminalSessionID: String?
    /// `session:window.pane` for tmux (`$TMUX_PANE` resolved).
    public var tmuxTarget: String?
    public var tmuxSocketPath: String?
    /// Warp session / leaf pane UUID (hex, no separators). Sourced from
    /// `WARP_TERMINAL_SESSION_UUID` / `WARP_FOCUS_URL` when available, else
    /// from Warp's SQLite `terminal_panes.uuid`. Used with `warp://session/<uuid>`.
    public var warpPaneUUID: String?

    public init(
        terminalApp: String? = nil,
        workingDirectory: String? = nil,
        terminalTTY: String? = nil,
        terminalSessionID: String? = nil,
        tmuxTarget: String? = nil,
        tmuxSocketPath: String? = nil,
        warpPaneUUID: String? = nil
    ) {
        self.terminalApp = terminalApp
        self.workingDirectory = workingDirectory
        self.terminalTTY = terminalTTY
        self.terminalSessionID = terminalSessionID
        self.tmuxTarget = tmuxTarget
        self.tmuxSocketPath = tmuxSocketPath
        self.warpPaneUUID = warpPaneUUID
    }

    /// True when we have something more useful than a bare host PID activate.
    public var hasPreciseLocator: Bool {
        let strings = [terminalSessionID, terminalTTY, tmuxTarget, warpPaneUUID]
        return strings.contains { value in
            guard let value else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Merge non-nil fields from `other` over this target (later hooks refine).
    public func merging(_ other: JumpTarget) -> JumpTarget {
        JumpTarget(
            terminalApp: other.terminalApp ?? terminalApp,
            workingDirectory: other.workingDirectory ?? workingDirectory,
            terminalTTY: other.terminalTTY ?? terminalTTY,
            terminalSessionID: other.terminalSessionID ?? terminalSessionID,
            tmuxTarget: other.tmuxTarget ?? tmuxTarget,
            tmuxSocketPath: other.tmuxSocketPath ?? tmuxSocketPath,
            warpPaneUUID: other.warpPaneUUID ?? warpPaneUUID
        )
    }
}
