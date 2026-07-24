import Foundation
import SQLite3

/// Read-only access to Warp's live SQLite for precision jump targeting.
///
/// Depends on Warp's internal schema (not a supported API). Every failure
/// path returns nil / 0 so callers can fall back to "activate Warp".
public struct WarpSQLiteReader: Sendable {
    public let databasePath: String

    public init(databasePath: String = WarpSQLiteReader.defaultDatabasePath()) {
        self.databasePath = databasePath
    }

    /// Warp Stable stores state in a group container (sandboxed app).
    public static func defaultDatabasePath() -> String {
        NSHomeDirectory()
            + "/Library/Group Containers/2BBY89MBSN.dev.warp"
            + "/Library/Application Support/dev.warp.Warp-Stable/warp.sqlite"
    }

    /// Resolve the pane UUID hosting an agent in `cwd`.
    ///
    /// 1. Direct match on `terminal_panes.cwd` (with /tmp firmlink variants)
    /// 2. Fallback: command history `cd <cwd>` → pane via blocks join
    public func lookupPaneUUID(forCwd cwd: String) -> String? {
        guard let db = openReadOnly() else { return nil }
        defer { sqlite3_close(db) }

        if let uuid = lookupViaTerminalPanesCwd(db: db, cwd: cwd) {
            return uuid
        }
        return lookupViaCommandsHistory(db: db, cwd: cwd)
    }

    /// Pane UUID currently focused in Warp's active window.
    public func currentFocusedPaneUUID() -> String? {
        guard let db = openReadOnly() else { return nil }
        defer { sqlite3_close(db) }

        guard let activeWindowID = fetchActiveWindowID(db: db) else { return nil }
        let activeTabIndex = fetchActiveTabIndex(db: db, windowID: activeWindowID) ?? 0
        guard let activeTabID = fetchTabIDAtOffset(
            db: db,
            windowID: activeWindowID,
            offset: activeTabIndex
        ) else {
            return nil
        }

        let sql = """
        SELECT hex(tp.uuid)
        FROM pane_nodes pn
        LEFT JOIN pane_leaves pl ON pl.pane_node_id = pn.id
        JOIN terminal_panes tp ON tp.id = pn.id
        WHERE pn.tab_id = ?
          AND pn.is_leaf = 1
        ORDER BY COALESCE(pl.is_focused, 0) DESC, pn.id ASC
        LIMIT 1;
        """
        return fetchHexUUID(db: db, sql: sql, bindInt64: activeTabID)
    }

