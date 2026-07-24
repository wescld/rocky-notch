import Foundation

/// Opt-in Claude Code statusLine bridge that caches account rate limits for Rocky.
///
/// Writes `~/.rocky/bin/rocky-statusline` and points `statusLine.command` at it.
/// If the user already has a custom status line, installs in **wrapper** mode
/// so their display stays intact and we only tee `rate_limits` to the cache.
public enum ClaudeStatusLineInstaller {
    public static let managedScriptName = "rocky-statusline"
    public static let wrapperDelegateName = "rocky-statusline-delegate"
    public static let originalStatusLineKey = "_rockyOriginalStatusLine"

    public static var scriptDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".rocky/bin", isDirectory: true)
    }

    public static var scriptURL: URL {
        scriptDirectory.appendingPathComponent(managedScriptName)
    }

    public static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }

    public static var cacheURL: URL { ClaudeUsageLoader.defaultCacheURL }

    public struct Status: Equatable, Sendable {
        public var isInstalled: Bool
        public var isWrapper: Bool
        public var hasConflict: Bool
        public var command: String?

        public init(isInstalled: Bool, isWrapper: Bool, hasConflict: Bool, command: String?) {
            self.isInstalled = isInstalled
            self.isWrapper = isWrapper
            self.hasConflict = hasConflict
            self.command = command
        }
    }

    public static func status(
        settingsData: Data? = try? Data(contentsOf: settingsURL)
    ) -> Status {
        let settings = parseSettings(settingsData) ?? [:]
        let command = (settings["statusLine"] as? [String: Any])?["command"] as? String
        let isInstalled = command == scriptURL.path
            || (command?.contains(managedScriptName) == true)
        let isWrapper = settings[originalStatusLineKey] != nil
        let hasConflict = command != nil && !isInstalled
        return Status(
            isInstalled: isInstalled,
            isWrapper: isWrapper,
            hasConflict: hasConflict,
            command: command
        )
    }

    public enum InstallError: LocalizedError {
        case unparseableSettings

        public var errorDescription: String? {
            switch self {
            case .unparseableSettings:
                "Could not parse ~/.claude/settings.json"
            }
        }
    }

    /// Install managed status line. Wraps an existing custom statusLine when present.
    public static func install() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: scriptDirectory, withIntermediateDirectories: true)

        let existingData = try? Data(contentsOf: settingsURL)
        var settings = parseSettings(existingData) ?? [:]
        if settings.isEmpty, existingData != nil {
            throw InstallError.unparseableSettings
        }

        let existingCommand = (settings["statusLine"] as? [String: Any])?["command"] as? String
        let alreadyOurs = existingCommand == scriptURL.path
            || (existingCommand?.contains(managedScriptName) == true)

        if let existingCommand, !existingCommand.isEmpty, !alreadyOurs {
            // Wrapper mode: preserve original.
            settings[originalStatusLineKey] = settings["statusLine"]
            let delegateURL = scriptDirectory.appendingPathComponent(wrapperDelegateName)
            let delegate = "#!/bin/bash\n# Original Claude statusLine preserved by Rocky.\n\(existingCommand)\n"
            try delegate.write(to: delegateURL, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: delegateURL.path)
            try writeScript(wrapperScript(delegatePath: delegateURL.path), to: scriptURL)
        } else {
            try writeScript(managedScript(), to: scriptURL)
        }

        settings["statusLine"] = ["type": "command", "command": scriptURL.path]
        let data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: settingsURL, options: .atomic)
    }

    public static func uninstall() throws {
        let fm = FileManager.default
        let existingData = try? Data(contentsOf: settingsURL)
        guard var settings = parseSettings(existingData) else { return }

        let current = status(settingsData: existingData)
        guard current.isInstalled || settings[originalStatusLineKey] != nil else { return }

        if let original = settings[originalStatusLineKey] {
            settings["statusLine"] = original
            settings.removeValue(forKey: originalStatusLineKey)
        } else if current.isInstalled {
            settings.removeValue(forKey: "statusLine")
        }

        let data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: settingsURL, options: .atomic)

        try? fm.removeItem(at: scriptURL)
        try? fm.removeItem(at: scriptDirectory.appendingPathComponent(wrapperDelegateName))
    }

    // MARK: - Scripts

    public static func managedScript(cachePath: String = ClaudeUsageLoader.defaultCacheURL.path) -> String {
        """
        #!/bin/bash
        # Rocky Claude statusLine — caches rate_limits for the notch usage chip.
        input=$(cat)
        _rl=$(printf '%s' "$input" | /usr/bin/jq -c '.rate_limits // empty' 2>/dev/null)
        [ -n "$_rl" ] && printf '%s\\n' "$_rl" > "\(cachePath)"
        printf '%s' "$input" | /usr/bin/jq -r '"[\\(.model.display_name // "Claude")] \\(.context_window.used_percentage // 0)% context"' 2>/dev/null \\
          || printf 'Claude\\n'
        """
    }

    public static func wrapperScript(
        delegatePath: String,
        cachePath: String = ClaudeUsageLoader.defaultCacheURL.path
    ) -> String {
        """
        #!/bin/bash
        # Rocky Claude statusLine wrapper — tees rate_limits, keeps your display.
        input=$(cat)
        _rl=$(printf '%s' "$input" | /usr/bin/jq -c '.rate_limits // empty' 2>/dev/null)
        [ -n "$_rl" ] && printf '%s\\n' "$_rl" > "\(cachePath)"
        printf '%s' "$input" | "\(delegatePath)"
        """
    }

    private static func writeScript(_ contents: String, to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }

    private static func parseSettings(_ data: Data?) -> [String: Any]? {
        guard let data else { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any]
        else { return nil }
        return dict
    }
}
