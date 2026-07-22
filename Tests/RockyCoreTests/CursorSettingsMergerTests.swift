import XCTest
@testable import RockyCore

final class CursorSettingsMergerTests: XCTestCase {
    let binary = "/Applications/Rocky.app/Contents/MacOS/rocky-hook"
    let official = [
        "beforeSubmitPrompt",
        "beforeShellExecution",
        "beforeMCPExecution",
        "beforeReadFile",
        "afterFileEdit",
        "stop",
    ]

    func parse(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testMergeIntoEmptyUsesOfficialCursorEvents() throws {
        let out = try CursorSettingsMerger.merge(settings: nil, hookBinaryPath: binary)
        let root = try parse(out)
        XCTAssertEqual(root["version"] as? Int, 1)
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        for event in official {
            let entries = try XCTUnwrap(hooks[event] as? [[String: Any]], event)
            XCTAssertEqual(entries.count, 1, event)
            XCTAssertNil(entries[0]["hooks"], event)
            XCTAssertEqual(
                entries[0]["command"] as? String,
                "\(binary) --agent cursor",
                event
            )
        }
        // Blocking channels get the long timeout.
        for event in ["beforeShellExecution", "beforeMCPExecution"] {
            let entry = try XCTUnwrap((hooks[event] as? [[String: Any]])?.first, event)
            XCTAssertEqual(entry["timeout"] as? Int, 60, event)
        }
        // No Grok-style / phantom events.
        for ghost in ["sessionStart", "sessionEnd", "preToolUse"] {
            XCTAssertNil(hooks[ghost], ghost)
        }
        XCTAssertTrue(CursorSettingsMerger.isInstalled(settings: out))
    }

    func testMergeStripsLegacyRockyEvents() throws {
        let existing = """
        {
          "version": 1,
          "hooks": {
            "sessionStart": [{"command": "\(binary) --agent cursor", "timeout": 10}],
            "preToolUse": [{"command": "\(binary) --agent cursor", "timeout": 60}],
            "afterFileEdit": [{"command": "./hooks/format.sh"}]
          }
        }
        """
        let out = try CursorSettingsMerger.merge(
            settings: Data(existing.utf8), hookBinaryPath: binary
        )
        let hooks = try XCTUnwrap(try parse(out)["hooks"] as? [String: Any])
        XCTAssertNil(hooks["sessionStart"])
        XCTAssertNil(hooks["preToolUse"])
        // Foreign afterFileEdit kept; ours appended.
        XCTAssertEqual((hooks["afterFileEdit"] as? [[String: Any]])?.count, 2)
    }

    func testMergePreservesForeignHooksAndVersion() throws {
        let existing = """
        {
          "version": 1,
          "hooks": {
            "afterFileEdit": [
              {"command": "./hooks/format.sh"}
            ],
            "beforeShellExecution": [
              {"command": "/usr/local/bin/other-tool"}
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
        XCTAssertEqual((hooks["afterFileEdit"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual((hooks["beforeShellExecution"] as? [[String: Any]])?.count, 2)
    }

    func testMergeIsIdempotent() throws {
        let once = try CursorSettingsMerger.merge(settings: nil, hookBinaryPath: binary)
        let twice = try CursorSettingsMerger.merge(settings: once, hookBinaryPath: binary)
        let hooks = try XCTUnwrap(try parse(twice)["hooks"] as? [String: Any])
        XCTAssertEqual((hooks["beforeShellExecution"] as? [[String: Any]])?.count, 1)
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
        XCTAssertNil(hooks["beforeShellExecution"])
        XCTAssertFalse(CursorSettingsMerger.isInstalled(settings: cleaned))
    }

    func testIsCurrentDetectsStalePathAndMissingAgentFlag() throws {
        let out = try CursorSettingsMerger.merge(settings: nil, hookBinaryPath: binary)
        XCTAssertTrue(CursorSettingsMerger.isCurrent(
            settings: out, hookBinaryPath: binary
        ))
        XCTAssertFalse(CursorSettingsMerger.isCurrent(
            settings: out, hookBinaryPath: "/moved/rocky-hook"
        ))
        // Full command must include --agent cursor.
        XCTAssertFalse(CursorSettingsMerger.isCurrent(
            settings: out,
            hookBinaryPath: binary,
            commandArguments: ""
        ))
    }
}
