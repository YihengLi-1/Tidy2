import Foundation

final class BundleBuilder: BundleBuilderServiceProtocol {
    private struct RiskDetection {
        let level: RiskLevel
        let hitToken: String?
        let hitPath: String?
        let hitLocation: String?
    }

    private struct AIHints {
        let titleCategory: String?
        let summaryPrefix: String?
        let summarySuffix: String?
        let actionUpgrade: BundleActionKind?
        let evidence: [EvidenceItem]
    }

    private let store: SQLiteStore
    private let fileManager = FileManager.default
    private let installerMaxSizeBytes: Int64 = 300 * 1024 * 1024
    private let testModeSettingKey = "test_mode_enabled"
    private let archiveTimeWindowSettingKey = "downloads_archive_time_window"

    private let highRiskTokens: [String] = [
        "passport", "id card", "idcard", "tax", "ssn", "insurance", "driver", "license", "social security",
        "社会安全", "身份证", "护照"
    ]
    private let rulesEmergencyBrakeKey = "rules_emergency_brake"

    init(store: SQLiteStore) {
        self.store = store
    }

    func seedMockBundlesIfNeeded() throws {
        if try store.pendingBundleRawCount() > 0 {
            return
        }

        let now = Date()
        let weekKey = DateFormatter.bundleWeekKey.string(from: DateHelper.startOfCurrentWeek(now: now))
        let hasArchiveRoot = (try store.blobSetting(key: "archive_root_bookmark")) != nil
        let rules = try loadEffectiveRules()

        let seeded: [DecisionBundle] = [
            buildBundle(
                id: "downloads-weeklyDownloadsPDF-\(weekKey)",
                type: .weeklyDownloadsPDF,
                scope: .downloads,
                title: "本周下载的 PDF（下载文件夹）",
                summary: "发现 18 个本周下载的 PDF。",
                filePaths: [
                    "/Users/me/Downloads/lecture_notes_week7.pdf",
                    "/Users/me/Downloads/project_brief.pdf",
                    "/Users/me/Downloads/reading_list.pdf"
                ],
                fallbackRisk: .medium,
                timeWindowLabel: "本周",
                hasArchiveRoot: hasArchiveRoot,
                rules: rules,
                now: now
            ),
            buildBundle(
                id: "downloads-weeklyScreenshots-\(weekKey)",
                type: .weeklyScreenshots,
                scope: .downloads,
                title: "本周截图包",
                summary: "发现 26 张本周截图候选。",
                filePaths: [
                    "/Users/me/Downloads/Screenshot 2026-02-20 at 9.11.02.png",
                    "/Users/me/Downloads/Screen Shot 2026-02-19 at 08.01.10.jpg",
                    "/Users/me/Downloads/Screenshot 2026-02-18 at 14.09.52.png"
                ],
                fallbackRisk: .low,
                timeWindowLabel: "本周",
                hasArchiveRoot: hasArchiveRoot,
                rules: rules,
                now: now
            ),
            buildBundle(
                id: "downloads-weeklyInstallers-\(weekKey)",
                type: .weeklyInstallers,
                scope: .downloads,
                title: "本周安装包（下载文件夹）",
                summary: "发现 9 个安装包候选。",
                filePaths: [
                    "/Users/me/Downloads/MyApp.dmg",
                    "/Users/me/Downloads/Setup.pkg"
                ],
                fallbackRisk: .low,
                timeWindowLabel: "本周",
                hasArchiveRoot: hasArchiveRoot,
                rules: rules,
                now: now
            ),
            buildBundle(
                id: "downloads-weeklyDocuments-\(weekKey)",
                type: .weeklyDocuments,
                scope: .downloads,
                title: "本周文档混合包（PDF/DOC/TXT）",
                summary: "发现 13 份本周文档。",
                filePaths: [
                    "/Users/me/Downloads/notes.txt",
                    "/Users/me/Downloads/proposal.docx",
                    "/Users/me/Downloads/outline.pdf"
                ],
                fallbackRisk: .medium,
                timeWindowLabel: "本周",
                hasArchiveRoot: hasArchiveRoot,
                rules: rules,
                now: now
            )
        ]

        for bundle in seeded {
            try store.upsertBundle(bundle)
        }
    }

