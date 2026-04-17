import SwiftUI

struct InstallerCandidatesView: View {
    @EnvironmentObject private var appState: AppState
    @State private var processingItemID: String?
    @State private var showTrashAllConfirm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header

                if appState.installerReviewCandidates.isEmpty {
                    if appState.totalFilesScanned > 0 {
                        EmptyStateView(
                            icon: "tray",
                            title: "没有待处理安装包",
                            subtitle: "下载的 dmg/pkg/zip 文件会出现在这里"
                        )
                    } else {
                        EmptyStateView(
                            icon: "tray",
                            title: "先扫描一次",
                            subtitle: "扫描后这里会列出需要你确认的安装包"
                        )
                    }
                } else {
                    ForEach(appState.installerReviewCandidates) { item in
                        row(item)
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("待处理安装包")
        .task {
            await appState.refreshTotalFilesScanned()
        }
        .confirmationDialog(
            "确认全部移到废纸篓？",
            isPresented: $showTrashAllConfirm,
            titleVisibility: .visible
        ) {
            Button("全部移到废纸篓", role: .destructive) {
                trashAllCandidates()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将把 \(appState.installerReviewCandidates.count) 个待处理安装包移到废纸篓，可从废纸篓恢复。")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("待处理安装包：\(appState.installerReviewCandidates.count) 个")
                    .font(.headline)
                Text("系统不确定的文件会放在这里。你可以按条处理：保留 / 归档 / 隔离。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !appState.installerReviewCandidates.isEmpty {
                Button("全部移到废纸篓") {
                    showTrashAllConfirm = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func row(_ item: SearchResultItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.headline)
                Text(compactPath(item.path))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(item.excerpt ?? appState.pendingInboxExplanation(for: item))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text("\(SizeFormatter.string(from: item.sizeBytes)) · 下载于 \(DateHelper.relativeShort(item.modifiedAt))")
                    .font(.caption2)
                    .foregroundStyle(isOldDownload(item) ? .orange : .secondary)
            }

            Spacer()

            HStack(spacing: 8) {
                Button("保留") {
                    apply(item, action: .keep)
                }
                .buttonStyle(.bordered)
                .disabled(isProcessing(item))

                Button("归档") {
                    apply(item, action: .archive)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isProcessing(item))

                Button("隔离") {
                    apply(item, action: .quarantine)
                }
                .buttonStyle(.bordered)
                .disabled(isProcessing(item))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func apply(_ item: SearchResultItem, action: PendingInboxAction) {
        processingItemID = item.id
        Task {
            await appState.handlePendingInboxItem(item, action: action)
            processingItemID = nil
        }
    }

    private func isProcessing(_ item: SearchResultItem) -> Bool {
        processingItemID == item.id || appState.isBusy
    }

    private func compactPath(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        let components = URL(fileURLWithPath: path).pathComponents.filter { $0 != "/" }
        guard components.count > 2 else { return path }
        return "…/\(components.suffix(2).joined(separator: "/"))"
    }

    private func isOldDownload(_ item: SearchResultItem) -> Bool {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -90, to: Date()) else {
            return false
        }
        return item.modifiedAt < cutoff
    }

    private func trashAllCandidates() {
        let paths = appState.installerReviewCandidates.map(\.path)
        Task {
            _ = await appState.moveFilesToTrash(paths: paths)
        }
    }
}
