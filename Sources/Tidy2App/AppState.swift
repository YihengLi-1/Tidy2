import AppKit
import Foundation
import SwiftUI
import UserNotifications
import UniformTypeIdentifiers

@MainActor
final class AppState: ObservableObject {
    enum Route: Hashable {
        case bundles
        case bundleDetail(String)
        case quarantine
        case search
        case duplicates
        case cleanup
        case aiFiles
        case cases
        case installerCandidates
        case changeLog
        case settings
        case rules
        case metrics
        case versionFiles
    }

    struct RuleNudge: Identifiable, Hashable {
        let id: String
        let ruleID: String
        let text: String
    }

    private struct LastDownloadsIndexStats: Decodable {
        let reason: String?
        let enumeratedFiles: Int?
        let written: Int?
        let skippedTotal: Int?
        let skippedHidden: Int?
        let skippedPackage: Int?
        let skippedSymlink: Int?
        let skippedPermission: Int?
        let skippedWatermark: Int?
    }

    private struct QuickPlanPhaseAResult {
        let screenshotsCount: Int
        let pdfCount: Int
        let inboxCount: Int
        let installersCount: Int
        let scannedFiles: Int
        let skippedReasons: [String: Int]
        let noActionReason: String?

        func actionableCount(window: ArchiveTimeWindow) -> Int {
            screenshotsCount + pdfCount + inboxCount + (window == .all ? 0 : installersCount)
        }

        func bucketCount(window: ArchiveTimeWindow) -> Int {
            var count = 0
            if screenshotsCount > 0 { count += 1 }
            if pdfCount > 0 { count += 1 }
            if inboxCount > 0 { count += 1 }
            if window != .all, installersCount > 0 { count += 1 }
            return count
        }
    }

    private enum DownloadsScanMode: Equatable {
        case quick
        case full

        var operationName: String {
            switch self {
            case .quick:
                return "autopilot"
            case .full:
                return "force-full-scan"
            }
        }

        var runningMessage: String {
            switch self {
            case .quick:
                return "快速扫描中..."
            case .full:
                return "完整扫描中..."
            }
        }

        var successEventType: String {
            switch self {
            case .quick:
                return "autopilot"
            case .full:
                return "force_full_scan"
            }
        }

        var failureEventType: String {
            switch self {
            case .quick:
                return "autopilot_failed"
            case .full:
                return "force_full_scan_failed"
            }
        }
    }

    private struct DownloadsScanExecutionResult {
        let isolatedCount: Int
        let bundleCount: Int
        let sizeOnlyCandidates: Int
        let noActionReason: String?
    }

    @Published var path: [Route] = []
    /// Set this to switch the sidebar selection. RootView observes and clears it.
    @Published var pendingTab: Route? = nil

    @Published var digest: DigestSummary = AppState.emptyDigest
    @Published var pendingBundlesCount: Int = 0
    @Published var recommendedPlanBuckets: [RecommendedPlanBucket] = []
    @Published var recommendedPlanActionableCount: Int = 0
    @Published var newFilesToArchiveCount: Int = 0
    @Published var showNewFilesHint: Bool = false
    @Published var installerReviewCandidates: [SearchResultItem] = []
    @Published var pendingInboxCount: Int = 0
    @Published var archiveResultMessage: String = ""
    @Published var archiveOpenDestinations: [ArchiveOpenDestination] = []
    @Published var archiveTimeWindow: ArchiveTimeWindow = .all
    @Published var lastArchiveBucketSummary: String = ""
    @Published var hasArchivedAtLeastOnce: Bool = false
    @Published var isTestModeEnabled: Bool = false
    @Published var bundles: [DecisionBundle] = []
    @Published var bundleMissingCounts: [String: Int] = [:]
    @Published var quarantineItems: [QuarantineItem] = []
    @Published var changeLogEntries: [ChangeLogEntry] = []
    @Published var metricsRows: [WeeklyMetricsRow] = []

    @Published var queryText: String = ""
    @Published var parsedFilters = SearchFilters()
    @Published var searchResults: [SearchResultItem] = []
    @Published var searchResultIntelMap: [String: FileIntelligence] = [:]
    @Published var aiAnalyzedFilesCount: Int = 0
    @Published var aiIntelligenceItems: [FileIntelligence] = []
    @Published var detectedCases: [DetectedCase] = []
    @Published var activeChecklist: ChecklistTemplate = ChecklistTemplate.presets[0]
    @Published var isAIAnalyzing: Bool = false
    @Published var totalFilesScanned: Int = 0
    @Published var duplicateGroups: [DuplicateGroup] = []
    @Published var duplicatesTotalWastedBytes: Int64 = 0
    @Published var largeFiles: [IndexedFile] = []
    @Published var oldInstallers: [IndexedFile] = []
    @Published var versionGroups: [VersionFileGroup] = []
    @Published var aiAnalysisLastError: FileIntelligenceService.AIError?

    @Published var rules: [UserRule] = []
    @Published var focusedRuleID: String?
    @Published var selectedRulePreviewRuleID: String?
    @Published var rulePreviewItems: [RuleDryRunItem] = []
    @Published var isRulePreviewLoading: Bool = false
    @Published var rulesEmergencyBrake: Bool = false

    @Published var quarantineFilter: QuarantineListFilter = .active
    @Published var autoPurgeExpiredQuarantine: Bool = false
    @Published var safeCleanupQuarantineCount: Int = 0

    @Published var isBusy: Bool = false
    @Published var statusMessage: String = ""
    @Published var scanProgressDetail: String = ""
    @Published var databaseNeedsReset: Bool = false
    @Published var scanToastMessage: String = ""
    @Published var showUndoDetailsAction: Bool = false
    @Published var undoFailedTxnID: String?
    @Published var lastScanSummary: String = "尚未扫描"
    @Published var lastScanAt: Date?

    @Published var digestNudgeText: String?
    @Published var ruleNudge: RuleNudge?

    @Published var needsDownloadsAuthorization: Bool = true
    @Published var downloadsFolderPath: String = ""
    @Published var archiveRootPath: String = ""
    @Published var userExcludedPaths: [String] = []
    @Published var desktopFolderPath: String = ""
    @Published var documentsFolderPath: String = ""
    @Published var accessHealth: [AccessTarget: AccessHealthItem] = [:]

    @Published var stormModeActive: Bool = false
    @Published var stormStatusText: String?

    @Published var showOnboarding: Bool = false

    private static let emptyDigest = DigestSummary(
        autoIsolatedCount: 0,
        autoIsolatedBytes: 0,
        autoOrganizedCount: 0,
        needsDecisionCount: 0,
        lastAppliedHint: nil,
        healthStatus: "初始化中",
        maintenanceHint: nil,
        missingQuarantineCount: 0,
        expiredQuarantineCount: 0,
        missingOriginalsCount: 0,
        archiveAccessStatus: .missing
    )

    private let services: ServiceContainer
    private let workerQueue = DispatchQueue(
        label: "tidy2.appstate.worker",
        qos: .utility,
        attributes: .concurrent
    )
    private let operationLock = OperationLock()

    private var didBootstrap = false
    private var watcher: FSEventsWatcher?

    private var pendingReindexDirectories: [RootScope: Set<String>] = [:]
    private var incrementalReindexTask: Task<Void, Never>?

    private var stormSamples: [(time: Date, count: Int)] = []
    private var stormRecoveryTask: Task<Void, Never>?
    private var stormDirty = false

    private let stormWindowSeconds: TimeInterval = 10
    private var stormThreshold = 200
    private let defaultStormThreshold = 200
    private let stormRecoverDelaySeconds: UInt64 = 30

    private let autoPurgeSettingKey = "auto_purge_expired_quarantine"
    private let lastNudgeAtKey = "last_nudge_at"
    private let lastRuleNudgeAtKey = "last_rule_nudge_at"
    private let archiveRootHealthKey = "archive_root_health"
    private let rulesEmergencyBrakeKey = "rules_emergency_brake"
    private let lastRepairAtKey = "last_repair_at"
    private let lastAutoPurgeAtKey = "last_auto_purge_at"
    private let onboardingCompletedKey = "onboarding_completed"
    private let initialSeedDoneKey = "initial_seed_done"
    private let stormThresholdKey = "storm_mode_threshold"
    private let testModeSettingKey = "test_mode_enabled"
    private let archiveTimeWindowSettingKey = "downloads_archive_time_window"
    private let lastProcessedAtKey = "last_processed_at"
    private let lastInboxHintAtKey = "last_inbox_hint_at"
    private let lastScanAtKey = "last_scan_at"
    private let lastScanSummaryKey = "last_scan_summary"
    private let lastDownloadsIndexStatsKey = "last_downloads_index_stats_json"
    private let pendingInboxDismissedKey = "pending_inbox_dismissed_json"
    private let lastAIAnalysisAtKey = "last_ai_analysis_at"
    private let activeChecklistTemplateKey = "activeChecklistTemplateId"
    private let userExcludedPathsKey = "user_excluded_paths_json"

    private var autoScanTimer: Timer?

