import SwiftUI

// MARK: - DigestView
// Philosophy: not a toolbox. Tell the user exactly what needs doing and let them do it in one tap.
// States: freshStart → scanning → taskEngine | allClean → completion

struct DigestView: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage("hasRunFullHistoryScan") private var hasRunFullHistoryScan = false

    @State private var isExecutingAll = false
    @State private var showCompletion = false
    @State private var completionSummary: AppState.ExecutionSummary? = nil
    @State private var scanWasRunning = false

    // MARK: - State machine

    private enum ViewState {
        case freshStart, scanning, taskEngine, allClean, completion
    }

    private var viewState: ViewState {
        if showCompletion { return .completion }
        if appState.isBusy && appState.totalFilesScanned == 0 { return .scanning }
        if appState.isBusy { return .scanning }
        if appState.totalFilesScanned == 0 { return .freshStart }
        if taskCount > 0 { return .taskEngine }
        return .allClean
    }

    // MARK: - Computed task counts

    private var aiArchiveCount: Int {
        appState.aiIntelligenceItems.filter { $0.keepOrDelete == .keep && !$0.suggestedFolder.isEmpty }.count
    }
    private var aiDeleteCount: Int {
        appState.aiIntelligenceItems.filter { $0.keepOrDelete == .delete }.count
    }
    private var hasDuplicates: Bool {
        appState.duplicateGroups.count > 0 && appState.duplicatesTotalWastedBytes > 20_000_000
    }
    private var hasBundles: Bool {
        appState.bundles.count > 0 && aiArchiveCount == 0
    }
    private var hasAnyAIKey: Bool {
        let gemini = FileIntelligenceService.readGeminiAPIKeyFromKeychain() ?? ""
        let claude = FileIntelligenceService.readAPIKeyFromKeychain() ?? ""
        return !gemini.isEmpty || !claude.isEmpty
    }
    private var hasAIResults: Bool { aiArchiveCount > 0 || aiDeleteCount > 0 }
    private var estimatedFreedBytes: Int64 {
        var total: Int64 = 0
        if hasDuplicates { total += appState.duplicatesTotalWastedBytes }
        return total
    }
    private var taskCount: Int {
        var n = 0
        if hasAIResults { n += 1 }
        if hasDuplicates { n += 1 }
        if hasBundles { n += 1 }
        if appState.largeTotalBytes > 50_000_000 { n += 1 }
        return n
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TidySpacing.xl) {
                switch viewState {
                case .freshStart:   freshStartView
                case .scanning:     scanningView
                case .taskEngine:   taskEngineView
                case .allClean:     allCleanView
                case .completion:   completionView
                }
            }
            .padding(TidySpacing.xxl)
            .animation(.easeInOut(duration: 0.25), value: viewState)
        }
        .navigationTitle("首页")
        .onChange(of: appState.isBusy) { newValue in
            if !newValue && scanWasRunning {
                scanWasRunning = false
            } else if newValue {
                scanWasRunning = true
            }
        }
        .task {
            await appState.loadLargeFiles()
            await appState.refreshAIAnalysisState()
        }
    }

    // MARK: - State views

    /// No data at all — one big friendly CTA
    private var freshStartView: some View {
        VStack(spacing: TidySpacing.xxl) {
            Spacer(minLength: 40)
            VStack(spacing: TidySpacing.lg) {
                Image(systemName: "magnifyingglass.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.blue.gradient)
                Text("扫描你的下载文件夹")
                    .font(.title2.weight(.bold))
                Text("AI 读取文件内容，识别重复和垃圾，\n生成整理计划。误删可从废纸篓恢复。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button {
                appState.scanButtonTappedFromHome()
            } label: {
                Text("开始扫描")
                    .font(.headline)
                    .frame(width: 200, height: 44)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.return, modifiers: .command)
            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity)
    }

    /// Busy — show indeterminate progress
    private var scanningView: some View {
        VStack(spacing: TidySpacing.xl) {
            Spacer(minLength: 40)
            VStack(spacing: TidySpacing.lg) {
                ProgressView()
                    .controlSize(.large)
                    .scaleEffect(1.4)
                let detail = appState.scanProgressDetail.trimmingCharacters(in: .whitespacesAndNewlines)
                Text(detail.isEmpty ? "正在扫描..." : detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if appState.totalFilesScanned > 0 {
                    Text("已发现 \(appState.totalFilesScanned) 个文件")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity)
    }

    /// The core task-engine view — "X 件事要处理"
    @ViewBuilder
    private var taskEngineView: some View {
        // Header
        VStack(alignment: .leading, spacing: 4) {
            Text("发现 \(taskCount) 件事要处理")
                .font(.title2.weight(.bold))
            Text("共扫描 \(appState.totalFilesScanned) 个文件 · AI 已分析 \(appState.aiAnalyzedFilesCount) 个")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        // Task cards — ordered by impact
        if hasAIResults {
            aiTaskCard
        }
        if hasDuplicates {
            duplicateTaskCard
        }
        if hasBundles {
            bundlesTaskCard
        }
        if appState.largeTotalBytes > 50_000_000 {
            largeFilesTaskCard
        }

        // AI nudges (don't count as tasks but show below real tasks)
        if !hasAIResults && appState.aiAnalyzedFilesCount == 0 {
            if hasAnyAIKey {
                aiAnalysisNudge
            } else {
                aiKeyNudge
            }
        }

        // Archive root nudge
        if appState.archiveRootPath.isEmpty {
            archiveRootNudge
        }

        // The one big button
        if hasAIResults || hasDuplicates || hasBundles {
            oneButtonSection
        }

        // History backlog
        if !hasRunFullHistoryScan {
            historyBacklogCard
        }

        // Footer
        footerStatsLine
    }

    /// Clean state — nothing to do
    private var allCleanView: some View {
        VStack(spacing: TidySpacing.xl) {
            Spacer(minLength: 40)
            VStack(spacing: TidySpacing.lg) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.green.gradient)
                Text("一切井井有条")
                    .font(.title2.weight(.semibold))
                Text("没有待处理文件。Tidy 会在后台继续守候，发现新文件会立即提醒你。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if !hasAnyAIKey {
                    Button("开启 AI 分析（免费）→") {
                        appState.openSettings()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else if appState.aiAnalyzedFilesCount == 0 && appState.totalFilesScanned > 0 {
                    Button {
                        Task { await appState.analyzeNewFiles() }
                    } label: {
                        Label(appState.isAIAnalyzing ? "分析中..." : "运行 AI 深度分析", systemImage: "sparkles")
                    }
                    .buttonStyle(.bordered)
                    .disabled(appState.isAIAnalyzing)
                }
            }
            if !hasRunFullHistoryScan {
                historyBacklogCard
            }
            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity)
    }

    /// Shown right after executing everything
    private var completionView: some View {
        VStack(spacing: TidySpacing.xl) {
            Spacer(minLength: 40)
            VStack(spacing: TidySpacing.lg) {
                Image(systemName: "party.popper.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.purple.gradient)
                Text("整理完成 🎉")
                    .font(.title2.weight(.bold))

                if let s = completionSummary {
                    VStack(spacing: 6) {
                        if s.archived > 0 {
                            Label("归档了 \(s.archived) 个文件", systemImage: "folder.fill.badge.plus")
                                .foregroundStyle(.purple)
                        }
                        if s.deleted > 0 {
                            Label("删除了 \(s.deleted) 个文件", systemImage: "trash.fill")
                                .foregroundStyle(.orange)
                        }
                        if s.freedBytes > 0 {
                            Label("释放了 \(SizeFormatter.string(from: s.freedBytes))", systemImage: "externaldrive.badge.checkmark")
                                .foregroundStyle(.green)
                        }
                    }
                    .font(.subheadline.weight(.medium))
                }

                Text("文件已移到废纸篓，可随时恢复")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: TidySpacing.md) {
                Button("查看操作记录") {
                    appState.pendingTab = .changeLog
                }
                .buttonStyle(.bordered)
                Button("返回首页") {
                    withAnimation { showCompletion = false }
                }
                .buttonStyle(.borderedProminent)
            }
            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Task Cards

    private var aiTaskCard: some View {
        VStack(alignment: .leading, spacing: TidySpacing.md) {
            HStack(spacing: TidySpacing.sm) {
                Image(systemName: "brain.filled.head.profile")
                    .foregroundStyle(.purple)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("AI 整理计划")
                        .font(.subheadline.weight(.semibold))
                    Group {
                        let parts = [
                            aiArchiveCount > 0 ? "归档 \(aiArchiveCount) 个文件" : nil,
                            aiDeleteCount > 0 ? "删除 \(aiDeleteCount) 个文件" : nil
                        ].compactMap { $0 }
                        Text(parts.joined(separator: " · "))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                // Preview folders
                if aiArchiveCount > 0 {
                    let folders = Array(
                        Set(appState.aiIntelligenceItems
                            .filter { $0.keepOrDelete == .keep && !$0.suggestedFolder.isEmpty }
                            .map { $0.suggestedFolder })
                    ).prefix(3)
                    VStack(alignment: .trailing, spacing: 2) {
                        ForEach(Array(folders), id: \.self) { folder in
                            Text(folder)
                                .font(.caption2)
                                .foregroundStyle(.purple.opacity(0.8))
                                .lineLimit(1)
                        }
                    }
                }
            }

            Button("查看详细计划") {
                appState.pendingTab = .aiFiles
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.purple)
        }
        .padding(TidySpacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.purple.opacity(TidyOpacity.medium))
        .clipShape(RoundedRectangle(cornerRadius: TidyRadius.xl))
    }

    private var duplicateTaskCard: some View {
        VStack(alignment: .leading, spacing: TidySpacing.md) {
            HStack(spacing: TidySpacing.sm) {
                Image(systemName: "doc.on.doc.fill")
                    .foregroundStyle(.orange)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("重复文件")
                        .font(.subheadline.weight(.semibold))
                    Text("\(appState.duplicateGroups.count) 组重复 · 可释放 \(SizeFormatter.string(from: appState.duplicatesTotalWastedBytes))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            Button("查看重复文件") {
                appState.pendingTab = .duplicates
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.orange)
        }
        .padding(TidySpacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(TidyOpacity.medium))
        .clipShape(RoundedRectangle(cornerRadius: TidyRadius.xl))
    }

    private var bundlesTaskCard: some View {
        VStack(alignment: .leading, spacing: TidySpacing.md) {
            HStack(spacing: TidySpacing.sm) {
                Image(systemName: "folder.badge.gearshape")
                    .foregroundStyle(.green)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("整理建议")
                        .font(.subheadline.weight(.semibold))
                    Text("\(appState.bundles.count) 条归档方案待确认")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            Button("逐条确认") {
                appState.pendingTab = .bundles
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.green)
        }
        .padding(TidySpacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(TidyOpacity.medium))
        .clipShape(RoundedRectangle(cornerRadius: TidyRadius.xl))
    }

    private var largeFilesTaskCard: some View {
        VStack(alignment: .leading, spacing: TidySpacing.md) {
            HStack(spacing: TidySpacing.sm) {
                Image(systemName: "externaldrive.badge.minus")
                    .foregroundStyle(.blue)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("大文件")
                        .font(.subheadline.weight(.semibold))
                    Text("\(appState.largeFiles.count) 个文件 · 共 \(SizeFormatter.string(from: appState.largeTotalBytes))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            Button("查看大文件") {
                appState.pendingTab = .cleanup
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.blue)
        }
        .padding(TidySpacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(TidyOpacity.medium))
        .clipShape(RoundedRectangle(cornerRadius: TidyRadius.xl))
    }

    // MARK: - The one button

    private var oneButtonSection: some View {
        VStack(spacing: TidySpacing.sm) {
            Button {
                executeAll()
            } label: {
                if isExecutingAll {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("整理中...")
                    }
                    .frame(maxWidth: .infinity, minHeight: 50)
                } else {
                    VStack(spacing: 2) {
                        Text("全部一键搞定")
                            .font(.headline)
                        if estimatedFreedBytes > 0 {
                            Text("约释放 \(SizeFormatter.string(from: estimatedFreedBytes))")
                                .font(.caption)
                                .opacity(0.85)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 50)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.accentColor)
            .disabled(isExecutingAll || appState.isBusy)

            Text("文件会移到废纸篓，可随时撤销")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.top, TidySpacing.sm)
    }

    // MARK: - Nudge cards (don't count as tasks)

    private var aiAnalysisNudge: some View {
        HStack(spacing: TidySpacing.md) {
            Image(systemName: "sparkles")
                .foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 2) {
                Text("还没有 AI 分析结果")
                    .font(.caption.weight(.medium))
                Text("AI 会读取文件内容，给出更精准的整理建议")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(appState.isAIAnalyzing ? "分析中..." : "立即分析") {
                Task { await appState.analyzeNewFiles() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(appState.isAIAnalyzing)
        }
        .padding(TidySpacing.lg)
        .background(Color.purple.opacity(TidyOpacity.ultraLight))
        .clipShape(RoundedRectangle(cornerRadius: TidyRadius.lg))
        .overlay(RoundedRectangle(cornerRadius: TidyRadius.lg).strokeBorder(Color.purple.opacity(0.15), lineWidth: 1))
    }

    private var aiKeyNudge: some View {
        HStack(spacing: TidySpacing.md) {
            Image(systemName: "key.fill")
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("开启 AI 分析，整理更精准")
                    .font(.caption.weight(.medium))
                Text("Gemini Flash 完全免费，只需 Google 账号")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("配置 Key →") {
                appState.openSettings()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(TidySpacing.lg)
        .background(Color.blue.opacity(TidyOpacity.ultraLight))
        .clipShape(RoundedRectangle(cornerRadius: TidyRadius.lg))
        .overlay(RoundedRectangle(cornerRadius: TidyRadius.lg).strokeBorder(Color.blue.opacity(0.15), lineWidth: 1))
    }

    private var archiveRootNudge: some View {
        Button {
            Task { await appState.setupDefaultArchiveRoot() }
        } label: {
            HStack(spacing: TidySpacing.sm) {
                Image(systemName: "folder.badge.plus")
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("设置整理文件夹后可执行归档")
                        .font(.caption.weight(.medium))
                    Text("点击使用默认位置 ~/Documents/Tidy Archive")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(TidySpacing.lg)
            .background(Color.accentColor.opacity(TidyOpacity.ultraLight))
            .clipShape(RoundedRectangle(cornerRadius: TidyRadius.lg))
        }
        .buttonStyle(.plain)
    }

    // MARK: - History backlog

    private var historyBacklogCard: some View {
        HStack(spacing: TidySpacing.md) {
            Text("🗂")
            VStack(alignment: .leading, spacing: 2) {
                Text("还没整理过历史积压？")
                    .font(.caption.weight(.semibold))
                Text("一次性扫描多年来积压的 PDF、截图和安装包")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("扫一次 →") {
                hasRunFullHistoryScan = true
                Task { await appState.runFullHistoryScan() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(appState.isBusy)
        }
        .padding(TidySpacing.lg)
        .background(Color.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: TidyRadius.lg))
    }

    // MARK: - Footer

    private var footerStatsLine: some View {
        HStack(spacing: 6) {
            Text("\(appState.totalFilesScanned) 个文件")
            Text("·")
            Text("\(appState.duplicateGroups.count) 组重复")
            Text("·")
            Text("AI 已分析 \(appState.aiAnalyzedFilesCount) 个")
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }

    // MARK: - Actions

    private func executeAll() {
        isExecutingAll = true
        Task {
            let summary = await appState.executeAllRecommendations()
            await MainActor.run {
                completionSummary = summary
                isExecutingAll = false
                withAnimation { showCompletion = true }
            }
        }
    }
}