    func rebuildWeeklyBundles(scope: RootScope, now: Date) throws {
        let hasArchiveRoot = (try store.blobSetting(key: "archive_root_bookmark")) != nil
        let rules = try loadEffectiveRules()
        let allScopeFiles = try scopedFiles(scope: scope)
        var includeInstallersInInbox = false

        let windowStart: Date
        let timeWindowLabel: String
        let titlePrefix: String

        if scope == .downloads {
            let mode = try loadArchiveTimeWindow()
            switch mode {
            case .days7:
                windowStart = Calendar.current.date(byAdding: .day, value: -7, to: now) ?? DateHelper.startOfCurrentWeek(now: now)
                timeWindowLabel = "最近 7 天"
                titlePrefix = "下载文件夹 · 最近 7 天"
            case .days30:
                windowStart = Calendar.current.date(byAdding: .day, value: -30, to: now) ?? DateHelper.startOfCurrentWeek(now: now)
                timeWindowLabel = "最近 30 天"
                titlePrefix = "下载文件夹 · 最近 30 天"
            case .all:
                windowStart = Date.distantPast
                timeWindowLabel = "全部文件"
                titlePrefix = "下载文件夹 · 全部"
                includeInstallersInInbox = true
            }
        } else if scope == .documents {
            windowStart = Calendar.current.date(byAdding: .day, value: -30, to: now) ?? DateHelper.startOfCurrentWeek(now: now)
            timeWindowLabel = "最近 30 天"
            titlePrefix = "文稿文件夹 · 最近 30 天"
        } else {
            windowStart = DateHelper.startOfCurrentWeek(now: now)
            timeWindowLabel = "本周"
            titlePrefix = "桌面 · 本周"
        }

        let files = allScopeFiles
            .filter { $0.modifiedAt >= windowStart }
        let existingFiles = files.filter { fileManager.fileExists(atPath: $0.path) }

        let pdfFiles = existingFiles.filter { $0.ext == "pdf" }.map(\.path)
        let imageFiles = existingFiles
            .filter { isScreenshotCandidate($0) }
            .map(\.path)
        let installerFiles = scope == .downloads
            ? (includeInstallersInInbox ? [] : existingFiles.filter { isInstallerCandidate($0) }.map(\.path))
            : []
        let mixedCandidates = existingFiles
            .filter { file in
                !isScreenshotCandidate(file) && file.ext != "pdf" && (includeInstallersInInbox || !isInstallerCandidate(file))
            }
        let mixedFiles: [String]
        if scope == .downloads, let rootPath = try downloadsScopeRootPath() {
            mixedFiles = mixedCandidates
                .filter { isDirectChild(path: $0.path, rootPath: rootPath) }
                .map(\.path)
        } else {
            mixedFiles = mixedCandidates.map(\.path)
        }

        let pdfBundleID = scope == .downloads
            ? "\(scope.rawValue)-inbox30d-\(BundleType.weeklyDownloadsPDF.rawValue)"
            : "\(scope.rawValue)-\(BundleType.weeklyDownloadsPDF.rawValue)-\(DateFormatter.bundleWeekKey.string(from: windowStart))"
        let screenshotBundleID = scope == .downloads
            ? "\(scope.rawValue)-inbox30d-\(BundleType.weeklyScreenshots.rawValue)"
            : "\(scope.rawValue)-\(BundleType.weeklyScreenshots.rawValue)-\(DateFormatter.bundleWeekKey.string(from: windowStart))"
        let mixedBundleID = scope == .downloads
            ? "\(scope.rawValue)-inbox30d-\(BundleType.weeklyDocuments.rawValue)"
            : "\(scope.rawValue)-\(BundleType.weeklyDocuments.rawValue)-\(DateFormatter.bundleWeekKey.string(from: windowStart))"
        let installerBundleID = scope == .downloads
            ? "\(scope.rawValue)-inbox30d-\(BundleType.weeklyInstallers.rawValue)"
            : "\(scope.rawValue)-\(BundleType.weeklyInstallers.rawValue)-\(DateFormatter.bundleWeekKey.string(from: windowStart))"

        var built: [DecisionBundle] = [
            buildBundle(
                id: pdfBundleID,
                type: .weeklyDownloadsPDF,
                scope: scope,
                title: "\(titlePrefix) · PDF 文件",
                summary: "Found \(pdfFiles.count) PDF files in \(timeWindowLabel).",
                filePaths: pdfFiles,
                fallbackRisk: .medium,
                timeWindowLabel: timeWindowLabel,
                hasArchiveRoot: hasArchiveRoot,
                rules: rules,
                now: now
            ),
            buildBundle(
                id: screenshotBundleID,
                type: .weeklyScreenshots,
                scope: scope,
                title: "\(titlePrefix) · 截图",
                summary: "Found \(imageFiles.count) image files in \(timeWindowLabel).",
                filePaths: imageFiles,
                fallbackRisk: .low,
                timeWindowLabel: timeWindowLabel,
                hasArchiveRoot: hasArchiveRoot,
                rules: rules,
                now: now
            ),
            buildBundle(
                id: mixedBundleID,
                type: .weeklyDocuments,
                scope: scope,
                title: "\(titlePrefix) · 杂项文件",
                summary: "Found \(mixedFiles.count) other files in \(timeWindowLabel).",
                filePaths: mixedFiles,
                fallbackRisk: .medium,
                timeWindowLabel: timeWindowLabel,
                hasArchiveRoot: hasArchiveRoot,
                rules: rules,
                now: now
            ),
        ]

        if scope == .downloads {
            built.append(
                buildBundle(
                    id: installerBundleID,
                    type: .weeklyInstallers,
                    scope: scope,
                    title: "\(titlePrefix) · 安装包",
                    summary: "Found \(installerFiles.count) installer files in \(timeWindowLabel).",
                    filePaths: installerFiles,
                    fallbackRisk: .low,
                    timeWindowLabel: timeWindowLabel,
                    hasArchiveRoot: hasArchiveRoot,
                    rules: rules,
                    now: now
                )
            )
        }

        var upsertedCount = 0
        for bundle in built where !bundle.filePaths.isEmpty {
            try store.upsertBundle(bundle)
            upsertedCount += 1
        }

        for bundle in built where bundle.filePaths.isEmpty {
            try store.deleteBundle(id: bundle.id)
        }

        if scope != .downloads {
            try store.deleteBundle(id: installerBundleID)
        }

        // Remove legacy/stale pending bundles for this scope so Home plan binds to current IDs.
        let activeIDs = Set(built.map(\.id))
        let pending = try store.loadPendingBundles(limit: 300, now: now)
        for bundle in pending {
            guard bundle.id.hasPrefix("\(scope.rawValue)-") else { continue }
            guard bundle.type == .weeklyDownloadsPDF
                || bundle.type == .weeklyScreenshots
                || bundle.type == .weeklyDocuments
                || bundle.type == .weeklyInstallers else {
                continue
            }
            if !activeIDs.contains(bundle.id) {
                try store.deleteBundle(id: bundle.id)
            }
        }

        // Cross-directory grouping is global; run it once after the downloads pass.
        if scope == .downloads {
            try buildCrossDirectoryBundles(now: now)
        }
    }

