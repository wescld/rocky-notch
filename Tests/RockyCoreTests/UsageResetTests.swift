import XCTest
@testable import RockyCore

final class UsageResetTests: XCTestCase {
    private let enUS = Locale(identifier: "en_US")

    private func utcCalendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private func utcDate(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour, c.minute) = (y, mo, d, h, mi)
        return utcCalendar().date(from: c)!
    }

    /// Anchor: Friday, 24 Jul 2026, 12:00 UTC.
    private var now: Date { utcDate(2026, 7, 24, 12, 0) }

    private func describe(_ reset: Date) -> String? {
        UsageReset.describe(reset, now: now, calendar: utcCalendar(), locale: enUS)
    }

    func testPastResetReturnsNil() {
        XCTAssertNil(describe(now.addingTimeInterval(-60)))
        XCTAssertNil(describe(now))
    }

    func testUnderOneMinuteNeverShowsZero() {
        XCTAssertEqual(describe(now.addingTimeInterval(30)), "in 1 min")
    }

    func testMinutesRelative() {
        XCTAssertEqual(describe(now.addingTimeInterval(56 * 60)), "in 56 min")
        XCTAssertEqual(describe(now.addingTimeInterval(59 * 60)), "in 59 min")
    }

    func testHourBoundaryRollsToHours() {
        XCTAssertEqual(describe(now.addingTimeInterval(60 * 60)), "in 1h")
    }

    func testHoursRelative() {
        XCTAssertEqual(describe(now.addingTimeInterval(4 * 3600 + 11 * 60)), "in 4h 11m")
        XCTAssertEqual(describe(now.addingTimeInterval(5 * 3600)), "in 5h")
    }

    func testWithinAWeekReadsAsWeekday() {
        // +3 days is inside the week window → weekday + time, no month, no "in".
        let result = describe(now.addingTimeInterval(3 * 86400))
        let unwrapped = try? XCTUnwrap(result)
        guard let text = unwrapped else { return XCTFail("expected a description") }

        XCTAssertFalse(text.hasPrefix("in "))
        XCTAssertTrue(text.contains(":"), "expected a time component in \(text)")

        let weekday = DateFormatter()
        weekday.locale = enUS
        weekday.calendar = utcCalendar()
        weekday.timeZone = TimeZone(identifier: "UTC")!
        weekday.setLocalizedDateFormatFromTemplate("EEE")
        let expected = weekday.string(from: now.addingTimeInterval(3 * 86400))
        XCTAssertTrue(text.contains(expected), "expected weekday \(expected) in \(text)")
    }

    func testBeyondAWeekReadsAsDate() {
        // +10 days is past the week window → month + day.
        let result = describe(now.addingTimeInterval(10 * 86400))
        guard let text = result else { return XCTFail("expected a description") }

        let month = DateFormatter()
        month.locale = enUS
        month.calendar = utcCalendar()
        month.timeZone = TimeZone(identifier: "UTC")!
        month.setLocalizedDateFormatFromTemplate("MMM")
        let expected = month.string(from: now.addingTimeInterval(10 * 86400))
        XCTAssertTrue(text.contains(expected), "expected month \(expected) in \(text)")
    }

    func testTwelveHourLocaleShowsMeridiem() {
        // Noon UTC, en_US → 12h clock with AM/PM.
        let text = describe(now.addingTimeInterval(3 * 86400)) ?? ""
        XCTAssertTrue(text.contains("PM") || text.contains("AM"), "expected meridiem in \(text)")
    }

    func testTwentyFourHourLocaleOmitsMeridiem() {
        // de_DE uses a 24h clock — no AM/PM marker.
        let text = UsageReset.describe(
            now.addingTimeInterval(3 * 86400),
            now: now,
            calendar: utcCalendar(),
            locale: Locale(identifier: "de_DE")
        ) ?? ""
        XCTAssertFalse(text.contains("AM"))
        XCTAssertFalse(text.contains("PM"))
        XCTAssertTrue(text.contains(":"), "expected a time component in \(text)")
    }
}
