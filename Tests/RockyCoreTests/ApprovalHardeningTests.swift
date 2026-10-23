import XCTest
@testable import RockyCore

final class ApprovalHardeningTests: XCTestCase {
    func testReleaseAutoDeciderRequiresExplicitLaunchFlag() {
        for decision in [Decision.allow, .deny, .ask, .passthrough] {
            let environment = ["ROCKY_AUTODECIDE": decision.rawValue]
            XCTAssertNil(AutoDecideGate.decision(environment: environment, arguments: [], isDebugBuild: false))
            XCTAssertEqual(AutoDecideGate.decision(
                environment: environment, arguments: [IntegrationTestLaunch.flag], isDebugBuild: false
            ), decision)
            XCTAssertEqual(AutoDecideGate.decision(
                environment: environment, arguments: [], isDebugBuild: true
            ), decision)
        }
        XCTAssertNil(AutoDecideGate.decision(
            environment: ["ROCKY_AUTODECIDE": "bogus"], arguments: [IntegrationTestLaunch.flag], isDebugBuild: false
        ))
        XCTAssertNil(AutoDecideGate.decision(environment: [:], arguments: [IntegrationTestLaunch.flag]))
        XCTAssertTrue(IntegrationTestLaunch.isActive(arguments: [IntegrationTestLaunch.flag]))
        XCTAssertFalse(IntegrationTestLaunch.isActive(arguments: []))
    }

    func testAlternateSocketIsInjectedForBothPeers() {
        for isDebug in [true, false] {
            let arguments = [IntegrationTestLaunch.flag]
            XCTAssertEqual(IPC.socketPath(home: "/fixture", environment: ["ROCKY_SOCKET_PATH": "/fixture/test.sock"], arguments: arguments, isDebugBuild: isDebug), "/fixture/test.sock")
            XCTAssertEqual(IPC.socketPath(home: "/fixture", environment: [:], arguments: arguments, isDebugBuild: isDebug), "/fixture/Library/Application Support/rocky/rocky.sock")
            XCTAssertEqual(IPC.socketPath(home: "/fixture", environment: ["ROCKY_SOCKET_PATH": "relative.sock"], arguments: arguments, isDebugBuild: isDebug), "/fixture/Library/Application Support/rocky/rocky.sock")
        }
    }

    func testReleaseSocketOverrideRequiresExplicitTestMode() {
        let environment = ["ROCKY_SOCKET_PATH": "/fixture/fake.sock"]
        XCTAssertEqual(IPC.socketPath(home: "/fixture", environment: environment, arguments: [], isDebugBuild: false), "/fixture/Library/Application Support/rocky/rocky.sock")
        XCTAssertEqual(IPC.socketPath(home: "/fixture", environment: environment, arguments: [IntegrationTestLaunch.flag], isDebugBuild: false), "/fixture/fake.sock")
        XCTAssertEqual(IPC.socketPath(home: "/fixture", environment: environment, arguments: [], isDebugBuild: true), "/fixture/fake.sock")
        #if !DEBUG
        XCTAssertEqual(
            IPC.socketPath(home: "/fixture", environment: ["ROCKY_SOCKET_PATH": "/fixture/fake.sock"]),
            "/fixture/Library/Application Support/rocky/rocky.sock"
        )
        #endif
    }