    /// Number of tabs in the active Warp window (for cycle cap).
    public func tabCountInActiveWindow() -> Int {
        guard let db = openReadOnly() else { return 0 }
        defer { sqlite3_close(db) }
        guard let activeWindowID = fetchActiveWindowID(db: db) else { return 0 }

        let sql = "SELECT COUNT(*) FROM tabs WHERE window_id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, activeWindowID)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    // MARK: - Lookups

    private func lookupViaTerminalPanesCwd(db: OpaquePointer, cwd: String) -> String? {
        let candidates = Self.cwdLookupCandidates(for: cwd)
        let placeholders = Array(repeating: "?", count: candidates.count).joined(separator: ", ")
        let sql = """
        SELECT hex(uuid)
        FROM terminal_panes
        WHERE cwd IN (\(placeholders))
        ORDER BY id DESC
        LIMIT 1;
        """
        return fetchHexUUID(db: db, sql: sql, bindTexts: candidates)
    }

    private func lookupViaCommandsHistory(db: OpaquePointer, cwd: String) -> String? {
        let candidates = Self.cwdLookupCandidates(for: cwd)
        if candidates.contains(where: { path in path.contains(where: { "*?[".contains($0) }) }) {
            return nil
        }

        var patterns: [String] = []
        for candidate in candidates {
            patterns.append("*cd \(candidate)[ ;&|]*")
            patterns.append("*cd \(candidate)")
        }
        let whereClause = Array(repeating: "c.command GLOB ?", count: patterns.count)
            .joined(separator: " OR ")

        let sql = """
        SELECT hex(tp.uuid)
        FROM commands c
        JOIN terminal_panes tp ON tp.cwd = c.pwd
        LEFT JOIN blocks b_match
            ON b_match.pane_leaf_uuid = tp.uuid
            AND b_match.block_id GLOB 'precmd-' || c.session_id || '-*'
        WHERE (\(whereClause))
          AND NOT EXISTS (
              SELECT 1 FROM blocks b_foreign
              WHERE b_foreign.pane_leaf_uuid = tp.uuid
                AND b_foreign.block_id GLOB 'precmd-*-*'
                AND b_foreign.block_id NOT GLOB 'precmd-' || c.session_id || '-*'
          )
        ORDER BY (b_match.id IS NOT NULL) DESC,
                 c.id DESC,
                 tp.id DESC
        LIMIT 1;
        """
        return fetchHexUUID(db: db, sql: sql, bindTexts: patterns)
    }

    /// `/tmp` ↔ `/private/tmp` (and `/var`) firmlink pair for cwd matching.
    public static func cwdLookupCandidates(for cwd: String) -> [String] {
        var result: [String] = [cwd]
        if cwd.hasPrefix("/private/tmp/") || cwd == "/private/tmp" {
            result.append(String(cwd.dropFirst("/private".count)))
        } else if cwd.hasPrefix("/tmp/") || cwd == "/tmp" {
            result.append("/private" + cwd)
        } else if cwd.hasPrefix("/private/var/") || cwd == "/private/var" {
            result.append(String(cwd.dropFirst("/private".count)))
        } else if cwd.hasPrefix("/var/") || cwd == "/var" {
            result.append("/private" + cwd)
        }
        return result
    }

    // MARK: - Window / tab helpers

    private func fetchActiveWindowID(db: OpaquePointer) -> Int64? {
        if let value = fetchSingleInt64(db: db, sql: "SELECT active_window_id FROM app LIMIT 1") {
            return value
        }
        return fetchSingleInt64(db: db, sql: "SELECT MIN(window_id) FROM tabs")
    }

    private func fetchActiveTabIndex(db: OpaquePointer, windowID: Int64) -> Int? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT active_tab_index FROM windows WHERE id = ?",
            -1,
            &stmt,
            nil
        ) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, windowID)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        if sqlite3_column_type(stmt, 0) == SQLITE_NULL { return nil }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private func fetchTabIDAtOffset(
        db: OpaquePointer,
        windowID: Int64,
        offset: Int
    ) -> Int64? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT id FROM tabs WHERE window_id = ? ORDER BY id ASC LIMIT 1 OFFSET ?",
            -1,
            &stmt,
            nil
        ) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, windowID)
        sqlite3_bind_int(stmt, 2, Int32(offset))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(stmt, 0)
    }

    // MARK: - SQLite plumbing

    private func openReadOnly() -> OpaquePointer? {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databasePath, &db, flags, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return nil
        }
        // Short busy timeout — never hang the hook.
        sqlite3_busy_timeout(db, 30)
        return db
    }

    private func fetchSingleInt64(db: OpaquePointer, sql: String) -> Int64? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        if sqlite3_column_type(stmt, 0) == SQLITE_NULL { return nil }
        return sqlite3_column_int64(stmt, 0)
    }

    private func fetchHexUUID(
        db: OpaquePointer,
        sql: String,
        bindTexts: [String]? = nil,
        bindInt64: Int64? = nil
    ) -> String? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        var held: [UnsafeMutablePointer<CChar>?] = []
        defer { held.forEach { free($0) } }

        if let bindTexts {
            for (index, text) in bindTexts.enumerated() {
                let cString = text.withCString { strdup($0) }
                held.append(cString)
                sqlite3_bind_text(stmt, Int32(index + 1), cString, -1, nil)
            }
        }
        if let bindInt64 {
            sqlite3_bind_int64(stmt, 1, bindInt64)
        }

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let cString = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: cString)
    }
}
