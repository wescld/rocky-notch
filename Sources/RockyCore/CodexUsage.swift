import Foundation

/// One Codex account rate-limit window (primary ≈ short, secondary ≈ weekly).
public struct CodexUsageWindow: Equatable, Codable, Sendable {
    public var key: String
    public var label: String
    public var usedPercentage: Double
    public var windowMinutes: Int
    public var resetsAt: Date?

    public init(
        key: String,
        label: String,
        usedPercentage: Double,
        windowMinutes: Int,
        resetsAt: Date?
    ) {
        self.key = key
        self.label = label
        self.usedPercentage = usedPercentage
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
    }

    public var roundedUsedPercentage: Int {
        Int(usedPercentage.rounded())
    }
}

/// Latest usable Codex rate-limit snapshot found in local rollout logs.
public struct CodexUsageSnapshot: Equatable, Codable, Sendable {
    public var windows: [CodexUsageWindow]
    public var planType: String?
    public var limitID: String?
    public var capturedAt: Date?
    public var sourcePath: String?

    public init(
        windows: [CodexUsageWindow],
        planType: String? = nil,
        limitID: String? = nil,
        capturedAt: Date? = nil,
        sourcePath: String? = nil
    ) {
        self.windows = windows
        self.planType = planType
        self.limitID = limitID
        self.capturedAt = capturedAt
        self.sourcePath = sourcePath
    }

    public var isEmpty: Bool { windows.isEmpty }

    /// Short window first (Codex emits primary then secondary).
    public var primary: CodexUsageWindow? { windows.first }
}

/// Reads Codex account rate limits from local `rollout-*.jsonl` session files.
///
/// Codex writes `event_msg` / `token_count` lines that include `rate_limits`.
/// No network and no hooks — pure filesystem read under `~/.codex` (or `$CODEX_HOME`).
public enum CodexUsageLoader {
    /// Default sessions tree: `~/.codex/sessions`.
    public static var defaultSessionsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    /// How far back to consider rollout files (seconds).
    /// 7 days: account windows are weekly on Plus, and users may not run Codex daily.
    public static let defaultMaxAge: TimeInterval = 7 * 86_400
    /// Cap on candidate files (newest first).
    public static let defaultMaxFiles = 60
    /// Only scan the tail of large rollouts (bytes).
    public static let defaultTailBytes: UInt64 = 1_024_000

    /// Resolve `…/sessions` under a Codex home directory (`$CODEX_HOME`).
    public static func sessionsRoot(codexHome: URL) -> URL {
        codexHome.appendingPathComponent("sessions", isDirectory: true)
    }

    /// Discover a usable sessions root. Prefers `$CODEX_HOME/sessions`, then
    /// `~/.codex/sessions`. Returns nil when nothing exists.
    public static func discoverSessionsRoot(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        if let raw = environment["CODEX_HOME"], !raw.isEmpty {
            let root = sessionsRoot(codexHome: URL(fileURLWithPath: raw, isDirectory: true))
            if fileManager.fileExists(atPath: root.path) { return root }
        }
        let fallback = defaultSessionsRoot
        if fileManager.fileExists(atPath: fallback.path) { return fallback }
        return nil
    }

    public static func load(
        fileManager: FileManager = .default,
        now: Date = Date(),
        maxAge: TimeInterval = defaultMaxAge,
        maxFiles: Int = defaultMaxFiles,
        tailBytes: UInt64 = defaultTailBytes
    ) -> CodexUsageSnapshot? {
        guard let root = discoverSessionsRoot(fileManager: fileManager) else {
            return nil
        }
        return load(
            fromRoot: root,
            fileManager: fileManager,
            now: now,
            maxAge: maxAge,
            maxFiles: maxFiles,
            tailBytes: tailBytes
        )
    }

    /// Load from an explicit sessions root (tests inject a temp tree).
    public static func load(
        fromRoot root: URL,
        fileManager: FileManager = .default,
        now: Date = Date(),
        maxAge: TimeInterval = defaultMaxAge,
        maxFiles: Int = defaultMaxFiles,
        tailBytes: UInt64 = defaultTailBytes
    ) -> CodexUsageSnapshot? {
        let candidates = recentRollouts(
            under: root,
            fileManager: fileManager,
            now: now,
            maxAge: maxAge,
            maxFiles: maxFiles
        )
        for file in candidates {
            if let snap = parseLatestRateLimits(
                in: file.url,
                modifiedAt: file.modifiedAt,
                tailBytes: tailBytes
            ) {
                return snap
            }
        }
        return nil
    }

    // MARK: - Discovery (bounded)

    private struct RolloutFile {
        var url: URL
        var modifiedAt: Date
    }

    private static func recentRollouts(
        under root: URL,
        fileManager: FileManager,
        now: Date,
        maxAge: TimeInterval,
        maxFiles: Int
    ) -> [RolloutFile] {
        guard fileManager.fileExists(atPath: root.path),
              let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
              )
        else { return [] }

        let cutoff = now.addingTimeInterval(-maxAge)
        var found: [RolloutFile] = []

