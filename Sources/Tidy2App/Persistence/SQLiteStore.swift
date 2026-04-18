import Foundation
import SQLite3

final class SQLiteStore: @unchecked Sendable {
    private let duplicateHashMinimumSizeBytes: Int64 = 50_000
    struct AuthorizedRootRecord {
        let scope: RootScope
        let path: String
        let bookmark: Data
    }

    struct JournalRow {
        let id: String
        let txnID: String
        let actor: String
        let actionType: ActionType
        let targetType: String
        let targetID: String
        let srcPath: String
        let dstPath: String
        let copyOrMove: String
        let conflictResolution: String
        let verified: Bool
        let errorCode: String?
        let errorMessage: String?
        let bytesDelta: Int64
        let createdAt: Date
        let undoneAt: Date?
        let undoable: Bool
    }

    struct JournalInsert {
        let id: String
        let txnID: String
        let actor: String
        let actionType: ActionType
        let targetType: String
        let targetID: String
        let srcPath: String
        let dstPath: String
        let copyOrMove: String
        let conflictResolution: String
        let verified: Bool
        let errorCode: String?
        let errorMessage: String?
        let bytesDelta: Int64
        let createdAt: Date
        let undoable: Bool

        init(id: String,
             txnID: String,
             actor: String,
             actionType: ActionType,
             targetType: String,
             targetID: String,
             srcPath: String,
             dstPath: String,
             copyOrMove: String,
             conflictResolution: String,
             verified: Bool,
             errorCode: String?,
             errorMessage: String?,
             bytesDelta: Int64,
             createdAt: Date,
             undoable: Bool = true) {
            self.id = id
            self.txnID = txnID
            self.actor = actor
            self.actionType = actionType
            self.targetType = targetType
            self.targetID = targetID
            self.srcPath = srcPath
            self.dstPath = dstPath
            self.copyOrMove = copyOrMove
            self.conflictResolution = conflictResolution
            self.verified = verified
            self.errorCode = errorCode
            self.errorMessage = errorMessage
            self.bytesDelta = bytesDelta
            self.createdAt = createdAt
            self.undoable = undoable
        }
    }

    struct BundleState {
        let status: BundleStatus
        let snoozedUntil: Date?
    }

    struct WeeklyConfirmStats {
        let confirmCount: Int
        let confirmedFilesTotal: Int
    }

    struct BundleApplyTransactionResult {
        let movedCount: Int
        let renamedCount: Int
        let quarantinedCount: Int
        let journalCount: Int
    }

