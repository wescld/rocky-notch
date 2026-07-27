import XCTest
@testable import RockyCore

final class UsageHeatTests: XCTestCase {
    func testSpentSessionIsHot() {
        XCTAssertTrue(UsageHeat.isHot([91, 12]))
    }

    /// The reading the notch used to miss entirely: the session has room, the
    /// week does not.
    func testSpentWeekIsHotEvenWhenTheSessionIsCalm() {
        XCTAssertTrue(UsageHeat.isHot([12, 91]))
    }

    func testBothWindowsCalmIsNotHot() {
        XCTAssertFalse(UsageHeat.isHot([12, 42]))
    }

    func testThresholdIsInclusive() {
        XCTAssertTrue(UsageHeat.isHot([UsageHeat.amberThreshold]))
        XCTAssertFalse(UsageHeat.isHot([UsageHeat.amberThreshold - 0.1]))
    }

    func testMissingWindowsAreSkippedNotReadAsZero() {
        XCTAssertTrue(UsageHeat.isHot([nil, 91]))
        XCTAssertFalse(UsageHeat.isHot([nil, 12]))
        XCTAssertFalse(UsageHeat.isHot([nil, nil]))
    }

    func testNoWindowsAtAllIsNotHot() {
        XCTAssertFalse(UsageHeat.isHot([]))
    }
}
