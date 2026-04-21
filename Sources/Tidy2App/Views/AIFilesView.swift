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
    @State private var showDeleteConfirm = false

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
                    if !hasAnyKey {
                        aiKeySetupPrompt
                    } else if let s = appState.lastExecutionSummary, s.total > 0 {
                        // Files were just organized — show success state with Finder button
                        VStack(spacing: TidySpacing.xl) {
                            Spacer(minLength: 24)
                            VStack(spacing: TidySpacing.lg) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 56))
                                    .foregroundStyle(.green.gradient)
                                Text("整理计划已全部执行")
                                    .font(.title3.weight(.semibold))
                                VStack(spacing: 6) {
                                    if s.archived > 0 {
                                        Label("归档了 \(s.archived) 个文件", systemImage: "folder.fill.badge.plus")
                                            .foregroundStyle(.purple)
                                    }
                                    if s.deleted > 0 {
                                        Label("移到废纸篓 \(s.deleted) 个文件", systemImage: "trash.fill")
                                            .foregroundStyle(.orange)
                                    }
                                }
                                .font(.subheadline.weight(.medium))
                                if s.archived > 0 && !s.archiveRootPath.isEmpty {
                                    Button {
                                        appState.openArchiveRootInFinder()
                                    } label: {
                                        Label("在 Finder 中查看归档文件夹", systemImage: "folder.badge.magnifyingglass")
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                            HStack(spacing: TidySpacing.md) {
                                Button("重新扫描") {
                                    appState.scanButtonTappedFromHome()
                                }
                                .buttonStyle(.bordered)
                                Button("回到首页") {
                                    appState.pendingTab = nil
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            Spacer(minLength: 24)
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        EmptyStateView(
                            icon: "brain",
                            title: appState.totalFilesScanned == 0 ? "先扫描文件，再运行 AI 分析" : "还没有 AI 分析结果",
                            subtitle: appState.totalFilesScanned == 0
                                ? "回到首页，点击「开始扫描」"
                                : "点击「开始分析」，AI 会读取文件内容并生成整理计划"
                        )
                    }
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
        .confirmationDialog(
            "移入废纸篓",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("删除 \(deleteItems.count) 个文件", role: .destructive) {
                Task { await trashAllDeleteItems() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将 \(deleteItems.count) 个文件移入废纸篓。这些是 AI 建议删除的安装包和临时文件。可从废纸篓恢复。")
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
                    pill(AIProvider.current.displayName, .blue)
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
                    Text("归档计划")
                        .font(.title3.weight(.semibold))
                    Text("\(archiveItems.count) 个文件 → \(archiveGroups.count) 个文件夹")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if appState.isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Button("一键执行整理") {
                        showExecuteConfirm = true
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(archiveRootMissing)
                }
            }

            if archiveRootMissing {
                HStack(spacing: TidySpacing.xs) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("请先在「偏好设置」中设置整理文件夹")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !appState.archiveRootPath.isEmpty {
                Text("→ \(appState.archiveRootPath)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            ForEach(archiveGroups) { group in
                archiveGroupRow(group)
            }
        }
        .onAppear {
            // Auto-expand the largest group so users immediately see the plan
            if let biggest = archiveGroups.max(by: { $0.files.count < $1.files.count }) {
                expandedGroups.insert(biggest.id)
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
            } else if group.files.count > 1 {
                // Collapsed preview: show first 2 file names
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(group.files.prefix(2), id: \.filePath) { file in
                        HStack(spacing: 6) {
                            Image(systemName: file.docType.icon)
                                .foregroundStyle(.tertiary)
                                .font(.caption2)
                                .frame(width: 14)
                            Text(URL(fileURLWithPath: file.filePath).lastPathComponent)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    if group.files.count > 2 {
                        Text("还有 \(group.files.count - 2) 个文件…")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, TidySpacing.xl)
                .padding(.bottom, TidySpacing.sm)
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
                if !file.suggestedFolder.isEmpty {
                    Text("→ \(file.suggestedFolder)")
                        .font(.caption2)
                        .foregroundStyle(.blue.opacity(0.7))
                        .lineLimit(1)
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
                    showDeleteConfirm = true
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
    // These are files AI couldn't confidently identify — don't force per-file decisions.
    // Offer two bulk choices: archive to inbox, or dismiss.

    @State private var showUnsureFiles = false

    private var unsurePlanSection: some View {
        VStack(alignment: .leading, spacing: TidySpacing.lg) {
            // Header
            HStack(spacing: TidySpacing.sm) {
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(.secondary)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("AI 没把握的 \(unsureItems.count) 个文件")
                        .font(.subheadline.weight(.semibold))
                    Text("无法识别内容或无日期信息，批量处理最省事")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            // Two bulk action buttons
            HStack(spacing: TidySpacing.md) {
                Button {
                    Task { await archiveUnsureToInbox() }
                } label: {
                    VStack(spacing: 2) {
                        Text("全部归档到收件箱")
                            .font(.subheadline.weight(.medium))
                        Text("移到归档目录 / Inbox 文件夹")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.bordered)
                .disabled(appState.isBusy)

                Button {
                    Task { await dismissAllUnsure() }
                } label: {
                    VStack(spacing: 2) {
                        Text("全部跳过，不处理")
                            .font(.subheadline.weight(.medium))
                        Text("保持原位，不移动")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.bordered)
                .disabled(appState.isBusy)
            }

            // Optional: show files list (collapsed by default)
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showUnsureFiles.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showUnsureFiles ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                    Text(showUnsureFiles ? "收起文件列表" : "查看 \(unsureItems.count) 个文件")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            if showUnsureFiles {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(unsureItems, id: \.filePath) { file in
                        HStack(spacing: TidySpacing.sm) {
                            Image(systemName: file.docType.icon)
                                .foregroundStyle(.secondary)
                                .frame(width: 16)
                                .font(.caption)
                            Text(URL(fileURLWithPath: file.filePath).lastPathComponent)
                                .font(.caption)
                                .lineLimit(1)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.vertical, 3)
                        .padding(.horizontal, TidySpacing.sm)
                    }
                }
                .background(Color.secondary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: TidyRadius.sm))
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

    // MARK: - Key Setup Prompt

    private var hasAnyKey: Bool {
        let gemini = FileIntelligenceService.readGeminiAPIKeyFromKeychain() ?? ""
        let claude = FileIntelligenceService.readAPIKeyFromKeychain() ?? ""
        return !gemini.isEmpty || !claude.isEmpty
    }

    private var aiKeySetupPrompt: some View {
        VStack(spacing: TidySpacing.xl) {
            Image(systemName: "sparkles")
                .font(.system(size: 40))
                .foregroundStyle(.blue)

            VStack(spacing: TidySpacing.sm) {
                Text("AI 分析需要 API Key")
                    .font(.title3.weight(.semibold))
                Text("Gemini Flash 完全免费，用 Google 账号即可申请，每天 1500 次分析")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: TidySpacing.sm) {
                Link(destination: URL(string: "https://aistudio.google.com/apikey")!) {
                    HStack(spacing: TidySpacing.sm) {
                        Image(systemName: "arrow.up.right.square")
                        Text("免费获取 Gemini API Key")
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, TidySpacing.xl)
                    .padding(.vertical, TidySpacing.sm)
                    .background(Color.blue)
                    .clipShape(RoundedRectangle(cornerRadius: TidyRadius.md))
                }

                Text("获取 Key 后，在下方「AI 设置」中填入")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(TidySpacing.xxxl)
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

    private func archiveUnsureToInbox() async {
        guard !appState.archiveRootPath.isEmpty else {
            resultIsError = true
            showResult(msg: "请先在偏好设置中配置整理文件夹")
            return
        }
        let inboxFolder = (appState.archiveRootPath as NSString).appendingPathComponent("Inbox")
        var moved = 0
        for file in unsureItems {
            let src = URL(fileURLWithPath: file.filePath)
            let dst = URL(fileURLWithPath: inboxFolder).appendingPathComponent(src.lastPathComponent)
            do {
                try FileManager.default.createDirectory(atPath: inboxFolder, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: src, to: dst)
                await appState.dismissAIRecord(path: file.filePath)
                moved += 1
            } catch { /* skip */ }
        }
        showResult(msg: "已将 \(moved) 个文件归档到 Inbox 文件夹")
    }

    private func dismissAllUnsure() async {
        let count = unsureItems.count
        for file in unsureItems {
            await appState.dismissAIRecord(path: file.filePath)
        }
        showResult(msg: "已跳过 \(count) 个文件")
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
