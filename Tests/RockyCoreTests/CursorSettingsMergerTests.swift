import XCTest
@testable import RockyCore

final class CursorSettingsMergerTests: XCTestCase {
    let binary = "/Applications/Rocky.app/Contents/MacOS/rocky-hook"

    func parse(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testMergeIntoEmptyUsesFlatSchema() throws {
        let out = try CursorSettingsMerger.merge(settings: nil, hookBinaryPath: binary)
        let root = try parse(out)
        XCTAssertEqual(root["version"] as? Int, 1)
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        for event in ["sessionStart", "sessionEnd", "beforeSubmitPrompt", "stop", "preToolUse"] {
            let entries = try XCTUnwrap(hooks[event] as? [[String: Any]], event)
            XCTAssertEqual(entries.count, 1, event)
            // Flat — no nested "hooks" group.
            XCTAssertNil(entries[0]["hooks"])
            XCTAssertEqual(
                entries[0]["command"] as? String,
                "\(binary) --agent cursor",
                event
            )
        }
        let pre = try XCTUnwrap((hooks["preToolUse"] as? [[String: Any]])?.first)
        XCTAssertEqual(pre["timeout"] as? Int, 60)
        XCTAssertTrue(CursorSettingsMerger.isInstalled(settings: out))
    }

    func testMergePreservesForeignHooksAndVersion() throws {
        let existing = """
        {
          "version": 1,
          "hooks": {
            "afterFileEdit": [
              {"command": "./hooks/format.sh"}
            ],
            "preToolUse": [
              {"command": "/usr/local/bin/other-tool", "matcher": "Shell"}
            ]
          }
        }
        """
        let out = try CursorSettingsMerger.merge(
            settings: Data(existing.utf8), hookBinaryPath: binary
        )
        let root = try parse(out)
        XCTAssertEqual(root["version"] as? Int, 1)
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        XCTAssertEqual((hooks["afterFileEdit"] as? [[String: Any]])?.count, 1)
        // Foreign preToolUse kept; ours appended.
        XCTAssertEqual((hooks["preToolUse"] as? [[String: Any]])?.count, 2)
    }

    func testMergeIsIdempotent() throws {
        let once = try CursorSettingsMerger.merge(settings: nil, hookBinaryPath: binary)
        let twice = try CursorSettingsMerger.merge(settings: once, hookBinaryPath: binary)
        let hooks = try XCTUnwrap(try parse(twice)["hooks"] as? [String: Any])
        XCTAssertEqual((hooks["preToolUse"] as? [[String: Any]])?.count, 1)
    }

    func testUnmergeRemovesOnlyOurs() throws {
        let existing = """
        {"version":1,"hooks":{"stop":[{"command":"/bin/other"}]}}
        """
        let merged = try CursorSettingsMerger.merge(
            settings: Data(existing.utf8), hookBinaryPath: binary
        )
        let cleaned = try CursorSettingsMerger.unmerge(settings: merged)
        let hooks = try XCTUnwrap(try parse(cleaned)["hooks"] as? [String: Any])
        XCTAssertEqual((hooks["stop"] as? [[String: Any]])?.count, 1)
        XCTAssertNil(hooks["preToolUse"])
        XCTAssertFalse(CursorSettingsMerger.isInstalled(settings: cleaned))
    }

    func testIsCurrentDetectsStalePath() throws {
        let out = try CursorSettingsMerger.merge(settings: nil, hookBinaryPath: binary)
        XCTAssertTrue(CursorSettingsMerger.isCurrent(
            settings: out, hookBinaryPath: binary
        ))
        XCTAssertFalse(CursorSettingsMerger.isCurrent(
            settings: out, hookBinaryPath: "/moved/rocky-hook"
        ))
    }
}