    func testPOSIXQuotingRoundTripsAllMetacharactersWithoutEvaluation() throws {
        for component in ["with space", "$(printf injected)", "`printf injected`", "single'quote", "double\"quote", "all $()`'\""] {
            let path = "/Applications/\(component)/rocky-hook"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "printf '%s' " + ShellCommand.quote(path)]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            XCTAssertEqual(String(data: output, encoding: .utf8), path)
            let prefix = ShellCommand.quote(path) + " --agent test"
            XCTAssertEqual(ClaudeSettingsMerger.hookCommand(hookBinaryPath: path, commandArguments: "--agent test"), prefix)
            XCTAssertEqual(CursorSettingsMerger.hookCommand(hookBinaryPath: path, commandArguments: "--agent test"), prefix)
            XCTAssertEqual(KimiPluginMerger.hookCommand(hookBinaryPath: path, commandArguments: "--agent test"), prefix)
            XCTAssertEqual(AgySettingsMerger.hookCommand(hookBinaryPath: path, event: "Stop", commandArguments: "--agent test"), prefix + " --event Stop")
            let data = try ClaudeSettingsMerger.merge(settings: nil, hookBinaryPath: path)
            XCTAssertTrue(ClaudeSettingsMerger.isCurrent(settings: data, hookBinaryPath: path, events: ClaudeSettingsMerger.claudeEvents))
            XCTAssertTrue(HookHealthCheck.inspectNested(
                agent: "claude-code", displayName: "Claude Code", expectedBinaryPath: path,
                configPath: "/fixture/settings.json", configData: data,
                fileExists: { _ in true }, isExecutable: { _ in true }
            ).isHealthy)
        }
    }

    func testLegacyCommandsRemainCurrentDetectedAndRemovable() throws {
        for path in ["/Applications/Rocky.app/rocky-hook", "/Applications/Rocky Beta.app/rocky-hook"] {
            let legacy = path.contains(" ") ? "\"\(path)\"" : path
            let command = legacy + " --agent claude-code"
            let root: [String: Any] = ["hooks": Dictionary(uniqueKeysWithValues: ClaudeSettingsMerger.claudeEvents.map {
                ($0.name, [["hooks": [["command": command]]]])
            })]
            let data = try JSONSerialization.data(withJSONObject: root)
            XCTAssertTrue(ClaudeSettingsMerger.isCurrent(
                settings: data, hookBinaryPath: path, events: ClaudeSettingsMerger.claudeEvents,
                commandArguments: "--agent claude-code"
            ))
            XCTAssertTrue(ClaudeSettingsMerger.isInstalled(settings: data))
            XCTAssertTrue(HookHealthCheck.inspectNested(
                agent: "claude-code", displayName: "Claude Code", expectedBinaryPath: path,
                configPath: "/fixture/settings.json", configData: data,
                fileExists: { _ in true }, isExecutable: { _ in true }
            ).isHealthy)
            XCTAssertFalse(ClaudeSettingsMerger.isInstalled(settings: try ClaudeSettingsMerger.unmerge(settings: data)))

            let cursorRoot: [String: Any] = ["hooks": Dictionary(uniqueKeysWithValues: CursorSettingsMerger.cursorEvents.map {
                ($0.name, [["command": legacy + " --agent cursor"]])
            })]
            let cursor = try JSONSerialization.data(withJSONObject: cursorRoot)
            XCTAssertTrue(CursorSettingsMerger.isCurrent(settings: cursor, hookBinaryPath: path))
            XCTAssertFalse(CursorSettingsMerger.isInstalled(settings: try CursorSettingsMerger.unmerge(settings: cursor)))

            let agy = try AgySettingsMerger.merge(settings: nil, hookBinaryPath: path)
            let oldAgy = try legacyCommands(agy, quoted: ShellCommand.quote(path), legacy: legacy)
            XCTAssertTrue(AgySettingsMerger.isCurrent(settings: oldAgy, hookBinaryPath: path))
            XCTAssertFalse(AgySettingsMerger.isInstalled(settings: try AgySettingsMerger.unmerge(settings: oldAgy)))

            let registry = try KimiPluginMerger.registryMerge(registry: nil, pluginRoot: "/fixture/plugin", now: "now")
            let manifest = try KimiPluginMerger.manifest(hookBinaryPath: path)
            XCTAssertTrue(KimiPluginMerger.isCurrent(
                registry: registry, manifest: try legacyCommands(manifest, quoted: ShellCommand.quote(path), legacy: legacy),
                pluginRoot: "/fixture/plugin", hookBinaryPath: path
            ))
            XCTAssertFalse(KimiPluginMerger.isInstalled(registry: try KimiPluginMerger.registryUnmerge(registry: registry)))
        }
    }

    private func legacyCommands(_ data: Data, quoted: String, legacy: String) throws -> Data {
        func replacing(_ object: Any) -> Any {
            if let dictionary = object as? [String: Any] {
                return dictionary.mapValues(replacing)
            }
            if let array = object as? [Any] { return array.map(replacing) }
            if let text = object as? String { return text.replacingOccurrences(of: quoted, with: legacy) }
            return object
        }
        return try JSONSerialization.data(withJSONObject: replacing(JSONSerialization.jsonObject(with: data)))
    }

    func testDiagnosticsNeverIncludePayloadOrDecoderDescriptions() {
        let secret = "secret-token $(command)"
        let error = DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: secret))
        XCTAssertEqual(HookDiagnostics.decodeFailure(error, byteCount: 123), "decode category=data-corrupted bytes=123")
        let event = HookEvent(sessionId: secret, hookEventName: secret, toolName: secret,
                              toolInput: .object(["command": .string(secret)]))
        XCTAssertFalse(HookDiagnostics.eventSummary(event).contains(secret))
        XCTAssertTrue(HookDiagnostics.eventSummary(event).contains("unknown"))
    }

    func testClaudeDowngradeRemovesOnlyRockysUnsupportedEvent() throws {
        let binary = "/fixture/rocky-hook"
        let supported = try ClaudeSettingsMerger.merge(
            settings: nil, hookBinaryPath: binary, events: ClaudeHookCapabilities.events(version: "2.1.305")
        )
        let legacyEvents = ClaudeHookCapabilities.events(version: "2.0.76")
        XCTAssertFalse(ClaudeSettingsMerger.isCurrent(settings: supported, hookBinaryPath: binary, events: legacyEvents))
        let downgraded = try ClaudeSettingsMerger.merge(settings: supported, hookBinaryPath: binary, events: legacyEvents)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: downgraded) as? [String: Any])
        XCTAssertNil((root["hooks"] as? [String: Any])?["StopFailure"])
        XCTAssertTrue(ClaudeSettingsMerger.isCurrent(settings: downgraded, hookBinaryPath: binary, events: legacyEvents))
    }

    func testStopFailureIsOnlyInstalledOnSupportedClaudeVersions() {
        for version in [nil, "2.0.76", "2.1.77", "invalid", "2.1.78-preview"] {
            XCTAssertFalse(ClaudeHookCapabilities.events(version: version).contains { $0.name == "StopFailure" })
        }
        for version in ["2.1.78", "2.1.305", "3.0.0"] {
            let event = ClaudeHookCapabilities.events(version: version).first { $0.name == "StopFailure" }
            XCTAssertEqual(event?.needsReply, false)
        }
        XCTAssertEqual(ClaudeHookCapabilities.version(resolvedBinaryName: "2.1.305", header: ""), "2.1.305")
        XCTAssertEqual(ClaudeHookCapabilities.version(resolvedBinaryName: "cli.js", header: "#!/usr/bin/env node\n// Version: 2.1.305\n"), "2.1.305")
    }
}
