import Foundation

public struct ClaudeUsageWindow: Equatable, Codable, Sendable {
    public var usedPercentage: Double
    public var resetsAt: Date?

    public init(usedPercentage: Double, resetsAt: Date?) {
        self.usedPercentage = usedPercentage
        self.resetsAt = resetsAt
    }

    public var roundedUsedPercentage: Int {
        Int(usedPercentage.rounded())
    }
}

public struct ClaudeUsageSnapshot: Equatable, Codable, Sendable {
    public var fiveHour: ClaudeUsageWindow?
    public var sevenDay: ClaudeUsageWindow?
    public var cachedAt: Date?

    public init(
        fiveHour: ClaudeUsageWindow?,
        sevenDay: ClaudeUsageWindow?,
        cachedAt: Date? = nil
    ) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.cachedAt = cachedAt
    }

    public var isEmpty: Bool {
        fiveHour == nil && sevenDay == nil
    }
}

/// Reads Claude account rate-limit cache written by a statusLine bridge script.
public enum ClaudeUsageLoader {
    /// Rocky's own cache path.
    public static let defaultCacheURL = URL(fileURLWithPath: "/tmp/rocky-rl.json")
    /// Read Open Island / Vibe Island caches if the user already has them.
    public static let openIslandCacheURL = URL(fileURLWithPath: "/tmp/open-island-rl.json")
    public static let vibeIslandCacheURL = URL(fileURLWithPath: "/tmp/vibe-island-rl.json")

    public static var candidateURLs: [URL] {
        [defaultCacheURL, openIslandCacheURL, vibeIslandCacheURL]
    }

    public static func load() -> ClaudeUsageSnapshot? {
        load(from: candidateURLs)
    }

    public static func load(from urls: [URL]) -> ClaudeUsageSnapshot? {
        let ranked = urls
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map { url -> (URL, Date) in
                let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                let mod = attrs?[.modificationDate] as? Date ?? .distantPast
                return (url, mod)
            }
            .sorted { $0.1 > $1.1 }

        for (url, _) in ranked {
            if let snap = load(from: url) { return snap }
        }
        return nil
    }

    public static func load(from url: URL) -> ClaudeUsageSnapshot? {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data),
              let payload = object as? [String: Any]
        else { return nil }

        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let cachedAt = attrs?[.modificationDate] as? Date

        // Status line scripts often write just the rate_limits object:
        // { "five_hour": {...}, "seven_day": {...} }
        // or nested under rate_limits.
        let root: [String: Any]
        if let nested = payload["rate_limits"] as? [String: Any] {
            root = nested
        } else {
            root = payload
        }

        let snap = ClaudeUsageSnapshot(
            fiveHour: usageWindow(for: "five_hour", in: root)
                ?? usageWindow(for: "fiveHour", in: root),
            sevenDay: usageWindow(for: "seven_day", in: root)
                ?? usageWindow(for: "sevenDay", in: root),
            cachedAt: cachedAt
        )
        return snap.isEmpty ? nil : snap
    }

    private static func usageWindow(for key: String, in payload: [String: Any]) -> ClaudeUsageWindow? {
        guard let window = payload[key] as? [String: Any],
              let raw = number(from: window["used_percentage"])
                ?? number(from: window["utilization"])
                ?? number(from: window["usedPercentage"])
        else { return nil }
        return ClaudeUsageWindow(
            usedPercentage: raw,
            resetsAt: date(from: window["resets_at"] ?? window["resetsAt"])
        )
    }

    private static func number(from value: Any?) -> Double? {
        switch value {
        case let n as NSNumber: n.doubleValue
        case let s as String: Double(s)
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
            let frac = ISO8601DateFormatter()
            frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = frac.date(from: s) { return d }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            return plain.date(from: s)
        default:
            return nil
        }
    }
}
