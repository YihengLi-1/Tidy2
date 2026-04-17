import Foundation

protocol AccessManagerProtocol {
    func resolveDownloadsAccess() throws -> URL?
    func resolveDesktopAccess() throws -> URL?
    func resolveDocumentsAccess() throws -> URL?
    func resolveArchiveRootAccess() throws -> URL?
    func saveDownloadsBookmark(url: URL) throws
    func saveDesktopBookmark(url: URL) throws
    func saveDocumentsBookmark(url: URL) throws
    func saveArchiveRootBookmark(url: URL) throws
    func health(target: AccessTarget) throws -> AccessHealthItem
    func healthSnapshot() throws -> [AccessHealthItem]
    func makeAccessError(target: AccessTarget, reason: String, fallbackStatus: AccessHealthStatus?) -> NSError
}

protocol IndexerServiceProtocol: AnyObject {
    var onProgress: (@Sendable (RootScope, Int) -> Void)? { get set }
    func scanDownloads(rootURL: URL) throws -> [IndexedFile]
    func forceFullScanDownloads(rootURL: URL) throws -> [IndexedFile]
    func reindex(scope: RootScope, rootURL: URL, changedDirectories: [URL]) throws -> [IndexedFile]
    func backfillPDFTextIndex(scope: RootScope, limit: Int) throws -> Int
}

protocol ScannerServiceProtocol {
    func detectDuplicateGroups(scope: RootScope) throws -> DuplicateScanReport
}

protocol BundleBuilderServiceProtocol {
    func seedMockBundlesIfNeeded() throws
    func rebuildWeeklyBundles(scope: RootScope, now: Date) throws
    func pendingBundles(limit: Int) throws -> [DecisionBundle]
}

protocol ActionEngineServiceProtocol {
    func autoQuarantineDuplicateGroups(_ groups: [DuplicateScanGroup]) throws -> Int
    func applyBundle(bundleID: String, override: BundleApplyOverride?) throws -> BundleApplyResult
    func restore(quarantineItemID: String) throws
    func purgeExpiredQuarantine(actor: String) throws -> PurgeResult
    func purgeSafeCleanupQuarantine(actor: String) throws -> PurgeResult
    func undoLastTxn() throws -> UndoResult?
}

protocol DigestServiceProtocol {
    func weeklySummary(now: Date) throws -> DigestSummary
}

protocol QuarantineServiceProtocol {
    func listActiveItems() throws -> [QuarantineItem]
    func listItems(filter: QuarantineListFilter) throws -> [QuarantineItem]
}

protocol ConsistencyCheckerProtocol {
    func runRepair(now: Date) throws -> ConsistencyReport
}

protocol MetricsStoreProtocol {
    func captureWeeklySnapshot(now: Date, pendingBundles: Int) throws
    func recentWeeklyMetrics(limit: Int) throws -> [WeeklyMetricsRow]
}

protocol DebugBundleExporterProtocol: Sendable {
    func export(to destinationURL: URL, now: Date, accessHealth: [AccessTarget: AccessHealthItem]) throws -> URL
}
