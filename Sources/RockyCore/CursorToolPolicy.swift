import Foundation

/// Cursor fires `preToolUse` for every tool. Rocky auto-passes read-only tools
/// so the notch only asks about shell, writes, deletes, tasks, and MCP calls.
///
/// Cursor's Agent **Auto-run / YOLO** (`fullAutoRun` in composer state) still
/// runs `preToolUse` hooks — so Rocky must opt out itself when the user already
/// chose full auto, otherwise the notch becomes a second approval gate they
/// never asked for. Same idea as `GrokToolPolicy` + always-approve.
public enum CursorToolPolicy {
    /// Tools Cursor treats as safe / observational. Keep aligned with Cursor's
    /// agent tool names (Shell, Read, Write, Grep, Delete, Task, MCP:…).
    public static let autoPassTools: Set<String> = [
        "Read",
        "Grep",
        "Glob",
        "SemanticSearch",
        "ReadLints",
        "TodoWrite",
    ]

    /// Mode strings that mean "don't prompt the human" if Cursor ever puts them
    /// on the hook payload (`permissionMode` / aliases).
    public static let alwaysApproveModes: Set<String> = [
        "always-approve",
        "always_approve",
        "alwaysapprove",
        "bypasspermissions",
        "bypass-permissions",
        "yolo",
        "full-auto",
        "full_auto",
        "fullauto",
        "fullautorun",
        "full-auto-run",
        "auto-run",
        "autorun",
    ]

    /// Key Cursor stores the full `applicationUser` blob under in `state.vscdb`.
    public static let applicationUserStorageKey =
        "src.vs.platform.reactivestorage.browser.reactiveStorageServiceImpl.persistentStorage.applicationUser"

    public static func shouldAutoPass(toolName: String?) -> Bool {
        guard let toolName, !toolName.isEmpty else { return false }
        // Explicit deny list wins for anything write-like misnamed.
        if writeLike(toolName) { return false }
        // MCP tools always need a human (or Cursor's own gate).
        if toolName.hasPrefix("MCP:") || toolName.hasPrefix("mcp:") { return false }
        // autoPassTools is the single source of truth; match case-insensitively
        // so a lowercase alias (read/grep/glob) resolves without a second list.
        let lower = toolName.lowercased()
        return autoPassTools.contains { $0.lowercased() == lower }
    }

    /// True when the hook payload or Cursor composer state says YOLO / full auto-run.
    public static func isAlwaysApproveMode(
        permissionMode: String? = nil,
        home: String = NSHomeDirectory()
    ) -> Bool {
        if let permissionMode, isAlwaysApproveModeName(permissionMode) {
            return true
        }
        return isAlwaysApproveInConfig(home: home)
    }

    /// preToolUse should not open a Rocky card when the tool is read-only or
    /// Cursor Agent is already in full Auto-run / YOLO.
    public static func shouldSkipRockyGate(
        toolName: String?,
        permissionMode: String? = nil,
        home: String = NSHomeDirectory()
    ) -> Bool {
        if shouldAutoPass(toolName: toolName) { return true }
        return isAlwaysApproveMode(permissionMode: permissionMode, home: home)
    }

    public static func isAlwaysApproveModeName(_ raw: String) -> Bool {
        let key = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        let compact = key.replacingOccurrences(of: "-", with: "")
        return alwaysApproveModes.contains(key)
            || alwaysApproveModes.contains(compact)
            || compact == "bypasspermissions"
            || compact == "fullautorun"
    }

    /// Best-effort read of Cursor's `state.vscdb` Agent mode `fullAutoRun`.
    /// Session toggles may lag a moment behind the UI; payload `permissionMode`
    /// (when present) wins first.
    public static func isAlwaysApproveInConfig(home: String = NSHomeDirectory()) -> Bool {
        let dbPath = (home as NSString)
            .appendingPathComponent(
                "Library/Application Support/Cursor/User/globalStorage/state.vscdb"
            )
        guard FileManager.default.fileExists(atPath: dbPath) else { return false }
        // Tiny json_extract query (~bytes) — avoids loading the full ~300KB
        // applicationUser blob (and pipe-buffer deadlocks with Process).
        if let flag = readAgentFullAutoRun(dbPath: dbPath) {
            return flag
        }
        // Fallback: modes4 JSON only, then pure parser used by tests.
        if let modesJSON = readModes4JSON(dbPath: dbPath) {
            let wrapped = "{\"composerState\":{\"modes4\":\(modesJSON)}}"
            return parseAlwaysApprove(fromApplicationUserJSON: wrapped)
        }
        return false
    }

    /// Pure JSON scan for tests. Looks at `composerState.modes4` Agent mode.
    ///
    /// - `fullAutoRun == true` on the `agent` mode → always-approve (YOLO).
    /// - Other modes (plan/ask/…) are ignored; Rocky only mirrors Agent auto-run.
    public static func parseAlwaysApprove(fromApplicationUserJSON text: String) -> Bool {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let composer = root["composerState"] as? [String: Any],
              let modes = composer["modes4"] as? [[String: Any]]
        else { return false }

        guard let agent = modes.first(where: { ($0["id"] as? String) == "agent" })
        else { return false }

        // fullAutoRun is the UI "full auto" / YOLO switch.
        return boolish(agent["fullAutoRun"])
    }

    // MARK: - SQLite (sqlite3 CLI, best-effort)

    /// `1`/`true` when Agent has fullAutoRun; `0`/`false` when not; nil on error.
    public static func readAgentFullAutoRun(dbPath: String) -> Bool? {
        let key = applicationUserStorageKey
        // json_each over modes4; only the agent row's fullAutoRun flag.
        let sql = """
        SELECT json_extract(j.value, '$.fullAutoRun') \
        FROM ItemTable, \
             json_each(json_extract(ItemTable.value, '$.composerState.modes4')) AS j \
        WHERE ItemTable.key='\(key)' \
          AND json_extract(j.value, '$.id') = 'agent' \
        LIMIT 1;
        """
        guard let raw = runSqlite(dbPath: dbPath, sql: sql) else { return nil }
        let trimmed = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch trimmed {
        case "1", "true": return true
        case "0", "false": return false
        case "": return false
        default: return nil
        }
    }

    public static func readModes4JSON(dbPath: String) -> String? {
        let key = applicationUserStorageKey
        let sql = """
        SELECT json_extract(value, '$.composerState.modes4') \
        FROM ItemTable WHERE key='\(key)' LIMIT 1;
        """
        guard let raw = runSqlite(dbPath: dbPath, sql: sql) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else { return nil }
        return trimmed
    }

    /// Runs `/usr/bin/sqlite3` and returns stdout. Drains the pipe before
    /// `waitUntilExit` so large results cannot deadlock on a full pipe buffer.
    public static func runSqlite(dbPath: String, sql: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        // Pass the path as its own argv element so spaces in
        // "Application Support" need no escaping / URI encoding.
        process.arguments = ["-batch", "-noheader", dbPath, sql]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        // Drain first — critical when result size > ~64KB pipe buffer.
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        guard !data.isEmpty else { return "" }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Internals

    private static func writeLike(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("write")
            || lower.contains("edit")
            || lower.contains("delete")
            || lower == "shell"
            || lower == "task"
            || lower == "bash"
    }

    private static func boolish(_ value: Any?) -> Bool {
        switch value {
        case let b as Bool: return b
        case let n as NSNumber: return n.boolValue
        case let s as String:
            switch s.lowercased() {
            case "true", "1", "yes": return true
            default: return false
            }
        default: return false
        }
    }
}