    init(services: ServiceContainer) {
        self.services = services
        let savedChecklistID = UserDefaults.standard.string(forKey: activeChecklistTemplateKey)
        self.activeChecklist = ChecklistTemplate.presets.first(where: { $0.id == savedChecklistID })
            ?? ChecklistTemplate.presets[0]
        if let jsonData = UserDefaults.standard.data(forKey: "user_excluded_paths_json"),
           let paths = try? JSONDecoder().decode([String].self, from: jsonData) {
            self.userExcludedPaths = paths
        }
        services.indexer.onProgress = { [weak self] scope, count in
            Task { @MainActor [weak self] in
                guard let self, self.isBusy else { return }
                self.totalFilesScanned = count
                self.scanProgressDetail = "正在扫描 \(self.displayName(for: scope))… 已发现 \(count) 个文件"
            }
        }
        scheduleAutoScanTimer()
        // Safety watchdog: if isBusy gets stuck (e.g. from a crash), release it after 5 min
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000_000) // 5 min
            guard let self else { return }
            if self.isBusy {
                self.isBusy = false
                self.scanProgressDetail = ""
            }
        }
        // Re-schedule when settings change
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.scheduleAutoScanTimer()
        }
    }

    deinit {
        watcher?.stop()
        stormRecoveryTask?.cancel()
        incrementalReindexTask?.cancel()
        autoScanTimer?.invalidate()
    }

    private func scheduleAutoScanTimer() {
        autoScanTimer?.invalidate()
        autoScanTimer = nil
        let enabled = UserDefaults.standard.object(forKey: "auto_scan_enabled") as? Bool ?? true
        guard enabled else { return }
        let hours = UserDefaults.standard.object(forKey: "scan_interval_hours") as? Double ?? 1.0
        let interval = max(hours, 0.25) * 3600
        autoScanTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.scanButtonTappedFromHome() }
        }
    }

    // MARK: - Computed rule sections

    var recentAddedRules: [UserRule] {
        let threshold = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        return rules
            .filter { $0.createdAt >= threshold }
            .sorted { $0.createdAt > $1.createdAt }
    }

    var recentModifiedRules: [UserRule] {
        let threshold = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        return rules
            .filter { rule in
                rule.updatedAt >= threshold &&
                    rule.updatedAt.timeIntervalSince(rule.createdAt) > 60
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    var otherRules: [UserRule] {
        let addedIDs = Set(recentAddedRules.map(\.id))
        let modifiedIDs = Set(recentModifiedRules.map(\.id))
        return rules
            .filter { !addedIDs.contains($0.id) && !modifiedIDs.contains($0.id) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    var homeNoActionReason: String {
        scanNoActionReasonForHome()
    }

    var lastScanDate: Date? {
        lastScanAt
    }

    var largeTotalBytes: Int64 {
        largeFiles.reduce(Int64(0)) { $0 + $1.sizeBytes }
    }

    private var archiveExcludedPaths: [String] {
        var paths: [String] = []
        if !archiveRootPath.isEmpty {
            paths.append(URL(fileURLWithPath: archiveRootPath).standardizedFileURL.path)
        }
        paths += userExcludedPaths.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        }
        return paths
    }

    // MARK: - Bootstrap

    func bootstrapIfNeeded() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        await ensureDatabaseReady()
        Task { [weak self] in
            guard let self else { return }
            await self.refreshAll(trigger: "bootstrap")
        }
    }

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func completeOnboarding() async {
        do {
            try await runBackground {
                try self.services.store.setStringSetting(key: self.onboardingCompletedKey, value: "1")
                if (try self.services.store.doubleSetting(key: "first_run_started_at")) == nil {
                    try self.services.store.setDoubleSetting(
                        key: "first_run_started_at",
                        value: Date().timeIntervalSince1970
                    )
                }
            }
            showOnboarding = false
            await ensureFirstRunResultsIfNeeded(force: true)
            await startWatcherIfPossible()
            await refreshAll(trigger: "onboarding-complete")
            Task.detached(priority: .background) { [weak self] in
                guard let self else { return }
                await self.scanButtonTappedFromHome()
            }
        } catch {
            handleError(error)
        }
    }

    // MARK: - Navigation

    func openBundles() {
        digestNudgeText = nil
        pendingTab = .bundles
    }

    func openBundlesTab() {
        openBundles()
    }

    func openBundleDetail(_ bundle: DecisionBundle) {
        // Bundle detail is a drill-down within the bundles tab.
        // We use pendingTab = .bundleDetail so RootView can handle path+tab together.
        pendingTab = .bundleDetail(bundle.id)
    }

    func openQuarantine() {
        pendingTab = .quarantine
    }

    func openSearch() {
        pendingTab = .search
    }

    func openDuplicates() {
        pendingTab = .duplicates
    }

    func openCleanup() {
        pendingTab = .cleanup
    }

    func openAIFiles() {
        pendingTab = .aiFiles
    }

    func openCases() {
        pendingTab = .cases
    }

    func setActiveChecklist(id: String) {
        let template = ChecklistTemplate.presets.first(where: { $0.id == id }) ?? ChecklistTemplate.presets[0]
        activeChecklist = template
        UserDefaults.standard.set(template.id, forKey: activeChecklistTemplateKey)
    }

    func addUserExcludedPath(_ path: String) {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard !userExcludedPaths.contains(normalized) else { return }
        userExcludedPaths.append(normalized)
        persistUserExcludedPaths()
    }

    func removeUserExcludedPath(_ path: String) {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        userExcludedPaths.removeAll { $0 == normalized }
        persistUserExcludedPaths()
    }

    private func persistUserExcludedPaths() {
        if let data = try? JSONEncoder().encode(userExcludedPaths) {
            UserDefaults.standard.set(data, forKey: userExcludedPathsKey)
        }
    }

    func openVersionFiles() {
        pendingTab = .versionFiles
    }

    func openSettings() {
        pendingTab = .settings
    }

    func triggerAIAnalysis() async {
        await runBatchAnalysis()
    }

    func runBatchAnalysis() async {
        launchAIAnalysis(priority: .utility) { service in
            await service.runBatchAnalysis()
        }
    }

    func refreshAIAnalysisState() async {
        await refreshAIAnalysisCount()
        await loadAIIntelligenceItems()
        await loadDetectedCases()
        await refreshTotalFilesScanned()
        await loadDuplicateGroups()
        await loadLargeFiles()
        await loadOldInstallers()
        await refreshAIAnalysisError()
    }

    func loadAIIntelligenceItems() async {
        let items = (try? services.store.allFileIntelligence(limit: 200)) ?? []
        await MainActor.run {
            aiIntelligenceItems = items
        }
    }

    func refreshAIAnalysisCount() async {
        do {
            let count = try await runBackground {
                try self.services.store.countAnalyzedFiles()
            }
            aiAnalyzedFilesCount = count
        } catch {
            handleError(error)
        }
    }

    func refreshTotalFilesScanned() async {
        do {
            let count = try await runBackground {
                try self.services.store.totalFileCount()
            }
            totalFilesScanned = count
        } catch {
            handleError(error)
        }
    }

    func refreshAIAnalysisError() async {
        aiAnalysisLastError = await services.fileIntelligenceService.currentError()
    }

    func loadDuplicateGroups() async {
        do {
            let groups = try await runBackground {
                try self.services.store.findDuplicateGroups()
            }
            let wasted = groups.reduce(into: Int64(0)) { partialResult, group in
                partialResult += group.totalWastedBytes
            }
            duplicateGroups = groups
            duplicatesTotalWastedBytes = wasted
        } catch {
            handleError(error)
        }
    }

    func autoCleanDuplicates() async -> (kept: Int, deleted: Int, freedBytes: Int64) {
        var toDelete: [String] = []
        var freedBytes: Int64 = 0
        for group in duplicateGroups {
            let sorted = group.files.sorted { $0.modifiedAt > $1.modifiedAt }
            let dupes = sorted.dropFirst()
            for file in dupes {
                toDelete.append(file.path)
                freedBytes += file.sizeBytes
            }
        }
        let deleted = await moveFilesToTrash(paths: toDelete)
        await loadDuplicateGroups()
        await loadLargeFiles()
        return (kept: duplicateGroups.count, deleted: deleted, freedBytes: freedBytes)
    }

    func loadLargeFiles() async {
        do {
            largeFiles = try await runBackground {
                try self.services.store.largeFiles()
            }
        } catch {
            handleError(error)
        }
    }

    func loadOldInstallers() async {
        do {
            oldInstallers = try await runBackground {
                try self.services.store.oldInstallerCandidates()
            }
        } catch {
            handleError(error)
        }
    }

    func loadVersionGroups() async {
        do {
            versionGroups = try await runBackground {
                try self.services.store.versionFileGroups()
            }
        } catch {
            handleError(error)
        }
    }

    func loadBundles() async {
        do {
            let snapshot = try await runBackground {
                let bundles = try self.services.bundleBuilder.pendingBundles(limit: 50)
                let fm = FileManager.default
                let missingCounts = Dictionary(uniqueKeysWithValues: bundles.map { bundle in
                    let missing = bundle.filePaths.reduce(into: 0) { count, path in
                        if !fm.fileExists(atPath: path) {
                            count += 1
                        }
                    }
                    return (bundle.id, missing)
                })
                let digest = try self.services.digestService.weeklySummary(now: Date())
                return (bundles, missingCounts, digest.needsDecisionCount)
            }

            bundles = snapshot.0
            bundleMissingCounts = snapshot.1
            pendingBundlesCount = snapshot.2
        } catch {
            handleError(error)
        }
    }

    func loadChangeLog() async {
        do {
            changeLogEntries = try await runBackground {
                try self.services.store.recentChangeLog(limit: 200)
            }
        } catch {
            handleError(error)
        }
    }

    func clearAIAnalysisError() {
        aiAnalysisLastError = nil
        let service = services.fileIntelligenceService
        Task {
            await service.clearLastError()
        }
    }

    func loadDetectedCases() async {
        let sourceItems: [FileIntelligence]
        if aiIntelligenceItems.isEmpty {
            sourceItems = (try? services.store.allFileIntelligence(limit: 200)) ?? []
            if !sourceItems.isEmpty {
                aiIntelligenceItems = sourceItems
            }
        } else {
            sourceItems = aiIntelligenceItems
        }

        let items = sourceItems.filter { item in
            !(item.extractedName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let grouped = Dictionary(grouping: items) { item in
            (item.extractedName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let allTypes = Set(items.map(\.docType))
        let templateID: String
        if allTypes.contains(.passport) || allTypes.contains(.immigrationForm) || allTypes.contains(.visaDoc) {
            templateID = "immigration"
        } else if allTypes.contains(.resume) || allTypes.contains(.offerLetter) {
            templateID = "hr_onboarding"
        } else if allTypes.contains(.propertyDoc) || allTypes.contains(.contract) {
            templateID = "real_estate"
        } else if allTypes.contains(.invoice) || allTypes.contains(.taxRecord) {
            templateID = "finance_audit"
        } else if allTypes.contains(.medicalRecord) || allTypes.contains(.prescription) {
            templateID = "medical"
        } else {
            templateID = "immigration"
        }

        detectedCases = grouped
            .filter { !$0.key.isEmpty && $0.value.count >= 2 }
            .map { DetectedCase(id: $0.key, name: $0.key, files: $0.value) }
            .sorted { lhs, rhs in
                if lhs.files.count == rhs.files.count {
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
                return lhs.files.count > rhs.files.count
            }

        if let template = ChecklistTemplate.presets.first(where: { $0.id == templateID }) {
            activeChecklist = template
            UserDefaults.standard.set(template.id, forKey: activeChecklistTemplateKey)
        }
    }

    func organizeCaseFiles(_ cas: DetectedCase) async {
        guard !archiveRootPath.isEmpty else {
            statusMessage = "请先设置整理文件夹"
            return
        }

        let safeCaseName = sanitizedArchiveComponent(cas.name)
        var moved = 0
        for intel in cas.files {
            let safeDocType = sanitizedArchiveComponent(intel.docType.rawValue)
            let folder = "Cases/\(safeCaseName)/\(safeDocType)"
            let ok = await moveFileToArchiveFolder(
                sourcePath: intel.filePath,
                destinationFolder: folder,
                successMessage: nil,
                suppressSuccessMessage: true,
                suppressRefresh: true
            )
            if ok {
                moved += 1
            }
        }

        await refreshAll(trigger: "organize-case-\(cas.name)")
        await loadDetectedCases()
        statusMessage = "✓ 已归档 \(cas.name) 的 \(moved) 个文件"
    }

    func runAIAnalysisNow() async {
        isAIAnalyzing = true
        NotificationCenter.default.post(name: .aiAnalysisStarted, object: nil)
        await services.fileIntelligenceService.analyzeNewFiles()
        isAIAnalyzing = false
        NotificationCenter.default.post(name: .aiAnalysisFinished, object: nil)
        await refreshAIAnalysisState()
    }

    /// Remove an AI intelligence record from memory + DB without touching the file on disk.
    /// Used to dismiss ghost records (file already moved/deleted) or unwanted suggestions.
    func dismissAIRecord(path: String) async {
        aiIntelligenceItems.removeAll { $0.filePath == path }
        searchResultIntelMap.removeValue(forKey: path)
        try? await runBackground {
            try self.services.store.deleteFileIntelligence(path: path)
        }
    }

    /// Remove all AI records whose file no longer exists on disk.
    func purgeGhostAIRecords() async {
        let ghosts = aiIntelligenceItems.filter {
            !FileManager.default.fileExists(atPath: $0.filePath)
        }
        guard !ghosts.isEmpty else { return }
        let paths = ghosts.map(\.filePath)
        aiIntelligenceItems.removeAll { paths.contains($0.filePath) }
        for path in paths { searchResultIntelMap.removeValue(forKey: path) }
        try? await runBackground {
            for path in paths {
                try? self.services.store.deleteFileIntelligence(path: path)
            }
        }
        statusMessage = "已清除 \(ghosts.count) 条失效记录"
    }

    func markAIItemKeep(path: String) async {
        let existing = aiIntelligenceItems.first(where: { $0.filePath == path }) ?? searchResultIntelMap[path]

        do {
            let current = if let existing {
                existing
            } else {
                try await runBackground {
                    try self.services.store.fileIntelligence(for: path)
                }
            }

            guard let current else { return }

            let updated = FileIntelligence(
                filePath: current.filePath,
                category: current.category,
                summary: current.summary,
                suggestedFolder: current.suggestedFolder,
                keepOrDelete: .keep,
                reason: current.reason,
                confidence: current.confidence,
                analyzedAt: current.analyzedAt,
                extractedName: current.extractedName,
                documentDate: current.documentDate,
                docType: current.docType
            )

            try await runBackground {
                try self.services.store.upsertFileIntelligence(updated)
            }

            if let idx = aiIntelligenceItems.firstIndex(where: { $0.filePath == path }) {
                aiIntelligenceItems[idx] = updated
            }
            searchResultIntelMap[path] = updated
            statusMessage = "已保留：\(URL(fileURLWithPath: path).lastPathComponent)"
            await loadDetectedCases()
        } catch {
            handleError(error)
        }
    }

    @discardableResult
    func moveFileToSuggestedFolder(_ intel: FileIntelligence) async -> Bool {
        await moveFileToArchiveFolder(
            sourcePath: intel.filePath,
            destinationFolder: intel.suggestedFolder,
            successMessage: "已移动：\(URL(fileURLWithPath: intel.filePath).lastPathComponent) → \(intel.suggestedFolder)"
        )
    }

    /// Efficient bulk-move: moves all items without calling refreshAll per item,
    /// then does a single refresh at the end. Prevents the 92x re-population bug.
    @discardableResult
    func bulkMoveToSuggestedFolders(_ items: [FileIntelligence]) async -> Int {
        guard !items.isEmpty else { return 0 }
        var movedCount = 0
        for intel in items {
            let ok = await moveFileToArchiveFolder(
                sourcePath: intel.filePath,
                destinationFolder: intel.suggestedFolder,
                successMessage: nil,
                suppressSuccessMessage: true,
                suppressRefresh: true
            )
            if ok { movedCount += 1 }
        }
        // Single refresh after all moves
        await refreshAll(trigger: "bulk-ai-move")
        await refreshAIAnalysisState()
        statusMessage = movedCount > 0
            ? "已批量移动 \(movedCount)/\(items.count) 个文件"
            : "没有文件被移动，请检查整理文件夹设置"
        return movedCount
    }

    @discardableResult
    func moveFileToFolder(path: String, destinationFolder: String) async -> Bool {
        await moveFileToArchiveFolder(
            sourcePath: path,
            destinationFolder: destinationFolder,
            successMessage: "已移动：\(URL(fileURLWithPath: path).lastPathComponent) → \(destinationFolder)"
        )
    }

    @discardableResult
    private func moveFileToArchiveFolder(sourcePath: String,
                                         destinationFolder: String,
                                         successMessage: String?,
                                         suppressSuccessMessage: Bool = false,
                                         suppressRefresh: Bool = false) async -> Bool {
        let sourceURL = URL(fileURLWithPath: sourcePath)
        let filename = sourceURL.lastPathComponent

        guard FileManager.default.fileExists(atPath: sourcePath) else {
            statusMessage = "文件已不存在：\(filename)"
            return false
        }

        guard !destinationFolder.contains("..") else {
            statusMessage = "路径无效"
            return false
        }

        guard let archiveRoot = try? services.accessManager.resolveArchiveRootAccess(),
              !archiveRootPath.isEmpty else {
            statusMessage = "请先设置整理文件夹"
            return false
        }

        let destDir = archiveRoot.appendingPathComponent(destinationFolder, isDirectory: true)
        let archiveRootPath = archiveRoot.standardizedFileURL.path
        let destDirPath = destDir.standardizedFileURL.path
        guard destDirPath == archiveRootPath || destDirPath.hasPrefix(archiveRootPath + "/") else {
            statusMessage = "路径无效"
            return false
        }

        let indexedFile = try? await runBackground {
            try self.services.store.fileByPath(sourcePath)
        }

        let didStartAccess = archiveRoot.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                archiveRoot.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let destinationPath = try await runBackground {
                let fm = FileManager.default
                try fm.createDirectory(at: destDir, withIntermediateDirectories: true, attributes: nil)

                var resolvedURL = destDir.appendingPathComponent(filename)
                if fm.fileExists(atPath: resolvedURL.path) {
                    let ext = resolvedURL.pathExtension
                    let base = resolvedURL.deletingPathExtension().lastPathComponent
                    var counter = 1
                    repeat {
                        let newName = ext.isEmpty ? "\(base)_\(counter)" : "\(base)_\(counter).\(ext)"
                        resolvedURL = destDir.appendingPathComponent(newName)
                        counter += 1
                    } while fm.fileExists(atPath: resolvedURL.path)
                }

                try fm.moveItem(at: sourceURL, to: resolvedURL)
                return resolvedURL.path
            }

            let now = Date()
            let modifiedAt = (
                try? FileManager.default.attributesOfItem(atPath: destinationPath)[.modificationDate] as? Date
            ) ?? now

            try? await runBackground {
                if indexedFile != nil {
                    try self.services.store.moveIndexedFile(
                        oldPath: sourcePath,
                        newPath: destinationPath,
                        newScope: .archived,
                        modifiedAt: modifiedAt,
                        lastSeenAt: now
                    )
                }

                try self.services.store.insertJournalEntry(
                    .init(
                        id: UUID().uuidString,
                        txnID: "ai-move-" + UUID().uuidString,
                        actor: "user",
                        actionType: .move,
                        targetType: "file",
                        targetID: sourcePath,
                        srcPath: sourcePath,
                        dstPath: destinationPath,
                        copyOrMove: "move",
                        conflictResolution: "rename",
                        verified: true,
                        errorCode: nil,
                        errorMessage: nil,
                        bytesDelta: 0,
                        createdAt: now,
                        undoable: true
                    )
                )
            }

            aiIntelligenceItems.removeAll { $0.filePath == sourcePath }
            searchResults.removeAll { $0.path == sourcePath }
            installerReviewCandidates.removeAll { $0.path == sourcePath }
            searchResultIntelMap.removeValue(forKey: sourcePath)
            pendingInboxCount = installerReviewCandidates.count

            if !suppressRefresh {
                await loadChangeLog()
                await loadDuplicateGroups()
                await loadLargeFiles()
                await loadOldInstallers()
                await loadDetectedCases()
            }

            if !suppressSuccessMessage {
                statusMessage = successMessage ?? "已移动：\(filename)"
            }
            return true
        } catch {
            statusMessage = "移动失败：\(error.localizedDescription)"
            return false
        }
    }

    private func sanitizedArchiveComponent(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let replaced = trimmed
            .replacingOccurrences(of: "..", with: "")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return replaced.isEmpty ? "未命名" : replaced
    }

    @discardableResult
    func moveFileToTrash(path: String) async -> Bool {
        await moveFilesToTrash(paths: [path]) > 0
    }

    @discardableResult
    func moveFilesToTrash(paths: [String]) async -> Int {
        let uniquePaths = Array(Set(paths)).sorted()
        guard !uniquePaths.isEmpty else { return 0 }

        // Ensure security-scoped access is active for all known scopes before background work
        _ = try? services.accessManager.resolveDownloadsAccess()
        _ = try? services.accessManager.resolveDesktopAccess()
        _ = try? services.accessManager.resolveDocumentsAccess()

        do {
            let (movedPaths, skippedCount) = try await runBackground {
                let fileManager = FileManager.default
                let now = Date()
                var movedPaths: [String] = []
                var skipped = 0

                for path in uniquePaths {
                    guard fileManager.fileExists(atPath: path) else {
                        try? self.services.store.updateFileStatus(path: path, status: .missing, lastSeenAt: now)
                        skipped += 1
                        continue
                    }
                    let url = URL(fileURLWithPath: path)
                    try fileManager.trashItem(at: url, resultingItemURL: nil)
                    try? self.services.store.updateFileStatus(path: path, status: .missing, lastSeenAt: now)
                    movedPaths.append(path)
                }

                return (movedPaths, skipped)
            }

            let movedCount = movedPaths.count

            guard movedCount > 0 else {
                if skippedCount > 0 {
                    statusMessage = "\(skippedCount) 个文件不存在，已跳过"
                } else {
                    statusMessage = "没有找到可处理的文件"
                }
                return 0
            }

            searchResults.removeAll { movedPaths.contains($0.path) }
            installerReviewCandidates.removeAll { movedPaths.contains($0.path) }
            pendingInboxCount = installerReviewCandidates.count
            for path in movedPaths {
                searchResultIntelMap.removeValue(forKey: path)
            }
            aiIntelligenceItems.removeAll { movedPaths.contains($0.filePath) }

            await refreshAll(trigger: "trash-files")
            await refreshAIAnalysisState()
            await loadVersionGroups()
            if skippedCount > 0 {
                statusMessage = "已移到回收站 \(movedCount) 个文件，\(skippedCount) 个不存在已跳过"
            } else {
                statusMessage = "已移到回收站 \(movedCount) 个文件"
            }
            return movedCount
        } catch {
            handleError(error)
            return 0
        }
    }

    func openInstallerCandidates() {
        pendingTab = .installerCandidates
    }

    func handlePendingInboxItem(_ item: SearchResultItem, action: PendingInboxAction) async {
        switch action {
        case .keep:
            await keepPendingInboxItem(item)
        case .archive:
            await applyPendingInboxItem(item, actionKind: .move)
        case .quarantine:
            await applyPendingInboxItem(item, actionKind: .quarantine)
        }
    }

    func openChangeLog() {
        push(.changeLog)
    }

    func openUndoFailureDetails() {
        showUndoDetailsAction = false
        openChangeLog()
    }

    func openRules() {
        push(.rules)
    }

    func openMetrics() {
        push(.metrics)
    }

    func bundle(by id: String) -> DecisionBundle? {
        bundles.first(where: { $0.id == id })
    }

    func hasDefaultArchiveRoot() -> Bool {
        !archiveRootPath.isEmpty
    }

    func missingFilesCount(bundleID: String) -> Int {
        bundleMissingCounts[bundleID] ?? 0
    }

    func pendingInboxExplanation(for item: SearchResultItem) -> String {
        FileExplanationBuilder.explanation(path: item.path, bundleType: nil)
    }

    private func keepPendingInboxItem(_ item: SearchResultItem) async {
        do {
            try await runBackground {
                var map = try self.loadPendingInboxDismissedMapUnlocked()
                map[item.id] = item.modifiedAt.timeIntervalSince1970
                try self.savePendingInboxDismissedMapUnlocked(map)
            }
            statusMessage = "已保留：\(item.name)"
            installerReviewCandidates.removeAll { $0.id == item.id }
            pendingInboxCount = installerReviewCandidates.count
            await logEvent("pending_inbox_keep", "Keep pending inbox item", payload: [
                "file_id": item.id,
                "name": item.name
            ])
            await refreshAll(trigger: "pending-inbox-keep")
        } catch {
            handleError(error)
        }
    }

    private func applyPendingInboxItem(_ item: SearchResultItem, actionKind: BundleActionKind) async {
        guard FileManager.default.fileExists(atPath: item.path) else {
            statusMessage = "文件已不存在，已从待确认移除。"
            await keepPendingInboxItem(item)
            return
        }

        let bundleID = "pending-inbox-\(UUID().uuidString)"
        let now = Date()
        let action = BundleActionConfig(actionKind: actionKind, renameTemplate: nil, targetFolderBookmark: nil)
        let bundle = DecisionBundle(
            id: bundleID,
            type: .weeklyDocuments,
            title: "待确认收件箱：\(item.name)",
            summary: "手动处理待确认文件",
            action: action,
            evidence: [
                EvidenceItem(
                    id: UUID().uuidString,
                    kind: .fileSignal,
                    title: "待确认收件箱",
                    detail: "用户手动确认的高风险/不确定文件。",
                    supportingFileIDs: [item.id],
                    supportingRuleID: nil
                )
            ],
            risk: .medium,
            filePaths: [item.path],
            status: .pending,
            createdAt: now,
            snoozedUntil: nil,
            matchedRuleID: nil
        )

        isBusy = true
        defer { isBusy = false }

        do {
            try await runBackground {
                try self.services.store.upsertBundle(bundle)
            }

            let result = try await runExclusiveLongTask(name: "pending-inbox-apply:\(item.id)", timeoutSeconds: 45) {
                try self.services.actionEngine.applyBundle(
                    bundleID: bundleID,
                    override: BundleApplyOverride(
                        actionKind: actionKind,
                        renameTemplate: nil,
                        targetFolderBookmark: nil,
                        allowHighRiskMoveOverride: false
                    )
                )
            }

            try await runBackground {
                var map = try self.loadPendingInboxDismissedMapUnlocked()
                map[item.id] = item.modifiedAt.timeIntervalSince1970
                try self.savePendingInboxDismissedMapUnlocked(map)
            }

            if result.succeeded > 0 {
                let verb = actionKind == .move ? "已归档" : "已隔离"
                statusMessage = "\(verb)：\(item.name)"
            } else {
                statusMessage = "处理失败：\(result.firstError ?? "未成功执行文件操作")"
            }

            await logEvent("pending_inbox_apply", "Applied pending inbox action", payload: [
                "file_id": item.id,
                "action": actionKind.rawValue,
                "succeeded": String(result.succeeded),
                "failed": String(result.failed)
            ])
            await refreshAll(trigger: "pending-inbox-apply")
        } catch {
            handleError(error)
        }
    }

    // MARK: - Digest actions

    func runAutopilotNow() async {
        appendRuntimeLog("[AppState] quick_scan_requested")
        await runDownloadsScan(mode: .quick)
    }

    func clearArchiveResultToast() {
        archiveResultMessage = ""
        archiveOpenDestinations = []
    }

    func openArchiveDestination(_ destination: ArchiveOpenDestination) {
        let url = URL(fileURLWithPath: destination.path, isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.path) else {
            let message = "未创建（本次未移动）"
            statusMessage = message
            scanToastMessage = message
            appendRuntimeLog("[AppState] archive_destination_missing path=\(url.path)")
            return
        }
        NSWorkspace.shared.open(url)
    }

    func openPrimaryArchiveLocation() {
        guard let destination = archiveOpenDestinations.first else {
            let message = "未创建（本次未移动）"
            statusMessage = message
            scanToastMessage = message
            return
        }
        openArchiveDestination(destination)
    }

    func openQuarantineLocation() {
        do {
            let root = try quarantineRootURL()
            guard FileManager.default.fileExists(atPath: root.path) else {
                let message = "未创建（本次未隔离）"
                statusMessage = message
                scanToastMessage = message
                return
            }
            NSWorkspace.shared.open(root)
        } catch {
            handleError(error)
        }
    }

    func setTestModeEnabled(_ enabled: Bool) async {
        do {
            try await runBackground {
                try self.services.store.setStringSetting(
                    key: self.testModeSettingKey,
                    value: enabled ? "1" : "0"
                )
                try self.services.store.setDoubleSetting(key: "downloads_last_indexed_at", value: 0)
                if enabled, let downloads = try self.services.accessManager.resolveDownloadsAccess() {
                    let testRoot = downloads.appendingPathComponent("TidyTest", isDirectory: true)
                    try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
                }
            }
            isTestModeEnabled = enabled
            statusMessage = enabled ? "测试模式已开启：使用下载文件夹/TidyTest。" : "测试模式已关闭：使用下载文件夹。"
            await startWatcherIfPossible()
            await runIncrementalResyncForAuthorizedScopes(reason: "test-mode-toggle")
            await refreshAll(trigger: "test-mode-toggle")
        } catch {
            handleError(error)
        }
    }

    func setArchiveTimeWindow(_ window: ArchiveTimeWindow) async {
        do {
            try await runBackground {
                try self.services.store.setStringSetting(
                    key: self.archiveTimeWindowSettingKey,
                    value: window.rawValue
                )
            }
            UserDefaults.standard.set(window.rawValue, forKey: archiveTimeWindowSettingKey)
            archiveTimeWindow = window
            statusMessage = "时间范围：\(window.title)"
            await runIncrementalResyncForAuthorizedScopes(reason: "archive-time-window")
            await refreshAll(trigger: "archive-time-window")
        } catch {
            handleError(error)
        }
    }

    func runFullHistoryScan() async {
        do {
            try await runBackground {
                try self.services.store.setStringSetting(
                    key: self.archiveTimeWindowSettingKey,
                    value: ArchiveTimeWindow.all.rawValue
                )
            }
            UserDefaults.standard.set(ArchiveTimeWindow.all.rawValue, forKey: archiveTimeWindowSettingKey)
            archiveTimeWindow = .all
            await runAutopilotNow()
        } catch {
            handleError(error)
        }
    }

    func runRecommendedArchiveNow() async {
        if archiveTimeWindow == .all {
            await runPrepareArchiveBundlesOnly()
        } else {
            await runDownloadsScan(mode: .quick)
        }
        await executeRecommendedArchivePlan()
    }

    private func runPrepareArchiveBundlesOnly() async {
        do {
            guard let rootURL = try resolveRootURL(scope: .downloads) else {
                let message = "范围路径不存在，请重新选择"
                statusMessage = message
                scanToastMessage = message
                return
            }
            let excludedPaths = archiveExcludedPaths
            _ = try await runExclusiveLongTask(name: "archive-prepare-bundles", timeoutSeconds: 30) {
                _ = try self.services.indexer.forceFullScanDownloads(
                    rootURL: rootURL,
                    excludedPaths: excludedPaths
                )
                try self.services.bundleBuilder.rebuildWeeklyBundles(scope: .downloads, now: Date())
                return true
            }
            triggerBackgroundAIAnalysis()
            await refreshAll(trigger: "archive-prepare-bundles")
        } catch {
            handleError(error)
        }
    }

    func executeRecommendedArchivePlan() async {
        showUndoDetailsAction = false
        undoFailedTxnID = nil
        archiveResultMessage = ""
        archiveOpenDestinations = []
        lastArchiveBucketSummary = ""

        if recommendedPlanBuckets.contains(where: { $0.actionableFiles > 0 && $0.bundleID == nil }) {
            statusMessage = "正在准备归档计划..."
            await runPrepareArchiveBundlesOnly()
            await refreshAll(trigger: "archive-plan-prepare")
        }

        let actionable = recommendedPlanActionableCount
        guard actionable > 0 else {
            let message = "当前没有可归档的文件。"
            statusMessage = message
            scanToastMessage = message
            return
        }

        let unboundBuckets = recommendedPlanBuckets.filter { $0.actionableFiles > 0 && $0.bundleID == nil }
        if !unboundBuckets.isEmpty {
            let names = unboundBuckets.map(\.title).joined(separator: ", ")
            let message = "未整理：计划尚未生成（\(names)）。请先扫描一次。"
            statusMessage = message
            scanToastMessage = message
            appendRuntimeLog("[AppState] archive_plan_unbound actionable=\(actionable) buckets=\(names)")
            await persistLastScan(summary: message)
            return
        }

        let skipInstallerQuarantine = archiveTimeWindow == .all
        let hasMoveWork = recommendedPlanBuckets.contains { $0.actionKind == .move && $0.actionableFiles > 0 }
        if hasMoveWork && !hasDefaultArchiveRoot() {
            guard let selected = chooseFolder(
                message: "请选择整理文件夹",
                prompt: "选择文件夹",
                defaultURL: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ) else {
                statusMessage = "整理已取消，请先设置整理文件夹"
                return
            }
            await saveDefaultArchiveRoot(url: selected)
        }

        let rootURLForVerification: URL?
        do {
            rootURLForVerification = try resolveRootURL(scope: .downloads)
        } catch {
            rootURLForVerification = nil
            appendRuntimeLog("[AppState] archive_verify_root_resolve_failed error=\(error.localizedDescription)")
        }
        let filesBefore = countVisibleTopLevelFiles(in: rootURLForVerification)

        isBusy = true
        statusMessage = "正在归档下载文件夹..."
        defer { isBusy = false }

        var screenshotsMoved = 0
        var pdfMoved = 0
        var inboxMoved = 0
        var installersQuarantined = 0
        var hadFailures = false
        var firstFailureReason: String?

        for bucket in recommendedPlanBuckets {
            guard bucket.actionableFiles > 0, let bundleID = bucket.bundleID else { continue }
            if skipInstallerQuarantine && bucket.kind == .installers {
                continue
            }

            do {
                let result = try await runExclusiveLongTask(name: "archive-recommended:\(bundleID)", timeoutSeconds: 60) {
                    try self.services.actionEngine.applyBundle(
                        bundleID: bundleID,
                        override: BundleApplyOverride(
                            actionKind: bucket.actionKind,
                            renameTemplate: nil,
                            targetFolderBookmark: nil,
                            allowHighRiskMoveOverride: false
                        )
                    )
                }

                switch bucket.kind {
                case .screenshots:
                    screenshotsMoved += result.movedCount
                case .pdfs:
                    pdfMoved += result.movedCount
                case .inbox:
                    inboxMoved += result.movedCount
                case .installers:
                    installersQuarantined += result.quarantinedCount
                }
                appendRuntimeLog(
                    "[AppState] apply_counts bucket=\(bucket.kind.rawValue) moved=\(result.movedCount) renamed=\(result.renamedCount) quarantined=\(result.quarantinedCount) failed=\(result.failed)"
                )
                if result.failed > 0 {
                    hadFailures = true
                    if firstFailureReason == nil {
                        firstFailureReason = result.firstError ?? "部分文件处理失败"
                    }
                }
            } catch {
                hadFailures = true
                if firstFailureReason == nil {
                    firstFailureReason = archiveFailureMessage(error)
                }
                appendRuntimeLog("[AppState] archive_recommended_failed bundle_id=\(bundleID) error=\(error.localizedDescription)")
            }
        }

        let filesAfter = countVisibleTopLevelFiles(in: rootURLForVerification)
        let reducedCount = max(0, filesBefore - filesAfter)
        let movedOnlyCount = screenshotsMoved + pdfMoved + inboxMoved
        appendRuntimeLog(
            "[AppState] archive_verify scope=\(isTestModeEnabled ? "TidyTest" : "Downloads") files_before=\(filesBefore) files_after=\(filesAfter) reduced=\(reducedCount)"
        )
        appendRuntimeLog(
            "[AppState] apply_counts_total moved=\(movedOnlyCount) quarantined=\(installersQuarantined) reduced=\(reducedCount)"
        )

        await refreshAll(trigger: "archive-recommended")

        let archivedFiles = screenshotsMoved + pdfMoved + inboxMoved + installersQuarantined
        lastArchiveBucketSummary = "截图 \(screenshotsMoved)、PDF \(pdfMoved)、杂物 \(inboxMoved)、安装包 \(installersQuarantined)"

        let lowImpactMessage = "未整理：本次没有移动文件（原因：规则未命中/时间窗口/范围不对）"
        let shouldShowLowImpact = reducedCount < 5
        let shouldWarnInsufficientMove = filesBefore >= 20 && movedOnlyCount < 20
        let insufficientMoveMessage = "本次移动 \(movedOnlyCount) 个，少于预期（原因：范围/时间窗口/规则未命中）"

        if archivedFiles > 0 {
            let message = "已归档：截图\(screenshotsMoved)、PDF\(pdfMoved)、杂物\(inboxMoved)；隔离安装包\(installersQuarantined)（可撤销） · 下载区 \(filesBefore)→\(filesAfter)"
            statusMessage = message
            if shouldWarnInsufficientMove {
                scanToastMessage = insufficientMoveMessage
            } else {
                scanToastMessage = shouldShowLowImpact ? lowImpactMessage : message
            }
            archiveResultMessage = message
            archiveOpenDestinations = makeArchiveOpenDestinations(
                screenshotsMoved: screenshotsMoved,
                pdfMoved: pdfMoved,
                inboxMoved: inboxMoved
            )
            let summary = "已归档 \(archivedFiles) 个文件（截图 \(screenshotsMoved)、PDF \(pdfMoved)、杂物 \(inboxMoved)、安装包 \(installersQuarantined)）；下载区文件 \(filesBefore)→\(filesAfter)"
            await persistLastScan(summary: summary)
            let now = Date().timeIntervalSince1970
            do {
                try await runBackground {
                    try self.services.store.setDoubleSetting(key: self.lastProcessedAtKey, value: now)
                }
            } catch {
                appendRuntimeLog("[AppState] failed to persist last_processed_at: \(error.localizedDescription)")
            }
            showNewFilesHint = false
            newFilesToArchiveCount = 0
            await logEvent("archive_recommended", message, payload: [
                "archived_files": String(archivedFiles),
                "screenshots_moved": String(screenshotsMoved),
                "pdf_moved": String(pdfMoved),
                "inbox_moved": String(inboxMoved),
                "installers_quarantined": String(installersQuarantined),
                "files_before": String(filesBefore),
                "files_after": String(filesAfter),
                "files_reduced": String(reducedCount),
                "time_window": archiveTimeWindow.rawValue,
                "had_failures": hadFailures ? "1" : "0"
            ])
            await recordArchiveFinishedJournal(
                movedScreenshots: screenshotsMoved,
                movedPDFs: pdfMoved,
                movedInbox: inboxMoved,
                quarantinedInstallers: installersQuarantined,
                filesBefore: filesBefore,
                filesAfter: filesAfter,
                skippedReason: shouldWarnInsufficientMove ? insufficientMoveMessage : nil
            )
            if let firstDestination = archiveOpenDestinations.first {
                openArchiveDestination(firstDestination)
            }
            if shouldShowLowImpact {
                await persistLastScan(summary: lowImpactMessage)
            }
        } else if hadFailures {
            let reason = firstFailureReason ?? "当前建议暂时不可执行，请先扫描一次。"
            let message = "未整理：\(reason)"
            statusMessage = message
            scanToastMessage = shouldShowLowImpact ? lowImpactMessage : message
            archiveResultMessage = message
            archiveOpenDestinations = []
            await recordArchiveFinishedJournal(
                movedScreenshots: 0,
                movedPDFs: 0,
                movedInbox: 0,
                quarantinedInstallers: 0,
                filesBefore: filesBefore,
                filesAfter: filesAfter,
                skippedReason: message
            )
            if shouldShowLowImpact {
                await persistLastScan(summary: lowImpactMessage)
            }
        } else {
            let message = shouldShowLowImpact ? lowImpactMessage : "当前没有可归档的文件。"
            statusMessage = message
            scanToastMessage = message
            archiveResultMessage = message
            archiveOpenDestinations = []
            await recordArchiveFinishedJournal(
                movedScreenshots: 0,
                movedPDFs: 0,
                movedInbox: 0,
                quarantinedInstallers: 0,
                filesBefore: filesBefore,
                filesAfter: filesAfter,
                skippedReason: message
            )
            await persistLastScan(summary: message)
        }
    }

    func forceFullScanDownloads() async {
        guard !databaseNeedsReset else {
            statusMessage = "数据库需要重置，请先修复"
            return
        }
        await runDownloadsScan(mode: .full)
    }

    private func runDownloadsScan(mode: DownloadsScanMode) async {
        appendRuntimeLog("[AppState] \(mode.operationName)_entry")
        showUndoDetailsAction = false
        undoFailedTxnID = nil

        guard !databaseNeedsReset else {
            let message = "数据库需要重置后才能扫描。"
            statusMessage = message
            scanToastMessage = message
            appendRuntimeLog("[AppState] \(mode.operationName)_guard reason=db_needs_reset")
            await persistLastScan(summary: message)
            return
        }

        if isBusy {
            let message = "正在处理中，请稍后重试"
            statusMessage = message
            scanToastMessage = message
            appendRuntimeLog("[AppState] \(mode.operationName)_guard reason=busy")
            await persistLastScan(summary: message)
            return
        }

        let rootURL: URL
        do {
            guard let resolvedRoot = try resolveRootURL(scope: .downloads) else {
                let message = "范围路径不存在，请重新选择"
                statusMessage = message
                scanToastMessage = message
                appendRuntimeLog("[AppState] \(mode.operationName)_guard reason=scope_root_missing")
                await persistLastScan(summary: message)
                return
            }

            guard FileManager.default.fileExists(atPath: resolvedRoot.path) else {
                let message = "范围路径不存在，请重新选择"
                statusMessage = message
                scanToastMessage = message
                appendRuntimeLog("[AppState] \(mode.operationName)_guard reason=scope_path_not_found path=\(resolvedRoot.path)")
                await persistLastScan(summary: message)
                return
            }

            rootURL = resolvedRoot
        } catch {
            let nsError = error as NSError
            let message: String
            if nsError.domain == "AccessManager" || nsError.code == 403 {
                message = "需要先授权下载文件夹"
            } else {
                message = formatErrorMessage(error)
            }
            statusMessage = message
            scanToastMessage = message
            appendRuntimeLog("[AppState] \(mode.operationName)_guard reason=permission_or_root_error error=\(message)")
            await persistLastScan(summary: message)
            return
        }

        let timeoutSeconds: TimeInterval = mode == .quick ? 10 : 30
        let currentArchiveWindow = archiveTimeWindow
        let excludedPaths = archiveExcludedPaths
        var phaseAPlan: QuickPlanPhaseAResult?
        isBusy = true
        statusMessage = mode.runningMessage
        scanToastMessage = "扫描中..."
        scanProgressDetail = "正在读取文件列表..."
        appendRuntimeLog("[AppState] \(mode.operationName)_start")
        defer {
            isBusy = false
            scanProgressDetail = ""
        }

        do {
            let quickPlan = try await runBackgroundWithTimeout(
                operationName: "\(mode.operationName)-phase-a",
                timeoutSeconds: 2
            ) {
                try self.runQuickPlanPhaseA(rootURL: rootURL, window: currentArchiveWindow, now: Date())
            }
            phaseAPlan = quickPlan
            applyQuickPlanPhaseAToUI(quickPlan, archiveWindow: currentArchiveWindow, now: Date())
            appendRuntimeLog(
                "[AppState] \(mode.operationName)_phase_a buckets=\(quickPlan.bucketCount(window: currentArchiveWindow)) actionable=\(quickPlan.actionableCount(window: currentArchiveWindow)) scanned=\(quickPlan.scannedFiles)"
            )
            appendRuntimeLog(
                "[AppState] scan_phase_a scope=\(isTestModeEnabled ? "TidyTest" : "Downloads") actionable=\(quickPlan.actionableCount(window: currentArchiveWindow))"
            )
            appendRuntimeLog(
                "[AppState] plan_counts screenshots=\(quickPlan.screenshotsCount) pdfs=\(quickPlan.pdfCount) inbox=\(quickPlan.inboxCount) installers=\(quickPlan.installersCount)"
            )
        } catch {
            appendRuntimeLog("[AppState] \(mode.operationName)_phase_a_failed error=\(error.localizedDescription)")
        }

        scanProgressDetail = "扫描文件中..."
        do {
            let result = try await runExclusiveLongTask(name: mode.operationName, timeoutSeconds: timeoutSeconds) {
                if mode == .full {
                    _ = try self.services.indexer.forceFullScanDownloads(
                        rootURL: rootURL,
                        excludedPaths: excludedPaths
                    )
                } else {
                    _ = try self.services.indexer.scanDownloads(
                        rootURL: rootURL,
                        excludedPaths: excludedPaths
                    )
                }

                Task { @MainActor in self.scanProgressDetail = "检测重复文件..." }
                let report = try self.services.scanner.detectDuplicateGroups(scope: .downloads)
                let isolated = try self.services.actionEngine.autoQuarantineDuplicateGroups(report.verifiedGroups)
                Task { @MainActor in self.scanProgressDetail = "生成整理建议..." }
                try self.services.bundleBuilder.rebuildWeeklyBundles(scope: .downloads, now: Date())

                let pendingBundles = try self.services.store.pendingBundleRawCount(now: Date())
                let noActionReason = try self.buildNoActionReasonIfNeeded(
                    isolatedCount: isolated,
                    bundleCount: pendingBundles,
                    sizeOnlyCandidates: report.sizeOnlyDuplicateCandidates
                )

                return DownloadsScanExecutionResult(
                    isolatedCount: isolated,
                    bundleCount: pendingBundles,
                    sizeOnlyCandidates: report.sizeOnlyDuplicateCandidates,
                    noActionReason: noActionReason
                )
            }

            let summary = scanSummary(
                from: result,
                phaseAPlan: phaseAPlan,
                archiveWindow: currentArchiveWindow
            )
            triggerBackgroundAIAnalysis()
            scanProgressDetail = "AI 分析中..."
            let toast = summary
            statusMessage = toast
            scanToastMessage = toast
            await persistLastScan(summary: summary)
            appendRuntimeLog(
                "[AppState] \(mode.operationName)_refresh_before isolated=\(digest.autoIsolatedCount) organized=\(digest.autoOrganizedCount) pending=\(pendingBundlesCount)"
            )
            await refreshDigestSnapshot(reason: "\(mode.operationName)-success")
            appendRuntimeLog(
                "[AppState] \(mode.operationName)_refresh_after isolated=\(digest.autoIsolatedCount) organized=\(digest.autoOrganizedCount) pending=\(pendingBundlesCount) last_scan=\(lastScanSummary)"
            )

            appendRuntimeLog(
                "[AppState] \(mode.operationName)_end bundles=\(result.bundleCount) isolated=\(result.isolatedCount) size_only=\(result.sizeOnlyCandidates)"
            )
            await logEvent(mode.successEventType, "扫描完成", payload: [
                "bundles": String(result.bundleCount),
                "isolated_count": String(result.isolatedCount),
                "size_only_candidates": String(result.sizeOnlyCandidates)
            ])
        } catch {
            let reason = scanFailureReason(error)
            let partial = await loadCurrentScanDigestCounts()
            let timedOut = isScanTimeoutError(error)
            let phaseABundles = phaseAPlan?.bucketCount(window: currentArchiveWindow) ?? 0
            let phaseAActionable = phaseAPlan?.actionableCount(window: currentArchiveWindow) ?? 0
            let effectiveBundles = max(partial.bundles, phaseABundles)
            let summary = scanFailureSummary(
                reason: reason,
                timedOut: timedOut,
                timeoutSeconds: timeoutSeconds,
                bundles: effectiveBundles,
                isolated: partial.isolated,
                phaseAActionable: phaseAActionable
            )
            let toast = timedOut
                ? "扫描超时（\(Int(timeoutSeconds))秒），显示部分结果：建议 \(effectiveBundles) 条，已隔离 \(partial.isolated) 个"
                : summary
            statusMessage = toast
            scanToastMessage = toast
            await persistLastScan(summary: summary)
            appendRuntimeLog(
                "[AppState] \(mode.operationName)_refresh_before isolated=\(digest.autoIsolatedCount) organized=\(digest.autoOrganizedCount) pending=\(pendingBundlesCount)"
            )
            await refreshDigestSnapshot(reason: "\(mode.operationName)-failure")
            appendRuntimeLog(
                "[AppState] \(mode.operationName)_refresh_after isolated=\(digest.autoIsolatedCount) organized=\(digest.autoOrganizedCount) pending=\(pendingBundlesCount) last_scan=\(lastScanSummary)"
            )

            appendRuntimeLog("[AppState] \(mode.operationName)_failed reason=\(reason)")
            await logEvent(mode.failureEventType, toast, payload: nil)

            if timedOut {
                Task { [weak self] in
                    guard let self else { return }
                    await self.reconcileTimedOutScanSummary(timeoutSeconds: timeoutSeconds)
                }
            }
        }

        await refreshAll(trigger: mode.operationName)
        await loadBundles()
        await loadLargeFiles()
        await loadOldInstallers()
        await loadDuplicateGroups()
        await loadVersionGroups()

        if let phaseAPlan,
           phaseAPlan.actionableCount(window: currentArchiveWindow) > 0,
           recommendedPlanActionableCount == 0 {
            applyQuickPlanPhaseAToUI(phaseAPlan, archiveWindow: currentArchiveWindow, now: Date())
            appendRuntimeLog(
                "[AppState] \(mode.operationName)_phase_a_fallback_applied actionable=\(phaseAPlan.actionableCount(window: currentArchiveWindow))"
            )
        }
    }

    func scanButtonTappedFromHome() {
        let scope = isTestModeEnabled ? "TidyTest" : "Downloads"
        appendRuntimeLog("[UI] scan_clicked scope=\(scope)")
        totalFilesScanned = 0
        scanToastMessage = "扫描中..."
        statusMessage = "扫描中..."
        Task { [weak self] in
            guard let self else { return }
            await self.runAutopilotNow()
            await self.maybeAutoAnalyzeAfterHomeScan()
        }
    }

    func undoLastOperation() async {
        isBusy = true
        defer { isBusy = false }

        do {
            let result = try await runBackground {
                try self.services.actionEngine.undoLastTxn()
            }
            if let result {
                if result.failed > 0 {
                    let message = "撤销完成：成功 \(result.succeeded)，失败 \(result.failed)"
                    statusMessage = message
                    scanToastMessage = message
                    showUndoDetailsAction = true
                    undoFailedTxnID = result.txnId
                } else {
                    statusMessage = result.message
                    scanToastMessage = "撤销完成：已恢复 \(result.succeeded) 个文件"
                    showUndoDetailsAction = false
                    undoFailedTxnID = nil
                }
                appendRuntimeLog("[AppState] undo_counts txn_id=\(result.txnId) success=\(result.succeeded) failed=\(result.failed)")
                await logEvent("undo", "Undo completed", payload: [
                    "txn_id": result.txnId,
                    "succeeded": String(result.succeeded),
                    "failed": String(result.failed)
                ])
            } else {
                statusMessage = "没有可以撤销的操作"
                scanToastMessage = "没有可撤销的操作"
                showUndoDetailsAction = false
                undoFailedTxnID = nil
            }
            await refreshAll(trigger: "undo")
        } catch {
            handleError(error)
        }
    }

    func runRepairNow() async {
        guard !databaseNeedsReset else {
            statusMessage = "数据库需要重置后才能修复"
            return
        }
        isBusy = true
        defer { isBusy = false }

        do {
            let report = try await runBackground {
                let now = Date()
                _ = try self.services.store.markExpiredQuarantineItems(now: now)
                let report = try self.services.consistencyChecker.runRepair(now: now)
                try self.services.store.setStringSetting(
                    key: self.archiveRootHealthKey,
                    value: report.archiveAccess.rawValue
                )
                try self.services.store.setDoubleSetting(
                    key: self.lastRepairAtKey,
                    value: now.timeIntervalSince1970
                )
                return report
            }

            statusMessage = repairCompletionMessage(report: report)
            await logEvent("repair", "Manual repair run", payload: [
                "app_related_missing_originals": String(report.missingOriginals),
                "low_priority_missing_originals": String(report.lowPriorityMissingOriginals),
                "missing_quarantine": String(report.missingQuarantineFiles)
            ])
            await refreshAll(trigger: "repair")
        } catch {
            handleError(error)
        }
    }

    func exportDebugBundle() async {
        guard !databaseNeedsReset else {
            statusMessage = "数据库需要重置后才能导出"
            return
        }

        guard let destinationURL = chooseExportDestination(defaultName: defaultDebugBundleName()) else {
            statusMessage = "导出已取消"
            return
        }

        isBusy = true
        defer { isBusy = false }
        statusMessage = "正在导出调试包..."

        do {
            let start = Date()
            let health = accessHealth
            let exporter = services.debugBundleExporter
            logExportRuntime("[Export] start path=\(destinationURL.path)")
            let url = try await runDetachedWithTimeout(operationName: "export-debug-bundle", timeoutSeconds: 60) {
                try exporter.export(to: destinationURL, now: Date(), accessHealth: health)
            }
            let duration = Date().timeIntervalSince(start)
            statusMessage = "调试包已导出：\(url.path)"
            logExportRuntime("[Export] end success path=\(url.path) duration=\(String(format: "%.2f", duration))")
            await logEvent("debug_export", "Exported debug bundle", payload: ["path": url.lastPathComponent])
        } catch {
            let message = formatExportError(error)
            statusMessage = "导出失败：\(message)"
            logExportRuntime("[Export] end failed error=\(message)")
            await logEvent("debug_export_failed", message, payload: nil)
        }
    }

    func reportIssue() async {
        do {
            let reportText = try await buildIssueReportText()
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(reportText, forType: .string)
            statusMessage = "问题模板已复制到剪贴板"
            await logEvent("issue_report", "Copied issue template", payload: nil)
        } catch {
            handleError(error)
        }
    }

    func resetDatabase() async {
        isBusy = true
        defer { isBusy = false }

        do {
            try await runBackground {
                try self.services.store.resetDatabase()
            }
            databaseNeedsReset = false
            statusMessage = "数据库已重置完成"
            await logEvent("db_reset", "Database reset by user", payload: nil)
            await refreshAll(trigger: "db-reset")
        } catch {
            handleError(error)
        }
    }

    // MARK: - Authorization / Access

    func requestAccess(for target: AccessTarget) async {
        switch target {
        case .downloads:
            await requestDownloadsAuthorization()
        case .desktop:
            await requestDesktopAuthorization()
        case .documents:
            await requestDocumentsAuthorization()
        case .archiveRoot:
            await reauthorizeArchiveRoot()
        }
    }

    func requestDownloadsAuthorization() async {
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            statusMessage = "无法访问下载文件夹"
            return
        }

        guard let selected = chooseFolder(
            message: "重新授权下载文件夹",
            prompt: "选择 Downloads 文件夹",
            defaultURL: downloads
        ) else { return }

        do {
            try await runBackground {
                try self.services.accessManager.saveDownloadsBookmark(url: selected)
            }
            statusMessage = "下载文件夹已授权"
            await logEvent("access", "Downloads authorized", payload: nil)
            await refreshAccessHealth()
            await ensureFirstRunResultsIfNeeded(force: false)
            await startWatcherIfPossible()
            await refreshAll(trigger: "authorize-downloads")
        } catch {
            handleError(error)
        }
    }

    func requestDesktopAuthorization() async {
        guard let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first else {
            statusMessage = "无法访问桌面文件夹"
            return
        }

        guard let selected = chooseFolder(
            message: "启用桌面监控",
            prompt: "选择 Desktop 文件夹",
            defaultURL: desktop
        ) else { return }

        do {
            try await runBackground {
                try self.services.accessManager.saveDesktopBookmark(url: selected)
            }
            statusMessage = "桌面扫描已启用"
            await logEvent("access", "Desktop authorized", payload: nil)
            await refreshAccessHealth()
            await runIncrementalResyncForAuthorizedScopes(reason: "desktop-enabled")
            await startWatcherIfPossible()
            await refreshAll(trigger: "authorize-desktop")
        } catch {
            handleError(error)
        }
    }

    func requestDocumentsAuthorization() async {
        let defaultURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first

        guard let selected = chooseFolder(
            message: "启用文稿监控，请选择 Documents 文件夹",
            prompt: "选择 Documents 文件夹",
            defaultURL: defaultURL
        ) else { return }

        do {
            try await runBackground {
                try self.services.accessManager.saveDocumentsBookmark(url: selected)
            }
            statusMessage = "文稿扫描已启用"
            await logEvent("access", "Documents authorized", payload: nil)
            await refreshAccessHealth()
            await runIncrementalResyncForAuthorizedScopes(reason: "documents-enabled")
            await startWatcherIfPossible()
            await refreshAll(trigger: "authorize-documents")
        } catch {
            handleError(error)
        }
    }

    func reauthorizeArchiveRoot() async {
        guard let selected = chooseFolder(
            message: "选择整理文件夹",
            prompt: "使用此文件夹",
            defaultURL: nil
        ) else { return }

        await saveDefaultArchiveRoot(url: selected)
    }

    func chooseArchiveRoot() {
        Task { [weak self] in
            await self?.reauthorizeArchiveRoot()
        }
    }

    func installLaunchAgent() throws {
        let plistName = "com.tidy2.dailyscan.plist"
        let launchAgentsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
        let destination = launchAgentsDir.appendingPathComponent(plistName)

        guard !FileManager.default.fileExists(atPath: destination.path) else { return }

        let execPath = Bundle.main.executablePath ?? ""
        let plist: [String: Any] = [
            "Label": "com.tidy2.dailyscan",
            "ProgramArguments": [execPath, "--background-scan"],
            "StartCalendarInterval": [["Hour": 9, "Minute": 0]],
            "RunAtLoad": false,
            "StandardOutPath": NSHomeDirectory() + "/Library/Logs/Tidy2-bg.log",
            "StandardErrorPath": NSHomeDirectory() + "/Library/Logs/Tidy2-bg.log"
        ]

        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try FileManager.default.createDirectory(
            at: launchAgentsDir,
            withIntermediateDirectories: true
        )
        try data.write(to: destination)
    }

    /// Creates ~/Documents/Tidy Archive/ and activates it — no user interaction needed.
    func setupDefaultArchiveRoot() async {
        let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Tidy Archive", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: defaultRoot, withIntermediateDirectories: true)
        } catch {
            handleError(error)
            return
        }
        // saveDefaultArchiveRoot uses a bookmark; for the default path we go through
        // the open panel pre-filled to that location so the security scope is granted.
        guard let selected = chooseFolder(
            message: "确认整理文件夹位置",
            prompt: "使用此文件夹",
            defaultURL: defaultRoot
        ) else { return }
        await saveDefaultArchiveRoot(url: selected)
    }

    func saveDefaultArchiveRoot(url: URL) async {
        do {
            archiveRootPath = url.path
            try await runBackground {
                try self.services.accessManager.saveArchiveRootBookmark(url: url)
            }
            statusMessage = "归档目标文件夹已更新"
            await logEvent("access", "Archive root authorized", payload: nil)
            await refreshAccessHealth()
            await refreshAll(trigger: "archive-root-updated")
        } catch {
            handleError(error)
        }
    }

    func runBackgroundScanAndAutoApply() async {
        await runAutopilotNow()
        await loadBundles()
        let lowRiskBundles = bundles.filter { $0.risk == .low }
        var appliedCount = 0
        for bundle in lowRiskBundles {
            let ok = await applyBundle(bundleID: bundle.id, override: nil)
            if ok {
                appliedCount += 1
            }
        }
        await loadBundles()
        let remaining = bundles.count
        sendScanCompletionNotification(applied: appliedCount, remaining: remaining)
    }

    // MARK: - Bundle actions

    @discardableResult
    func applyBundle(bundleID: String, override: BundleApplyOverride?) async -> Bool {
        isBusy = true
        defer { isBusy = false }
        statusMessage = "正在执行整理建议..."

        appendRuntimeLog(
            "[AppState] apply_requested bundle_id=\(bundleID) override_action=\(override?.actionKind?.rawValue ?? "nil")"
        )

        var appliedSuccessfully = false

        do {
            let result = try await runExclusiveLongTask(name: "apply-bundle:\(bundleID)", timeoutSeconds: 60) {
                try self.services.actionEngine.applyBundle(bundleID: bundleID, override: override)
            }

            if result.succeeded == 0 {
                let reason = result.firstError?.trimmingCharacters(in: .whitespacesAndNewlines)
                let message = "整理失败：\(reason ?? "没有成功执行任何文件操作。")"
                statusMessage = message
                appendRuntimeLog(
                    "[AppState] apply_failed bundle_id=\(bundleID) txn_id=\(result.txnId) reason=\(message)"
                )
                await logEvent("bundle_apply_failed", message, payload: [
                    "bundle_id": bundleID,
                    "txn_id": result.txnId,
                    "succeeded": "0",
                    "failed": String(result.failed),
                    "skipped_missing": String(result.skippedMissing)
                ])
                appliedSuccessfully = false
                await refreshAll(trigger: "bundle-apply")
                return appliedSuccessfully
            }

            let baseMessage: String
            if result.movedCount > 0 {
                baseMessage = "已执行整理建议：移动了 \(result.movedCount) 个文件"
            } else if result.renamedCount > 0 {
                baseMessage = "已执行整理建议：重命名了 \(result.renamedCount) 个文件"
            } else if result.quarantinedCount > 0 {
                baseMessage = "已执行整理建议：隔离了 \(result.quarantinedCount) 个文件"
            } else {
                baseMessage = "整理完成，但没有成功执行任何文件操作"
            }

            var message = baseMessage
            if result.skippedMissing > 0 {
                message += "（已跳过 \(result.skippedMissing) 个缺失文件）"
            }
            if result.failed > 0 {
                let nonMissingFailures = max(0, result.failed - result.skippedMissing)
                if nonMissingFailures > 0 {
                    message += "，\(nonMissingFailures) 个失败"
                }
            }
            if result.skippedByRiskPolicy > 0 {
                message += "，\(result.skippedByRiskPolicy) 个因风险策略跳过"
            }
            if let firstError = result.firstError,
               max(0, result.failed - result.skippedMissing) > 0 {
                message += "。首个错误：\(firstError)"
            }
            if let destination = result.destinationHint {
                message += "。\(destination)"
            }
            statusMessage = message
            appendRuntimeLog(
                "[AppState] apply_succeeded bundle_id=\(bundleID) txn_id=\(result.txnId) moved=\(result.movedCount) renamed=\(result.renamedCount) quarantined=\(result.quarantinedCount) journal_rows=\(result.journalCount) failed=\(result.failed)"
            )
            await logEvent("bundle_apply", "Bundle applied", payload: [
                "bundle_id": bundleID,
                "txn_id": result.txnId,
                "succeeded": String(result.succeeded),
                "failed": String(result.failed),
                "skipped_missing": String(result.skippedMissing),
                "moved": String(result.movedCount),
                "renamed": String(result.renamedCount),
                "quarantined": String(result.quarantinedCount),
                "journal_rows": String(result.journalCount)
            ])
            appliedSuccessfully = true
        } catch {
            let message = formatErrorMessage(error)
            let visible = "执行失败：\(message)"
            statusMessage = visible
            appendRuntimeLog("[AppState] apply_failed bundle_id=\(bundleID) error=\(message)")
            await logEvent("bundle_apply_failed", visible, payload: ["bundle_id": bundleID])
        }

        await refreshAll(trigger: "bundle-apply")
        return appliedSuccessfully
    }

    func skipBundleToNextWeek(bundleID: String) async {
        do {
            let until = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
            try await runBackground {
                try self.services.store.snoozeBundle(id: bundleID, until: until)
            }
            statusMessage = "整理建议已推迟到下周"
            await logEvent("bundle_skip", "Bundle snoozed", payload: ["bundle_id": bundleID])
            await refreshAll(trigger: "bundle-skip")
        } catch {
            handleError(error)
        }
    }

    func refreshBundle(bundleID: String) async {
        guard let bundle = bundle(by: bundleID) else {
            statusMessage = "整理建议不存在"
            return
        }
        guard let scope = inferScope(for: bundle) else {
            statusMessage = "无法确定文件范围，请重新扫描"
            return
        }
        let preRefreshExistingCount = bundle.filePaths.reduce(into: 0) { count, path in
            if FileManager.default.fileExists(atPath: path) {
                count += 1
            }
        }

        isBusy = true
        defer { isBusy = false }
        statusMessage = "正在刷新整理建议..."

        do {
            let excludedPaths = archiveExcludedPaths
            let refreshResult = try await runExclusiveLongTask(name: "refresh-bundle:\(bundleID)", timeoutSeconds: 60) {
                guard let rootURL = try self.resolveRootURL(scope: scope) else {
                    throw self.services.accessManager.makeAccessError(
                        target: scope == .downloads ? .downloads : .desktop,
                        reason: "刷新整理建议时缺少对应范围的访问权限。",
                        fallbackStatus: .missing
                    )
                }
                _ = try self.services.indexer.reindex(
                    scope: scope,
                    rootURL: rootURL,
                    changedDirectories: [rootURL],
                    excludedPaths: excludedPaths
                )
                try self.services.bundleBuilder.rebuildWeeklyBundles(scope: scope, now: Date())
                let refreshed = try self.services.store.loadBundle(id: bundleID)
                return (exists: refreshed != nil, fileCount: refreshed?.filePaths.count ?? 0)
            }
            triggerBackgroundAIAnalysis()
            if refreshResult.exists {
                statusMessage = "整理建议已刷新"
            } else if preRefreshExistingCount == 0 {
                statusMessage = "所有文件均已不存在，已移除该建议"
            } else {
                statusMessage = "已刷新：当前没有可操作的文件"
            }
            await logEvent("bundle_refresh", "Bundle refreshed", payload: [
                "bundle_id": bundleID,
                "scope": scope.rawValue,
                "exists_after_refresh": refreshResult.exists ? "1" : "0",
                "pre_existing_count": String(preRefreshExistingCount)
            ])
            await refreshAll(trigger: "bundle-refresh")
        } catch {
            handleError(error)
        }
    }

    func refreshBundleMissingCount(bundleID: String) async {
        guard let bundle = bundle(by: bundleID) else { return }
        let paths = bundle.filePaths
        do {
            let missing = try await runBackground {
                let fm = FileManager.default
                return paths.reduce(into: 0) { count, path in
                    if !fm.fileExists(atPath: path) {
                        count += 1
                    }
                }
            }
            bundleMissingCounts[bundleID] = missing
        } catch {
            handleError(error)
        }
    }

    // MARK: - Quarantine actions

    func restoreFromQuarantine(_ item: QuarantineItem) async {
        isBusy = true
        defer { isBusy = false }

        do {
            try await runBackground {
                try self.services.actionEngine.restore(quarantineItemID: item.id)
            }
            statusMessage = "已恢复：\(URL(fileURLWithPath: item.originalPath).lastPathComponent)"
            await logEvent("restore", "Restored quarantine item", payload: ["item_id": item.id])
            await refreshAll(trigger: "restore")
            await refreshQuarantineItems()
        } catch {
            handleError(error)
        }
    }

    func setQuarantineFilter(_ filter: QuarantineListFilter) {
        quarantineFilter = filter
        Task {
            await refreshQuarantineItems()
        }
    }

    func setAutoPurgeExpiredQuarantine(_ enabled: Bool) async {
        do {
            try await runBackground {
                try self.services.store.setStringSetting(
                    key: self.autoPurgeSettingKey,
                    value: enabled ? "1" : "0"
                )
            }
            autoPurgeExpiredQuarantine = enabled
            statusMessage = enabled ? "已开启自动清理（每周）。" : "已关闭自动清理。"
            await logEvent("setting", "Updated auto purge setting", payload: ["enabled": enabled ? "1" : "0"])
            await refreshAll(trigger: "toggle-auto-purge")
        } catch {
            handleError(error)
        }
    }

    func purgeExpiredQuarantine(manual: Bool) async {
        isBusy = true
        defer { isBusy = false }

        do {
            let result = try await runBackground {
                try self.services.actionEngine.purgeExpiredQuarantine(actor: manual ? "user" : "system")
            }
            statusMessage = "已清理 \(result.purged)/\(result.attempted) 个过期文件，释放了 \(SizeFormatter.string(from: result.freedBytes))"
            await logEvent("purge", "Purged expired quarantine", payload: [
                "txn_id": result.txnId,
                "purged": String(result.purged),
                "failed": String(result.failed)
            ])
            if !manual {
                try await runBackground {
                    try self.services.store.setDoubleSetting(
                        key: self.lastAutoPurgeAtKey,
                        value: Date().timeIntervalSince1970
                    )
                }
            }
            await refreshAll(trigger: "purge-expired")
            await refreshQuarantineItems()
        } catch {
            handleError(error)
        }
    }

    func purgeSafeCleanupQuarantine() async {
        isBusy = true
        defer { isBusy = false }

        do {
            let result = try await runBackground {
                try self.services.actionEngine.purgeSafeCleanupQuarantine(actor: "user")
            }
            statusMessage = "已安全清理 \(result.purged)/\(result.attempted) 项，释放 \(SizeFormatter.string(from: result.freedBytes))."
            await logEvent("purge_safe_cleanup", "Purged safe cleanup quarantine", payload: [
                "txn_id": result.txnId,
                "purged": String(result.purged),
                "failed": String(result.failed)
            ])
            await refreshAll(trigger: "purge-safe-cleanup")
            await refreshQuarantineItems()
        } catch {
            handleError(error)
        }
    }

    // MARK: - Search

    func parseSearch() {
        parsedFilters = SearchParser.parse(queryText, now: Date())
    }

    func executeSearch() {
        Task {
            do {
                var filters = parsedFilters
                filters.archiveRootPath = archiveRootPath
                let startedAt = Date()
                let payload = try await runBackground {
                    if !filters.keywords.isEmpty {
                        if filters.location == nil || filters.location == .downloads {
                            _ = try self.services.indexer.backfillPDFTextIndex(scope: .downloads, limit: 24)
                        }
                        if filters.location == .desktop {
                            _ = try self.services.indexer.backfillPDFTextIndex(scope: .desktop, limit: 16)
                        }
                    }
                    let results = try self.services.store.queryFiles(filters: filters, limit: 200)
                    let intelMap = try self.services.store.fileIntelligenceMap(for: results.map(\.path))
                    return (results: results, intelMap: intelMap)
                }
                searchResults = payload.results
                searchResultIntelMap = payload.intelMap
                let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
                statusMessage = "找到 \(payload.results.count) 个文件"
                appendRuntimeLog("[Search] query keywords=\(filters.keywords.joined(separator: ",")) count=\(payload.results.count) duration_ms=\(durationMs)")
            } catch {
                handleError(error)
            }
        }
    }

    // MARK: - Evidence / Finder

    func revealEvidence(_ item: EvidenceItem) {
        if let ruleID = item.supportingRuleID {
            focusedRuleID = ruleID
            openRules()
            Task {
                await previewRuleImpact(ruleID: ruleID)
            }
            return
        }

        guard let fileID = item.supportingFileIDs?.first else {
            statusMessage = "无法找到该文件的来源路径"
            return
        }

        Task {
            do {
                let path = try await runBackground {
                    try self.services.store.filePath(fileID: fileID)
                }
                guard let path else {
                    statusMessage = "该文件已不在扫描记录中"
                    return
                }
                revealInFinder(path: path)
            } catch {
                handleError(error)
            }
        }
    }

    func revealInFinder(path: String) {
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Rules

    func setRuleEnabled(ruleID: String, isEnabled: Bool) async {
        do {
            try await runBackground {
                try self.services.store.setRuleEnabled(id: ruleID, isEnabled: isEnabled)
            }
            if ruleNudge?.ruleID == ruleID, !isEnabled {
                ruleNudge = nil
            }
            await runIncrementalResyncForAuthorizedScopes(reason: "rule-toggle")
            await refreshAll(trigger: "rule-toggle")
        } catch {
            handleError(error)
        }
    }

    func deleteRule(ruleID: String) async {
        do {
            try await runBackground {
                try self.services.store.deleteRule(id: ruleID)
            }
            if focusedRuleID == ruleID {
                focusedRuleID = nil
            }
            if selectedRulePreviewRuleID == ruleID {
                selectedRulePreviewRuleID = nil
                rulePreviewItems = []
            }
            if ruleNudge?.ruleID == ruleID {
                ruleNudge = nil
            }
            await runIncrementalResyncForAuthorizedScopes(reason: "rule-delete")
            await refreshAll(trigger: "rule-delete")
        } catch {
            handleError(error)
        }
    }

    func updateRuleTargetFolder(ruleID: String, url: URL) async {
        do {
            let bookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )

            try await runBackground {
                try self.services.store.updateRuleTargetFolder(id: ruleID, bookmark: bookmark)
            }
            await runIncrementalResyncForAuthorizedScopes(reason: "rule-target-update")
            await refreshAll(trigger: "rule-target-update")
        } catch {
            handleError(error)
        }
    }

    func previewRuleImpact(ruleID: String) async {
        selectedRulePreviewRuleID = ruleID
        isRulePreviewLoading = true
        defer { isRulePreviewLoading = false }

        do {
            let preview = try await runBackground {
                try self.services.store.dryRunPendingBundles(ruleID: ruleID, now: Date(), limit: 5)
            }
            rulePreviewItems = preview
        } catch {
            handleError(error)
        }
    }

    func clearRulePreview() {
        selectedRulePreviewRuleID = nil
        rulePreviewItems = []
    }

    func setRulesEmergencyBrake(_ enabled: Bool) async {
        do {
            try await runBackground {
                try self.services.store.setStringSetting(
                    key: self.rulesEmergencyBrakeKey,
                    value: enabled ? "1" : "0"
                )
            }
            rulesEmergencyBrake = enabled
            statusMessage = enabled ? "紧急制动已开启：规则已暂停。" : "紧急制动已关闭：规则恢复生效。"
            await logEvent("setting", "Updated rules emergency brake", payload: ["enabled": enabled ? "1" : "0"])
            await runIncrementalResyncForAuthorizedScopes(reason: "rules-emergency-brake")
            await refreshAll(trigger: "rules-emergency-brake")
        } catch {
            handleError(error)
        }
    }

    func disableRuleFromNudge(ruleID: String) async {
        await setRuleEnabled(ruleID: ruleID, isEnabled: false)
        ruleNudge = nil
    }

    func dismissRuleNudge() {
        ruleNudge = nil
    }

    // MARK: - Internal refresh pipeline

    private func refreshAll(trigger: String) async {
        await ensureDatabaseReady()
        if databaseNeedsReset {
            return
        }
        // Reconcile: any file physically inside the archive root must be marked
        // archived in the DB, regardless of how it got there. This prevents
        // moved files from re-appearing in bundles or AI suggestions.
        if !archiveRootPath.isEmpty {
            let root = archiveRootPath
            try? await runBackground {
                try self.services.store.reconcileArchivedByPath(archiveRootPath: root)
            }
        }
        await ensureDefaultSettings()
        await refreshAccessHealth()
        await runSilentMaintenanceIfDue(force: false)
        await maybeAutoPurgeExpired()
        await refreshDashboard()
        await refreshNudges()
        await updateOnboardingState()
        if trigger == "bootstrap", !needsDownloadsAuthorization {
            await ensureFirstRunResultsIfNeeded(force: false)
            await runIncrementalResyncForAuthorizedScopes(reason: "startup")
            await startWatcherIfPossible()
            await refreshDashboard()
        }
    }

    private func ensureDatabaseReady() async {
        do {
            try await runBackground {
                try self.services.store.ensureReady()
            }
            databaseNeedsReset = false
        } catch {
            databaseNeedsReset = true
            handleError(error)
        }
    }

    private func ensureDefaultSettings() async {
        do {
            try await runBackground {
                if (try self.services.store.stringSetting(key: self.stormThresholdKey)) == nil {
                    try self.services.store.setStringSetting(
                        key: self.stormThresholdKey,
                        value: String(self.defaultStormThreshold)
                    )
                }
                if (try self.services.store.stringSetting(key: self.testModeSettingKey)) == nil {
                    try self.services.store.setStringSetting(key: self.testModeSettingKey, value: "0")
                }
                if (try self.services.store.stringSetting(key: self.archiveTimeWindowSettingKey)) == nil {
                    try self.services.store.setStringSetting(
                        key: self.archiveTimeWindowSettingKey,
                        value: ArchiveTimeWindow.all.rawValue
                    )
                }
                if (try self.services.store.stringSetting(key: self.rulesEmergencyBrakeKey)) == nil {
                    try self.services.store.setStringSetting(key: self.rulesEmergencyBrakeKey, value: "0")
                }
                if (try self.services.store.stringSetting(key: self.autoPurgeSettingKey)) == nil {
                    try self.services.store.setStringSetting(key: self.autoPurgeSettingKey, value: "0")
                }
            }
        } catch {
            handleError(error)
        }
    }

    private func refreshDashboard() async {
        do {
            let filter = quarantineFilter
            let beforeDigest = digest
            let snapshot = try await runBackground {
                _ = try self.services.store.markExpiredQuarantineItems(now: Date())

                let digest = try self.services.digestService.weeklySummary(now: Date())
                try self.services.metricsStore.captureWeeklySnapshot(now: Date(), pendingBundles: digest.needsDecisionCount)
                let bundles = try self.services.bundleBuilder.pendingBundles(limit: 50)
                let fm = FileManager.default
                let missingCounts = Dictionary(uniqueKeysWithValues: bundles.map { bundle in
                    let missing = bundle.filePaths.reduce(into: 0) { count, path in
                        if !fm.fileExists(atPath: path) {
                            count += 1
                        }
                    }
                    return (bundle.id, missing)
                })
                let quarantine = try self.services.quarantineService.listItems(filter: filter)
                let changes = try self.services.store.recentChangeLog(limit: 5)
                let metrics = try self.services.metricsStore.recentWeeklyMetrics(limit: 4)
                let rules = try self.services.store.listRules().sorted { $0.updatedAt > $1.updatedAt }
                let autoPurgeRaw = try self.services.store.stringSetting(key: self.autoPurgeSettingKey) ?? "0"
                let emergencyRaw = try self.services.store.stringSetting(key: self.rulesEmergencyBrakeKey) ?? "0"
                let testModeRaw = try self.services.store.stringSetting(key: self.testModeSettingKey) ?? "0"
                let archiveWindowRaw = try self.services.store.stringSetting(key: self.archiveTimeWindowSettingKey) ?? ArchiveTimeWindow.all.rawValue
                let testModeEnabled = Self.parseBool(testModeRaw)
                let archiveWindow = ArchiveTimeWindow(rawValue: archiveWindowRaw) ?? .all
                let aiAnalyzedFilesCount = try self.services.store.countAnalyzedFiles()
                let thresholdRaw = try self.services.store.stringSetting(key: self.stormThresholdKey)
                let thresholdValue = Int(thresholdRaw ?? "") ?? self.defaultStormThreshold
                let lastScanSummary = try self.services.store.stringSetting(key: self.lastScanSummaryKey) ?? "尚未扫描"
                let lastScanAt = try self.services.store.doubleSetting(key: self.lastScanAtKey)
                let downloadsFiles = try self.services.store.listFiles(scope: .downloads)
                let scopedDownloads = Self.filterDownloadsFiles(files: downloadsFiles, testModeEnabled: testModeEnabled)
                let dismissedRaw = try self.services.store.stringSetting(key: self.pendingInboxDismissedKey)
                let dismissedMap = Self.decodePendingInboxDismissed(raw: dismissedRaw)
                let installerReview = Self.makePendingInboxCandidates(
                    from: scopedDownloads,
                    now: Date(),
                    dismissedMap: dismissedMap
                )
                let lastProcessedAt = try self.services.store.doubleSetting(key: self.lastProcessedAtKey) ?? 0
                let newFilesCount = Self.countNewRecommendedFiles(
                    files: scopedDownloads,
                    lastProcessedAt: lastProcessedAt,
                    now: Date()
                )
                let safeCleanupCount = try self.services.store.safeCleanupQuarantineCount()
                let hasArchivedAtLeastOnce = lastProcessedAt > 0
                let nowTs = Date().timeIntervalSince1970
                let lastHintAt = try self.services.store.doubleSetting(key: self.lastInboxHintAtKey) ?? 0
                let didRaiseToday = nowTs - lastHintAt < 24 * 60 * 60
                let shouldRaiseHint = newFilesCount > 0 && !didRaiseToday
                if shouldRaiseHint {
                    try self.services.store.setDoubleSetting(key: self.lastInboxHintAtKey, value: nowTs)
                }
                let shouldShowHint = newFilesCount > 0 && (shouldRaiseHint || didRaiseToday)

                return DashboardSnapshot(
                    digest: digest,
                    bundles: bundles,
                    bundleMissingCounts: missingCounts,
                    quarantineItems: quarantine,
                    changeLog: changes,
                    metrics: metrics,
                    rules: rules,
                    autoPurgeEnabled: Self.parseBool(autoPurgeRaw),
                    emergencyBrakeEnabled: Self.parseBool(emergencyRaw),
                    testModeEnabled: testModeEnabled,
                    archiveTimeWindow: archiveWindow,
                    aiAnalyzedFilesCount: aiAnalyzedFilesCount,
                    newFilesToArchiveCount: newFilesCount,
                    showNewFilesHint: shouldShowHint,
                    installerReviewCandidates: installerReview,
                    pendingInboxCount: installerReview.count,
                    safeCleanupQuarantineCount: safeCleanupCount,
                    stormThreshold: thresholdValue,
                    lastScanSummary: lastScanSummary,
                    lastScanAt: lastScanAt.map { Date(timeIntervalSince1970: $0) },
                    hasArchivedAtLeastOnce: hasArchivedAtLeastOnce
                )
            }

            digest = snapshot.digest
            pendingBundlesCount = snapshot.digest.needsDecisionCount
            bundles = snapshot.bundles
            bundleMissingCounts = snapshot.bundleMissingCounts
            let planBuckets = buildRecommendedPlanBuckets(
                bundles: snapshot.bundles,
                missingCounts: snapshot.bundleMissingCounts,
                archiveRootPath: archiveRootPath,
                archiveTimeWindow: snapshot.archiveTimeWindow,
                now: Date()
            )
            recommendedPlanBuckets = planBuckets
            recommendedPlanActionableCount = planBuckets.reduce(0) { $0 + $1.actionableFiles }
            quarantineItems = snapshot.quarantineItems
            changeLogEntries = snapshot.changeLog
            metricsRows = snapshot.metrics
            rules = snapshot.rules
            autoPurgeExpiredQuarantine = snapshot.autoPurgeEnabled
            rulesEmergencyBrake = snapshot.emergencyBrakeEnabled
            isTestModeEnabled = snapshot.testModeEnabled
            archiveTimeWindow = snapshot.archiveTimeWindow
            aiAnalyzedFilesCount = snapshot.aiAnalyzedFilesCount
            newFilesToArchiveCount = snapshot.newFilesToArchiveCount
            showNewFilesHint = snapshot.showNewFilesHint
            installerReviewCandidates = snapshot.installerReviewCandidates
            pendingInboxCount = snapshot.pendingInboxCount
            safeCleanupQuarantineCount = snapshot.safeCleanupQuarantineCount
            stormThreshold = snapshot.stormThreshold
            lastScanSummary = snapshot.lastScanSummary
            lastScanAt = snapshot.lastScanAt
            hasArchivedAtLeastOnce = snapshot.hasArchivedAtLeastOnce
            appendRuntimeLog(
                "[AppState] digest_refresh before(isolated=\(beforeDigest.autoIsolatedCount), organized=\(beforeDigest.autoOrganizedCount), pending=\(beforeDigest.needsDecisionCount)) after(isolated=\(snapshot.digest.autoIsolatedCount), organized=\(snapshot.digest.autoOrganizedCount), pending=\(snapshot.digest.needsDecisionCount))"
            )
        } catch {
            handleError(error)
        }
    }

    private func refreshDigestSnapshot(reason: String) async {
        do {
            let beforeDigest = digest
            let snapshot = try await runBackground {
                let now = Date()
                let digest = try self.services.digestService.weeklySummary(now: now)
                let lastScanSummary = try self.services.store.stringSetting(key: self.lastScanSummaryKey) ?? "尚未扫描"
                let lastScanAt = try self.services.store.doubleSetting(key: self.lastScanAtKey)
                return (
                    digest: digest,
                    lastScanSummary: lastScanSummary,
                    lastScanAt: lastScanAt.map { Date(timeIntervalSince1970: $0) }
                )
            }

            digest = snapshot.digest
            pendingBundlesCount = snapshot.digest.needsDecisionCount
            lastScanSummary = snapshot.lastScanSummary
            lastScanAt = snapshot.lastScanAt

            appendRuntimeLog(
                "[AppState] digest_snapshot_refresh reason=\(reason) before(isolated=\(beforeDigest.autoIsolatedCount), organized=\(beforeDigest.autoOrganizedCount), pending=\(beforeDigest.needsDecisionCount)) after(isolated=\(snapshot.digest.autoIsolatedCount), organized=\(snapshot.digest.autoOrganizedCount), pending=\(snapshot.digest.needsDecisionCount))"
            )
        } catch {
            handleError(error)
        }
    }

    private func refreshQuarantineItems() async {
        do {
            let filter = quarantineFilter
            let items = try await runBackground {
                try self.services.quarantineService.listItems(filter: filter)
            }
            quarantineItems = items
        } catch {
            handleError(error)
        }
    }

    private func refreshAccessHealth() async {
        do {
            let items = try await runBackground {
                try self.services.accessManager.healthSnapshot()
            }

            var map: [AccessTarget: AccessHealthItem] = [:]
            for item in items {
                map[item.target] = item
            }
            accessHealth = map

            let downloadsItem = map[.downloads]
            needsDownloadsAuthorization = downloadsItem?.status != .ok
            downloadsFolderPath = downloadsItem?.path ?? ""

            let desktopItem = map[.desktop]
            desktopFolderPath = desktopItem?.path ?? ""

            let documentsItem = map[.documents]
            documentsFolderPath = documentsItem?.path ?? ""

            let archiveItem = map[.archiveRoot]
            archiveRootPath = archiveItem?.path ?? ""

            let archiveStatusRaw = archiveItem?.status.rawValue ?? AccessHealthStatus.missing.rawValue
            try await runBackground {
                try self.services.store.setStringSetting(key: self.archiveRootHealthKey, value: archiveStatusRaw)
            }
        } catch {
            handleError(error)
        }
    }

    private func refreshNudges() async {
        await refreshDecisionNudge()
        await refreshRuleNudge()
    }

    private func refreshDecisionNudge() async {
        if digest.needsDecisionCount <= 0 {
            digestNudgeText = nil
            return
        }

        if digestNudgeText != nil {
            return
        }

        do {
            let last = try await runBackground {
                try self.services.store.doubleSetting(key: self.lastNudgeAtKey) ?? 0
            }

            let now = Date().timeIntervalSince1970
            if now - last >= 24 * 60 * 60 {
                digestNudgeText = "你有 \(digest.needsDecisionCount) 条待确认建议，尽快处理可以减少每周确认次数。"
                try await runBackground {
                    try self.services.store.setDoubleSetting(key: self.lastNudgeAtKey, value: now)
                }
            }
        } catch {
            handleError(error)
        }
    }

    private func refreshRuleNudge() async {
        if ruleNudge != nil {
            return
        }

        do {
            let now = Date()
            let last = try await runBackground {
                try self.services.store.doubleSetting(key: self.lastRuleNudgeAtKey) ?? 0
            }
            guard let latestRule = try await runBackground({
                try self.services.store.latestRuleUpdatedAfter(timestamp: last)
            }) else { return }

            let actionSummary: String
            switch latestRule.action.actionKind {
            case .move:
                actionSummary = "移动"
            case .rename:
                actionSummary = "重命名"
            case .quarantine:
                actionSummary = "隔离"
            }
            ruleNudge = RuleNudge(
                id: latestRule.id + "-nudge",
                ruleID: latestRule.id,
                text: "已学习新规则：\(latestRule.name) → \(actionSummary)"
            )

            try await runBackground {
                try self.services.store.setDoubleSetting(
                    key: self.lastRuleNudgeAtKey,
                    value: now.timeIntervalSince1970
                )
            }
        } catch {
            handleError(error)
        }
    }

    private func runSilentMaintenanceIfDue(force: Bool) async {
        do {
            let shouldRun = try await runBackground {
                let now = Date().timeIntervalSince1970
                let last = try self.services.store.doubleSetting(key: self.lastRepairAtKey) ?? 0
                if force { return true }
                return now - last >= 24 * 60 * 60
            }
            guard shouldRun else { return }

            let report = try await runBackground {
                let now = Date()
                _ = try self.services.store.markExpiredQuarantineItems(now: now)
                let report = try self.services.consistencyChecker.runRepair(now: now)
                try self.services.store.setStringSetting(
                    key: self.archiveRootHealthKey,
                    value: report.archiveAccess.rawValue
                )
                try self.services.store.setDoubleSetting(
                    key: self.lastRepairAtKey,
                    value: now.timeIntervalSince1970
                )
                return report
            }

            if force {
                statusMessage = repairCompletionMessage(report: report)
            }
        } catch {
            handleError(error)
        }
    }

    private func maybeAutoPurgeExpired() async {
        do {
            let now = Date()
            let shouldPurge = try await runBackground {
                let enabledRaw = try self.services.store.stringSetting(key: self.autoPurgeSettingKey) ?? "0"
                guard Self.parseBool(enabledRaw) else { return false }
                let last = try self.services.store.doubleSetting(key: self.lastAutoPurgeAtKey) ?? 0
                return now.timeIntervalSince1970 - last >= 7 * 24 * 60 * 60
            }

            guard shouldPurge else { return }

            _ = try await runBackground {
                let result = try self.services.actionEngine.purgeExpiredQuarantine(actor: "system")
                try self.services.store.setDoubleSetting(
                    key: self.lastAutoPurgeAtKey,
                    value: now.timeIntervalSince1970
                )
                return result
            }
        } catch {
            handleError(error)
        }
    }

    private func ensureFirstRunResultsIfNeeded(force: Bool) async {
        do {
            let shouldRun = try await runBackground {
                let onboardingDone = (try self.services.store.stringSetting(key: self.onboardingCompletedKey) ?? "0") == "1"
                guard onboardingDone else { return false }
                if force { return true }
                let seedDone = (try self.services.store.stringSetting(key: self.initialSeedDoneKey) ?? "0") == "1"
                return !seedDone
            }

            guard shouldRun else { return }
            guard !needsDownloadsAuthorization else { return }

            isBusy = true
            defer { isBusy = false }

            let result = try await runBackground {
                guard let downloadsURL = try self.resolveRootURL(scope: .downloads) else {
                    throw self.services.accessManager.makeAccessError(
                        target: .downloads,
                        reason: "首次扫描需要先授权下载文件夹。",
                        fallbackStatus: .missing
                    )
                }
                let excluded = self.archiveRootPath.isEmpty
                    ? []
                    : [URL(fileURLWithPath: self.archiveRootPath).standardizedFileURL.path]
                _ = try self.services.indexer.scanDownloads(
                    rootURL: downloadsURL,
                    excludedPaths: excluded
                )
                let report = try self.services.scanner.detectDuplicateGroups(scope: .downloads)
                let isolated = try self.services.actionEngine.autoQuarantineDuplicateGroups(report.verifiedGroups)
                try self.services.bundleBuilder.rebuildWeeklyBundles(scope: .downloads, now: Date())
                try self.services.store.setStringSetting(key: self.initialSeedDoneKey, value: "1")
                return isolated
            }

            triggerBackgroundAIAnalysis()
            statusMessage = "首次扫描完成：已处理 \(result) 个重复文件并生成整理建议"
        } catch {
            handleError(error)
        }
    }

    private func updateOnboardingState() async {
        do {
            let onboardingDone = try await runBackground {
                (try self.services.store.stringSetting(key: self.onboardingCompletedKey) ?? "0") == "1"
            }
            showOnboarding = !onboardingDone
        } catch {
            handleError(error)
        }
    }

    // MARK: - FSEvents + storm mode

    private func startWatcherIfPossible() async {
        watcher?.stop()
        watcher = nil

        do {
            let watchRoots = try await runBackground { () -> [FSEventsWatcher.WatchRoot] in
                var roots: [FSEventsWatcher.WatchRoot] = []
                if let downloads = try self.resolveRootURL(scope: .downloads) {
                    roots.append(.init(scope: .downloads, url: downloads))
                }
                if let desktop = try self.services.accessManager.resolveDesktopAccess() {
                    roots.append(.init(scope: .desktop, url: desktop))
                }
                if let documents = try self.services.accessManager.resolveDocumentsAccess() {
                    roots.append(.init(scope: .documents, url: documents))
                }
                return roots
            }

            guard !watchRoots.isEmpty else { return }
            let watcher = FSEventsWatcher(watchRoots: watchRoots, debounceInterval: 4.0) { [weak self] deltas in
                guard let self else { return }
                Task { @MainActor in
                    self.handleWatcherDeltas(deltas)
                }
            }
            try watcher.start()
            self.watcher = watcher
        } catch {
            handleError(error)
        }
    }

    private func handleWatcherDeltas(_ deltas: [FSEventsWatcher.ScopedDirectoryDelta]) {
        guard !deltas.isEmpty else { return }

        let changedDirectoryCount = deltas.reduce(0) { $0 + $1.directories.count }
        let now = Date()
        stormSamples.append((time: now, count: changedDirectoryCount))
        let thresholdDate = now.addingTimeInterval(-stormWindowSeconds)
        stormSamples.removeAll { $0.time < thresholdDate }
        let inWindow = stormSamples.reduce(0) { $0 + $1.count }

        if inWindow > stormThreshold, !stormModeActive {
            enterStormMode()
        }

        if stormModeActive {
            stormDirty = true
            stormStatusText = "检测到高频变动，稍后会自动重新同步。"
            return
        }

        enqueueIncrementalReindex(deltas)
    }

    private func enterStormMode() {
        stormModeActive = true
        stormDirty = true
        stormStatusText = "检测到高频变动，稍后会自动重新同步。"
        Task { await logEvent("storm_mode", "Entered storm mode", payload: ["threshold": String(stormThreshold)]) }

        stormRecoveryTask?.cancel()
        stormRecoveryTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: stormRecoverDelaySeconds * 1_000_000_000)
            await self.exitStormModeAndResync()
        }
    }

    private func exitStormModeAndResync() async {
        stormModeActive = false
        stormSamples.removeAll()

        guard stormDirty else {
            stormStatusText = nil
            return
        }

        stormDirty = false
        await runIncrementalResyncForAuthorizedScopes(reason: "storm-recovery")
        await refreshDashboard()
        stormStatusText = nil
        await logEvent("storm_mode", "Recovered from storm mode", payload: nil)
    }

    private func enqueueIncrementalReindex(_ deltas: [FSEventsWatcher.ScopedDirectoryDelta]) {
        for delta in deltas {
            let paths = Set(delta.directories.map { $0.standardizedFileURL.path })
            pendingReindexDirectories[delta.scope, default: []].formUnion(paths)
        }

        guard incrementalReindexTask == nil else { return }
        incrementalReindexTask = Task { [weak self] in
            guard let self else { return }
            await self.drainIncrementalReindexQueue()
        }
    }

    private func drainIncrementalReindexQueue() async {
        defer { incrementalReindexTask = nil }
        var performedResync = false

        while true {
            var snapshot: [RootScope: [String]] = [:]
            for (scope, paths) in pendingReindexDirectories {
                if !paths.isEmpty {
                    snapshot[scope] = paths.sorted()
                }
            }
            pendingReindexDirectories.removeAll()

            if snapshot.isEmpty {
                break
            }

            do {
                let didResyncSnapshot = try await runBackground {
                    var didResync = false
                    let excluded = self.archiveRootPath.isEmpty
                        ? []
                        : [URL(fileURLWithPath: self.archiveRootPath).standardizedFileURL.path]
                    for (scope, paths) in snapshot {
                        guard let rootURL = try self.resolveRootURL(scope: scope) else { continue }
                        didResync = true
                        let directories = paths.map { URL(fileURLWithPath: $0) }
                        _ = try self.services.indexer.reindex(
                            scope: scope,
                            rootURL: rootURL,
                            changedDirectories: directories,
                            excludedPaths: excluded
                        )
                        try self.services.bundleBuilder.rebuildWeeklyBundles(scope: scope, now: Date())
                    }
                    return didResync
                }
                performedResync = performedResync || didResyncSnapshot
            } catch {
                handleError(error)
            }
        }

        if performedResync {
            triggerBackgroundAIAnalysis()
        }
        await refreshDashboard()
    }

    private func runIncrementalResyncForAuthorizedScopes(reason _: String) async {
        do {
            let didResync = try await runBackground {
                var didResync = false
                let excluded = self.archiveRootPath.isEmpty
                    ? []
                    : [URL(fileURLWithPath: self.archiveRootPath).standardizedFileURL.path]
                if let downloads = try self.resolveRootURL(scope: .downloads) {
                    didResync = true
                    _ = try self.services.indexer.reindex(
                        scope: .downloads,
                        rootURL: downloads,
                        changedDirectories: [downloads],
                        excludedPaths: excluded
                    )
                    try self.services.bundleBuilder.rebuildWeeklyBundles(scope: .downloads, now: Date())
                }

                if let desktop = try self.services.accessManager.resolveDesktopAccess() {
                    didResync = true
                    _ = try self.services.indexer.reindex(
                        scope: .desktop,
                        rootURL: desktop,
                        changedDirectories: [desktop],
                        excludedPaths: excluded
                    )
                    try self.services.bundleBuilder.rebuildWeeklyBundles(scope: .desktop, now: Date())
                }

                if let documents = try self.services.accessManager.resolveDocumentsAccess() {
                    didResync = true
                    _ = try self.services.indexer.reindex(
                        scope: .documents,
                        rootURL: documents,
                        changedDirectories: [documents],
                        excludedPaths: excluded
                    )
                    try self.services.bundleBuilder.rebuildWeeklyBundles(scope: .documents, now: Date())
                }
                return didResync
            }
            if didResync {
                triggerBackgroundAIAnalysis()
            }
        } catch {
            handleError(error)
        }
    }

    private func resolveRootURL(scope: RootScope) throws -> URL? {
        switch scope {
        case .downloads:
            guard let downloads = try services.accessManager.resolveDownloadsAccess() else {
                return nil
            }
            let raw = try services.store.stringSetting(key: testModeSettingKey) ?? "0"
            guard Self.parseBool(raw) else {
                return downloads
            }
            let testRoot = downloads.appendingPathComponent("TidyTest", isDirectory: true)
            try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
            return testRoot
        case .desktop:
            return try services.accessManager.resolveDesktopAccess()
        case .documents:
            return try services.accessManager.resolveDocumentsAccess()
        case .archived:
            return try services.accessManager.resolveArchiveRootAccess()
        }
    }

    private func inferScope(for bundle: DecisionBundle) -> RootScope? {
        if bundle.id.hasPrefix("\(RootScope.downloads.rawValue)-") {
            return .downloads
        }
        if bundle.id.hasPrefix("\(RootScope.desktop.rawValue)-") {
            return .desktop
        }
        if bundle.id.hasPrefix("\(RootScope.documents.rawValue)-") {
            return .documents
        }

        guard let path = bundle.filePaths.first else {
            return nil
        }

        let downloadsRoot = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ?? ""
        if !downloadsRoot.isEmpty, path == downloadsRoot || path.hasPrefix(downloadsRoot + "/") {
            return .downloads
        }
        let desktopRoot = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first?.path ?? ""
        if !desktopRoot.isEmpty, path == desktopRoot || path.hasPrefix(desktopRoot + "/") {
            return .desktop
        }
        let documentsRoot = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? ""
        if !documentsRoot.isEmpty, path == documentsRoot || path.hasPrefix(documentsRoot + "/") {
            return .documents
        }
        return nil
    }

    // MARK: - Helpers

    private func runQuickPlanPhaseA(rootURL: URL,
                                    window: ArchiveTimeWindow,
                                    now: Date) throws -> QuickPlanPhaseAResult {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isDirectoryKey,
            .isHiddenKey,
            .isSymbolicLinkKey,
            .contentModificationDateKey,
            .nameKey,
            .fileSizeKey
        ]
        let urls = try fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: Array(keys), options: [])
        let packageExts: Set<String> = ["app", "pkg", "photoslibrary", "bundle", "framework", "xcarchive"]
        let imageExts: Set<String> = ["png", "jpg", "jpeg", "heic"]
        let screenshotTokens = ["screenshot", "screen shot", "屏幕快照", "截图"]

        let windowStart: Date
        switch window {
        case .days7:
            windowStart = Calendar.current.date(byAdding: .day, value: -7, to: now) ?? now
        case .days30:
            windowStart = Calendar.current.date(byAdding: .day, value: -30, to: now) ?? now
        case .all:
            windowStart = .distantPast
        }

        var screenshots = 0
        var pdfs = 0
        var inbox = 0
        var installers = 0
        var scannedFiles = 0
        var skipped: [String: Int] = [:]

        func skip(_ key: String) {
            skipped[key, default: 0] += 1
        }

        for url in urls {
            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: keys)
            } catch {
                skip("permission")
                continue
            }

            if values.isHidden == true || url.lastPathComponent.hasPrefix(".") {
                skip("hidden")
                continue
            }

            if values.isSymbolicLink == true {
                skip("symlink")
                continue
            }

            if values.isRegularFile != true {
                if values.isDirectory == true, packageExts.contains(url.pathExtension.lowercased()) {
                    skip("package")
                }
                continue
            }

            _ = values.fileSize ?? 0
            let modifiedAt = values.contentModificationDate ?? .distantPast
            if modifiedAt < windowStart {
                skip("time_window")
                continue
            }

            scannedFiles += 1
            let ext = url.pathExtension.lowercased()
            let lowerName = (values.name ?? url.lastPathComponent).lowercased()

            if Self.isPendingInboxRiskCandidate(ext: ext, lowerName: lowerName, sizeBytes: Int64(values.fileSize ?? 0)) {
                skip("pending_inbox")
                continue
            }

            if ext == "pdf" {
                pdfs += 1
                continue
            }
            if imageExts.contains(ext),
               screenshotTokens.contains(where: { lowerName.contains($0) }) {
                screenshots += 1
                continue
            }
            if ext == "dmg" || ext == "pkg" {
                if window == .all {
                    inbox += 1
                    continue
                }
                installers += 1
                continue
            }
            inbox += 1
        }

        let total = screenshots + pdfs + inbox + installers
        let reason: String?
        if total == 0 {
            reason = phaseANoActionReason(skipped: skipped, window: window)
        } else {
            reason = nil
        }

        return QuickPlanPhaseAResult(
            screenshotsCount: screenshots,
            pdfCount: pdfs,
            inboxCount: inbox,
            installersCount: installers,
            scannedFiles: scannedFiles,
            skippedReasons: skipped,
            noActionReason: reason
        )
    }

    private func phaseANoActionReason(skipped: [String: Int], window: ArchiveTimeWindow) -> String {
        var parts: [String] = []

        if let windowSkipped = skipped["time_window"], windowSkipped > 0, window != .all {
            parts.append("时间窗口内没有文件（可切换到“全部”）")
        }

        let hidden = skipped["hidden"] ?? 0
        let packages = skipped["package"] ?? 0
        let symlinks = skipped["symlink"] ?? 0
        let permissions = skipped["permission"] ?? 0

        var filtered: [String] = []
        if hidden > 0 { filtered.append("隐藏文件 \(hidden)") }
        if packages > 0 { filtered.append("package 目录 \(packages)") }
        if symlinks > 0 { filtered.append("符号链接 \(symlinks)") }
        if permissions > 0 { filtered.append("权限受限 \(permissions)") }

        if !filtered.isEmpty {
            parts.append("已过滤：\(filtered.joined(separator: "，"))")
        }

        if parts.isEmpty {
            return "范围/时间窗口/规则未命中"
        }
        return parts.joined(separator: "；")
    }

    private func buildRecommendedPlanBucketsFromPhaseA(_ phaseA: QuickPlanPhaseAResult,
                                                       archiveWindow: ArchiveTimeWindow,
                                                       now: Date) -> [RecommendedPlanBucket] {
        let month = DateFormatter.recommendedArchiveMonth.string(from: now)
        let root = archiveRootPath.isEmpty ? "<choose archive root>" : archiveRootPath
        let compactRoot: (String) -> String = { path in
            guard path.hasPrefix("/") else { return path }
            let components = URL(fileURLWithPath: path).pathComponents.filter { $0 != "/" }
            guard components.count > 2 else { return path }
            return "…/\(components.suffix(2).joined(separator: "/"))"
        }

        return [
            RecommendedPlanBucket(
                kind: .screenshots,
                bundleID: nil,
                title: "截图",
                destination: compactRoot("\(root)/Screenshots/\(month)"),
                why: "来自屏幕快照命名/时间集中。",
                riskLabel: "低",
                totalFiles: phaseA.screenshotsCount,
                missingFiles: 0,
                actionKind: .move
            ),
            RecommendedPlanBucket(
                kind: .pdfs,
                bundleID: nil,
                title: "PDF",
                destination: compactRoot("\(root)/Downloads PDFs/\(month)"),
                why: "最近下载的 PDF（多为课件/账单/表格）。",
                riskLabel: "低",
                totalFiles: phaseA.pdfCount,
                missingFiles: 0,
                actionKind: .move
            ),
            RecommendedPlanBucket(
                kind: .inbox,
                bundleID: nil,
                title: "下载区收件箱",
                destination: compactRoot("\(root)/Downloads Inbox/\(month)"),
                why: "下载区顶层杂物，按类型归档。",
                riskLabel: "低",
                totalFiles: phaseA.inboxCount,
                missingFiles: 0,
                actionKind: .move
            ),
            RecommendedPlanBucket(
                kind: .installers,
                bundleID: nil,
                title: "安装包（.dmg/.pkg）",
                destination: "隔离区",
                why: archiveWindow == .all
                    ? "首次大扫除：只移动不隔离。"
                    : "安装器文件用完通常可删（先隔离，可恢复）。",
                riskLabel: "低",
                totalFiles: archiveWindow == .all ? 0 : phaseA.installersCount,
                missingFiles: 0,
                actionKind: .quarantine
            )
        ]
    }

    private func applyQuickPlanPhaseAToUI(_ phaseA: QuickPlanPhaseAResult,
                                          archiveWindow: ArchiveTimeWindow,
                                          now: Date) {
        let buckets = buildRecommendedPlanBucketsFromPhaseA(phaseA, archiveWindow: archiveWindow, now: now)
        recommendedPlanBuckets = buckets
        recommendedPlanActionableCount = buckets.reduce(0) { $0 + $1.actionableFiles }
    }

    private func scanSummary(from result: DownloadsScanExecutionResult,
                             phaseAPlan: QuickPlanPhaseAResult?,
                             archiveWindow: ArchiveTimeWindow) -> String {
        let phaseABundleCount = phaseAPlan?.bucketCount(window: archiveWindow) ?? 0
        let phaseAActionable = phaseAPlan?.actionableCount(window: archiveWindow) ?? 0
        let effectiveBundleCount = max(result.bundleCount, phaseABundleCount)

        if effectiveBundleCount > 0 || result.isolatedCount > 0 || phaseAActionable > 0 {
            return "found \(effectiveBundleCount) bundles, isolated \(result.isolatedCount) duplicates"
        }

        if let reason = phaseAPlan?.noActionReason, !reason.isEmpty {
            return "no actionable files found (reason: \(reason))"
        }

        if let reason = result.noActionReason, !reason.isEmpty {
            return "no actionable files found (reason: \(reason))"
        }

        return "no actionable files found (reason: 范围/时间窗口/规则未命中)"
    }

    private func buildNoActionReasonIfNeeded(isolatedCount: Int,
                                             bundleCount: Int,
                                             sizeOnlyCandidates: Int) throws -> String? {
        guard isolatedCount == 0, bundleCount == 0 else { return nil }

        var reasons: [String] = []

        if let stats = try loadLastDownloadsIndexStats() {
            var filteredParts: [String] = []

            let hidden = stats.skippedHidden ?? 0
            let packages = stats.skippedPackage ?? 0
            let symlinks = stats.skippedSymlink ?? 0
            let permissions = stats.skippedPermission ?? 0
            let watermarkSkipped = stats.skippedWatermark ?? 0
            let written = stats.written ?? 0

            if hidden > 0 {
                filteredParts.append("\(hidden) hidden")
            }
            if packages > 0 {
                filteredParts.append("\(packages) package")
            }
            if symlinks > 0 {
                filteredParts.append("\(symlinks) symlink")
            }
            if permissions > 0 {
                filteredParts.append("\(permissions) permission-limited")
            }

            if !filteredParts.isEmpty {
                reasons.append("ignored " + filteredParts.joined(separator: ", "))
            }

            if written == 0, watermarkSkipped > 0 {
                reasons.append("no new files changed since last scan")
            }
        }

        if sizeOnlyCandidates > 0 {
            reasons.append("\(sizeOnlyCandidates) large-file duplicate candidates need manual review")
        }

        if reasons.isEmpty {
            reasons.append("no files matched Downloads Inbox in last 30 days")
        }

        return reasons.joined(separator: "; ")
    }

    private func loadLastDownloadsIndexStats() throws -> LastDownloadsIndexStats? {
        guard let raw = try services.store.stringSetting(key: lastDownloadsIndexStatsKey),
              let data = raw.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(LastDownloadsIndexStats.self, from: data)
    }

    private func scanFailureReason(_ error: Error) -> String {
        let formatted = formatErrorMessage(error)
        let lowered = formatted.lowercased()

        if lowered.contains("timed out") {
            return "扫描超时"
        }
        if lowered.contains("download") && (lowered.contains("missing") || lowered.contains("denied") || lowered.contains("authorization")) {
            return "下载文件夹需要授权"
        }
        if lowered.contains("db needs reset") || lowered.contains("no such table") || lowered.contains("no such column") {
            return "应用数据需要重置"
        }

        return formatted
    }

    private func isScanTimeoutError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.code == 408 {
            return true
        }
        return nsError.localizedDescription.lowercased().contains("timed out")
    }

    private func loadCurrentScanDigestCounts() async -> (bundles: Int, isolated: Int) {
        do {
            return try await runBackground {
                let digest = try self.services.digestService.weeklySummary(now: Date())
                return (digest.needsDecisionCount, digest.autoIsolatedCount)
            }
        } catch {
            appendRuntimeLog("[AppState] scan_partial_counts_fallback error=\(error.localizedDescription)")
            return (pendingBundlesCount, digest.autoIsolatedCount)
        }
    }

    private func scanFailureSummary(reason: String,
                                    timedOut: Bool,
                                    timeoutSeconds: TimeInterval,
                                    bundles: Int,
                                    isolated: Int,
                                    phaseAActionable: Int) -> String {
        if timedOut {
            if bundles > 0 || isolated > 0 || phaseAActionable > 0 {
                return "扫描超时（\(Int(timeoutSeconds))秒），显示部分结果：建议 \(bundles) 条，已隔离 \(isolated) 个"
            }
            return "当前没有可处理的文件（原因：\(reason)）"
        }
        if bundles > 0 || isolated > 0 || phaseAActionable > 0 {
            return "已有部分结果：建议 \(bundles) 条，已隔离 \(isolated) 个"
        }
        return "当前没有可处理的文件（原因：\(reason)）"
    }

    private func scanNoActionReasonForHome() -> String {
        if let reason = Self.extractNoActionReason(from: lastScanSummary) {
            return reason
        }
        return "范围/时间窗口/规则未命中"
    }

    private static func extractNoActionReason(from summary: String) -> String? {
        let lower = summary.lowercased()
        guard summary.contains("当前没有可处理的文件") else { return nil }
        guard let reasonRange = summary.range(of: "原因：") else { return nil }
        var reason = String(summary[reasonRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if reason.hasSuffix(")") {
            reason.removeLast()
        }
        return reason.isEmpty ? nil : reason
    }

    private func reconcileTimedOutScanSummary(timeoutSeconds: TimeInterval) async {
        do {
            try await Task.sleep(nanoseconds: 2_000_000_000)
        } catch {
            return
        }

        await refreshDigestSnapshot(reason: "scan-timeout-reconcile")
        let estimatedBundles = recommendedPlanBuckets.filter { $0.actionableFiles > 0 }.count
        let bundles = max(pendingBundlesCount, estimatedBundles)
        let isolated = digest.autoIsolatedCount
        guard bundles > 0 || isolated > 0 else {
            return
        }

        let corrected = "扫描超时（\(Int(timeoutSeconds))秒），显示部分结果：建议 \(bundles) 条，已隔离 \(isolated) 个"
        lastScanSummary = corrected
        do {
            try await runBackground {
                try self.services.store.setStringSetting(key: self.lastScanSummaryKey, value: corrected)
            }
            appendRuntimeLog("[AppState] scan_timeout_reconciled summary=\(corrected)")
        } catch {
            appendRuntimeLog("[AppState] scan_timeout_reconcile_failed error=\(error.localizedDescription)")
        }
    }

    private func repairCompletionMessage(report: ConsistencyReport) -> String {
        var parts: [String] = ["修复完成：已清理失效索引记录（不会恢复文件本身）。"]

        if report.missingOriginals > 0 {
            parts.append("需要关注：有 \(report.missingOriginals) 个与应用相关的文件缺失。")
        } else {
            parts.append("没有发现与应用相关的缺失文件。")
        }

        if report.lowPriorityMissingOriginals > 0 {
            parts.append("低优先级外部变动：有 \(report.lowPriorityMissingOriginals) 个文件在 Tidy 外部被移动或删除。")
        }

        if report.missingQuarantineFiles > 0 {
            parts.append("隔离区副本缺失：\(report.missingQuarantineFiles) 个。")
        }

        return parts.joined(separator: " ")
    }

    private func persistLastScan(summary: String) async {
        let now = Date()
        lastScanAt = now
        lastScanSummary = summary

        do {
            try await runBackground {
                try self.services.store.setDoubleSetting(key: self.lastScanAtKey, value: now.timeIntervalSince1970)
                try self.services.store.setStringSetting(key: self.lastScanSummaryKey, value: summary)
            }
        } catch {
            appendRuntimeLog("[AppState] failed to persist last scan summary: \(error.localizedDescription)")
        }
    }

    private func recordArchiveFinishedJournal(movedScreenshots: Int,
                                              movedPDFs: Int,
                                              movedInbox: Int,
                                              quarantinedInstallers: Int,
                                              filesBefore: Int,
                                              filesAfter: Int,
                                              skippedReason: String?) async {
        let txnID = "archive-plan-" + UUID().uuidString
        let movedTotal = movedScreenshots + movedPDFs + movedInbox
        let state: String
        if movedTotal > 0 {
            state = "SUCCESS"
        } else {
            state = "FAILED"
        }

        let human = "archive_finished moved=\(movedTotal) screenshots=\(movedScreenshots) pdf=\(movedPDFs) inbox=\(movedInbox) installers_quarantine=\(quarantinedInstallers) files=\(filesBefore)->\(filesAfter)"
        let message = skippedReason ?? human

        do {
            try await runBackground {
                try self.services.store.insertJournalEntry(
                    .init(
                        id: UUID().uuidString,
                        txnID: txnID,
                        actor: "user",
                        actionType: .bundleApplyFinished,
                        targetType: "archive_plan",
                        targetID: txnID,
                        srcPath: "",
                        dstPath: self.archiveOpenDestinations.first?.path ?? "",
                        copyOrMove: "none",
                        conflictResolution: "summary",
                        verified: movedTotal > 0,
                        errorCode: state,
                        errorMessage: message,
                        bytesDelta: 0,
                        createdAt: Date(),
                        undoable: false
                    )
                )
            }
        } catch {
            appendRuntimeLog("[AppState] archive_finished_journal_failed error=\(error.localizedDescription)")
        }
    }

    private func push(_ route: Route) {
        if path.last == route {
            return
        }
        path.append(route)
    }

    private func triggerBackgroundAIAnalysis() {
        Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            await self.refreshTotalFilesScanned()
            await self.loadDuplicateGroups()
            await self.loadLargeFiles()
            await self.loadOldInstallers()
        }

        guard shouldAutoAnalyzeAfterScan() else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastAIAnalysisAtKey)
        Task { [weak self] in
            await self?.runBatchAnalysis()
        }
    }

    private var autoAnalyzeEnabled: Bool {
        if let value = UserDefaults.standard.object(forKey: "auto_analyze_enabled") as? Bool {
            return value
        }
        return true
    }

    private var notifyAIDoneEnabled: Bool {
        if let value = UserDefaults.standard.object(forKey: "notify_ai_done") as? Bool {
            return value
        }
        return true
    }

    func sendScanCompletionNotification(applied: Int, remaining: Int) {
        let content = UNMutableNotificationContent()
        content.sound = .default

        if applied > 0 && remaining == 0 {
            content.title = "文件整理完毕 ✓"
            content.body = "已自动整理 \(applied) 个文件，收件箱清空了"
        } else if applied > 0 && remaining > 0 {
            content.title = "已自动整理 \(applied) 个文件"
            content.body = "另有 \(remaining) 条建议需要你确认"
        } else if remaining > 0 {
            content.title = "发现 \(remaining) 条整理建议"
            content.body = "点击打开 Tidy 查看"
        } else {
            return
        }

        content.userInfo = ["action": "openBundles"]

        let request = UNNotificationRequest(
            identifier: "tidy2.scan.complete.\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    private func maybeAutoAnalyzeAfterHomeScan() async {
        await refreshTotalFilesScanned()
        let shouldAutoAnalyze = shouldAutoAnalyzeAfterScan()
        if shouldAutoAnalyze {
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastAIAnalysisAtKey)
            Task { [weak self] in
                await self?.runBatchAnalysis()
            }
        }
    }

    private func shouldAutoAnalyzeAfterScan() -> Bool {
        guard autoAnalyzeEnabled else { return false }
        guard totalFilesScanned > 0 else { return false }

        switch AIProvider.current {
        case .ollama:
            let model = (UserDefaults.standard.string(forKey: "ollama_model") ?? "qwen2.5:3b")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty else { return false }
        case .claude:
            let key = FileIntelligenceService.readAPIKeyFromKeychain()?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !key.isEmpty else { return false }
        }

        let lastAnalysisAt = UserDefaults.standard.double(forKey: lastAIAnalysisAtKey)
        if lastAnalysisAt > 0,
           Date().timeIntervalSince1970 - lastAnalysisAt < 3600 {
            return false
        }
        return true
    }

    private func launchAIAnalysis(priority: TaskPriority,
                                  run: @escaping @Sendable (FileIntelligenceService) async -> Void) {
        let service = services.fileIntelligenceService
        let store = services.store
        let notificationsEnabled = notifyAIDoneEnabled

        Task.detached(priority: priority) { [weak self] in
            let beforeCount = (try? store.countAnalyzedFiles()) ?? 0
            await MainActor.run { self?.isAIAnalyzing = true }
            NotificationCenter.default.post(name: .aiAnalysisStarted, object: nil)

            await run(service)

            let afterCount = (try? store.countAnalyzedFiles()) ?? beforeCount
            let newCount = max(afterCount - beforeCount, 0)
            if notificationsEnabled, newCount > 0 {
                let recentItems = (try? store.allFileIntelligence(limit: newCount)) ?? []
                let keepCount = recentItems.filter { $0.keepOrDelete == .keep }.count
                let deleteCount = recentItems.filter { $0.keepOrDelete == .delete }.count
                let content = UNMutableNotificationContent()
                content.title = "AI 分析完成"
                content.body = "分析了 \(newCount) 个文件，\(keepCount) 个建议保留，\(deleteCount) 个建议删除"
                content.sound = .default
                let request = UNNotificationRequest(
                    identifier: UUID().uuidString,
                    content: content,
                    trigger: nil
                )
                try? await UNUserNotificationCenter.current().add(request)
            }

            await MainActor.run { self?.isAIAnalyzing = false }
            NotificationCenter.default.post(name: .aiAnalysisFinished, object: nil)
        }

        // Poll every 3s for up to 5 minutes until analysis finishes
        Task { [weak self] in
            var elapsed = 0
            let maxSeconds = 300
            let interval = 3
            while elapsed < maxSeconds {
                try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
                elapsed += interval
                guard let self else { return }
                await self.refreshAIAnalysisState()
                // Stop early once no more files need analysis
                let remaining = (try? await self.runBackground {
                    try self.services.store.pathsNeedingAnalysis(limit: 1)
                }) ?? []
                if remaining.isEmpty { break }
            }
        }
    }

    private func chooseFolder(message: String, prompt: String, defaultURL: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.message = message
        panel.prompt = prompt
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = defaultURL

        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private func chooseExportDestination(defaultName: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = "导出诊断包"
        panel.nameFieldStringValue = defaultName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [.zip]
        panel.message = "选择保存匿名诊断包的位置。"
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private func defaultDebugBundleName() -> String {
        let stamp = DateFormatter.debugExportFilename.string(from: Date())
        return "Tidy2_Debug_\(stamp).zip"
    }

    private func logExportRuntime(_ message: String) {
        Task.detached(priority: .utility) {
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let line = "[\(timestamp)] \(message)\n"
            RuntimeLog.append(line.trimmingCharacters(in: .newlines))
        }
    }

    private func runBackground<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            workerQueue.async {
                do {
                    let value = try work()
                    continuation.resume(returning: value)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func runBackgroundWithTimeout<T>(operationName: String,
                                             timeoutSeconds: TimeInterval,
                                             work: @escaping () throws -> T) async throws -> T {
        let gate = BackgroundOperationCompletionGate()

        return try await withCheckedThrowingContinuation { continuation in
            var workItem: DispatchWorkItem?
            workItem = DispatchWorkItem {
                guard let workItem, !workItem.isCancelled else { return }
                do {
                    let value = try work()
                    Task.detached(priority: .utility) {
                        if await gate.completeIfNeeded() {
                            continuation.resume(returning: value)
                        }
                    }
                } catch {
                    Task.detached(priority: .utility) {
                        if await gate.completeIfNeeded() {
                            continuation.resume(throwing: error)
                        }
                    }
                }
            }
            if let workItem {
                workerQueue.async(execute: workItem)
            }

            Task.detached(priority: .utility) {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                if await gate.completeIfNeeded() {
                    workItem?.cancel()
                    let timeoutError = NSError(
                        domain: "AppState.Operation",
                        code: 408,
                        userInfo: [NSLocalizedDescriptionKey: "\(operationName) timed out"]
                    )
                    continuation.resume(throwing: timeoutError)
                }
            }
        }
    }

    private func runDetachedWithTimeout<T: Sendable>(operationName: String,
                                                     timeoutSeconds: TimeInterval,
                                                     work: @Sendable @escaping () throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask(priority: .utility) {
                try work()
            }
            group.addTask(priority: .utility) {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw NSError(
                    domain: "AppState.Operation",
                    code: 408,
                    userInfo: [NSLocalizedDescriptionKey: "\(operationName) timed out"]
                )
            }

            guard let value = try await group.next() else {
                throw NSError(
                    domain: "AppState.Operation",
                    code: 500,
                    userInfo: [NSLocalizedDescriptionKey: "\(operationName) returned no result"]
                )
            }
            group.cancelAll()
            return value
        }
    }

    private func runExclusiveLongTask<T>(name: String,
                                         timeoutSeconds: TimeInterval,
                                         work: @escaping () throws -> T) async throws -> T {
        if let active = await operationLock.currentOperationName() {
            appendRuntimeLog("[OperationLock] waiting name=\(name) active=\(active)")
        }

        await operationLock.acquire(name: name)
        appendRuntimeLog("[OperationLock] acquired name=\(name)")

        do {
            let value = try await runBackgroundWithTimeout(
                operationName: name,
                timeoutSeconds: timeoutSeconds,
                work: work
            )
            await operationLock.release()
            appendRuntimeLog("[OperationLock] released name=\(name)")
            return value
        } catch {
            await operationLock.release()
            appendRuntimeLog("[OperationLock] released name=\(name) error=\(error.localizedDescription)")
            throw error
        }
    }

    private func logEvent(_ eventType: String, _ message: String, payload: [String: String]?) async {
        do {
            let payloadJSON: String?
            if let payload, !payload.isEmpty {
                let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
                payloadJSON = String(data: data, encoding: .utf8)
            } else {
                payloadJSON = nil
            }
            let store = services.store
            workerQueue.async {
                do {
                    try store.logEvent(eventType: eventType, message: message, payloadJSON: payloadJSON)
                } catch {
                    // Avoid surfacing telemetry failures to end users.
                }
            }
        } catch {
            // Avoid surfacing telemetry failures to end users.
        }
    }

    private func buildIssueReportText() async throws -> String {
        let latestTxn = try await runBackground {
            try self.services.store.latestTxnID()
        } ?? "n/a"

        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"

        let downloads = accessHealth[.downloads]?.status.rawValue ?? "unknown"
        let desktop = accessHealth[.desktop]?.status.rawValue ?? "unknown"
        let documents = accessHealth[.documents]?.status.rawValue ?? "not enabled"
        let archive = accessHealth[.archiveRoot]?.status.rawValue ?? "unknown"

        return """
        [Tidy2 Issue Report]
        Version: \(version) (\(build))
        macOS: \(os)
        Health:
        - Downloads: \(downloads)
        - Desktop: \(desktop)
        - Documents: \(documents)
        - Archive Root: \(archive)
        Latest txn_id: \(latestTxn)
        Pending bundles: \(digest.needsDecisionCount)
        Notes:
        - What did you expect?
        - What happened instead?
        - Can you reproduce it? (steps)
        """
    }

    private func formatErrorMessage(_ error: Error) -> String {
        let nsError = error as NSError
        var message = nsError.localizedDescription
        let lowerMessage = message.lowercased()
        // Common POSIX / system errors → Chinese
        if lowerMessage.contains("no such file or directory") {
            message = "文件不存在，可能已被移动或删除"
        } else if lowerMessage.contains("permission denied") || lowerMessage.contains("operation not permitted") {
            message = "没有权限访问此文件"
        } else if lowerMessage.contains("no space left") || lowerMessage.contains("disk full") || lowerMessage.contains("not enough space") {
            message = "磁盘空间不足，无法完成操作"
        } else if lowerMessage.contains("apply-bundle") && lowerMessage.contains("timed out") {
            message = "执行整理超时"
        } else if lowerMessage.contains("autopilot") && lowerMessage.contains("timed out") {
            message = "自动扫描超时"
        } else if lowerMessage.contains("force-full-scan") && lowerMessage.contains("timed out") {
            message = "完整扫描超时"
        } else if !message.hasPrefix("操作失败") && !message.hasPrefix("文件") && !message.hasPrefix("没有") && !message.hasPrefix("磁盘") {
            // Prefix unknown errors for clarity
            let domainSpecific = nsError.domain == "SQLiteStore" || nsError.domain == "Tidy2"
            if !domainSpecific {
                message = "操作失败：\(message)"
            }
        }

        if let hintRaw = nsError.userInfo["action_hint"] as? String,
           let hint = AccessActionHint(rawValue: hintRaw) {
            message += " (\(hintText(hint)))"
        }
        if message.lowercased().contains("db needs reset") ||
            message.lowercased().contains("no such table") ||
            message.lowercased().contains("no such column") {
            databaseNeedsReset = true
            message += "（数据库需要重置）"
        }
        return message
    }

    private func archiveFailureMessage(_ error: Error) -> String {
        let message = formatErrorMessage(error).lowercased()
        if message.contains("high-risk bundle is blocked from move") {
            return "包含敏感文件，已改为保护模式（不自动移动）"
        }
        if message.contains("archive root") && message.contains("missing") {
            return "归档位置不可用，请重新选择归档目录"
        }
        if message.contains("source files are missing") {
            return "源文件已变化，已跳过不可用文件"
        }
        if message.contains("timed out") {
            return "处理超时，请重试"
        }
        return formatErrorMessage(error)
    }

    private func formatExportError(_ error: Error) -> String {
        let message = formatErrorMessage(error)
        let lower = message.lowercased()
        if lower.contains("timed out") {
            return "timeout"
        }
        if lower.contains("locked") || lower.contains("busy") {
            return "db locked"
        }
        if lower.contains("permission") || lower.contains("access") || lower.contains("denied") {
            return "permission"
        }
        return message
    }

    private func handleError(_ error: Error) {
        let nsError = error as NSError
        let message = formatErrorMessage(error)
        statusMessage = message
        appendRuntimeLog("[AppState] error \(message)")
        Task { await logEvent("error", message, payload: ["domain": nsError.domain, "code": String(nsError.code)]) }
    }

    private func appendRuntimeLog(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        RuntimeLog.append(line.trimmingCharacters(in: .newlines))
    }

    private func hintText(_ hint: AccessActionHint) -> String {
        switch hint {
        case .reauthorizeDownloads:
            return "请到首页的健康提示中重新授权下载文件夹"
        case .reauthorizeArchiveRoot:
            return "请到首页的健康提示中重新选择整理文件夹"
        case .enableDesktop:
            return "请到首页的健康提示中启用桌面监控"
        case .enableDocuments:
            return "请到首页的健康提示中启用文稿监控"
        }
    }

    private func displayName(for scope: RootScope) -> String {
        switch scope {
        case .downloads:
            return "Downloads"
        case .desktop:
            return "Desktop"
        case .documents:
            return "Documents"
        case .archived:
            return "归档目录"
        }
    }

    private func countVisibleTopLevelFiles(in rootURL: URL?) -> Int {
        guard let rootURL else { return 0 }
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isHiddenKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        return urls.reduce(into: 0) { count, url in
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isHiddenKey])
            guard values?.isHidden != true else { return }
            if values?.isRegularFile == true {
                count += 1
            }
        }
    }

    private func quarantineRootURL() throws -> URL {
        let fm = FileManager.default
        let appSupport = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Tidy2", isDirectory: true)
        return appSupport.appendingPathComponent("Quarantine", isDirectory: true)
    }

    private static func parseBool(_ raw: String?) -> Bool {
        guard let raw else { return false }
        return raw == "1" || raw.lowercased() == "true"
    }

    private static func decodePendingInboxDismissed(raw: String?) -> [String: Double] {
        guard let raw, !raw.isEmpty, let data = raw.data(using: .utf8) else {
            return [:]
        }
        let decoded = (try? JSONDecoder().decode([String: Double].self, from: data)) ?? [:]
        return decoded
    }

    private func loadPendingInboxDismissedMapUnlocked() throws -> [String: Double] {
        let raw = try services.store.stringSetting(key: pendingInboxDismissedKey)
        return Self.decodePendingInboxDismissed(raw: raw)
    }

    private func savePendingInboxDismissedMapUnlocked(_ map: [String: Double]) throws {
        let data = try JSONEncoder().encode(map)
        let raw = String(data: data, encoding: .utf8) ?? "{}"
        try services.store.setStringSetting(key: pendingInboxDismissedKey, value: raw)
    }

    private static func filterDownloadsFiles(files: [IndexedFile], testModeEnabled: Bool) -> [IndexedFile] {
        guard testModeEnabled else { return files }
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            return files
        }
        let testRoot = downloads.appendingPathComponent("TidyTest", isDirectory: true).standardizedFileURL.path
        return files.filter { file in
            let path = URL(fileURLWithPath: file.path).standardizedFileURL.path
            return path == testRoot || path.hasPrefix(testRoot + "/")
        }
    }

    private static func isRecommendedCandidate(file: IndexedFile) -> Bool {
        if file.ext == "pdf" { return true }
        if file.ext == "dmg" || file.ext == "pkg" { return true }

        let inboxExts: Set<String> = [
            "doc", "docx", "txt", "md",
            "xls", "xlsx", "csv",
            "ppt", "pptx", "key",
            "zip", "rar", "7z",
            "mp4", "mov", "mp3", "wav"
        ]
        if inboxExts.contains(file.ext) {
            return true
        }

        let imageExtensions = Set(["png", "jpg", "jpeg"])
        if imageExtensions.contains(file.ext) {
            let lower = file.name.lowercased()
            if lower.contains("screenshot") || lower.contains("screen shot") {
                return true
            }
        }
        return false
    }

    private static func countNewRecommendedFiles(files: [IndexedFile],
                                                 lastProcessedAt: Double,
                                                 now: Date) -> Int {
        let windowStart = Calendar.current.date(byAdding: .day, value: -30, to: now) ?? now
        let fm = FileManager.default
        return files.reduce(into: 0) { count, file in
            guard file.modifiedAt >= windowStart else { return }
            guard file.modifiedAt.timeIntervalSince1970 >= lastProcessedAt else { return }
            guard isRecommendedCandidate(file: file) else { return }
            guard fm.fileExists(atPath: file.path) else { return }
            count += 1
        }
    }

    private static func isPendingInboxRiskCandidate(ext: String, lowerName: String, sizeBytes: Int64) -> Bool {
        let archiveLikeExts: Set<String> = ["zip", "rar", "7z"]
        let highRiskBinaryExts: Set<String> = ["exe", "msi", "iso", "apk", "dylib", "sh", "command", "bat", "jar"]
        let knownLowRiskExts: Set<String> = [
            "pdf", "png", "jpg", "jpeg", "heic",
            "doc", "docx", "txt", "md",
            "xls", "xlsx", "csv",
            "ppt", "pptx", "key",
            "mp4", "mov", "mp3", "wav",
            "dmg", "pkg"
        ]
        let riskyNameTokens = [
            "install", "installer", "setup", "patch", "update", "driver",
            "keygen", "serial", "license", "crack", "activator"
        ]

        if archiveLikeExts.contains(ext) {
            return true
        }
        if highRiskBinaryExts.contains(ext) {
            return true
        }
        if riskyNameTokens.contains(where: { lowerName.contains($0) }) {
            return true
        }
        if ext.isEmpty || !knownLowRiskExts.contains(ext) {
            return sizeBytes > 0
        }
        return false
    }

    private static func makePendingInboxCandidates(from files: [IndexedFile],
                                                   now: Date,
                                                   dismissedMap: [String: Double]) -> [SearchResultItem] {
        let windowStart = Calendar.current.date(byAdding: .day, value: -30, to: now) ?? now

        return files
            .filter { $0.modifiedAt >= windowStart }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .filter { file in
                let dismissedMtime = dismissedMap[file.id]
                guard let dismissedMtime else { return true }
                return abs(dismissedMtime - file.modifiedAt.timeIntervalSince1970) > 0.001
            }
            .filter { file in
                Self.isPendingInboxRiskCandidate(
                    ext: file.ext.lowercased(),
                    lowerName: file.name.lowercased(),
                    sizeBytes: file.sizeBytes
                )
            }
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(120)
            .map {
                SearchResultItem(
                    id: $0.id,
                    path: $0.path,
                    name: $0.name,
                    ext: $0.ext,
                    sizeBytes: $0.sizeBytes,
                    modifiedAt: $0.modifiedAt,
                    excerpt: FileExplanationBuilder.explanation(path: $0.path, bundleType: nil),
                    matchSource: "pending_inbox"
                )
            }
    }

    private func makeArchiveOpenDestinations(screenshotsMoved: Int,
                                             pdfMoved: Int,
                                             inboxMoved: Int) -> [ArchiveOpenDestination] {
        guard !archiveRootPath.isEmpty else { return [] }
        let month = DateFormatter.recommendedArchiveMonth.string(from: Date())
        var destinations: [ArchiveOpenDestination] = []
        if inboxMoved > 0 {
            destinations.append(
                ArchiveOpenDestination(
                    id: "downloads_inbox",
                    title: "下载区收件箱",
                    path: "\(archiveRootPath)/Downloads Inbox/\(month)"
                )
            )
        }
        if screenshotsMoved > 0 {
            destinations.append(
                ArchiveOpenDestination(
                    id: "screenshots",
                    title: "截图",
                    path: "\(archiveRootPath)/Screenshots/\(month)"
                )
            )
        }
        if pdfMoved > 0 {
            destinations.append(
                ArchiveOpenDestination(
                    id: "downloads_pdfs",
                    title: "下载的 PDF",
                    path: "\(archiveRootPath)/Downloads PDFs/\(month)"
                )
            )
        }
        return destinations
    }

    private func buildRecommendedPlanBuckets(bundles: [DecisionBundle],
                                             missingCounts: [String: Int],
                                             archiveRootPath: String,
                                             archiveTimeWindow: ArchiveTimeWindow,
                                             now: Date) -> [RecommendedPlanBucket] {
        let month = DateFormatter.recommendedArchiveMonth.string(from: now)
        let root = archiveRootPath.isEmpty ? "（请先选择归档根目录）" : archiveRootPath
        let compactRoot: (String) -> String = { path in
            guard path.hasPrefix("/") else { return path }
            let components = URL(fileURLWithPath: path).pathComponents.filter { $0 != "/" }
            guard components.count > 2 else { return path }
            return "…/\(components.suffix(2).joined(separator: "/"))"
        }

        func preferredBundleID(for type: BundleType) -> String {
            "\(RootScope.downloads.rawValue)-inbox30d-\(type.rawValue)"
        }

        func actionableScore(for bundle: DecisionBundle) -> Int {
            max(0, bundle.filePaths.count - (missingCounts[bundle.id] ?? 0))
        }

        func bundleFor(type: BundleType) -> DecisionBundle? {
            let candidates = bundles.filter { bundle in
                bundle.type == type && bundle.id.hasPrefix("\(RootScope.downloads.rawValue)-")
            }
            guard !candidates.isEmpty else { return nil }

            let preferredID = preferredBundleID(for: type)
            return candidates.max { lhs, rhs in
                let lhsPreferred = lhs.id == preferredID ? 1 : 0
                let rhsPreferred = rhs.id == preferredID ? 1 : 0
                if lhsPreferred != rhsPreferred {
                    return lhsPreferred < rhsPreferred
                }

                let lhsActionable = actionableScore(for: lhs)
                let rhsActionable = actionableScore(for: rhs)
                if lhsActionable != rhsActionable {
                    return lhsActionable < rhsActionable
                }
                return lhs.createdAt < rhs.createdAt
            }
        }

        let screenshotsBundle = bundleFor(type: .weeklyScreenshots)
        let pdfBundle = bundleFor(type: .weeklyDownloadsPDF)
        let inboxBundle = bundleFor(type: .weeklyDocuments)
        let installersBundle = bundleFor(type: .weeklyInstallers)

        let screenshotsTarget = compactRoot("\(root)/Screenshots/\(month)")
        let pdfsTarget = compactRoot("\(root)/Downloads PDFs/\(month)")
        let inboxTarget = compactRoot("\(root)/Downloads Inbox/\(month)")
        let installersTotal = archiveTimeWindow == .all ? 0 : (installersBundle?.filePaths.count ?? 0)
        let installersMissing = archiveTimeWindow == .all ? 0 : (installersBundle.flatMap { missingCounts[$0.id] } ?? 0)

        return [
            RecommendedPlanBucket(
                kind: .screenshots,
                bundleID: screenshotsBundle?.id,
                title: "截图",
                destination: screenshotsTarget,
                why: "来自屏幕快照命名，且时间上集中在最近下载。",
                riskLabel: "低",
                totalFiles: screenshotsBundle?.filePaths.count ?? 0,
                missingFiles: screenshotsBundle.flatMap { missingCounts[$0.id] } ?? 0,
                actionKind: .move
            ),
            RecommendedPlanBucket(
                kind: .pdfs,
                bundleID: pdfBundle?.id,
                title: "PDF",
                destination: pdfsTarget,
                why: "最近下载的 PDF，多为课件、账单或表格。",
                riskLabel: "低",
                totalFiles: pdfBundle?.filePaths.count ?? 0,
                missingFiles: pdfBundle.flatMap { missingCounts[$0.id] } ?? 0,
                actionKind: .move
            ),
            RecommendedPlanBucket(
                kind: .inbox,
                bundleID: inboxBundle?.id,
                title: "下载区收件箱",
                destination: inboxTarget,
                why: "下载区根目录最近文件里的杂物，按类型归档。",
                riskLabel: "低",
                totalFiles: inboxBundle?.filePaths.count ?? 0,
                missingFiles: inboxBundle.flatMap { missingCounts[$0.id] } ?? 0,
                actionKind: .move
            ),
            RecommendedPlanBucket(
                kind: .installers,
                bundleID: installersBundle?.id,
                title: "安装包（.dmg/.pkg）",
                destination: "隔离区",
                why: archiveTimeWindow == .all
                    ? "首次大扫除模式：安装包本次不自动隔离。"
                    : "安装器文件用完通常可删；先隔离，随时可恢复。",
                riskLabel: "低",
                totalFiles: installersTotal,
                missingFiles: installersMissing,
                actionKind: .quarantine
            )
        ]
    }
}

