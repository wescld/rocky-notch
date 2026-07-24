import XCTest
@testable import RockyCore

final class ClaudeUsageTests: XCTestCase {
    func testLoadFiveAndSevenHourWindows() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rocky-usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("rl.json")
        let json = """
        {
          "five_hour": { "used_percentage": 42.4, "resets_at": 1700000000 },
          "seven_day": { "used_percentage": 18.1 }
        }
        """
        try Data(json.utf8).write(to: url)

        let snap = try XCTUnwrap(ClaudeUsageLoader.load(from: url))
        XCTAssertEqual(snap.fiveHour?.roundedUsedPercentage, 42)
        XCTAssertEqual(snap.sevenDay?.roundedUsedPercentage, 18)
        XCTAssertNotNil(snap.fiveHour?.resetsAt)
    }

    func testNestedRateLimitsKey() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rocky-usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("rl.json")
        try Data(#"{"rate_limits":{"five_hour":{"utilization":55}}}"#.utf8).write(to: url)
        let snap = try XCTUnwrap(ClaudeUsageLoader.load(from: url))
        XCTAssertEqual(snap.fiveHour?.roundedUsedPercentage, 55)
    }

    func testMissingFileReturnsNil() {
        XCTAssertNil(ClaudeUsageLoader.load(from: URL(fileURLWithPath: "/tmp/no-such-rocky-rl.json")))
    }

    func testManagedScriptContainsCachePath() {
        let script = ClaudeStatusLineInstaller.managedScript(cachePath: "/tmp/rocky-rl.json")
        XCTAssertTrue(script.contains("rate_limits"))
        XCTAssertTrue(script.contains("/tmp/rocky-rl.json"))
        XCTAssertTrue(script.hasPrefix("#!/bin/bash"))
    }
}
