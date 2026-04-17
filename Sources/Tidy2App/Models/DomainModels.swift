import Foundation

enum RootScope: String, Codable, CaseIterable {
    case downloads
    case desktop
    case documents
    case archived
}

enum RiskLevel: String, Codable {
    case low
    case medium
    case high
}

enum BundleType: String, Codable {
    case weeklyDownloadsPDF
    case weeklyScreenshots
    case weeklyInstallers
    case weeklyDocuments
    case crossDirectoryGroup
}

enum BundleStatus: String, Codable {
    case pending
    case accepted
    case skipped
    case applied
}

enum BundleActionKind: String, Codable {
    case rename
    case quarantine
    case move
}

enum ArchiveTimeWindow: String, Codable, CaseIterable {
    case days7 = "7d"
    case days30 = "30d"
    case all = "all"

    var title: String {
        switch self {
        case .days7:
            return "7天"
        case .days30:
            return "30天"
        case .all:
            return "全部"
        }
    }
}

enum ActionType: String, Codable {
    case quarantineCopy
    case restore
    case rename
    case move
    case overrideRisk
    case purgeExpired
    case bundleApplyStarted = "bundle_apply_started"
    case bundleApplyFinished = "bundle_apply_finished"
}

enum FileStatus: String, Codable {
    case active
    case archived
    case quarantined
    case missing
}

enum QuarantineState: String, Codable {
    case active
    case expired
    case restored
    case deleted
    case undone
    case missing
    case cleanupCandidate
}

enum AccessHealthStatus: String, Codable {
    case ok
    case stale
    case denied
    case missing
}

enum AccessTarget: String, Codable, CaseIterable {
    case downloads
    case desktop
    case documents
    case archiveRoot
}

enum AccessActionHint: String, Codable {
    case reauthorizeDownloads
    case reauthorizeArchiveRoot
    case enableDesktop
    case enableDocuments
}

struct AccessHealthItem: Hashable {
    let target: AccessTarget
    let status: AccessHealthStatus
    let path: String?
}

// MARK: - Version file groups

struct VersionFileGroup: Identifiable {
    let id: String          // path of the newest file
    let baseName: String    // display name (newest file's filename)
    let files: [IndexedFile] // sorted newest first
    let wastedBytes: Int64  // sum of all but the newest

    var totalBytes: Int64 { files.reduce(Int64(0)) { $0 + $1.sizeBytes } }
}

enum EvidenceKind: String, Codable {
    case scopeWindowType
    case ruleMatch
    case fileSignal
    case riskHit
    case aiClassification
    case aiSuggestedFolder
    case aiAgeJudgment
    case crossDirectoryOrigin
}

struct EvidenceItem: Identifiable, Hashable, Codable {
    let id: String
    let kind: EvidenceKind
    let title: String
    let detail: String
    let supportingFileIDs: [String]?
    let supportingRuleID: String?
    let aiCategory: String?
    let aiReason: String?
    let aiSuggestedFolder: String?
    let aiConfidence: Double?
    let originScope: String?

    init(id: String,
         kind: EvidenceKind,
         title: String,
         detail: String,
         supportingFileIDs: [String]? = nil,
         supportingRuleID: String? = nil,
         aiCategory: String? = nil,
         aiReason: String? = nil,
         aiSuggestedFolder: String? = nil,
         aiConfidence: Double? = nil,
         originScope: String? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.supportingFileIDs = supportingFileIDs
        self.supportingRuleID = supportingRuleID
        self.aiCategory = aiCategory
        self.aiReason = aiReason
        self.aiSuggestedFolder = aiSuggestedFolder
        self.aiConfidence = aiConfidence
        self.originScope = originScope
    }
}

struct IndexedFile: Identifiable, Hashable {
    let id: String
    let path: String
    let rootScope: RootScope
    let name: String
    let ext: String
    let sizeBytes: Int64
    let modifiedAt: Date
    let lastSeenAt: Date
    let sha256: String?
}

struct DuplicateScanGroup: Hashable {
    let sha256: String
    let canonical: IndexedFile
    let duplicatesToQuarantine: [IndexedFile]
}

struct DuplicateScanReport: Hashable {
    let verifiedGroups: [DuplicateScanGroup]
    let sizeOnlyDuplicateCandidates: Int
}

struct DuplicateGroup: Identifiable, Hashable {
    let id: String
    let contentHash: String
    let files: [IndexedFile]

    var totalWastedBytes: Int64 {
        Int64(max(files.count - 1, 0)) * (files.first?.sizeBytes ?? 0)
    }
}

struct BundleActionConfig: Hashable, Codable {
    var actionKind: BundleActionKind
    var renameTemplate: String?
    var targetFolderBookmark: Data?
}

struct DecisionBundle: Identifiable, Hashable {
    let id: String
    let type: BundleType
    let title: String
    let summary: String
    let action: BundleActionConfig
    let evidence: [EvidenceItem]
    let risk: RiskLevel
    let filePaths: [String]
    let status: BundleStatus
    let createdAt: Date
    let snoozedUntil: Date?
    let matchedRuleID: String?

    var samplePaths: [String] {
        Array(filePaths.prefix(5))
    }
}

