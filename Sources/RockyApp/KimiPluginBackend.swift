import Foundation
import RockyCore

/// Filesystem side of Rocky's Kimi Code integration.
///
/// Kimi has no shared hooks config file to merge into (§ `KimiPluginMerger`):
/// it loads hooks from user plugins. So install/uninstall is a two-part
/// operation — stage a plugin folder + manifest, and merge our entry into the
/// shared `installed.json` registry. All pure JSON lives in `KimiPluginMerger`;
/// this struct owns only the disk I/O, with the same safety rules as
/// `AgentIntegration.write`: back up before writing, write atomically, and
/// only ever touch our own registry entry.
///
/// `AgentIntegration` composes one of these for the Kimi provider and delegates
/// its lifecycle methods to it, leaving the config-file merge path untouched.
struct KimiPluginBackend {
    /// `$KIMI_CODE_HOME` if the app inherited it, else `~/.kimi-code`. Note the
    /// app launched from Finder may not see a shell-exported override; the hook
    /// itself always receives the correct `KIMI_CODE_HOME` from Kimi at runtime.
    let kimiHome: URL
    let commandArguments: String
    let events: [(name: String, needsReply: Bool)]

    var pluginRoot: URL {
        kimiHome.appendingPathComponent("plugins/managed/\(KimiPluginMerger.pluginId)")
    }

    var manifestURL: URL {
        pluginRoot.appendingPathComponent("kimi.plugin.json")
    }

    var registryURL: URL {
        kimiHome.appendingPathComponent("plugins/installed.json")
    }

    var isInstalled: Bool {
        KimiPluginMerger.isInstalled(registry: try? Data(contentsOf: registryURL))
    }

    /// True when the registry entry, manifest, and hook path all match what a
    /// fresh install would write. `AgentIntegration.needsReinstall` inverts this
    /// so a moved app bundle or a new event self-heals.
    var isCurrent: Bool {
        KimiPluginMerger.isCurrent(
            registry: try? Data(contentsOf: registryURL),
            manifest: try? Data(contentsOf: manifestURL),
            pluginRoot: pluginRoot.path,
            hookBinaryPath: AgentIntegration.hookBinaryPath,
            events: events,
            commandArguments: commandArguments
        )
    }

    func install() throws {
        // Stage the folder + manifest FIRST, then register the entry. A failure
        // mid-way leaves at most an orphan folder — never a registry entry
        // pointing at a folder that isn't there, which would break Kimi's load.
        let manifest = try KimiPluginMerger.manifest(
            hookBinaryPath: AgentIntegration.hookBinaryPath,
            events: events,
            commandArguments: commandArguments
        )
        try FileManager.default.createDirectory(
            at: pluginRoot,
            withIntermediateDirectories: true
        )
        try manifest.write(to: manifestURL, options: .atomic)

        let existing = try? Data(contentsOf: registryURL)
        let merged = try KimiPluginMerger.registryMerge(
            registry: existing,
            pluginRoot: pluginRoot.path,
            now: Self.timestamp()
        )
        try writeRegistry(merged, backupOf: existing)
    }

    func uninstall() throws {
        // Drop the registry entry FIRST, then the folder — the mirror of
        // install, so a failure never leaves a live entry with no folder.
        if let existing = try? Data(contentsOf: registryURL) {
            let cleaned = try KimiPluginMerger.registryUnmerge(registry: existing)
            try writeRegistry(cleaned, backupOf: existing)
        }
        try? FileManager.default.removeItem(at: pluginRoot)
    }

    private func writeRegistry(_ data: Data, backupOf existing: Data?) throws {
        try FileManager.default.createDirectory(
            at: registryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if let existing {
            try existing.write(
                to: registryURL.appendingPathExtension("rocky-bak"),
                options: .atomic
            )
        }
        try data.write(to: registryURL, options: .atomic)
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}