private struct DashboardSnapshot {
    let digest: DigestSummary
    let bundles: [DecisionBundle]
    let bundleMissingCounts: [String: Int]
    let quarantineItems: [QuarantineItem]
    let changeLog: [ChangeLogEntry]
    let metrics: [WeeklyMetricsRow]
    let rules: [UserRule]
    let autoPurgeEnabled: Bool
    let emergencyBrakeEnabled: Bool
    let testModeEnabled: Bool
    let archiveTimeWindow: ArchiveTimeWindow
    let aiAnalyzedFilesCount: Int
    let newFilesToArchiveCount: Int
    let showNewFilesHint: Bool
    let installerReviewCandidates: [SearchResultItem]
    let pendingInboxCount: Int
    let safeCleanupQuarantineCount: Int
    let stormThreshold: Int
    let lastScanSummary: String
    let lastScanAt: Date?
    let hasArchivedAtLeastOnce: Bool
}

struct DetectedCase: Identifiable, Hashable {
    let id: String
    let name: String
    var files: [FileIntelligence]

    var presentTypes: Set<DocType> {
        Set(files.map(\.docType))
    }

    func missingDocs(for template: ChecklistTemplate) -> [DocType] {
        template.docTypes.filter { !presentTypes.contains($0) }
    }

    var totalSize: Int64 {
        0
    }
}

extension Notification.Name {
    static let aiAnalysisStarted = Notification.Name("aiAnalysisStarted")
    static let aiAnalysisFinished = Notification.Name("aiAnalysisFinished")
}

struct ArchiveOpenDestination: Identifiable, Hashable {
    let id: String
    let title: String
    let path: String
}

private extension DateFormatter {
    static let recommendedArchiveMonth: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        return formatter
    }()
}

private actor OperationLock {
    private var isLocked = false
    private var activeOperationName: String?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire(name: String) async {
        if !isLocked {
            isLocked = true
            activeOperationName = name
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
        activeOperationName = name
    }

    func release() {
        if waiters.isEmpty {
            isLocked = false
            activeOperationName = nil
            return
        }

        activeOperationName = nil
        let next = waiters.removeFirst()
        next.resume()
    }

    func currentOperationName() -> String? {
        activeOperationName
    }
}

private actor BackgroundOperationCompletionGate {
    private var completed = false

    func completeIfNeeded() -> Bool {
        if completed {
            return false
        }
        completed = true
        return true
    }
}

private extension DateFormatter {
    static let debugExportFilename: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter
    }()
}
