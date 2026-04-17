import CryptoKit
import Foundation
import SQLite3

final class DebugBundleExporter: DebugBundleExporterProtocol, @unchecked Sendable {
    func export(to destinationURL: URL, now: Date, accessHealth: [AccessTarget: AccessHealthItem]) throws -> URL {
        let normalizedDestination = normalizedDestinationURL(destinationURL)
        let destinationFolder = normalizedDestination.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: destinationFolder.path) else {
            throw DebugExportError.invalidDestination("Destination folder does not exist.")
        }

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("Tidy2Debug-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let salt = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var journal: [JournalExportEntry] = []
        var rules: [DebugRuleDump] = []
        var events: [AppEvent] = []
        var latestTxn: String?
        var settingsValues: [String: String] = [:]

        if let dbPath = try? SQLiteStore.defaultDatabasePath(),
           FileManager.default.fileExists(atPath: dbPath) {
            let reader = try SQLiteSnapshotReader(path: dbPath, busyTimeoutMS: 3_000)
            journal = try reader.loadJournal(limit: 5_000, salt: salt)
            rules = try reader.loadRules(salt: salt)
            events = try reader.loadEvents(limit: 200)
            latestTxn = try reader.latestTxnID()
            settingsValues["archive_root_health"] = try reader.settingValue(key: "archive_root_health") ?? "unknown"
            settingsValues["auto_purge_expired_quarantine"] = try reader.settingValue(key: "auto_purge_expired_quarantine") ?? "0"
            settingsValues["rules_emergency_brake"] = try reader.settingValue(key: "rules_emergency_brake") ?? "0"
            settingsValues["onboarding_completed"] = try reader.settingValue(key: "onboarding_completed") ?? "0"
        }

        let settingsHealth = DebugSettingsHealth(
            archiveHealth: settingsValues["archive_root_health"] ?? "unknown",
            autoPurgeEnabled: settingsValues["auto_purge_expired_quarantine"] ?? "0",
            rulesEmergencyBrake: settingsValues["rules_emergency_brake"] ?? "0",
            onboardingCompleted: settingsValues["onboarding_completed"] ?? "0",
            accessHealth: accessHealth.mapValues { item in
                DebugAccessHealth(status: item.status.rawValue, pathHash: item.path.map { DebugBundleExporter.hashPath($0, salt: salt) })
            }
        )

        let version = DebugVersion(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
            buildNumber: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            exportedAt: now,
            latestTxnID: latestTxn
        )

        try writeJSON(journal, to: tempRoot.appendingPathComponent("journal_anonymized.json"))
        try writeJSON(rules, to: tempRoot.appendingPathComponent("rules_anonymized.json"))
        try writeJSON(settingsHealth, to: tempRoot.appendingPathComponent("settings_health.json"))
        try writeJSON(events, to: tempRoot.appendingPathComponent("events_recent_200.json"))
        try writeJSON(version, to: tempRoot.appendingPathComponent("version.json"))

        if FileManager.default.fileExists(atPath: normalizedDestination.path) {
            try FileManager.default.removeItem(at: normalizedDestination)
        }
        try zipDirectory(tempRoot, to: normalizedDestination, timeoutSeconds: 20)
        return normalizedDestination
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }

    private func normalizedDestinationURL(_ url: URL) -> URL {
        if url.pathExtension.lowercased() == "zip" {
            return url
        }
        return url.appendingPathExtension("zip")
    }

    private static func hashPath(_ path: String, salt: String) -> String {
        guard !path.isEmpty else { return "" }
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path.lowercased()
        let input = Data((salt + "|" + normalized).utf8)
        let digest = SHA256.hash(data: input)
        let hex = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return "path_\(hex)"
    }

    private static func resolveBookmarkPathHash(_ bookmark: Data, salt: String) -> String? {
        var stale = false
        let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        guard let url else { return nil }
        return hashPath(url.path, salt: salt)
    }

    private func zipDirectory(_ directory: URL, to destinationZip: URL, timeoutSeconds: TimeInterval) throws {
        let process = Process()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = directory.deletingLastPathComponent()
        process.arguments = ["-r", "-q", destinationZip.path, directory.lastPathComponent]
        process.standardError = stderrPipe

        try process.run()
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        if process.isRunning {
            process.terminate()
            throw DebugExportError.timeout("zip packaging timed out after \(Int(timeoutSeconds))s")
        }

        guard process.terminationStatus == 0 else {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let detail = stderr.isEmpty ? "zip exit code \(process.terminationStatus)" : stderr
            throw DebugExportError.zipFailed("Failed to zip debug bundle: \(detail)")
        }
    }

