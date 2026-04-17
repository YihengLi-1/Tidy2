import SwiftUI

struct ChangeLogView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Group {
            if appState.changeLogEntries.isEmpty {
                EmptyStateView(
                    icon: "clock.arrow.circlepath",
                    title: "暂无操作记录",
                    subtitle: "整理、清理、恢复等操作完成后会记录在这里"
                )
            } else {
                List {
                    ForEach(appState.changeLogEntries) { entry in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: iconName(for: entry))
                                .foregroundStyle(iconColor(for: entry))
                                .frame(width: 22, height: 22)
                                .padding(.top, 2)

                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .top, spacing: 12) {
                                    Text(entry.title)
                                        .font(.headline)

                                    Spacer()

                                    Text(DateHelper.relativeShort(entry.createdAt))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                if !trimmedDetail(for: entry).isEmpty {
                                    Text(trimmedDetail(for: entry))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                HStack(spacing: 10) {
                                    if entry.isUndone {
                                        Text("已撤销")
                                            .font(.caption2)
                                            .foregroundStyle(.orange)
                                    }

                                    if !entry.isUndoable {
                                        Text("不可撤销")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }

                                    if entry.isUndoable && !entry.isUndone {
                                        Button("撤销") {
                                            Task { await appState.undoLastOperation() }
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                    }

                                    if let path = entry.revealPath {
                                        Button("在访达中显示") {
                                            appState.revealInFinder(path: path)
                                        }
                                        .buttonStyle(.borderless)
                                        .font(.caption)
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("操作记录")
        .task {
            await appState.loadChangeLog()
        }
    }

    private func trimmedDetail(for entry: ChangeLogEntry) -> String {
        entry.detail.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func iconName(for entry: ChangeLogEntry) -> String {
        let text = "\(entry.title) \(entry.detail)"
        if text.contains("恢复") || text.contains("撤销") {
            return "arrow.uturn.backward"
        }
        if text.contains("隔离") {
            return "shield"
        }
        if text.contains("删除") || text.contains("清理") || text.contains("废纸篓") {
            return "trash"
        }
        if text.contains("移动") || text.contains("归档") {
            return "arrow.right.doc.on.clipboard"
        }
        return "clock.arrow.circlepath"
    }

    private func iconColor(for entry: ChangeLogEntry) -> Color {
        let text = "\(entry.title) \(entry.detail)"
        if text.contains("恢复") || text.contains("撤销") {
            return .green
        }
        if text.contains("隔离") {
            return .orange
        }
        if text.contains("删除") || text.contains("清理") || text.contains("废纸篓") {
            return .red
        }
        if text.contains("移动") || text.contains("归档") {
            return .accentColor
        }
        return .secondary
    }
}
