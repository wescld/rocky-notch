import XCTest
@testable import RockyCore

final class VersionTests: XCTestCase {
    func testVersionIsSemver() {
        XCTAssertEqual(Rocky.version.split(separator: ".").count, 3)
    }
}
