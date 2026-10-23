import XCTest
@testable import RockyCore

final class PermissionBrokerMonitorTests: XCTestCase {
    private let command = "'/Library/Application Support/GitKrakenCLI/gk' ai hook run --host claude-code --blocking"

    private func hook(_ command: String, event: String = "PermissionRequest") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["hooks": [event: [["hooks": [["type": "command", "command": command]]]]]])
    }

    func testTOMLTablesDottedKeysCommentsAndInlineTables() {
        let enabled = [
            "[plugins.\"gitkraken-hooks@gitkraken\"]\nenabled = true",
            "[ 'plugins' . 'gitkraken-hooks@gitkraken' ] # note\nenabled\t=\ttrue # enabled=false",
            "[plugins]\n'gitkraken-hooks@gitkraken'.enabled = true",
            "plugins.'gitkraken-hooks@gitkraken'.'enabled' = true",
            "[plugins]\n'gitkraken-hooks@gitkraken' = { enabled = true, note = 'enabled=false' }",
            "[plugins.\"gitkraken-hooks@gitkraken\"]\n# enabled = false\n[other]\nenabled=false",
        ]
        for text in enabled { XCTAssertTrue(HookHealthCheck.gitkrakenHooksPluginEnabled(in: text), text) }
        let disabled = [
            "# [plugins.\"gitkraken-hooks@gitkraken\"]\n# enabled=true",
            "note = '[plugins.\"gitkraken-hooks@gitkraken\"]'",
            "note = \"\"\"\n[plugins.'gitkraken-hooks@gitkraken']\nenabled = true\n\"\"\"",
            "[plugins.\"gitkraken-hooks@gitkraken\"]\nenabled=false # enabled=true",
            "[plugins.'gitkraken-hooks@gitkraken']\n'enabled' = false\n[other]\nenabled=true",
            "[plugins]\n'gitkraken-hooks@gitkraken' = { enabled = false }",
            "plugins.'gitkraken-hooks@gitkraken'.enabled = false",
            "[plugins.'other']\nenabled=true",
        ]
        for text in disabled { XCTAssertFalse(HookHealthCheck.gitkrakenHooksPluginEnabled(in: text), text) }
    }

    func testOnlyIdentifiedBlockingBrokersCount() throws {
        XCTAssertTrue(PermissionBrokerScan.isBlockingGitKraken(command))
        XCTAssertTrue(PermissionBrokerScan.isBlockingGitKraken("gk ai hook run --host codex --blocking=true"))
        for command in ["build --blocking", "echo gk ai hook run --blocking", "gk ai hook run --host claude-code", "echo 'gk ai hook run --blocking'"] {
            XCTAssertFalse(PermissionBrokerScan.isBlockingGitKraken(command), command)
        }
        let source = PermissionBrokerSource(agent: "claude-code", path: "/fixture/settings.json")
        XCTAssertEqual(PermissionBrokerScan.inspect(try hook(command), source: source)?.count, 1)
        XCTAssertEqual(PermissionBrokerScan.inspect(try hook(command, event: "PostToolUse"), source: source), [])
        XCTAssertEqual(PermissionBrokerScan.inspect(try hook("other --blocking"), source: source), [])
    }

    func testBlockingFlagMustBelongToTheSameCommandSegment() {
        for separator in [";", "&&", "||", "|", "\n"] {
            XCTAssertFalse(PermissionBrokerScan.isBlockingGitKraken("gk ai hook run --host claude-code \(separator) echo --blocking"))
            XCTAssertFalse(PermissionBrokerScan.isBlockingGitKraken("echo --blocking \(separator) gk ai hook run --host claude-code"))
        }
        XCTAssertFalse(PermissionBrokerScan.isBlockingGitKraken("echo 'gitkrakencli/gk ai hook run --blocking'"))
        XCTAssertTrue(PermissionBrokerScan.isBlockingGitKraken("echo ready; env MODE=test gk ai hook run --blocking"))
        XCTAssertTrue(PermissionBrokerScan.isBlockingGitKraken("gk ai hook run --blocking=true; echo done"))
        let legacy = "/Library/Application Support/GitKrakenCLI/gk ai hook run --host claude-code"
        XCTAssertTrue(PermissionBrokerScan.isBlockingGitKraken(legacy + " --blocking"))
        XCTAssertFalse(PermissionBrokerScan.isBlockingGitKraken(legacy + "; echo --blocking"))
        XCTAssertFalse(PermissionBrokerScan.isBlockingGitKraken("echo " + legacy + " --blocking"))
    }

    func testTruncateThenRestoreDoesNotAlertAgain() {
        let source = PermissionBrokerSource(agent: "codex", path: "/fixture/config.toml", format: .codexTOML)
        let enabled = "[plugins.'gitkraken-hooks@gitkraken']\nenabled=true"
        var text = enabled
        var monitor = PermissionBrokerMonitor(read: { _ in .data(Data(text.utf8)) })
        XCTAssertEqual(monitor.check(sources: [source]).count, 1)
        for truncated in ["", "# rewriting", "[plugins]"] {
            text = truncated
            XCTAssertTrue(monitor.check(sources: [source]).isEmpty)
            XCTAssertEqual(monitor.current.count, 1)
            XCTAssertTrue(monitor.needsConfirmation)
            text = enabled
            XCTAssertTrue(monitor.check(sources: [source]).isEmpty)
            XCTAssertFalse(monitor.needsConfirmation)
        }
    }

    func testDisabledHooksDoNotProduceBrokerWarnings() throws {
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: hook(command)) as? [String: Any])
        root["disableAllHooks"] = true
        let data = try JSONSerialization.data(withJSONObject: root)
        XCTAssertEqual(PermissionBrokerScan.inspect(data, source: .init(agent: "claude-code", path: "/fixture/settings.json")), [])
    }

    func testFlatNamedAndPluginFootprints() throws {
        let flat = try JSONSerialization.data(withJSONObject: ["hooks": ["beforeShellExecution": [["command": command]]]])
        let named = try JSONSerialization.data(withJSONObject: ["gitkraken": ["PreToolUse": [["hooks": [["command": command]]]]]])
        for data in [flat, named] {
            XCTAssertEqual(PermissionBrokerScan.inspect(data, source: .init(agent: "cursor", path: "/fixture/hooks.json"))?.count, 1)
        }
        for (agent, format) in [("claude-code", PermissionBrokerSource.Format.json), ("codex", .codexTOML)] {
            let text = format == .json ? #"{"enabledPlugins":{"gitkraken-hooks@gitkraken":true}}"#
                : "[plugins.'gitkraken-hooks@gitkraken']\nenabled=true"
            let found = PermissionBrokerScan.inspect(Data(text.utf8), source: .init(agent: agent, path: "/fixture/config", format: format))
            XCTAssertEqual(found?.first?.agent, agent)
            XCTAssertTrue(found?.first?.description.contains("/fixture/config") == true)
            XCTAssertTrue(found?.first?.description.contains("uninstall \(agent)") == true)
        }
        let disabled = Data(#"{"enabledPlugins":{"gitkraken-hooks@gitkraken":false}}"#.utf8)
        XCTAssertEqual(PermissionBrokerScan.inspect(disabled, source: .init(agent: "claude-code", path: "/fixture/settings.json")), [])
        let script = Data("spawn('gk', ['ai hook run', '--blocking'])".utf8)
        XCTAssertEqual(PermissionBrokerScan.inspect(script, source: .init(agent: "opencode", path: "/fixture/gk-hooks.js", format: .script))?.count, 1)
    }

    func testAppearanceConfirmedRemovalAndReappearanceWithInjectedReader() throws {
        let source = PermissionBrokerSource(agent: "claude-code", path: "/fixture/settings.json")
        var contents = PermissionBrokerMonitor.FileContents.missing
        var monitor = PermissionBrokerMonitor(read: { _ in contents })
        XCTAssertTrue(monitor.check(sources: [source]).isEmpty)
        contents = .data(try hook(command))
        XCTAssertEqual(monitor.check(sources: [source]).count, 1)
        XCTAssertTrue(monitor.check(sources: [source]).isEmpty)
        contents = .unavailable
        XCTAssertTrue(monitor.check(sources: [source]).isEmpty)
        XCTAssertEqual(monitor.current.count, 1)
        contents = .data(Data("{partial".utf8))
        XCTAssertTrue(monitor.check(sources: [source]).isEmpty)
        XCTAssertEqual(monitor.current.count, 1)
        contents = .missing
        XCTAssertTrue(monitor.check(sources: [source]).isEmpty)
        XCTAssertEqual(monitor.current.count, 1)
        XCTAssertTrue(monitor.needsConfirmation)
        XCTAssertTrue(monitor.check(sources: [source]).isEmpty)
        XCTAssertTrue(monitor.current.isEmpty)
        XCTAssertFalse(monitor.needsConfirmation)
        contents = .data(try hook(command))
        XCTAssertEqual(monitor.check(sources: [source]).count, 1)
    }

    func testOneAlertPerAgentAndFileEvenIfHookBecomesPlugin() throws {
        let source = PermissionBrokerSource(agent: "claude-code", path: "/fixture/settings.json")
        var data = try hook(command)
        var monitor = PermissionBrokerMonitor(read: { _ in .data(data) })
        XCTAssertEqual(monitor.check(sources: [source]).count, 1)
        data = Data(#"{"enabledPlugins":{"gitkraken-hooks@gitkraken":true}}"#.utf8)
        XCTAssertTrue(monitor.check(sources: [source]).isEmpty)
    }

    func testPartialTOMLDoesNotResetAppearance() {
        let source = PermissionBrokerSource(agent: "codex", path: "/fixture/config.toml", format: .codexTOML)
        var text = "[plugins.'gitkraken-hooks@gitkraken']\nenabled=true"
        var monitor = PermissionBrokerMonitor(read: { _ in .data(Data(text.utf8)) })
        XCTAssertEqual(monitor.check(sources: [source]).count, 1)
        text = "[plugins.'gitkraken-hooks@"
        XCTAssertTrue(monitor.check(sources: [source]).isEmpty)
        XCTAssertEqual(monitor.current.count, 1)
        text = "[plugins.'gitkraken-hooks@gitkraken']\nenabled=true"
        XCTAssertTrue(monitor.check(sources: [source]).isEmpty)
    }

    func testNonBlockingScriptIsNotACompetingBroker() {
        let source = PermissionBrokerSource(agent: "opencode", path: "/fixture/gk-hooks.js", format: .script)
        let nonblocking = #"spawn(EXECUTABLE, ["ai", "hook", "run", "--host", HOST]); child.unref()"#
        XCTAssertEqual(PermissionBrokerScan.inspect(Data(nonblocking.utf8), source: source), [])
        let blocking = #"spawn(EXECUTABLE, ["ai", "hook", "run", "--host", HOST, "--blocking"])"#
        XCTAssertEqual(PermissionBrokerScan.inspect(Data(blocking.utf8), source: source)?.count, 1)
    }

    func testConfigRootOverridesAndActualCopilotFootprint() {
        let sources = PermissionBrokerSource.defaults(home: "/fixture", environment: [
            "CLAUDE_CONFIG_DIR": "/custom/claude", "XDG_CONFIG_HOME": "/custom/config",
            "GROK_HOME": "/custom/grok", "PI_CODING_AGENT_DIR": "/custom/pi",
        ])
        for path in ["/fixture/.copilot/hooks/gitkraken-hooks.json", "/custom/claude/settings.json",
                     "/custom/config/opencode/plugins/gk-hooks.js", "/custom/grok/hooks/gitkraken-hooks.json",
                     "/custom/pi/extensions/gk-hooks.js"] {
            XCTAssertTrue(sources.contains { $0.path == path }, path)
        }
    }

    func testOneScanReturnsAllAppearancesAsOneDeduplicatedBatch() throws {
        let sources = [
            PermissionBrokerSource(agent: "claude-code", path: "/fixture/settings.json"),
            PermissionBrokerSource(agent: "codex", path: "/fixture/hooks.json"),
        ]
        let data = try hook(command)
        var monitor = PermissionBrokerMonitor(read: { _ in .data(data) })
        let batch = monitor.check(sources: sources)
        XCTAssertEqual(batch.count, 2)
        XCTAssertEqual(Set(batch.map(\.agent)), ["claude-code", "codex"])
        XCTAssertTrue(monitor.check(sources: sources).isEmpty)
    }

    func testDisappearanceConfirmationResetsOnUnreadableFiles() {
        let source = PermissionBrokerSource(agent: "codex", path: "/fixture/config.toml", format: .codexTOML)
        var contents = PermissionBrokerMonitor.FileContents.data(Data("[plugins.'gitkraken-hooks@gitkraken']\nenabled=true".utf8))
        var monitor = PermissionBrokerMonitor(read: { _ in contents })
        XCTAssertEqual(monitor.check(sources: [source]).count, 1)
        contents = .missing
        XCTAssertTrue(monitor.check(sources: [source]).isEmpty)
        XCTAssertTrue(monitor.needsConfirmation)
        contents = .unavailable
        XCTAssertTrue(monitor.check(sources: [source]).isEmpty)
        XCTAssertFalse(monitor.needsConfirmation)
        contents = .data(Data("[plugins.'gitkraken-hooks@gitkraken']\nenabled=false".utf8))
        XCTAssertTrue(monitor.check(sources: [source]).isEmpty)
        XCTAssertEqual(monitor.current.count, 1)
        XCTAssertTrue(monitor.needsConfirmation)
        XCTAssertTrue(monitor.check(sources: [source]).isEmpty)
        XCTAssertTrue(monitor.current.isEmpty)
        XCTAssertFalse(monitor.needsConfirmation)
    }

    func testDismissedFindingSurvivesRelaunchAndRemainsListed() throws {
        let source = PermissionBrokerSource(agent: "claude-code", path: "/fixture/settings.json")
        let data = try hook(command)
        var contents = PermissionBrokerMonitor.FileContents.data(data)
        var monitor = PermissionBrokerMonitor(read: { _ in contents })
        let appeared = monitor.check(sources: [source])
        XCTAssertEqual(appeared.count, 1)
        monitor.dismiss(appeared)
        let savedKeys = Array(monitor.dismissedKeys).sorted()
        XCTAssertEqual(savedKeys, ["claude-code|/fixture/settings.json"])
        var relaunched = PermissionBrokerMonitor(dismissedKeys: Set(savedKeys), read: { _ in contents })
        XCTAssertTrue(relaunched.check(sources: [source]).isEmpty)
        XCTAssertEqual(relaunched.current.count, 1) // Settings must still list it.
        for unreadable in [PermissionBrokerMonitor.FileContents.unavailable, .data(Data("{partial".utf8))] {
            contents = unreadable
            XCTAssertTrue(relaunched.check(sources: [source]).isEmpty)
            XCTAssertEqual(relaunched.current.count, 1)
            XCTAssertEqual(relaunched.dismissedKeys, Set(savedKeys))
        }
        contents = .data(data)
        XCTAssertTrue(relaunched.check(sources: [source]).isEmpty)
    }

    func testDismissedFindingAlertsAgainOnlyAfterConfirmedRemoval() throws {
        let source = PermissionBrokerSource(agent: "claude-code", path: "/fixture/settings.json")
        let data = try hook(command)
        for relaunch in [false, true] {
            var contents = PermissionBrokerMonitor.FileContents.data(data)
            var monitor = PermissionBrokerMonitor(read: { _ in contents })
            let appeared = monitor.check(sources: [source])
            monitor.dismiss(appeared)
            XCTAssertEqual(monitor.dismissedKeys.count, 1)
            if relaunch {
                monitor = PermissionBrokerMonitor(dismissedKeys: monitor.dismissedKeys, read: { _ in contents })
            }
            contents = .missing
            XCTAssertTrue(monitor.check(sources: [source]).isEmpty)
            XCTAssertTrue(monitor.needsConfirmation)
            XCTAssertEqual(monitor.dismissedKeys.count, 1)
            XCTAssertTrue(monitor.check(sources: [source]).isEmpty)
            XCTAssertFalse(monitor.needsConfirmation)
            XCTAssertTrue(monitor.dismissedKeys.isEmpty)
            contents = .data(data)
            XCTAssertEqual(monitor.check(sources: [source]).count, 1)
        }
    }

    func testCommentedOpenCodeConfigIsScannedReadOnly() {
        let source = PermissionBrokerSource(agent: "opencode", path: "/fixture/opencode.jsonc")
        let config = """
        {
          // A user-declared blocking gate, not the auto-loaded bridge.
          "hooks": { "PermissionRequest": [{ "command": "gk ai hook run --blocking" }], },
        }
        """
        XCTAssertEqual(PermissionBrokerScan.inspect(Data(config.utf8), source: source)?.count, 1)
        let referenceOnly = #"{"plugin":["file:///fixture/gk-hooks.js"] /* presence does not prove blocking */}"#
        XCTAssertEqual(PermissionBrokerScan.inspect(Data(referenceOnly.utf8), source: source), [])
    }

    func testAllGitKrakenHostsHaveBoundedCandidates() {
        let sources = PermissionBrokerSource.defaults(home: "/fixture", projects: ["/workspace"])
        XCTAssertEqual(Set(sources.map(\.agent)), ["claude-code", "codex", "opencode", "cursor", "antigravity", "copilot", "pi", "augment", "grok"])
        XCTAssertTrue(sources.contains { $0.path == "/workspace/.claude/settings.local.json" })
        XCTAssertTrue(sources.contains { $0.path == "/fixture/.claude/settings.json" })
        XCTAssertTrue(sources.contains { $0.path == "/fixture/.codex/config.toml" })
    }
}
