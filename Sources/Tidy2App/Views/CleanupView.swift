import AppKit
import SwiftUI

struct CleanupView: View {
    @EnvironmentObject private var appState: AppState
    @State private var trashingPaths: Set<String> = []
    @State private var resultMessage: String? = nil
    @State private var resultIsError: Bool = false
    @State private var displayLimitLarge = 50
    @State private var displayLimitInstallers = 50

    private var hasPrimarySuggestions: Bool {
        !appState.largeFiles.isEmpty || !appState.oldInstallers.isEmpty
    }

    var body: some View {
        Group {
            if appState.totalFilesScanned == 0 {
                EmptyStateView(
                    icon: "sparkles",
                    title: "先扫描一次",
                    subtitle: "完成扫描后，这里会展示可以清理的大文件和重复内容"
                )
            } else if !hasPrimarySuggestions {
                EmptyStateView(
                    icon: "externaldrive",
                    title: "暂无清理建议",
                    subtitle: "扫描完成后会自动检测大文件和旧安装包"
                )
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    if let msg = resultMessage {
                        HStack(spacing: TidySpacing.sm) {
                            Image(systemName: resultIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                .foregroundStyle(resultIsError ? Color.orange : Color.green)
                            Text(msg)
                                .font(.subheadline.weight(.medium))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(resultIsError ? Color.orange.opacity(0.10) : Color.green.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: TidyRadius.md))
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    reclaimableSpaceCard

                    List {
                        Section("大文件（>50MB）\(appState.largeFiles.count > displayLimitLarge ? " · 显示 \(displayLimitLarge)/\(appState.largeFiles.count)" : "")") {
                            ForEach(Array(appState.largeFiles.prefix(displayLimitLarge)), id: \.path) { file in
                                CleanupFileRow(file: file) {
                                    HStack(spacing: TidySpacing.sm) {
                                        Button("显示") {
                                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                        .accessibilityLabel("在 Finder 中显示 \(file.name)")

                                        if trashingPaths.contains(file.path) {
                                            ProgressView()
                                                .controlSize(.small)
                                                .frame(width: 60)
                                                .accessibilityLabel("正在移除 \(file.name)")
                                        } else {
                                            Button("移到废纸篓") {
                                                trashAndReload(file.path)
                                            }
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)
                                            .accessibilityLabel("将 \(file.name) 移到废纸篓")
                                        }
                                    }
                                }
                            }
                            if appState.largeFiles.count > displayLimitLarge {
                                Button("显示更多（还有 \(appState.largeFiles.count - displayLimitLarge) 个）") {
                                    displayLimitLarge += 50
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }

                        Section("老旧安装包\(appState.oldInstallers.count > displayLimitInstallers ? " · 显示 \(displayLimitInstallers)/\(appState.oldInstallers.count)" : "")") {
                            ForEach(Array(appState.oldInstallers.prefix(displayLimitInstallers)), id: \.path) { file in
                                CleanupFileRow(file: file) {
                                    HStack(spacing: TidySpacing.sm) {
                                        Button("显示") {
                                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                        .accessibilityLabel("在 Finder 中显示 \(file.name)")

                                        if trashingPaths.contains(file.path) {
                                            ProgressView()
                                                .controlSize(.small)
                                                .frame(width: 60)
                                                .accessibilityLabel("正在移除 \(file.name)")
                                        } else {
                                            Button("移到废纸篓") {
                                                trashAndReload(file.path)
                                            }
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)
                                            .accessibilityLabel("将 \(file.name) 移到废纸篓")
                                        }
                                    }
                                }
                            }
                            if appState.oldInstallers.count > displayLimitInstallers {
                                Button("显示更多（还有 \(appState.oldInstallers.count - displayLimitInstallers) 个）") {
                                    displayLimitInstallers += 50
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }

                        Section("重复文件汇总") {
                            HStack(alignment: .center, spacing: TidySpacing.lg) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("发现 \(appState.duplicateGroups.count) 组重复，可释放 \(SizeFormatter.string(from: appState.duplicatesTotalWastedBytes))")
                                        .font(.subheadline.weight(.semibold))
                                    Text("重复文件会在扫描后自动更新")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Button("查看详情") {
                                    appState.openDuplicates()
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(appState.duplicateGroups.isEmpty)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .listStyle(.inset)
                }
                .padding(20)
                .animation(.easeInOut(duration: 0.25), value: resultMessage)
            }
        }
        .navigationTitle("清理建议")
        .task {
            await appState.refreshTotalFilesScanned()
            await appState.loadDuplicateGroups()
            await appState.loadLargeFiles()
            await appState.loadOldInstallers()
        }
    }

    private var reclaimableSpaceCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("可释放空间")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(totalReclaimableLabel)
                .font(.system(size: 28, weight: .bold))
            Text("包含大文件、重复文件浪费空间和老旧安装包")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: TidyRadius.lg))
    }

    private var totalReclaimableBytes: Int64 {
        let oldInstallersBytes = appState.oldInstallers.reduce(into: Int64(0)) { partialResult, file in
            partialResult += file.sizeBytes
        }
        return appState.largeTotalBytes + appState.duplicatesTotalWastedBytes + oldInstallersBytes
    }

    private var totalReclaimableLabel: String {
        let gigabytes = Double(totalReclaimableBytes) / 1_073_741_824
        return String(format: "约 %.1f GB", gigabytes)
    }

    private func trashAndReload(_ path: String) {
        guard !trashingPaths.contains(path) else { return }
        trashingPaths.insert(path)
        Task {
            let moved = await appState.moveFileToTrash(path: path)
            // Always reload the lists regardless of success/failure —
            // files may already be gone on disk and need to be cleared from the list.
            await appState.loadLargeFiles()
            await appState.loadOldInstallers()
            await appState.loadDuplicateGroups()
            trashingPaths.remove(path)
            if moved {
                showResult("已移到废纸篓", isError: false)
            } else {
                let msg = appState.statusMessage.isEmpty
                    ? "文件不存在或无法访问，列表已刷新"
                    : appState.statusMessage
                showResult(msg, isError: true)
            }
        }
    }

    private func showResult(_ msg: String, isError: Bool) {
        resultMessage = msg
        resultIsError = isError
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            resultMessage = nil
        }
    }
}

private struct CleanupFileRow<Actions: View>: View {
    let file: IndexedFile

    private let actions: Actions

    init(file: IndexedFile, @ViewBuilder actions: () -> Actions) {
        self.file = file
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .top, spacing: TidySpacing.lg) {
            VStack(alignment: .leading, spacing: 4) {
                Text(file.name)
                    .font(.headline)
                Text(compactPath(file.path))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(SizeFormatter.string(from: file.sizeBytes)) · \(DateHelper.relativeShort(file.modifiedAt))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            actions
        }
        .padding(.vertical, 4)
        .tidyFileRowAccessibility(
            name: file.name,
            value: "\(SizeFormatter.string(from: file.sizeBytes)), \(DateHelper.relativeShort(file.modifiedAt))"
        )
        .tidyFileContextMenu(path: file.path)
    }

    private func compactPath(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        let components = URL(fileURLWithPath: path).pathComponents.filter { $0 != "/" }
        guard components.count > 3 else { return path }
        return "…/\(components.suffix(3).joined(separator: "/"))"
    }
}
