import AppKit
import SwiftUI

struct AIFilesView: View {
    private enum OllamaStatus { case unknown, running, notRunning }

    @EnvironmentObject private var appState: AppState
    @State private var keepFilter: FileIntelligence.KeepOrDelete? = nil
    @State private var showBulkMoveConfirmation = false
    @State private var showSettings = false
    @State private var ollamaStatus: OllamaStatus = .unknown
    @State private var resultMessage: String? = nil
    @State private var resultIsError: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let msg = resultMessage {
                HStack(spacing: 8) {
                    Image(systemName: resultIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(resultIsError ? Color.orange : Color.green)
                    Text(msg).font(.subheadline.weight(.medium))
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(resultIsError ? Color.orange.opacity(0.10) : Color.green.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            statusCard

            DisclosureGroup("AI 设置", isExpanded: $showSettings) {
                aiSettingsContent.padding(.top, 8)
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
        .animation(.easeInOut(duration: 0.25), value: resultMessage)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if ghostCount > 0 {
                    Button("清理失效记录（\(ghostCount)个）") {
                        Task {
                            await appState.purgeGhostAIRecords()
                            showResult(appState.statusMessage, isError: false)
                        }
                    }
                    .foregroundStyle(.orange)
                }
                if !movableKeepItems.isEmpty {
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
                    var moved = 0
                    for intel in items {
                        if await appState.moveFileToSuggestedFolder(intel) { moved += 1 }
                    }
                    showResult("已批量移动 \(moved) 个文件", isError: moved == 0)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将移动 \(movableKeepItems.count) 个建议保留且已提供目标位置的文件。")
        }
    }

    // MARK: - Status card

    @ViewBuilder
    private var statusCard: some View {
        if appState.isAIAnalyzing {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("正在分析中，已完成 \(appState.aiAnalyzedFilesCount) 个...")
                    .font(.subheadline.weight(.medium))
                Spacer()
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.blue.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        } else if let error = appState.aiAnalysisLastError, error.isOllamaConnectionIssue {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "brain.head.profile").foregroundStyle(.yellow).font(.title3)
                VStack(alignment: .leading, spacing: 6) {
                    Text("需要本地 AI 服务").font(.subheadline.weight(.semibold))
                    Text("Tidy 使用 Ollama 在本地分析文件，不上传任何数据。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 8) {
                    Button("下载 Ollama") {
                        if let url = URL(string: "https://ollama.com") { NSWorkspace.shared.open(url) }
                    }.buttonStyle(.bordered)
                    Button("已安装，重试") {
                        Task { await appState.triggerAIAnalysis(); await refreshOllamaStatus() }
                    }.buttonStyle(.borderedProminent).tint(.yellow)
                }
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.yellow.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        } else if let error = appState.aiAnalysisLastError {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 6) {
                    Text("AI 分析暂时不可用").font(.subheadline.weight(.medium))
                    Text(error.userMessage).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("重试") {
                    Task { await appState.triggerAIAnalysis(); await refreshOllamaStatus() }
                }.buttonStyle(.borderedProminent).tint(.red)
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        } else if appState.aiAnalyzedFilesCount == 0 {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "brain").foregroundStyle(Color.accentColor).font(.title3)
                VStack(alignment: .leading, spacing: 6) {
                    Text("开始 AI 智能分析").font(.subheadline.weight(.semibold))
                    Text("分析你的文件内容，找出可删除的重复版本、旧文件和可归档的内容")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("开始分析") { Task { await appState.triggerAIAnalysis() } }
                    .buttonStyle(.borderedProminent)
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.gray.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("已分析 \(appState.aiAnalyzedFilesCount) 个文件")
                        .font(.subheadline.weight(.semibold))
                    HStack(spacing: 8) {
                        ollamaStatusDot
                        Text(ollamaStatusText).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("继续分析") { Task { await appState.triggerAIAnalysis() } }
                    .buttonStyle(.borderedProminent).disabled(appState.isBusy)
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.gray.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private var aiSettingsContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ollamaStatusDot
                Text(ollamaStatusText).font(.caption).foregroundStyle(.secondary)
            }
            if AIProvider.current == .ollama {
                Text("当前模型：\(UserDefaults.standard.string(forKey: "ollama_model") ?? "qwen2.5:3b")")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("当前使用 Claude API").font(.caption).foregroundStyle(.secondary)
            }
            if AIProvider.current == .ollama && ollamaStatus == .notRunning {
                Text("运行 ollama serve 后刷新").font(.caption).foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Content sections

    @ViewBuilder
    private var contentSection: some View {
        if appState.aiIntelligenceItems.isEmpty {
            emptyState
        } else if filteredItems.isEmpty {
            filteredEmptyState
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !deleteItems.isEmpty { deleteSection }
                    if !archiveItems.isEmpty { archiveSection }
                    if !otherItems.isEmpty { otherSection }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var deleteSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("建议清理（\(deleteItems.count) 个）").font(.headline).foregroundStyle(.red)
            ForEach(deleteItems, id: \.filePath) { item in
                AIDeleteSuggestionRow(item: item, onResult: showResult)
                    .environmentObject(appState)
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var archiveSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("建议归档（\(archiveItems.count) 个）").font(.headline)
            // Warn if archive root isn't configured
            if appState.archiveRootPath.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("请先在偏好设置中设置整理文件夹，才能移动文件")
                        .font(.caption).foregroundStyle(.orange)
                    Spacer()
                    Button("去设置") { appState.pendingTab = .settings }
                        .buttonStyle(.bordered).controlSize(.small)
                }
                .padding(10)
                .background(Color.orange.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            ForEach(archiveItems, id: \.filePath) { item in
                AIArchiveSuggestionRow(item: item, onResult: showResult)
                    .environmentObject(appState)
            }
        }
    }

    private var otherSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("其他分析结果（\(otherItems.count) 个）").font(.headline)
            ForEach(otherItems, id: \.filePath) { item in
                AIGeneralSuggestionRow(item: item, onResult: showResult)
                    .environmentObject(appState)
            }
        }
    }

    // MARK: - Helpers

    private var filteredItems: [FileIntelligence] {
        keepFilter.map { f in appState.aiIntelligenceItems.filter { $0.keepOrDelete == f } }
            ?? appState.aiIntelligenceItems
    }
    private var deleteItems:  [FileIntelligence] { filteredItems.filter { $0.keepOrDelete == .delete } }
    private var archiveItems: [FileIntelligence] { filteredItems.filter { $0.keepOrDelete != .delete && !$0.suggestedFolder.isEmpty } }
    private var otherItems:   [FileIntelligence] { filteredItems.filter { $0.keepOrDelete != .delete && $0.suggestedFolder.isEmpty } }
    private var movableKeepItems: [FileIntelligence] {
        appState.aiIntelligenceItems.filter { $0.keepOrDelete == .keep && !$0.suggestedFolder.isEmpty }
    }
    private var ghostCount: Int {
        appState.aiIntelligenceItems.filter { !FileManager.default.fileExists(atPath: $0.filePath) }.count
    }

    private var ollamaStatusDot: some View {
        Circle().fill(ollamaStatusColor).frame(width: 8, height: 8)
    }
    private var ollamaStatusColor: Color {
        switch AIProvider.current {
        case .claude: return .gray
        case .ollama:
            switch ollamaStatus {
            case .running: return .green; case .notRunning: return .red; case .unknown: return .orange
            }
        }
    }
    private var ollamaStatusText: String {
        switch AIProvider.current {
        case .claude: return "当前使用 Claude API"
        case .ollama:
            switch ollamaStatus {
            case .running: return "Ollama 已在运行"
            case .notRunning: return "Ollama 未启动"
            case .unknown: return "正在检测 Ollama 状态…"
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "brain").font(.system(size: 34, weight: .semibold)).foregroundStyle(.secondary)
            Text("暂无分析结果").font(.title3.weight(.semibold))
            Text("完成一次扫描后，AI 会自动识别每个文件的内容")
                .font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("重新分析") { Task { await appState.triggerAIAnalysis() } }.buttonStyle(.borderedProminent)
            Text("首次使用需要先完成扫描").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
    }

    private var filteredEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 30, weight: .semibold)).foregroundStyle(.secondary)
            Text("当前筛选下暂无结果").font(.title3.weight(.semibold))
            Text("换一个过滤条件试试看").font(.body).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
    }

    private func showResult(_ msg: String, isError: Bool) {
        resultMessage = msg
        resultIsError = isError
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            resultMessage = nil
        }
    }

    @MainActor
    private func refreshOllamaStatus() async {
        guard AIProvider.current == .ollama else { ollamaStatus = .unknown; return }
        guard let url = URL(string: "http://localhost:11434") else { ollamaStatus = .notRunning; return }
        ollamaStatus = .unknown
        await withTaskGroup(of: OllamaStatus.self) { group in
            group.addTask {
                if let _ = try? await URLSession.shared.data(from: url) { return .running }
                return .notRunning
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return .notRunning
            }
            if let status = await group.next() { group.cancelAll(); ollamaStatus = status }
        }
    }
}

// MARK: - Delete row

private struct AIDeleteSuggestionRow: View {
    let item: FileIntelligence
    let onResult: (String, Bool) -> Void
    @EnvironmentObject private var appState: AppState
    @State private var isWorking = false

    private var fileExists: Bool { FileManager.default.fileExists(atPath: item.filePath) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(fileName).font(.headline).lineLimit(1).truncationMode(.middle)
            Text(compactPath(item.filePath)).font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)

            if fileExists {
                let attrs = AIFilesViewHelpers.attributes(for: item.filePath)
                Text("\(SizeFormatter.string(from: attrs.size)) · \(DateHelper.relativeShort(attrs.modifiedAt))")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("文件不存在（可能已移动或删除）")
                    .font(.caption2).foregroundStyle(.orange)
            }

            if !item.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(item.reason.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }

            HStack(spacing: 8) {
                if isWorking {
                    ProgressView().controlSize(.small).frame(width: 80)
                } else if fileExists {
                    Button("移到废纸篓") { perform(.trash) }
                        .buttonStyle(.bordered).controlSize(.small)
                    Button("保留（忽略）") { perform(.keep) }
                        .buttonStyle(.bordered).controlSize(.small)
                } else {
                    // File is gone – only action is to remove the stale record
                    Button("移除此记录") { perform(.dismiss) }
                        .buttonStyle(.bordered).controlSize(.small)
                        .foregroundStyle(.orange)
                    Button("保留（忽略）") { perform(.keep) }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private enum Action { case trash, keep, dismiss }

    private func perform(_ action: Action) {
        guard !isWorking else { return }
        isWorking = true
        Task {
            switch action {
            case .trash:
                let ok = await appState.moveFileToTrash(path: item.filePath)
                onResult(ok ? "已移到废纸篓：\(fileName)" : (appState.statusMessage.isEmpty ? "无法移动文件" : appState.statusMessage), !ok)
            case .keep:
                await appState.markAIItemKeep(path: item.filePath)
                onResult("已保留：\(fileName)", false)
            case .dismiss:
                await appState.dismissAIRecord(path: item.filePath)
                onResult("已清除失效记录：\(fileName)", false)
            }
            isWorking = false
        }
    }

    private var fileName: String { URL(fileURLWithPath: item.filePath).lastPathComponent }
    private func compactPath(_ p: String) -> String { AIFilesViewHelpers.compactPath(p) }
}

// MARK: - Archive row

private struct AIArchiveSuggestionRow: View {
    let item: FileIntelligence
    let onResult: (String, Bool) -> Void
    @EnvironmentObject private var appState: AppState
    @State private var isMoving = false

    private var fileExists: Bool { FileManager.default.fileExists(atPath: item.filePath) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(fileName) → \(item.suggestedFolder)")
                    .font(.headline).lineLimit(1).truncationMode(.middle)
                Text(compactPath(item.filePath)).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)

                if fileExists {
                    let attrs = AIFilesViewHelpers.attributes(for: item.filePath)
                    Text("\(SizeFormatter.string(from: attrs.size)) · \(DateHelper.relativeShort(attrs.modifiedAt))")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("文件不存在（可能已移动或删除）")
                        .font(.caption2).foregroundStyle(.orange)
                }

                if !item.reason.isEmpty {
                    Text(item.reason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }

            Spacer()

            if isMoving {
                ProgressView().controlSize(.small).frame(width: 60)
            } else if fileExists {
                Button("立即移动") { move() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            } else {
                Button("移除记录") { dismiss() }
                    .buttonStyle(.bordered).controlSize(.small).foregroundStyle(.orange)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func move() {
        guard !isMoving else { return }
        isMoving = true
        Task {
            let ok = await appState.moveFileToSuggestedFolder(item)
            if !ok {
                let msg = appState.statusMessage.isEmpty ? "移动失败，请检查整理文件夹是否已设置" : appState.statusMessage
                onResult(msg, true)
                isMoving = false
            }
            // On success, item is removed from list by AppState; no need to reset isMoving
        }
    }

    private func dismiss() {
        Task {
            await appState.dismissAIRecord(path: item.filePath)
            onResult("已清除失效记录：\(fileName)", false)
        }
    }

    private var fileName: String { URL(fileURLWithPath: item.filePath).lastPathComponent }
    private func compactPath(_ p: String) -> String { AIFilesViewHelpers.compactPath(p) }
}

// MARK: - General row

private struct AIGeneralSuggestionRow: View {
    let item: FileIntelligence
    let onResult: (String, Bool) -> Void
    @EnvironmentObject private var appState: AppState

    private var fileExists: Bool { FileManager.default.fileExists(atPath: item.filePath) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Text(fileName).font(.headline.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                Text(item.category)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(FileIntelligence.categoryColor(for: item.category))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(FileIntelligence.categoryColor(for: item.category).opacity(0.12))
                    .clipShape(Capsule())
                Spacer(minLength: 12)
                Image(systemName: keepOrDeleteIconName).foregroundStyle(keepOrDeleteColor).font(.title3)
            }

            Text(compactPath(item.filePath)).font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)

            if !item.summary.isEmpty {
                Text(item.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }

            if fileExists {
                let attrs = AIFilesViewHelpers.attributes(for: item.filePath)
                Text("\(SizeFormatter.string(from: attrs.size)) · \(DateHelper.relativeShort(attrs.modifiedAt))")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    Text("文件不存在（可能已移动或删除）").font(.caption2).foregroundStyle(.orange)
                    Spacer()
                    Button("移除记录") {
                        Task {
                            await appState.dismissAIRecord(path: item.filePath)
                            onResult("已清除失效记录：\(fileName)", false)
                        }
                    }
                    .buttonStyle(.bordered).controlSize(.mini).foregroundStyle(.orange)
                }
            }
        }
        .padding(12)
        .background(Color.gray.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var fileName: String { URL(fileURLWithPath: item.filePath).lastPathComponent }
    private var keepOrDeleteIconName: String {
        switch item.keepOrDelete { case .keep: "checkmark.circle"; case .delete: "trash"; case .unsure: "questionmark.circle" }
    }
    private var keepOrDeleteColor: Color {
        switch item.keepOrDelete { case .keep: .green; case .delete: .red; case .unsure: .gray }
    }
    private func compactPath(_ p: String) -> String { AIFilesViewHelpers.compactPath(p) }
}

// MARK: - Helpers

private enum AIFilesViewHelpers {
    static func attributes(for path: String) -> (size: Int64, modifiedAt: Date, exists: Bool) {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return (0, Date(), false) }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return (Int64(values?.fileSize ?? 0), values?.contentModificationDate ?? Date(), true)
    }

    static func compactPath(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        let components = URL(fileURLWithPath: path).pathComponents.filter { $0 != "/" }
        guard components.count > 3 else { return path }
        return "…/\(components.suffix(3).joined(separator: "/"))"
    }
}
