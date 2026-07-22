import XCTest
@testable import RockyCore

final class ClaudeSettingsMergerTests: XCTestCase {
    let binary = "/Applications/Vibenotch.app/Contents/MacOS/rocky-hook"

    func parse(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testMergeIntoEmpty() throws {
        let out = try ClaudeSettingsMerger.merge(settings: nil, hookBinaryPath: binary)
        let root = try parse(out)
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        for event in ["SessionStart", "SessionEnd", "UserPromptSubmit", "Stop", "Notification", "PermissionRequest"] {
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

    func testCodexEventsAndAgentArgument() throws {
        let out = try ClaudeSettingsMerger.merge(
            settings: nil,
            hookBinaryPath: binary,
            events: ClaudeSettingsMerger.codexEvents,
            commandArguments: "--agent codex"
        )
        let hooks = try XCTUnwrap(try parse(out)["hooks"] as? [String: Any])
        XCTAssertNil(hooks["SessionEnd"])
        XCTAssertNil(hooks["Notification"])
        XCTAssertNotNil(hooks["UserPromptSubmit"])
        let pr = try XCTUnwrap((hooks["PermissionRequest"] as? [[String: Any]])?.first)
        let hook = try XCTUnwrap((pr["hooks"] as? [[String: Any]])?.first)
        XCTAssertEqual(hook["command"] as? String, "\(binary) --agent codex")
        XCTAssertTrue(ClaudeSettingsMerger.isInstalled(settings: out))
    }

    func testIsCurrentDetectsMissingEventOrStalePath() throws {
        let out = try ClaudeSettingsMerger.merge(settings: nil, hookBinaryPath: binary)
        XCTAssertTrue(ClaudeSettingsMerger.isCurrent(
            settings: out, hookBinaryPath: binary, events: ClaudeSettingsMerger.claudeEvents
        ))
        XCTAssertFalse(ClaudeSettingsMerger.isCurrent(
            settings: out, hookBinaryPath: "/moved/rocky-hook",
            events: ClaudeSettingsMerger.claudeEvents
        ))
        // Config antiga sem UserPromptSubmit não é current.
        let old = try ClaudeSettingsMerger.merge(
            settings: nil, hookBinaryPath: binary,
            events: [("Stop", false), ("PermissionRequest", true)]
        )
        XCTAssertFalse(ClaudeSettingsMerger.isCurrent(
            settings: old, hookBinaryPath: binary, events: ClaudeSettingsMerger.claudeEvents
        ))
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
        let spacedBinary = "/Applications/My Apps/Vibenotch.app/Contents/MacOS/rocky-hook"
        let out = try ClaudeSettingsMerger.merge(settings: nil, hookBinaryPath: spacedBinary)
        let hooks = try XCTUnwrap(try parse(out)["hooks"] as? [String: Any])
        let group = try XCTUnwrap((hooks["Stop"] as? [[String: Any]])?.first)
        let hook = try XCTUnwrap((group["hooks"] as? [[String: Any]])?.first)
        XCTAssertEqual(hook["command"] as? String, "\"\(spacedBinary)\"")
    }

    func testGrokEventsUsePreToolUse() throws {
        let out = try ClaudeSettingsMerger.merge(
            settings: nil,
            hookBinaryPath: binary,
            events: ClaudeSettingsMerger.grokEvents,
            commandArguments: "--agent grok"
        )
        let hooks = try XCTUnwrap(try parse(out)["hooks"] as? [String: Any])
        XCTAssertNil(hooks["PermissionRequest"])
        let pre = try XCTUnwrap((hooks["PreToolUse"] as? [[String: Any]])?.first)
        let hook = try XCTUnwrap((pre["hooks"] as? [[String: Any]])?.first)
        XCTAssertEqual(hook["command"] as? String, "\(binary) --agent grok")
        XCTAssertEqual(hook["timeout"] as? Int, 60)
        XCTAssertTrue(ClaudeSettingsMerger.isInstalled(settings: out))
        XCTAssertTrue(ClaudeSettingsMerger.isCurrent(
            settings: out, hookBinaryPath: binary, events: ClaudeSettingsMerger.grokEvents,
            commandArguments: "--agent grok"
        ))
    }

    /// An install written before `--agent` was passed keeps the right binary
    /// but the wrong command, so it must read as stale and get re-merged.
    func testIsCurrentDetectsMissingAgentArgument() throws {
        let legacy = try ClaudeSettingsMerger.merge(
            settings: nil,
            hookBinaryPath: binary,
            events: ClaudeSettingsMerger.claudeEvents
        )
        XCTAssertFalse(ClaudeSettingsMerger.isCurrent(
            settings: legacy, hookBinaryPath: binary,
            events: ClaudeSettingsMerger.claudeEvents,
            commandArguments: "--agent claude-code"
        ))

        let healed = try ClaudeSettingsMerger.merge(
            settings: legacy,
            hookBinaryPath: binary,
            events: ClaudeSettingsMerger.claudeEvents,
            commandArguments: "--agent claude-code"
        )
        XCTAssertTrue(ClaudeSettingsMerger.isCurrent(
            settings: healed, hookBinaryPath: binary,
            events: ClaudeSettingsMerger.claudeEvents,
            commandArguments: "--agent claude-code"
        ))
        // Re-merging must not leave the stale entry behind.
        let groups = try XCTUnwrap(
            (try parse(healed)["hooks"] as? [String: Any])?["PermissionRequest"]
                as? [[String: Any]]
        )
        XCTAssertEqual(groups.count, 1)
    }
}
