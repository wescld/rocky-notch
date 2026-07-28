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

    func testPeakTakesTheWindowClosestToRunningOut() {
        XCTAssertEqual(UsageHeat.peak([12, 91]), 91)
        XCTAssertEqual(UsageHeat.peak([91, 12]), 91)
        XCTAssertEqual(UsageHeat.peak([nil, 42]), 42)
    }

    func testPeakOfNothingIsNil() {
        XCTAssertNil(UsageHeat.peak([nil, nil]))
        XCTAssertNil(UsageHeat.peak([]))
    }

    func testHotterAccountKeepsTheStrip() {
        XCTAssertTrue(UsageHeat.keepsFirst(91, over: 12))
        XCTAssertFalse(UsageHeat.keepsFirst(12, over: 91))
    }

    /// An account with nothing to report cannot win space it would leave empty.
    func testSilentAccountNeverKeepsTheStrip() {
        XCTAssertFalse(UsageHeat.keepsFirst(nil, over: 12))
        XCTAssertTrue(UsageHeat.keepsFirst(12, over: nil))
        XCTAssertTrue(UsageHeat.keepsFirst(nil, over: nil))
    }

    /// Ties hold still: a strip sitting on the width boundary must not swap its
    /// chip back and forth as the figures drift.
    func testTieKeepsTheFirstAccount() {
        XCTAssertTrue(UsageHeat.keepsFirst(50, over: 50))
    }
}
