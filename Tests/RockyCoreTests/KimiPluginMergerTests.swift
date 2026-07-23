import XCTest
@testable import RockyCore

final class KimiPluginMergerTests: XCTestCase {
    let binary = "/Applications/Rocky.app/Contents/MacOS/rocky-hook"
    let args = "--agent kimi-code"
    let root = "/Users/x/.kimi-code/plugins/managed/rocky-notch"
    let now = "2026-07-23T12:00:00Z"

    func parse(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Manifest

    func testManifestShape() throws {
        let out = try KimiPluginMerger.manifest(
            hookBinaryPath: binary, commandArguments: args
        )
        let manifest = try parse(out)
        XCTAssertEqual(manifest["name"] as? String, "rocky-notch")
        let hooks = try XCTUnwrap(manifest["hooks"] as? [[String: Any]])
        XCTAssertEqual(hooks.count, KimiPluginMerger.kimiEvents.count)

        let pre = try XCTUnwrap(hooks.first { ($0["event"] as? String) == "PreToolUse" })
        XCTAssertEqual(pre["command"] as? String, "\(binary) \(args)")
        XCTAssertEqual(pre["timeout"] as? Int, 60)
        // Observe-only events use the short timeout.
        let stop = try XCTUnwrap(hooks.first { ($0["event"] as? String) == "Stop" })
        XCTAssertEqual(stop["timeout"] as? Int, 10)
        // No matcher: PreToolUse must fire for every tool (filtering is in the hook).
        XCTAssertNil(pre["matcher"])
        // PermissionRequest is deliberately never registered (would hang the hook).
        XCTAssertFalse(hooks.contains { ($0["event"] as? String) == "PermissionRequest" })
    }

    func testManifestShellQuotesPathWithSpaces() throws {
        let spaced = "/Applications/Rocky Beta.app/Contents/MacOS/rocky-hook"
        let out = try KimiPluginMerger.manifest(hookBinaryPath: spaced, commandArguments: args)
        let hooks = try XCTUnwrap(try parse(out)["hooks"] as? [[String: Any]])
        let pre = try XCTUnwrap(hooks.first { ($0["event"] as? String) == "PreToolUse" })
        XCTAssertEqual(pre["command"] as? String, "\"\(spaced)\" \(args)")
    }

    // MARK: - Registry merge

    func testRegistryMergeIntoEmpty() throws {
        let out = try KimiPluginMerger.registryMerge(registry: nil, pluginRoot: root, now: now)
        let reg = try parse(out)
        XCTAssertEqual(reg["version"] as? Int, 1)
        let plugins = try XCTUnwrap(reg["plugins"] as? [[String: Any]])
        XCTAssertEqual(plugins.count, 1)
        let entry = plugins[0]
        XCTAssertEqual(entry["id"] as? String, "rocky-notch")
        XCTAssertEqual(entry["root"] as? String, root)
        XCTAssertEqual(entry["source"] as? String, "local-path")
        XCTAssertEqual(entry["enabled"] as? Bool, true)
        XCTAssertEqual(entry["installedAt"] as? String, now)
        XCTAssertEqual(entry["updatedAt"] as? String, now)
        XCTAssertTrue(KimiPluginMerger.isInstalled(registry: out))
    }

    func testRegistryMergePreservesForeignEntriesAndKeys() throws {
        let existing = """
        {
          "version": 1,
          "note": "user comment",
          "plugins": [
            {"id": "someones-plugin", "root": "/opt/x", "enabled": true, "capabilities": ["hooks"]}
          ]
        }
        """
        let out = try KimiPluginMerger.registryMerge(
            registry: Data(existing.utf8), pluginRoot: root, now: now
        )
        let reg = try parse(out)
        XCTAssertEqual(reg["note"] as? String, "user comment")
        let plugins = try XCTUnwrap(reg["plugins"] as? [[String: Any]])
        XCTAssertEqual(plugins.count, 2)
        // Foreign entry untouched, including its extra keys.
        let foreign = try XCTUnwrap(plugins.first { ($0["id"] as? String) == "someones-plugin" })
        XCTAssertEqual(foreign["capabilities"] as? [String], ["hooks"])
    }

    func testRegistryMergeIsIdempotent() throws {
        let once = try KimiPluginMerger.registryMerge(registry: nil, pluginRoot: root, now: now)
        let twice = try KimiPluginMerger.registryMerge(registry: once, pluginRoot: root, now: "2026-07-23T13:00:00Z")
        let plugins = try XCTUnwrap(try parse(twice)["plugins"] as? [[String: Any]])
        XCTAssertEqual(plugins.count, 1)
    }

    func testRegistryMergePreservesInstalledAtAndBumpsUpdatedAt() throws {
        let once = try KimiPluginMerger.registryMerge(registry: nil, pluginRoot: root, now: now)
        let later = "2026-07-24T09:30:00Z"
        let twice = try KimiPluginMerger.registryMerge(registry: once, pluginRoot: root, now: later)
        let entry = try XCTUnwrap((try parse(twice)["plugins"] as? [[String: Any]])?.first)
        XCTAssertEqual(entry["installedAt"] as? String, now, "install date must be preserved")
        XCTAssertEqual(entry["updatedAt"] as? String, later)
    }

    // MARK: - Registry unmerge

    func testRegistryUnmergeRemovesOnlyOurs() throws {
        let existing = """
        {
          "version": 1,
          "plugins": [
            {"id": "someones-plugin", "root": "/opt/x", "enabled": true},
            {"id": "rocky-notch", "root": "\(root)", "enabled": true}
          ]
        }
        """
        let out = try KimiPluginMerger.registryUnmerge(registry: Data(existing.utf8))
        let plugins = try XCTUnwrap(try parse(out)["plugins"] as? [[String: Any]])
        XCTAssertEqual(plugins.count, 1)
        XCTAssertEqual(plugins[0]["id"] as? String, "someones-plugin")
        XCTAssertFalse(KimiPluginMerger.isInstalled(registry: out))
    }

    func testUnmergeOnEmptyRegistryIsSafe() throws {
        let out = try KimiPluginMerger.registryUnmerge(registry: nil)
        XCTAssertFalse(KimiPluginMerger.isInstalled(registry: out))
    }

    // MARK: - isCurrent (staleness)

    func testIsCurrentTrueForFreshInstall() throws {
        let registry = try KimiPluginMerger.registryMerge(registry: nil, pluginRoot: root, now: now)
        let manifest = try KimiPluginMerger.manifest(hookBinaryPath: binary, commandArguments: args)
        XCTAssertTrue(KimiPluginMerger.isCurrent(
            registry: registry, manifest: manifest,
            pluginRoot: root, hookBinaryPath: binary, commandArguments: args
        ))
    }

    func testIsCurrentFalseWhenBundleMoved() throws {
        let registry = try KimiPluginMerger.registryMerge(registry: nil, pluginRoot: root, now: now)
        let manifest = try KimiPluginMerger.manifest(hookBinaryPath: binary, commandArguments: args)
        // The app moved: the expected command no longer matches the manifest.
        XCTAssertFalse(KimiPluginMerger.isCurrent(
            registry: registry, manifest: manifest,
            pluginRoot: root,
            hookBinaryPath: "/Applications/Rocky.app/Contents/MacOS/rocky-hook-MOVED",
            commandArguments: args
        ))
    }

    func testIsCurrentFalseWhenRootMismatch() throws {
        let registry = try KimiPluginMerger.registryMerge(registry: nil, pluginRoot: root, now: now)
        let manifest = try KimiPluginMerger.manifest(hookBinaryPath: binary, commandArguments: args)
        XCTAssertFalse(KimiPluginMerger.isCurrent(
            registry: registry, manifest: manifest,
            pluginRoot: "/somewhere/else", hookBinaryPath: binary, commandArguments: args
        ))
    }

    func testIsCurrentFalseWithoutManifest() throws {
        let registry = try KimiPluginMerger.registryMerge(registry: nil, pluginRoot: root, now: now)
        XCTAssertFalse(KimiPluginMerger.isCurrent(
            registry: registry, manifest: nil,
            pluginRoot: root, hookBinaryPath: binary, commandArguments: args
        ))
    }

    // MARK: - Error handling

    func testUnsupportedVersionThrows() {
        let future = Data(#"{"version": 2, "plugins": []}"#.utf8)
        XCTAssertThrowsError(
            try KimiPluginMerger.registryMerge(registry: future, pluginRoot: root, now: now)
        ) { error in
            XCTAssertEqual(error as? KimiPluginMerger.MergeError, .unsupportedVersion(2))
        }
    }

    func testMalformedRegistryThrows() {
        let garbage = Data("[not an object]".utf8)
        XCTAssertThrowsError(
            try KimiPluginMerger.registryMerge(registry: garbage, pluginRoot: root, now: now)
        )
    }
}
