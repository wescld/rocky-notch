import XCTest
@testable import VibenotchCore

final class VersionTests: XCTestCase {
    func testVersionIsSemver() {
        XCTAssertEqual(Vibenotch.version.split(separator: ".").count, 3)
    }
}
