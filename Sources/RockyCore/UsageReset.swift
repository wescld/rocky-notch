import Foundation

/// Human-facing "resets …" description for an account rate-limit window.
///
/// Near-term resets read relatively ("in 56 min", "in 4h 11m"); a reset within
/// the next week reads as a weekday ("Sun 12:00 AM"); anything further out reads
/// as a date ("Aug 3, 4:12 PM"). Time-of-day follows the locale's 12h/24h clock.
public enum UsageReset {
    private static let week: TimeInterval = 7 * 24 * 3600

    /// Returns the reset phrase (without a leading "resets"), or `nil` when the
    /// reset is already in the past — a stale timestamp is not worth showing.
    public static func describe(
        _ date: Date,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String? {
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return nil }

        let totalMinutes = Int(seconds / 60)
        if totalMinutes < 60 {
            return "in \(max(1, totalMinutes)) min"
        }
        if seconds < 24 * 3600 {
            let hours = totalMinutes / 60
            let minutes = totalMinutes % 60
            return minutes > 0 ? "in \(hours)h \(minutes)m" : "in \(hours)h"
        }

        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        // `j` picks the locale's preferred hour cycle (12h vs 24h) automatically.
        formatter.setLocalizedDateFormatFromTemplate(seconds < week ? "EEE jmm" : "MMMd jmm")
        return formatter.string(from: date)
    }
}
