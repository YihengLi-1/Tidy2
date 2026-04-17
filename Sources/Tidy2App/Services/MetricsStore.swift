import Foundation

final class MetricsStore: MetricsStoreProtocol {
    private let store: SQLiteStore
    private let firstRunStartedAtKey = "first_run_started_at"
    private let firstZeroInboxAtKey = "first_zero_inbox_at"

    init(store: SQLiteStore) {
        self.store = store
    }

    func captureWeeklySnapshot(now: Date, pendingBundles: Int) throws {
        let weekStart = DateHelper.startOfCurrentWeek(now: now)
        let weekKey = DateFormatter.metricsWeekKey.string(from: weekStart)

        let confirmStats = try store.weeklyConfirmStats(weekStart: weekStart)
        let undoCount = try store.weeklyUndoCount(weekStart: weekStart)
        let autopilotBytes = try store.weeklyAutopilotIsolatedBytes(weekStart: weekStart)
        let missingSkippedCount = try store.weeklyMissingSkippedCount(weekStart: weekStart)

        var firstRun = try store.doubleSetting(key: firstRunStartedAtKey)
        if firstRun == nil {
            firstRun = now.timeIntervalSince1970
            try store.setDoubleSetting(key: firstRunStartedAtKey, value: firstRun!)
        }

        var zeroInboxAt = try store.doubleSetting(key: firstZeroInboxAtKey)
        if pendingBundles == 0, zeroInboxAt == nil {
            zeroInboxAt = now.timeIntervalSince1970
            try store.setDoubleSetting(key: firstZeroInboxAtKey, value: zeroInboxAt!)
        }

        let timeToZeroDays: Double?
        if let firstRun, let zeroInboxAt {
            timeToZeroDays = max(0, (zeroInboxAt - firstRun) / (24 * 60 * 60))
        } else {
            timeToZeroDays = nil
        }

        let row = WeeklyMetricsRow(
            weekKey: weekKey,
            weekStart: weekStart,
            weeklyConfirmCount: confirmStats.confirmCount,
            confirmedFilesTotal: confirmStats.confirmedFilesTotal,
            undoCount: undoCount,
            autopilotIsolatedBytes: autopilotBytes,
            pendingBundles: pendingBundles,
            missingSkippedCount: missingSkippedCount,
            timeToZeroInboxDays: timeToZeroDays
        )
        try store.upsertWeeklyMetrics(row: row, updatedAt: now)
    }

    func recentWeeklyMetrics(limit: Int) throws -> [WeeklyMetricsRow] {
        try store.recentWeeklyMetrics(limit: limit)
    }
}

private extension DateFormatter {
    static let metricsWeekKey: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-'W'ww"
        return formatter
    }()
}
