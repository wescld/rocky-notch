import XCTest
@testable import VibenotchCore

final class ClaudeSettingsMergerTests: XCTestCase {
    let binary = "/Applications/Vibenotch.app/Contents/MacOS/vibenotch-hook"

    func parse(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testMergeIntoEmpty() throws {
        let out = try ClaudeSettingsMerger.merge(settings: nil, hookBinaryPath: binary)
        let root = try parse(out)
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        for event in ["SessionStart", "SessionEnd", "Stop", "Notification", "PermissionRequest"] {
            let groups = try XCTUnwrap(hooks[event] as? [[String: Any]], event)
            XCTAssertEqual(groups.count, 1, event)
        }
        let pr = try XCTUnwrap((hooks["PermissionRequest"] as? [[String: Any]])?.first)
        let hook = try XCTUnwrap((pr["hooks"] as? [[String: Any]])?.first)
        XCTAssertEqual(hook["command"] as? String, binary)
        XCTAssertEqual(hook["timeout"] as? Int, 60)
        XCTAssertTrue(ClaudeSettingsMerger.isInstalled(settings: out))
    }

    func testMergePreservesForeignKeysAndHooks() throws {
        let existing = """
        {
          "model": "opus",
          "permissions": {"allow": ["Bash(ls:*)"]},
          "hooks": {
            "PreToolUse": [
              {"matcher": "Bash", "hooks": [{"type": "command", "command": "/usr/local/bin/other-tool"}]}
            ],
            "Stop": [
              {"hooks": [{"type": "command", "command": "/usr/local/bin/other-tool"}]}
            ]
          }
        }
        """
        let out = try ClaudeSettingsMerger.merge(
            settings: Data(existing.utf8), hookBinaryPath: binary
        )
        let root = try parse(out)
        XCTAssertEqual(root["model"] as? String, "opus")
        XCTAssertNotNil(root["permissions"])
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        // Foreign PreToolUse untouched.
        XCTAssertEqual((hooks["PreToolUse"] as? [[String: Any]])?.count, 1)
        // Stop has the foreign hook + ours.
        XCTAssertEqual((hooks["Stop"] as? [[String: Any]])?.count, 2)
    }

    func testMergeIsIdempotent() throws {
        let once = try ClaudeSettingsMerger.merge(settings: nil, hookBinaryPath: binary)
        let twice = try ClaudeSettingsMerger.merge(settings: once, hookBinaryPath: binary)
        let hooks = try XCTUnwrap(try parse(twice)["hooks"] as? [String: Any])
        XCTAssertEqual((hooks["PermissionRequest"] as? [[String: Any]])?.count, 1)
    }

    func testUnmergeRemovesOnlyOurs() throws {
        let existing = """
        {"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "/bin/other"}]}]}}
        """
        let merged = try ClaudeSettingsMerger.merge(
            settings: Data(existing.utf8), hookBinaryPath: binary
        )
        let cleaned = try ClaudeSettingsMerger.unmerge(settings: merged)
        let hooks = try XCTUnwrap(try parse(cleaned)["hooks"] as? [String: Any])
        XCTAssertEqual((hooks["Stop"] as? [[String: Any]])?.count, 1)
        XCTAssertNil(hooks["PermissionRequest"])
        XCTAssertFalse(ClaudeSettingsMerger.isInstalled(settings: cleaned))
    }

    func testInvalidJSONThrows() {
        XCTAssertThrowsError(
            try ClaudeSettingsMerger.merge(
                settings: Data("not json".utf8), hookBinaryPath: binary
            )
        )
        XCTAssertThrowsError(
            try ClaudeSettingsMerger.merge(
                settings: Data("[1,2]".utf8), hookBinaryPath: binary
            )
        )
    }

    func testPathWithSpacesIsQuoted() throws {
        let spacedBinary = "/Applications/My Apps/Vibenotch.app/Contents/MacOS/vibenotch-hook"
        let out = try ClaudeSettingsMerger.merge(settings: nil, hookBinaryPath: spacedBinary)
        let hooks = try XCTUnwrap(try parse(out)["hooks"] as? [String: Any])
        let group = try XCTUnwrap((hooks["Stop"] as? [[String: Any]])?.first)
        let hook = try XCTUnwrap((group["hooks"] as? [[String: Any]])?.first)
        XCTAssertEqual(hook["command"] as? String, "\"\(spacedBinary)\"")
    }
}
