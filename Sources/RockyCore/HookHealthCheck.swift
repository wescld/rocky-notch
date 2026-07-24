import Foundation

/// Diagnostic report for a single agent integration's hooks.
public struct HookHealthReport: Equatable, Sendable {
    public enum Severity: Equatable, Sendable {
        case error
        case info
    }

    public enum Issue: Equatable, Sendable, CustomStringConvertible {
        case binaryNotFound(path: String)
        case binaryNotExecutable(path: String)
        case configMissing(path: String)
        case configMalformed(path: String)
        case staleCommandPath(recorded: String, expected: String)
        case notInstalled
        case otherHooksDetected(count: Int)

        public var description: String {
            switch self {
            case .binaryNotFound(let path):
                "Hook binary not found: \(path)"
            case .binaryNotExecutable(let path):
                "Hook binary is not executable: \(path)"
            case .configMissing(let path):
                "Config file missing: \(path)"
            case .configMalformed(let path):
                "Config file is not valid JSON: \(path)"
            case .staleCommandPath(let recorded, let expected):
                "Hook path is stale (points to \(recorded), expected \(expected))"
            case .notInstalled:
                "Rocky hooks are not installed"
            case .otherHooksDetected(let count):
                "\(count) other hook command(s) coexist with Rocky"
            }
        }

        public var severity: Severity {
            switch self {
            case .otherHooksDetected, .notInstalled:
                .info
            default:
                .error
            }
        }

        public var isAutoRepairable: Bool {
            switch self {
            case .staleCommandPath, .binaryNotExecutable, .notInstalled:
                true
            default:
                false
            }
        }
    }

    public var agent: String
    public var displayName: String
    public var issues: [Issue]
    public var expectedBinaryPath: String
    public var configPath: String?

    public var isHealthy: Bool {
        issues.allSatisfy { $0.severity != .error }
    }

    public var errors: [Issue] { issues.filter { $0.severity == .error } }
    public var notices: [Issue] { issues.filter { $0.severity == .info } }

    public init(
        agent: String,
        displayName: String,
        issues: [Issue],
        expectedBinaryPath: String,
        configPath: String? = nil
    ) {
        self.agent = agent
        self.displayName = displayName
        self.issues = issues
        self.expectedBinaryPath = expectedBinaryPath
        self.configPath = configPath
    }
}

/// Pure diagnostics over hook install state. I/O is injected so tests stay pure.
public enum HookHealthCheck {
    /// Inspect a nested-groups style config (Claude/Codex/Grok) for Rocky health.
    public static func inspectNested(
        agent: String,
        displayName: String,
        expectedBinaryPath: String,
        configPath: String,
        configData: Data?,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        isExecutable: (String) -> Bool = {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    ) -> HookHealthReport {
        var issues: [HookHealthReport.Issue] = []

        if !fileExists(expectedBinaryPath) {
            issues.append(.binaryNotFound(path: expectedBinaryPath))
        } else if !isExecutable(expectedBinaryPath) {
            issues.append(.binaryNotExecutable(path: expectedBinaryPath))
        }

        guard let configData else {
            issues.append(.configMissing(path: configPath))
            issues.append(.notInstalled)
            return HookHealthReport(
                agent: agent,
                displayName: displayName,
                issues: issues,
                expectedBinaryPath: expectedBinaryPath,
                configPath: configPath
            )
        }

        guard let root = try? JSONSerialization.jsonObject(with: configData) as? [String: Any] else {
            issues.append(.configMalformed(path: configPath))
            return HookHealthReport(
                agent: agent,
                displayName: displayName,
                issues: issues,
                expectedBinaryPath: expectedBinaryPath,
                configPath: configPath
            )
        }

        let commands = collectCommands(from: root)
        let rockyCommands = commands.filter { $0.contains("rocky-hook") || $0.contains("Rocky") }
        let otherCount = commands.count - rockyCommands.count

        if rockyCommands.isEmpty {
            issues.append(.notInstalled)
        } else {
            // Stale if none of the Rocky commands point at the expected binary.
            let expectedQuoted = shellContains(path: expectedBinaryPath)
            let anyCurrent = rockyCommands.contains { cmd in
                cmd.contains(expectedBinaryPath) || expectedQuoted.map { cmd.contains($0) } == true
            }
            if !anyCurrent, let sample = rockyCommands.first {
                let recorded = extractBinaryPath(from: sample) ?? sample
                issues.append(.staleCommandPath(recorded: recorded, expected: expectedBinaryPath))
            }
        }

        if otherCount > 0 {
            issues.append(.otherHooksDetected(count: otherCount))
        }

        return HookHealthReport(
            agent: agent,
            displayName: displayName,
            issues: issues,
            expectedBinaryPath: expectedBinaryPath,
            configPath: configPath
        )
    }

    /// Cursor flat hooks.json shape.
    public static func inspectCursor(
        expectedBinaryPath: String,
        configPath: String,
        configData: Data?,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        isExecutable: (String) -> Bool = {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    ) -> HookHealthReport {
        inspectNested(
            agent: "cursor",
            displayName: "Cursor",
            expectedBinaryPath: expectedBinaryPath,
            configPath: configPath,
            configData: configData,
            fileExists: fileExists,
            isExecutable: isExecutable
        )
    }

    // MARK: - Helpers

    private static func collectCommands(from root: [String: Any]) -> [String] {
        var results: [String] = []
        walk(root, into: &results)
        return results
    }

    private static func walk(_ value: Any, into results: inout [String]) {
        if let dict = value as? [String: Any] {
            if let command = dict["command"] as? String {
                results.append(command)
            }
            for v in dict.values { walk(v, into: &results) }
        } else if let array = value as? [Any] {
            for v in array { walk(v, into: &results) }
        }
    }

    private static func shellContains(path: String) -> String? {
        // Common shell-quoted form: '/path with spaces/rocky-hook'
        path.contains(" ") ? "'\(path)'" : nil
    }

    private static func extractBinaryPath(from command: String) -> String? {
        // First token, strip surrounding quotes.
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("'"), let end = trimmed.dropFirst().firstIndex(of: "'") {
            return String(trimmed[trimmed.index(after: trimmed.startIndex)..<end])
        }
        if trimmed.hasPrefix("\""), let end = trimmed.dropFirst().firstIndex(of: "\"") {
            return String(trimmed[trimmed.index(after: trimmed.startIndex)..<end])
        }
        return trimmed.split(separator: " ").first.map(String.init)
    }
}
