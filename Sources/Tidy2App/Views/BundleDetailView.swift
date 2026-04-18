import AppKit
import QuickLookUI
import SwiftUI

struct BundleDetailView: View {
    @EnvironmentObject private var appState: AppState
    let bundleID: String

    @State private var previewURL: URL? = nil
    @State private var previewNonce = 0
    @State private var renameTemplate: String = ""
    @State private var selectedActionKind: BundleActionKind = .rename
    @State private var selectedTargetPath: String = ""
    @State private var selectedTargetBookmark: Data?
    @State private var useBundleTargetOverride: Bool = false
    @State private var allowHighRiskMoveOverride: Bool = false
    @State private var showAdvancedDetails: Bool = false
    @State private var showFullTargetPath: Bool = false
    @State private var showAllEvidence: Bool = false
    @State private var isApplying: Bool = false
    @State private var applyBannerText: String?
    @State private var applyBannerIsError: Bool = false
    @State private var aiFolderCopied = false

    var body: some View {
        Group {
            if let bundle = appState.bundle(by: bundleID) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        summaryBlock(bundle)
                        aiInsightsCard(bundle)
                        fileListSection(bundle)
                        advancedBlock(bundle)
                        actionBar(bundle)

                        if let applyBannerText {
                            Text(applyBannerText)
                                .font(.subheadline)
                                .foregroundStyle(applyBannerIsError ? .red : .secondary)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background((applyBannerIsError ? Color.red : Color.gray).opacity(0.10))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    .padding(24)
                }
                .onAppear {
                    selectedActionKind = bundle.action.actionKind
                    if renameTemplate.isEmpty {
                        renameTemplate = bundle.action.renameTemplate ?? ""
                    }
                    if let bookmark = bundle.action.targetFolderBookmark,
                       let url = resolveBookmarkURL(bookmark) {
                        selectedTargetBookmark = bookmark
                        selectedTargetPath = url.path
                    }
                    showFullTargetPath = false
                    Task { await appState.refreshBundleMissingCount(bundleID: bundle.id) }
                }
            } else {
                Text("该整理建议已不存在。")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("整理建议详情")
        .background(
            QuickLookView(url: previewURL, nonce: previewNonce)
                .frame(width: 0, height: 0)
        )
        .onDisappear {
            if QLPreviewPanel.sharedPreviewPanelExists(),
               let panel = QLPreviewPanel.shared() {
                panel.orderOut(nil)
            }
        }
    }

    private func summaryBlock(_ bundle: DecisionBundle) -> some View {
        let missing = appState.missingFilesCount(bundleID: bundle.id)
        let count = max(0, bundle.filePaths.count - missing)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(primarySentence(bundle: bundle, actionableCount: count, missing: missing, expandPath: showFullTargetPath))
                    .font(.title3.weight(.semibold))
                    .lineLimit(showFullTargetPath ? 3 : 1)
                    .truncationMode(.middle)

                if selectedActionKind == .move, canExpandPath(bundle) {
                    Button(showFullTargetPath ? "收起路径" : "显示完整路径") {
                        showFullTargetPath.toggle()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }

            if missing > 0 {
                Text("有 \(missing) 个文件已消失，将自动跳过")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            } else {
                Text("所有文件均存在，可直接处理。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func actionBar(_ bundle: DecisionBundle) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button("确认执行") {
                    acceptBundle(bundle)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(isApplying)

                Button("跳过这条") {
                    skipBundle(bundle)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(isApplying)

                if isApplying {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Text("确认后会立即执行这条整理建议，并自动返回建议列表。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func fileListSection(_ bundle: DecisionBundle) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("涉及文件")
                .font(.headline)

            ForEach(Array(bundle.filePaths.enumerated()), id: \.element) { index, path in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: actionIcon(for: selectedActionKind))
                        .foregroundStyle(actionColor(for: selectedActionKind))
                        .frame(width: 18, height: 18)
                        .padding(.top, 2)

                    VStack(alignment: .leading, spacing: 4) {
                        Button {
                            openPreview(for: path)
                        } label: {
                            Text(URL(fileURLWithPath: path).lastPathComponent)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .underline()
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .buttonStyle(.plain)
                        .overlay(alignment: .topTrailing) {
                            if index == 0 {
                                Text("点击文件名预览")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .offset(x: 120)
                            }
                        }

                        Text("→ \(targetSummary(for: path, bundle: bundle))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Text(FileExplanationBuilder.explanation(path: path, bundleType: bundle.type))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    Spacer()

                    Button("在 Finder 中显示") {
                        revealInFinder(path: path)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
                .padding(.vertical, 4)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func aiInsightsCard(_ bundle: DecisionBundle) -> some View {
        let items = aiEvidenceItems(bundle)
        if !items.isEmpty {
            let bestConfidence = items.compactMap(\.aiConfidence).max() ?? 0
            let category = items.compactMap(\.aiCategory).first
            let suggestedFolder = items.compactMap(\.aiSuggestedFolder).first(where: { !$0.isEmpty })
            let reason = items
                .sorted { ($0.aiConfidence ?? 0) > ($1.aiConfidence ?? 0) }
                .compactMap { item in
                    let text = item.aiReason?.trimmingCharacters(in: .whitespacesAndNewlines)
                        ?? item.detail.trimmingCharacters(in: .whitespacesAndNewlines)
                    return text.isEmpty ? nil : text
                }
                .first

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("✦ AI 分析")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                    Spacer()
                    if bestConfidence >= 0.5 {
                        Text("置信度 \(Int(bestConfidence * 100))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let category, !category.isEmpty {
                    aiRow(title: "分类", value: category)
                }

                if let suggestedFolder, !suggestedFolder.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        Text("建议位置:")
                            .font(.subheadline.weight(.semibold))
                        Button(suggestedFolder) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(suggestedFolder, forType: .string)
                            aiFolderCopied = true
                            Task {
                                try? await Task.sleep(nanoseconds: 1_200_000_000)
                                await MainActor.run {
                                    aiFolderCopied = false
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                    }

                    if aiFolderCopied {
                        Text("已复制")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let reason, !reason.isEmpty {
                    Text("“\(reason)”")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    private func advancedBlock(_ bundle: DecisionBundle) -> some View {
        DisclosureGroup("高级设置", isExpanded: $showAdvancedDetails) {
            VStack(alignment: .leading, spacing: 12) {
                Picker("操作方式", selection: $selectedActionKind) {
                    Text("移动").tag(BundleActionKind.move)
                    Text("重命名").tag(BundleActionKind.rename)
                    Text("隔离").tag(BundleActionKind.quarantine)
                }
                .pickerStyle(.segmented)

                if selectedActionKind == .move {
                    if bundle.risk == .high {
                        Toggle("允许移动此高风险建议", isOn: $allowHighRiskMoveOverride)
                            .toggleStyle(.switch)
                    }
                    Text("目标路径：\(moveDestinationPath(bundle: bundle, expanded: true))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                TextField("重命名模板（可选）", text: $renameTemplate)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Button("设置整理文件夹") {
                        chooseDefaultArchiveRoot()
                    }

                    Toggle("为本条建议指定目标位置", isOn: $useBundleTargetOverride)
                        .toggleStyle(.switch)
                }

                if useBundleTargetOverride {
                    Button("选择目标文件夹") {
                        chooseBundleOverrideFolder()
                    }

                    if !selectedTargetPath.isEmpty {
                        Text("已指定：\(compactPath(selectedTargetPath))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Text("风险等级：\(riskLabel(bundle.risk))")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(displayedEvidence(bundle: bundle)) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title)
                            .font(.caption.weight(.semibold))
                        Text(item.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if bundle.evidence.count > 3 {
                    Button(showAllEvidence ? "收起依据" : "查看更多依据") {
                        showAllEvidence.toggle()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }

                if bundle.type == .crossDirectoryGroup {
                    crossDirectoryOriginList(bundle)
                }
            }
            .padding(.top, 8)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func acceptBundle(_ bundle: DecisionBundle) {
        guard !isApplying else { return }

        if selectedActionKind == .move && !hasMoveTarget(bundle: bundle) {
            applyBannerText = "请先设置整理文件夹。"
            applyBannerIsError = true
            return
        }

        let override = makeAcceptOverride(bundle: bundle)
        let actionForLog = override?.actionKind ?? bundle.action.actionKind
        appendRuntimeLog("[UI] accept_clicked bundle_id=\(bundle.id) action=\(actionForLog.rawValue) risk=\(bundle.risk.rawValue)")
        startApply(bundleID: bundle.id, override: override)
    }

    private func skipBundle(_ bundle: DecisionBundle) {
        guard !isApplying else { return }
        isApplying = true

        Task {
            await appState.skipBundleToNextWeek(bundleID: bundle.id)
            await MainActor.run {
                isApplying = false
                if !appState.path.isEmpty {
                    appState.path.removeLast()
                }
            }
        }
    }

    private func startApply(bundleID: String, override: BundleApplyOverride?) {
        applyBannerText = nil
        isApplying = true
        let gate = ApplyCompletionGate()

        Task {
            let success = await appState.applyBundle(bundleID: bundleID, override: override)
            let message = humanStatus(appState.statusMessage)

            if await gate.completeIfNeeded() {
                await MainActor.run {
                    isApplying = false
                    applyBannerText = message
                    applyBannerIsError = !success
                    if success, !appState.path.isEmpty {
                        appState.path.removeLast()
                    }
                }
            }
        }

        Task {
            try? await Task.sleep(nanoseconds: 65 * 1_000_000_000)
            if await gate.completeIfNeeded() {
                await MainActor.run {
                    isApplying = false
                    applyBannerText = "操作超时，请重试"
                    applyBannerIsError = true
                    appState.statusMessage = "操作超时，请重试"
                }
                appendRuntimeLog("[UI] apply_timeout bundle_id=\(bundleID)")
            }
        }
    }

    private func makeAcceptOverride(bundle: DecisionBundle) -> BundleApplyOverride? {
        let trimmedTemplate = renameTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentTemplate = bundle.action.renameTemplate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let actionChanged = selectedActionKind != bundle.action.actionKind
        let templateChanged = trimmedTemplate != currentTemplate
        let useRiskOverride = allowHighRiskMoveOverride && selectedActionKind == .move && bundle.risk == .high
        let includeTargetOverride = useBundleTargetOverride

        guard actionChanged || templateChanged || includeTargetOverride || useRiskOverride else {
            return nil
        }

        return BundleApplyOverride(
            actionKind: actionChanged ? selectedActionKind : nil,
            renameTemplate: templateChanged ? (trimmedTemplate.isEmpty ? nil : trimmedTemplate) : nil,
            targetFolderBookmark: includeTargetOverride ? selectedTargetBookmark : nil,
            allowHighRiskMoveOverride: useRiskOverride
        )
    }

    private func displayedEvidence(bundle: DecisionBundle) -> [EvidenceItem] {
        showAllEvidence ? bundle.evidence : Array(bundle.evidence.prefix(3))
    }

    private func aiEvidenceItems(_ bundle: DecisionBundle) -> [EvidenceItem] {
        bundle.evidence.filter {
            $0.kind == .aiClassification || $0.kind == .aiSuggestedFolder || $0.kind == .aiAgeJudgment
        }
    }

    @ViewBuilder
    private func crossDirectoryOriginList(_ bundle: DecisionBundle) -> some View {
        let originItems = bundle.evidence.filter { $0.kind == .crossDirectoryOrigin }
        if !originItems.isEmpty {
            let scopeCount = Set(originItems.compactMap(\.originScope)).count
            VStack(alignment: .leading, spacing: 8) {
                Text("这些文件目前散落在 \(scopeCount) 个位置")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                ForEach(originItems) { item in
                    HStack(alignment: .top, spacing: 6) {
                        Text(item.title)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if let scope = item.originScope {
                            Text("来自: \(scope)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if let folder = item.aiSuggestedFolder, !folder.isEmpty {
                            Text("→")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(URL(fileURLWithPath: folder).lastPathComponent)
                                .font(.caption2)
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
        }
    }

    private func primarySentence(bundle: DecisionBundle, actionableCount: Int, missing: Int, expandPath: Bool) -> String {
        switch selectedActionKind {
        case .move:
            return "将 \(actionableCount) 个文件移动到 \(moveDestinationPath(bundle: bundle, expanded: expandPath))"
        case .rename:
            return "在原位置重命名 \(actionableCount) 个文件"
        case .quarantine:
            return "隔离 \(actionableCount) 个文件"
        }
    }

    private func moveDestinationPath(bundle: DecisionBundle, expanded: Bool) -> String {
        let root = moveRootPath(bundle: bundle)
        let base = root.isEmpty ? "（请先设置整理文件夹）" : root
        let month = DateFormatter.bundleDetailMonth.string(from: Date())
        let full: String
        switch bundle.type {
        case .weeklyDownloadsPDF:
            full = "\(base)/Downloads PDFs/\(month)"
        case .weeklyScreenshots:
            full = "\(base)/Screenshots/\(month)"
        case .weeklyInstallers:
            full = "\(base)/Installers/\(month)"
        case .weeklyDocuments:
            full = "\(base)/Documents/\(month)"
        case .crossDirectoryGroup:
            let suggested = bundle.evidence.compactMap(\.aiSuggestedFolder).first(where: { !$0.isEmpty }) ?? "Organized"
            full = "\(base)/\(suggested)"
        }
        return expanded ? full : compactPath(full)
    }

    private func canExpandPath(_ bundle: DecisionBundle) -> Bool {
        moveDestinationPath(bundle: bundle, expanded: false) != moveDestinationPath(bundle: bundle, expanded: true)
    }

    private func moveRootPath(bundle: DecisionBundle) -> String {
        if useBundleTargetOverride {
            return selectedTargetPath
        }
        if !appState.archiveRootPath.isEmpty {
            return appState.archiveRootPath
        }
        if bundle.action.targetFolderBookmark != nil {
            return selectedTargetPath
        }
        return ""
    }

    private func hasMoveTarget(bundle: DecisionBundle) -> Bool {
        if useBundleTargetOverride {
            return selectedTargetBookmark != nil
        }
        if bundle.action.targetFolderBookmark != nil {
            return true
        }
        return appState.hasDefaultArchiveRoot()
    }

    private func compactPath(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        let components = URL(fileURLWithPath: path).pathComponents.filter { $0 != "/" }
        guard components.count > 2 else { return path }
        return "…/\(components.suffix(2).joined(separator: "/"))"
    }

    private func targetSummary(for path: String, bundle: DecisionBundle) -> String {
        switch selectedActionKind {
        case .move:
            return moveDestinationPath(bundle: bundle, expanded: false)
        case .rename:
            let directory = compactPath(URL(fileURLWithPath: path).deletingLastPathComponent().path)
            let trimmedTemplate = renameTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedTemplate.isEmpty ? "\(directory)（原位置）" : "\(directory)/\(trimmedTemplate)"
        case .quarantine:
            return "隔离区"
        }
    }

    private func actionIcon(for action: BundleActionKind) -> String {
        switch action {
        case .move:
            return "arrow.right.doc.on.clipboard"
        case .rename:
            return "character.cursor.ibeam"
        case .quarantine:
            return "shield"
        }
    }

    private func actionColor(for action: BundleActionKind) -> Color {
        switch action {
        case .move:
            return .accentColor
        case .rename:
            return .orange
        case .quarantine:
            return .red
        }
    }

    private func aiRow(title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("\(title):")
                .font(.subheadline.weight(.semibold))
            Text(value)
                .font(.subheadline)
        }
    }

    private func chooseDefaultArchiveRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "选择整理文件夹"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await appState.saveDefaultArchiveRoot(url: url) }
    }

    private func chooseBundleOverrideFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "选择目标文件夹"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            selectedTargetPath = url.path
            selectedTargetBookmark = bookmark
            useBundleTargetOverride = true
        } catch {
            selectedTargetPath = ""
            selectedTargetBookmark = nil
        }
    }

    private func resolveBookmarkURL(_ data: Data) -> URL? {
        var stale = false
        return try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
    }

    private func humanStatus(_ text: String) -> String {
        if let translated = translatedBundleStatus(text) {
            return translated
        }
        let lower = text.lowercased()
        if lower.contains("bookmark") || lower.contains("txn_id") || lower.contains("db") {
            return "操作失败，请刷新后重试。"
        }
        return text
    }

    private func translatedBundleStatus(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.hasPrefix("Bundle failed: ") {
            let reason = trimmed.replacingOccurrences(of: "Bundle failed: ", with: "")
            if reason == "No file operations succeeded." {
                return "整理失败：没有成功执行任何文件操作。"
            }
            return "整理失败：\(reason)"
        }

        if trimmed.hasPrefix("Applied bundle: moved ") {
            return trimmed
                .replacingOccurrences(of: "Applied bundle: moved ", with: "已执行整理建议：移动了 ")
                .replacingOccurrences(of: " files", with: " 个文件")
                .replacingOccurrences(of: " (skipped ", with: "（已跳过 ")
                .replacingOccurrences(of: " missing)", with: " 个缺失文件）")
                .replacingOccurrences(of: ", ", with: "，")
                .replacingOccurrences(of: " failed", with: " 个失败")
                .replacingOccurrences(of: " skipped by risk policy", with: " 个因风险策略跳过")
                .replacingOccurrences(of: ". First error: ", with: "。首个错误：")
        }

        if trimmed.hasPrefix("Applied bundle: renamed ") {
            return trimmed
                .replacingOccurrences(of: "Applied bundle: renamed ", with: "已执行整理建议：重命名了 ")
                .replacingOccurrences(of: " files", with: " 个文件")
                .replacingOccurrences(of: " (skipped ", with: "（已跳过 ")
                .replacingOccurrences(of: " missing)", with: " 个缺失文件）")
                .replacingOccurrences(of: ", ", with: "，")
                .replacingOccurrences(of: " failed", with: " 个失败")
                .replacingOccurrences(of: " skipped by risk policy", with: " 个因风险策略跳过")
                .replacingOccurrences(of: ". First error: ", with: "。首个错误：")
        }

        if trimmed.hasPrefix("Applied bundle: quarantined ") {
            return trimmed
                .replacingOccurrences(of: "Applied bundle: quarantined ", with: "已执行整理建议：隔离了 ")
                .replacingOccurrences(of: " files", with: " 个文件")
                .replacingOccurrences(of: " (skipped ", with: "（已跳过 ")
                .replacingOccurrences(of: " missing)", with: " 个缺失文件）")
                .replacingOccurrences(of: ", ", with: "，")
                .replacingOccurrences(of: " failed", with: " 个失败")
                .replacingOccurrences(of: " skipped by risk policy", with: " 个因风险策略跳过")
                .replacingOccurrences(of: ". First error: ", with: "。首个错误：")
        }

        if trimmed == "Applied bundle: no successful file operations" {
            return "整理完成，但没有成功执行任何文件操作。"
        }

        return nil
    }

    private func riskLabel(_ risk: RiskLevel) -> String {
        switch risk {
        case .low: return "低"
        case .medium: return "中"
        case .high: return "高"
        }
    }

    private func appendRuntimeLog(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        print(line.trimmingCharacters(in: .newlines))

        do {
            let fm = FileManager.default
            let appSupport = try fm.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("Tidy2", isDirectory: true)

            let logFolder = appSupport.appendingPathComponent("Logs", isDirectory: true)
            if !fm.fileExists(atPath: logFolder.path) {
                try fm.createDirectory(at: logFolder, withIntermediateDirectories: true)
            }

            let logURL = logFolder.appendingPathComponent("runtime.log", isDirectory: false)
            if fm.fileExists(atPath: logURL.path) {
                let handle = try FileHandle(forWritingTo: logURL)
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                if let data = line.data(using: .utf8) {
                    handle.write(data)
                }
            } else {
                try line.write(to: logURL, atomically: true, encoding: .utf8)
            }
        } catch {
            print("[BundleDetailView] runtime.log write failed: \(error.localizedDescription)")
        }
    }
}

private struct QuickLookView: NSViewRepresentable {
    let url: URL?
    let nonce: Int

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        _ = nonce
        guard let url else { return }
        guard let panel = QLPreviewPanel.shared() else { return }
        context.coordinator.url = url
        panel.dataSource = context.coordinator
        panel.delegate = context.coordinator
        panel.currentPreviewItemIndex = 0
        if panel.isVisible {
            panel.reloadData()
        } else {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    final class Coordinator: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
        var url: URL?

        init(url: URL?) {
            self.url = url
            super.init()
        }

        func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
            url == nil ? 0 : 1
        }

        func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
            url as NSURL?
        }
    }
}

private actor ApplyCompletionGate {
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
    static let bundleDetailMonth: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        return formatter
    }()
}

private extension BundleDetailView {
    func openPreview(for path: String) {
        let url = URL(fileURLWithPath: path)
        if previewURL == url {
            previewNonce += 1
        } else {
            previewURL = url
        }
    }

    func revealInFinder(path: String) {
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
