import SwiftUI

struct DigestView: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage("hasRunFullHistoryScan") private var hasRunFullHistoryScan = false

    @State private var showAutoCleanConfirm = false
    @State private var isAutoCleaningDuplicates = false
    @State private var autoCleanSuccessMessage: String? = nil
    @State private var scanCompleteMessage: String? = nil
    @State private var scanWasRunning = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                // ── Success banner (shown after auto-clean even when card disappears) ──
                if let msg = autoCleanSuccessMessage {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(msg)
                            .font(.subheadline.weight(.medium))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.green.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if let msg = scanCompleteMessage {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(msg)
                            .font(.subheadline.weight(.medium))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.green.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                // ── Action Cards ──────────────────────────────────────
                if appState.isBusy {
                    scanningCard
                } else if appState.totalFilesScanned == 0 {
                    scanPromptCard
                } else {
                    if appState.duplicateGroups.count > 0 && appState.duplicatesTotalWastedBytes > 20_000_000 {
                        duplicateCard
                    }
                    if appState.bundles.count > 0 {
                        bundleCard
                    }
                    if !appState.detectedCases.isEmpty {
                        casesCard
                    }
                    if appState.largeTotalBytes > 50_000_000 {
                        largeFilesCard
                    }
                    if appState.duplicateGroups.count == 0 &&
                        appState.bundles.count == 0 &&
                        appState.largeTotalBytes <= 50_000_000 &&
                        appState.oldInstallers.isEmpty &&
                        autoCleanSuccessMessage == nil {
                        cleanCard
                    }
                }

                if !hasRunFullHistoryScan && appState.totalFilesScanned > 0 {
                    historyBacklogCard
                }

                // ── Footer stats line ─────────────────────────────────
                footerStatsLine

                // ── Last operation summary ────────────────────────────
                if let summary = latestOperationSummary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // ── AI status line ────────────────────────────────────
                aiStatusLine
            }
            .padding(24)
        }
        .navigationTitle("首页")
        .confirmationDialog(
            "确认一键清理",
            isPresented: $showAutoCleanConfirm,
            titleVisibility: .visible
        ) {
            Button("确认清理 \(SizeFormatter.string(from: appState.duplicatesTotalWastedBytes))", role: .destructive) {
                performAutoClean()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除 \(toDeleteCount) 个重复文件，每组保留最新版本，共释放 \(SizeFormatter.string(from: appState.duplicatesTotalWastedBytes))。文件移到废纸篓，可随时恢复。")
        }
        .onAppear {
            scanWasRunning = appState.isBusy && appState.statusMessage.contains("扫描")
            Task {
                await appState.refreshAIAnalysisState()
            }
        }
        .onChange(of: appState.isBusy) { newValue in
            handleBusyStateChange(newValue)
        }
        .task {
            await appState.loadLargeFiles()
            await appState.loadDetectedCases()
        }
    }

    // MARK: - Cards

    private var duplicateCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "doc.on.doc.fill")
                    .foregroundStyle(.orange)
                Text("发现 \(appState.duplicateGroups.count) 组重复文件，可释放 \(SizeFormatter.string(from: appState.duplicatesTotalWastedBytes))")
                    .font(.subheadline.weight(.semibold))
            }
            Text("每组保留最新版本，其余全部移到废纸篓（可从废纸篓恢复）")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button {
                    showAutoCleanConfirm = true
                } label: {
                    if isAutoCleaningDuplicates {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("清理中...")
                        }
                    } else {
                        Text("一键清理 \(SizeFormatter.string(from: appState.duplicatesTotalWastedBytes))")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(isAutoCleaningDuplicates)

                Button("手动选择") {
                    appState.openDuplicates()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var bundleCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "folder.badge.gearshape")
                    .foregroundStyle(.green)
                Text("\(appState.bundles.count) 条整理建议等待确认")
                    .font(.subheadline.weight(.semibold))
            }
            Text("AI 扫描后生成的文件归档方案，确认后立即执行")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("逐条确认") {
                appState.openBundles()
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var scanPromptCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass.circle.fill")
                    .foregroundStyle(.blue)
                Text("扫描一下你的文件，Tidy 会帮你找出可整理的内容")
                    .font(.subheadline.weight(.semibold))
            }
            Button("开始扫描") {
                appState.scanButtonTappedFromHome()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var scanningCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                let detail = appState.scanProgressDetail.trimmingCharacters(in: .whitespacesAndNewlines)
                Text(detail.isEmpty ? "正在扫描..." : detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text("已发现 \(appState.totalFilesScanned) 个文件")
                .font(.caption)
                .foregroundStyle(.secondary)

            if appState.totalFilesScanned > 0 {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var cleanCard: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("一切井井有条")
                .font(.title2.weight(.semibold))
            Text("没有待处理的文件，Tidy 会在后台继续为你守候。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(40)
        .background(Color.green.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var largeFilesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "externaldrive.badge.minus")
                    .foregroundStyle(.blue)
                Text("发现 \(appState.largeFiles.count) 个大文件，共 \(SizeFormatter.string(from: appState.largeTotalBytes))")
                    .font(.subheadline.weight(.semibold))
            }
            Text("单个文件超过 50MB，可能是旧备份或未使用的安装包")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("查看大文件") {
                appState.openCleanup()
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var casesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "person.2.fill")
                    .foregroundStyle(.purple)
                Text("识别到 \(appState.detectedCases.count) 个案例文件夹")
                    .font(.headline)
            }

            ForEach(Array(appState.detectedCases.prefix(2))) { cas in
                HStack(spacing: 6) {
                    Image(systemName: "person.crop.circle")
                        .foregroundStyle(.secondary)
                    Text(cas.name)
                        .font(.subheadline)
                    Spacer()
                    Text("\(cas.files.count) 份文件")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    caseMissingBadge(for: cas)
                }
            }

            if appState.detectedCases.count > 2 {
                Text("还有 \(appState.detectedCases.count - 2) 个案例…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("查看所有案例") {
                appState.pendingTab = .cases
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(16)
        .background(Color.purple.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var historyBacklogCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("🗂")
                Text("还没整理过历史积压？")
                    .font(.subheadline.weight(.semibold))
            }

            Text("扫描全部下载文件夹，发现多年来积压的 PDF、截图和安装包")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("扫一次历史文件 →") {
                hasRunFullHistoryScan = true
                Task {
                    await appState.runFullHistoryScan()
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
            .disabled(appState.isBusy)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.purple.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Footer

    private var footerStatsLine: some View {
        HStack(spacing: 6) {
            Text("\(appState.totalFilesScanned) 个文件")
            Text("·")
            Text("\(appState.duplicateGroups.count) 组重复")
            Text("·")
            Text("AI 已分析 \(appState.aiAnalyzedFilesCount) 个")
            Text("·")
            Text("大文件 \(SizeFormatter.string(from: appState.largeTotalBytes))")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    // MARK: - Helpers

    private var toDeleteCount: Int {
        appState.duplicateGroups.reduce(0) { $0 + max($1.files.count - 1, 0) }
    }

    private func performAutoClean() {
        isAutoCleaningDuplicates = true
        Task {
            let result = await appState.autoCleanDuplicates()
            await appState.loadDuplicateGroups()
            await appState.loadLargeFiles()
            isAutoCleaningDuplicates = false
            autoCleanSuccessMessage = "✓ 已清理 \(result.deleted) 个文件，释放了 \(SizeFormatter.string(from: result.freedBytes))"
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            autoCleanSuccessMessage = nil
        }
    }

    private func handleBusyStateChange(_ isBusy: Bool) {
        if isBusy {
            let detail = appState.scanProgressDetail.trimmingCharacters(in: .whitespacesAndNewlines)
            let status = appState.statusMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.contains("扫描") || status.contains("扫描") {
                scanWasRunning = true
            }
            return
        }

        if scanWasRunning && appState.totalFilesScanned > 0 {
            let message = "✓ 扫描完成：\(appState.totalFilesScanned) 个文件，发现 \(appState.duplicateGroups.count) 组重复"
            scanCompleteMessage = message
            scanWasRunning = false

            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await MainActor.run {
                    if scanCompleteMessage == message {
                        scanCompleteMessage = nil
                    }
                }
            }
        } else {
            scanWasRunning = false
        }
    }

    private var latestOperationSummary: String? {
        guard let entry = appState.changeLogEntries.first else { return nil }
        return "上次操作：\(localizedChangeTitle(entry.title)) · \(DateHelper.relativeShort(entry.createdAt))"
    }

    private func localizedChangeTitle(_ title: String) -> String {
        if title.contains("已移动") || title.contains("已重命名") || title.contains("已隔离") || title.contains("整理完成") {
            return title
        }
        if let count = extractCount(from: title, prefix: "Moved ") {
            return "移动了 \(count) 个文件"
        }
        if let count = extractCount(from: title, prefix: "Renamed ") {
            return "重命名了 \(count) 个文件"
        }
        if let count = extractCount(from: title, prefix: "Quarantined ") {
            return "隔离了 \(count) 个文件"
        }
        if let count = extractCount(from: title, prefix: "Purged ") {
            return "清理了 \(count) 个过期项目"
        }
        if title.hasPrefix("Bundle applied:") {
            return title
                .replacingOccurrences(of: "Bundle applied:", with: "整理完成：")
                .replacingOccurrences(of: " renamed ", with: " 重命名 ")
                .replacingOccurrences(of: " moved ", with: " 移动 ")
        }
        return title
    }

    private func extractCount(from title: String, prefix: String) -> Int? {
        guard title.hasPrefix(prefix) else { return nil }
        let remainder = title.dropFirst(prefix.count)
        let digits = remainder.prefix { $0.isNumber }
        return Int(digits)
    }

    @ViewBuilder
    private func caseMissingBadge(for cas: DetectedCase) -> some View {
        let missing = cas.missingDocs(for: appState.activeChecklist)
        if !missing.isEmpty {
            Text("缺 \(missing.count) 份")
                .font(.caption)
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.orange)
                .clipShape(Capsule())
        }
    }

    private var aiStatusLine: some View {
        Button {
            appState.openAIFiles()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "brain")
                    .font(.caption)
                Text(aiStatusText)
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }

    private var aiStatusText: String {
        if appState.aiAnalyzedFilesCount > 0 {
            return "AI 已分析 \(appState.aiAnalyzedFilesCount) 个文件"
        }
        return "AI 分析：在「更多工具」中开始"
    }
}

private struct ArchivePreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState

    @State private var isExecuting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("整理预演")
                .font(.title3.weight(.semibold))

            VStack(alignment: .leading, spacing: 10) {
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(previewLineText(for: row))
                            .font(.body)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(reasonLine(for: row))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            if appState.archiveTimeWindow == .all {
                Text("首次大扫除：只移动不隔离")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("整理后可一键撤销")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button(isExecuting ? "整理中..." : "确认整理") {
                    execute()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isExecuting || appState.isBusy)

                Button("暂不整理") {
                    dismiss()
                }
                .buttonStyle(.bordered)
                .disabled(isExecuting)
            }
        }
        .padding(24)
        .frame(minWidth: 620)
    }

    private var rows: [ArchivePreviewRow] {
        let bucketMap = Dictionary(uniqueKeysWithValues: appState.recommendedPlanBuckets.map { ($0.kind, $0) })
        return [
            ArchivePreviewRow(
                id: "screenshots",
                title: "截图",
                count: bucketMap[.screenshots]?.actionableFiles ?? 0,
                destination: bucketMap[.screenshots]?.destination ?? "…/Screenshots/YYYY-MM"
            ),
            ArchivePreviewRow(
                id: "pdfs",
                title: "PDF 文件",
                count: bucketMap[.pdfs]?.actionableFiles ?? 0,
                destination: bucketMap[.pdfs]?.destination ?? "…/Downloads PDFs/YYYY-MM"
            ),
            ArchivePreviewRow(
                id: "inbox",
                title: "其他文件",
                count: bucketMap[.inbox]?.actionableFiles ?? 0,
                destination: bucketMap[.inbox]?.destination ?? "…/Downloads Inbox/YYYY-MM"
            ),
            ArchivePreviewRow(
                id: "installers",
                title: "安装包",
                count: bucketMap[.installers]?.actionableFiles ?? 0,
                destination: "隔离区"
            )
        ]
    }

    private func execute() {
        isExecuting = true
        Task {
            await appState.executeRecommendedArchivePlan()
            isExecuting = false
            dismiss()
        }
    }

    private func previewLineText(for row: ArchivePreviewRow) -> String {
        return "\(row.title) \(row.count) 个 → \(row.destination)"
    }

    private func reasonLine(for row: ArchivePreviewRow) -> String {
        switch row.id {
        case "screenshots":
            return "截图：来自屏幕快照命名/时间集中"
        case "pdfs":
            return "PDF：最近下载的 PDF（课件/账单/表格）"
        case "inbox":
            return "其他文件：下载文件夹中的杂项，按类型自动归档"
        case "installers":
            return "安装包：显示下载时长，可能已用完（默认可恢复）"
        default:
            return ""
        }
    }
}

private struct ArchivePreviewRow: Identifiable {
    let id: String
    let title: String
    let count: Int
    let destination: String
}
