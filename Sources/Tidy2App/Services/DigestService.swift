import Foundation

final class DigestService: DigestServiceProtocol {
    private let store: SQLiteStore
    private let archiveHealthSettingKey = "archive_root_health"

    init(store: SQLiteStore) {
        self.store = store
    }

    func weeklySummary(now: Date) throws -> DigestSummary {
        let weekStart = DateHelper.startOfCurrentWeek(now: now)
        let isolated = try store.weeklyAutopilotIsolated(weekStart: weekStart)
        let organized = try store.weeklyUserOrganized(weekStart: weekStart)
        let pending = try store.pendingBundleCount(limit: 5, now: now)
        let lastAppliedHint = try store.latestAppliedHint()
        let rawArchiveStatus = try store.stringSetting(key: archiveHealthSettingKey) ?? AccessHealthStatus.missing.rawValue
        let archiveAccessStatus = AccessHealthStatus(rawValue: rawArchiveStatus) ?? .missing
        let healthStatus: String
        switch archiveAccessStatus {
        case .ok:
            healthStatus = "Archive root access OK"
        case .stale:
            healthStatus = "Archive root bookmark stale"
        case .denied:
            healthStatus = "Archive root access denied"
        case .missing:
            healthStatus = "Archive root missing"
        }

        let missingOriginals = try store.appRelatedMissingOriginalFilesCount()
        let lowPriorityMissingOriginals = try store.lowPriorityMissingOriginalFilesCount()
        let missingQuarantineCount = try store.quarantineItemCount(states: [.missing])
        let expiredCount = try store.quarantineItemCount(states: [.expired])

        let maintenanceHint: String?
        if missingOriginals > 0 {
            maintenanceHint = "Missing originals: \(missingOriginals)"
        } else if lowPriorityMissingOriginals > 0 {
            maintenanceHint = "Low-priority: \(lowPriorityMissingOriginals) files moved outside Tidy (Repair now will clean stale index records)"
        } else if missingQuarantineCount > 0 {
            maintenanceHint = "\(missingQuarantineCount) quarantine items are missing from disk"
        } else if expiredCount > 0 {
            maintenanceHint = "Expired items: \(expiredCount)（可清理）"
        } else {
            maintenanceHint = nil
        }

        return DigestSummary(
            autoIsolatedCount: isolated.count,
            autoIsolatedBytes: isolated.bytes,
            autoOrganizedCount: organized,
            needsDecisionCount: pending,
            lastAppliedHint: lastAppliedHint,
            healthStatus: healthStatus,
            maintenanceHint: maintenanceHint,
            missingQuarantineCount: missingQuarantineCount,
            expiredQuarantineCount: expiredCount,
            missingOriginalsCount: missingOriginals,
            archiveAccessStatus: archiveAccessStatus
        )
    }
}
