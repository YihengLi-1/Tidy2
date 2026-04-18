import AppKit
import SwiftUI

struct VersionFilesView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showConfirm = false
    @State private var pendingTrashPaths: [String] = []
    @State private var confirmTitle = ""
    @State private var cleanupResult: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let msg = cleanupResult {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(msg).font(.subheadline.weight(.medium))
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.green.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            summaryCard

            if appState.versionGroups.isEmpty {
                EmptyStateView(
                    icon: "doc.badge.clock",
                    title: "没有发现版本文件",
                    subtitle: appState.totalFilesScanned == 0
                        ? "完成一次扫描后自动检测"
                        : "同一目录中没有发现多版本文件"
                )
            } else {
                List(appState.versionGroups) { group in
                    VersionGroupRow(group: group) { paths, title in
                        pendingTrashPaths = paths
                        confirmTitle = title
                        showConfirm = true
                    }
                    .environmentObject(appState)
                    .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
            }
        }
        .padding(20)
        .navigationTitle("版本文件")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("重新检测") {
                    Task { await appState.loadVersionGroups() }
                }
                .disabled(appState.isBusy)
            }
        }
        .task {
            await appState.loadVersionGroups()
        }
        .confirmationDialog(confirmTitle, isPresented: $showConfirm, titleVisibility: .visible) {
            Button("移到废纸篓", role: .destructive) {
                trashPaths(pendingTrashPaths)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将 \(pendingTrashPaths.count) 个旧版本文件移到废纸篓，可随时从废纸篓恢复。")
        }
    }

    private var totalWastedBytes: Int64 {
        appState.versionGroups.reduce(Int64(0)) { $0 + $1.wastedBytes }
    }

    private var summaryCard: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("共 \(appState.versionGroups.count) 组版本文件")
                    .font(.headline)
                Text("可释放 \(SizeFormatter.string(from: totalWastedBytes))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("一键清理旧版本") {
                let paths = appState.versionGroups.flatMap { g in
                    Array(g.files.dropFirst()).map(\.path)
                }
                pendingTrashPaths = paths
                confirmTitle = "清理所有旧版本？"
                showConfirm = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(appState.versionGroups.isEmpty)
        }
        .padding(12)
        .background(Color.gray.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func trashPaths(_ paths: [String]) {
        Task {
            let moved = await appState.moveFilesToTrash(paths: paths)
            if moved > 0 {
                cleanupResult = "✓ 已清理 \(moved) 个旧版本文件"
                await appState.loadVersionGroups()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                cleanupResult = nil
            }
        }
    }
}

// MARK: - Row

private struct VersionGroupRow: View {
    let group: VersionFileGroup
    let onTrash: ([String], String) -> Void
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(group.baseName)
                            .font(.headline).lineLimit(1).truncationMode(.middle)
                        Text("\(group.files.count) 个版本 · 可释放 \(SizeFormatter.string(from: group.wastedBytes))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    Button("清理此组（保留最新）") {
                        let paths = Array(group.files.dropFirst()).map(\.path)
                        onTrash(paths, "清理旧版本？")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(group.files.count < 2)

                    ForEach(Array(group.files.enumerated()), id: \.element.path) { idx, file in
                        HStack(spacing: 8) {
                            Image(systemName: "doc")
                                .foregroundStyle(.secondary).frame(width: 20)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(URL(fileURLWithPath: file.path).lastPathComponent)
                                    .font(.subheadline).lineLimit(1)
                                Text(compactPath(file.path))
                                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                Text(DateHelper.relativeShort(file.modifiedAt))
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }

                            Spacer()

                            if idx == 0 {
                                Text("最新·保留")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.green)
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(Color.green.opacity(0.12))
                                    .clipShape(Capsule())
                            } else {
                                Button("移到废纸篓") {
                                    onTrash([file.path], "移除旧版本？")
                                }
                                .buttonStyle(.bordered).controlSize(.small)
                                .foregroundStyle(.red)
                            }
                        }
                        .padding(.horizontal, 4).padding(.vertical, 2)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(12)
        .background(Color.gray.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func compactPath(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        let components = URL(fileURLWithPath: path).pathComponents.filter { $0 != "/" }
        guard components.count > 2 else { return path }
        return "…/\(components.suffix(2).joined(separator: "/"))"
    }
}
