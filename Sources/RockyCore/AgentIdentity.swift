import Foundation

/// Works out which CLI invoked the hook.
///
/// The shape of the reply depends on this: Grok expects
/// `{"decision":"allow|deny"}` while Claude Code and Codex expect
/// `hookSpecificOutput`. Guessing wrong means the decision never reaches the
/// agent, so an explicit `--agent` from our own installs always wins over the
/// environment sniff.
public enum AgentIdentity {
    public static let fallback = "claude-code"

    /// Env vars Grok injects into every hook it runs. They are inherited by
    /// child processes, so a `claude` launched from a Grok shell command sees
    /// them too — hence the sniff is only a last resort.
    static let grokEnvKeys = ["GROK_HOOK_EVENT", "GROK_SESSION_ID"]

    public static func resolve(
        arguments: [String],
        environment: [String: String]
    ) -> String {
        if let explicit = explicitAgent(in: arguments) {
            return explicit
        }
        if grokEnvKeys.contains(where: { environment[$0]?.isEmpty == false }) {
            return "grok"
        }
        return fallback
    }

    /// `--agent <name>`; ignored when the flag is last or the value is blank.
    private static func explicitAgent(in arguments: [String]) -> String? {
        guard let flag = arguments.firstIndex(of: "--agent"), flag + 1 < arguments.count else {
            return nil
        }
        let value = arguments[flag + 1].trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }
}
