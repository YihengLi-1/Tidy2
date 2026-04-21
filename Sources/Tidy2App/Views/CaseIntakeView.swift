import AppKit
import SwiftUI

// MARK: - Legal Evidence Categories

private enum LegalCategory: String, CaseIterable {
    case award        = "奖项"
    case press        = "媒体报道"
    case expertLetter = "专家推荐信"
    case publication  = "学术论文"
    case certificate  = "证书"
    case membership   = "会员资格"
    case judging      = "评审经历"
    case originalWork = "原创贡献"
    case salary       = "薪资证明"
    case criticalRole = "关键职位"
    case recommendation = "推荐信"
    case other        = "其他"

    var icon: String {
        switch self {
        case .award:          return "trophy.fill"
        case .press:          return "newspaper.fill"
        case .expertLetter:   return "envelope.open.fill"
        case .publication:    return "doc.richtext.fill"
        case .certificate:    return "rosette"
        case .membership:     return "person.2.fill"
        case .judging:        return "checkmark.seal.fill"
        case .originalWork:   return "lightbulb.fill"
        case .salary:         return "banknote"
        case .criticalRole:   return "building.2.fill"
        case .recommendation: return "hand.thumbsup.fill"
        case .other:          return "folder.fill"
        }
    }

    var color: Color {
        switch self {
        case .award:          return .yellow
        case .press:          return .blue
        case .expertLetter:   return .green
        case .publication:    return .purple
        case .certificate:    return .orange
        case .membership:     return .teal
        case .judging:        return .indigo
        case .originalWork:   return .pink
        case .salary:         return Color(red: 0.2, green: 0.6, blue: 0.3)
        case .criticalRole:   return .red
        case .recommendation: return .cyan
        case .other:          return .secondary
        }
    }

    /// Minimum count considered sufficient for EB-1/O-1
    var minimumRecommended: Int {
        switch self {
        case .award:          return 3
        case .press:          return 3
        case .expertLetter:   return 3
        case .publication:    return 5
        case .judging:        return 2
        case .originalWork:   return 1
        default:              return 0
        }
    }

    /// Short description of the EB-1 criterion
    var eb1Criterion: String? {
        switch self {
        case .award:          return "EB-1 标准一：国家级/国际级奖项"
        case .press:          return "EB-1 标准三：媒体报道"
        case .expertLetter:   return "EB-1 标准八：专家证明"
        case .publication:    return "EB-1 标准六：学术论文引用"
        case .judging:        return "EB-1 标准四：担任评审"
        case .originalWork:   return "EB-1 标准五：原创贡献"
        case .membership:     return "EB-1 标准二：专业学会会员"
        case .salary:         return "EB-1 标准九：高薪证明"
        case .criticalRole:   return "EB-1 标准八：关键职位"
        default:              return nil
        }
    }
}

// MARK: - View

struct CaseIntakeView: View {
    @EnvironmentObject private var appState: AppState

    @State private var selectedTab: Tab = .timeline
    @State private var copiedSummary = false
    @State private var showReplaceConfirmation = false