struct DigestSummary {
    let autoIsolatedCount: Int
    let autoIsolatedBytes: Int64
    let autoOrganizedCount: Int
    let needsDecisionCount: Int
    let lastAppliedHint: String?
    let healthStatus: String
    let maintenanceHint: String?
    let missingQuarantineCount: Int
    let expiredQuarantineCount: Int
    let missingOriginalsCount: Int
    let archiveAccessStatus: AccessHealthStatus
}

enum RecommendedPlanBucketKind: String, Hashable {
    case screenshots
    case pdfs
    case inbox
    case installers
}

struct RecommendedPlanBucket: Identifiable, Hashable {
    let kind: RecommendedPlanBucketKind
    let bundleID: String?
    let title: String
    let destination: String
    let why: String
    let riskLabel: String
    let totalFiles: Int
    let missingFiles: Int
    let actionKind: BundleActionKind

    var id: String { kind.rawValue }

    var actionableFiles: Int {
        max(0, totalFiles - missingFiles)
    }
}

struct QuarantineItem: Identifiable, Hashable {
    let id: String
    let originalPath: String
    let quarantinePath: String
    let sha256: String
    let sizeBytes: Int64
    let quarantinedAt: Date
    let state: QuarantineState
}

struct SearchFilters {
    var location: RootScope?
    var fileType: String?
    var dateFrom: Date?
    var dateTo: Date?
    var minSizeBytes: Int64? = nil
    var keywords: [String] = []
}

struct SearchResultItem: Identifiable, Hashable {
    let id: String
    let path: String
    let name: String
    let ext: String
    let sizeBytes: Int64
    let modifiedAt: Date
    let excerpt: String?
    let matchSource: String?

    init(id: String,
         path: String,
         name: String,
         ext: String,
         sizeBytes: Int64,
         modifiedAt: Date,
         excerpt: String? = nil,
         matchSource: String? = nil) {
        self.id = id
        self.path = path
        self.name = name
        self.ext = ext
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
        self.excerpt = excerpt
        self.matchSource = matchSource
    }
}

enum PendingInboxAction: String, CaseIterable {
    case keep
    case archive
    case quarantine
}

struct UndoResult {
    let txnId: String
    let requested: Int
    let succeeded: Int
    let failed: Int
    let message: String
}

struct ChangeLogEntry: Identifiable, Hashable {
    let id: String
    let createdAt: Date
    let title: String
    let detail: String
    let revealPath: String?
    let isUndone: Bool
    let isUndoable: Bool
}

struct BundleApplyOverride {
    var actionKind: BundleActionKind?
    var renameTemplate: String?
    var targetFolderBookmark: Data?
    var allowHighRiskMoveOverride: Bool = false
}

struct BundleApplyResult {
    let txnId: String
    let attempted: Int
    let succeeded: Int
    let failed: Int
    let skippedByRiskPolicy: Int
    let skippedMissing: Int
    let movedCount: Int
    let renamedCount: Int
    let quarantinedCount: Int
    let journalCount: Int
    let destinationHint: String?
    let firstError: String?
}

struct RuleMatch: Hashable {
    var bundleType: BundleType?
    var scope: RootScope?
    var fileExt: String?
    var namePattern: String?
}

struct RuleStats: Hashable {
    var matchedCount: Int
    var appliedCount: Int
}

struct UserRule: Identifiable, Hashable {
    let id: String
    let name: String
    let isEnabled: Bool
    let match: RuleMatch
    let action: BundleActionConfig
    let createdAt: Date
    let updatedAt: Date
    let stats: RuleStats
}

enum QuarantineListFilter: String, CaseIterable {
    case active
    case expired
}

struct PurgeResult {
    let txnId: String
    let attempted: Int
    let purged: Int
    let failed: Int
    let freedBytes: Int64
}

struct RuleDryRunItem: Identifiable, Hashable {
    let id: String
    let title: String
    let fileCount: Int
}

struct ConsistencyReport {
    let missingOriginals: Int
    let lowPriorityMissingOriginals: Int
    let missingQuarantineFiles: Int
    let archiveAccess: AccessHealthStatus
}

struct WeeklyMetricsRow: Identifiable, Hashable {
    var id: String { weekKey }
    let weekKey: String
    let weekStart: Date
    let weeklyConfirmCount: Int
    let confirmedFilesTotal: Int
    let undoCount: Int
    let autopilotIsolatedBytes: Int64
    let pendingBundles: Int
    let missingSkippedCount: Int
    let timeToZeroInboxDays: Double?

    var filesPerConfirm: Double {
        guard weeklyConfirmCount > 0 else { return 0 }
        return Double(confirmedFilesTotal) / Double(weeklyConfirmCount)
    }

    var undoRate: Double {
        guard weeklyConfirmCount > 0 else { return 0 }
        return Double(undoCount) / Double(weeklyConfirmCount)
    }

    var missingRate: Double {
        let denominator = confirmedFilesTotal + missingSkippedCount
        guard denominator > 0 else { return 0 }
        return Double(missingSkippedCount) / Double(denominator)
    }
}

struct AppEvent: Identifiable, Hashable, Codable {
    let id: String
    let createdAt: Date
    let eventType: String
    let message: String
    let payloadJSON: String?
}

struct JournalExportEntry: Identifiable, Hashable, Codable {
    let id: String
    let txnID: String
    let actor: String
    let actionType: String
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
