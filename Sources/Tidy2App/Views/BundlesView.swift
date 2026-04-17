import SwiftUI

struct BundlesView: View {
    @EnvironmentObject private var appState: AppState
    @State private var isApplyingLowRisk = false
    @State private var isApplyingAll = false
    @State private var feedbackToast: String? = nil
    @State private var showApplyAllConfirm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                summaryCard

                if let feedbackToast {
                    Text(feedbackToast)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.green)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.green.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .transition(.opacity)
                }

                if shouldShowToast {
                    Text(humanStatus(appState.statusMessage))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.blue.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                if appState.bundles.isEmpty {
                    emptyState
                } else {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(appState.bundles) { bundle in
                            BundleCard(
                                bundle: bundle,
                                missingCount: appState.missingFilesCount(bundleID: bundle.id),
                                archiveRootPath: appState.archiveRootPath,
                                isDisabled: appState.isBusy || isApplyingAll || isApplyingLowRisk,
                                onReview: { appState.openBundleDetail(bundle) },
                                onSkip: { skip(bundle) },
                                onConfirm: { confirm(bundle) }
                            )
                        }
                    }
                }
            }
            .padding(24)
            .animation(.easeInOut(duration: 0.25), value: feedbackToast != nil)
        }
        .navigationTitle("整理建议")
        .task {
            await appState.refreshTotalFilesScanned()
            await appState.loadBundles()
        }
        .confirmationDialog(
            "确认全部执行这些建议？",
            isPresented: $showApplyAllConfirm,
            titleVisibility: .visible
        ) {
            Button("全部确认") {
                confirmAllBundles()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将依次执行当前列表中的 \(appState.bundles.count) 条建议。")
        }
    }

    private var lowRiskBundles: [DecisionBundle] {
        appState.bundles.filter { $0.risk == .low }
    }

    @ViewBuilder
    private var emptyState: some View {
        if appState.totalFilesScanned > 0 {
            EmptyStateView(
                icon: "square.stack.3d.up",
                title: "暂无整理建议",
                subtitle: "完成扫描后，AI 会自动生成文件归档方案"
            )
            .frame(maxWidth: .infinity, minHeight: 320)
        } else {
            EmptyStateView(
                icon: "sparkles",
                title: "先扫描一次",
                subtitle: "完成扫描后，这里会出现可以直接确认的整理建议",
                action: { appState.scanButtonTappedFromHome() },
                actionLabel: "开始扫描"
            )
            .frame(maxWidth: .infinity, minHeight: 320)
        }
    }

    private var summaryCard: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(appState.bundles.count) 条建议等待确认")
                    .font(.headline)
                Text("确认后会立即执行整理，并自动从列表中移除。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 10) {
                if !lowRiskBundles.isEmpty {
                    Button(isApplyingLowRisk ? "正在接受低风险建议..." : "接受低风险") {
                        acceptAllLowRisk()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .disabled(appState.isBusy || isApplyingLowRisk || isApplyingAll)
                }

                Button(isApplyingAll ? "正在全部确认..." : "全部确认") {
                    showApplyAllConfirm = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(appState.bundles.isEmpty || appState.isBusy || isApplyingAll || isApplyingLowRisk)
            }
        }
        .padding(14)
        .background(Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var shouldShowToast: Bool {
        let text = appState.statusMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        return text.contains("整理") ||
            text.contains("移动") ||
            text.contains("重命名") ||
            text.contains("隔离") ||
            text.contains("失败") ||
            text.contains("已归档") ||
            text.contains("已执行") ||
            text.contains("跳过")
    }

    private func confirm(_ bundle: DecisionBundle) {
        Task {
            let success = await appState.applyBundle(bundleID: bundle.id, override: nil)
            if success {
                await MainActor.run {
                    showFeedbackToast("✓ 已应用：\(bundle.title)")
                }
            }
        }
    }

    private func skip(_ bundle: DecisionBundle) {
        Task {
            await appState.skipBundleToNextWeek(bundleID: bundle.id)
            await MainActor.run {
                showFeedbackToast("已跳过：\(bundle.title)")
            }
        }
    }

    private func acceptAllLowRisk() {
        guard !isApplyingLowRisk else { return }
        isApplyingLowRisk = true
        let bundlesToApply = lowRiskBundles
        Task {
            var appliedCount = 0
            for bundle in bundlesToApply {
                let success = await appState.applyBundle(bundleID: bundle.id, override: nil)
                if success {
                    appliedCount += 1
                }
            }
            await MainActor.run {
                isApplyingLowRisk = false
                showFeedbackToast("已接受 \(appliedCount) 条低风险建议 ✓")
            }
        }
    }

    private func confirmAllBundles() {
        guard !isApplyingAll else { return }
        isApplyingAll = true
        let bundlesToApply = appState.bundles
        Task {
            var appliedCount = 0
            for bundle in bundlesToApply {
                let success = await appState.applyBundle(bundleID: bundle.id, override: nil)
                if success {
                    appliedCount += 1
                }
            }
            await MainActor.run {
                isApplyingAll = false
                showFeedbackToast("✓ 已应用 \(appliedCount) 条整理建议")
            }
        }
    }

    private func showFeedbackToast(_ text: String) {
        feedbackToast = text
        let currentText = text
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await MainActor.run {
                if feedbackToast == currentText {
                    feedbackToast = nil
                }
            }
        }
    }

    private func humanStatus(_ text: String) -> String {
        let lower = text.lowercased()
        if lower.contains("bookmark") || lower.contains("txn_id") || lower.contains("db") {
            return "操作失败，请点击刷新后重试。"
        }
        if text.contains("No recommended files") {
            return "当前没有可归档的文件。"
        }
        return text
    }
}

