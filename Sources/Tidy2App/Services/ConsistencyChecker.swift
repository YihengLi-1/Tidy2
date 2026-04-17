import Foundation

final class ConsistencyChecker: ConsistencyCheckerProtocol {
    private let store: SQLiteStore
    private let accessManager: AccessManagerProtocol

    init(store: SQLiteStore, accessManager: AccessManagerProtocol) {
        self.store = store
        self.accessManager = accessManager
    }

    func runRepair(now _: Date) throws -> ConsistencyReport {
        let totalMissingOriginals = try store.repairFileMissingStatus()
        let appRelatedMissing = try store.appRelatedMissingOriginalFilesCount()
        let lowPriorityMissing = max(0, totalMissingOriginals - appRelatedMissing)
        _ = try store.markMissingQuarantineItems()
        let missingQuarantine = try store.quarantineItemCount(states: [.missing])
        let archiveHealth = try accessManager.health(target: .archiveRoot).status

        return ConsistencyReport(
            missingOriginals: appRelatedMissing,
            lowPriorityMissingOriginals: lowPriorityMissing,
            missingQuarantineFiles: missingQuarantine,
            archiveAccess: archiveHealth
        )
    }
}