    private final class SQLiteSnapshotReader {
        private var db: OpaquePointer?

        init(path: String, busyTimeoutMS: Int32) throws {
            let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
            if sqlite3_open_v2(path, &db, flags, nil) != SQLITE_OK {
                let message = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
                throw DebugExportError.permission("Could not open DB: \(message)")
            }
            sqlite3_busy_timeout(db, busyTimeoutMS)
            _ = sqlite3_exec(db, "PRAGMA query_only = ON;", nil, nil, nil)
        }

        deinit {
            if let db {
                sqlite3_close(db)
            }
        }

        func loadJournal(limit: Int, salt: String) throws -> [JournalExportEntry] {
            guard try tableExists("journal_entries") else { return [] }
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
            while true {
                let code = sqlite3_step(stmt)
                if code == SQLITE_DONE { break }
                if code != SQLITE_ROW {
                    throw sqliteError(code: code, context: "loadJournal")
                }

                rows.append(
                    JournalExportEntry(
                        id: columnText(stmt, index: 0) ?? UUID().uuidString,
                        txnID: columnText(stmt, index: 1) ?? "",
                        actor: columnText(stmt, index: 2) ?? "",
                        actionType: columnText(stmt, index: 3) ?? "",
                        targetType: columnText(stmt, index: 4) ?? "",
                        targetID: columnText(stmt, index: 5) ?? "",
                        srcPath: DebugBundleExporter.hashPath(columnText(stmt, index: 6) ?? "", salt: salt),
                        dstPath: DebugBundleExporter.hashPath(columnText(stmt, index: 7) ?? "", salt: salt),
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

        func loadRules(salt: String) throws -> [DebugRuleDump] {
            guard try tableExists("rules") else { return [] }
            let sql = """
            SELECT id, name, is_enabled, match_bundle_type, match_scope, match_file_ext, match_name_pattern,
                   action_kind, rename_template, target_folder_bookmark, created_at, updated_at, matched_count, applied_count
            FROM rules
            ORDER BY updated_at DESC
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)

            var rules: [DebugRuleDump] = []
            while true {
                let code = sqlite3_step(stmt)
                if code == SQLITE_DONE { break }
                if code != SQLITE_ROW {
                    throw sqliteError(code: code, context: "loadRules")
                }

                let bookmark = columnBlob(stmt, index: 9)
                rules.append(
                    DebugRuleDump(
                        id: columnText(stmt, index: 0) ?? UUID().uuidString,
                        isEnabled: sqlite3_column_int(stmt, 2) == 1,
                        match: DebugRuleMatch(
                            bundleType: columnText(stmt, index: 3),
                            scope: columnText(stmt, index: 4),
                            fileExt: columnText(stmt, index: 5),
                            namePattern: columnText(stmt, index: 6)
                        ),
                        actionKind: columnText(stmt, index: 7) ?? "rename",
                        renameTemplate: columnText(stmt, index: 8),
                        targetFolderHash: bookmark.flatMap { DebugBundleExporter.resolveBookmarkPathHash($0, salt: salt) },
                        createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 10)),
                        updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 11)),
                        matchedCount: Int(sqlite3_column_int(stmt, 12)),
                        appliedCount: Int(sqlite3_column_int(stmt, 13))
                    )
                )
            }
            return rules
        }

        func loadEvents(limit: Int) throws -> [AppEvent] {
            guard try tableExists("app_events") else { return [] }
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
            while true {
                let code = sqlite3_step(stmt)
                if code == SQLITE_DONE { break }
                if code != SQLITE_ROW {
                    throw sqliteError(code: code, context: "loadEvents")
                }

                events.append(
                    AppEvent(
                        id: columnText(stmt, index: 0) ?? UUID().uuidString,
                        createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                        eventType: columnText(stmt, index: 2) ?? "",
                        message: columnText(stmt, index: 3) ?? "",
                        payloadJSON: columnText(stmt, index: 4)
                    )
                )
            }
            return events
        }

        func latestTxnID() throws -> String? {
            guard try tableExists("journal_entries") else { return nil }
            let sql = "SELECT txn_id FROM journal_entries ORDER BY created_at DESC LIMIT 1"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)
            let code = sqlite3_step(stmt)
            if code == SQLITE_DONE { return nil }
            if code != SQLITE_ROW {
                throw sqliteError(code: code, context: "latestTxnID")
            }
            return columnText(stmt, index: 0)
        }

        func settingValue(key: String) throws -> String? {
            guard try tableExists("settings") else { return nil }
            let sql = "SELECT value FROM settings WHERE key = ? LIMIT 1"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)
            try bindText(key, index: 1, stmt: stmt)
            let code = sqlite3_step(stmt)
            if code == SQLITE_DONE { return nil }
            if code != SQLITE_ROW {
                throw sqliteError(code: code, context: "settingValue")
            }
            return columnText(stmt, index: 0)
        }

        private func tableExists(_ name: String) throws -> Bool {
            let sql = "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            try prepare(sql: sql, stmt: &stmt)
            try bindText(name, index: 1, stmt: stmt)
            let code = sqlite3_step(stmt)
            if code == SQLITE_DONE { return false }
            if code != SQLITE_ROW {
                throw sqliteError(code: code, context: "tableExists")
            }
            return true
        }

        private func prepare(sql: String, stmt: inout OpaquePointer?) throws {
            guard let db else {
                throw DebugExportError.database("Snapshot DB is not open.")
            }
            let code = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
            if code != SQLITE_OK {
                throw sqliteError(code: code, context: "prepare")
            }
        }

        private func bindText(_ value: String, index: Int32, stmt: OpaquePointer?) throws {
            if sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT) != SQLITE_OK {
                throw sqliteError(code: sqlite3_errcode(db), context: "bindText")
            }
        }

        private func columnText(_ stmt: OpaquePointer?, index: Int32) -> String? {
            guard let raw = sqlite3_column_text(stmt, index) else { return nil }
            return String(cString: raw)
        }

        private func columnBlob(_ stmt: OpaquePointer?, index: Int32) -> Data? {
            let pointer = sqlite3_column_blob(stmt, index)
            let count = sqlite3_column_bytes(stmt, index)
            guard let pointer, count > 0 else { return nil }
            return Data(bytes: pointer, count: Int(count))
        }

        private func sqliteError(code: Int32, context: String) -> DebugExportError {
            let message = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown sqlite error"
            if code == SQLITE_BUSY || code == SQLITE_LOCKED || message.localizedCaseInsensitiveContains("database is locked") {
                return .databaseLocked("DB locked during \(context).")
            }
            if code == SQLITE_CANTOPEN || message.localizedCaseInsensitiveContains("permission") {
                return .permission("Cannot access DB during \(context): \(message)")
            }
            return .database("SQLite error during \(context): \(message)")
        }
    }

    private enum DebugExportError: LocalizedError {
        case invalidDestination(String)
        case permission(String)
        case databaseLocked(String)
        case database(String)
        case zipFailed(String)
        case timeout(String)

        var errorDescription: String? {
            switch self {
            case let .invalidDestination(message):
                return message
            case let .permission(message):
                return message
            case let .databaseLocked(message):
                return message
            case let .database(message):
                return message
            case let .zipFailed(message):
                return message
            case let .timeout(message):
                return message
            }
        }
    }
}

private struct DebugRuleDump: Encodable {
    let id: String
    let isEnabled: Bool
    let match: DebugRuleMatch
    let actionKind: String
    let renameTemplate: String?
    let targetFolderHash: String?
    let createdAt: Date
    let updatedAt: Date
    let matchedCount: Int
    let appliedCount: Int
}

private struct DebugRuleMatch: Encodable {
    let bundleType: String?
    let scope: String?
    let fileExt: String?
    let namePattern: String?
}

private struct DebugSettingsHealth: Encodable {
    let archiveHealth: String
    let autoPurgeEnabled: String
    let rulesEmergencyBrake: String
    let onboardingCompleted: String
    let accessHealth: [AccessTarget: DebugAccessHealth]
}

private struct DebugAccessHealth: Encodable {
    let status: String
    let pathHash: String?
}

private struct DebugVersion: Encodable {
    let appVersion: String
    let buildNumber: String
    let osVersion: String
    let exportedAt: Date
    let latestTxnID: String?
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
