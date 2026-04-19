import AppKit
import SwiftUI

// MARK: - Data

private struct ArchivePlanGroup: Identifiable {
    var id: String { folderPath }
    let folderPath: String
    var files: [FileIntelligence]
}

// MARK: - Main View

struct AIFilesView: View {
    private enum OllamaStatus { case unknown, running, notRunning }

    @EnvironmentObject private var appState: AppState
    @State private var showSettings = false
    @State private var ollamaStatus: OllamaStatus = .unknown
    @State private var resultMessage: String? = nil
    @State private var resultIsError: Bool = false
    @State private var expandedGroups: Set<String> = []
    @State private var showExecuteConfirm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TidySpacing.xl) {
                // Result banner
                if let msg = resultMessage {
                    HStack(spacing: TidySpacing.sm) {
                        Image(systemName: resultIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(resultIsError ? Color.orange : Color.green)
                        Text(msg).font(.subheadline.weight(.medium))
                    }
                    .padding(.horizontal, TidySpacing.lg)
                    .padding(.vertical, TidySpacing.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .tidyColorCard(resultIsError ? .orange : .green, radius: TidyRadius.md, opacity: TidyOpacity.medium)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                // Status card
                statusCard

                // Empty state
                if appState.aiIntelligenceItems.isEmpty {
                    EmptyStateView(
                        icon: "brain",
                        title: "还没有 AI 分析结果",
                        subtitle: "点击「开始分析」让 AI 理解你的文件内容并生成整理计划"
                    )
                } else {
                    // Archive plan groups
                    if !archiveGroups.isEmpty {
                        archivePlanSection
                    }

                    // Delete section
                    if !deleteItems.isEmpty {
                        deletePlanSection
                    }

                    // Unsure section
                    if !unsureItems.isEmpty {
                        unsurePlanSection
                    }
                }

                // AI Settings (collapsed by default)
                DisclosureGroup("AI 设置", isExpanded: $showSettings) {
                    aiSettingsContent.padding(.top, TidySpacing.sm)
                }
                .padding(TidySpacing.xl)
                .tidyCard()
            }
            .padding(TidySpacing.xxl)
        }
        .navigationTitle("智能整理")
        .confirmationDialog(
            "执行整理计划",
            isPresented: $showExecuteConfirm,
            titleVisibility: .visible
        ) {
            Button("整理 \(archiveItems.count) 个文件") {
                Task { await executeArchivePlan() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将 \(archiveItems.count) 个文件移动到 \(archiveGroups.count) 个文件夹。操作完成后可一键撤销。")
        }
        .task {
            await appState.refreshAIAnalysisState()
            await checkOllamaStatus()
        }
    }

    // MARK: - Status Card

    private var statusCard: some View {
        HStack(spacing: TidySpacing.xl) {
            VStack(alignment: .leading, spacing: TidySpacing.xxs) {
                Text("AI 已分析 \(appState.aiAnalyzedFilesCount) 个文件")
                    .font(.headline)
                HStack(spacing: TidySpacing.sm) {
                    if !archiveItems.isEmpty {
                        pill("\(archiveItems.count) 待整理", .blue)
                    }
                    if !deleteItems.isEmpty {
                        pill("\(deleteItems.count) 建议删除", .red)
                    }
                    if !unsureItems.isEmpty {
                        pill("\(unsureItems.count) 待确认", .secondary)
                    }
                }
            }
            Spacer()
            Button {
                Task {
                    showResult(msg: nil)
                    await appState.analyzeNewFiles()
                }
            } label: {
                Label(appState.isBusy ? "分析中..." : "开始分析", systemImage: "brain")
            }
            .buttonStyle(.borderedProminent)
            .disabled(appState.isBusy)
        }
        .padding(TidySpacing.xl)
        .tidyCard(radius: TidyRadius.lg, opacity: TidyOpacity.light)
    }

    // MARK: - Archive Plan Section

    private var archivePlanSection: some View {
        VStack(alignment: .leading, spacing: TidySpacing.sm) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("待整理")
                        .font(.title3.weight(.semibold))
                    Text("\(archiveItems.count) 个文件 → \(archiveGroups.count) 个文件夹")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("一键执行整理") {
                    showExecuteConfirm = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(appState.isBusy || archiveRootMissing)
            }

            if archiveRootMissing {
                HStack(spacing: TidySpacing.xs) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("请先在「偏好设置」中设置整理文件夹")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(archiveGroups) { group in
                archiveGroupRow(group)
            }
        }
    }

    private func archiveGroupRow(_ group: ArchivePlanGroup) -> some View {
        let isExpanded = expandedGroups.contains(group.id)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                if isExpanded { expandedGroups.remove(group.id) }
                else { expandedGroups.insert(group.id) }
            } label: {
                HStack(spacing: TidySpacing.sm) {
                    Image(systemName: isExpanded ? "folder.fill" : "folder")
                        .foregroundStyle(.blue)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.folderPath)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                    }
                    Spacer()
                    Text("\(group.files.count) 个")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(TidySpacing.lg)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider().padding(.horizontal, TidySpacing.lg)
                ForEach(group.files, id: \.filePath) { file in
                    fileRow(file)
                }
            }
        }
        .background(Color.blue.opacity(TidyOpacity.ultraLight))
        .clipShape(RoundedRectangle(cornerRadius: TidyRadius.md))
    }

    private func fileRow(_ file: FileIntelligence) -> some View {
        HStack(spacing: TidySpacing.sm) {
            Image(systemName: file.docType.icon)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(URL(fileURLWithPath: file.filePath).lastPathComponent)
                    .font(.subheadline)
                    .lineLimit(1)
                if !file.summary.isEmpty {
                    Text(file.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            Button {
                Task {
                    let moved = await appState.moveFileToSuggestedFolder(file)
                    if moved { showResult(msg: "已移动：\(URL(fileURLWithPath: file.filePath).lastPathComponent)") }
                }
            } label: {
                Image(systemName: "arrow.right.circle")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.blue)
            .accessibilityLabel("移动 \(URL(fileURLWithPath: file.filePath).lastPathComponent)")
        }
        .padding(.horizontal, TidySpacing.xl)
        .padding(.vertical, TidySpacing.xs)
        .tidyFileRowAccessibility(
            name: URL(fileURLWithPath: file.filePath).lastPathComponent,
            value: file.summary
        )
        .tidyFileContextMenu(path: file.filePath)
    }

    // MARK: - Delete Section

    private var deletePlanSection: some View {
        VStack(alignment: .leading, spacing: TidySpacing.sm) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("建议删除")
                        .font(.title3.weight(.semibold))
                    Text("安装包、明显重复、临时文件")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("全部移入废纸篓") {
                    Task { await trashAllDeleteItems() }
                }
                .buttonStyle(.bordered)
                .foregroundStyle(.red)
                .disabled(appState.isBusy)
            }

            ForEach(deleteItems, id: \.filePath) { file in
                HStack(spacing: TidySpacing.sm) {
                    Image(systemName: file.docType.icon)
                        .foregroundStyle(.red.opacity(0.7))
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(URL(fileURLWithPath: file.filePath).lastPathComponent)
                            .font(.subheadline)
                            .lineLimit(1)
                        Text(file.reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button {
                        Task { await appState.moveFileToTrash(path: file.filePath) }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                }
                .padding(TidySpacing.lg)
                .tidyFileRowAccessibility(
                    name: URL(fileURLWithPath: file.filePath).lastPathComponent,
                    value: "建议删除：\(file.reason)"
                )
                .tidyFileContextMenu(path: file.filePath)
            }
        }
        .padding(TidySpacing.xl)
        .tidyColorCard(.red, radius: TidyRadius.lg, opacity: 0.04)
    }

    // MARK: - Unsure Section

    private var unsurePlanSection: some View {
        VStack(alignment: .leading, spacing: TidySpacing.sm) {
            Text("待确认")
                .font(.title3.weight(.semibold))
            Text("AI 不确定如何处理，需要你来决定")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(unsureItems.prefix(10), id: \.filePath) { file in
                HStack(spacing: TidySpacing.sm) {
                    Image(systemName: file.docType.icon)
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(URL(fileURLWithPath: file.filePath).lastPathComponent)
                            .font(.subheadline)
                            .lineLimit(1)
                        Text(file.summary.isEmpty ? file.reason : file.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button("整理") {
                        Task { let _ = await appState.moveFileToSuggestedFolder(file) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("跳过") {
                        Task { await appState.dismissAIRecord(path: file.filePath) }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, TidySpacing.xs)
                .tidyFileRowAccessibility(
                    name: URL(fileURLWithPath: file.filePath).lastPathComponent,
                    value: "待确认：\(file.summary)"
                )
            }

            if unsureItems.count > 10 {
                Text("还有 \(unsureItems.count - 10) 个待确认文件…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(TidySpacing.xl)
        .tidyCard(radius: TidyRadius.lg, opacity: TidyOpacity.light)
    }

    // MARK: - AI Settings

    @ViewBuilder
    private var aiSettingsContent: some View {
        VStack(alignment: .leading, spacing: TidySpacing.lg) {
            Picker("AI 提供商", selection: Binding(
                get: { AIProvider.current },
                set: { AIProvider.setCurrent($0) }
            )) {
                Text("Gemini（免费）").tag(AIProvider.gemini)
                Text("Ollama（本地）").tag(AIProvider.ollama)
                Text("Claude（付费）").tag(AIProvider.claude)
            }
            .pickerStyle(.segmented)

            switch AIProvider.current {
            case .gemini:
                let geminiBinding = Binding<String>(
                    get: { FileIntelligenceService.readGeminiAPIKeyFromKeychain() ?? "" },
                    set: { FileIntelligenceService.saveGeminiAPIKey($0) }
                )
                VStack(alignment: .leading, spacing: TidySpacing.xs) {
                    SecureField("Gemini API Key (AIza...)", text: geminiBinding)
                        .textFieldStyle(.roundedBorder)
                    Link("免费获取 → aistudio.google.com/apikey",
                         destination: URL(string: "https://aistudio.google.com/apikey")!)
                        .font(.caption)
                        .foregroundColor(.accentColor)
                }
            case .claude:
                let claudeBinding = Binding<String>(
                    get: { FileIntelligenceService.readAPIKeyFromKeychain() ?? "" },
                    set: { FileIntelligenceService.saveAPIKey($0) }
                )
                SecureField("Claude API Key (sk-ant-...)", text: claudeBinding)
                    .textFieldStyle(.roundedBorder)
            case .ollama:
                VStack(alignment: .leading, spacing: TidySpacing.xs) {
                    HStack(spacing: TidySpacing.sm) {
                        Circle()
                            .fill(ollamaStatusColor)
                            .frame(width: 8, height: 8)
                        Text(ollamaStatusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("刷新") { Task { await checkOllamaStatus() } }
                            .buttonStyle(.borderless)
                            .font(.caption)
                    }
                    let modelBinding = Binding<String>(
                        get: { UserDefaults.standard.string(forKey: "ollama_model") ?? "qwen2.5:3b" },
                        set: { UserDefaults.standard.set($0, forKey: "ollama_model") }
                    )
                    HStack {
                        Text("模型")
                        TextField("模型名称", text: modelBinding)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private var archiveItems: [FileIntelligence] {
        appState.aiIntelligenceItems.filter { $0.keepOrDelete == .keep && !$0.suggestedFolder.isEmpty }
    }

    private var deleteItems: [FileIntelligence] {
        appState.aiIntelligenceItems.filter { $0.keepOrDelete == .delete }
    }

    private var unsureItems: [FileIntelligence] {
        appState.aiIntelligenceItems.filter { $0.keepOrDelete == .unsure || ($0.keepOrDelete == .keep && $0.suggestedFolder.isEmpty) }
    }

    private var archiveGroups: [ArchivePlanGroup] {
        var groups: [String: [FileIntelligence]] = [:]
        for file in archiveItems {
            let folder = file.suggestedFolder.isEmpty ? "归档" : file.suggestedFolder
            groups[folder, default: []].append(file)
        }
        return groups.map { ArchivePlanGroup(folderPath: $0.key, files: $0.value) }
            .sorted { a, b in
                if a.files.count != b.files.count { return a.files.count > b.files.count }
                return a.folderPath < b.folderPath
            }
    }

    private var archiveRootMissing: Bool {
        appState.archiveRootPath.isEmpty
    }

    private func pill(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, TidySpacing.xs)
            .padding(.vertical, 2)
            .background(color.opacity(TidyOpacity.strong))
            .clipShape(Capsule())
    }

    private func showResult(msg: String?) {
        withAnimation {
            resultMessage = msg
            resultIsError = false
        }
        if msg != nil {
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await MainActor.run { withAnimation { resultMessage = nil } }
            }
        }
    }

    private func executeArchivePlan() async {
        let count = await appState.bulkMoveToSuggestedFolders(archiveItems)
        showResult(msg: "已整理 \(count) 个文件到 \(archiveGroups.count) 个文件夹")
    }

    private func trashAllDeleteItems() async {
        let paths = deleteItems.map { $0.filePath }
        let count = await appState.moveFilesToTrash(paths: paths)
        showResult(msg: "已移动 \(count) 个文件到废纸篓")
    }

    private func checkOllamaStatus() async {
        guard AIProvider.current == .ollama else { return }
        let url = URL(string: "http://localhost:11434/api/tags")!
        if let _ = try? await URLSession.shared.data(from: url) {
            ollamaStatus = .running
        } else {
            ollamaStatus = .notRunning
        }
    }

    private var ollamaStatusColor: Color {
        switch ollamaStatus {
        case .running: return .green
        case .notRunning: return .red
        case .unknown: return .secondary
        }
    }

    private var ollamaStatusText: String {
        switch ollamaStatus {
        case .running: return "Ollama 运行中"
        case .notRunning: return "Ollama 未运行（请先执行 ollama serve）"
        case .unknown: return "检查中..."
        }
    }
}