    // MARK: - Cross-directory bundle building

    private func buildCrossDirectoryBundles(now: Date) throws {
        let groups = try store.crossDirectoryFileGroups()
        guard !groups.isEmpty else { return }

        // Load existing pending cross-directory bundle titles to avoid duplicates.
        let existingPending = try store.loadPendingBundles(limit: 200, now: now)
        let existingCDTitles: Set<String> = Set(
            existingPending
                .filter { $0.type == .crossDirectoryGroup && ($0.status == .pending || $0.status == .applied) }
                .map(\.title)
        )

        for group in groups {
            let leaf = URL(fileURLWithPath: group.suggestedFolder).lastPathComponent
            let title = "🗂 \(group.category) · \(leaf)"
            guard !existingCDTitles.contains(title) else { continue }

            let filePaths = group.files.map(\.path)
            let scopeCount = Set(group.files.map(\.rootScope)).count
            let summary = "发现 \(group.files.count) 个文件分散在 \(scopeCount) 个位置，AI 建议整理到同一文件夹 · 目标: \(group.suggestedFolder)"

            // Build per-file evidence items (crossDirectoryOrigin)
            var evidence: [EvidenceItem] = []
            for file in group.files {
                let humanScope: String
                switch file.rootScope {
                case "downloads":  humanScope = "下载"
                case "desktop":    humanScope = "桌面"
                case "documents":  humanScope = "文稿"
                default:           humanScope = "归档"
                }
                evidence.append(EvidenceItem(
                    id: UUID().uuidString,
                    kind: .crossDirectoryOrigin,
                    title: "\(file.name).\(file.ext)",
                    detail: file.aiSummary,
                    aiSuggestedFolder: group.suggestedFolder,
                    aiConfidence: file.aiConfidence,
                    originScope: humanScope
                ))
            }

            let bundleID = "crossdir-\(group.suggestedFolder.replacingOccurrences(of: "/", with: "-").prefix(40))-\(DateFormatter.bundleWeekKey.string(from: now))"
            let bundle = DecisionBundle(
                id: bundleID,
                type: .crossDirectoryGroup,
                title: title,
                summary: summary,
                action: BundleActionConfig(actionKind: .move, renameTemplate: nil, targetFolderBookmark: nil),
                evidence: evidence,
                risk: .low,
                filePaths: filePaths,
                status: .pending,
                createdAt: now,
                snoozedUntil: nil,
                matchedRuleID: nil
            )
            try store.upsertBundle(bundle)
        }

        // Clean up stale cross-directory bundles whose suggested folders no longer have enough files.
        let currentTitles = Set(groups.map { "🗂 \($0.category) · \(URL(fileURLWithPath: $0.suggestedFolder).lastPathComponent)" })
        let allPending = try store.loadPendingBundles(limit: 200, now: now)
        for bundle in allPending where bundle.type == .crossDirectoryGroup && bundle.status == .pending {
            if !currentTitles.contains(bundle.title) {
                try store.deleteBundle(id: bundle.id)
            }
        }
    }

