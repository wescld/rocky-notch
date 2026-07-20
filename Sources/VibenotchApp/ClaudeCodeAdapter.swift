import Foundation
import VibenotchCore

/// Installs/removes vibenotch hooks in `~/.claude/settings.json`.
/// Safety rules (spec §3.4): backup before writing, atomic write, never
/// overwrite a file that failed to parse, remove only our own entries.
struct ClaudeCodeAdapter {
    enum InstallError: LocalizedError {
        case unparseableSettings(String)

        var errorDescription: String? {
            switch self {
            case .unparseableSettings(let path):
                "O arquivo \(path) não pôde ser lido como JSON. "
                    + "Nada foi alterado — corrija o arquivo e tente de novo."
            }
        }
    }

    var settingsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/settings.json")

    /// The hook binary lives next to the app executable inside the bundle.
    static var hookBinaryPath: String {
        let executable = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
        return executable.deletingLastPathComponent()
            .appendingPathComponent("vibenotch-hook").path
    }

    var isInstalled: Bool {
        ClaudeSettingsMerger.isInstalled(settings: try? Data(contentsOf: settingsURL))
    }

    /// True when installed but pointing at a stale binary path (app moved).
    var needsReinstall: Bool {
        guard isInstalled,
              let data = try? Data(contentsOf: settingsURL),
              let text = String(data: data, encoding: .utf8)
        else { return false }
        return !text.contains(Self.hookBinaryPath)
    }

    func install() throws {
        let existing = try? Data(contentsOf: settingsURL)
        let merged: Data
        do {
            merged = try ClaudeSettingsMerger.merge(
                settings: existing,
                hookBinaryPath: Self.hookBinaryPath
            )
        } catch {
            throw InstallError.unparseableSettings(settingsURL.path)
        }
        try write(merged, backupOf: existing)
    }

    func uninstall() throws {
        guard let existing = try? Data(contentsOf: settingsURL) else { return }
        let cleaned: Data
        do {
            cleaned = try ClaudeSettingsMerger.unmerge(settings: existing)
        } catch {
            throw InstallError.unparseableSettings(settingsURL.path)
        }
        try write(cleaned, backupOf: existing)
    }

    private func write(_ data: Data, backupOf existing: Data?) throws {
        let directory = settingsURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        if let existing {
            try existing.write(
                to: settingsURL.appendingPathExtension("vibenotch-bak"),
                options: .atomic
            )
        }
        try data.write(to: settingsURL, options: .atomic)
    }
}
