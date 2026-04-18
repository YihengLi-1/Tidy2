import SwiftUI

struct ChangeLogView: View {
    @EnvironmentObject private var appState: AppState
    @State private var displayLimit: Int = 50

    private let pageSize: Int = 50

    var body: some View {
        bodyContent
            .navigationTitle("操作记录")
            .task {
                await appState.loadChangeLog()
            }
            .onChange(of: appState.changeLogEntries.count) { _ in
                displayLimit = pageSize
            }
    }

    @ViewBuilder
    private var bodyContent: some View {
        if appState.changeLogEntries.isEmpty {
            EmptyStateView(
                icon: "clock.arrow.circlepath",
                title: "暂无操作记录",
                subtitle: "整理、清理、恢复等操作完成后会记录在这里"
            )
        } else {
            logList
        }
    }

    private var logList: some View {
        List {
            // Count header when paginated
            if appState.changeLogEntries.count > pageSize {
                Text("显示 \(min(displayLimit, appState.changeLogEntries.count)) / \(appState.changeLogEntries.count) 条")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
            }

            ForEach(visibleEntries) { entry in
                HStack(alignment: .top, spacing: TidySpacing.lg) {
                    Image(systemName: iconName(for: entry))
                        .foregroundStyle(iconColor(for: entry))
                        .frame(width: 22, height: 22)
                        .padding(.top, 2)

                    VStack(alignment: .leading, spacing: TidySpacing.sm) {
                        HStack(alignment: .top, spacing: TidySpacing.lg) {
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

                        HStack(spacing: TidySpacing.md) {
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
                .padding(.vertical, TidySpacing.xxs)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(entry.title), \(DateHelper.relativeShort(entry.createdAt))")
            }

            // Show more button
            if appState.changeLogEntries.count > displayLimit {
                Button("显示更多（还有 \(appState.changeLogEntries.count - displayLimit) 条）") {
                    displayLimit += pageSize
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundColor(.accentColor)
                .frame(maxWidth: .infinity, alignment: .center)
                .listRowSeparator(.hidden)
                .padding(.vertical, TidySpacing.sm)
            }
        }
        .listStyle(.inset)
    }

    // MARK: - Computed

    private var visibleEntries: [ChangeLogEntry] {
        Array(appState.changeLogEntries.prefix(displayLimit))
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
