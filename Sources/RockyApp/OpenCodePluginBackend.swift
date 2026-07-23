import Foundation
import RockyCore

/// Filesystem side of Rocky's OpenCode integration.
///
/// OpenCode auto-loads `*.js` / `*.ts` from `~/.config/opencode/plugins/`.
/// Install writes our bridge plugin there with the absolute `rocky-hook` path
/// baked in; uninstall deletes only our file. Never touches `opencode.json`
/// (user plugins / npm entries stay intact).
struct OpenCodePluginBackend {
    /// `$XDG_CONFIG_HOME/opencode` if set, else `~/.config/opencode`.
    let configHome: URL
    let commandArguments: String

    var pluginsDirectory: URL {
        configHome.appendingPathComponent("plugins")
    }

    var pluginURL: URL {
        pluginsDirectory.appendingPathComponent(OpenCodePluginMerger.pluginFileName)
    }

    var isInstalled: Bool {
        OpenCodePluginMerger.isInstalled(pluginSource: try? Data(contentsOf: pluginURL))
    }

    var isCurrent: Bool {
        OpenCodePluginMerger.isCurrent(
            pluginSource: try? Data(contentsOf: pluginURL),
            hookBinaryPath: AgentIntegration.hookBinaryPath,
            commandArguments: commandArguments
        )
    }

    func install() throws {
        let source = OpenCodePluginMerger.pluginSource(
            hookBinaryPath: AgentIntegration.hookBinaryPath,
            commandArguments: commandArguments
        )
        try FileManager.default.createDirectory(
            at: pluginsDirectory,
            withIntermediateDirectories: true
        )
        // Backup previous Rocky plugin if present (not foreign plugins).
        if let existing = try? Data(contentsOf: pluginURL),
           OpenCodePluginMerger.isInstalled(pluginSource: existing) {
            try existing.write(
                to: pluginURL.appendingPathExtension("rocky-bak"),
                options: .atomic
            )
        }
        try Data(source.utf8).write(to: pluginURL, options: .atomic)
    }

    func uninstall() throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: pluginURL.path) {
            try? fm.removeItem(at: pluginURL.appendingPathExtension("rocky-bak"))
            try fm.removeItem(at: pluginURL)
        }
    }

    /// Resolve OpenCode's global config directory the same way the CLI does.
    static func defaultConfigHome(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg).appendingPathComponent("opencode")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/opencode")
    }
}
