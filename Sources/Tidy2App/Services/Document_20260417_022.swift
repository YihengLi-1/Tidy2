import Foundation

final class ServiceContainer {
    let store: SQLiteStore
    let accessManager: AccessManagerProtocol
    let indexer: IndexerServiceProtocol
    let scanner: ScannerServiceProtocol
    let fileIntelligenceService: FileIntelligenceService
    let bundleBuilder: BundleBuilderServiceProtocol
    let actionEngine: ActionEngineServiceProtocol
    let digestService: DigestServiceProtocol
    let quarantineService: QuarantineServiceProtocol
    let consistencyChecker: ConsistencyCheckerProtocol
    let metricsStore: MetricsStoreProtocol
    let debugBundleExporter: DebugBundleExporterProtocol

    init() throws {
        let store = try SQLiteStore()
        let accessManager = AccessManager(store: store)
        let fileIntelligenceService = FileIntelligenceService(store: store)
        let indexer = Indexer(store: store)
        indexer.onScanCompleted = { [fileIntelligenceService] in
            Task.detached(priority: .utility) {
                await fileIntelligenceService.runBatchAnalysis()
            }
        }
        self.store = store
        self.accessManager = accessManager
        self.indexer = indexer
        self.scanner = Scanner(store: store)
        self.fileIntelligenceService = fileIntelligenceService
        self.bundleBuilder = BundleBuilder(store: store)
        self.actionEngine = ActionEngine(store: store, accessManager: accessManager)
        self.digestService = DigestService(store: store)
        self.quarantineService = QuarantineService(store: store)
        self.consistencyChecker = ConsistencyChecker(store: store, accessManager: accessManager)
        self.metricsStore = MetricsStore(store: store)
        self.debugBundleExporter = DebugBundleExporter()
    }
}