        for case let fileURL as URL in enumerator {
            let name = fileURL.lastPathComponent
            guard name.hasPrefix("rollout-"),
                  fileURL.pathExtension == "jsonl"
            else { continue }

            guard let values = try? fileURL.resourceValues(
                forKeys: [.contentModificationDateKey, .isRegularFileKey]
            ),
                  values.isRegularFile == true
            else { continue }

            let modified = values.contentModificationDate ?? .distantPast
            guard modified >= cutoff else { continue }

            found.append(RolloutFile(url: fileURL, modifiedAt: modified))
        }

        found.sort { lhs, rhs in
            if lhs.modifiedAt != rhs.modifiedAt {
                return lhs.modifiedAt > rhs.modifiedAt
            }
            return lhs.url.path > rhs.url.path
        }
        if found.count > maxFiles {
            found = Array(found.prefix(maxFiles))
        }
        return found
    }

    // MARK: - Parsing

    private static func parseLatestRateLimits(
        in fileURL: URL,
        modifiedAt: Date,
        tailBytes: UInt64
    ) -> CodexUsageSnapshot? {
        guard let text = tailText(of: fileURL, maxBytes: tailBytes) else {
            return nil
        }

        var latest: CodexUsageSnapshot?
        text.enumerateLines { line, _ in
            if let snap = snapshot(fromLine: line, sourcePath: fileURL.path, fallbackDate: modifiedAt) {
                latest = snap
            }
        }
        return latest
    }

    /// Read at most `maxBytes` from the end of the file so large rollouts stay cheap.
    private static func tailText(of fileURL: URL, maxBytes: UInt64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return nil
        }
        defer { try? handle.close() }

        let size: UInt64
        do {
            size = try handle.seekToEnd()
        } catch {
            return nil
        }
        guard size > 0 else { return nil }

        let offset: UInt64 = size > maxBytes ? size - maxBytes : 0
        do {
            try handle.seek(toOffset: offset)
        } catch {
            return nil
        }
        guard let data = try? handle.readToEnd(), !data.isEmpty else {
            return nil
        }
        guard var text = String(data: data, encoding: .utf8) else {
            return nil
        }
        // Tail may start mid-line — drop the partial first line.
        if offset > 0, let nl = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: nl)...])
        }
        return text
    }

    /// Parse one JSONL line into a snapshot when it carries rate_limits.
    static func snapshot(
        fromLine line: String,
        sourcePath: String,
        fallbackDate: Date
    ) -> CodexUsageSnapshot? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any]
        else { return nil }

        // Codex rollout: { "type": "event_msg", "payload": { "type": "token_count", "rate_limits": … } }
        guard root["type"] as? String == "event_msg" else { return nil }
        let payload = root["payload"] as? [String: Any] ?? [:]
        guard payload["type"] as? String == "token_count",
              let rateLimits = payload["rate_limits"] as? [String: Any]
        else { return nil }

        let windows = ["primary", "secondary"].compactMap { key in
            usageWindow(key: key, in: rateLimits)
        }
        guard !windows.isEmpty else { return nil }

        return CodexUsageSnapshot(
            windows: windows,
            planType: stringValue(rateLimits["plan_type"]),
            limitID: stringValue(rateLimits["limit_id"]),
            capturedAt: timestamp(from: root["timestamp"]) ?? fallbackDate,
            sourcePath: sourcePath
        )
    }

    private static func usageWindow(key: String, in rateLimits: [String: Any]) -> CodexUsageWindow? {
        guard let body = rateLimits[key] as? [String: Any],
              let used = number(from: body["used_percent"] ?? body["used_percentage"]),
              let minutes = integer(from: body["window_minutes"])
        else { return nil }

        return CodexUsageWindow(
            key: key,
            label: windowLabel(minutes: minutes),
            usedPercentage: used,
            windowMinutes: minutes,
            resetsAt: date(from: body["resets_at"] ?? body["resetsAt"])
        )
    }

    /// Compact human label for notch / settings (e.g. `5h`, `7d`, `1h 30m`).
    public static func windowLabel(minutes: Int) -> String {
        let days = minutes / 1_440
        let afterDays = minutes % 1_440
        let hours = afterDays / 60
        let mins = afterDays % 60

        if days > 0, hours == 0, mins == 0 { return "\(days)d" }
        if days > 0, hours > 0 { return "\(days)d \(hours)h" }
        if hours > 0, mins == 0 { return "\(hours)h" }
        if hours > 0 { return "\(hours)h \(mins)m" }
        return "\(minutes)m"
    }

    // MARK: - JSON helpers (same spirit as ClaudeUsageLoader)

    private static func number(from value: Any?) -> Double? {
        switch value {
        case let n as NSNumber: n.doubleValue
        case let s as String: Double(s)
        default: nil
        }
    }

    private static func integer(from value: Any?) -> Int? {
        switch value {
        case let n as NSNumber: n.intValue
        case let s as String: Int(s)
        default: nil
        }
    }

    private static func date(from value: Any?) -> Date? {
        switch value {
        case let n as NSNumber:
            return Date(timeIntervalSince1970: n.doubleValue)
        case let s as String:
            if let seconds = Double(s) {
                return Date(timeIntervalSince1970: seconds)
            }
            return timestamp(from: s)
        default:
            return nil
        }
    }

    private static func timestamp(from value: Any?) -> Date? {
        guard let s = value as? String else { return nil }
        let frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = frac.date(from: s) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: s)
    }

    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let s as String:
            return s.isEmpty ? nil : s
        case let n as NSNumber:
            return n.stringValue
        default:
            return nil
        }
    }
}
