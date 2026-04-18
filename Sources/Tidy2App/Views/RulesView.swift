import AppKit
import SwiftUI

struct RulesView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        List {
            Section("安全") {
                Toggle("紧急制动：停用所有规则", isOn: Binding(
                    get: { appState.rulesEmergencyBrake },
                    set: { value in
                        Task { await appState.setRulesEmergencyBrake(value) }
                    }
                ))
                .toggleStyle(.switch)

                Text("开启后，整理建议将忽略所有已学习的规则。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if appState.rules.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            Image(systemName: "ruler")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("还没有自定义规则")
                                    .font(.headline)
                                Text("确认一条整理建议后，Tidy 会自动学习规则，下次自动归档同类文件。你也可以在「整理建议」页手动确认来生成规则。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Button("去查看整理建议") {
                            appState.openBundles()
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.vertical, 8)
                }
            } else {
                ruleSection(title: "最近新增", rules: appState.recentAddedRules)
                ruleSection(title: "最近修改", rules: appState.recentModifiedRules)
                ruleSection(title: "其他规则", rules: appState.otherRules)
            }
        }
        .navigationTitle("自定义规则")
    }

    @ViewBuilder
    private func ruleSection(title: String, rules: [UserRule]) -> some View {
        if !rules.isEmpty {
            Section(title) {
                ForEach(rules) { rule in
                    ruleRow(rule)
                }
            }
        }
    }

    private func ruleRow(_ rule: UserRule) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(rule.name)
                    .font(.headline)
                Spacer()
                Toggle("启用", isOn: Binding(
                    get: { rule.isEnabled },
                    set: { newValue in
                        Task { await appState.setRuleEnabled(ruleID: rule.id, isEnabled: newValue) }
                    }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }

            Text(matchSummary(rule))
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(actionSummary(rule))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Text("触发 \(rule.stats.matchedCount) 次 · 执行 \(rule.stats.appliedCount) 次")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Button("预览效果") {
                    Task { await appState.previewRuleImpact(ruleID: rule.id) }
                }
                .buttonStyle(.borderless)

                Button("修改目标文件夹") {
                    chooseTargetFolder(for: rule)
                }
                .buttonStyle(.borderless)

                Button("删除") {
                    Task { await appState.deleteRule(ruleID: rule.id) }
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
            }

            if appState.selectedRulePreviewRuleID == rule.id {
                Divider()
                if appState.isRulePreviewLoading {
                    ProgressView()
                        .controlSize(.small)
                } else if appState.rulePreviewItems.isEmpty {
                    Text("当前没有符合条件的建议。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appState.rulePreviewItems) { item in
                        HStack {
                            Text(item.title)
                                .font(.caption)
                            Spacer()
                            Text("\(item.fileCount) 个文件")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 6)
        .listRowBackground(rowBackground(rule))
    }

    private func rowBackground(_ rule: UserRule) -> Color {
        if appState.focusedRuleID == rule.id {
            return .orange.opacity(0.14)
        }
        return .clear
    }

    private func matchSummary(_ rule: UserRule) -> String {
        var parts: [String] = []
        if let ext = rule.match.fileExt, !ext.isEmpty {
            parts.append("扩展名：.\(ext)")
        }
        if let pattern = rule.match.namePattern, !pattern.isEmpty {
            parts.append("文件名包含：\(pattern)")
        }
        if let scope = rule.match.scope {
            switch scope {
            case .downloads:  parts.append("范围：下载")
            case .desktop:    parts.append("范围：桌面")
            case .documents:  parts.append("范围：文稿")
            case .archived:   parts.append("范围：归档")
            }
        }
        if let bundleType = rule.match.bundleType {
            switch bundleType {
            case .weeklyScreenshots: parts.append("类型：截图")
            case .weeklyDownloadsPDF: parts.append("类型：PDF 文件")
            case .weeklyInstallers: parts.append("类型：安装包")
            case .weeklyDocuments: parts.append("类型：文档")
            case .crossDirectoryGroup: parts.append("类型：跨目录归组")
            }
        }
        return parts.isEmpty ? "匹配所有文件" : parts.joined(separator: " · ")
    }

    private func actionSummary(_ rule: UserRule) -> String {
        var parts: [String] = ["操作：\(localizedActionKind(rule.action.actionKind))"]
        if let template = rule.action.renameTemplate, !template.isEmpty {
            parts.append("重命名模板：\(template)")
        }
        if let bookmark = rule.action.targetFolderBookmark,
           let path = resolveBookmarkPath(bookmark) {
            let compact = compactPath(path)
            parts.append("目标：\(compact)")
        }
        return parts.joined(separator: " · ")
    }

    private func compactPath(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        let components = URL(fileURLWithPath: path).pathComponents.filter { $0 != "/" }
        guard components.count > 3 else { return path }
        return "…/\(components.suffix(3).joined(separator: "/"))"
    }

    private func chooseTargetFolder(for rule: UserRule) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "选择规则目标文件夹"

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        Task {
            await appState.updateRuleTargetFolder(ruleID: rule.id, url: url)
        }
    }

    private func resolveBookmarkPath(_ data: Data) -> String? {
        var stale = false
        let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        return url?.path
    }

    private func localizedActionKind(_ actionKind: BundleActionKind) -> String {
        switch actionKind {
        case .move:
            return "移动"
        case .rename:
            return "重命名"
        case .quarantine:
            return "隔离"
        }
    }
}