private struct BundleCard: View {
    let bundle: DecisionBundle
    let missingCount: Int
    let archiveRootPath: String
    let isDisabled: Bool
    let onReview: () -> Void
    let onSkip: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(bundle.title)
                        .font(.headline)

                    Text("\(actionableCount) 个文件")
                        .font(.subheadline.weight(.medium))

                    Text(actionSummary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    if missingCount > 0 {
                        Text("将自动跳过 \(missingCount) 个已消失文件")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    if let explanationLine {
                        Text(explanationLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Spacer()

                Text("风险 \(riskLabel)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(riskColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(riskColor.opacity(0.12))
                    .clipShape(Capsule())
            }

            HStack(spacing: 10) {
                Button("查看详情", action: onReview)
                    .buttonStyle(.borderless)
                    .font(.caption)

                Spacer()

                Button("跳过", action: onSkip)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isDisabled)

                Button("确认", action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(.green)
                    .disabled(isDisabled)
            }
        }
        .padding(14)
        .background(Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var actionableCount: Int {
        max(0, bundle.filePaths.count - missingCount)
    }

    private var actionSummary: String {
        switch bundle.action.actionKind {
        case .move:
            return "移动到 \(tailPath(destinationPath, components: 2))"
        case .rename:
            return "重命名 \(actionableCount) 个文件"
        case .quarantine:
            let noun = bundle.type == .weeklyInstallers ? "安装包" : "文件"
            return "隔离 \(actionableCount) 个\(noun)"
        }
    }

    private var riskLabel: String {
        switch bundle.risk {
        case .low: return "低"
        case .medium: return "中"
        case .high: return "高"
        }
    }

    private var explanationLine: String? {
        guard let path = bundle.samplePaths.first else { return nil }
        return FileExplanationBuilder.explanation(path: path, bundleType: bundle.type)
    }

    private var destinationPath: String {
        let root = archiveRootPath.isEmpty ? "（请先选择归档根目录）" : archiveRootPath
        let month = DateFormatter.bundleMonth.string(from: Date())
        switch bundle.type {
        case .weeklyDownloadsPDF:
            return "\(root)/Downloads PDFs/\(month)"
        case .weeklyScreenshots:
            return "\(root)/Screenshots/\(month)"
        case .weeklyInstallers:
            return "\(root)/Installers/\(month)"
        case .weeklyDocuments:
            return "\(root)/Documents/\(month)"
        case .crossDirectoryGroup:
            let suggested = bundle.evidence.compactMap(\.aiSuggestedFolder).first(where: { !$0.isEmpty }) ?? "Organized"
            return "\(root)/\(suggested)"
        }
    }

    private func tailPath(_ path: String, components count: Int) -> String {
        guard path.contains("/") else { return path }
        let components = path.split(separator: "/").map(String.init)
        guard components.count > count else { return path }
        return components.suffix(count).joined(separator: "/")
    }

    private var riskColor: Color {
        switch bundle.risk {
        case .low:
            return .green
        case .medium:
            return .orange
        case .high:
            return .red
        }
    }
}

private extension DateFormatter {
    static let bundleMonth: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        return formatter
    }()
}
