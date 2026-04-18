import AppKit
import SwiftUI

struct QuarantineView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showAdvanced = false
    @State private var confirmCleanExpired = false
    @State private var confirmSafeCleanup = false
    @State private var showHowToHandlePopover = false

    @State private var activeCountSnapshot = 0
    @State private var expiredCountSnapshot = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            summary
            howToHandleButton
            nextStepButton
            filterControl
            restoreToast
            listSection
            safeCleanupSection
            advancedSection
        }
        .padding(20)
        .navigationTitle("隔离区（可随时恢复）")
        .onAppear {
            syncCountSnapshots()
        }
        .onChange(of: appState.quarantineItems) { _ in
            syncCountSnapshots()
        }
        .onChange(of: appState.quarantineFilter) { _ in
            syncCountSnapshots()
        }
        .onChange(of: appState.digest.expiredQuarantineCount) { _ in
            syncCountSnapshots()
        }
        .confirmationDialog(
            "清理所有已过期的文件？",
            isPresented: $confirmCleanExpired,
            titleVisibility: .visible
        ) {
            Button("永久删除已过期项", role: .destructive) {
                Task { await appState.purgeExpiredQuarantine(manual: true) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此操作不可撤销，将永久删除已过期文件。")
        }
        .confirmationDialog(
            "清理可安全清理项？",
            isPresented: $confirmSafeCleanup,
            titleVisibility: .visible
        ) {
            Button("清理（不可撤销）", role: .destructive) {
                Task { await appState.purgeSafeCleanupQuarantine() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("仅清理已过期且明确低风险的项（dmg/pkg、重复文件）。")
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("隔离区：共 \(totalCount) 个文件（已过期：\(expiredCount) 个）")
                .font(.title3.weight(.semibold))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var howToHandleButton: some View {
        Button("如何使用隔离区？") {
            showHowToHandlePopover = true
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .popover(isPresented: $showHowToHandlePopover, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 10) {
                Text("先别删：隔离区默认保留30天。")
                Text("不确定就点【恢复】回原位置。")
                Text("确认不要了再清理过期项。")
            }
            .font(.body)
            .padding(16)
            .frame(width: 320, alignment: .leading)
        }
    }

    @ViewBuilder
    private var nextStepButton: some View {
        if expiredCount > 0 {
            Button(primaryButtonTitle) {
                confirmCleanExpired = true
            }
            .buttonStyle(.bordered)
            .foregroundStyle(.red)
            .controlSize(.large)
            .disabled(appState.isBusy)
        } else {
            Button(primaryButtonTitle) {
                appState.setQuarantineFilter(.active)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(appState.isBusy)
        }
    }

    private var filterControl: some View {
        Picker("筛选", selection: Binding(
            get: { appState.quarantineFilter },
            set: { appState.setQuarantineFilter($0) }
        )) {
            Text("活跃").tag(QuarantineListFilter.active)
            Text("已过期").tag(QuarantineListFilter.expired)
        }
        .pickerStyle(.segmented)
    }

    private var restoreToast: some View {
        Group {
            if let restoredName {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("已恢复：\(restoredName)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.green.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else if let purgeMsg = purgeStatusMessage {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(purgeMsg)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.green.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var listSection: some View {
        Group {
            if appState.quarantineItems.isEmpty {
                EmptyStateView(
                    icon: "archivebox",
                    title: "隔离区是空的",
                    subtitle: appState.quarantineFilter == .expired
                        ? "没有已过期的文件"
                        : "归档时被跳过或隔离的文件会放在这里，30天内可随时恢复"
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(appState.quarantineItems) { item in
                            HStack(alignment: .top, spacing: 10) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(URL(fileURLWithPath: item.originalPath).lastPathComponent)
                                        .font(.headline)
                                    Text(compactPath(item.originalPath))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(DateHelper.relativeShort(item.quarantinedAt))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if appState.quarantineFilter == .active {
                                    HStack(spacing: 8) {
                                        Button("显示") {
                                            NSWorkspace.shared.activateFileViewerSelecting(
                                                [URL(fileURLWithPath: item.quarantinePath)]
                                            )
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)

                                        Button("恢复") {
                                            Task { await appState.restoreFromQuarantine(item) }
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .controlSize(.large)
                                    }
                                }
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.gray.opacity(0.07))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var safeCleanupSection: some View {
        if appState.safeCleanupQuarantineCount > 0 {
            VStack(alignment: .leading, spacing: 8) {
                Text("可安全清理：\(appState.safeCleanupQuarantineCount) 项")
                    .font(.subheadline.weight(.semibold))
                Text("仅包含已过期的 dmg/pkg 与重复文件。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("清理 \(appState.safeCleanupQuarantineCount) 个（不可撤销）") {
                    confirmSafeCleanup = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(appState.isBusy)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private var advancedSection: some View {
        DisclosureGroup("高级选项", isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("每周自动清理已过期文件", isOn: Binding(
                    get: { appState.autoPurgeExpiredQuarantine },
                    set: { value in Task { await appState.setAutoPurgeExpiredQuarantine(value) } }
                ))
                .toggleStyle(.switch)

                Button("立即清理所有已过期文件") {
                    confirmCleanExpired = true
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 8)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var primaryButtonTitle: String {
        expiredCount > 0 ? "永久删除已过期文件（\(expiredCount) 个）" : "查看隔离区"
    }

    private var expiredCount: Int {
        max(expiredCountSnapshot, appState.digest.expiredQuarantineCount)
    }

    private var totalCount: Int {
        max(0, activeCountSnapshot) + expiredCount
    }

    private var purgeStatusMessage: String? {
        let text = appState.statusMessage
        guard text.hasPrefix("已清理") || text.hasPrefix("已安全清理") else { return nil }
        return text.isEmpty ? nil : text
    }

    private var restoredName: String? {
        let text = appState.statusMessage
        let trimmed: String
        if text.hasPrefix("已恢复：") {
            trimmed = text.replacingOccurrences(of: "已恢复：", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else if text.hasPrefix("Restored ") {
            trimmed = text.replacingOccurrences(of: "Restored ", with: "")
                .replacingOccurrences(of: ".", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            return nil
        }
        return trimmed.isEmpty ? nil : trimmed
    }

    private var emptyText: String {
        switch appState.quarantineFilter {
        case .active:
            return "暂无活跃文件。"
        case .expired:
            return "暂无已过期文件。"
        }
    }

    private func compactPath(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        let components = URL(fileURLWithPath: path).pathComponents.filter { $0 != "/" }
        guard components.count > 2 else { return path }
        return "…/\(components.suffix(2).joined(separator: "/"))"
    }

    private func syncCountSnapshots() {
        switch appState.quarantineFilter {
        case .active:
            activeCountSnapshot = appState.quarantineItems.count
            expiredCountSnapshot = appState.digest.expiredQuarantineCount
        case .expired:
            expiredCountSnapshot = appState.quarantineItems.count
        }
        if expiredCountSnapshot == 0 {
            expiredCountSnapshot = appState.digest.expiredQuarantineCount
        }
    }
}
