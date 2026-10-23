import Foundation

public enum ClaudeHookCapabilities {
    /// StopFailure was introduced in Claude Code 2.1.78. Older releases use
    /// an enum-keyed hooks schema and can reject the entire settings file.
    /// https://github.com/anthropics/claude-code/releases/tag/v2.1.78
    public static func supportsStopFailure(version: String?) -> Bool {
        guard let version else { return false }
        let components = version.split(separator: ".")
        guard components.count == 3, components.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) })
        else { return false }
        let numbers = components.compactMap { Int($0) }
        guard numbers.count == 3 else { return false }
        return !numbers.lexicographicallyPrecedes([2, 1, 78])
    }

    public static func events(version: String?) -> [(name: String, needsReply: Bool)] {
        ClaudeSettingsMerger.claudeEvents + (supportsStopFailure(version: version) ? [("StopFailure", false)] : [])
    }

    /// Native installs resolve to a version-named binary. npm installs carry
    /// a `// Version:` header. Unknown layouts conservatively omit the event.
    public static func version(resolvedBinaryName: String, header: String) -> String? {
        if supportsStopFailure(version: resolvedBinaryName) { return resolvedBinaryName }
        for line in header.split(whereSeparator: \.isNewline) {
            let prefix = "// Version: "
            if line.hasPrefix(prefix) {
                return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}
