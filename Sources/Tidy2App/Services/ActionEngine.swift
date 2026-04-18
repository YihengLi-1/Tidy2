import Foundation

final class ActionEngine: ActionEngineServiceProtocol {
    private let store: SQLiteStore
    private let accessManager: AccessManagerProtocol
    private let fileManager = FileManager.default
    private let fileOpQueue = DispatchQueue(label: "tidy2.actionengine.fileops", qos: .utility, attributes: .concurrent)
    private let storeOpQueue = DispatchQueue(label: "tidy2.actionengine.storeops", qos: .utility)

    private let lowRiskQuarantineExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "webp",
        "zip", "dmg", "pkg", "tmp", "log", "part", "crdownload"
    ]

    init(store: SQLiteStore, accessManager: AccessManagerProtocol) {
        self.store = store
        self.accessManager = accessManager
    }

    func autoQuarantineDuplicateGroups(_ groups: [DuplicateScanGroup]) throws -> Int {
        guard !groups.isEmpty else { return 0 }
        try ensureAccessForPaths(groups.flatMap { $0.duplicatesToQuarantine.map(\.path) })

        let txnID = UUID().uuidString
        let now = Date()
        let expiresAt = Calendar.current.date(byAdding: .day, value: 30, to: now) ?? now

        var successCount = 0

        for group in groups {
            for duplicate in group.duplicatesToQuarantine {
                if try store.hasActiveQuarantineItem(originalPath: duplicate.path, sha256: group.sha256) {
                    continue
                }

                let sourceURL = URL(fileURLWithPath: duplicate.path)
                let destinationURL = try makeQuarantineDestination(ext: duplicate.ext)
                let quarantineID = UUID().uuidString

                var verified = false
                var errorCode: String?
                var errorMessage: String?

                do {
                    try ensureParentFolder(for: destinationURL)
                    try fileManager.copyItem(at: sourceURL, to: destinationURL)
                    verified = fileManager.fileExists(atPath: destinationURL.path)

                    if verified {
                        try store.insertQuarantineItem(
                            id: quarantineID,
                            fileID: duplicate.id,
                            originalPath: duplicate.path,
                            quarantinePath: destinationURL.path,
                            sha256: group.sha256,
                            sizeBytes: duplicate.sizeBytes,
                            quarantinedAt: now,
                            expiresAt: expiresAt,
                            state: .active
                        )
                        successCount += 1
                    } else {
                        errorCode = "VERIFY_FAILED"
                        errorMessage = "Copied but destination verification failed"
                    }
                } catch {
                    errorCode = "COPY_FAILED"
                    errorMessage = error.localizedDescription
                }

                try store.insertJournalEntry(
                    .init(
                        id: UUID().uuidString,
                        txnID: txnID,
                        actor: "autopilot",
                        actionType: .quarantineCopy,
                        targetType: "file",
                        targetID: duplicate.id,
                        srcPath: duplicate.path,
                        dstPath: destinationURL.path,
                        copyOrMove: "copy",
                        conflictResolution: "uuid_filename",
                        verified: verified,
                        errorCode: errorCode,
                        errorMessage: errorMessage,
                        bytesDelta: verified ? duplicate.sizeBytes : 0,
                        createdAt: now
                    )
                )
            }
        }

        return successCount
    }

    func applyBundle(bundleID: String, override: BundleApplyOverride?) throws -> BundleApplyResult {
        let startedAt = Date()
        let txnID = UUID().uuidString
        var endMovedCount = 0
        var endRenamedCount = 0
        var endQuarantinedCount = 0
        var endSkippedMissingCount = 0
        var endErrorCount = 0
        var endState = "failed"
        var finishMessage = "Bundle failed: Unknown error."
        var finishDestinationHint: String?

        do {
            try insertBundleApplyStarted(
                txnID: txnID,
                bundleID: bundleID,
                actionHint: override?.actionKind,
                createdAt: startedAt
            )
        } catch {
            appendRuntimeLog("[ActionEngine] apply_journal_start_failed bundle_id=\(bundleID) txn_id=\(txnID) error=\(error.localizedDescription)")
        }
        defer {
            let duration = Date().timeIntervalSince(startedAt)
            appendRuntimeLog(
                "[ActionEngine] apply_end bundle_id=\(bundleID) state=\(endState) moved=\(endMovedCount) errors=\(endErrorCount) duration=\(String(format: "%.2f", duration))"
            )
            do {
                try insertBundleApplyFinished(
                    txnID: txnID,
                    bundleID: bundleID,
                    state: endState,
                    movedCount: endMovedCount,
                    renamedCount: endRenamedCount,
                    quarantinedCount: endQuarantinedCount,
                    skippedMissing: endSkippedMissingCount,
                    destinationHint: finishDestinationHint,
                    message: finishMessage,
                    createdAt: Date()
                )
            } catch {
                appendRuntimeLog("[ActionEngine] apply_journal_finish_failed bundle_id=\(bundleID) txn_id=\(txnID) error=\(error.localizedDescription)")
            }
        }

        do {
            guard let bundle = try runStoreCallWithTimeout(
            name: "load_bundle",
            timeoutSeconds: 8,
            call: { try self.store.loadBundle(id: bundleID) }
            ) else {
                appendRuntimeLog("[ActionEngine] bundle_missing bundle_id=\(bundleID)")
                let message = "Bundle not found"
                finishMessage = "Bundle failed: \(message)"
                throw NSError(domain: "ActionEngine", code: 404, userInfo: [NSLocalizedDescriptionKey: message])
            }

        appendRuntimeLog(
            "[ActionEngine] apply_start bundle_id=\(bundleID) fileCount=\(bundle.filePaths.count) status=\(bundle.status.rawValue) risk=\(bundle.risk.rawValue) override_action=\(override?.actionKind?.rawValue ?? "nil")"
        )

        guard bundle.status == .pending else {
            let message = "Bundle is not pending (status=\(bundle.status.rawValue))."
            appendRuntimeLog("[ActionEngine] apply_blocked bundle_id=\(bundleID) reason=\(message)")
            finishMessage = "Bundle failed: \(message)"
            throw NSError(domain: "ActionEngine", code: 409, userInfo: [NSLocalizedDescriptionKey: message])
        }

        try ensureAccessForPaths(bundle.filePaths)

        var action = bundle.action
        if let actionKind = override?.actionKind {
            action.actionKind = actionKind
        }
        if let renameTemplate = override?.renameTemplate {
            action.renameTemplate = renameTemplate
        }
        if let targetFolderBookmark = override?.targetFolderBookmark {
            action.targetFolderBookmark = targetFolderBookmark
        }

        appendRuntimeLog(
            "[ActionEngine] action_resolved bundle_id=\(bundleID) action=\(action.actionKind.rawValue) has_target_bookmark=\(action.targetFolderBookmark != nil) has_rename_template=\((action.renameTemplate?.isEmpty == false))"
        )

        if bundle.type == .crossDirectoryGroup {
            guard action.actionKind == .move else {
                let message = "跨目录整理建议只支持移动操作"
                appendRuntimeLog("[ActionEngine] apply_blocked bundle_id=\(bundleID) reason=\(message)")
                finishMessage = "Bundle failed: \(message)"
                throw NSError(domain: "ActionEngine", code: 400, userInfo: [NSLocalizedDescriptionKey: message])
            }
        }

        let allowsHighRiskMove = override?.allowHighRiskMoveOverride == true
        if action.actionKind == .move && bundle.risk == .high && !allowsHighRiskMove {
            let message = "High-risk bundle is blocked from move. Use rename/quarantine instead."
            appendRuntimeLog("[ActionEngine] apply_blocked bundle_id=\(bundleID) reason=\(message)")
            finishMessage = "Bundle failed: \(message)"
            throw NSError(domain: "ActionEngine", code: 400, userInfo: [NSLocalizedDescriptionKey: message])
        }

        let existingFilePaths = bundle.filePaths.filter { fileManager.fileExists(atPath: $0) }
        let missingFilePaths = bundle.filePaths.filter { !fileManager.fileExists(atPath: $0) }
        appendRuntimeLog(
            "[ActionEngine] source_files bundle_id=\(bundleID) existing=\(existingFilePaths.count) missing=\(missingFilePaths.count) total=\(bundle.filePaths.count)"
        )
        guard !existingFilePaths.isEmpty else {
            let message = "No source files found. Please run Full Scan."
            appendRuntimeLog("[ActionEngine] apply_failed bundle_id=\(bundleID) reason=\(message)")
            finishMessage = "Bundle failed: \(message)"
            throw NSError(domain: "ActionEngine", code: 410, userInfo: [NSLocalizedDescriptionKey: message])
        }

        let now = Date()
        var extraJournalEntries: [SQLiteStore.JournalInsert] = []
        let shouldLearnRule: Bool

        let coreOperations: [BundleOperationRecord]
        let skippedByRiskPolicy: Int
        let skippedMissingCount = missingFilePaths.count
        var destinationHint: String?
        endSkippedMissingCount = skippedMissingCount

        switch action.actionKind {
        case .rename:
            let template = (action.renameTemplate?.isEmpty == false) ? action.renameTemplate! : defaultTemplate(for: bundle.type)
            let result = try buildRenameOperations(filePaths: existingFilePaths, template: template, baseDate: now)
            coreOperations = result.operations
            skippedByRiskPolicy = 0
            destinationHint = nil

        case .quarantine:
            let result = try buildQuarantineOperations(filePaths: existingFilePaths)
            coreOperations = result.operations
            skippedByRiskPolicy = result.skippedByRisk
            destinationHint = nil

        case .move:
            let archiveRoot = try resolveArchiveRootURL(action: action)
            appendRuntimeLog("[ActionEngine] archive_root_resolved bundle_id=\(bundleID) path=\(archiveRoot.path)")
            guard archiveRoot.startAccessingSecurityScopedResource() else {
                let message = "Archive root bookmark is not accessible. Please re-authorize folder."
                appendRuntimeLog("[ActionEngine] apply_failed bundle_id=\(bundleID) reason=\(message)")
                finishMessage = "Bundle failed: \(message)"
                throw NSError(domain: "ActionEngine", code: 403, userInfo: [NSLocalizedDescriptionKey: message])
            }
            defer { archiveRoot.stopAccessingSecurityScopedResource() }

            // For AI-grouped cross-directory bundles, honour the AI-suggested
            // subfolder stored in the evidence rather than the generic type bucket.
            let aiSubfolder: String?
            if bundle.type == .crossDirectoryGroup {
                aiSubfolder = bundle.evidence
                    .compactMap(\.aiSuggestedFolder)
                    .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            } else {
                aiSubfolder = nil
            }

            let result = try buildMoveOperations(
                filePaths: existingFilePaths,
                bundleType: bundle.type,
                archiveRoot: archiveRoot,
                renameTemplate: action.renameTemplate,
                baseDate: now,
                aiSubfolder: aiSubfolder
            )
            appendRuntimeLog("[ActionEngine] destination_folder bundle_id=\(bundleID) path=\(result.destinationFolder.path)")
            coreOperations = result.operations
            skippedByRiskPolicy = 0
            destinationHint = "Moved to \(result.destinationFolder.path)"
            finishDestinationHint = destinationHint

            if bundle.risk == .high && allowsHighRiskMove {
                appendRuntimeLog("[ActionEngine] high_risk_override bundle_id=\(bundleID) enabled=1")
                extraJournalEntries.append(
                    .init(
                        id: UUID().uuidString,
                        txnID: txnID,
                        actor: "user",
                        actionType: .overrideRisk,
                        targetType: "bundle",
                        targetID: bundleID,
                        srcPath: bundleID,
                        dstPath: bundleID,
                        copyOrMove: "none",
                        conflictResolution: "user_override",
                        verified: true,
                        errorCode: nil,
                        errorMessage: "One-time high-risk move override",
                        bytesDelta: 0,
                        createdAt: now
                    )
                )
            }
        }

        let missingOperations = buildMissingOperations(
            filePaths: missingFilePaths,
            actionKind: action.actionKind
        )
        let operations = coreOperations + missingOperations

        let firstOperationError = operations.first(where: { !$0.verified })?.errorMessage ??
            operations.first(where: { !$0.verified })?.errorCode

        appendRuntimeLog(
            "[ActionEngine] operations_ready bundle_id=\(bundleID) action=\(action.actionKind.rawValue) attempted=\(operations.count) skipped_missing=\(skippedMissingCount) first_error=\(firstOperationError ?? "none")"
        )

        shouldLearnRule = hasTrainingSignal(bundle: bundle, finalAction: action)

        let txResult: SQLiteStore.BundleApplyTransactionResult
        do {
            txResult = try runBundleApplyTransactionWithTimeout(
                bundleID: bundleID,
                action: action,
                operations: operations,
                actor: "user",
                txnID: txnID,
                createdAt: now,
                extraJournalEntries: extraJournalEntries,
                timeoutSeconds: 12
            )
        } catch {
            appendRuntimeLog("[ActionEngine] txn_failed bundle_id=\(bundleID) txn_id=\(txnID) error=\(error.localizedDescription)")
            finishMessage = "Bundle failed: \(error.localizedDescription)"
            throw error
        }

        appendRuntimeLog(
            "[ActionEngine] txn_committed bundle_id=\(bundleID) txn_id=\(txnID) moved=\(txResult.movedCount) renamed=\(txResult.renamedCount) quarantined=\(txResult.quarantinedCount) journal_rows=\(txResult.journalCount)"
        )

        let learnedRuleID: String?
        if shouldLearnRule {
            learnedRuleID = try? learnRuleFromUserOverride(bundle: bundle, action: action, now: now)
        } else {
            learnedRuleID = nil
        }

        if let appliedRuleID = learnedRuleID ?? bundle.matchedRuleID {
            try? runStoreCallWithTimeout(
                name: "increment_rule_applied",
                timeoutSeconds: 5,
                call: { try self.store.incrementRuleAppliedCount(ruleID: appliedRuleID) }
            )
        }

        let succeeded = txResult.movedCount + txResult.renamedCount + txResult.quarantinedCount
        let failed = operations.count - succeeded
        endMovedCount = txResult.movedCount
        endRenamedCount = txResult.renamedCount
        endQuarantinedCount = txResult.quarantinedCount
        endErrorCount = failed
        let summary = bundleApplySummaryMessage(
            moved: txResult.movedCount,
            renamed: txResult.renamedCount,
            quarantined: txResult.quarantinedCount,
            skippedMissing: skippedMissingCount,
            failed: failed
        )
        finishMessage = summary
        if succeeded == 0 {
            endState = "failed"
            if let firstOperationError, !firstOperationError.isEmpty {
                finishMessage = "Bundle failed: \(firstOperationError)"
            } else {
                finishMessage = "Bundle failed: No file operations succeeded."
            }
        } else {
            endState = failed > 0 ? "partial" : "success"
        }

            return BundleApplyResult(
                txnId: txnID,
                attempted: operations.count,
                succeeded: succeeded,
                failed: failed,
                skippedByRiskPolicy: skippedByRiskPolicy,
                skippedMissing: skippedMissingCount,
                movedCount: txResult.movedCount,
                renamedCount: txResult.renamedCount,
                quarantinedCount: txResult.quarantinedCount,
                journalCount: txResult.journalCount,
                destinationHint: destinationHint,
                firstError: firstOperationError
            )
        } catch {
            if finishMessage == "Bundle failed: Unknown error." {
                finishMessage = "Bundle failed: \(error.localizedDescription)"
            }
            endState = "failed"
            if endErrorCount == 0 {
                endErrorCount = 1
            }
            throw error
        }
    }

    func restore(quarantineItemID: String) throws {
        guard let item = try store.loadQuarantineItem(id: quarantineItemID) else {
            throw NSError(domain: "ActionEngine", code: 404, userInfo: [NSLocalizedDescriptionKey: "Quarantine item not found"])
        }
        guard item.state == .active else {
            throw NSError(domain: "ActionEngine", code: 409, userInfo: [NSLocalizedDescriptionKey: "Quarantine item is not active"])
        }
        try ensureAccessForPaths([item.originalPath])

        let txnID = UUID().uuidString
        let now = Date()

        let sourceURL = URL(fileURLWithPath: item.quarantinePath)
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            try store.insertJournalEntry(
                .init(
                    id: UUID().uuidString,
                    txnID: txnID,
                    actor: "user",
                    actionType: .restore,
                    targetType: "quarantine_item",
                    targetID: item.id,
                    srcPath: sourceURL.path,
                    dstPath: item.originalPath,
                    copyOrMove: "copy",
                    conflictResolution: "rename_on_conflict",
                    verified: false,
                    errorCode: "SOURCE_MISSING",
                    errorMessage: "Quarantine file missing",
                    bytesDelta: 0,
                    createdAt: now
                )
            )
            throw NSError(domain: "ActionEngine", code: 410, userInfo: [NSLocalizedDescriptionKey: "Quarantine file missing"])
        }

        let originalURL = URL(fileURLWithPath: item.originalPath)
        let destinationURL: URL
        let conflictResolution: String
        if fileManager.fileExists(atPath: originalURL.path) {
            destinationURL = conflictResolvedRestoreURL(for: originalURL)
            conflictResolution = "rename_on_conflict"
        } else {
            destinationURL = originalURL
            conflictResolution = "none"
        }

        var verified = false
        var errorCode: String?
        var errorMessage: String?

        do {
            try ensureParentFolder(for: destinationURL)
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            verified = fileManager.fileExists(atPath: destinationURL.path)

            if verified {
                try store.updateQuarantineItemState(id: item.id, state: .restored)
            } else {
                errorCode = "VERIFY_FAILED"
                errorMessage = "Restore verification failed"
            }
        } catch {
            errorCode = "RESTORE_COPY_FAILED"
            errorMessage = error.localizedDescription
        }

        try store.insertJournalEntry(
            .init(
                id: UUID().uuidString,
                txnID: txnID,
                actor: "user",
                actionType: .restore,
                targetType: "quarantine_item",
                targetID: item.id,
                srcPath: sourceURL.path,
                dstPath: destinationURL.path,
                copyOrMove: "copy",
                conflictResolution: conflictResolution,
                verified: verified,
                errorCode: errorCode,
                errorMessage: errorMessage,
                bytesDelta: verified ? item.sizeBytes : 0,
                createdAt: now
            )
        )

        if !verified {
            throw NSError(domain: "ActionEngine", code: 500, userInfo: [NSLocalizedDescriptionKey: errorMessage ?? "Restore failed"])
        }
    }

    func purgeExpiredQuarantine(actor: String) throws -> PurgeResult {
        let expiredItems = try store.listQuarantineItems(states: [.expired])
        return try purgeQuarantineItems(
            expiredItems,
            actor: actor,
            conflictResolution: "expired_policy",
            successMessage: "Purged expired quarantine item"
        )
    }

    func purgeSafeCleanupQuarantine(actor: String) throws -> PurgeResult {
        let safeItems = try store.listSafeCleanupQuarantineItems()
        return try purgeQuarantineItems(
            safeItems,
            actor: actor,
            conflictResolution: "safe_cleanup",
            successMessage: "Purged safe cleanup quarantine item"
        )
    }

    private func purgeQuarantineItems(_ items: [QuarantineItem],
                                      actor: String,
                                      conflictResolution: String,
                                      successMessage: String) throws -> PurgeResult {
        let txnID = UUID().uuidString
        guard !items.isEmpty else {
            return PurgeResult(txnId: txnID, attempted: 0, purged: 0, failed: 0, freedBytes: 0)
        }

        let now = Date()
        let quarantineRoot = try quarantineRootURL().standardizedFileURL.path + "/"
        var purged = 0
        var failed = 0
        var freedBytes: Int64 = 0
        var deletedIDs: [String] = []
        var missingIDs: [String] = []

        for item in items {
            let resolvedURL = URL(fileURLWithPath: item.quarantinePath)
                .resolvingSymlinksInPath()
                .standardizedFileURL
            let path = resolvedURL.path
            var verified = false
            var errorCode: String?
            var errorMessage: String?

            if path.contains("/../") || path.hasPrefix("../") {
                failed += 1
                errorCode = "UNSAFE_PATH"
                errorMessage = "Refused purge with parent traversal"
            } else if !path.hasPrefix(quarantineRoot) {
                failed += 1
                errorCode = "UNSAFE_PATH"
                errorMessage = "Refused purge outside quarantine root"
            } else if item.quarantinePath != path && !item.quarantinePath.hasPrefix(quarantineRoot) {
                failed += 1
                errorCode = "SYMLINK_ESCAPE"
                errorMessage = "Refused purge due to symlink escape"
            } else if !fileManager.fileExists(atPath: path) {
                failed += 1
                missingIDs.append(item.id)
                errorCode = "SOURCE_MISSING"
                errorMessage = "Expired file already missing"
            } else {
                do {
                    try fileManager.removeItem(atPath: path)
                    verified = !fileManager.fileExists(atPath: path)
                    if verified {
                        purged += 1
                        freedBytes += item.sizeBytes
                        deletedIDs.append(item.id)
                        errorMessage = successMessage
                    } else {
                        failed += 1
                        errorCode = "VERIFY_FAILED"
                        errorMessage = "File still exists after purge"
                    }
                } catch {
                    failed += 1
                    errorCode = "PURGE_FAILED"
                    errorMessage = error.localizedDescription
                }
            }

            try store.insertJournalEntry(
                .init(
                    id: UUID().uuidString,
                    txnID: txnID,
                    actor: actor,
                    actionType: .purgeExpired,
                    targetType: "quarantine_item",
                    targetID: item.id,
                    srcPath: item.quarantinePath,
                    dstPath: "",
                    copyOrMove: "delete",
                    conflictResolution: conflictResolution,
                    verified: verified,
                    errorCode: errorCode,
                    errorMessage: errorMessage,
                    bytesDelta: verified ? item.sizeBytes : 0,
                    createdAt: now,
                    undoable: false
                )
            )
        }

        if !deletedIDs.isEmpty {
            try store.setQuarantineState(ids: deletedIDs, state: .deleted)
        }
        if !missingIDs.isEmpty {
            try store.setQuarantineState(ids: missingIDs, state: .missing)
        }

        return PurgeResult(
            txnId: txnID,
            attempted: items.count,
            purged: purged,
            failed: failed,
            freedBytes: freedBytes
        )
    }

    func undoLastTxn() throws -> UndoResult? {
        guard let txnID = try store.latestUndoableTxn() else {
            return nil
        }

        let rows = try store.journalRows(txnID: txnID)
            .filter { $0.verified && ($0.actionType == .quarantineCopy || $0.actionType == .rename || $0.actionType == .move) }

        guard !rows.isEmpty else {
            return nil
        }

        var succeeded = 0
        var failed = 0
        var succeededRowIDs: [String] = []

        for row in rows.reversed() {
            do {
                try ensureAccessForPaths([row.srcPath, row.dstPath])
            } catch {
                failed += 1
                try? store.appendUndoError(rowID: row.id, message: error.localizedDescription)
                continue
            }

            switch row.actionType {
            case .quarantineCopy:
                let destinationURL = URL(fileURLWithPath: row.dstPath)
                if fileManager.fileExists(atPath: destinationURL.path) {
                    do {
                        try fileManager.removeItem(at: destinationURL)
                        if !fileManager.fileExists(atPath: destinationURL.path) {
                            succeeded += 1
                            succeededRowIDs.append(row.id)
                            try? store.updateQuarantineItemStateByPath(quarantinePath: row.dstPath, state: .undone)
                        } else {
                            failed += 1
                            try? store.appendUndoError(rowID: row.id, message: "Quarantine file still exists after delete")
                        }
                    } catch {
                        failed += 1
                        try? store.appendUndoError(rowID: row.id, message: error.localizedDescription)
                    }
                } else {
                    succeeded += 1
                    succeededRowIDs.append(row.id)
                    try? store.updateQuarantineItemStateByPath(quarantinePath: row.dstPath, state: .undone)
                }

            case .rename, .move:
                let sourceURL = URL(fileURLWithPath: row.srcPath)
                let currentURL = URL(fileURLWithPath: row.dstPath)

                guard fileManager.fileExists(atPath: currentURL.path) else {
                    failed += 1
                    try? store.appendUndoError(rowID: row.id, message: "Current file missing for undo")
                    continue
                }

                let restoreURL: URL
                if fileManager.fileExists(atPath: sourceURL.path) {
                    restoreURL = resolveConflictWithIncrementalSuffix(for: sourceURL)
                } else {
                    restoreURL = sourceURL
                }

                do {
                    try ensureParentFolder(for: restoreURL)
                    try fileManager.moveItem(at: currentURL, to: restoreURL)
                    let scope = scopeForPath(restoreURL.path)
                    try store.moveIndexedFile(
                        oldPath: row.dstPath,
                        newPath: restoreURL.path,
                        newScope: scope,
                        modifiedAt: Date(),
                        lastSeenAt: Date()
                    )
                    succeeded += 1
                    succeededRowIDs.append(row.id)
                } catch {
                    failed += 1
                    try? store.appendUndoError(rowID: row.id, message: error.localizedDescription)
                }

            default:
                continue
            }
        }

        try store.markJournalRowsUndone(rowIDs: succeededRowIDs, undoneAt: Date())

        let remaining = try store.activeUndoRowsCount(txnID: txnID)
        if remaining == 0 {
            try? store.markTxnUndone(txnID: txnID, undoneAt: Date())
            if let bundleTarget = rows.first(where: { $0.targetType == "bundle" })?.targetID {
                try? store.updateBundleStatus(id: bundleTarget, status: .pending)
            }
        }

        return UndoResult(
            txnId: txnID,
            requested: rows.count,
            succeeded: succeeded,
            failed: failed,
            message: "Undo txn \(txnID.prefix(8)) completed: \(succeeded) success, \(failed) failed"
        )
    }

    // MARK: - Bundle operation builders

    private func buildRenameOperations(filePaths: [String],
                                       template: String,
                                       baseDate: Date) throws -> (operations: [BundleOperationRecord], finalTemplate: String) {
        var operations: [BundleOperationRecord] = []
        var sequence = 1

        for path in filePaths.sorted() {
            let sourceURL = URL(fileURLWithPath: path)
            let ext = sourceURL.pathExtension
            let sizeBytes = (try? fileManager.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0

            let renderedBase = renderRenameTemplate(template, date: baseDate, sequence: sequence)
            let proposedURL = sourceURL.deletingLastPathComponent().appendingPathComponent(nameWithExtension(base: renderedBase, ext: ext))
            let destinationURL = resolveConflictWithIncrementalSuffix(for: proposedURL, excludingPath: sourceURL.path)
            sequence += 1

            var verified = false
            var errorCode: String?
            var errorMessage: String?
            var conflictResolution = "none"

            do {
                if destinationURL.path == sourceURL.path {
                    // File is already named correctly — treat as success, not failure
                    verified = true
                    conflictResolution = "no_op_already_named"
                } else {
                    if destinationURL.lastPathComponent != proposedURL.lastPathComponent {
                        conflictResolution = "suffix_incremental"
                    }
                    try fileManager.moveItem(at: sourceURL, to: destinationURL)
                    verified = fileManager.fileExists(atPath: destinationURL.path)
                }

                if !verified, errorCode == nil {
                    errorCode = "VERIFY_FAILED"
                    errorMessage = "Rename target verification failed"
                }
            } catch {
                errorCode = "RENAME_FAILED"
                errorMessage = error.localizedDescription
            }

            operations.append(
                BundleOperationRecord(
                    actionType: .rename,
                    srcPath: sourceURL.path,
                    dstPath: destinationURL.path,
                    newRootScope: nil,
                    copyOrMove: "move",
                    conflictResolution: conflictResolution,
                    verified: verified,
                    errorCode: errorCode,
                    errorMessage: errorMessage,
                    bytesDelta: verified ? sizeBytes : 0,
                    quarantineItemID: nil,
                    sha256: nil
                )
            )
        }

        return (operations, template)
    }

    private func buildQuarantineOperations(filePaths: [String]) throws -> (operations: [BundleOperationRecord], skippedByRisk: Int) {
        var operations: [BundleOperationRecord] = []
        var skippedByRisk = 0

        for path in filePaths.sorted() {
            let sourceURL = URL(fileURLWithPath: path)
            guard fileManager.fileExists(atPath: sourceURL.path) else {
                operations.append(
                    BundleOperationRecord(
                        actionType: .quarantineCopy,
                        srcPath: sourceURL.path,
                        dstPath: "",
                        newRootScope: nil,
                        copyOrMove: "copy",
                        conflictResolution: "risk_filter",
                        verified: false,
                        errorCode: "SOURCE_MISSING",
                        errorMessage: "Source file missing",
                        bytesDelta: 0,
                        quarantineItemID: nil,
                        sha256: nil
                    )
                )
                continue
            }

            guard isLowRiskForQuarantine(sourceURL) else {
                skippedByRisk += 1
                operations.append(
                    BundleOperationRecord(
                        actionType: .quarantineCopy,
                        srcPath: sourceURL.path,
                        dstPath: "",
                        newRootScope: nil,
                        copyOrMove: "copy",
                        conflictResolution: "risk_filter",
                        verified: false,
                        errorCode: "LOW_RISK_FILTER",
                        errorMessage: "Skipped by low-risk quarantine policy",
                        bytesDelta: 0,
                        quarantineItemID: nil,
                        sha256: nil
                    )
                )
                continue
            }

            let ext = sourceURL.pathExtension.lowercased()
            let destinationURL = try makeQuarantineDestination(ext: ext)
            let sizeBytes = (try? fileManager.attributesOfItem(atPath: sourceURL.path)[.size] as? NSNumber)?.int64Value ?? 0

            var verified = false
            var errorCode: String?
            var errorMessage: String?

            do {
                try ensureParentFolder(for: destinationURL)
                try fileManager.copyItem(at: sourceURL, to: destinationURL)
                verified = fileManager.fileExists(atPath: destinationURL.path)
                if !verified {
                    errorCode = "VERIFY_FAILED"
                    errorMessage = "Quarantine copy verification failed"
                }
            } catch {
                errorCode = "COPY_FAILED"
                errorMessage = error.localizedDescription
            }

            operations.append(
                BundleOperationRecord(
                    actionType: .quarantineCopy,
                    srcPath: sourceURL.path,
                    dstPath: destinationURL.path,
                    newRootScope: nil,
                    copyOrMove: "copy",
                    conflictResolution: "uuid_filename",
                    verified: verified,
                    errorCode: errorCode,
                    errorMessage: errorMessage,
                    bytesDelta: verified ? sizeBytes : 0,
                    quarantineItemID: verified ? UUID().uuidString : nil,
                    sha256: try? FileHash.sha256(for: sourceURL)
                )
            )
        }

        return (operations, skippedByRisk)
    }

    private func buildMissingOperations(filePaths: [String],
                                        actionKind: BundleActionKind) -> [BundleOperationRecord] {
        guard !filePaths.isEmpty else { return [] }

        let actionType: ActionType
        let copyOrMove: String
        let newScope: RootScope?

        switch actionKind {
        case .rename:
            actionType = .rename
            copyOrMove = "move"
            newScope = nil
        case .quarantine:
            actionType = .quarantineCopy
            copyOrMove = "copy"
            newScope = nil
        case .move:
            actionType = .move
            copyOrMove = "move"
            newScope = .archived
        }

        return filePaths.sorted().map { path in
            BundleOperationRecord(
                actionType: actionType,
                srcPath: path,
                dstPath: path,
                newRootScope: newScope,
                copyOrMove: copyOrMove,
                conflictResolution: "source_missing",
                verified: false,
                errorCode: "SKIPPED_MISSING",
                errorMessage: "Source file missing before apply",
                bytesDelta: 0,
                quarantineItemID: nil,
                sha256: nil
            )
        }
    }

    private func buildMoveOperations(filePaths: [String],
                                     bundleType: BundleType,
                                     archiveRoot: URL,
                                     renameTemplate: String?,
                                     baseDate: Date,
                                     aiSubfolder: String? = nil) throws -> (operations: [BundleOperationRecord], destinationFolder: URL) {
        let destinationFolder: URL
        if let aiSubfolder {
            // Sanitise: strip leading slashes and any absolute-path prefix so we
            // always append safely under archiveRoot.
            let clean = aiSubfolder
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            destinationFolder = clean.isEmpty
                ? archiveRoot.appendingPathComponent("Organized", isDirectory: true)
                : aiSubfolder.split(separator: "/").reduce(archiveRoot) { $0.appendingPathComponent(String($1), isDirectory: true) }
        } else {
            destinationFolder = archiveDestinationFolder(for: bundleType, archiveRoot: archiveRoot, date: baseDate)
        }
        try ensureParentFolder(for: destinationFolder.appendingPathComponent("placeholder"))

        var operations: [BundleOperationRecord] = []
        var sequence = 1

        for path in filePaths.sorted() {
            let sourceURL = URL(fileURLWithPath: path)
            let ext = sourceURL.pathExtension
            let sizeBytes = (try? fileManager.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
            let extLower = ext.lowercased()

            let targetName: String
            if let renameTemplate, !renameTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let rendered = renderRenameTemplate(renameTemplate, date: baseDate, sequence: sequence)
                targetName = nameWithExtension(base: rendered, ext: ext)
            } else {
                targetName = sourceURL.lastPathComponent
            }
            sequence += 1

            let finalDestinationFolder: URL
            if bundleType == .weeklyDocuments {
                let group = inboxGroupName(for: extLower)
                finalDestinationFolder = destinationFolder.appendingPathComponent(group, isDirectory: true)
            } else {
                finalDestinationFolder = destinationFolder
            }

            let proposedURL = finalDestinationFolder.appendingPathComponent(targetName)
            let destinationURL = resolveConflictWithIncrementalSuffix(for: proposedURL)
            let conflictResolution = destinationURL.lastPathComponent == proposedURL.lastPathComponent ? "none" : "suffix_incremental"

            var verified = false
            var errorCode: String?
            var errorMessage: String?

            appendRuntimeLog("[ActionEngine] move_file_start src=\(sourceURL.path) dst=\(destinationURL.path)")

            do {
                try ensureParentFolder(for: destinationURL)
                let result = moveItemWithTimeout(
                    sourceURL: sourceURL,
                    destinationURL: destinationURL,
                    timeoutSeconds: 8
                )
                verified = result.verified
                errorCode = result.errorCode
                errorMessage = result.errorMessage
            } catch {
                errorCode = "MOVE_FAILED"
                errorMessage = error.localizedDescription
            }

            if verified {
                appendRuntimeLog("[ActionEngine] move_file_done src=\(sourceURL.path) dst=\(destinationURL.path) status=ok")
            } else {
                appendRuntimeLog("[ActionEngine] move_file_done src=\(sourceURL.path) dst=\(destinationURL.path) status=error message=\(errorMessage ?? errorCode ?? "unknown")")
            }

            operations.append(
                BundleOperationRecord(
                    actionType: .move,
                    srcPath: sourceURL.path,
                    dstPath: destinationURL.path,
                    newRootScope: .archived,
                    copyOrMove: "move",
                    conflictResolution: conflictResolution,
                    verified: verified,
                    errorCode: errorCode,
                    errorMessage: errorMessage,
                    bytesDelta: verified ? sizeBytes : 0,
                    quarantineItemID: nil,
                    sha256: nil
                )
            )
        }

        return (operations, destinationFolder)
    }

    // MARK: - Helpers

    private func ensureAccessForPaths(_ paths: [String]) throws {
        guard !paths.isEmpty else { return }

        let downloadsRoot = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ?? ""
        let desktopRoot = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first?.path ?? ""
        let documentsRoot = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? ""
        let archiveRootPath = (try? accessManager.health(target: .archiveRoot).path) ?? nil

        var requiredTargets: Set<AccessTarget> = []

        for path in paths where !path.isEmpty {
            if !downloadsRoot.isEmpty, path == downloadsRoot || path.hasPrefix(downloadsRoot + "/") {
                requiredTargets.insert(.downloads)
                continue
            }
            if !desktopRoot.isEmpty, path == desktopRoot || path.hasPrefix(desktopRoot + "/") {
                requiredTargets.insert(.desktop)
                continue
            }
            if !documentsRoot.isEmpty, path == documentsRoot || path.hasPrefix(documentsRoot + "/") {
                requiredTargets.insert(.documents)
                continue
            }
            if let archiveRootPath, !archiveRootPath.isEmpty,
               (path == archiveRootPath || path.hasPrefix(archiveRootPath + "/")) {
                requiredTargets.insert(.archiveRoot)
            }
        }

        for target in requiredTargets {
            let item = try accessManager.health(target: target)
            guard item.status == .ok else {
                throw accessManager.makeAccessError(
                    target: target,
                    reason: "Access check failed for \(target.rawValue) (\(item.status.rawValue)). Open Digest Health to repair.",
                    fallbackStatus: item.status
                )
            }

            switch target {
            case .downloads:
                _ = try accessManager.resolveDownloadsAccess()
            case .desktop:
                _ = try accessManager.resolveDesktopAccess()
            case .documents:
                _ = try accessManager.resolveDocumentsAccess()
            case .archiveRoot:
                _ = try accessManager.resolveArchiveRootAccess()
            }
        }
    }

    private func hasTrainingSignal(bundle: DecisionBundle, finalAction: BundleActionConfig) -> Bool {
        if finalAction.actionKind != bundle.action.actionKind {
            return true
        }

        let newTemplate = finalAction.renameTemplate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let oldTemplate = bundle.action.renameTemplate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if newTemplate != oldTemplate {
            return true
        }

        if finalAction.targetFolderBookmark != bundle.action.targetFolderBookmark {
            return true
        }
        return false
    }

    private func moveItemWithTimeout(sourceURL: URL,
                                     destinationURL: URL,
                                     timeoutSeconds: TimeInterval) -> (verified: Bool, errorCode: String?, errorMessage: String?) {
        let semaphore = DispatchSemaphore(value: 0)
        var moveError: Error?

        fileOpQueue.async {
            do {
                try self.fileManager.moveItem(at: sourceURL, to: destinationURL)
            } catch {
                moveError = error
            }
            semaphore.signal()
        }

        let timeoutResult = semaphore.wait(timeout: .now() + timeoutSeconds)
        if timeoutResult == .timedOut {
            return (
                verified: false,
                errorCode: "MOVE_TIMEOUT",
                errorMessage: "Move timed out after \(Int(timeoutSeconds))s"
            )
        }

        if let moveError {
            return (
                verified: false,
                errorCode: "MOVE_FAILED",
                errorMessage: moveError.localizedDescription
            )
        }

        let verified = fileManager.fileExists(atPath: destinationURL.path)
        if !verified {
            return (
                verified: false,
                errorCode: "VERIFY_FAILED",
                errorMessage: "Move verification failed"
            )
        }

        return (verified: true, errorCode: nil, errorMessage: nil)
    }

    private func runBundleApplyTransactionWithTimeout(bundleID: String,
                                                      action: BundleActionConfig,
                                                      operations: [BundleOperationRecord],
                                                      actor: String,
                                                      txnID: String,
                                                      createdAt: Date,
                                                      extraJournalEntries: [SQLiteStore.JournalInsert],
                                                      timeoutSeconds: TimeInterval) throws -> SQLiteStore.BundleApplyTransactionResult {
        try runStoreCallWithTimeout(
            name: "bundle_apply_txn",
            timeoutSeconds: timeoutSeconds,
            call: {
                try self.store.runBundleApplyTransaction(
                    bundleID: bundleID,
                    action: action,
                    operations: operations,
                    actor: actor,
                    txnID: txnID,
                    createdAt: createdAt,
                    extraJournalEntries: extraJournalEntries
                )
            }
        )
    }

    private func runStoreCallWithTimeout<T>(name: String,
                                            timeoutSeconds: TimeInterval,
                                            call: @escaping () throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        var output: T?
        var outputError: Error?

        storeOpQueue.async {
            defer { semaphore.signal() }
            do {
                output = try call()
            } catch {
                outputError = error
            }
        }

        if semaphore.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            throw NSError(
                domain: "ActionEngine",
                code: 408,
                userInfo: [NSLocalizedDescriptionKey: "\(name) timed out after \(Int(timeoutSeconds))s"]
            )
        }

        if let outputError {
            throw outputError
        }

        guard let output else {
            throw NSError(
                domain: "ActionEngine",
                code: 500,
                userInfo: [NSLocalizedDescriptionKey: "\(name) returned no result"]
            )
        }
        return output
    }

    private func insertBundleApplyStarted(txnID: String,
                                          bundleID: String,
                                          actionHint: BundleActionKind?,
                                          createdAt: Date) throws {
        let message: String
        if let actionHint {
            message = "Bundle apply started (action=\(actionHint.rawValue))."
        } else {
            message = "Bundle apply started."
        }
        let entry = SQLiteStore.JournalInsert(
            id: UUID().uuidString,
            txnID: txnID,
            actor: "user",
            actionType: .bundleApplyStarted,
            targetType: "bundle",
            targetID: bundleID,
            srcPath: bundleID,
            dstPath: "",
            copyOrMove: "none",
            conflictResolution: "started",
            verified: true,
            errorCode: "STARTED",
            errorMessage: message,
            bytesDelta: 0,
            createdAt: createdAt,
            undoable: false
        )
        try runStoreCallWithTimeout(
            name: "journal_bundle_apply_started",
            timeoutSeconds: 5,
            call: { try self.store.insertJournalEntry(entry) }
        )
    }

    private func insertBundleApplyFinished(txnID: String,
                                           bundleID: String,
                                           state: String,
                                           movedCount: Int,
                                           renamedCount: Int,
                                           quarantinedCount: Int,
                                           skippedMissing: Int,
                                           destinationHint: String?,
                                           message: String,
                                           createdAt: Date) throws {
        let normalizedState = state.lowercased()
        let successState = normalizedState == "success" || normalizedState == "partial"
        let statusCode: String
        switch normalizedState {
        case "success":
            statusCode = "SUCCESS"
        case "partial":
            statusCode = "PARTIAL"
        default:
            statusCode = "FAILED"
        }

        let countsMessage = "moved=\(movedCount),renamed=\(renamedCount),quarantined=\(quarantinedCount),skipped_missing=\(skippedMissing)"
        let detail = "\(message) [\(countsMessage)]"
        let entry = SQLiteStore.JournalInsert(
            id: UUID().uuidString,
            txnID: txnID,
            actor: "user",
            actionType: .bundleApplyFinished,
            targetType: "bundle",
            targetID: bundleID,
            srcPath: bundleID,
            dstPath: destinationHint ?? "",
            copyOrMove: "none",
            conflictResolution: normalizedState,
            verified: successState,
            errorCode: statusCode,
            errorMessage: detail,
            bytesDelta: Int64(max(0, movedCount + renamedCount + quarantinedCount)),
            createdAt: createdAt,
            undoable: false
        )
        try runStoreCallWithTimeout(
            name: "journal_bundle_apply_finished",
            timeoutSeconds: 5,
            call: { try self.store.insertJournalEntry(entry) }
        )
    }

    private func bundleApplySummaryMessage(moved: Int,
                                           renamed: Int,
                                           quarantined: Int,
                                           skippedMissing: Int,
                                           failed: Int) -> String {
        let actionPart: String
        if moved > 0 {
            actionPart = "moved \(moved)"
        } else if renamed > 0 {
            actionPart = "renamed \(renamed)"
        } else if quarantined > 0 {
            actionPart = "quarantined \(quarantined)"
        } else {
            actionPart = "moved 0"
        }

        var message = "Bundle applied: \(actionPart)"
        if skippedMissing > 0 {
            message += " (skipped \(skippedMissing) missing)"
        }
        if failed > 0 {
            message += ", \(failed) failed"
        }
        return message
    }

    private func learnRuleFromUserOverride(bundle: DecisionBundle,
                                           action: BundleActionConfig,
                                           now: Date) throws -> String {
        let scope = inferScopeForBundle(bundle)
        let ext = dominantExtension(in: bundle.filePaths)
        let pattern = preferredNamePattern(for: bundle)

        let match = RuleMatch(
            bundleType: bundle.type,
            scope: scope,
            fileExt: ext,
            namePattern: pattern
        )
        let name = "My \(bundle.type.rawValue) rule"
        return try store.upsertLearnedRule(name: name, match: match, action: action, now: now)
    }

    private func inferScopeForBundle(_ bundle: DecisionBundle) -> RootScope? {
        if bundle.id.hasPrefix("\(RootScope.downloads.rawValue)-") { return .downloads }
        if bundle.id.hasPrefix("\(RootScope.desktop.rawValue)-") { return .desktop }
        if bundle.id.hasPrefix("\(RootScope.documents.rawValue)-") { return .documents }

        if let firstPath = bundle.filePaths.first {
            let inferred = scopeForPath(firstPath)
            return inferred == .archived ? nil : inferred
        }
        return nil
    }

    private func dominantExtension(in filePaths: [String]) -> String? {
        var counts: [String: Int] = [:]
        for path in filePaths {
            let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
            guard !ext.isEmpty else { continue }
            counts[ext, default: 0] += 1
        }
        return counts.max(by: { $0.value < $1.value })?.key
    }

    private func preferredNamePattern(for bundle: DecisionBundle) -> String? {
        if bundle.type == .weeklyScreenshots {
            return "screenshot"
        }

        let lowerNames = bundle.filePaths.map { URL(fileURLWithPath: $0).lastPathComponent.lowercased() }
        if lowerNames.contains(where: { $0.contains("invoice") }) {
            return "invoice"
        }
        return nil
    }

    private func resolveArchiveRootURL(action: BundleActionConfig) throws -> URL {
        if let targetBookmark = action.targetFolderBookmark {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: targetBookmark,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if isStale {
                throw accessManager.makeAccessError(
                    target: .archiveRoot,
                    reason: "Bundle target bookmark is stale. Please re-authorize archive folder.",
                    fallbackStatus: .stale
                )
            }
            guard url.startAccessingSecurityScopedResource() else {
                throw accessManager.makeAccessError(
                    target: .archiveRoot,
                    reason: "Bundle target access denied. Please re-authorize archive folder.",
                    fallbackStatus: .denied
                )
            }
            url.stopAccessingSecurityScopedResource()
            return url
        }

        guard let url = try accessManager.resolveArchiveRootAccess() else {
            throw accessManager.makeAccessError(
                target: .archiveRoot,
                reason: "Archive root is not configured. Please choose archive folder once in Bundle Detail.",
                fallbackStatus: .missing
            )
        }

        return url
    }

    private func archiveDestinationFolder(for type: BundleType, archiveRoot: URL, date: Date) -> URL {
        let month = DateFormatter.archiveMonth.string(from: date)

        switch type {
        case .weeklyDownloadsPDF:
            return archiveRoot.appendingPathComponent("Downloads PDFs", isDirectory: true)
                .appendingPathComponent(month, isDirectory: true)
        case .weeklyScreenshots:
            return archiveRoot.appendingPathComponent("Screenshots", isDirectory: true)
                .appendingPathComponent(month, isDirectory: true)
        case .weeklyInstallers:
            return archiveRoot.appendingPathComponent("Installers", isDirectory: true)
                .appendingPathComponent(month, isDirectory: true)
        case .weeklyDocuments:
            return archiveRoot.appendingPathComponent("Downloads Inbox", isDirectory: true)
                .appendingPathComponent(month, isDirectory: true)
        case .crossDirectoryGroup:
            // Use "Organized" as the fallback subfolder; actual destination comes from bundle evidence
            return archiveRoot.appendingPathComponent("Organized", isDirectory: true)
                .appendingPathComponent(month, isDirectory: true)
        }
    }

    private func inboxGroupName(for ext: String) -> String {
        switch ext.lowercased() {
        case "doc", "docx", "txt", "md":
            return "Docs"
        case "xls", "xlsx", "csv":
            return "Sheets"
        case "ppt", "pptx", "key":
            return "Slides"
        case "zip", "rar", "7z":
            return "Archives"
        case "mp4", "mov", "mp3", "wav":
            return "Media"
        default:
            return "Others"
        }
    }

    private func defaultTemplate(for type: BundleType) -> String {
        switch type {
        case .weeklyDownloadsPDF:
            return "DownloadsPDF_{yyyyMMdd}_{seq}"
        case .weeklyScreenshots:
            return "Screenshot_{yyyyMMdd_HHmm}_{seq}"
        case .weeklyInstallers:
            return "Installer_{yyyyMMdd}_{seq}"
        case .weeklyDocuments:
            return "Document_{yyyyMMdd}_{seq}"
        case .crossDirectoryGroup:
            return "File_{yyyyMMdd}_{seq}"
        }
    }

    private func renderRenameTemplate(_ template: String, date: Date, sequence: Int) -> String {
        let day = DateFormatter.renameDay.string(from: date)
        let minute = DateFormatter.renameMinute.string(from: date)

        return template
            .replacingOccurrences(of: "{yyyyMMdd}", with: day)
            .replacingOccurrences(of: "{yyyyMMdd_HHmm}", with: minute)
            .replacingOccurrences(of: "{seq}", with: String(format: "%03d", sequence))
    }

    private func nameWithExtension(base: String, ext: String) -> String {
        if ext.isEmpty {
            return base
        }
        if base.lowercased().hasSuffix(".\(ext.lowercased())") {
            return base
        }
        return "\(base).\(ext)"
    }

    private func resolveConflictWithIncrementalSuffix(for url: URL, excludingPath: String? = nil) -> URL {
        if !fileManager.fileExists(atPath: url.path) || url.path == excludingPath {
            return url
        }

        let folder = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent

        var index = 1
        while true {
            let candidateName: String
            if ext.isEmpty {
                candidateName = "\(stem) (\(index))"
            } else {
                candidateName = "\(stem) (\(index)).\(ext)"
            }
            let candidate = folder.appendingPathComponent(candidateName)
            if !fileManager.fileExists(atPath: candidate.path) || candidate.path == excludingPath {
                return candidate
            }
            index += 1
        }
    }

    private func isLowRiskForQuarantine(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if lowRiskQuarantineExtensions.contains(ext) {
            return true
        }

        let lowerName = url.lastPathComponent.lowercased()
        if lowerName.contains("screenshot") || lowerName.contains("screen shot") || lowerName.contains("截屏") || lowerName.contains("屏幕快照") {
            return true
        }

        return false
    }

    private func appendRuntimeLog(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        print(line.trimmingCharacters(in: .newlines))

        do {
            let appSupport = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("Tidy2", isDirectory: true)

            let logFolder = appSupport.appendingPathComponent("Logs", isDirectory: true)
            if !fileManager.fileExists(atPath: logFolder.path) {
                try fileManager.createDirectory(at: logFolder, withIntermediateDirectories: true)
            }

            let logURL = logFolder.appendingPathComponent("runtime.log", isDirectory: false)
            if fileManager.fileExists(atPath: logURL.path) {
                let handle = try FileHandle(forWritingTo: logURL)
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                if let data = line.data(using: .utf8) {
                    handle.write(data)
                }
            } else {
                try line.write(to: logURL, atomically: true, encoding: .utf8)
            }
        } catch {
            print("[ActionEngine] runtime.log write failed: \(error.localizedDescription)")
        }
    }

    private func scopeForPath(_ path: String) -> RootScope {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ?? ""
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first?.path ?? ""
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? ""

        if !downloads.isEmpty, path.hasPrefix(downloads + "/") || path == downloads { return .downloads }
        if !desktop.isEmpty,   path.hasPrefix(desktop + "/")   || path == desktop   { return .desktop }
        if !documents.isEmpty, path.hasPrefix(documents + "/") || path == documents  { return .documents }
        return .archived
    }

    private func quarantineRootURL() throws -> URL {
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Tidy2", isDirectory: true)

        return appSupport.appendingPathComponent("Quarantine", isDirectory: true)
    }

    private func makeQuarantineDestination(ext: String) throws -> URL {
        let root = try quarantineRootURL()
        let month = DateFormatter.quarantineMonth.string(from: Date())
        let folder = root.appendingPathComponent(month, isDirectory: true)

        let fileName: String
        if ext.isEmpty {
            fileName = UUID().uuidString
        } else {
            fileName = "\(UUID().uuidString).\(ext)"
        }

        return folder.appendingPathComponent(fileName)
    }

    private func ensureParentFolder(for url: URL) throws {
        let parent = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parent.path) {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        }
    }

    private func conflictResolvedRestoreURL(for originalURL: URL) -> URL {
        let folder = originalURL.deletingLastPathComponent()
        let baseName = originalURL.deletingPathExtension().lastPathComponent
        let ext = originalURL.pathExtension
        let stamp = DateFormatter.restoreSuffix.string(from: Date())

        let fileName: String
        if ext.isEmpty {
            fileName = "\(baseName) (Restored \(stamp))"
        } else {
            fileName = "\(baseName) (Restored \(stamp)).\(ext)"
        }

        return folder.appendingPathComponent(fileName)
    }
}

private extension DateFormatter {
    static let quarantineMonth: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        return formatter
    }()

    static let archiveMonth: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        return formatter
    }()

    static let restoreSuffix: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        return formatter
    }()

    static let renameDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        return formatter
    }()

    static let renameMinute: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmm"
        return formatter
    }()
}
