import XCTest
@testable import RockyCore

final class HookHealthCheckTests: XCTestCase {
    let expected = "/Applications/Rocky.app/Contents/MacOS/rocky-hook"

    func testHealthyInstall() {
        let config = """
        {"hooks":{"SessionStart":[{"hooks":[{"command":"\(expected) --agent claude-code"}]}]}}
        """.data(using: .utf8)
        let report = HookHealthCheck.inspectNested(
            agent: "claude",
            displayName: "Claude Code",
            expectedBinaryPath: expected,
            configPath: "/tmp/settings.json",
            configData: config,
            fileExists: { $0 == expected },
            isExecutable: { $0 == expected }
        )
        XCTAssertTrue(report.isHealthy)
        XCTAssertTrue(report.issues.isEmpty)
    }

    func testStalePath() {
        let old = "/Old/Rocky.app/Contents/MacOS/rocky-hook"
        let config = """
        {"hooks":{"SessionStart":[{"hooks":[{"command":"\(old) --agent claude-code"}]}]}}
        """.data(using: .utf8)
        let report = HookHealthCheck.inspectNested(
            agent: "claude",
            displayName: "Claude Code",
            expectedBinaryPath: expected,
            configPath: "/tmp/settings.json",
            configData: config,
            fileExists: { $0 == expected },
            isExecutable: { $0 == expected }
        )
        XCTAssertFalse(report.isHealthy)
        XCTAssertTrue(report.errors.contains { if case .staleCommandPath = $0 { return true }; return false })
        XCTAssertTrue(report.errors.contains { $0.isAutoRepairable })
    }

    func testNotInstalled() {
        let config = #"{"hooks":{}}"#.data(using: .utf8)
        let report = HookHealthCheck.inspectNested(
            agent: "claude",
            displayName: "Claude Code",
            expectedBinaryPath: expected,
            configPath: "/tmp/settings.json",
            configData: config,
            fileExists: { $0 == expected },
            isExecutable: { $0 == expected }
        )
        XCTAssertTrue(report.issues.contains(.notInstalled))
    }

    func testCompetingPermissionBrokerInHooksJson() {
        let gk = "/Users/me/Library/Application Support/GitKrakenCLI/gk ai hook run --host claude-code --blocking"
        let config = """
        {"hooks":{"PermissionRequest":[
          {"hooks":[{"command":"\(expected) --agent codex"}]},
          {"hooks":[{"command":"\(gk)"}]}
        ]}}
        """.data(using: .utf8)
        let report = HookHealthCheck.inspectNested(
            agent: "codex",
            displayName: "Codex",
            expectedBinaryPath: expected,
            configPath: "/tmp/hooks.json",
            configData: config,
            fileExists: { $0 == expected },
            isExecutable: { $0 == expected }
        )
        XCTAssertFalse(report.isHealthy)
        XCTAssertTrue(report.errors.contains {
            if case .competingPermissionBroker(let name) = $0 { return name == "GitKraken" }
            return false
        })
    }

    func testGitkrakenPluginEnabledInCodexToml() {
        let on = """
        [plugins."gitkraken-hooks@gitkraken"]
        enabled = true
        """
        XCTAssertTrue(HookHealthCheck.gitkrakenHooksPluginEnabled(in: on))
        let off = """
        [plugins."gitkraken-hooks@gitkraken"]
        enabled = false
        """
        XCTAssertFalse(HookHealthCheck.gitkrakenHooksPluginEnabled(in: off))
        XCTAssertTrue(
            HookHealthCheck.inspectCodexPluginBrokers(configToml: on)
                .contains { if case .competingPermissionBroker(let n) = $0 { return n == "gitkraken-hooks" }; return false }
        )
        XCTAssertTrue(HookHealthCheck.inspectCodexPluginBrokers(configToml: off).isEmpty)
    }

    func testBinaryMissing() {
        let report = HookHealthCheck.inspectNested(
            agent: "claude",
            displayName: "Claude Code",
            expectedBinaryPath: expected,
            configPath: "/tmp/settings.json",
            configData: nil,
            fileExists: { _ in false },
            isExecutable: { _ in false }
        )
        XCTAssertTrue(report.errors.contains { if case .binaryNotFound = $0 { return true }; return false })
    }
}
