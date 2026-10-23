import Foundation

public struct PermissionBrokerFinding: Hashable, Sendable {
    public let agent: String
    public let path: String
    public let detail: String

    public var identityKey: String { "\(agent)|\(path)" }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.agent == rhs.agent && lhs.path == rhs.path
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(agent)
        hasher.combine(path)
    }

    public var description: String {
        "GitKraken — \(agent): \(detail) in \(path). Multiple permission brokers can leave Rocky approvals waiting. Disable the agent status integration in GitKraken Preferences > External Tools, or run gk ai hook uninstall \(agent). For plugins, disable gitkraken-hooks@gitkraken in the agent's plugin settings. Restart the agent afterward. Rocky does not remove foreign hooks."
    }
}

public struct PermissionBrokerSource: Hashable, Sendable {
    public enum Format: Hashable, Sendable { case json, codexTOML, script }
    public let agent: String
    public let path: String
    public let format: Format
    var identityKey: String { "\(agent)|\(path)" }

    public init(agent: String, path: String, format: Format = .json) {
        self.agent = agent
        self.path = path
        self.format = format
    }

    /// Bounded candidates, never a recursive scan of the user's home.
    public static func defaults(
        home: String, projects: [String] = [], environment: [String: String] = [:]
    ) -> [Self] {
        let candidates: [(String, String, Format)] = [
            ("claude-code", ".claude/settings.json", .json),
            ("claude-code", ".claude/settings.local.json", .json),
            ("codex", ".codex/hooks.json", .json),
            ("codex", ".codex/config.toml", .codexTOML),
            ("cursor", ".cursor/hooks.json", .json),
            ("antigravity", ".gemini/config/hooks.json", .json),
            ("antigravity", ".gemini/antigravity-cli/hooks.json", .json),
            ("grok", ".grok/hooks/gitkraken-hooks.json", .json),
            ("grok", ".grok/hooks.json", .json),
            ("augment", ".augment/settings.json", .json),
            ("copilot", ".copilot/hooks.json", .json),
            ("copilot", ".copilot/hooks/gitkraken-hooks.json", .json),
            // Supplemental plugin-declaration configs, not GitKraken's installed
            // bridge. A plugin reference alone is not proof of a blocking broker.
            ("opencode", ".config/opencode/opencode.json", .json),
            ("opencode", ".config/opencode/opencode.jsonc", .json),
            ("opencode", ".config/opencode/plugins/gk-hooks.js", .script),
            ("opencode", ".config/opencode/plugin/gk-hooks.js", .script),
            ("pi", ".pi/agent/extensions/gk-hooks.js", .script),
            ("pi", ".pi/agent/extensions/gk-hooks.ts", .script),
        ]
        var result = candidates.map {
            Self(agent: $0.0, path: (home as NSString).appendingPathComponent($0.1), format: $0.2)
        }
        for (key, agent, relatives, format) in [
            ("CLAUDE_CONFIG_DIR", "claude-code", ["settings.json", "settings.local.json"], Format.json),
            ("CODEX_HOME", "codex", ["hooks.json"], .json),
            ("CODEX_HOME", "codex", ["config.toml"], .codexTOML),
            ("XDG_CONFIG_HOME", "opencode", ["opencode/plugins/gk-hooks.js"], .script),
            ("GROK_HOME", "grok", ["hooks/gitkraken-hooks.json"], .json),
            ("PI_CODING_AGENT_DIR", "pi", ["extensions/gk-hooks.js"], .script),
        ] {
            guard let root = environment[key], root.hasPrefix("/") else { continue }
            for relative in relatives {
                result.append(Self(agent: agent, path: (root as NSString).appendingPathComponent(relative), format: format))
            }
        }
        for project in Set(projects) {
            for (agent, relative) in [
                ("claude-code", ".claude/settings.json"),
                ("claude-code", ".claude/settings.local.json"),
                ("cursor", ".cursor/hooks.json"),
                ("codex", ".codex/config.toml"),
                ("copilot", ".github/hooks/gitkraken-hooks.json"),
                ("augment", ".augment/settings.json"),
                ("opencode", "opencode.json"),
                ("opencode", "opencode.jsonc"),
            ] {
                result.append(Self(
                    agent: agent, path: (project as NSString).appendingPathComponent(relative),
                    format: agent == "codex" ? .codexTOML : .json
                ))
            }
            result.append(Self(agent: "opencode", path: (project as NSString)
                .appendingPathComponent(".opencode/plugins/gk-hooks.js"), format: .script))
        }
        return Array(Set(result)).sorted { $0.path < $1.path }
    }
}

public enum PermissionBrokerScan {
    public static func isBlockingGitKraken(_ command: String) -> Bool {
        // The broker invocation and its flag must belong to one simple command.
        GitCommandRisk.segments(of: command).contains { segment in
            guard let index = segment.firstIndex(where: { ($0 as NSString).lastPathComponent.lowercased() == "gk" }),
                  Array(segment.dropFirst(index + 1).prefix(3)) == ["ai", "hook", "run"] else { return false }
            let wrapped = segment.prefix(index).allSatisfy {
                ["env", "sudo", "command", "exec"].contains($0) || $0.contains("=")
            }
            // Recognize the legacy unquoted macOS install path, but only at
            // the start of this segment (never an echo argument/subsequence).
            let legacyPath = segment.first?.hasPrefix("/") == true
                && segment.prefix(index + 1).joined(separator: " ").lowercased()
                    .hasSuffix("/library/application support/gitkrakencli/gk")
            return (wrapped || legacyPath) && segment.dropFirst(index + 4).contains {
                $0 == "--blocking" || $0 == "--blocking=true"
            }
        }
    }