    private enum Tab: String, CaseIterable {
        case timeline   = "时间线"
        case categories = "类别"
        case gaps       = "缺口分析"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TidySpacing.xl) {

                // ── Header ─────────────────────────────────────────
                headerSection

                // ── Intake control ─────────────────────────────────
                intakeControlSection

                // ── Progress ───────────────────────────────────────
                if appState.isCaseIntakeRunning {
                    progressSection
                }

                // ── Error state ────────────────────────────────────
                if let err = appState.caseIntakeError {
                    VStack(spacing: TidySpacing.lg) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(.orange)
                        Text("分析遇到问题")
                            .font(.headline)
                        Text(err)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("重新选择文件夹") {
                            Task { await appState.selectCaseIntakeFolder() }
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(TidySpacing.xxl)
                    .frame(maxWidth: .infinity)
                }

                // ── Content tabs ───────────────────────────────────
                if !appState.caseDocuments.isEmpty {
                    Picker("视图", selection: $selectedTab) {
                        ForEach(Tab.allCases, id: \.self) { tab in
                            Text(tab.rawValue).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)

                    switch selectedTab {
                    case .timeline:   timelineSection
                    case .categories: categoriesSection
                    case .gaps:       gapAnalysisSection
                    }

                    exportSection
                }

                if appState.caseDocuments.isEmpty && !appState.isCaseIntakeRunning && !appState.caseIntakeFolderPath.isEmpty {
                    analyzeNowSection
                }

                if appState.caseIntakeFolderPath.isEmpty {
                    emptyState
                }
            }
            .padding(TidySpacing.xxl)
        }
        .navigationTitle("案件助手")
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: TidySpacing.sm) {
            HStack(spacing: TidySpacing.sm) {
                Image(systemName: "doc.badge.clock.fill")
                    .foregroundStyle(.blue)
                    .font(.title3)
                Text("移民案件文件整理")
                    .font(.title3.weight(.semibold))
            }
            Text("选择客户文件夹，AI 自动读取所有文件内容，生成 EB-1/O-1 证据时间线和缺口分析")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(TidySpacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tidyColorCard(.blue, radius: TidyRadius.xl, opacity: TidyOpacity.ultraLight)
    }

    // MARK: - Intake Control

    private var intakeControlSection: some View {
        HStack(spacing: TidySpacing.lg) {
            VStack(alignment: .leading, spacing: TidySpacing.xxs) {
                if appState.caseIntakeFolderPath.isEmpty {
                    Text("尚未选择文件夹")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                } else {
                    Text(URL(fileURLWithPath: appState.caseIntakeFolderPath).lastPathComponent)
                        .font(.subheadline.weight(.medium))
                    Text(appState.caseIntakeFolderPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            Button {
                if appState.caseDocuments.isEmpty {
                    Task {
                        if let path = await appState.selectCaseIntakeFolder() {
                            await appState.runCaseIntake(folderPath: path)
                        }
                    }
                } else {
                    showReplaceConfirmation = true
                }
            } label: {
                Label(appState.caseIntakeFolderPath.isEmpty ? "选择客户文件夹" : "重新选择", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.borderedProminent)
            .disabled(appState.isCaseIntakeRunning)
            .confirmationDialog("重新选择文件夹将清除当前分析结果，确定继续？", isPresented: $showReplaceConfirmation, titleVisibility: .visible) {
                Button("重新选择", role: .destructive) {
                    Task {
                        if let path = await appState.selectCaseIntakeFolder() {
                            await appState.runCaseIntake(folderPath: path)
                        }
                    }
                }
                Button("取消", role: .cancel) {}
            }
        }
        .padding(TidySpacing.xl)
        .tidyCard(radius: TidyRadius.lg)
    }

    // MARK: - Progress

    private var progressSection: some View {
        let (current, total) = appState.caseIntakeProgress
        let fraction = total > 0 ? Double(current) / Double(total) : 0
        return VStack(alignment: .leading, spacing: TidySpacing.sm) {
            HStack {
                ProgressView().controlSize(.small)
                Text("AI 正在分析文件 \(current) / \(total)…")
                    .font(.subheadline)
                Spacer()
                Text("\(Int(fraction * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button("取消") {
                    appState.cancelCaseIntake()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .foregroundStyle(.secondary)
            }
            ProgressView(value: fraction)
                .tint(.purple)
        }
        .padding(TidySpacing.xl)
        .tidyColorCard(.purple, radius: TidyRadius.lg, opacity: TidyOpacity.light)
    }

    // MARK: - Analyze Now (folder selected, no results yet)

    private var analyzeNowSection: some View {
        VStack(alignment: .leading, spacing: TidySpacing.lg) {
            HStack(spacing: TidySpacing.sm) {
                Image(systemName: "brain").foregroundStyle(.purple)
                Text("文件夹已选择，点击开始 AI 分析")
                    .font(.subheadline.weight(.medium))
            }
            Button {
                Task { await appState.runCaseIntake(folderPath: appState.caseIntakeFolderPath) }
            } label: {
                Label("开始分析", systemImage: "sparkles")
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
        }
        .padding(TidySpacing.xl)
        .tidyColorCard(.purple, radius: TidyRadius.lg, opacity: TidyOpacity.light)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: TidySpacing.xl) {
            Image(systemName: "doc.badge.clock")
                .font(.system(size: 52))
                .foregroundStyle(.blue.opacity(0.5))
            VStack(spacing: TidySpacing.sm) {
                Text("选择客户文件夹开始整理")
                    .font(.title3.weight(.semibold))
                Text("支持 PDF、图片（证书扫描件）、文本文件\n子目录内的文件会自动递归扫描")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            VStack(alignment: .leading, spacing: TidySpacing.sm) {
                tipRow("AI 读取每份文件内容，识别证据类型")
                tipRow("按年份生成时间线，一眼看到职业轨迹")
                tipRow("自动比对 EB-1/O-1 十大标准，找出缺口")
                tipRow("40小时手工整理 → 20分钟 AI 辅助核查")
            }
            .padding(TidySpacing.xl)
            .tidyCard(radius: TidyRadius.lg)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func tipRow(_ text: String) -> some View {
        HStack(spacing: TidySpacing.sm) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Timeline Section

    private var timelineSection: some View {
        let byYear = Dictionary(grouping: appState.caseDocuments) { $0.projectGroup ?? "未知" }
        let sortedYears = byYear.keys.sorted { a, b in
            if a == "未知" { return false }
            if b == "未知" { return true }
            return a > b  // most recent first
        }
        return VStack(alignment: .leading, spacing: TidySpacing.lg) {
            Text("时间线")
                .font(.title3.weight(.semibold))
            Text("共 \(appState.caseDocuments.count) 份文件，跨越 \(sortedYears.filter { $0 != "未知" }.count) 个年份")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(sortedYears, id: \.self) { year in
                yearBlock(year: year, docs: byYear[year] ?? [])
            }
        }
    }

    private func yearBlock(year: String, docs: [FileIntelligence]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Year header
            HStack(spacing: TidySpacing.sm) {
                Text(year)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, TidySpacing.lg)
                    .padding(.vertical, TidySpacing.xs)
                    .background(Color.blue)
                    .clipShape(Capsule())
                Text("\(docs.count) 份")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.bottom, TidySpacing.sm)

            // Documents in this year, grouped by category
            let byCat = Dictionary(grouping: docs) { $0.suggestedFolder }
            let sortedCats = byCat.keys.sorted()
            VStack(alignment: .leading, spacing: TidySpacing.xs) {
                ForEach(sortedCats, id: \.self) { cat in
                    ForEach(byCat[cat] ?? [], id: \.filePath) { doc in
                        timelineDocRow(doc: doc, category: cat)
                    }
                }
            }
            .padding(.leading, TidySpacing.lg)
        }
        .padding(TidySpacing.lg)
        .background(Color.gray.opacity(TidyOpacity.ultraLight))
        .clipShape(RoundedRectangle(cornerRadius: TidyRadius.lg))
    }

    private func timelineDocRow(doc: FileIntelligence, category: String) -> some View {
        let cat = LegalCategory(rawValue: category) ?? .other
        return HStack(spacing: TidySpacing.sm) {
            Image(systemName: cat.icon)
                .foregroundStyle(cat.color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(doc.summary.isEmpty ? URL(fileURLWithPath: doc.filePath).lastPathComponent : doc.summary)
                    .font(.subheadline)
                    .lineLimit(2)
                HStack(spacing: TidySpacing.xs) {
                    Text(category)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(cat.color)
                        .padding(.horizontal, TidySpacing.xs)
                        .padding(.vertical, 1)
                        .background(cat.color.opacity(TidyOpacity.medium))
                        .clipShape(Capsule())
                    if let org = doc.extractedName, !org.isEmpty {
                        Text(org)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, TidySpacing.xs)
    }

    // MARK: - Categories Section

    private var categoriesSection: some View {
        let byCategory = Dictionary(grouping: appState.caseDocuments) { $0.suggestedFolder }
        let sorted = byCategory.sorted { $0.value.count > $1.value.count }
        return VStack(alignment: .leading, spacing: TidySpacing.lg) {
            Text("证据类别")
                .font(.title3.weight(.semibold))
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: TidySpacing.md) {
                ForEach(sorted, id: \.key) { cat, docs in
                    categoryCard(category: cat, docs: docs)
                }
            }
        }
    }

    private func categoryCard(category: String, docs: [FileIntelligence]) -> some View {
        let cat = LegalCategory(rawValue: category) ?? .other
        return VStack(alignment: .leading, spacing: TidySpacing.sm) {
            HStack(spacing: TidySpacing.sm) {
                Image(systemName: cat.icon)
                    .foregroundStyle(cat.color)
                Text(category)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(docs.count)")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(cat.color)
            }
            Divider()
            ForEach(docs.prefix(3), id: \.filePath) { doc in
                Text(doc.summary.isEmpty ? URL(fileURLWithPath: doc.filePath).lastPathComponent : doc.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if docs.count > 3 {
                Text("还有 \(docs.count - 3) 份…")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(TidySpacing.lg)
        .background(cat.color.opacity(TidyOpacity.ultraLight))
        .clipShape(RoundedRectangle(cornerRadius: TidyRadius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: TidyRadius.lg)
                .strokeBorder(cat.color.opacity(0.2), lineWidth: 1)
        )
    }

    // MARK: - Gap Analysis Section

    private var gapAnalysisSection: some View {
        let counts = Dictionary(grouping: appState.caseDocuments) { $0.suggestedFolder }
        let keyCategories: [LegalCategory] = [.award, .press, .expertLetter, .publication, .judging, .originalWork, .membership, .salary, .criticalRole]

        return VStack(alignment: .leading, spacing: TidySpacing.lg) {
            VStack(alignment: .leading, spacing: TidySpacing.xs) {
                Text("EB-1/O-1 缺口分析")
                    .font(.title3.weight(.semibold))
                Text("满足任意 3 项标准即可提交 EB-1。绿色表示文件数量充足，橙色表示可能需要补充。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            let satisfiedCount = keyCategories.filter { cat in
                let count = counts[cat.rawValue]?.count ?? 0
                return cat.minimumRecommended == 0 ? count > 0 : count >= cat.minimumRecommended
            }.count

            // Summary bar
            HStack(spacing: TidySpacing.sm) {
                Text("满足标准")
                    .font(.subheadline.weight(.medium))
                Text("\(satisfiedCount) / \(keyCategories.filter { $0.minimumRecommended > 0 || $0 == .criticalRole }.count)")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(satisfiedCount >= 3 ? Color.green : Color.orange)
                Spacer()
                if satisfiedCount >= 3 {
                    Label("初步达标", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.green)
                } else {
                    Label("需补充材料", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                }
            }
            .padding(TidySpacing.lg)
            .background(satisfiedCount >= 3 ? Color.green.opacity(TidyOpacity.ultraLight) : Color.orange.opacity(TidyOpacity.ultraLight))
            .clipShape(RoundedRectangle(cornerRadius: TidyRadius.md))

            ForEach(keyCategories, id: \.rawValue) { cat in
                let count = counts[cat.rawValue]?.count ?? 0
                gapRow(category: cat, count: count)
            }
        }
    }

    private func gapRow(category: LegalCategory, count: Int) -> some View {
        let minRec = category.minimumRecommended
        let isSatisfied = minRec == 0 ? count > 0 : count >= minRec
        let statusColor: Color = count == 0 ? .secondary : (isSatisfied ? .green : .orange)

        return HStack(spacing: TidySpacing.md) {
            Image(systemName: category.icon)
                .foregroundStyle(category.color)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(category.rawValue)
                    .font(.subheadline.weight(.medium))
                if let criterion = category.eb1Criterion {
                    Text(criterion)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 4) {
                    Text("\(count) 份")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(statusColor)
                    if minRec > 0 {
                        Text("/ 建议 \(minRec)+")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if count == 0 {
                    Text("未找到相关文件")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if !isSatisfied && minRec > 0 {
                    Text("建议补充 \(minRec - count) 份")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                } else if isSatisfied {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                }
            }
        }
        .padding(TidySpacing.lg)
        .background(Color.gray.opacity(isSatisfied ? TidyOpacity.ultraLight : (count == 0 ? 0 : TidyOpacity.ultraLight)))
        .clipShape(RoundedRectangle(cornerRadius: TidyRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: TidyRadius.md)
                .strokeBorder(statusColor.opacity(isSatisfied ? 0.3 : (count == 0 ? 0.1 : 0.3)), lineWidth: 1)
        )
    }

    // MARK: - Export Section

    private var exportSection: some View {
        VStack(alignment: .leading, spacing: TidySpacing.md) {
            Text("导出")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: TidySpacing.md) {
                Button {
                    let summary = appState.exportCaseSummary()
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(summary, forType: .string)
                    copiedSummary = true
                    Task {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        await MainActor.run { copiedSummary = false }
                    }
                } label: {
                    Label(copiedSummary ? "已复制！" : "复制完整清单", systemImage: copiedSummary ? "checkmark" : "doc.on.clipboard")
                }
                .buttonStyle(.borderedProminent)
                .tint(copiedSummary ? .green : .accentColor)

                Button {
                    appState.openCaseIntakeFolderInFinder()
                } label: {
                    Label("在 Finder 中打开案件文件夹", systemImage: "folder.badge.magnifyingglass")
                }
                .buttonStyle(.bordered)
                .disabled(appState.caseIntakeFolderPath.isEmpty)
            }

            Text("清单包含 EB-1 标准达标情况、证据时间线、类别统计，可直接粘贴到 Word/Notion 作为律师底稿")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(TidySpacing.xl)
        .tidyCard(radius: TidyRadius.lg)
    }

    // MARK: - Helpers

    private var documentsByYear: [(String, [FileIntelligence])] {
        let grouped = Dictionary(grouping: appState.caseDocuments) { $0.projectGroup ?? "未知" }
        return grouped.sorted { a, b in
            if a.key == "未知" { return false }
            if b.key == "未知" { return true }
            return a.key > b.key
        }
    }
}
