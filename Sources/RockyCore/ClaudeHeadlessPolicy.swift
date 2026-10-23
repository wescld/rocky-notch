import Foundation

/// Decides when rocky-hook must not turn a Claude Code permission request into
/// a notch card because nobody is at the Claude Code session to begin with.
///
/// Headless CLI/script runs (`claude -p` / `--print`, Python Agent SDK
/// scripts, CI) normally auto-deny anything that would prompt. Routed through
/// Rocky they instead parked a 55 s approvable card on the notch, and a hasty
/// click approved something no human asked for. For those runs the hook now
/// passes through silently, so Claude Code keeps its own headless behaviour.
///
/// Scope is deliberately narrow: only the *blocking* approval of a real tool
/// permission in a Claude Code session is affected. Every other event —
/// session start/stop, prompts, notifications, PostToolUse,
/// SubagentStart/SubagentStop — is still forwarded for display, headless or
/// not. `AskUserQuestion` is always forwarded too: it is Claude asking the
/// user something, not an approval, and the notch is where it gets answered.
///
/// Evidence, captured from Claude Code 2.1.295 with a harmless capture hook
/// (2026-10-09), of what a hook process sees:
///
/// | parent run            | CLAUDE_CODE_ENTRYPOINT | CLAUDE_CODE_SESSION_ATTENDED | parent argv     |
/// |-----------------------|------------------------|------------------------------|-----------------|
/// | interactive TUI       | `cli`                  | `1`                          | no `-p`         |
/// | `claude -p "…"`       | `sdk-cli`              | `0`                          | contains `-p`   |
/// | Python Agent SDK      | `sdk-py`               | `0`                          | no `-p` (stream-json) |
///
/// Claude Code sets both variables itself on every launch (a `-p` run started
/// from an interactive session's shell still reports `sdk-cli` / `0`).
///
/// Decision order:
/// 1. `CLAUDE_CODE_SESSION_ATTENDED=1` → interactive, always keep the card
///    (a TUI that inherited an `sdk-*` entrypoint still says `1`).
/// 2. `CLAUDE_CODE_ENTRYPOINT` present → pass through only if it is in
///    `passthroughEntrypoints`; any other or unknown value keeps the card.
/// 3. No entrypoint at all (older builds) → `-p` / `--print` in the parent
///    `claude` argv.
public enum ClaudeHeadlessPolicy {
    public static let entrypointKey = "CLAUDE_CODE_ENTRYPOINT"
    public static let attendedKey = "CLAUDE_CODE_SESSION_ATTENDED"
    /// Hook flag / env override: `gate` keeps showing cards for headless runs.
    public static let modeFlag = "--headless-permissions"
    public static let modeEnvKey = "ROCKY_HOOK_HEADLESS_PERMISSIONS"
    /// Tool that asks the user a question rather than requesting approval.
    public static let askUserQuestionTool = "AskUserQuestion"

    /// Entrypoints whose permission requests pass through. Deliberately an
    /// allow-list, so a new or unknown entrypoint keeps the safety net:
    /// - `sdk-cli`: `claude -p` / `--print` (shell scripts, CI, test runs);
    /// - `sdk-py`: Python Agent SDK scripts.
    ///
    /// `sdk-ts` is intentionally absent: T3 Code drives Claude Code through
    /// the TypeScript Agent SDK, and in full-access mode its `canUseTool`
    /// auto-approves everything — the notch card is the only chance left to
    /// deny there. Desktop/IDE entrypoints have their own UI and are absent
    /// for the same reason (keep the card unless a run is known to be a
    /// script).
    public static let passthroughEntrypoints: Set<String> = ["sdk-cli", "sdk-py"]

    /// Why a Claude Code session counts as headless.
    public enum Signal: Equatable, Sendable, CustomStringConvertible {
        /// `CLAUDE_CODE_ENTRYPOINT` is one of `passthroughEntrypoints`.
        case sdkEntrypoint(String)
        /// `-p` / `--print` in the parent `claude` argv (no entrypoint env).
        case printFlag

        public var description: String {
            switch self {
            case .sdkEntrypoint(let value): return "entrypoint=\(value)"
            case .printFlag: return "argv -p/--print"
            }
        }
    }

    /// What the hook does with a headless permission request.
    public enum Mode: String, Equatable, Sendable {
        /// Default: exit 0 with no output, no card, no wait.
        case passthrough
        /// Opt-in: forward to the app like an interactive session.
        case gate
    }

    /// `--headless-permissions <mode>` on the hook command wins over
    /// `ROCKY_HOOK_HEADLESS_PERMISSIONS`; anything unrecognised is the
    /// default, `.passthrough`.
    public static func mode(hookArguments: [String], environment: [String: String]) -> Mode {
        let raw = AgentIdentity.flagValue(modeFlag, in: hookArguments)
            ?? environment[modeEnvKey]
        return raw.flatMap { Mode(rawValue: $0.trimmingCharacters(in: .whitespaces).lowercased()) }
            ?? .passthrough
    }

    /// See the decision order in the type documentation.
    public static func headlessSignal(
        environment: [String: String],
        parentArguments: [String]?
    ) -> Signal? {
        let attended = environment[attendedKey]?.trimmingCharacters(in: .whitespaces)
        if attended == "1" { return nil }
        if let entrypoint = environment[entrypointKey]?
            .trimmingCharacters(in: .whitespaces).lowercased(), !entrypoint.isEmpty {
            return passthroughEntrypoints.contains(entrypoint) ? .sdkEntrypoint(entrypoint) : nil
        }
        if let parentArguments, isPrintMode(arguments: parentArguments) {
            return .printFlag
        }
        return nil
    }

    /// The hook-level decision: non-nil means "pass through silently, do not
    /// contact the app". Only a Claude Code tool-permission request in a
    /// headless session qualifies; `AskUserQuestion`, every other agent and
    /// every other event kind — subagent start/stop included — return nil and
    /// are forwarded as before.
    public static func passthroughSignal(
        agent: String,
        eventKind: HookEvent.Kind,
        toolName: String?,
        hookArguments: [String],
        environment: [String: String],
        parentArguments: [String]?
    ) -> Signal? {
        guard agent == "claude-code", eventKind == .permissionRequest else { return nil }
        guard toolName != askUserQuestionTool else { return nil }
        guard mode(hookArguments: hookArguments, environment: environment) == .passthrough else {
            return nil
        }
        return headlessSignal(environment: environment, parentArguments: parentArguments)
    }

    /// Boolean short options of the `claude` CLI that may be bundled with
    /// `-p` (commander accepts `-cp`).
    private static let bundleableShortFlags: Set<Character> = ["p", "c", "d", "v"]

    /// `claude … -p|--print …` (also `--print=…` and bundled `-cp`). `argv[0]`
    /// is skipped and scanning stops at `--`, after which everything is a
    /// positional prompt. A prompt is a single argv element, so text such as
    /// `"explain -p"` never matches.
    public static func isPrintMode(arguments: [String]) -> Bool {
        for argument in arguments.dropFirst() {
            if argument == "--" { return false }
            if argument == "-p" || argument == "--print" || argument.hasPrefix("--print=") {
                return true
            }
            if argument.count > 2, argument.hasPrefix("-"), !argument.hasPrefix("--") {
                let letters = argument.dropFirst()
                if letters.contains("p"), letters.allSatisfy({ bundleableShortFlags.contains($0) }) {
                    return true
                }
            }
        }
        return false
    }
}