    struct PDFIndexCandidate {
        let path: String
        let modifiedAt: Date
    }

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "tidy2.sqlite.serial")
    private let queueKey = DispatchSpecificKey<String>()
    private let queueTag = UUID().uuidString
    private let dbURL: URL
    private var safeModeEnabled = false
    private let schemaVersion = 3

    init() throws {
        let fm = FileManager.default
        let appSupport = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Tidy2", isDirectory: true)

        try fm.createDirectory(at: appSupport, withIntermediateDirectories: true)
        dbURL = appSupport.appendingPathComponent("tidy2.sqlite")
        queue.setSpecific(key: queueKey, value: queueTag)

        try syncOnQueue {
            try openDatabaseUnlocked()
            try migrate()
        }
    }

    deinit {
        if isOnQueue {
            if let db {
                sqlite3_close(db)
            }
            return
        }

        queue.sync {
            if let db {
                sqlite3_close(db)
            }
        }
    }

    func ensureReady() throws {
        try syncOnQueue {
            if db == nil {
                try openDatabaseUnlocked()
            }
            try migrate()
            safeModeEnabled = false
        }
    }

    func resetDatabase() throws {
        try syncOnQueue {
            closeDatabaseUnlocked()
            try removeDatabaseFilesUnlocked()
            try openDatabaseUnlocked()
            try migrate()
            safeModeEnabled = false
        }
    }

    func isSafeModeEnabled() throws -> Bool {
        try syncOnQueue {
            safeModeEnabled
        }
    }

    static func resetPersistentStoreOnDisk() throws {
        let dbURL = try defaultDatabaseURL()
        let fm = FileManager.default
        let paths = [dbURL.path, dbURL.path + "-wal", dbURL.path + "-shm"]
        for path in paths where fm.fileExists(atPath: path) {
            try fm.removeItem(atPath: path)
        }
    }

    static func defaultDatabasePath() throws -> String {
        try defaultDatabaseURL().path
    }

    // MARK: - Migration

    private func migrate() throws {
        let schema = """
        CREATE TABLE IF NOT EXISTS authorized_roots (
            scope TEXT PRIMARY KEY,
            path TEXT NOT NULL,
            bookmark BLOB NOT NULL,
            granted_at REAL NOT NULL
        );

        CREATE TABLE IF NOT EXISTS files (
            id TEXT PRIMARY KEY,
            path TEXT NOT NULL UNIQUE,
            root_scope TEXT NOT NULL,
            name TEXT NOT NULL,
            ext TEXT NOT NULL,
            size_bytes INTEGER NOT NULL,
            modified_at REAL NOT NULL,
            last_seen_at REAL NOT NULL,
            sha256 TEXT,
            content_hash TEXT,
            status TEXT NOT NULL DEFAULT 'active'
        );

        CREATE TABLE IF NOT EXISTS quarantine_items (
            id TEXT PRIMARY KEY,
            file_id TEXT,
            original_path TEXT NOT NULL,
            quarantine_path TEXT NOT NULL UNIQUE,
            sha256 TEXT NOT NULL,
            size_bytes INTEGER NOT NULL,
            quarantined_at REAL NOT NULL,
            expires_at REAL NOT NULL,
            state TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS bundles (
            id TEXT PRIMARY KEY,
            type TEXT NOT NULL,
            title TEXT NOT NULL,
            summary TEXT NOT NULL,
            action_kind TEXT NOT NULL DEFAULT 'rename',
            rename_template TEXT,
            target_folder_bookmark BLOB,
            evidence_json TEXT NOT NULL,
            risk_level TEXT NOT NULL,
            status TEXT NOT NULL,
            created_at REAL NOT NULL,
            snoozed_until REAL,
            matched_rule_id TEXT
        );

        CREATE TABLE IF NOT EXISTS bundle_items (
            bundle_id TEXT NOT NULL,
            file_path TEXT NOT NULL,
            PRIMARY KEY (bundle_id, file_path)
        );

        CREATE TABLE IF NOT EXISTS journal_entries (
            id TEXT PRIMARY KEY,
            txn_id TEXT NOT NULL,
            actor TEXT NOT NULL,
            action_type TEXT NOT NULL,
            target_type TEXT NOT NULL DEFAULT 'file',
            target_id TEXT NOT NULL,
            src_path TEXT NOT NULL,
            dst_path TEXT NOT NULL,
            copy_or_move TEXT NOT NULL,
            conflict_resolution TEXT NOT NULL,
            verified INTEGER NOT NULL,
            error_code TEXT,
            error_message TEXT,
            bytes_delta INTEGER NOT NULL,
            created_at REAL NOT NULL,
            undone_at REAL,
            undo_status TEXT NOT NULL DEFAULT 'active',
            undoable INTEGER NOT NULL DEFAULT 1
        );

        CREATE TABLE IF NOT EXISTS settings (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL,
            value_blob BLOB,
            updated_at REAL NOT NULL
        );

        CREATE TABLE IF NOT EXISTS rules (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            is_enabled INTEGER NOT NULL DEFAULT 1,
            match_bundle_type TEXT,
            match_scope TEXT,
            match_file_ext TEXT,
            match_name_pattern TEXT,
            match_key TEXT NOT NULL UNIQUE,
            action_kind TEXT NOT NULL,
            rename_template TEXT,
            target_folder_bookmark BLOB,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            matched_count INTEGER NOT NULL DEFAULT 0,
            applied_count INTEGER NOT NULL DEFAULT 0
        );

        CREATE TABLE IF NOT EXISTS metrics_weekly (
            week_start REAL PRIMARY KEY,
            week_key TEXT NOT NULL,
            weekly_confirm_count INTEGER NOT NULL DEFAULT 0,
            confirmed_files_total INTEGER NOT NULL DEFAULT 0,
            undo_count INTEGER NOT NULL DEFAULT 0,
            autopilot_isolated_bytes INTEGER NOT NULL DEFAULT 0,
            pending_bundles INTEGER NOT NULL DEFAULT 0,
            missing_skipped_count INTEGER NOT NULL DEFAULT 0,
            time_to_zero_inbox_days REAL,
            updated_at REAL NOT NULL
        );

        CREATE TABLE IF NOT EXISTS app_events (
            id TEXT PRIMARY KEY,
            created_at REAL NOT NULL,
            event_type TEXT NOT NULL,
            message TEXT NOT NULL,
            payload_json TEXT
        );

        CREATE TABLE IF NOT EXISTS pdf_text_index (
            file_path TEXT PRIMARY KEY,
            modified_at REAL NOT NULL,
            indexed_at REAL NOT NULL,
            title TEXT,
            snippet TEXT
        );

        CREATE TABLE IF NOT EXISTS file_ai (
            file_path TEXT PRIMARY KEY,
            category TEXT NOT NULL,
            summary TEXT NOT NULL,
            suggested_folder TEXT NOT NULL DEFAULT '',
            keep_or_delete TEXT NOT NULL DEFAULT 'unsure',
            reason TEXT NOT NULL DEFAULT '',
            confidence REAL NOT NULL DEFAULT 0.0,
            analyzed_at REAL NOT NULL
        );

        CREATE VIRTUAL TABLE IF NOT EXISTS pdf_text_fts USING fts5(
            file_path UNINDEXED,
            title,
            body,
            tokenize = 'unicode61 remove_diacritics 2'
        );

        CREATE INDEX IF NOT EXISTS idx_files_scope ON files(root_scope);
        CREATE INDEX IF NOT EXISTS idx_files_size ON files(size_bytes);
        CREATE INDEX IF NOT EXISTS idx_files_sha ON files(sha256);
        CREATE INDEX IF NOT EXISTS idx_files_modified ON files(modified_at);
        CREATE INDEX IF NOT EXISTS idx_pdf_text_index_modified ON pdf_text_index(modified_at DESC);
        CREATE INDEX IF NOT EXISTS idx_file_ai_analyzed_at ON file_ai(analyzed_at DESC);
        CREATE INDEX IF NOT EXISTS idx_bundles_status ON bundles(status);
        CREATE INDEX IF NOT EXISTS idx_bundles_created ON bundles(created_at);
        CREATE INDEX IF NOT EXISTS idx_bundle_items_bundle ON bundle_items(bundle_id);
        CREATE INDEX IF NOT EXISTS idx_journal_created ON journal_entries(created_at);
        CREATE INDEX IF NOT EXISTS idx_journal_txn ON journal_entries(txn_id);
        CREATE INDEX IF NOT EXISTS idx_rules_enabled ON rules(is_enabled);
        CREATE INDEX IF NOT EXISTS idx_rules_updated ON rules(updated_at);
        CREATE INDEX IF NOT EXISTS idx_metrics_week_start ON metrics_weekly(week_start DESC);
        CREATE INDEX IF NOT EXISTS idx_events_created ON app_events(created_at DESC);
        """

        try execute(sql: schema)

        // Forward-compatible migration for older DBs created by earlier MVP revisions.
        try ensureColumn(
            table: "bundles",
            column: "action_kind",
            definition: "TEXT NOT NULL DEFAULT 'rename'"
        )
        try ensureColumn(table: "bundles", column: "rename_template", definition: "TEXT")
        try ensureColumn(table: "bundles", column: "target_folder_bookmark", definition: "BLOB")
        try ensureColumn(table: "bundles", column: "snoozed_until", definition: "REAL")
        try ensureColumn(table: "bundles", column: "matched_rule_id", definition: "TEXT")
        try ensureColumn(table: "files", column: "content_hash", definition: "TEXT")
        try ensureColumn(table: "journal_entries", column: "target_type", definition: "TEXT NOT NULL DEFAULT 'file'")
        try ensureColumn(table: "journal_entries", column: "undoable", definition: "INTEGER NOT NULL DEFAULT 1")
        try ensureColumn(table: "settings", column: "value_blob", definition: "BLOB")
        try ensureColumn(table: "metrics_weekly", column: "missing_skipped_count", definition: "INTEGER NOT NULL DEFAULT 0")
        try execute(sql: "UPDATE files SET content_hash = sha256 WHERE (content_hash IS NULL OR content_hash = '') AND sha256 IS NOT NULL AND sha256 != ''")
        try execute(sql: "CREATE INDEX IF NOT EXISTS idx_files_content_hash ON files(content_hash)")
        try execute(sql: "PRAGMA user_version = \(schemaVersion)")
    }

    private static func defaultDatabaseURL() throws -> URL {
        let fm = FileManager.default
        let appSupport = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Tidy2", isDirectory: true)
        try fm.createDirectory(at: appSupport, withIntermediateDirectories: true)
        return appSupport.appendingPathComponent("tidy2.sqlite")
    }

    private func ensureColumn(table: String, column: String, definition: String) throws {
        if try hasColumn(table: table, column: column) {
            return
        }
        try execute(sql: "ALTER TABLE \(table) ADD COLUMN \(column) \(definition)")
    }

    private func hasColumn(table: String, column: String) throws -> Bool {
        let sql = "PRAGMA table_info(\(table))"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        try prepare(sql: sql, stmt: &stmt)

        while sqlite3_step(stmt) == SQLITE_ROW {
            let name = columnText(stmt, index: 1) ?? ""
            if name == column {
                return true
            }
        }
        return false
    }

    // MARK: - Authorized roots

    func saveAuthorizedRoot(scope: RootScope, path: String, bookmark: Data) throws {
        try syncOnQueue {
            let sql = """
            INSERT INTO authorized_roots(scope, path, bookmark, granted_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(scope) DO UPDATE SET
                path = excluded.path,
                bookmark = excluded.bookmark,
                granted_at = excluded.granted_at
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)
            try bindText(scope.rawValue, index: 1, stmt: stmt)
            try bindText(path, index: 2, stmt: stmt)
            try bindBlob(bookmark, index: 3, stmt: stmt)
            sqlite3_bind_double(stmt, 4, Date().timeIntervalSince1970)
            try stepDone(stmt)
        }
    }

    func loadAuthorizedRoot(scope: RootScope) throws -> AuthorizedRootRecord? {
        try syncOnQueue {
            let sql = "SELECT scope, path, bookmark FROM authorized_roots WHERE scope = ? LIMIT 1"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)
            try bindText(scope.rawValue, index: 1, stmt: stmt)

            guard sqlite3_step(stmt) == SQLITE_ROW else {
                return nil
            }
            let path = columnText(stmt, index: 1) ?? ""
            let bookmark = columnBlob(stmt, index: 2) ?? Data()
            return AuthorizedRootRecord(scope: scope, path: path, bookmark: bookmark)
        }
    }

    // MARK: - Settings

    func doubleSetting(key: String) throws -> Double? {
        try syncOnQueue {
            let sql = "SELECT value FROM settings WHERE key = ? LIMIT 1"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)
            try bindText(key, index: 1, stmt: stmt)

            guard sqlite3_step(stmt) == SQLITE_ROW else {
                return nil
            }
            guard let text = columnText(stmt, index: 0) else {
                return nil
            }
            return Double(text)
        }
    }

    func setDoubleSetting(key: String, value: Double) throws {
        try syncOnQueue {
            let sql = """
            INSERT INTO settings(key, value, value_blob, updated_at)
            VALUES (?, ?, NULL, ?)
            ON CONFLICT(key) DO UPDATE SET
                value = excluded.value,
                value_blob = excluded.value_blob,
                updated_at = excluded.updated_at
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)
            try bindText(key, index: 1, stmt: stmt)
            try bindText(String(value), index: 2, stmt: stmt)
            sqlite3_bind_double(stmt, 3, Date().timeIntervalSince1970)
            try stepDone(stmt)
        }
    }

    func stringSetting(key: String) throws -> String? {
        try syncOnQueue {
            let sql = "SELECT value FROM settings WHERE key = ? LIMIT 1"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)
            try bindText(key, index: 1, stmt: stmt)

            guard sqlite3_step(stmt) == SQLITE_ROW else {
                return nil
            }
            return columnText(stmt, index: 0)
        }
    }

    func setStringSetting(key: String, value: String) throws {
        try syncOnQueue {
            let sql = """
            INSERT INTO settings(key, value, value_blob, updated_at)
            VALUES (?, ?, NULL, ?)
            ON CONFLICT(key) DO UPDATE SET
                value = excluded.value,
                value_blob = excluded.value_blob,
                updated_at = excluded.updated_at
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)
            try bindText(key, index: 1, stmt: stmt)
            try bindText(value, index: 2, stmt: stmt)
            sqlite3_bind_double(stmt, 3, Date().timeIntervalSince1970)
            try stepDone(stmt)
        }
    }

    func blobSetting(key: String) throws -> Data? {
        try syncOnQueue {
            let sql = "SELECT value_blob FROM settings WHERE key = ? LIMIT 1"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)
            try bindText(key, index: 1, stmt: stmt)

            guard sqlite3_step(stmt) == SQLITE_ROW else {
                return nil
            }
            return columnBlob(stmt, index: 0)
        }
    }

    func setBlobSetting(key: String, value: Data) throws {
        try syncOnQueue {
            let sql = """
            INSERT INTO settings(key, value, value_blob, updated_at)
            VALUES (?, '', ?, ?)
            ON CONFLICT(key) DO UPDATE SET
                value = excluded.value,
                value_blob = excluded.value_blob,
                updated_at = excluded.updated_at
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)
            try bindText(key, index: 1, stmt: stmt)
            try bindBlob(value, index: 2, stmt: stmt)
            sqlite3_bind_double(stmt, 3, Date().timeIntervalSince1970)
            try stepDone(stmt)
        }
    }

    // MARK: - App Events

    func logEvent(eventType: String, message: String, payloadJSON: String?) throws {
        try syncOnQueue {
            let sql = """
            INSERT INTO app_events(id, created_at, event_type, message, payload_json)
            VALUES (?, ?, ?, ?, ?)
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)
            try bindText(UUID().uuidString, index: 1, stmt: stmt)
            sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
            try bindText(eventType, index: 3, stmt: stmt)
            try bindText(message, index: 4, stmt: stmt)
            if let payloadJSON {
                try bindText(payloadJSON, index: 5, stmt: stmt)
            } else {
                sqlite3_bind_null(stmt, 5)
            }
            try stepDone(stmt)
        }
    }

    func recentEvents(limit: Int) throws -> [AppEvent] {
        try syncOnQueue {
            let sql = """
            SELECT id, created_at, event_type, message, payload_json
            FROM app_events
            ORDER BY created_at DESC
            LIMIT ?
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)
            sqlite3_bind_int(stmt, 1, Int32(limit))

            var events: [AppEvent] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                events.append(
                    AppEvent(
                        id: columnText(stmt, index: 0) ?? UUID().uuidString,
                        createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                        eventType: columnText(stmt, index: 2) ?? "unknown",
                        message: columnText(stmt, index: 3) ?? "",
                        payloadJSON: columnText(stmt, index: 4)
                    )
                )
            }
            return events
        }
    }

    // MARK: - Metrics

    func weeklyConfirmStats(weekStart: Date) throws -> WeeklyConfirmStats {
        try syncOnQueue {
            let sql = """
            SELECT COUNT(DISTINCT txn_id), COUNT(*)
            FROM journal_entries
            WHERE actor = 'user'
              AND target_type = 'bundle'
              AND action_type IN ('rename', 'move', 'quarantineCopy')
              AND verified = 1
              AND created_at >= ?
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)
            sqlite3_bind_double(stmt, 1, weekStart.timeIntervalSince1970)

            guard sqlite3_step(stmt) == SQLITE_ROW else {
                return WeeklyConfirmStats(confirmCount: 0, confirmedFilesTotal: 0)
            }
            return WeeklyConfirmStats(
                confirmCount: Int(sqlite3_column_int(stmt, 0)),
                confirmedFilesTotal: Int(sqlite3_column_int(stmt, 1))
            )
        }
    }

    func weeklyUndoCount(weekStart: Date) throws -> Int {
        try syncOnQueue {
            let sql = """
            SELECT COUNT(DISTINCT txn_id)
            FROM journal_entries
            WHERE actor = 'user'
              AND target_type = 'bundle'
              AND action_type IN ('rename', 'move', 'quarantineCopy')
              AND undo_status = 'undone'
              AND undone_at IS NOT NULL
              AND created_at >= ?
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)
            sqlite3_bind_double(stmt, 1, weekStart.timeIntervalSince1970)
            guard sqlite3_step(stmt) == SQLITE_ROW else {
                return 0
            }
            return Int(sqlite3_column_int(stmt, 0))
        }
    }

    func weeklyAutopilotIsolatedBytes(weekStart: Date) throws -> Int64 {
        try syncOnQueue {
            let sql = """
            SELECT COALESCE(SUM(bytes_delta), 0)
            FROM journal_entries
            WHERE actor = 'autopilot'
              AND action_type = 'quarantineCopy'
              AND verified = 1
              AND undone_at IS NULL
              AND created_at >= ?
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)
            sqlite3_bind_double(stmt, 1, weekStart.timeIntervalSince1970)
            guard sqlite3_step(stmt) == SQLITE_ROW else {
                return 0
            }
            return sqlite3_column_int64(stmt, 0)
        }
    }

    func weeklyMissingSkippedCount(weekStart: Date) throws -> Int {
        try syncOnQueue {
            let sql = """
            SELECT COUNT(*)
            FROM journal_entries
            WHERE actor = 'user'
              AND target_type = 'bundle'
              AND verified = 0
              AND error_code = 'SKIPPED_MISSING'
              AND created_at >= ?
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)
            sqlite3_bind_double(stmt, 1, weekStart.timeIntervalSince1970)
            guard sqlite3_step(stmt) == SQLITE_ROW else {
                return 0
            }
            return Int(sqlite3_column_int(stmt, 0))
        }
    }

    func upsertWeeklyMetrics(row: WeeklyMetricsRow, updatedAt: Date) throws {
        try syncOnQueue {
            let sql = """
            INSERT INTO metrics_weekly(
                week_start, week_key, weekly_confirm_count, confirmed_files_total,
                undo_count, autopilot_isolated_bytes, pending_bundles,
                missing_skipped_count, time_to_zero_inbox_days, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(week_start) DO UPDATE SET
                week_key = excluded.week_key,
                weekly_confirm_count = excluded.weekly_confirm_count,
                confirmed_files_total = excluded.confirmed_files_total,
                undo_count = excluded.undo_count,
                autopilot_isolated_bytes = excluded.autopilot_isolated_bytes,
                pending_bundles = excluded.pending_bundles,
                missing_skipped_count = excluded.missing_skipped_count,
                time_to_zero_inbox_days = excluded.time_to_zero_inbox_days,
                updated_at = excluded.updated_at
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)
            sqlite3_bind_double(stmt, 1, row.weekStart.timeIntervalSince1970)
            try bindText(row.weekKey, index: 2, stmt: stmt)
            sqlite3_bind_int(stmt, 3, Int32(row.weeklyConfirmCount))
            sqlite3_bind_int(stmt, 4, Int32(row.confirmedFilesTotal))
            sqlite3_bind_int(stmt, 5, Int32(row.undoCount))
            sqlite3_bind_int64(stmt, 6, row.autopilotIsolatedBytes)
            sqlite3_bind_int(stmt, 7, Int32(row.pendingBundles))
            sqlite3_bind_int(stmt, 8, Int32(row.missingSkippedCount))
            if let days = row.timeToZeroInboxDays {
                sqlite3_bind_double(stmt, 9, days)
            } else {
                sqlite3_bind_null(stmt, 9)
            }
            sqlite3_bind_double(stmt, 10, updatedAt.timeIntervalSince1970)
            try stepDone(stmt)
        }
    }

    func recentWeeklyMetrics(limit: Int) throws -> [WeeklyMetricsRow] {
        try syncOnQueue {
            let sql = """
            SELECT week_start, week_key, weekly_confirm_count, confirmed_files_total,
                   undo_count, autopilot_isolated_bytes, pending_bundles, missing_skipped_count, time_to_zero_inbox_days
            FROM metrics_weekly
            ORDER BY week_start DESC
            LIMIT ?
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)
            sqlite3_bind_int(stmt, 1, Int32(limit))

            var rows: [WeeklyMetricsRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let weekStart = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0))
                let weekKey = columnText(stmt, index: 1) ?? DateFormatter.metricsWeekKey.string(from: weekStart)
                let timeToZero: Double?
                if sqlite3_column_type(stmt, 8) == SQLITE_NULL {
                    timeToZero = nil
                } else {
                    timeToZero = sqlite3_column_double(stmt, 8)
                }
                rows.append(
                    WeeklyMetricsRow(
                        weekKey: weekKey,
                        weekStart: weekStart,
                        weeklyConfirmCount: Int(sqlite3_column_int(stmt, 2)),
                        confirmedFilesTotal: Int(sqlite3_column_int(stmt, 3)),
                        undoCount: Int(sqlite3_column_int(stmt, 4)),
                        autopilotIsolatedBytes: sqlite3_column_int64(stmt, 5),
                        pendingBundles: Int(sqlite3_column_int(stmt, 6)),
                        missingSkippedCount: Int(sqlite3_column_int(stmt, 7)),
                        timeToZeroInboxDays: timeToZero
                    )
                )
            }
            return rows
        }
    }

    // MARK: - Rules

    func listRules() throws -> [UserRule] {
        try syncOnQueue {
            let sql = """
            SELECT id, name, is_enabled, match_bundle_type, match_scope, match_file_ext, match_name_pattern,
                   action_kind, rename_template, target_folder_bookmark, created_at, updated_at, matched_count, applied_count
            FROM rules
            ORDER BY updated_at DESC
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)

            var rules: [UserRule] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                rules.append(readRule(stmt: stmt))
            }
            return rules
        }
    }

    func listEnabledRules() throws -> [UserRule] {
        try syncOnQueue {
            let sql = """
            SELECT id, name, is_enabled, match_bundle_type, match_scope, match_file_ext, match_name_pattern,
                   action_kind, rename_template, target_folder_bookmark, created_at, updated_at, matched_count, applied_count
            FROM rules
            WHERE is_enabled = 1
            ORDER BY updated_at DESC
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)

            var rules: [UserRule] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                rules.append(readRule(stmt: stmt))
            }
            return rules
        }
    }

    func upsertLearnedRule(name: String,
                           match: RuleMatch,
                           action: BundleActionConfig,
                           now: Date) throws -> String {
        try syncOnQueue {
            let matchKey = makeRuleMatchKey(match: match)
            let sql = """
            INSERT INTO rules(
                id, name, is_enabled, match_bundle_type, match_scope, match_file_ext, match_name_pattern, match_key,
                action_kind, rename_template, target_folder_bookmark,
                created_at, updated_at, matched_count, applied_count
            ) VALUES (?, ?, 1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, 0)
            ON CONFLICT(match_key) DO UPDATE SET
                name = excluded.name,
                is_enabled = 1,
                action_kind = excluded.action_kind,
                rename_template = excluded.rename_template,
                target_folder_bookmark = COALESCE(excluded.target_folder_bookmark, rules.target_folder_bookmark),
                updated_at = excluded.updated_at
            """
            let newID = UUID().uuidString
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)
            try bindText(newID, index: 1, stmt: stmt)
            try bindText(name, index: 2, stmt: stmt)
            if let bundleType = match.bundleType {
                try bindText(bundleType.rawValue, index: 3, stmt: stmt)
            } else {
                sqlite3_bind_null(stmt, 3)
            }
            if let scope = match.scope {
                try bindText(scope.rawValue, index: 4, stmt: stmt)
            } else {
                sqlite3_bind_null(stmt, 4)
            }
            if let ext = match.fileExt, !ext.isEmpty {
                try bindText(ext.lowercased(), index: 5, stmt: stmt)
            } else {
                sqlite3_bind_null(stmt, 5)
            }
            if let pattern = match.namePattern, !pattern.isEmpty {
                try bindText(pattern.lowercased(), index: 6, stmt: stmt)
            } else {
                sqlite3_bind_null(stmt, 6)
            }
            try bindText(matchKey, index: 7, stmt: stmt)
            try bindText(action.actionKind.rawValue, index: 8, stmt: stmt)
            if let template = action.renameTemplate, !template.isEmpty {
                try bindText(template, index: 9, stmt: stmt)
            } else {
                sqlite3_bind_null(stmt, 9)
            }
            if let bookmark = action.targetFolderBookmark {
                try bindBlob(bookmark, index: 10, stmt: stmt)
            } else {
                sqlite3_bind_null(stmt, 10)
            }
            sqlite3_bind_double(stmt, 11, now.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 12, now.timeIntervalSince1970)
            try stepDone(stmt)

            return try resolveRuleIDByMatchKey(matchKey: matchKey, fallback: newID)
        }
    }

    func setRuleEnabled(id: String, isEnabled: Bool) throws {
        try syncOnQueue {
            let sql = """
            UPDATE rules
            SET is_enabled = ?, updated_at = ?
            WHERE id = ?
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)
            sqlite3_bind_int(stmt, 1, isEnabled ? 1 : 0)
            sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
            try bindText(id, index: 3, stmt: stmt)
            try stepDone(stmt)
        }
    }

    func deleteRule(id: String) throws {
        try syncOnQueue {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: "DELETE FROM rules WHERE id = ?", stmt: &stmt)
            try bindText(id, index: 1, stmt: stmt)
            try stepDone(stmt)
        }
    }

    func updateRuleTargetFolder(id: String, bookmark: Data?) throws {
        try syncOnQueue {
            let sql = """
            UPDATE rules
            SET target_folder_bookmark = ?, updated_at = ?
            WHERE id = ?
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)
            if let bookmark {
                try bindBlob(bookmark, index: 1, stmt: stmt)
            } else {
                sqlite3_bind_null(stmt, 1)
            }
            sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
            try bindText(id, index: 3, stmt: stmt)
            try stepDone(stmt)
        }
    }

    func loadRule(id: String) throws -> UserRule? {
        try syncOnQueue {
            let sql = """
            SELECT id, name, is_enabled, match_bundle_type, match_scope, match_file_ext, match_name_pattern,
                   action_kind, rename_template, target_folder_bookmark, created_at, updated_at, matched_count, applied_count
            FROM rules
            WHERE id = ?
            LIMIT 1
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)
            try bindText(id, index: 1, stmt: stmt)
            guard sqlite3_step(stmt) == SQLITE_ROW else {
                return nil
            }
            return readRule(stmt: stmt)
        }
    }

    func latestRuleUpdatedAfter(timestamp: Double) throws -> UserRule? {
        try syncOnQueue {
            let sql = """
            SELECT id, name, is_enabled, match_bundle_type, match_scope, match_file_ext, match_name_pattern,
                   action_kind, rename_template, target_folder_bookmark, created_at, updated_at, matched_count, applied_count
            FROM rules
            WHERE updated_at > ?
            ORDER BY updated_at DESC
            LIMIT 1
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)
            sqlite3_bind_double(stmt, 1, timestamp)
            guard sqlite3_step(stmt) == SQLITE_ROW else {
                return nil
            }
            return readRule(stmt: stmt)
        }
    }

    func dryRunPendingBundles(ruleID: String, now: Date, limit: Int) throws -> [RuleDryRunItem] {
        try syncOnQueue {
            let weekStart = DateHelper.startOfCurrentWeek(now: now)
            let sql = """
            SELECT b.id, b.title, COUNT(bi.file_path) AS file_count
            FROM rules r
            JOIN bundles b ON 1 = 1
            JOIN bundle_items bi ON bi.bundle_id = b.id
            WHERE r.id = ?
              AND (
                    b.status = 'pending'
                    OR (
                        b.status = 'skipped'
                        AND (b.snoozed_until IS NULL OR b.snoozed_until <= ?)
                    )
                  )
              AND b.created_at >= ?
              AND (r.match_bundle_type IS NULL OR b.type = r.match_bundle_type)
              AND (r.match_scope IS NULL OR b.id LIKE r.match_scope || '-%')
              AND (
                    r.match_file_ext IS NULL
                    OR EXISTS (
                        SELECT 1
                        FROM bundle_items bx
                        WHERE bx.bundle_id = b.id
                          AND LOWER(bx.file_path) LIKE '%.' || LOWER(r.match_file_ext)
                    )
                  )
              AND (
                    r.match_name_pattern IS NULL
                    OR EXISTS (
                        SELECT 1
                        FROM bundle_items by
                        WHERE by.bundle_id = b.id
                          AND LOWER(by.file_path) LIKE '%' || LOWER(r.match_name_pattern) || '%'
                    )
                  )
            GROUP BY b.id, b.title
            ORDER BY file_count DESC, b.created_at DESC
            LIMIT ?
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)
            try bindText(ruleID, index: 1, stmt: stmt)
            sqlite3_bind_double(stmt, 2, now.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 3, weekStart.timeIntervalSince1970)
            sqlite3_bind_int(stmt, 4, Int32(limit))

            var items: [RuleDryRunItem] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                items.append(
                    RuleDryRunItem(
                        id: columnText(stmt, index: 0) ?? UUID().uuidString,
                        title: columnText(stmt, index: 1) ?? "Untitled bundle",
                        fileCount: Int(sqlite3_column_int(stmt, 2))
                    )
                )
            }
            return items
        }
    }

    func incrementRuleMatchedCount(ruleID: String) throws {
        try syncOnQueue {
            let sql = """
            UPDATE rules
            SET matched_count = matched_count + 1,
                updated_at = ?
            WHERE id = ?
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)
            sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
            try bindText(ruleID, index: 2, stmt: stmt)
            try stepDone(stmt)
        }
    }

    func missingOriginalFilesCount() throws -> Int {
        do {
            return try syncOnQueue {
                try missingOriginalFilesCountUnlocked()
            }
        } catch {
            print("[SQLiteStore] missingOriginalFilesCount fallback to 0: \(error.localizedDescription)")
            return 0
        }
    }

    func appRelatedMissingOriginalFilesCount() throws -> Int {
        do {
            return try syncOnQueue {
                try appRelatedMissingOriginalFilesCountUnlocked()
            }
        } catch {
            print("[SQLiteStore] appRelatedMissingOriginalFilesCount fallback to 0: \(error.localizedDescription)")
            return 0
        }
    }

    func lowPriorityMissingOriginalFilesCount() throws -> Int {
        do {
            return try syncOnQueue {
                let total = try missingOriginalFilesCountUnlocked()
                let appRelated = try appRelatedMissingOriginalFilesCountUnlocked()
                return max(0, total - appRelated)
            }
        } catch {
            print("[SQLiteStore] lowPriorityMissingOriginalFilesCount fallback to 0: \(error.localizedDescription)")
            return 0
        }
    }

    func repairFileMissingStatus() throws -> Int {
        try syncOnQueue {
            let sql = """
            SELECT path, root_scope, status
            FROM files
            WHERE status IN ('active', 'archived', 'missing')
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)

            let fm = FileManager.default
            var updates: [(path: String, status: String)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let path = columnText(stmt, index: 0) ?? ""
                let scope = columnText(stmt, index: 1) ?? RootScope.downloads.rawValue
                let status = columnText(stmt, index: 2) ?? FileStatus.active.rawValue
                guard !path.isEmpty else { continue }

                let exists = fm.fileExists(atPath: path)
                if exists {
                    if status == FileStatus.missing.rawValue {
                        let restored = scope == RootScope.archived.rawValue ? FileStatus.archived.rawValue : FileStatus.active.rawValue
                        updates.append((path: path, status: restored))
                    }
                } else if status != FileStatus.missing.rawValue {
                    updates.append((path: path, status: FileStatus.missing.rawValue))
                }
            }

            guard !updates.isEmpty else {
                return try missingOriginalFilesCountUnlocked()
            }

            let updateSQL = "UPDATE files SET status = ?, last_seen_at = ? WHERE path = ?"
            var updateStmt: OpaquePointer?
            defer { sqlite3_finalize(updateStmt) }
            try prepare(sql: updateSQL, stmt: &updateStmt)
            let now = Date().timeIntervalSince1970
            for update in updates {
                sqlite3_reset(updateStmt)
                sqlite3_clear_bindings(updateStmt)
                try bindText(update.status, index: 1, stmt: updateStmt)
                sqlite3_bind_double(updateStmt, 2, now)
                try bindText(update.path, index: 3, stmt: updateStmt)
                try stepDone(updateStmt)
            }

            return try missingOriginalFilesCountUnlocked()
        }
    }

    private func missingOriginalFilesCountUnlocked() throws -> Int {
        let sql = "SELECT COUNT(*) FROM files WHERE status = 'missing'"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        try prepare(sql: sql, stmt: &stmt)
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return 0
        }
        return Int(sqlite3_column_int(stmt, 0))
    }

    private func appRelatedMissingOriginalFilesCountUnlocked() throws -> Int {
        let sql = """
        SELECT COUNT(DISTINCT f.path)
        FROM files f
        JOIN (
            SELECT DISTINCT src_path
            FROM journal_entries
            WHERE action_type = 'quarantineCopy'
              AND verified = 1
              AND undone_at IS NULL
              AND src_path <> ''
        ) j ON j.src_path = f.path
        WHERE f.status = 'missing'
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        try prepare(sql: sql, stmt: &stmt)
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return 0
        }
        return Int(sqlite3_column_int(stmt, 0))
    }

    func incrementRuleAppliedCount(ruleID: String) throws {
        try syncOnQueue {
            let sql = """
            UPDATE rules
            SET applied_count = applied_count + 1,
                updated_at = ?
            WHERE id = ?
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)
            sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
            try bindText(ruleID, index: 2, stmt: stmt)
            try stepDone(stmt)
        }
    }

    // MARK: - Files

    func upsertFile(path: String,
                    rootScope: RootScope,
                    name: String,
                    ext: String,
                    sizeBytes: Int64,
                    modifiedAt: Date,
                    lastSeenAt: Date) throws {
        let contentHash: String?
        if sizeBytes >= duplicateHashMinimumSizeBytes {
            contentHash = try? FileHash.sha256(for: URL(fileURLWithPath: path))
        } else {
            contentHash = nil
        }

        try syncOnQueue {
            let sql = """
            INSERT INTO files(id, path, root_scope, name, ext, size_bytes, modified_at, last_seen_at, sha256, content_hash, status)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'active')
            ON CONFLICT(path) DO UPDATE SET
                root_scope = excluded.root_scope,
                name = excluded.name,
                ext = excluded.ext,
                size_bytes = excluded.size_bytes,
                modified_at = excluded.modified_at,
                last_seen_at = excluded.last_seen_at,
                sha256 = COALESCE(excluded.sha256, files.sha256),
                content_hash = COALESCE(excluded.content_hash, files.content_hash),
                status = 'active'
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)
            try bindText(UUID().uuidString, index: 1, stmt: stmt)
            try bindText(path, index: 2, stmt: stmt)
            try bindText(rootScope.rawValue, index: 3, stmt: stmt)
            try bindText(name, index: 4, stmt: stmt)
            try bindText(ext, index: 5, stmt: stmt)
            sqlite3_bind_int64(stmt, 6, sizeBytes)
            sqlite3_bind_double(stmt, 7, modifiedAt.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 8, lastSeenAt.timeIntervalSince1970)
            if let contentHash {
                try bindText(contentHash, index: 9, stmt: stmt)
                try bindText(contentHash, index: 10, stmt: stmt)
            } else {
                sqlite3_bind_null(stmt, 9)
                sqlite3_bind_null(stmt, 10)
            }
            try stepDone(stmt)
        }
    }

    func updateFileHash(path: String, sha256: String) throws {
        try syncOnQueue {
            let sql = "UPDATE files SET sha256 = ?, content_hash = ? WHERE path = ?"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)
            try bindText(sha256, index: 1, stmt: stmt)
            try bindText(sha256, index: 2, stmt: stmt)
            try bindText(path, index: 3, stmt: stmt)
            try stepDone(stmt)
        }
    }

    func renameIndexedFile(oldPath: String, newPath: String, modifiedAt: Date, lastSeenAt: Date) throws {
        try moveIndexedFile(
            oldPath: oldPath,
            newPath: newPath,
            newScope: nil,
            modifiedAt: modifiedAt,
            lastSeenAt: lastSeenAt
        )
    }

    func moveIndexedFile(oldPath: String,
                         newPath: String,
                         newScope: RootScope?,
                         modifiedAt: Date,
                         lastSeenAt: Date) throws {
        try syncOnQueue {
            try updateIndexedFilePathInternal(
                oldPath: oldPath,
                newPath: newPath,
                newScope: newScope,
                modifiedAt: modifiedAt,
                lastSeenAt: lastSeenAt
            )
        }
    }

    func listFiles(scope: RootScope) throws -> [IndexedFile] {
        try syncOnQueue {
            let status = scope == .archived ? FileStatus.archived.rawValue : FileStatus.active.rawValue
            let sql = """
            SELECT id, path, root_scope, name, ext, size_bytes, modified_at, last_seen_at, sha256
            FROM files
            WHERE root_scope = ? AND status = ?
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)
            try bindText(scope.rawValue, index: 1, stmt: stmt)
            try bindText(status, index: 2, stmt: stmt)

            var files: [IndexedFile] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                files.append(readIndexedFile(stmt: stmt))
            }
            return files
        }
    }

    func fileByPath(_ path: String) throws -> IndexedFile? {
        try syncOnQueue {
            let sql = """
            SELECT id, path, root_scope, name, ext, size_bytes, modified_at, last_seen_at,
                   COALESCE(NULLIF(content_hash, ''), sha256)
            FROM files
            WHERE path = ?
            LIMIT 1
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)
            try bindText(path, index: 1, stmt: stmt)

            guard sqlite3_step(stmt) == SQLITE_ROW else {
                return nil
            }
            return readIndexedFile(stmt: stmt)
        }
    }

    func filePath(fileID: String) throws -> String? {
        try syncOnQueue {
            let sql = "SELECT path FROM files WHERE id = ? LIMIT 1"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)
            try bindText(fileID, index: 1, stmt: stmt)
            guard sqlite3_step(stmt) == SQLITE_ROW else {
                return nil
            }
            return columnText(stmt, index: 0)
        }
    }

    func fileID(path: String) throws -> String? {
        try syncOnQueue {
            let sql = "SELECT id FROM files WHERE path = ? LIMIT 1"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)
            try bindText(path, index: 1, stmt: stmt)
            guard sqlite3_step(stmt) == SQLITE_ROW else {
                return nil
            }
            return columnText(stmt, index: 0)
        }
    }

    func filePaths(scope: RootScope, underDirectory directoryPath: String, statuses: [FileStatus]) throws -> [String] {
        try syncOnQueue {
            guard !statuses.isEmpty else { return [] }
            let placeholders = statuses.map { _ in "?" }.joined(separator: ",")
            let sql = """
            SELECT path
            FROM files
            WHERE root_scope = ?
              AND path LIKE ?
              AND status IN (\(placeholders))
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)
            try bindText(scope.rawValue, index: 1, stmt: stmt)
            let prefix = directoryPath.hasSuffix("/") ? directoryPath : directoryPath + "/"
            try bindText(prefix + "%", index: 2, stmt: stmt)

            var index: Int32 = 3
            for status in statuses {
                try bindText(status.rawValue, index: index, stmt: stmt)
                index += 1
            }

            var paths: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                paths.append(columnText(stmt, index: 0) ?? "")
            }
            return paths
        }
    }

    func updateFileStatus(path: String, status: FileStatus, lastSeenAt: Date) throws {
        try syncOnQueue {
            let sql = """
            UPDATE files
            SET status = ?, last_seen_at = ?
            WHERE path = ?
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)
            try bindText(status.rawValue, index: 1, stmt: stmt)
            sqlite3_bind_double(stmt, 2, lastSeenAt.timeIntervalSince1970)
            try bindText(path, index: 3, stmt: stmt)
            try stepDone(stmt)
        }
    }

    // MARK: - PDF text index

    func pdfContentIndexModifiedAt(path: String) throws -> Date? {
        try syncOnQueue {
            let sql = "SELECT modified_at FROM pdf_text_index WHERE file_path = ? LIMIT 1"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)
            try bindText(path, index: 1, stmt: stmt)
            guard sqlite3_step(stmt) == SQLITE_ROW else {
                return nil
            }
            return Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0))
        }
    }

    func listPDFFilesMissingContentIndex(scope: RootScope, limit: Int) throws -> [PDFIndexCandidate] {
        try syncOnQueue {
            let sql = """
            SELECT f.path, f.modified_at
            FROM files f
            LEFT JOIN pdf_text_index p ON p.file_path = f.path
            WHERE f.status = 'active'
              AND f.root_scope = ?
              AND f.ext = 'pdf'
              AND (p.file_path IS NULL OR p.modified_at + 0.0001 < f.modified_at)
            ORDER BY f.modified_at DESC
            LIMIT ?
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)
            try bindText(scope.rawValue, index: 1, stmt: stmt)
            sqlite3_bind_int(stmt, 2, Int32(limit))

            var candidates: [PDFIndexCandidate] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let path = columnText(stmt, index: 0) ?? ""
                let modifiedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
                if !path.isEmpty {
                    candidates.append(PDFIndexCandidate(path: path, modifiedAt: modifiedAt))
                }
            }
            return candidates
        }
    }

    func upsertPDFContentIndex(path: String,
                               modifiedAt: Date,
                               title: String?,
                               snippet: String?,
                               body: String) throws {
        try syncOnQueue {
            if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try removePDFContentIndexUnlocked(path: path)
                return
            }

            try beginTransaction()
            do {
                try removePDFContentIndexUnlocked(path: path)

                let ftsSQL = "INSERT INTO pdf_text_fts(file_path, title, body) VALUES (?, ?, ?)"
                var ftsStmt: OpaquePointer?
                defer { sqlite3_finalize(ftsStmt) }
                try prepare(sql: ftsSQL, stmt: &ftsStmt)
                try bindText(path, index: 1, stmt: ftsStmt)
                if let title, !title.isEmpty {
                    try bindText(title, index: 2, stmt: ftsStmt)
                } else {
                    sqlite3_bind_null(ftsStmt, 2)
                }
                try bindText(body, index: 3, stmt: ftsStmt)
                try stepDone(ftsStmt)

                let metaSQL = """
                INSERT INTO pdf_text_index(file_path, modified_at, indexed_at, title, snippet)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(file_path) DO UPDATE SET
                    modified_at = excluded.modified_at,
                    indexed_at = excluded.indexed_at,
                    title = excluded.title,
                    snippet = excluded.snippet
                """
                var metaStmt: OpaquePointer?
                defer { sqlite3_finalize(metaStmt) }
                try prepare(sql: metaSQL, stmt: &metaStmt)
                try bindText(path, index: 1, stmt: metaStmt)
                sqlite3_bind_double(metaStmt, 2, modifiedAt.timeIntervalSince1970)
                sqlite3_bind_double(metaStmt, 3, Date().timeIntervalSince1970)
                if let title, !title.isEmpty {
                    try bindText(title, index: 4, stmt: metaStmt)
                } else {
                    sqlite3_bind_null(metaStmt, 4)
                }
                if let snippet, !snippet.isEmpty {
                    try bindText(snippet, index: 5, stmt: metaStmt)
                } else {
                    sqlite3_bind_null(metaStmt, 5)
                }
                try stepDone(metaStmt)

                try commitTransaction()
            } catch {
                try? rollbackTransaction()
                throw error
            }
        }
    }

    func removePDFContentIndex(path: String) throws {
        try syncOnQueue {
            try removePDFContentIndexUnlocked(path: path)
        }
    }

    private func removePDFContentIndexUnlocked(path: String) throws {
        let deleteMetaSQL = "DELETE FROM pdf_text_index WHERE file_path = ?"
        var metaStmt: OpaquePointer?
        defer { sqlite3_finalize(metaStmt) }
        try prepare(sql: deleteMetaSQL, stmt: &metaStmt)
        try bindText(path, index: 1, stmt: metaStmt)
        try stepDone(metaStmt)

        let deleteFTSSQL = "DELETE FROM pdf_text_fts WHERE file_path = ?"
        var ftsStmt: OpaquePointer?
        defer { sqlite3_finalize(ftsStmt) }
        try prepare(sql: deleteFTSSQL, stmt: &ftsStmt)
        try bindText(path, index: 1, stmt: ftsStmt)
        try stepDone(ftsStmt)
    }

    // MARK: - File intelligence

    func upsertFileIntelligence(_ intelligence: FileIntelligence) throws {
        try syncOnQueue {
            let sql = """
            INSERT INTO file_ai(
                file_path,
                category,
                summary,
                suggested_folder,
                keep_or_delete,
                reason,
                confidence,
                analyzed_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(file_path) DO UPDATE SET
                category = excluded.category,
                summary = excluded.summary,
                suggested_folder = excluded.suggested_folder,
                keep_or_delete = excluded.keep_or_delete,
                reason = excluded.reason,
                confidence = excluded.confidence,
                analyzed_at = excluded.analyzed_at
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)
            try bindText(intelligence.filePath, index: 1, stmt: stmt)
            try bindText(intelligence.category, index: 2, stmt: stmt)
            try bindText(intelligence.summary, index: 3, stmt: stmt)
            try bindText(intelligence.suggestedFolder, index: 4, stmt: stmt)
            try bindText(intelligence.keepOrDelete.rawValue, index: 5, stmt: stmt)
            try bindText(intelligence.reason, index: 6, stmt: stmt)
            sqlite3_bind_double(stmt, 7, intelligence.confidence)
            sqlite3_bind_double(stmt, 8, intelligence.analyzedAt.timeIntervalSince1970)
            try stepDone(stmt)
        }
    }

    func loadFileIntelligence(path: String) throws -> FileIntelligence? {
        try syncOnQueue {
            let sql = """
            SELECT file_path, category, summary, suggested_folder, keep_or_delete, reason, confidence, analyzed_at
            FROM file_ai
            WHERE file_path = ?
            LIMIT 1
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)
            try bindText(path, index: 1, stmt: stmt)
            guard sqlite3_step(stmt) == SQLITE_ROW else {
                return nil
            }
            return readFileIntelligence(stmt: stmt)
        }
    }

    func fileIntelligence(for path: String) throws -> FileIntelligence? {
        try loadFileIntelligence(path: path)
    }

    func allFileIntelligence(limit: Int) throws -> [FileIntelligence] {
        try syncOnQueue {
            guard limit > 0 else { return [] }

            let sql = """
            SELECT file_path, category, summary, suggested_folder, keep_or_delete, reason, confidence, analyzed_at
            FROM file_ai
            ORDER BY analyzed_at DESC
            LIMIT ?
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)
            sqlite3_bind_int(stmt, 1, Int32(limit))

            var result: [FileIntelligence] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                result.append(readFileIntelligence(stmt: stmt))
            }
            return result
        }
    }

    func fileIntelligenceMap(for paths: [String]) throws -> [String: FileIntelligence] {
        try loadFileIntelligences(paths: Array(paths.prefix(500)))
    }

    func findDuplicateGroups(minCount: Int = 2, minSizeBytes: Int64 = 50_000) throws -> [DuplicateGroup] {
        try syncOnQueue {
            guard minCount >= 2 else { return [] }

            let groupsSQL = """
            SELECT COALESCE(NULLIF(content_hash, ''), NULLIF(sha256, '')) AS duplicate_hash,
                   COUNT(*) AS cnt,
                   MAX(size_bytes) AS max_size
            FROM files
            WHERE status = 'active'
              AND COALESCE(NULLIF(content_hash, ''), NULLIF(sha256, '')) IS NOT NULL
              AND size_bytes >= ?
            GROUP BY duplicate_hash
            HAVING cnt >= ?
            ORDER BY cnt DESC, max_size DESC
            LIMIT 200
            """
            var groupsStmt: OpaquePointer?
            defer { sqlite3_finalize(groupsStmt) }
            try prepare(sql: groupsSQL, stmt: &groupsStmt)
            sqlite3_bind_int64(groupsStmt, 1, minSizeBytes)
            sqlite3_bind_int(groupsStmt, 2, Int32(minCount))

            var hashes: [String] = []
            while sqlite3_step(groupsStmt) == SQLITE_ROW {
                if let hash = columnText(groupsStmt, index: 0), !hash.isEmpty {
                    hashes.append(hash)
                }
            }

            guard !hashes.isEmpty else { return [] }

            let filesSQL = """
            SELECT id, path, root_scope, name, ext, size_bytes, modified_at, last_seen_at,
                   COALESCE(NULLIF(content_hash, ''), sha256)
            FROM files
            WHERE status = 'active'
              AND COALESCE(NULLIF(content_hash, ''), NULLIF(sha256, '')) = ?
            ORDER BY modified_at DESC, path ASC
            """

            var result: [DuplicateGroup] = []
            for hash in hashes {
                var files: [IndexedFile] = []
                do {
                    var filesStmt: OpaquePointer?
                    defer { sqlite3_finalize(filesStmt) }
                    try prepare(sql: filesSQL, stmt: &filesStmt)
                    try bindText(hash, index: 1, stmt: filesStmt)

                    while sqlite3_step(filesStmt) == SQLITE_ROW {
                        files.append(readIndexedFile(stmt: filesStmt))
                    }
                }

                guard files.count >= minCount else { continue }
                result.append(DuplicateGroup(id: hash, contentHash: hash, files: files))
            }

            return result
        }
    }

    func loadFileIntelligences(paths: [String]) throws -> [String: FileIntelligence] {
        try syncOnQueue {
            guard !paths.isEmpty else { return [:] }
            let placeholders = paths.map { _ in "?" }.joined(separator: ",")
            let sql = """
            SELECT file_path, category, summary, suggested_folder, keep_or_delete, reason, confidence, analyzed_at
            FROM file_ai
            WHERE file_path IN (\(placeholders))
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)
            var index: Int32 = 1
            for path in paths {
                try bindText(path, index: index, stmt: stmt)
                index += 1
            }

            var result: [String: FileIntelligence] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                let intelligence = readFileIntelligence(stmt: stmt)
                result[intelligence.filePath] = intelligence
            }
            return result
        }
    }

    func pathsNeedingAnalysis(limit: Int = 500) throws -> [String] {
        try syncOnQueue {
            let sql = """
            SELECT f.path
            FROM files f
            LEFT JOIN file_ai ai ON ai.file_path = f.path
            WHERE f.status = 'active'
              AND f.path != ''
              AND f.name != '.DS_Store'
              AND (ai.file_path IS NULL OR ai.analyzed_at <= f.modified_at)
            ORDER BY
              CASE WHEN ai.file_path IS NULL THEN 0 ELSE 1 END,
              f.modified_at DESC,
              f.path ASC
            LIMIT ?
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)
            sqlite3_bind_int(stmt, 1, Int32(limit))

            var paths: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let path = columnText(stmt, index: 0) {
                    paths.append(path)
                }
            }
            return paths
        }
    }

    func countAnalyzedFiles() throws -> Int {
        try syncOnQueue {
            let sql = "SELECT COUNT(*) FROM file_ai"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)
            guard sqlite3_step(stmt) == SQLITE_ROW else {
                return 0
            }
            return Int(sqlite3_column_int(stmt, 0))
        }
    }

    func totalFileCount() throws -> Int {
        try syncOnQueue {
            let sql = "SELECT COUNT(*) FROM files"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)
            guard sqlite3_step(stmt) == SQLITE_ROW else {
                return 0
            }
            return Int(sqlite3_column_int(stmt, 0))
        }
    }

    func largeFiles(minSizeBytes: Int64 = 50_000_000, limit: Int = 50) throws -> [IndexedFile] {
        try syncOnQueue {
            guard limit > 0 else { return [] }
            let sql = """
            SELECT id, path, root_scope, name, ext, size_bytes, modified_at, last_seen_at,
                   COALESCE(NULLIF(content_hash, ''), sha256)
            FROM files
            WHERE status = 'active'
              AND size_bytes > ?
            ORDER BY size_bytes DESC, modified_at DESC
            LIMIT ?
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)
            sqlite3_bind_int64(stmt, 1, minSizeBytes)
            sqlite3_bind_int(stmt, 2, Int32(limit))

            var files: [IndexedFile] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                files.append(readIndexedFile(stmt: stmt))
            }
            return files
        }
    }

    // MARK: - Version file groups (near-duplicates with different names)

    func versionFileGroups(limit: Int = 50) throws -> [VersionFileGroup] {
        // Load all active files with a real extension
        let files: [IndexedFile] = try syncOnQueue {
            let sql = """
            SELECT id, path, root_scope, name, ext, size_bytes, modified_at, last_seen_at,
                   COALESCE(NULLIF(content_hash,''),sha256)
            FROM files
            WHERE status = 'active'
              AND ext != ''
              AND size_bytes > 1024
            ORDER BY name
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)
            var result: [IndexedFile] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                result.append(readIndexedFile(stmt: stmt))
            }
            return result
        }

        // Group by (normalizedStem + "." + lowercased ext) within same parent folder
        var groupMap: [String: [IndexedFile]] = [:]
        for file in files {
            let url = URL(fileURLWithPath: file.path)
            let parent = url.deletingLastPathComponent().path
            let ext = url.pathExtension.lowercased()
            guard !ext.isEmpty else { continue }
            let stem = url.deletingPathExtension().lastPathComponent
            let normalized = SQLiteStore.normalizeVersionStem(stem)
            let key = "\(parent)|\(normalized).\(ext)"
            groupMap[key, default: []].append(file)
        }

        // Keep groups of 2+ files, sort newest first within each group
        var groups: [VersionFileGroup] = []
        for (_, members) in groupMap where members.count >= 2 {
            let sorted = members.sorted { $0.modifiedAt > $1.modifiedAt }
            let groupID = sorted.first?.path ?? UUID().uuidString
            let baseName = URL(fileURLWithPath: sorted.first?.path ?? "").lastPathComponent
            let wasted = sorted.dropFirst().reduce(Int64(0)) { $0 + $1.sizeBytes }
            groups.append(VersionFileGroup(id: groupID, baseName: baseName,
                                           files: sorted, wastedBytes: wasted))
        }

        return groups
            .sorted { $0.wastedBytes > $1.wastedBytes }
            .prefix(limit)
            .map { $0 }
    }

    private static func normalizeVersionStem(_ stem: String) -> String {
        var s = stem

        // Strip trailing patterns: space + (N), (N) with N 1-9
        let parenPatterns = [#" \(\d+\)$"#, #"\(\d+\)$"#]
        for pattern in parenPatterns {
            if let range = s.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                s = String(s[s.startIndex..<range.lowerBound])
            }
        }

        // Strip common version suffixes (Chinese + English)
        let suffixes = [
            " 副本", "_副本", " copy", "_copy",
            "_new", " new", "_final", " final",
            "_backup", "_bak", "_old",
            "_v2", "_v3", "_v4", "_v5",
            "_revised", "_updated", "_draft",
            " 2", " 3", " 4",         // "report 2.pdf"
            "-2", "-3", "-4",
            "_2", "_3", "_4",
        ]
        for suffix in suffixes {
            if s.lowercased().hasSuffix(suffix.lowercased()) {
                s = String(s.dropLast(suffix.count))
            }
        }

        return s.trimmingCharacters(in: .whitespaces).lowercased()
    }

    func oldInstallerCandidates(olderThan days: Int = 90, limit: Int = 30) throws -> [IndexedFile] {
        try syncOnQueue {
            guard limit > 0 else { return [] }
            let cutoff = Date().addingTimeInterval(TimeInterval(-(days * 86_400))).timeIntervalSince1970
            let sql = """
            SELECT id, path, root_scope, name, ext, size_bytes, modified_at, last_seen_at,
                   COALESCE(NULLIF(content_hash, ''), sha256)
            FROM files
            WHERE status = 'active'
              AND ext IN ('dmg', 'pkg', 'zip')
              AND modified_at < ?
            ORDER BY size_bytes DESC, modified_at ASC
            LIMIT ?
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)
            sqlite3_bind_double(stmt, 1, cutoff)
            sqlite3_bind_int(stmt, 2, Int32(limit))

            var files: [IndexedFile] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                files.append(readIndexedFile(stmt: stmt))
            }
            return files
        }
    }

    struct CrossDirectoryFile {
        let path: String
        let name: String
        let ext: String
        let rootScope: String
        let sizeBytes: Int64
        let modifiedAt: Date
        let aiSummary: String
        let aiConfidence: Double
    }

    struct CrossDirectoryGroup {
        let suggestedFolder: String
        let category: String
        let files: [CrossDirectoryFile]
    }

    /// Returns groups of active files that share the same AI-suggested folder
    /// but come from at least `minScopes` distinct root_scope directories.
    func crossDirectoryFileGroups(
        minFiles: Int = 3,
        minConfidence: Double = 0.55,
        minScopes: Int = 2
    ) throws -> [CrossDirectoryGroup] {
        try syncOnQueue {
            let sql = """
                SELECT
                    fa.suggested_folder,
                    f.path,
                    f.name,
                    f.ext,
                    f.root_scope,
                    f.size_bytes,
                    f.modified_at,
                    fa.summary,
                    fa.confidence,
                    fa.category
                FROM file_ai fa
                JOIN files f ON fa.file_path = f.path
                WHERE fa.suggested_folder != ''
                  AND fa.confidence >= ?
                  AND f.status = 'active'
                ORDER BY fa.suggested_folder, f.modified_at DESC
                """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)
            sqlite3_bind_double(stmt, 1, minConfidence)

            // Collect all rows grouped by suggested_folder
            var byFolder: [String: (categories: [String], files: [CrossDirectoryFile])] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                let folder    = columnText(stmt, index: 0) ?? ""
                let path      = columnText(stmt, index: 1) ?? ""
                let name      = columnText(stmt, index: 2) ?? ""
                let ext       = columnText(stmt, index: 3) ?? ""
                let scope     = columnText(stmt, index: 4) ?? ""
                let size      = sqlite3_column_int64(stmt, 5)
                let mtime     = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))
                let summary   = columnText(stmt, index: 7) ?? ""
                let conf      = sqlite3_column_double(stmt, 8)
                let category  = columnText(stmt, index: 9) ?? ""

                guard !folder.isEmpty, !path.isEmpty else { continue }
                let file = CrossDirectoryFile(
                    path: path, name: name, ext: ext, rootScope: scope,
                    sizeBytes: size, modifiedAt: mtime,
                    aiSummary: summary, aiConfidence: conf
                )
                byFolder[folder, default: ([], [])].categories.append(category)
                byFolder[folder, default: ([], [])].files.append(file)
            }

            // Filter: need minFiles total and minScopes distinct root_scopes
            var result: [CrossDirectoryGroup] = []
            for (folder, data) in byFolder {
                guard data.files.count >= minFiles else { continue }
                let distinctScopes = Set(data.files.map(\.rootScope))
                guard distinctScopes.count >= minScopes else { continue }
                // Most frequent category
                let freq = data.categories.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
                let topCategory = freq.max(by: { $0.value < $1.value })?.key ?? "其他"
                result.append(CrossDirectoryGroup(suggestedFolder: folder, category: topCategory, files: data.files))
            }
            return result.sorted { $0.files.count > $1.files.count }
        }
    }

    func queryFiles(filters: SearchFilters, limit: Int) throws -> [SearchResultItem] {
        try syncOnQueue {
            let keywordTokens = filters.keywords
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }

            let metadata = try queryFilesByMetadataUnlocked(filters: filters, keywords: keywordTokens, limit: max(limit, 200))
            guard !keywordTokens.isEmpty else {
                return Array(metadata.prefix(limit))
            }

            let pdfContent = try queryFilesByPDFContentUnlocked(filters: filters, keywords: keywordTokens, limit: max(limit, 200))
            guard !pdfContent.isEmpty else {
                return Array(metadata.prefix(limit))
            }

            var merged: [SearchResultItem] = []
            var seenPaths: Set<String> = []
            for item in pdfContent + metadata where !seenPaths.contains(item.path) {
                merged.append(item)
                seenPaths.insert(item.path)
                if merged.count >= limit {
                    break
                }
            }
            return merged
        }
    }

    private func queryFilesByMetadataUnlocked(filters: SearchFilters,
                                              keywords: [String],
                                              limit: Int) throws -> [SearchResultItem] {
        var conditions: [String] = []
        var textParams: [String] = []
        var doubleParams: [Double] = []
        var int64Params: [Int64] = []
        var bindPlan: [String] = []

        switch filters.location {
        case .archived:
            conditions.append("status = 'archived'")
            if !filters.archiveRootPath.isEmpty {
                conditions.append("path LIKE ?")
                textParams.append("\(filters.archiveRootPath)%")
                bindPlan.append("text")
            }
        case nil:
            conditions.append("status IN ('active', 'archived')")
        default:
            conditions.append("status = 'active'")
        }

        if let location = filters.location {
            if location != .archived {
                conditions.append("root_scope = ?")
                textParams.append(location.rawValue)
                bindPlan.append("text")
            }
        }

        if let fileType = filters.fileType, !fileType.isEmpty {
            conditions.append("ext = ?")
            textParams.append(fileType.lowercased())
            bindPlan.append("text")
        }

        if let dateFrom = filters.dateFrom {
            conditions.append("modified_at >= ?")
            doubleParams.append(dateFrom.timeIntervalSince1970)
            bindPlan.append("double")
        }

        if let dateTo = filters.dateTo {
            conditions.append("modified_at <= ?")
            doubleParams.append(dateTo.timeIntervalSince1970)
            bindPlan.append("double")
        }

        if let minSizeBytes = filters.minSizeBytes {
            conditions.append("size_bytes >= ?")
            int64Params.append(minSizeBytes)
            bindPlan.append("int64")
        }

        for _ in keywords {
            conditions.append("(LOWER(name) LIKE ? OR LOWER(path) LIKE ?)")
            bindPlan.append("kw")
        }

        let whereClause = conditions.joined(separator: " AND ")
        let sql = """
        SELECT id, path, name, ext, size_bytes, modified_at
        FROM files
        WHERE \(whereClause)
        ORDER BY modified_at DESC
        LIMIT ?
        """

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        try prepare(sql: sql, stmt: &stmt)

        var textIndex = 0
        var doubleIndex = 0
        var int64Index = 0
        var keywordIndex = 0
        var paramIndex: Int32 = 1

        for entry in bindPlan {
            switch entry {
            case "text":
                try bindText(textParams[textIndex], index: paramIndex, stmt: stmt)
                textIndex += 1
                paramIndex += 1
            case "double":
                sqlite3_bind_double(stmt, paramIndex, doubleParams[doubleIndex])
                doubleIndex += 1
                paramIndex += 1
            case "int64":
                sqlite3_bind_int64(stmt, paramIndex, int64Params[int64Index])
                int64Index += 1
                paramIndex += 1
            case "kw":
                let keyword = "%\(keywords[keywordIndex])%"
                try bindText(keyword, index: paramIndex, stmt: stmt)
                paramIndex += 1
                try bindText(keyword, index: paramIndex, stmt: stmt)
                paramIndex += 1
                keywordIndex += 1
            default:
                break
            }
        }

        sqlite3_bind_int(stmt, paramIndex, Int32(limit))

        var results: [SearchResultItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = columnText(stmt, index: 0) ?? UUID().uuidString
            let path = columnText(stmt, index: 1) ?? ""
            let name = columnText(stmt, index: 2) ?? URL(fileURLWithPath: path).lastPathComponent
            let ext = columnText(stmt, index: 3) ?? ""
            let size = sqlite3_column_int64(stmt, 4)
            let modifiedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))

            results.append(
                SearchResultItem(
                    id: id,
                    path: path,
                    name: name,
                    ext: ext,
                    sizeBytes: size,
                    modifiedAt: modifiedAt,
                    excerpt: nil,
                    matchSource: keywords.isEmpty ? nil : "metadata"
                )
            )
        }
        return results
    }

    private func queryFilesByPDFContentUnlocked(filters: SearchFilters,
                                                keywords: [String],
                                                limit: Int) throws -> [SearchResultItem] {
        guard !keywords.isEmpty else { return [] }
        if let fileType = filters.fileType, fileType.lowercased() != "pdf" {
            return []
        }

        let terms = ftsTerms(from: keywords)
        guard !terms.isEmpty else { return [] }
        let ftsQuery = terms.map { "\($0)*" }.joined(separator: " AND ")

        var conditions: [String] = ["f.ext = 'pdf'"]
        var textParams: [String] = []
        var doubleParams: [Double] = []
        var int64Params: [Int64] = []
        var bindPlan: [String] = []

        switch filters.location {
        case .archived:
            conditions.append("f.status = 'archived'")
            if !filters.archiveRootPath.isEmpty {
                conditions.append("f.path LIKE ?")
                textParams.append("\(filters.archiveRootPath)%")
                bindPlan.append("text")
            }
        case nil:
            conditions.append("f.status IN ('active', 'archived')")
        default:
            conditions.append("f.status = 'active'")
        }

        if let location = filters.location {
            if location != .archived {
                conditions.append("f.root_scope = ?")
                textParams.append(location.rawValue)
                bindPlan.append("text")
            }
        }
        if let dateFrom = filters.dateFrom {
            conditions.append("f.modified_at >= ?")
            doubleParams.append(dateFrom.timeIntervalSince1970)
            bindPlan.append("double")
        }
        if let dateTo = filters.dateTo {
            conditions.append("f.modified_at <= ?")
            doubleParams.append(dateTo.timeIntervalSince1970)
            bindPlan.append("double")
        }
        if let minSizeBytes = filters.minSizeBytes {
            conditions.append("f.size_bytes >= ?")
            int64Params.append(minSizeBytes)
            bindPlan.append("int64")
        }

        let whereClause = conditions.joined(separator: " AND ")
        let sql = """
        SELECT f.id,
               f.path,
               f.name,
               f.ext,
               f.size_bytes,
               f.modified_at,
               m.snippet,
               bm25(pdf_text_fts) AS rank
        FROM pdf_text_fts
        JOIN files f ON f.path = pdf_text_fts.file_path
        LEFT JOIN pdf_text_index m ON m.file_path = f.path
        WHERE pdf_text_fts MATCH ?
          AND \(whereClause)
        ORDER BY rank ASC, f.modified_at DESC
        LIMIT ?
        """

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        try prepare(sql: sql, stmt: &stmt)

        var paramIndex: Int32 = 1
        try bindText(ftsQuery, index: paramIndex, stmt: stmt)
        paramIndex += 1

        var textIndex = 0
        var doubleIndex = 0
        var int64Index = 0
        for entry in bindPlan {
            switch entry {
            case "text":
                try bindText(textParams[textIndex], index: paramIndex, stmt: stmt)
                textIndex += 1
                paramIndex += 1
            case "double":
                sqlite3_bind_double(stmt, paramIndex, doubleParams[doubleIndex])
                doubleIndex += 1
                paramIndex += 1
            case "int64":
                sqlite3_bind_int64(stmt, paramIndex, int64Params[int64Index])
                int64Index += 1
                paramIndex += 1
            default:
                break
            }
        }
        sqlite3_bind_int(stmt, paramIndex, Int32(limit))

        var results: [SearchResultItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = columnText(stmt, index: 0) ?? UUID().uuidString
            let path = columnText(stmt, index: 1) ?? ""
            let name = columnText(stmt, index: 2) ?? URL(fileURLWithPath: path).lastPathComponent
            let ext = columnText(stmt, index: 3) ?? "pdf"
            let size = sqlite3_column_int64(stmt, 4)
            let modifiedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))
            let snippet = columnText(stmt, index: 6)
            results.append(
                SearchResultItem(
                    id: id,
                    path: path,
                    name: name,
                    ext: ext,
                    sizeBytes: size,
                    modifiedAt: modifiedAt,
                    excerpt: snippet,
                    matchSource: "pdf_content"
                )
            )
        }
        return results
    }

    private func ftsTerms(from keywords: [String]) -> [String] {
        var terms: [String] = []
        let splitCharset = CharacterSet.alphanumerics.inverted
        for keyword in keywords {
            let lowered = keyword.lowercased()
            let normalized = lowered
                .replacingOccurrences(of: "\"", with: " ")
                .replacingOccurrences(of: "'", with: " ")
            let pieces = normalized
                .components(separatedBy: splitCharset)
                .filter { !$0.isEmpty }
            if pieces.isEmpty {
                let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    terms.append(trimmed)
                }
            } else {
                terms.append(contentsOf: pieces)
            }
        }
        return Array(Set(terms)).sorted()
    }

    // MARK: - Quarantine

    func insertQuarantineItem(id: String,
                              fileID: String,
                              originalPath: String,
                              quarantinePath: String,
                              sha256: String,
                              sizeBytes: Int64,
                              quarantinedAt: Date,
                              expiresAt: Date,
                              state: QuarantineState) throws {
        try syncOnQueue {
            let sql = """
            INSERT INTO quarantine_items(id, file_id, original_path, quarantine_path, sha256, size_bytes, quarantined_at, expires_at, state)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)
            try bindText(id, index: 1, stmt: stmt)
            try bindText(fileID, index: 2, stmt: stmt)
            try bindText(originalPath, index: 3, stmt: stmt)
            try bindText(quarantinePath, index: 4, stmt: stmt)
            try bindText(sha256, index: 5, stmt: stmt)
            sqlite3_bind_int64(stmt, 6, sizeBytes)
            sqlite3_bind_double(stmt, 7, quarantinedAt.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 8, expiresAt.timeIntervalSince1970)
            try bindText(state.rawValue, index: 9, stmt: stmt)
            try stepDone(stmt)
        }
    }

    func listActiveQuarantineItems() throws -> [QuarantineItem] {
        try syncOnQueue {
            try listActiveQuarantineItemsUnlocked()
        }
    }

    func listQuarantineItems(states: [QuarantineState]) throws -> [QuarantineItem] {
        try syncOnQueue {
            try listQuarantineItemsUnlocked(states: states)
        }
    }

    func listSafeCleanupQuarantineItems() throws -> [QuarantineItem] {
        try syncOnQueue {
            let sql = """
            SELECT q.id, q.original_path, q.quarantine_path, q.sha256, q.size_bytes, q.quarantined_at, q.state
            FROM quarantine_items q
            WHERE q.state = 'expired'
              AND (
                    LOWER(q.original_path) LIKE '%.dmg'
                 OR LOWER(q.original_path) LIKE '%.pkg'
                 OR LOWER(q.quarantine_path) LIKE '%.dmg'
                 OR LOWER(q.quarantine_path) LIKE '%.pkg'
                 OR (
                        q.sha256 IS NOT NULL
                    AND q.sha256 != ''
                    AND q.sha256 IN (
                        SELECT sha256
                        FROM quarantine_items
                        WHERE sha256 IS NOT NULL AND sha256 != ''
                        GROUP BY sha256
                        HAVING COUNT(*) > 1
                    )
                 )
              )
            ORDER BY q.quarantined_at DESC
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)

            var result: [QuarantineItem] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                result.append(readQuarantineItem(stmt: stmt))
            }
            return result
        }
    }

    func safeCleanupQuarantineCount() throws -> Int {
        try syncOnQueue {
            let sql = """
            SELECT COUNT(*)
            FROM quarantine_items q
            WHERE q.state = 'expired'
              AND (
                    LOWER(q.original_path) LIKE '%.dmg'
                 OR LOWER(q.original_path) LIKE '%.pkg'
                 OR LOWER(q.quarantine_path) LIKE '%.dmg'
                 OR LOWER(q.quarantine_path) LIKE '%.pkg'
                 OR (
                        q.sha256 IS NOT NULL
                    AND q.sha256 != ''
                    AND q.sha256 IN (
                        SELECT sha256
                        FROM quarantine_items
                        WHERE sha256 IS NOT NULL AND sha256 != ''
                        GROUP BY sha256
                        HAVING COUNT(*) > 1
                    )
                 )
              )
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)
            guard sqlite3_step(stmt) == SQLITE_ROW else {
                return 0
            }
            return Int(sqlite3_column_int(stmt, 0))
        }
    }

    private func listActiveQuarantineItemsUnlocked() throws -> [QuarantineItem] {
        try listQuarantineItemsUnlocked(states: [.active])
    }

    private func listQuarantineItemsUnlocked(states: [QuarantineState]) throws -> [QuarantineItem] {
        guard !states.isEmpty else { return [] }
        let placeholders = states.map { _ in "?" }.joined(separator: ",")
        let sql = """
        SELECT id, original_path, quarantine_path, sha256, size_bytes, quarantined_at, state
        FROM quarantine_items
        WHERE state IN (\(placeholders))
        ORDER BY quarantined_at DESC
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        try prepare(sql: sql, stmt: &stmt)
        var idx: Int32 = 1
        for state in states {
            try bindText(state.rawValue, index: idx, stmt: stmt)
            idx += 1
        }

        var result: [QuarantineItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append(readQuarantineItem(stmt: stmt))
        }
        return result
    }

    func loadQuarantineItem(id: String) throws -> QuarantineItem? {
        try syncOnQueue {
            let sql = """
            SELECT id, original_path, quarantine_path, sha256, size_bytes, quarantined_at, state
            FROM quarantine_items
            WHERE id = ?
            LIMIT 1
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)
            try bindText(id, index: 1, stmt: stmt)

            guard sqlite3_step(stmt) == SQLITE_ROW else {
                return nil
            }
            return readQuarantineItem(stmt: stmt)
        }
    }

    func hasActiveQuarantineItem(originalPath: String, sha256: String) throws -> Bool {
        try syncOnQueue {
            let sql = """
            SELECT 1
            FROM quarantine_items
            WHERE original_path = ?
              AND sha256 = ?
              AND state = 'active'
            LIMIT 1
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)
            try bindText(originalPath, index: 1, stmt: stmt)
            try bindText(sha256, index: 2, stmt: stmt)
            return sqlite3_step(stmt) == SQLITE_ROW
        }
    }

    func updateQuarantineItemState(id: String, state: QuarantineState) throws {
        try syncOnQueue {
            let sql = "UPDATE quarantine_items SET state = ? WHERE id = ?"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)
            try bindText(state.rawValue, index: 1, stmt: stmt)
            try bindText(id, index: 2, stmt: stmt)
            try stepDone(stmt)
        }
    }

    func updateQuarantineItemStateByPath(quarantinePath: String, state: QuarantineState) throws {
        try syncOnQueue {
            let sql = "UPDATE quarantine_items SET state = ? WHERE quarantine_path = ?"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)
            try bindText(state.rawValue, index: 1, stmt: stmt)
            try bindText(quarantinePath, index: 2, stmt: stmt)
            try stepDone(stmt)
        }
    }

    func markMissingQuarantineItems() throws -> Int {
        try syncOnQueue {
            let sql = """
            SELECT id, quarantine_path
            FROM quarantine_items
            WHERE state = 'active'
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)

            let fileManager = FileManager.default
            var missingIDs: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = columnText(stmt, index: 0) ?? ""
                let path = columnText(stmt, index: 1) ?? ""
                if !path.isEmpty, !fileManager.fileExists(atPath: path) {
                    missingIDs.append(id)
                }
            }

            guard !missingIDs.isEmpty else { return 0 }

            let updateSQL = "UPDATE quarantine_items SET state = ? WHERE id = ?"
            var updateStmt: OpaquePointer?
            defer { sqlite3_finalize(updateStmt) }
            try prepare(sql: updateSQL, stmt: &updateStmt)
            for id in missingIDs {
                sqlite3_reset(updateStmt)
                sqlite3_clear_bindings(updateStmt)
                try bindText(QuarantineState.missing.rawValue, index: 1, stmt: updateStmt)
                try bindText(id, index: 2, stmt: updateStmt)
                try stepDone(updateStmt)
            }
            return missingIDs.count
        }
    }

    func markExpiredQuarantineItems(now: Date) throws -> Int {
        try syncOnQueue {
            let sql = """
            UPDATE quarantine_items
            SET state = ?
            WHERE (state = 'active' AND expires_at <= ?)
               OR state = 'cleanupCandidate'
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)
            try bindText(QuarantineState.expired.rawValue, index: 1, stmt: stmt)
            sqlite3_bind_double(stmt, 2, now.timeIntervalSince1970)
            try stepDone(stmt)
            return Int(sqlite3_changes(db))
        }
    }

    func setQuarantineState(ids: [String], state: QuarantineState) throws {
        guard !ids.isEmpty else { return }
        try syncOnQueue {
            let sql = "UPDATE quarantine_items SET state = ? WHERE id = ?"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)
            for id in ids {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                try bindText(state.rawValue, index: 1, stmt: stmt)
                try bindText(id, index: 2, stmt: stmt)
                try stepDone(stmt)
            }
        }
    }

    func quarantineItemCount(states: [QuarantineState]) throws -> Int {
        try syncOnQueue {
            guard !states.isEmpty else { return 0 }
            let placeholders = states.map { _ in "?" }.joined(separator: ",")
            let sql = """
            SELECT COUNT(*)
            FROM quarantine_items
            WHERE state IN (\(placeholders))
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)
            var idx: Int32 = 1
            for state in states {
                try bindText(state.rawValue, index: idx, stmt: stmt)
                idx += 1
            }
            guard sqlite3_step(stmt) == SQLITE_ROW else {
                return 0
            }
            return Int(sqlite3_column_int(stmt, 0))
        }
    }

    // MARK: - Journal

    func insertJournalEntry(_ entry: JournalInsert) throws {
        try syncOnQueue {
            try insertJournalEntryInternal(entry)
        }
    }

    func latestUndoableTxn() throws -> String? {
        try syncOnQueue {
            let sql = """
            SELECT txn_id
            FROM journal_entries
            WHERE undo_status = 'active'
              AND undoable = 1
              AND verified = 1
              AND action_type IN ('quarantineCopy', 'rename', 'move')
            ORDER BY created_at DESC
            LIMIT 1
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)

            guard sqlite3_step(stmt) == SQLITE_ROW else {
                return nil
            }
            return columnText(stmt, index: 0)
        }
    }

    func journalRows(txnID: String) throws -> [JournalRow] {
        try syncOnQueue {
            let sql = """
            SELECT id, txn_id, actor, action_type, target_type, target_id,
                   src_path, dst_path, copy_or_move, conflict_resolution,
                   verified, error_code, error_message, bytes_delta,
                   created_at, undone_at, undoable
            FROM journal_entries
            WHERE txn_id = ?
            ORDER BY created_at ASC
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)
            try bindText(txnID, index: 1, stmt: stmt)

            var rows: [JournalRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let actionRaw = columnText(stmt, index: 3) ?? ActionType.quarantineCopy.rawValue
                let row = JournalRow(
                    id: columnText(stmt, index: 0) ?? "",
                    txnID: columnText(stmt, index: 1) ?? "",
                    actor: columnText(stmt, index: 2) ?? "",
                    actionType: ActionType(rawValue: actionRaw) ?? .quarantineCopy,
                    targetType: columnText(stmt, index: 4) ?? "file",
                    targetID: columnText(stmt, index: 5) ?? "",
                    srcPath: columnText(stmt, index: 6) ?? "",
                    dstPath: columnText(stmt, index: 7) ?? "",
                    copyOrMove: columnText(stmt, index: 8) ?? "copy",
                    conflictResolution: columnText(stmt, index: 9) ?? "none",
                    verified: sqlite3_column_int(stmt, 10) == 1,
                    errorCode: columnText(stmt, index: 11),
                    errorMessage: columnText(stmt, index: 12),
                    bytesDelta: sqlite3_column_int64(stmt, 13),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 14)),
                    undoneAt: sqlite3_column_type(stmt, 15) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 15)),
                    undoable: sqlite3_column_int(stmt, 16) == 1
                )
                rows.append(row)
            }
            return rows
        }
    }

    func latestTxnID() throws -> String? {
        try syncOnQueue {
            let sql = """
            SELECT txn_id
            FROM journal_entries
            ORDER BY created_at DESC
            LIMIT 1
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)
            guard sqlite3_step(stmt) == SQLITE_ROW else {
                return nil
            }
            return columnText(stmt, index: 0)
        }
    }

    func recentJournalEntries(limit: Int) throws -> [JournalExportEntry] {
        try syncOnQueue {
            let sql = """
            SELECT id, txn_id, actor, action_type, target_type, target_id,
                   src_path, dst_path, copy_or_move, conflict_resolution,
                   verified, error_code, error_message, bytes_delta,
                   created_at, undone_at, undoable
            FROM journal_entries
            ORDER BY created_at DESC
            LIMIT ?
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)
            sqlite3_bind_int(stmt, 1, Int32(limit))

            var rows: [JournalExportEntry] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append(
                    JournalExportEntry(
                        id: columnText(stmt, index: 0) ?? UUID().uuidString,
                        txnID: columnText(stmt, index: 1) ?? "",
                        actor: columnText(stmt, index: 2) ?? "",
                        actionType: columnText(stmt, index: 3) ?? "",
                        targetType: columnText(stmt, index: 4) ?? "",
                        targetID: columnText(stmt, index: 5) ?? "",
                        srcPath: columnText(stmt, index: 6) ?? "",
                        dstPath: columnText(stmt, index: 7) ?? "",
                        copyOrMove: columnText(stmt, index: 8) ?? "",
                        conflictResolution: columnText(stmt, index: 9) ?? "",
                        verified: sqlite3_column_int(stmt, 10) == 1,
                        errorCode: columnText(stmt, index: 11),
                        errorMessage: columnText(stmt, index: 12),
                        bytesDelta: sqlite3_column_int64(stmt, 13),
                        createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 14)),
                        undoneAt: sqlite3_column_type(stmt, 15) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 15)),
                        undoable: sqlite3_column_int(stmt, 16) == 1
                    )
                )
            }
            return rows
        }
    }

    func markTxnUndone(txnID: String, undoneAt: Date) throws {
        try syncOnQueue {
            let sql = """
            UPDATE journal_entries
            SET undone_at = ?, undo_status = 'undone'
            WHERE txn_id = ?
              AND undo_status = 'active'
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)
            sqlite3_bind_double(stmt, 1, undoneAt.timeIntervalSince1970)
            try bindText(txnID, index: 2, stmt: stmt)
            try stepDone(stmt)
        }
    }

    func markJournalRowsUndone(rowIDs: [String], undoneAt: Date) throws {
        guard !rowIDs.isEmpty else { return }
        try syncOnQueue {
            let sql = """
            UPDATE journal_entries
            SET undone_at = ?, undo_status = 'undone'
            WHERE id = ?
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)

            for rowID in rowIDs {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                sqlite3_bind_double(stmt, 1, undoneAt.timeIntervalSince1970)
                try bindText(rowID, index: 2, stmt: stmt)
                try stepDone(stmt)
            }
        }
    }

    func appendUndoError(rowID: String, message: String) throws {
        try syncOnQueue {
            let sql = """
            UPDATE journal_entries
            SET error_message = CASE
                WHEN error_message IS NULL OR error_message = '' THEN ?
                ELSE error_message || ' | ' || ?
            END
            WHERE id = ?
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)
            try bindText("UNDO_FAILED: \(message)", index: 1, stmt: stmt)
            try bindText("UNDO_FAILED: \(message)", index: 2, stmt: stmt)
            try bindText(rowID, index: 3, stmt: stmt)
            try stepDone(stmt)
        }
    }

    func activeUndoRowsCount(txnID: String) throws -> Int {
        try syncOnQueue {
            let sql = """
            SELECT COUNT(*)
            FROM journal_entries
            WHERE txn_id = ?
              AND undo_status = 'active'
              AND undoable = 1
              AND verified = 1
              AND action_type IN ('quarantineCopy', 'rename', 'move')
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)
            try bindText(txnID, index: 1, stmt: stmt)
            guard sqlite3_step(stmt) == SQLITE_ROW else {
                return 0
            }
            return Int(sqlite3_column_int(stmt, 0))
        }
    }

    func weeklyUserIsolated(weekStart: Date) throws -> (count: Int, bytes: Int64) {
        try weeklyMetric(actor: "user", actionTypes: ["quarantineCopy"], weekStart: weekStart)
    }

    func weeklyAutopilotIsolated(weekStart: Date) throws -> (count: Int, bytes: Int64) {
        try weeklyMetric(actor: "autopilot", actionTypes: ["quarantineCopy"], weekStart: weekStart)
    }

    func weeklyUserOrganized(weekStart: Date) throws -> Int {
        try syncOnQueue {
            let sql = """
            SELECT COUNT(*)
            FROM journal_entries
            WHERE actor = 'user'
              AND action_type IN ('rename', 'move')
              AND created_at >= ?
              AND undone_at IS NULL
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)
            sqlite3_bind_double(stmt, 1, weekStart.timeIntervalSince1970)

            guard sqlite3_step(stmt) == SQLITE_ROW else {
                return 0
            }
            return Int(sqlite3_column_int(stmt, 0))
        }
    }

    func latestAppliedHint() throws -> String? {
        try syncOnQueue {
            let latestTxnSQL = """
            SELECT txn_id
            FROM journal_entries
            WHERE actor = 'user'
              AND action_type IN ('rename', 'move', 'quarantineCopy')
              AND undone_at IS NULL
              AND verified = 1
            GROUP BY txn_id
            ORDER BY MAX(created_at) DESC
            LIMIT 1
            """
            var txnStmt: OpaquePointer?
            defer { sqlite3_finalize(txnStmt) }
            try prepare(sql: latestTxnSQL, stmt: &txnStmt)

            guard sqlite3_step(txnStmt) == SQLITE_ROW else {
                return nil
            }
            guard let txnID = columnText(txnStmt, index: 0) else {
                return nil
            }

            let rowsSQL = """
            SELECT action_type, dst_path
            FROM journal_entries
            WHERE txn_id = ?
              AND verified = 1
              AND undone_at IS NULL
            """
            var rowsStmt: OpaquePointer?
            defer { sqlite3_finalize(rowsStmt) }
            try prepare(sql: rowsSQL, stmt: &rowsStmt)
            try bindText(txnID, index: 1, stmt: rowsStmt)

            var renameCount = 0
            var moveCount = 0
            var quarantineCount = 0
            var firstMoveParent: String?

            while sqlite3_step(rowsStmt) == SQLITE_ROW {
                let action = columnText(rowsStmt, index: 0) ?? ""
                let dstPath = columnText(rowsStmt, index: 1) ?? ""
                switch action {
                case ActionType.rename.rawValue:
                    renameCount += 1
                case ActionType.move.rawValue:
                    moveCount += 1
                    if firstMoveParent == nil {
                        firstMoveParent = URL(fileURLWithPath: dstPath).deletingLastPathComponent().path
                    }
                case ActionType.quarantineCopy.rawValue:
                    quarantineCount += 1
                default:
                    continue
                }
            }

            if moveCount > 0 {
                let destination = firstMoveParent ?? "selected archive folder"
                return "Last applied: Moved \(moveCount) files to \(destination)"
            }
            if renameCount > 0 {
                return "Last applied: Renamed \(renameCount) files"
            }
            if quarantineCount > 0 {
                return "Last applied: Quarantined \(quarantineCount) files"
            }
            return nil
        }
    }

    func recentChangeLog(limit: Int) throws -> [ChangeLogEntry] {
        try syncOnQueue {
            let sql = """
            SELECT
                txn_id,
                MAX(created_at) AS created_at,
                SUM(CASE WHEN action_type = 'move' AND verified = 1 THEN 1 ELSE 0 END) AS move_count,
                SUM(CASE WHEN action_type = 'rename' AND verified = 1 THEN 1 ELSE 0 END) AS rename_count,
                SUM(CASE WHEN action_type = 'quarantineCopy' AND verified = 1 THEN 1 ELSE 0 END) AS quarantine_count,
                SUM(CASE WHEN action_type = 'purgeExpired' AND verified = 1 THEN 1 ELSE 0 END) AS purge_count,
                SUM(CASE WHEN action_type = 'purgeExpired' AND verified = 1 THEN ABS(bytes_delta) ELSE 0 END) AS purge_bytes,
                SUM(CASE WHEN action_type = 'bundle_apply_finished' THEN 1 ELSE 0 END) AS bundle_apply_count,
                MAX(CASE WHEN action_type = 'bundle_apply_finished' THEN COALESCE(error_code, '') ELSE '' END) AS bundle_apply_code,
                MAX(CASE WHEN action_type = 'bundle_apply_finished' THEN COALESCE(error_message, '') ELSE '' END) AS bundle_apply_message,
                MAX(CASE WHEN action_type = 'bundle_apply_finished' THEN COALESCE(dst_path, '') ELSE '' END) AS bundle_apply_dst,
                MAX(CASE WHEN action_type = 'move' AND verified = 1 THEN dst_path ELSE '' END) AS move_dst,
                MAX(CASE WHEN action_type = 'rename' AND verified = 1 THEN dst_path ELSE '' END) AS rename_dst,
                MAX(CASE WHEN action_type = 'quarantineCopy' AND verified = 1 THEN dst_path ELSE '' END) AS quarantine_dst,
                SUM(CASE WHEN undo_status = 'active' THEN 1 ELSE 0 END) AS active_count,
                MIN(undoable) AS min_undoable
            FROM journal_entries
            WHERE action_type IN ('move', 'rename', 'quarantineCopy', 'purgeExpired', 'bundle_apply_finished')
            GROUP BY txn_id
            ORDER BY created_at DESC
            LIMIT ?
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)
            sqlite3_bind_int(stmt, 1, Int32(limit))

            var entries: [ChangeLogEntry] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let txnID = columnText(stmt, index: 0) ?? UUID().uuidString
                let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
                let moveCount = Int(sqlite3_column_int(stmt, 2))
                let renameCount = Int(sqlite3_column_int(stmt, 3))
                let quarantineCount = Int(sqlite3_column_int(stmt, 4))
                let purgeCount = Int(sqlite3_column_int(stmt, 5))
                let purgeBytes = sqlite3_column_int64(stmt, 6)
                let bundleApplyCount = Int(sqlite3_column_int(stmt, 7))
                let bundleApplyCode = columnText(stmt, index: 8) ?? ""
                let bundleApplyMessage = columnText(stmt, index: 9) ?? ""
                let bundleApplyDst = columnText(stmt, index: 10) ?? ""
                let moveDst = columnText(stmt, index: 11) ?? ""
                let renameDst = columnText(stmt, index: 12) ?? ""
                let quarantineDst = columnText(stmt, index: 13) ?? ""
                let activeCount = Int(sqlite3_column_int(stmt, 14))
                let isUndoable = sqlite3_column_int(stmt, 15) == 1

                let title: String
                let detail: String
                let revealPath: String?

                if bundleApplyCount > 0 {
                    let parts = bundleApplyMessage.components(separatedBy: " [")
                    let displayMessage = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let debugTail: String
                    if parts.count > 1 {
                        debugTail = "[" + parts.dropFirst().joined(separator: " [")
                    } else {
                        debugTail = ""
                    }
                    // Translate common English bundle apply messages to Chinese
                    let localizedMessage: String
                    if displayMessage.hasPrefix("Bundle applied:") {
                        let stats = displayMessage
                            .replacingOccurrences(of: "Bundle applied:", with: "")
                            .trimmingCharacters(in: .whitespaces)
                            .replacingOccurrences(of: "renamed", with: "重命名")
                            .replacingOccurrences(of: "moved", with: "移动")
                            .replacingOccurrences(of: "quarantined", with: "已隔离")
                        localizedMessage = stats.isEmpty ? "整理完成" : "整理完成：\(stats)"
                    } else if displayMessage.hasPrefix("Bundle failed:") {
                        let errorPart = displayMessage
                            .replacingOccurrences(of: "Bundle failed:", with: "")
                            .trimmingCharacters(in: .whitespaces)
                        let localizedError: String
                        switch errorPart {
                        case "Rename template resolved to current name",
                             "no_op_already_named":
                            localizedError = "文件名已是目标名称（已跳过）"
                        case "All operations are no-ops":
                            localizedError = "所有文件无需改动"
                        case "Source file not found":
                            localizedError = "源文件不存在"
                        case "Destination already exists":
                            localizedError = "目标位置已有同名文件"
                        case "Permission denied":
                            localizedError = "权限不足"
                        case let e where e.hasPrefix("High-risk bundle is blocked from move"):
                            localizedError = "高风险文件禁止直接移动，请改用重命名或隔离"
                        default:
                            localizedError = errorPart
                        }
                        localizedMessage = "整理失败：\(localizedError)"
                    } else if displayMessage == "Archive finished with no changes. Check Advanced > Decision Bundles." {
                        localizedMessage = "归档完成，没有文件被移动"
                    } else if displayMessage.isEmpty {
                        localizedMessage = "整理完成"
                    } else {
                        localizedMessage = displayMessage
                    }
                    title = localizedMessage.isEmpty ? "整理操作完成" : localizedMessage
                    if bundleApplyCode.uppercased() == "FAILED" {
                        detail = "整理操作未成功执行"
                        revealPath = nil
                    } else if !bundleApplyDst.isEmpty {
                        let parent = URL(fileURLWithPath: bundleApplyDst).deletingLastPathComponent().path
                        detail = "目标文件夹：\(parent)"
                        revealPath = bundleApplyDst
                    } else {
                        detail = "操作已记录"
                        revealPath = nil
                    }
                } else if moveCount > 0 {
                    title = "已移动 \(moveCount) 个文件"
                    let parent = moveDst.isEmpty ? "归档文件夹" : URL(fileURLWithPath: moveDst).deletingLastPathComponent().path
                    detail = "目标：\(parent)"
                    revealPath = moveDst.isEmpty ? nil : moveDst
                } else if renameCount > 0 {
                    title = "已重命名 \(renameCount) 个文件"
                    detail = "批量重命名完成"
                    revealPath = renameDst.isEmpty ? nil : renameDst
                } else if quarantineCount > 0 {
                    title = "已隔离 \(quarantineCount) 个文件"
                    detail = "已复制到隔离区"
                    revealPath = quarantineDst.isEmpty ? nil : quarantineDst
                } else if purgeCount > 0 {
                    title = "已清理 \(purgeCount) 个过期文件"
                    detail = "释放了 \(SizeFormatter.string(from: purgeBytes))"
                    revealPath = nil
                } else {
                    title = "没有成功执行文件操作"
                    detail = "事务 \(txnID.prefix(8))"
                    revealPath = nil
                }

                entries.append(
                    ChangeLogEntry(
                        id: txnID,
                        createdAt: createdAt,
                        title: title,
                        detail: detail,
                        revealPath: revealPath,
                        isUndone: activeCount == 0,
                        isUndoable: isUndoable
                    )
                )
            }
            return entries
        }
    }

    private func weeklyMetric(actor: String, actionTypes: [String], weekStart: Date) throws -> (count: Int, bytes: Int64) {
        try syncOnQueue {
            let placeholders = actionTypes.map { _ in "?" }.joined(separator: ",")
            let sql = """
            SELECT COUNT(*), COALESCE(SUM(bytes_delta), 0)
            FROM journal_entries
            WHERE actor = ?
              AND action_type IN (\(placeholders))
              AND created_at >= ?
              AND undone_at IS NULL
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)
            var index: Int32 = 1
            try bindText(actor, index: index, stmt: stmt)
            index += 1
            for action in actionTypes {
                try bindText(action, index: index, stmt: stmt)
                index += 1
            }
            sqlite3_bind_double(stmt, index, weekStart.timeIntervalSince1970)

            guard sqlite3_step(stmt) == SQLITE_ROW else {
                return (0, 0)
            }
            return (Int(sqlite3_column_int(stmt, 0)), sqlite3_column_int64(stmt, 1))
        }
    }

    // MARK: - Bundles

    func pendingBundleRawCount(now: Date = Date()) throws -> Int {
        try syncOnQueue {
            let weekStart = DateHelper.startOfCurrentWeek(now: now)
            let sql = """
            SELECT COUNT(*)
            FROM bundles
            WHERE created_at >= ?
              AND (
                    status = 'pending'
                    OR (
                        status = 'skipped'
                        AND (snoozed_until IS NULL OR snoozed_until <= ?)
                    )
                  )
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)
            sqlite3_bind_double(stmt, 1, weekStart.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 2, now.timeIntervalSince1970)

            guard sqlite3_step(stmt) == SQLITE_ROW else {
                return 0
            }
            return Int(sqlite3_column_int(stmt, 0))
        }
    }

    func pendingBundleCount(limit: Int, now: Date = Date()) throws -> Int {
        min(try pendingBundleRawCount(now: now), limit)
    }

    func loadPendingBundles(limit: Int, now: Date = Date()) throws -> [DecisionBundle] {
        try syncOnQueue {
            let weekStart = DateHelper.startOfCurrentWeek(now: now)
            let sql = """
            SELECT id, type, title, summary, action_kind, rename_template, target_folder_bookmark,
                   evidence_json, risk_level, status, created_at, snoozed_until, matched_rule_id
            FROM bundles
            WHERE created_at >= ?
              AND (
                    status = 'pending'
                    OR (
                        status = 'skipped'
                        AND (snoozed_until IS NULL OR snoozed_until <= ?)
                    )
                  )
            ORDER BY created_at DESC
            LIMIT ?
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)
            sqlite3_bind_double(stmt, 1, weekStart.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 2, now.timeIntervalSince1970)
            sqlite3_bind_int(stmt, 3, Int32(limit))

            var bundles: [DecisionBundle] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = columnText(stmt, index: 0) ?? UUID().uuidString
                bundles.append(try readBundleRow(stmt: stmt, id: id, forcePendingIfSkipped: true))
            }
            return bundles
        }
    }

    func loadBundle(id: String) throws -> DecisionBundle? {
        try syncOnQueue {
            let sql = """
            SELECT id, type, title, summary, action_kind, rename_template, target_folder_bookmark,
                   evidence_json, risk_level, status, created_at, snoozed_until, matched_rule_id
            FROM bundles
            WHERE id = ?
            LIMIT 1
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)
            try bindText(id, index: 1, stmt: stmt)

            guard sqlite3_step(stmt) == SQLITE_ROW else {
                return nil
            }
            return try readBundleRow(stmt: stmt, id: id, forcePendingIfSkipped: false)
        }
    }

    func loadBundleState(id: String) throws -> BundleState? {
        try syncOnQueue {
            let sql = "SELECT status, snoozed_until FROM bundles WHERE id = ? LIMIT 1"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)
            try bindText(id, index: 1, stmt: stmt)

            guard sqlite3_step(stmt) == SQLITE_ROW else {
                return nil
            }
            let statusRaw = columnText(stmt, index: 0) ?? BundleStatus.pending.rawValue
            let status = BundleStatus(rawValue: statusRaw) ?? .pending
            let snoozedUntil: Date?
            if sqlite3_column_type(stmt, 1) == SQLITE_NULL {
                snoozedUntil = nil
            } else {
                snoozedUntil = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
            }
            return BundleState(status: status, snoozedUntil: snoozedUntil)
        }
    }

    func upsertBundle(_ bundle: DecisionBundle) throws {
        try syncOnQueue {
            try beginTransaction()
            do {
                try upsertBundleInternal(bundle)
                try replaceBundleItems(bundleID: bundle.id, filePaths: bundle.filePaths)
                try commitTransaction()
            } catch {
                try? rollbackTransaction()
                throw error
            }
        }
    }

    func updateBundleStatus(id: String, status: BundleStatus) throws {
        try syncOnQueue {
            let sql = "UPDATE bundles SET status = ?, snoozed_until = NULL WHERE id = ?"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)
            try bindText(status.rawValue, index: 1, stmt: stmt)
            try bindText(id, index: 2, stmt: stmt)
            try stepDone(stmt)
        }
    }

    func snoozeBundle(id: String, until: Date) throws {
        try syncOnQueue {
            let sql = "UPDATE bundles SET status = 'skipped', snoozed_until = ? WHERE id = ?"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)
            sqlite3_bind_double(stmt, 1, until.timeIntervalSince1970)
            try bindText(id, index: 2, stmt: stmt)
            try stepDone(stmt)
        }
    }

    func updateBundleAction(id: String, action: BundleActionConfig) throws {
        try syncOnQueue {
            let sql = """
            UPDATE bundles
            SET action_kind = ?,
                rename_template = ?,
                target_folder_bookmark = ?
            WHERE id = ?
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)
            try bindText(action.actionKind.rawValue, index: 1, stmt: stmt)
            if let template = action.renameTemplate {
                try bindText(template, index: 2, stmt: stmt)
            } else {
                sqlite3_bind_null(stmt, 2)
            }
            if let bookmark = action.targetFolderBookmark {
                try bindBlob(bookmark, index: 3, stmt: stmt)
            } else {
                sqlite3_bind_null(stmt, 3)
            }
            try bindText(id, index: 4, stmt: stmt)
            try stepDone(stmt)
        }
    }

    func deleteBundle(id: String) throws {
        try syncOnQueue {
            try beginTransaction()
            do {
                var deleteItemsStmt: OpaquePointer?
                defer { sqlite3_finalize(deleteItemsStmt) }
                try prepare(sql: "DELETE FROM bundle_items WHERE bundle_id = ?", stmt: &deleteItemsStmt)
                try bindText(id, index: 1, stmt: deleteItemsStmt)
                try stepDone(deleteItemsStmt)

                var deleteBundleStmt: OpaquePointer?
                defer { sqlite3_finalize(deleteBundleStmt) }
                try prepare(sql: "DELETE FROM bundles WHERE id = ?", stmt: &deleteBundleStmt)
                try bindText(id, index: 1, stmt: deleteBundleStmt)
                try stepDone(deleteBundleStmt)
                try commitTransaction()
            } catch {
                try? rollbackTransaction()
                throw error
            }
        }
    }

    func loadBundleItems(bundleID: String) throws -> [String] {
        try syncOnQueue {
            let sql = "SELECT file_path FROM bundle_items WHERE bundle_id = ? ORDER BY file_path ASC"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)
            try bindText(bundleID, index: 1, stmt: stmt)

            var paths: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                paths.append(columnText(stmt, index: 0) ?? "")
            }
            return paths
        }
    }

    // MARK: - Bundle apply transaction helper

    func runBundleApplyTransaction(bundleID: String,
                                   action: BundleActionConfig,
                                   operations: [BundleOperationRecord],
                                   actor: String,
                                   txnID: String,
                                   createdAt: Date,
                                   extraJournalEntries: [JournalInsert] = []) throws -> BundleApplyTransactionResult {
        try syncOnQueue {
            try beginTransaction()
            do {
                var movedCount = 0
                var renamedCount = 0
                var quarantinedCount = 0
                var journalCount = 0

                for extra in extraJournalEntries {
                    try insertJournalEntryInternal(extra)
                    journalCount += 1
                }

                for op in operations {
                    if (op.actionType == .rename || op.actionType == .move), op.verified,
                       op.srcPath != op.dstPath {
                        try updateIndexedFilePathInternal(
                            oldPath: op.srcPath,
                            newPath: op.dstPath,
                            newScope: op.newRootScope,
                            modifiedAt: createdAt,
                            lastSeenAt: createdAt
                        )
                    }

                    if op.actionType == .quarantineCopy, op.verified, let quarantineID = op.quarantineItemID {
                        let fileID = (try fileByPathInternal(op.srcPath)?.id) ?? UUID().uuidString
                        try insertQuarantineItemInternal(
                            id: quarantineID,
                            fileID: fileID,
                            originalPath: op.srcPath,
                            quarantinePath: op.dstPath,
                            sha256: op.sha256 ?? "",
                            sizeBytes: op.bytesDelta,
                            quarantinedAt: createdAt,
                            expiresAt: Calendar.current.date(byAdding: .day, value: 30, to: createdAt) ?? createdAt,
                            state: .active
                        )
                    }

                    try insertJournalEntryInternal(
                        .init(
                            id: UUID().uuidString,
                            txnID: txnID,
                            actor: actor,
                            actionType: op.actionType,
                            targetType: "bundle",
                            targetID: bundleID,
                            srcPath: op.srcPath,
                            dstPath: op.dstPath,
                            copyOrMove: op.copyOrMove,
                            conflictResolution: op.conflictResolution,
                            verified: op.verified,
                            errorCode: op.errorCode,
                            errorMessage: op.errorMessage,
                            bytesDelta: op.bytesDelta,
                            createdAt: createdAt
                        )
                    )
                    journalCount += 1

                    if op.verified {
                        switch op.actionType {
                        case .move:
                            movedCount += 1
                        case .rename:
                            renamedCount += 1
                        case .quarantineCopy:
                            quarantinedCount += 1
                        default:
                            break
                        }
                    }
                }

                let successfulCount = movedCount + renamedCount + quarantinedCount
                let nextStatus: BundleStatus = successfulCount > 0 ? .applied : .pending
                try updateBundleStatusInternal(id: bundleID, status: nextStatus)
                try updateBundleActionInternal(id: bundleID, action: action)
                try commitTransaction()
                return BundleApplyTransactionResult(
                    movedCount: movedCount,
                    renamedCount: renamedCount,
                    quarantinedCount: quarantinedCount,
                    journalCount: journalCount
                )
            } catch {
                try? rollbackTransaction()
                throw error
            }
        }
    }

    // MARK: - Internal row readers

    private func readRule(stmt: OpaquePointer?) -> UserRule {
        let id = columnText(stmt, index: 0) ?? UUID().uuidString
        let name = columnText(stmt, index: 1) ?? "Untitled rule"
        let isEnabled = sqlite3_column_int(stmt, 2) == 1

        let bundleType = columnText(stmt, index: 3).flatMap(BundleType.init(rawValue:))
        let scope = columnText(stmt, index: 4).flatMap(RootScope.init(rawValue:))
        let fileExt = columnText(stmt, index: 5)
        let namePattern = columnText(stmt, index: 6)

        let actionKind = columnText(stmt, index: 7).flatMap(BundleActionKind.init(rawValue:)) ?? .rename
        let renameTemplate = columnText(stmt, index: 8)
        let targetFolderBookmark = columnBlob(stmt, index: 9)

        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 10))
        let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 11))
        let matchedCount = Int(sqlite3_column_int(stmt, 12))
        let appliedCount = Int(sqlite3_column_int(stmt, 13))

        return UserRule(
            id: id,
            name: name,
            isEnabled: isEnabled,
            match: RuleMatch(
                bundleType: bundleType,
                scope: scope,
                fileExt: fileExt,
                namePattern: namePattern
            ),
            action: BundleActionConfig(
                actionKind: actionKind,
                renameTemplate: renameTemplate,
                targetFolderBookmark: targetFolderBookmark
            ),
            createdAt: createdAt,
            updatedAt: updatedAt,
            stats: RuleStats(matchedCount: matchedCount, appliedCount: appliedCount)
        )
    }

    private func readIndexedFile(stmt: OpaquePointer?) -> IndexedFile {
        let id = columnText(stmt, index: 0) ?? UUID().uuidString
        let path = columnText(stmt, index: 1) ?? ""
        let scopeRaw = columnText(stmt, index: 2) ?? RootScope.downloads.rawValue
        let name = columnText(stmt, index: 3) ?? URL(fileURLWithPath: path).lastPathComponent
        let ext = columnText(stmt, index: 4) ?? ""
        let size = sqlite3_column_int64(stmt, 5)
        let modified = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))
        let seen = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7))
        let sha = columnText(stmt, index: 8)

        return IndexedFile(
            id: id,
            path: path,
            rootScope: RootScope(rawValue: scopeRaw) ?? .downloads,
            name: name,
            ext: ext,
            sizeBytes: size,
            modifiedAt: modified,
            lastSeenAt: seen,
            sha256: sha
        )
    }

    private func readQuarantineItem(stmt: OpaquePointer?) -> QuarantineItem {
        let id = columnText(stmt, index: 0) ?? ""
        let original = columnText(stmt, index: 1) ?? ""
        let quarantine = columnText(stmt, index: 2) ?? ""
        let sha = columnText(stmt, index: 3) ?? ""
        let size = sqlite3_column_int64(stmt, 4)
        let quarantinedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))
        let stateRaw = columnText(stmt, index: 6) ?? QuarantineState.active.rawValue
        return QuarantineItem(
            id: id,
            originalPath: original,
            quarantinePath: quarantine,
            sha256: sha,
            sizeBytes: size,
            quarantinedAt: quarantinedAt,
            state: QuarantineState(rawValue: stateRaw) ?? .active
        )
    }

    private func readFileIntelligence(stmt: OpaquePointer?) -> FileIntelligence {
        let filePath = columnText(stmt, index: 0) ?? ""
        let category = columnText(stmt, index: 1) ?? "其他"
        let summary = columnText(stmt, index: 2) ?? ""
        let suggestedFolder = columnText(stmt, index: 3) ?? ""
        let keepRaw = columnText(stmt, index: 4) ?? FileIntelligence.KeepOrDelete.unsure.rawValue
        let reason = columnText(stmt, index: 5) ?? ""
        let confidence = sqlite3_column_double(stmt, 6)
        let analyzedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7))

        return FileIntelligence(
            filePath: filePath,
            category: category,
            summary: summary,
            suggestedFolder: suggestedFolder,
            keepOrDelete: FileIntelligence.KeepOrDelete(rawValue: keepRaw) ?? .unsure,
            reason: reason,
            confidence: confidence,
            analyzedAt: analyzedAt
        )
    }

    private func readBundleRow(stmt: OpaquePointer?, id: String, forcePendingIfSkipped: Bool) throws -> DecisionBundle {
        let decoder = JSONDecoder()

        let typeRaw = columnText(stmt, index: 1) ?? BundleType.weeklyDownloadsPDF.rawValue
        let title = columnText(stmt, index: 2) ?? ""
        let summary = columnText(stmt, index: 3) ?? ""
        let actionKindRaw = columnText(stmt, index: 4) ?? BundleActionKind.rename.rawValue
        let renameTemplate = columnText(stmt, index: 5)
        let targetBookmark = columnBlob(stmt, index: 6)
        let evidenceData = Data((columnText(stmt, index: 7) ?? "[]").utf8)
        let riskRaw = columnText(stmt, index: 8) ?? RiskLevel.low.rawValue
        let statusRaw = columnText(stmt, index: 9) ?? BundleStatus.pending.rawValue
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 10))

        let snoozedUntil: Date?
        if sqlite3_column_type(stmt, 11) == SQLITE_NULL {
            snoozedUntil = nil
        } else {
            snoozedUntil = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 11))
        }
        let matchedRuleID = columnText(stmt, index: 12)

        let evidence: [EvidenceItem]
        if let decoded = try? decoder.decode([EvidenceItem].self, from: evidenceData) {
            evidence = decoded
        } else if let legacy = try? decoder.decode([String].self, from: evidenceData) {
            evidence = legacy.map {
                EvidenceItem(
                    id: UUID().uuidString,
                    kind: .ruleMatch,
                    title: "Legacy evidence",
                    detail: $0,
                    supportingFileIDs: nil,
                    supportingRuleID: nil
                )
            }
        } else {
            evidence = []
        }
        let filePaths = try loadBundleItemsInternal(bundleID: id)

        var status = BundleStatus(rawValue: statusRaw) ?? .pending
        if forcePendingIfSkipped, status == .skipped {
            status = .pending
        }

        return DecisionBundle(
            id: id,
            type: BundleType(rawValue: typeRaw) ?? .weeklyDownloadsPDF,
            title: title,
            summary: summary,
            action: BundleActionConfig(
                actionKind: BundleActionKind(rawValue: actionKindRaw) ?? .rename,
                renameTemplate: renameTemplate,
                targetFolderBookmark: targetBookmark
            ),
            evidence: evidence,
            risk: RiskLevel(rawValue: riskRaw) ?? .low,
            filePaths: filePaths,
            status: status,
            createdAt: createdAt,
            snoozedUntil: snoozedUntil,
            matchedRuleID: matchedRuleID
        )
    }

    // MARK: - Internal mutation helpers (must be called inside queue.sync)

    private func upsertBundleInternal(_ bundle: DecisionBundle) throws {
        let sql = """
        INSERT INTO bundles(id, type, title, summary, action_kind, rename_template, target_folder_bookmark, evidence_json, risk_level, status, created_at, snoozed_until, matched_rule_id)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            type = excluded.type,
            title = excluded.title,
            summary = excluded.summary,
            action_kind = excluded.action_kind,
            rename_template = excluded.rename_template,
            target_folder_bookmark = excluded.target_folder_bookmark,
            evidence_json = excluded.evidence_json,
            risk_level = excluded.risk_level,
            status = excluded.status,
            created_at = excluded.created_at,
            snoozed_until = excluded.snoozed_until,
            matched_rule_id = excluded.matched_rule_id
        """

        let encoder = JSONEncoder()
        let evidenceJSON = try String(data: encoder.encode(bundle.evidence), encoding: .utf8) ?? "[]"

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        try prepare(sql: sql, stmt: &stmt)
        try bindText(bundle.id, index: 1, stmt: stmt)
        try bindText(bundle.type.rawValue, index: 2, stmt: stmt)
        try bindText(bundle.title, index: 3, stmt: stmt)
        try bindText(bundle.summary, index: 4, stmt: stmt)
        try bindText(bundle.action.actionKind.rawValue, index: 5, stmt: stmt)

        if let template = bundle.action.renameTemplate {
            try bindText(template, index: 6, stmt: stmt)
        } else {
            sqlite3_bind_null(stmt, 6)
        }

        if let bookmark = bundle.action.targetFolderBookmark {
            try bindBlob(bookmark, index: 7, stmt: stmt)
        } else {
            sqlite3_bind_null(stmt, 7)
        }

        try bindText(evidenceJSON, index: 8, stmt: stmt)
        try bindText(bundle.risk.rawValue, index: 9, stmt: stmt)
        try bindText(bundle.status.rawValue, index: 10, stmt: stmt)
        sqlite3_bind_double(stmt, 11, bundle.createdAt.timeIntervalSince1970)

        if let snoozed = bundle.snoozedUntil {
            sqlite3_bind_double(stmt, 12, snoozed.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(stmt, 12)
        }
        if let matchedRuleID = bundle.matchedRuleID {
            try bindText(matchedRuleID, index: 13, stmt: stmt)
        } else {
            sqlite3_bind_null(stmt, 13)
        }

        try stepDone(stmt)
    }

    private func replaceBundleItems(bundleID: String, filePaths: [String]) throws {
        let deleteSQL = "DELETE FROM bundle_items WHERE bundle_id = ?"
        var deleteStmt: OpaquePointer?
        defer { sqlite3_finalize(deleteStmt) }
        try prepare(sql: deleteSQL, stmt: &deleteStmt)
        try bindText(bundleID, index: 1, stmt: deleteStmt)
        try stepDone(deleteStmt)

        if filePaths.isEmpty {
            return
        }

        let insertSQL = "INSERT INTO bundle_items(bundle_id, file_path) VALUES (?, ?)"
        var insertStmt: OpaquePointer?
        defer { sqlite3_finalize(insertStmt) }
        try prepare(sql: insertSQL, stmt: &insertStmt)

        for path in filePaths {
            sqlite3_reset(insertStmt)
            sqlite3_clear_bindings(insertStmt)
            try bindText(bundleID, index: 1, stmt: insertStmt)
            try bindText(path, index: 2, stmt: insertStmt)
            try stepDone(insertStmt)
        }
    }

    private func loadBundleItemsInternal(bundleID: String) throws -> [String] {
        let sql = "SELECT file_path FROM bundle_items WHERE bundle_id = ? ORDER BY file_path ASC"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        try prepare(sql: sql, stmt: &stmt)
        try bindText(bundleID, index: 1, stmt: stmt)

        var paths: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            paths.append(columnText(stmt, index: 0) ?? "")
        }
        return paths
    }

    private func updateBundleStatusInternal(id: String, status: BundleStatus) throws {
        let sql = "UPDATE bundles SET status = ?, snoozed_until = NULL WHERE id = ?"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        try prepare(sql: sql, stmt: &stmt)
        try bindText(status.rawValue, index: 1, stmt: stmt)
        try bindText(id, index: 2, stmt: stmt)
        try stepDone(stmt)
    }

    private func updateBundleActionInternal(id: String, action: BundleActionConfig) throws {
        let sql = """
        UPDATE bundles
        SET action_kind = ?, rename_template = ?, target_folder_bookmark = ?
        WHERE id = ?
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        try prepare(sql: sql, stmt: &stmt)
        try bindText(action.actionKind.rawValue, index: 1, stmt: stmt)
        if let template = action.renameTemplate {
            try bindText(template, index: 2, stmt: stmt)
        } else {
            sqlite3_bind_null(stmt, 2)
        }

        if let bookmark = action.targetFolderBookmark {
            try bindBlob(bookmark, index: 3, stmt: stmt)
        } else {
            sqlite3_bind_null(stmt, 3)
        }

        try bindText(id, index: 4, stmt: stmt)
        try stepDone(stmt)
    }

    private func fileByPathInternal(_ path: String) throws -> IndexedFile? {
        let sql = """
        SELECT id, path, root_scope, name, ext, size_bytes, modified_at, last_seen_at, sha256
        FROM files
        WHERE path = ?
        LIMIT 1
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        try prepare(sql: sql, stmt: &stmt)
        try bindText(path, index: 1, stmt: stmt)

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return nil
        }
        return readIndexedFile(stmt: stmt)
    }

    private func updateIndexedFilePathInternal(oldPath: String,
                                               newPath: String,
                                               newScope: RootScope?,
                                               modifiedAt: Date,
                                               lastSeenAt: Date) throws {
        let sql = """
        UPDATE files
        SET path = ?,
            root_scope = COALESCE(?, root_scope),
            status = CASE
                WHEN COALESCE(?, root_scope) = 'archived' THEN 'archived'
                ELSE 'active'
            END,
            name = ?,
            ext = ?,
            modified_at = ?,
            last_seen_at = ?
        WHERE path = ?
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        try prepare(sql: sql, stmt: &stmt)
        let newURL = URL(fileURLWithPath: newPath)
        try bindText(newPath, index: 1, stmt: stmt)
        if let newScope {
            try bindText(newScope.rawValue, index: 2, stmt: stmt)
        } else {
            sqlite3_bind_null(stmt, 2)
        }
        if let newScope {
            try bindText(newScope.rawValue, index: 3, stmt: stmt)
        } else {
            sqlite3_bind_null(stmt, 3)
        }
        try bindText(newURL.lastPathComponent, index: 4, stmt: stmt)
        try bindText(newURL.pathExtension.lowercased(), index: 5, stmt: stmt)
        sqlite3_bind_double(stmt, 6, modifiedAt.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 7, lastSeenAt.timeIntervalSince1970)
        try bindText(oldPath, index: 8, stmt: stmt)
        try stepDone(stmt)
    }

    private func insertQuarantineItemInternal(id: String,
                                              fileID: String,
                                              originalPath: String,
                                              quarantinePath: String,
                                              sha256: String,
                                              sizeBytes: Int64,
                                              quarantinedAt: Date,
                                              expiresAt: Date,
                                              state: QuarantineState) throws {
        let sql = """
        INSERT INTO quarantine_items(id, file_id, original_path, quarantine_path, sha256, size_bytes, quarantined_at, expires_at, state)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        try prepare(sql: sql, stmt: &stmt)
        try bindText(id, index: 1, stmt: stmt)
        try bindText(fileID, index: 2, stmt: stmt)
        try bindText(originalPath, index: 3, stmt: stmt)
        try bindText(quarantinePath, index: 4, stmt: stmt)
        try bindText(sha256, index: 5, stmt: stmt)
        sqlite3_bind_int64(stmt, 6, sizeBytes)
        sqlite3_bind_double(stmt, 7, quarantinedAt.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 8, expiresAt.timeIntervalSince1970)
        try bindText(state.rawValue, index: 9, stmt: stmt)
        try stepDone(stmt)
    }

    private func insertJournalEntryInternal(_ entry: JournalInsert) throws {
        let sql = """
        INSERT INTO journal_entries(
            id, txn_id, actor, action_type, target_type, target_id,
            src_path, dst_path, copy_or_move, conflict_resolution,
            verified, error_code, error_message, bytes_delta,
            created_at, undo_status, undoable
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'active', ?)
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        try prepare(sql: sql, stmt: &stmt)
        try bindText(entry.id, index: 1, stmt: stmt)
        try bindText(entry.txnID, index: 2, stmt: stmt)
        try bindText(entry.actor, index: 3, stmt: stmt)
        try bindText(entry.actionType.rawValue, index: 4, stmt: stmt)
        try bindText(entry.targetType, index: 5, stmt: stmt)
        try bindText(entry.targetID, index: 6, stmt: stmt)
        try bindText(entry.srcPath, index: 7, stmt: stmt)
        try bindText(entry.dstPath, index: 8, stmt: stmt)
        try bindText(entry.copyOrMove, index: 9, stmt: stmt)
        try bindText(entry.conflictResolution, index: 10, stmt: stmt)
        sqlite3_bind_int(stmt, 11, entry.verified ? 1 : 0)
        if let code = entry.errorCode {
            try bindText(code, index: 12, stmt: stmt)
        } else {
            sqlite3_bind_null(stmt, 12)
        }
        if let message = entry.errorMessage {
            try bindText(message, index: 13, stmt: stmt)
        } else {
            sqlite3_bind_null(stmt, 13)
        }
        sqlite3_bind_int64(stmt, 14, entry.bytesDelta)
        sqlite3_bind_double(stmt, 15, entry.createdAt.timeIntervalSince1970)
        sqlite3_bind_int(stmt, 16, entry.undoable ? 1 : 0)
        try stepDone(stmt)
    }

    private func makeRuleMatchKey(match: RuleMatch) -> String {
        let type = match.bundleType?.rawValue ?? "*"
        let scope = match.scope?.rawValue ?? "*"
        let ext = match.fileExt?.lowercased() ?? "*"
        let pattern = match.namePattern?.lowercased() ?? "*"
        return "bt=\(type)|sc=\(scope)|ext=\(ext)|np=\(pattern)"
    }

    private func resolveRuleIDByMatchKey(matchKey: String, fallback: String) throws -> String {
        let sql = "SELECT id FROM rules WHERE match_key = ? LIMIT 1"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        try prepare(sql: sql, stmt: &stmt)
        try bindText(matchKey, index: 1, stmt: stmt)
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return fallback
        }
        return columnText(stmt, index: 0) ?? fallback
    }

    private func beginTransaction() throws {
        try execute(sql: "BEGIN IMMEDIATE TRANSACTION")
    }

    private func commitTransaction() throws {
        try execute(sql: "COMMIT")
    }

    private func rollbackTransaction() throws {
        try execute(sql: "ROLLBACK")
    }

    // MARK: - Queue / DB lifecycle helpers

    private func syncOnQueue<T>(_ work: () throws -> T) throws -> T {
        if isOnQueue {
            #if DEBUG
            assertionFailure("[SQLiteStore] Reentrant sync detected. Public SQLiteStore methods must not be called from inside store queue.")
            #endif
            let error = NSError(
                domain: "SQLiteStore",
                code: 910,
                userInfo: [NSLocalizedDescriptionKey: "Reentrant SQLite queue access detected. Use unlocked helpers inside sync blocks."]
            )
            print("[SQLiteStore] \(error.localizedDescription)")
            throw error
        }
        return try queue.sync(execute: work)
    }

    private var isOnQueue: Bool {
        DispatchQueue.getSpecific(key: queueKey) == queueTag
    }

    private func openDatabaseUnlocked() throws {
        if sqlite3_open(dbURL.path, &db) != SQLITE_OK {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw NSError(domain: "SQLiteStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to open SQLite: \(msg)"])
        }
        try execute(sql: "PRAGMA foreign_keys = ON;")
    }

    private func closeDatabaseUnlocked() {
        if let db {
            sqlite3_close(db)
            self.db = nil
        }
    }

    private func removeDatabaseFilesUnlocked() throws {
        let fm = FileManager.default
        let paths = [
            dbURL.path,
            dbURL.path + "-wal",
            dbURL.path + "-shm"
        ]
        for path in paths where fm.fileExists(atPath: path) {
            try fm.removeItem(atPath: path)
        }
    }

    // MARK: - SQL helpers

    private func execute(sql: String) throws {
        guard let db else {
            throw NSError(domain: "SQLiteStore", code: 2, userInfo: [NSLocalizedDescriptionKey: "DB not opened"])
        }
        var errorMessage: UnsafeMutablePointer<Int8>?
        if sqlite3_exec(db, sql, nil, nil, &errorMessage) != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errorMessage)
            throw NSError(domain: "SQLiteStore", code: 3, userInfo: [NSLocalizedDescriptionKey: "SQL exec failed: \(message)"])
        }
    }

    private func prepare(sql: String, stmt: inout OpaquePointer?, allowSchemaRetry: Bool = true) throws {
        guard let db else {
            throw NSError(domain: "SQLiteStore", code: 4, userInfo: [NSLocalizedDescriptionKey: "DB not opened"])
        }
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        if rc != SQLITE_OK {
            let message = String(cString: sqlite3_errmsg(db))
            if allowSchemaRetry, isSchemaMismatchError(message) {
                print("[SQLiteStore] schema mismatch detected, retrying migrate once: \(message)")
                sqlite3_finalize(stmt)
                stmt = nil
                do {
                    try migrate()
                    try prepare(sql: sql, stmt: &stmt, allowSchemaRetry: false)
                    return
                } catch {
                    safeModeEnabled = true
                    let reason = "DB needs reset. Schema migrate retry failed: \(message)"
                    print("[SQLiteStore] \(reason)")
                    throw NSError(
                        domain: "SQLiteStore",
                        code: 901,
                        userInfo: [NSLocalizedDescriptionKey: reason]
                    )
                }
            }

            if isSchemaMismatchError(message) {
                safeModeEnabled = true
            }
            throw NSError(
                domain: "SQLiteStore",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "SQL prepare failed: \(message)"]
            )
        }
    }

    private func isSchemaMismatchError(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("no such table") || lower.contains("no such column")
    }

    private func bindText(_ value: String, index: Int32, stmt: OpaquePointer?) throws {
        if sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT) != SQLITE_OK {
            throw NSError(domain: "SQLiteStore", code: 6, userInfo: [NSLocalizedDescriptionKey: "bind text failed"])
        }
    }

    private func bindBlob(_ value: Data, index: Int32, stmt: OpaquePointer?) throws {
        let code = value.withUnsafeBytes { ptr -> Int32 in
            sqlite3_bind_blob(stmt, index, ptr.baseAddress, Int32(value.count), SQLITE_TRANSIENT)
        }
        if code != SQLITE_OK {
            throw NSError(domain: "SQLiteStore", code: 7, userInfo: [NSLocalizedDescriptionKey: "bind blob failed"])
        }
    }

    private func stepDone(_ stmt: OpaquePointer?) throws {
        let code = sqlite3_step(stmt)
        if code != SQLITE_DONE {
            throw NSError(domain: "SQLiteStore", code: 8, userInfo: [NSLocalizedDescriptionKey: "SQL step failed: \(code)"])
        }
    }

    private func columnText(_ stmt: OpaquePointer?, index: Int32) -> String? {
        guard let cString = sqlite3_column_text(stmt, index) else {
            return nil
        }
        return String(cString: cString)
    }

    private func columnBlob(_ stmt: OpaquePointer?, index: Int32) -> Data? {
        let bytes = sqlite3_column_blob(stmt, index)
        let count = sqlite3_column_bytes(stmt, index)
        guard let bytes, count > 0 else {
            return nil
        }
        return Data(bytes: bytes, count: Int(count))
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct BundleOperationRecord {
    let actionType: ActionType
    let srcPath: String
    let dstPath: String
    let newRootScope: RootScope?
    let copyOrMove: String
    let conflictResolution: String
    let verified: Bool
    let errorCode: String?
    let errorMessage: String?
    let bytesDelta: Int64
    let quarantineItemID: String?
    let sha256: String?
}

private extension DateFormatter {
    static let metricsWeekKey: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-'W'ww"
        return formatter
    }()
}
