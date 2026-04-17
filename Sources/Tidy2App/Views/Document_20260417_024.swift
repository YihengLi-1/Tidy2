import AppKit
import SwiftUI

struct AIFilesView: View {
    private enum OllamaStatus {
        case unknown
        case running
        case notRunning
    }

    @EnvironmentObject private var appState: AppState
    @State private var keepFilter: FileIntelligence.KeepOrDelete? = nil
    @State private var showBulkMoveConfirmation = false
    @State private var showSettings = false
    @State private var ollamaStatus: OllamaStatus = .unknown

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusCard

            DisclosureGroup("AI 设置", isExpanded: $showSettings) {
                aiSettingsContent
                    .padding(.top, 8)
            }

            Picker("筛选", selection: $keepFilter) {
                Text("全部").tag(FileIntelligence.KeepOrDelete?.none)
                Text("建议保留").tag(FileIntelligence.KeepOrDelete?.some(.keep))
                Text("建议删除").tag(FileIntelligence.KeepOrDelete?.some(.delete))
                Text("不确定").tag(FileIntelligence.KeepOrDelete?.some(.unsure))
            }
            .pickerStyle(.segmented)

            contentSection
        }
        .padding(20)
        .navigationTitle("AI 智能分析")
        .toolbar {
            if !movableKeepItems.isEmpty {
                ToolbarItem(placement: .automatic) {
                    Button("批量移动建议归档（\(movableKeepItems.count)个）") {
                        showBulkMoveConfirmation = true
                    }
                }
            }
        }
        .task {
            await appState.refreshAIAnalysisState()
            await refreshOllamaStatus()
        }
        .confirmationDialog(
            "批量移动建议归档的文件",
            isPresented: $showBulkMoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("确认移动") {
                let items = movableKeepItems
                Task {
                    var movedCount = 0
                    for intel in items {
                        if await appState.moveFileToSuggestedFolder(intel) {
                            movedCount += 1
                        }
                    }
                    appState.statusMessage = "已批量移动 \(movedCount) 个文件"
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将移动 \(movableKeepItems.count) 个建议保留且已提供目标位置的文件。")
        }
    }

    @ViewBuilder
    private var statusCard: some View {
        if appState.isAIAnalyzing {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("正在分析中，已完成 \(appState.aiAnalyzedFilesCount) 个...")
                    .font(.subheadline.weight(.medium))
                Spacer()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.blue.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        } else if let error = appState.aiAnalysisLastError, error.isOllamaConnectionIssue {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "brain.head.profile")
                    .foregroundStyle(.yellow)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 6) {
                    Text("需要本地 AI 服务")
                        .font(.subheadline.weight(.semibold))
                    Text("Tidy 使用 Ollama 在本地分析文件，不上传任何数据。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 8) {
                    Button("下载 Ollama") {
                        if let url = URL(string: "https://ollama.com") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.bordered)

                    Button("已安装，重试") {
                        Task {
                            await appState.triggerAIAnalysis()
                            await refreshOllamaStatus()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.yellow)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.yellow.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        } else if let error = appState.aiAnalysisLastError {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)

                VStack(alignment: .leading, spacing: 6) {
                    Text("AI 分析暂时不可用")
                        .font(.subheadline.weight(.medium))
                    Text(error.userMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("重试") {
                    Task {
                        await appState.triggerAIAnalysis()
                        await refreshOllamaStatus()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        } else if appState.aiAnalyzedFilesCount == 0 {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "brain")
                    .foregroundStyle(Color.accentColor)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 6) {
                    Text("开始 AI 智能分析")
                        .font(.subheadline.weight(.semibold))
                    Text("分析你的文件内容，找出可删除的重复版本、旧文件和可归档的内容")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("开始分析") {
                    Task { await appState.triggerAIAnalysis() }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.gray.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("已分析 \(appState.aiAnalyzedFilesCount) 个文件")
                        .font(.subheadline.weight(.semibold))
                    HStack(spacing: 8) {
                        ollamaStatusDot
                        Text(ollamaStatusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("继续分析") {
                    Task { await appState.triggerAIAnalysis() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(appState.isBusy)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.gray.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private var aiSettingsContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ollamaStatusDot
                Text(ollamaStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if AIProvider.current == .ollama {
                Text("当前模型：\(UserDefaults.standard.string(forKey: "ollama_model") ?? "qwen2.5:3b")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("当前使用 Claude API")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if AIProvider.current == .ollama && ollamaStatus == .notRunning {
                Text("运行 ollama serve 后刷新")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var contentSection: some View {
        if appState.aiIntelligenceItems.isEmpty {
            emptyState
        } else if filteredItems.isEmpty {
            filteredEmptyState
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !deleteItems.isEmpty {
                        deleteSection
                    }

                    if !archiveItems.isEmpty {
                        archiveSection
                    }

                    if !otherItems.isEmpty {
                        otherSection
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var deleteSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("建议清理（\(deleteItems.count) 个）")
                .font(.headline)
                .foregroundStyle(.red)

            ForEach(deleteItems, id: \.filePath) { item in
                AIDeleteSuggestionRow(item: item)
                    .environmentObject(appState)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var archiveSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("建议归档（\(archiveItems.count) 个）")
                .font(.headline)

            ForEach(archiveItems, id: \.filePath) { item in
                AIArchiveSuggestionRow(item: item)
                    .environmentObject(appState)
            }
        }
    }

    private var otherSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("其他分析结果（\(otherItems.count) 个）")
                .font(.headline)

            ForEach(otherItems, id: \.filePath) { item in
                AIGeneralSuggestionRow(item: item)
            }
        }
    }

    private var ollamaStatusDot: some View {
        Circle()
            .fill(ollamaStatusColor)
            .frame(width: 8, height: 8)
    }

    private var ollamaStatusColor: Color {
        switch AIProvider.current {
        case .claude:
            return .gray
        case .ollama:
            switch ollamaStatus {
            case .running:
                return .green
            case .notRunning:
                return .red
            case .unknown:
                return .orange
            }
        }
    }

    private var ollamaStatusText: String {
        switch AIProvider.current {
        case .claude:
            return "当前使用 Claude API"
        case .ollama:
            switch ollamaStatus {
            case .running:
                return "Ollama 已在运行"
            case .notRunning:
                return "Ollama 未启动"
            case .unknown:
                return "正在检测 Ollama 状态…"
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "brain")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.secondary)

            Text("暂无分析结果")
                .font(.title3.weight(.semibold))

            Text("完成一次扫描后，AI 会自动识别每个文件的内容")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("重新分析") {
                Task {
                    await appState.triggerAIAnalysis()
                }
            }
            .buttonStyle(.borderedProminent)

            Text("首次使用需要先完成扫描")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var filteredEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.secondary)

            Text("当前筛选下暂无结果")
                .font(.title3.weight(.semibold))

            Text("换一个过滤条件试试看")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var filteredItems: [FileIntelligence] {
        if let keepFilter {
            return appState.aiIntelligenceItems.filter { $0.keepOrDelete == keepFilter }
        }
        return appState.aiIntelligenceItems
    }

    private var deleteItems: [FileIntelligence] {
        filteredItems.filter { $0.keepOrDelete == .delete }
    }

    private var archiveItems: [FileIntelligence] {
        filteredItems.filter { $0.keepOrDelete != .delete && !$0.suggestedFolder.isEmpty }
    }

    private var otherItems: [FileIntelligence] {
        filteredItems.filter { $0.keepOrDelete != .delete && $0.suggestedFolder.isEmpty }
    }

    private var movableKeepItems: [FileIntelligence] {
        appState.aiIntelligenceItems.filter {
            $0.keepOrDelete == .keep && !$0.suggestedFolder.isEmpty
        }
    }

    @MainActor
    private func refreshOllamaStatus() async {
        guard AIProvider.current == .ollama else {
            ollamaStatus = .unknown
            return
        }
        guard let url = URL(string: "http://localhost:11434") else {
            ollamaStatus = .notRunning
            return
        }

        ollamaStatus = .unknown

        await withTaskGroup(of: OllamaStatus.self) { group in
            group.addTask {
                if let _ = try? await URLSession.shared.data(from: url) {
                    return .running
                }
                return .notRunning
            }

            group.addTask {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return .notRunning
            }

            if let status = await group.next() {
                group.cancelAll()
                ollamaStatus = status
            }
        }
    }
}

private struct AIDeleteSuggestionRow: View {
    let item: FileIntelligence
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(fileName)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)

            Text(compactPath(item.filePath))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            if fileAttributes.exists {
                Text("\(SizeFormatter.string(from: fileSizeBytes)) · \(DateHelper.relativeShort(modifiedAt))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("文件不存在（可能已移动或删除）")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            Text(reasonText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)

            HStack(spacing: 8) {
                Button("移到废纸篓") {
                    Task {
                        _ = await appState.moveFileToTrash(path: item.filePath)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("保留（忽略）") {
                    Task {
                        await appState.markAIItemKeep(path: item.filePath)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var fileName: String {
        URL(fileURLWithPath: item.filePath).lastPathComponent
    }

    private var reasonText: String {
        let trimmedReason = item.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedReason.isEmpty {
            return trimmedReason
        }
        if !item.suggestedFolder.isEmpty {
            return item.suggestedFolder
        }
        return "AI 判断这份文件可以清理。"
    }

    private var fileSizeBytes: Int64 {
        fileAttributes.size
    }

    private var modifiedAt: Date {
        fileAttributes.modifiedAt
    }

    private var fileAttributes: (size: Int64, modifiedAt: Date, exists: Bool) {
        AIFilesViewHelpers.attributes(for: item.filePath)
    }

    private func compactPath(_ path: String) -> String {
        AIFilesViewHelpers.compactPath(path)
    }
}

private struct AIArchiveSuggestionRow: View {
    let item: FileIntelligence
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(fileName) → \(item.suggestedFolder)")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(compactPath(item.filePath))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text("\(SizeFormatter.string(from: fileSizeBytes)) · \(DateHelper.relativeShort(modifiedAt))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if !item.reason.isEmpty {
                    Text(item.reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            Button("立即移动") {
                Task {
                    await appState.moveFileToSuggestedFolder(item)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var fileName: String {
        URL(fileURLWithPath: item.filePath).lastPathComponent
    }

    private var fileSizeBytes: Int64 {
        fileAttributes.size
    }

    private var modifiedAt: Date {
        fileAttributes.modifiedAt
    }

    private var fileAttributes: (size: Int64, modifiedAt: Date, exists: Bool) {
        AIFilesViewHelpers.attributes(for: item.filePath)
    }

    private func compactPath(_ path: String) -> String {
        AIFilesViewHelpers.compactPath(path)
    }
}

private struct AIGeneralSuggestionRow: View {
    let item: FileIntelligence

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Text(fileName)
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(item.category)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(FileIntelligence.categoryColor(for: item.category))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(FileIntelligence.categoryColor(for: item.category).opacity(0.12))
                    .clipShape(Capsule())

                Spacer(minLength: 12)

                Image(systemName: keepOrDeleteIconName)
                    .foregroundStyle(keepOrDeleteColor)
                    .font(.title3)
            }

            Text(compactPath(item.filePath))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            if !item.summary.isEmpty {
                Text(item.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if fileAttributes.exists {
                Text("\(SizeFormatter.string(from: fileSizeBytes)) · \(DateHelper.relativeShort(modifiedAt))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("文件不存在（可能已移动或删除）")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(12)
        .background(Color.gray.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var fileName: String {
        URL(fileURLWithPath: item.filePath).lastPathComponent
    }

    private var keepOrDeleteIconName: String {
        switch item.keepOrDelete {
        case .keep:
            return "checkmark.circle"
        case .delete:
            return "trash"
        case .unsure:
            return "questionmark.circle"
        }
    }

    private var keepOrDeleteColor: Color {
        switch item.keepOrDelete {
        case .keep:
            return .green
        case .delete:
            return .red
        case .unsure:
            return .gray
        }
    }

    private var fileSizeBytes: Int64 {
        fileAttributes.size
    }

    private var modifiedAt: Date {
        fileAttributes.modifiedAt
    }

    private var fileAttributes: (size: Int64, modifiedAt: Date, exists: Bool) {
        AIFilesViewHelpers.attributes(for: item.filePath)
    }

    private func compactPath(_ path: String) -> String {
        AIFilesViewHelpers.compactPath(path)
    }
}

private enum AIFilesViewHelpers {
    static func attributes(for path: String) -> (size: Int64, modifiedAt: Date, exists: Bool) {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            return (0, Date(), false)
        }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = Int64(values?.fileSize ?? 0)
        let modifiedAt = values?.contentModificationDate ?? Date()
        return (size, modifiedAt, true)
    }

    static func compactPath(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        let components = URL(fileURLWithPath: path).pathComponents.filter { $0 != "/" }
        guard components.count > 3 else { return path }
        return "…/\(components.suffix(3).joined(separator: "/"))"
    }
}