    /// Handles nested, flat and named JSON hook shapes. Only gate events count.
    static func commands(in value: Any) -> [String] {
        var result: [String] = []
        func walk(_ value: Any, permissionEvent: Bool) {
            if let object = value as? [String: Any] {
                if object["enabled"] as? Bool == false { return }
                let event = object["event"] as? String
                let relevant = permissionEvent || event.map(isPermissionEvent) == true
                for key in ["command", "bash", "powershell"] {
                    if relevant, let command = object[key] as? String, isBlockingGitKraken(command) {
                        result.append(command)
                    }
                }
                for (key, child) in object {
                    walk(child, permissionEvent: relevant || isPermissionEvent(key))
                }
            } else if let array = value as? [Any] {
                array.forEach { walk($0, permissionEvent: permissionEvent) }
            }
        }
        walk(value, permissionEvent: false)
        return result
    }

    private static func isPermissionEvent(_ value: String) -> Bool {
        ["permissionrequest", "pretooluse", "beforeshellexecution", "beforemcpexecution"]
            .contains(value.lowercased().replacingOccurrences(of: "_", with: ""))
    }

    static func inspect(_ data: Data, source: PermissionBrokerSource) -> [PermissionBrokerFinding]? {
        let detail: String
        switch source.format {
        case .codexTOML:
            guard let text = String(data: data, encoding: .utf8), TOMLPluginSettings.isComplete(text)
            else { return nil }
            guard HookHealthCheck.gitkrakenHooksPluginEnabled(in: text) else { return [] }
            detail = "enabled plugin gitkraken-hooks@gitkraken"
        case .script:
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            let compact = text.filter { !$0.isWhitespace }
            let hookRun = text.contains("ai hook run") || compact.contains("\"ai\",\"hook\",\"run\"")
                || compact.contains("'ai','hook','run'")
            guard hookRun, text.contains("--blocking") || text.contains("blocking=true") else { return [] }
            detail = "blocking gk-hooks bridge"
        case .json:
            guard let root = try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed]) as? [String: Any]
            else { return nil }
            if root["disableAllHooks"] as? Bool == true { return [] }
            let plugins = root["enabledPlugins"] as? [String: Any] ?? [:]
            let plugin = plugins["gitkraken-hooks@gitkraken"]
            let enabled = plugin as? Bool == true || plugin is [String]
            guard enabled || !commands(in: root).isEmpty else { return [] }
            detail = enabled ? "enabled plugin gitkraken-hooks@gitkraken" : "blocking permission hook"
        }
        return [PermissionBrokerFinding(agent: source.agent, path: source.path, detail: detail)]
    }
}

/// Injectable reader plus per-appearance deduplication. The watcher debounces
/// scans; disappearance requires a confirming scan so rewrites do not re-alert.
public struct PermissionBrokerMonitor {
    public enum FileContents { case missing, unavailable, data(Data) }
    public private(set) var current: Set<PermissionBrokerFinding> = []
    public private(set) var dismissedKeys: Set<String>
    private var pendingDisappearances: Set<String> = []
    private let read: (String) -> FileContents

    public var needsConfirmation: Bool { !pendingDisappearances.isEmpty }

    public init(dismissedKeys: Set<String> = [], read: @escaping (String) -> FileContents = Self.readFile) {
        self.dismissedKeys = dismissedKeys
        self.read = read
    }

    public mutating func dismiss(_ findings: [PermissionBrokerFinding]) {
        dismissedKeys.formUnion(findings.filter { current.contains($0) }.map(\.identityKey))
    }

    public static func readFile(_ path: String) -> FileContents {
        do { return .data(try Data(contentsOf: URL(fileURLWithPath: path))) }
        catch CocoaError.fileReadNoSuchFile { return .missing }
        catch { return .unavailable }
    }

    /// Returns only new appearances, including a reinstall after removal.
    public mutating func check(sources: [PermissionBrokerSource]) -> [PermissionBrokerFinding] {
        var found: Set<PermissionBrokerFinding> = []
        for source in sources {
            let findings: [PermissionBrokerFinding]?
            switch read(source.path) {
            case .missing: findings = []
            case .unavailable: findings = nil
            case .data(let data): findings = PermissionBrokerScan.inspect(data, source: source)
            }
            let previous = current.filter { $0.agent == source.agent && $0.path == source.path }
            let key = source.identityKey
            if let findings {
                found.formUnion(findings)
                if findings.isEmpty {
                    if pendingDisappearances.remove(key) != nil {
                        dismissedKeys.remove(key)
                    } else if !previous.isEmpty || dismissedKeys.contains(key) {
                        found.formUnion(previous)
                        pendingDisappearances.insert(key)
                    }
                } else {
                    pendingDisappearances.remove(key)
                }
            } else {
                found.formUnion(previous)
                pendingDisappearances.remove(key)
            }
        }
        pendingDisappearances.formIntersection(sources.map(\.identityKey))
        let appeared = found.subtracting(current).filter { !dismissedKeys.contains($0.identityKey) }
        current = found
        // Removal and reinstall while Rocky is closed cannot be distinguished
        // from continuous presence, so an existing dismissal remains in effect.
        return appeared.sorted { ($0.agent, $0.path) < ($1.agent, $1.path) }
    }
}