    func pendingBundles(limit: Int) throws -> [DecisionBundle] {
        let candidates = try store.loadPendingBundles(limit: max(limit * 4, 20))
        return candidates
            .sorted { impactScore(for: $0) > impactScore(for: $1) }
            .prefix(limit)
            .map { $0 }
    }

    private func buildBundle(id: String,
                             type: BundleType,
                             scope: RootScope,
                             title: String,
                             summary: String,
                             filePaths: [String],
                             fallbackRisk: RiskLevel,
                             timeWindowLabel: String,
                             hasArchiveRoot: Bool,
                             rules: [UserRule],
                             now: Date) -> DecisionBundle {
        let riskDetection = calculateRisk(filePaths: filePaths, fallback: fallbackRisk)

        var action = BundleActionConfig(
            actionKind: recommendedAction(type: type, risk: riskDetection.level),
            renameTemplate: defaultRenameTemplate(for: type),
            targetFolderBookmark: nil
        )

        var matchedRuleID: String?
        var evidence = makeDefaultEvidence(
            type: type,
            scope: scope,
            filePaths: filePaths,
            timeWindowLabel: timeWindowLabel
        )
        var finalTitle = title
        var finalSummary = summary

        if let matchedRule = bestMatchedRule(for: type, scope: scope, filePaths: filePaths, rules: rules) {
            action.actionKind = matchedRule.action.actionKind
            action.renameTemplate = matchedRule.action.renameTemplate
            action.targetFolderBookmark = matchedRule.action.targetFolderBookmark
            matchedRuleID = matchedRule.id
            try? store.incrementRuleMatchedCount(ruleID: matchedRule.id)

            evidence.insert(
                EvidenceItem(
                    id: UUID().uuidString,
                    kind: .ruleMatch,
                    title: "Matched your rule: \(matchedRule.name)",
                    detail: ruleSummary(matchedRule),
                    supportingFileIDs: nil,
                    supportingRuleID: matchedRule.id
                ),
                at: 0
            )
        }

        if let aiHints = makeAIHints(
            filePaths: filePaths,
            type: type,
            now: now,
            currentAction: action.actionKind,
            risk: riskDetection.level
        ) {
            if let upgradedAction = aiHints.actionUpgrade, riskDetection.level != .high {
                action.actionKind = upgradedAction
            }
            if let titleCategory = aiHints.titleCategory, !titleCategory.isEmpty {
                finalTitle += " · \(titleCategory)"
            }
            if let summaryPrefix = aiHints.summaryPrefix, !summaryPrefix.isEmpty {
                finalSummary = summaryPrefix + finalSummary
            }
            if let summarySuffix = aiHints.summarySuffix, !summarySuffix.isEmpty {
                finalSummary += summarySuffix
            }
            evidence = aiHints.evidence + evidence
        }

        if action.actionKind == .move && !hasArchiveRoot && action.targetFolderBookmark == nil {
            evidence.insert(
                EvidenceItem(
                    id: UUID().uuidString,
                    kind: .ruleMatch,
                    title: "需要整理文件夹",
                    detail: "需要先设置整理文件夹才能执行移动。",
                    supportingFileIDs: nil,
                    supportingRuleID: nil
                ),
                at: 0
            )
        }

        if riskDetection.level == .high,
           let token = riskDetection.hitToken,
           let path = riskDetection.hitPath,
           let location = riskDetection.hitLocation {
            let fileID = try? store.fileID(path: path)
            evidence.insert(
                EvidenceItem(
                    id: UUID().uuidString,
                    kind: .riskHit,
                    title: "High-risk token matched",
                    detail: "命中词 '\(token)'（位置：\(location)）→ \(path)",
                    supportingFileIDs: fileID.map { [$0] },
                    supportingRuleID: nil
                ),
                at: 0
            )
        }

        let existing = try? store.loadBundleState(id: id)
        let previousFileSet = Set((try? store.loadBundleItems(bundleID: id)) ?? [])
        let currentFileSet = Set(filePaths)
        let fileSetChanged = previousFileSet != currentFileSet
        var status: BundleStatus = .pending
        var snoozedUntil: Date?

        if let existing {
            switch existing.status {
            case .skipped:
                // Keep snooze only when bundle payload stays the same.
                if let until = existing.snoozedUntil, until > now, !fileSetChanged {
                    status = .skipped
                    snoozedUntil = until
                } else {
                    status = .pending
                }
            case .accepted, .applied, .pending:
                // Any regenerated non-empty bundle should become actionable again.
                status = .pending
            }
        }

        return DecisionBundle(
            id: id,
            type: type,
            title: finalTitle,
            summary: finalSummary,
            action: action,
            evidence: evidence,
            risk: riskDetection.level,
            filePaths: filePaths,
            status: status,
            createdAt: now,
            snoozedUntil: snoozedUntil,
            matchedRuleID: matchedRuleID
        )
    }

