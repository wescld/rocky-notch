import XCTest
@testable import RockyCore

final class AgySettingsMergerTests: XCTestCase {
    let binary = "/Applications/Rocky.app/Contents/MacOS/rocky-hook"

    func parse(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testMergeIntoEmptyWritesNamedRockyGroup() throws {
        let out = try AgySettingsMerger.merge(settings: nil, hookBinaryPath: binary)
        let root = try parse(out)
        let group = try XCTUnwrap(root["rocky-notch"] as? [String: Any])
        XCTAssertEqual(group["enabled"] as? Bool, true)

        let pre = try XCTUnwrap(group["PreToolUse"] as? [[String: Any]])
        XCTAssertEqual(pre.count, 1)
        XCTAssertEqual(pre[0]["matcher"] as? String, "*")
        let preHooks = try XCTUnwrap(pre[0]["hooks"] as? [[String: Any]])
        XCTAssertEqual(
            preHooks[0]["command"] as? String,
            "\(binary) --agent agy --event PreToolUse"
        )
        XCTAssertEqual(preHooks[0]["timeout"] as? Int, 60)

        let stop = try XCTUnwrap(group["Stop"] as? [[String: Any]])
        XCTAssertEqual(stop.count, 1)
        XCTAssertNil(stop[0]["hooks"])
        XCTAssertEqual(
            stop[0]["command"] as? String,
            "\(binary) --agent agy --event Stop"
        )
        XCTAssertEqual(stop[0]["timeout"] as? Int, 10)

        XCTAssertTrue(AgySettingsMerger.isInstalled(settings: out))
        XCTAssertTrue(AgySettingsMerger.isCurrent(settings: out, hookBinaryPath: binary))
    }

    func testMergePreservesForeignNamedHooks() throws {
        let existing = """
        {
          "lint-checker": {
            "PostToolUse": [
              { "matcher": "run_command", "hooks": [{ "command": "./lint.sh" }] }
            ]
          }
        }
        """
        let out = try AgySettingsMerger.merge(
            settings: Data(existing.utf8), hookBinaryPath: binary
        )
        let root = try parse(out)
        XCTAssertNotNil(root["lint-checker"])
        XCTAssertNotNil(root["rocky-notch"])
    }

    func testMergeIsIdempotent() throws {
        let first = try AgySettingsMerger.merge(settings: nil, hookBinaryPath: binary)
        let second = try AgySettingsMerger.merge(settings: first, hookBinaryPath: binary)
        let group = try XCTUnwrap(try parse(second)["rocky-notch"] as? [String: Any])
        let pre = try XCTUnwrap(group["PreToolUse"] as? [[String: Any]])
        XCTAssertEqual(pre.count, 1)
    }

    func testUnmergeRemovesOnlyRocky() throws {
        let existing = """
        {
          "lint-checker": {
            "PostToolUse": [
              { "matcher": "run_command", "hooks": [{ "command": "./lint.sh" }] }
            ]
          },
          "rocky-notch": {
            "PreToolUse": [
              { "matcher": "*", "hooks": [{ "command": "\(binary) --agent agy --event PreToolUse" }] }
            ]
          }
        }
        """
        let out = try AgySettingsMerger.unmerge(settings: Data(existing.utf8))
        let root = try parse(out)
        XCTAssertNil(root["rocky-notch"])
        XCTAssertNotNil(root["lint-checker"])
        XCTAssertFalse(AgySettingsMerger.isInstalled(settings: out))
    }

    func testStaleBinaryIsNotCurrent() throws {
        let out = try AgySettingsMerger.merge(
            settings: nil, hookBinaryPath: "/old/rocky-hook"
        )
        XCTAssertTrue(AgySettingsMerger.isInstalled(settings: out))
        XCTAssertFalse(AgySettingsMerger.isCurrent(settings: out, hookBinaryPath: binary))
    }

    func testUnparseableThrows() {
        XCTAssertThrowsError(
            try AgySettingsMerger.merge(settings: Data("[]".utf8), hookBinaryPath: binary)
        ) { error in
            XCTAssertEqual(error as? AgySettingsMerger.MergeError, .notAnObject)
        }
    }
}
