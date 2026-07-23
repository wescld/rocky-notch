import XCTest
@testable import RockyCore

final class OpenCodePluginMergerTests: XCTestCase {
    let binary = "/Applications/Rocky.app/Contents/MacOS/rocky-hook"
    let args = "--agent opencode"

    func testPluginSourceEmbedsHookPathAndAgentFlag() {
        let source = OpenCodePluginMerger.pluginSource(
            hookBinaryPath: binary,
            commandArguments: args
        )
        XCTAssertTrue(source.contains(binary))
        XCTAssertTrue(source.contains("opencode"))
        XCTAssertTrue(source.contains(OpenCodePluginMerger.commandMarker))
        XCTAssertTrue(source.contains("permission.ask"))
        XCTAssertTrue(source.contains("export const RockyNotch"))
        // Must not export non-functions (OpenCode loads every named export).
        XCTAssertFalse(source.contains("export const PLUGIN_VERSION"))
    }

    func testPluginSourceEscapesQuotesInPath() {
        let spaced = "/Users/x/My Apps/Rocky.app/Contents/MacOS/rocky-hook"
        let source = OpenCodePluginMerger.pluginSource(hookBinaryPath: spaced)
        XCTAssertTrue(source.contains("My Apps"))
        XCTAssertTrue(source.contains("\\\"") || source.contains(spaced))
    }

    func testIsInstalledDetectsMarker() {
        let source = OpenCodePluginMerger.pluginSource(hookBinaryPath: binary)
        XCTAssertTrue(OpenCodePluginMerger.isInstalled(pluginSource: Data(source.utf8)))
        XCTAssertFalse(OpenCodePluginMerger.isInstalled(pluginSource: nil))
        XCTAssertFalse(OpenCodePluginMerger.isInstalled(pluginSource: Data("nope".utf8)))
    }

    func testIsCurrentWhenPathMatches() {
        let source = OpenCodePluginMerger.pluginSource(
            hookBinaryPath: binary,
            commandArguments: args
        )
        XCTAssertTrue(OpenCodePluginMerger.isCurrent(
            pluginSource: Data(source.utf8),
            hookBinaryPath: binary,
            commandArguments: args
        ))
    }

    func testIsCurrentFalseWhenHookMoved() {
        let source = OpenCodePluginMerger.pluginSource(
            hookBinaryPath: binary,
            commandArguments: args
        )
        XCTAssertFalse(OpenCodePluginMerger.isCurrent(
            pluginSource: Data(source.utf8),
            hookBinaryPath: "/elsewhere/rocky-hook",
            commandArguments: args
        ))
    }

    func testIsCurrentFalseWhenAgentFlagMissing() {
        let source = OpenCodePluginMerger.pluginSource(
            hookBinaryPath: binary,
            commandArguments: args
        )
        XCTAssertFalse(OpenCodePluginMerger.isCurrent(
            pluginSource: Data(source.utf8),
            hookBinaryPath: binary,
            commandArguments: "--agent claude-code"
        ))
    }
}