    private func makeAIHints(filePaths: [String],
                             type: BundleType,
                             now: Date,
                             currentAction: BundleActionKind,
                             risk: RiskLevel) -> AIHints? {
        let intelligenceMap = (try? store.loadFileIntelligences(paths: filePaths)) ?? [:]
        guard !intelligenceMap.isEmpty else { return nil }

        let intelligences = filePaths.compactMap { intelligenceMap[$0] }
        guard !intelligences.isEmpty else { return nil }

        var evidence: [EvidenceItem] = []
        var titleCategory: String?
        var summaryPrefix: String?
        var summarySuffix: String?
        var actionUpgrade: BundleActionKind?

        let categoryCounts = Dictionary(grouping: intelligences, by: \.category)
        if let bestCategory = categoryCounts.max(by: { $0.value.count < $1.value.count }) {
            let matchCount = bestCategory.value.count
            let ratio = Double(matchCount) / Double(intelligences.count)
            let supportingIDs = filePaths.compactMap { path in
                intelligenceMap[path]?.category == bestCategory.key ? (try? store.fileID(path: path)) : nil
            }
            let strongest = bestCategory.value.max(by: { $0.confidence < $1.confidence })
            evidence.append(
                EvidenceItem(
                    id: UUID().uuidString,
                    kind: .aiClassification,
                    title: "AI 分类: \(bestCategory.key) (\(matchCount) 个文件)",
                    detail: strongest?.reason ?? strongest?.summary ?? "AI 认为这一组文件属于同一类型。",
                    supportingFileIDs: supportingIDs.isEmpty ? nil : supportingIDs,
                    supportingRuleID: nil,
                    aiCategory: bestCategory.key,
                    aiReason: strongest?.reason,
                    aiSuggestedFolder: optionalSuggestedFolder(strongest?.suggestedFolder),
                    aiConfidence: strongest?.confidence
                )
            )
            if ratio >= 0.6 {
                titleCategory = bestCategory.key
            }
        }

        let folders = intelligences.filter { !$0.suggestedFolder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let folderCounts = Dictionary(grouping: folders, by: { normalizedSuggestedFolder($0.suggestedFolder) })
        if let bestFolder = folderCounts.max(by: { $0.value.count < $1.value.count }) {
            let ratio = Double(bestFolder.value.count) / Double(intelligences.count)
            if ratio >= 0.5 {
                let strongest = bestFolder.value.max(by: { $0.confidence < $1.confidence })
                evidence.append(
                    EvidenceItem(
                        id: UUID().uuidString,
                        kind: .aiSuggestedFolder,
                        title: "AI 建议位置: \(bestFolder.key)",
                        detail: strongest?.reason ?? "多数文件建议归到同一路径。",
                        supportingFileIDs: nil,
                        supportingRuleID: nil,
                        aiCategory: strongest?.category,
                        aiReason: strongest?.reason,
                        aiSuggestedFolder: bestFolder.key,
                        aiConfidence: strongest?.confidence
                    )
                )
                if currentAction == .rename && risk != .high {
                    actionUpgrade = .move
                    summarySuffix = " · AI 建议归档到 \(bestFolder.key)"
                }
            }
        }

        let deleteVotes = intelligences.filter { $0.keepOrDelete == .delete }
        let freshFiles = filePaths.compactMap { try? store.fileByPath($0) }
        let underOneYearCount = freshFiles.filter { now.timeIntervalSince($0.modifiedAt) < 365 * 86_400 }.count
        if !deleteVotes.isEmpty,
           deleteVotes.count * 2 > intelligences.count,
           underOneYearCount * 2 >= filePaths.count {
            let strongestDelete = deleteVotes.max(by: { $0.confidence < $1.confidence })
            evidence.append(
                EvidenceItem(
                    id: UUID().uuidString,
                    kind: .aiAgeJudgment,
                    title: "AI 建议清理: 多数文件已过期或可删除",
                    detail: strongestDelete?.reason ?? "AI 认为这组文件更像临时内容或处理完即可删除。",
                    supportingFileIDs: nil,
                    supportingRuleID: nil,
                    aiCategory: strongestDelete?.category,
                    aiReason: strongestDelete?.reason,
                    aiSuggestedFolder: optionalSuggestedFolder(strongestDelete?.suggestedFolder),
                    aiConfidence: strongestDelete?.confidence
                )
            )
            if type == .weeklyInstallers || type == .weeklyScreenshots {
                summaryPrefix = "⚠️ AI 建议清理 · "
            }
        }

        guard !evidence.isEmpty || titleCategory != nil || summaryPrefix != nil || summarySuffix != nil || actionUpgrade != nil else {
            return nil
        }

        return AIHints(
            titleCategory: titleCategory,
            summaryPrefix: summaryPrefix,
            summarySuffix: summarySuffix,
            actionUpgrade: actionUpgrade,
            evidence: evidence
        )
    }

    private func bestMatchedRule(for type: BundleType, scope: RootScope, filePaths: [String], rules: [UserRule]) -> UserRule? {
        let matched = rules.filter { rule in
            guard rule.isEnabled else { return false }
            if let matchType = rule.match.bundleType, matchType != type {
                return false
            }
            if let matchScope = rule.match.scope, matchScope != scope {
                return false
            }
            if let ext = rule.match.fileExt?.lowercased(), !ext.isEmpty {
                let hasExt = filePaths.contains {
                    URL(fileURLWithPath: $0).pathExtension.lowercased() == ext
                }
                if !hasExt { return false }
            }
            if let pattern = rule.match.namePattern?.lowercased(), !pattern.isEmpty {
                let hasPattern = filePaths.contains {
                    URL(fileURLWithPath: $0).lastPathComponent.lowercased().contains(pattern)
                }
                if !hasPattern { return false }
            }
            return true
        }

        return matched.max { lhs, rhs in
            let lScore = ruleSpecificity(lhs)
            let rScore = ruleSpecificity(rhs)
            if lScore == rScore {
                return lhs.updatedAt < rhs.updatedAt
            }
            return lScore < rScore
        }
    }

    private func ruleSpecificity(_ rule: UserRule) -> Int {
        var score = 0
        if rule.match.bundleType != nil { score += 1 }
        if rule.match.scope != nil { score += 1 }
        if let ext = rule.match.fileExt, !ext.isEmpty { score += 1 }
        if let pattern = rule.match.namePattern, !pattern.isEmpty { score += 1 }
        return score
    }

    private func ruleSummary(_ rule: UserRule) -> String {
        var parts: [String] = []
        if let bundleType = rule.match.bundleType {
            parts.append("bundle=\(bundleType.rawValue)")
        }
        if let scope = rule.match.scope {
            parts.append("scope=\(scope.rawValue)")
        }
        if let ext = rule.match.fileExt, !ext.isEmpty {
            parts.append("ext=\(ext)")
        }
        if let pattern = rule.match.namePattern, !pattern.isEmpty {
            parts.append("name contains '\(pattern)'")
        }
        parts.append("action=\(rule.action.actionKind.rawValue)")
        return parts.joined(separator: " · ")
    }

    private func normalizedSuggestedFolder(_ folder: String) -> String {
        folder
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func optionalSuggestedFolder(_ folder: String?) -> String? {
        guard let folder else { return nil }
        let normalized = normalizedSuggestedFolder(folder)
        return normalized.isEmpty ? nil : normalized
    }

    private func makeDefaultEvidence(type: BundleType,
                                     scope: RootScope,
                                     filePaths: [String],
                                     timeWindowLabel: String) -> [EvidenceItem] {
        let scopeLabel = scope.rawValue
        let typeLabel: String
        switch type {
        case .weeklyDownloadsPDF:
            typeLabel = "PDF"
        case .weeklyScreenshots:
            typeLabel = "Screenshot images"
        case .weeklyInstallers:
            typeLabel = "DMG/PKG"
        case .weeklyDocuments:
            typeLabel = scope == .downloads ? "Mixed files" : "PDF/DOC/TXT"
        case .crossDirectoryGroup:
            typeLabel = "Cross-directory group"
        }

        var evidence: [EvidenceItem] = [
            EvidenceItem(
                id: UUID().uuidString,
                kind: .scopeWindowType,
                title: "Grouping rule",
                detail: "目录：\(scopeLabel) · 时间：\(timeWindowLabel) · 类型：\(typeLabel)",
                supportingFileIDs: nil,
                supportingRuleID: nil
            ),
            EvidenceItem(
                id: UUID().uuidString,
                kind: .ruleMatch,
                title: "Rule source",
                detail: "按目录 + 时间窗口 + 类型聚合，不用关键词做强分组。",
                supportingFileIDs: nil,
                supportingRuleID: nil
            )
        ]

        if let samplePath = filePaths.first {
            let sampleDate = (try? fileManager.attributesOfItem(atPath: samplePath)[.modificationDate] as? Date) ?? Date()
            let fileID = try? store.fileID(path: samplePath)
            evidence.append(
                EvidenceItem(
                    id: UUID().uuidString,
                    kind: .fileSignal,
                    title: "Sample file",
                    detail: "\(samplePath) · mtime \(DateFormatter.bundleEvidenceDate.string(from: sampleDate))",
                    supportingFileIDs: fileID.map { [$0] },
                    supportingRuleID: nil
                )
            )
        }

        return evidence
    }

    private func recommendedAction(type: BundleType, risk: RiskLevel) -> BundleActionKind {
        if risk == .high {
            return .rename
        }

        switch type {
        case .weeklyDownloadsPDF, .weeklyScreenshots:
            return .move
        case .weeklyInstallers:
            return .quarantine
        case .weeklyDocuments:
            return .rename
        case .crossDirectoryGroup:
            return .move
        }
    }

    private func defaultRenameTemplate(for type: BundleType) -> String {
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

    private func calculateRisk(filePaths: [String], fallback: RiskLevel) -> RiskDetection {
        guard !filePaths.isEmpty else {
            return RiskDetection(level: fallback, hitToken: nil, hitPath: nil, hitLocation: nil)
        }

        for path in filePaths {
            let fileName = URL(fileURLWithPath: path).lastPathComponent.lowercased()
            if let token = highRiskTokens.first(where: { containsRiskToken($0, in: fileName) }) {
                return RiskDetection(level: .high, hitToken: token, hitPath: path, hitLocation: "filename")
            }
        }

        for path in filePaths {
            let lowerPath = path.lowercased()
            if let token = highRiskTokens.first(where: { containsRiskToken($0, in: lowerPath) }) {
                return RiskDetection(level: .high, hitToken: token, hitPath: path, hitLocation: "path")
            }
        }

        return RiskDetection(level: fallback, hitToken: nil, hitPath: nil, hitLocation: nil)
    }

    private func containsRiskToken(_ token: String, in text: String) -> Bool {
        let asciiToken = token.range(of: #"^[a-z0-9 ]+$"#, options: .regularExpression) != nil
        guard asciiToken else {
            return text.contains(token)
        }

        let escaped = NSRegularExpression.escapedPattern(for: token)
        let pattern = "(^|[^a-z0-9])\(escaped)([^a-z0-9]|$)"
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    private func impactScore(for bundle: DecisionBundle) -> Double {
        var sizeTotal: Double = 0
        for path in bundle.filePaths {
            if let attr = try? fileManager.attributesOfItem(atPath: path),
               let bytes = attr[.size] as? NSNumber {
                sizeTotal += bytes.doubleValue
            }
        }

        let riskPenalty: Double
        switch bundle.risk {
        case .low:
            riskPenalty = 0
        case .medium:
            riskPenalty = 2
        case .high:
            riskPenalty = 5
        }

        let snoozedPenalty = bundle.snoozedUntil == nil ? 0.0 : 1.5
        return Double(bundle.filePaths.count) + log(max(sizeTotal, 1.0)) - riskPenalty - snoozedPenalty
    }

    private func isScreenshotCandidate(_ file: IndexedFile) -> Bool {
        let imageExtensions = Set(["png", "jpg", "jpeg"])
        guard imageExtensions.contains(file.ext) else { return false }
        let name = file.name.lowercased()
        return name.contains("screenshot") || name.contains("screen shot")
    }

    private func isInstallerCandidate(_ file: IndexedFile) -> Bool {
        guard file.sizeBytes <= installerMaxSizeBytes else { return false }
        switch file.ext {
        case "dmg", "pkg":
            return true
        default:
            return false
        }
    }

    private func isDirectChild(path: String, rootPath: String) -> Bool {
        let fileParent = URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL.path
        let normalizedRoot = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        return fileParent == normalizedRoot
    }

    private func loadEffectiveRules() throws -> [UserRule] {
        let brakeRaw = try store.stringSetting(key: rulesEmergencyBrakeKey) ?? "0"
        if brakeRaw == "1" || brakeRaw.lowercased() == "true" {
            return []
        }
        return try store.listEnabledRules()
    }

    private func loadArchiveTimeWindow() throws -> ArchiveTimeWindow {
        let raw = try store.stringSetting(key: archiveTimeWindowSettingKey) ?? ArchiveTimeWindow.all.rawValue
        return ArchiveTimeWindow(rawValue: raw) ?? .all
    }

    private func downloadsScopeRootPath() throws -> String? {
        guard let downloads = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            return nil
        }
        let raw = try store.stringSetting(key: testModeSettingKey) ?? "0"
        if raw == "1" || raw.lowercased() == "true" {
            return downloads.appendingPathComponent("TidyTest", isDirectory: true).standardizedFileURL.path
        }
        return downloads.standardizedFileURL.path
    }

    private func scopedFiles(scope: RootScope) throws -> [IndexedFile] {
        let files = try store.listFiles(scope: scope)
        guard scope == .downloads else { return files }
        let raw = try store.stringSetting(key: testModeSettingKey) ?? "0"
        guard raw == "1" || raw.lowercased() == "true" else { return files }

        guard let downloads = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            return files
        }
        let testRootPath = downloads.appendingPathComponent("TidyTest", isDirectory: true).standardizedFileURL.path
        return files.filter { file in
            let path = URL(fileURLWithPath: file.path).standardizedFileURL.path
            return path == testRootPath || path.hasPrefix(testRootPath + "/")
        }
    }
}

private extension DateFormatter {
    static let bundleWeekKey: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        return formatter
    }()

    static let bundleEvidenceDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}
