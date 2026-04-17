import AppKit
import SwiftUI

struct DuplicatesView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedHash: String? = nil
    @State private var showConfirm = false
    @State private var isAutoCleaning = false
    @State private var cleanupResult: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let msg = cleanupResult {
                Text(msg)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.green.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            summaryCard

            if appState.duplicateGroups.isEmpty {
                emptyState
            } else {
                List(appState.duplicateGroups) { group in
                    DuplicateGroupRow(group: group, selectedHash: $selectedHash)
                        .environmentObject(appState)
                        .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
            }
        }
        .padding(20)
        .navigationTitle("重复文件")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("重新检测") {
                    Task {
                        await appState.loadDuplicateGroups()
                    }
                }
            }
        }
        .task {
            await appState.loadDuplicateGroups()
        }
        .confirmationDialog(
            "确认一键清理",
            isPresented: $showConfirm,
            titleVisibility: .visible
        ) {
            Button("确认清理 \(SizeFormatter.string(from: appState.duplicatesTotalWastedBytes))", role: .destructive) {
                performAutoClean()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除 \(toDeleteCount) 个重复文件，每组保留最新版本，共释放 \(SizeFormatter.string(from: appState.duplicatesTotalWastedBytes))。文件移到废纸篓，可随时恢复。")
        }
    }

    private var toDeleteCount: Int {
        appState.duplicateGroups.reduce(0) { $0 + max($1.files.count - 1, 0) }
    }

    private func performAutoClean() {
        isAutoCleaning = true
        Task {
            let result = await appState.autoCleanDuplicates()
            await appState.loadDuplicateGroups()
            isAutoCleaning = false
            cleanupResult = "✓ 已清理 \(result.deleted) 个文件，释放了 \(SizeFormatter.string(from: result.freedBytes))"
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            cleanupResult = nil
        }
    }

    private var summaryCard: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("共 \(appState.duplicateGroups.count) 组重复文件")
                    .font(.headline)
                Text("可释放 \(SizeFormatter.string(from: appState.duplicatesTotalWastedBytes))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                showConfirm = true
            } label: {
                if isAutoCleaning {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("清理中...")
                    }
                } else {
                    Text("一键清理")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(isAutoCleaning || appState.duplicateGroups.isEmpty)
        }
        .padding(12)
        .background(Color.gray.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var emptyState: some View {
        EmptyStateView(
            icon: "doc.on.doc",
            title: "未发现重复文件",
            subtitle: appState.totalFilesScanned == 0 ? "先完成一次扫描，之后自动检测" : "很好，没有发现重复的文件"
        )
    }
}

private struct DuplicateGroupRow: View {
    let group: DuplicateGroup
    @Binding var selectedHash: String?
    @EnvironmentObject private var appState: AppState
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                    selectedHash = isExpanded ? group.id : nil
                }
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(primaryName)
                            .font(.headline)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Text("\(group.files.count) 个副本 · 浪费 \(SizeFormatter.string(from: group.totalWastedBytes))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    Button("清理此组（保留最新）") {
                        Task {
                            let moved = await appState.moveFilesToTrash(paths: removablePaths)
                            if moved > 0 {
                                await appState.loadDuplicateGroups()
                                appState.statusMessage = "已保留最新文件，移到回收站 \(moved) 个重复项"
                                selectedHash = nil
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(removablePaths.isEmpty)

                    ForEach(sortedDuplicates, id: \.path) { file in
                        HStack(spacing: 8) {
                            Image(systemName: fileIcon(ext: URL(fileURLWithPath: file.path).pathExtension))
                                .foregroundStyle(.secondary)
                                .frame(width: 20)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(URL(fileURLWithPath: file.path).lastPathComponent)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                Text(compactPath(file.path))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Text(DateHelper.relativeShort(file.modifiedAt))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }

                            Spacer()

                            if file.path == sortedDuplicates.first?.path {
                                Text("保留")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.green)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Color.green.opacity(0.12))
                                    .clipShape(Capsule())
                            } else {
                                Button("移到废纸篓") {
                                    trashFile(path: file.path)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .foregroundStyle(.red)
                            }
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(12)
        .background(Color.gray.opacity(0.07))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(selectedHash == group.id ? Color.accentColor.opacity(0.35) : Color.clear, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var primaryName: String {
        group.files.first?.name ?? group.contentHash
    }

    private var sortedDuplicates: [IndexedFile] {
        group.duplicates.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    private var removablePaths: [String] {
        Array(sortedDuplicates.dropFirst()).map(\.path)
    }

    private func trashFile(path: String) {
        Task {
            let moved = await appState.moveFileToTrash(path: path)
            if moved {
                await appState.loadDuplicateGroups()
            }
        }
    }

    private func compactPath(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        let components = URL(fileURLWithPath: path).pathComponents.filter { $0 != "/" }
        guard components.count > 2 else { return path }
        return "…/\(components.suffix(2).joined(separator: "/"))"
    }

    private func fileIcon(ext: String) -> String {
        switch ext.lowercased() {
        case "pdf":
            return "doc.richtext"
        case "png", "jpg", "jpeg", "heic":
            return "photo"
        case "mp4", "mov":
            return "video"
        case "mp3", "wav":
            return "music.note"
        case "zip", "rar", "7z":
            return "archivebox"
        case "dmg", "pkg":
            return "opticaldisc"
        case "doc", "docx", "txt", "md":
            return "doc.text"
        default:
            return "doc"
        }
    }
}

private extension DuplicateGroup {
    var duplicates: [IndexedFile] {
        files
    }
}
